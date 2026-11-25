//
//  SGRuntime.m
//  Scriptographer for Glyphs
//

#import "SGRuntime.h"
#import "SGScript.h"
#import <GlyphsCore/GlyphsCore.h>
#import <GlyphsApp/GlyphsApp.h>
#import <CommonCrypto/CommonDigest.h>

@implementation SGRuntime {
	NSMutableDictionary<NSString *, SGScript *> *_scripts;
	SGScript *_console;
	// The script that runs its code for the first time:
	SGScript *_startingScript;
	// Keys for the layers and paths that scripts see, both ways:
	NSMapTable<id, NSNumber *> *_keysByObject;
	NSMapTable<NSNumber *, id> *_objectsByKey;
	NSUInteger _nextKey;
	BOOL _isApplyingEffects;
	// The layers that scripts changed in their current work, whose effects
	// draw again once it's done, see -scriptDidWork:
	NSMutableSet<GSLayer *> *_editedLayers;
	// The layers that Glyphs' own tools change in an interaction, whose
	// interactive effects draw along once it's done with the current step:
	NSMutableSet<GSLayer *> *_interactiveLayers;
}

+ (instancetype)sharedRuntime {
	static SGRuntime *runtime;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		runtime = [[SGRuntime alloc] init];
	});
	return runtime;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		_scripts = [NSMutableDictionary dictionary];
		_editedLayers = [NSMutableSet set];
		_interactiveLayers = [NSMutableSet set];
		_keysByObject = [NSMapTable weakToStrongObjectsMapTable];
		_objectsByKey = [NSMapTable strongToWeakObjectsMapTable];
		_nextKey = 1;
		_responseTime = 5;
		// The scripts hear when Glyphs comes to the front, leaves it, and
		// quits:
		NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
		NSDictionary *handlers = @{
			NSApplicationDidBecomeActiveNotification: @"onAppActivate",
			NSApplicationDidResignActiveNotification: @"onAppDeactivate",
			NSApplicationWillTerminateNotification: @"onShutdown"
		};
		for (NSString *notification in handlers) {
			__weak SGRuntime *weakSelf = self;
			[center addObserverForName:notification object:nil queue:nil
					usingBlock:^(NSNotification *note) {
				[weakSelf callHandler:handlers[notification]];
			}];
		}
		// Effects draw again once an edit is done, into its undo step:
		[center addObserver:self selector:@selector(undoGroupWillClose:)
				name:NSUndoManagerWillCloseUndoGroupNotification object:nil];
		[center addObserver:self selector:@selector(interfaceWillUpdate:)
				name:GSUpdateInterface object:nil];
	}
	return self;
}

- (void)print:(NSString *)line {
	NSLog(@"Scriptographer: %@", line);
	if (_printHandler)
		_printHandler(line);
}

#pragma mark - Layers

- (NSNumber *)keyForObject:(id)object {
	NSNumber *key = [_keysByObject objectForKey:object];
	if (!key) {
		key = @(_nextKey++);
		[_keysByObject setObject:key forKey:object];
		[_objectsByKey setObject:object forKey:key];
	}
	return key;
}

- (GSLayer *)activeLayer {
	if (_toolLayer)
		return _toolLayer;
	GSDocument *document = (GSDocument *)
			[[NSDocumentController sharedDocumentController] currentDocument];
	return [document isKindOfClass:[GSDocument class]]
			? document.windowController.activeLayer
			: nil;
}

// Where paths keep the scripts' `item.data` and `item.effects`, as JSON,
// with what the effects last drew: their input, and the id that their output
// paths keep, so they draw again only once the input changes, see
// -setEffectOutput:input:ofPathKey:
static NSString *const dataKey = @"com.scriptographer.data";
static NSString *const effectsKey = @"com.scriptographer.effects";
static NSString *const effectsInputKey = @"com.scriptographer.effectsInput";
static NSString *const effectsIdKey = @"com.scriptographer.effectsId";
static NSString *const effectOfKey = @"com.scriptographer.effectOf";
// The fingerprint of what the effects drew, which edits in Glyphs change:
static NSString *const effectsOutputKey = @"com.scriptographer.effectsOutput";

- (NSDictionary *)layerData {
	GSLayer *layer = [self activeLayer];
	return layer ? [self dataOfLayer:layer] : nil;
}

// The layer with its paths, nodes flat as x, y, type, connection. Scripts
// get the nodes' positions as they set them, which Glyphs rounds to the grid
// only to show and keep them, so rounding doesn't add up over their changes:
- (NSDictionary *)dataOfLayer:(GSLayer *)layer {
	NSMutableArray *paths = [NSMutableArray array];
	for (GSShape *shape in layer.shapes) {
		if ([shape isKindOfClass:[GSPath class]]) {
			GSPath *path = (GSPath *)shape;
			NSMutableArray *nodes = [NSMutableArray array];
			NSMutableArray *selection = [NSMutableArray array];
			BOOL isSelected = [layer selectionContainsObject:path];
			for (GSNode *node in path.nodes) {
				if (isSelected || [layer selectionContainsObject:node])
					[selection addObject:@(nodes.count / 4)];
				NSPoint position = node.positionPrecise;
				[nodes addObject:@(position.x)];
				[nodes addObject:@(position.y)];
				[nodes addObject:@(node.type)];
				[nodes addObject:@(node.connection)];
			}
			NSMutableDictionary *entry = [@{
				@"key": [self keyForObject:path],
				@"closed": @(path.closed),
				@"nodes": nodes,
				@"selection": selection
			} mutableCopy];
			NSDictionary *keys = @{
				@"data": dataKey,
				@"effects": effectsKey,
				@"effectsInput": effectsInputKey
			};
			for (NSString *name in keys) {
				id json = [path userDataForKey:keys[name]];
				if ([json isKindOfClass:[NSString class]])
					entry[name] = json;
			}
			[paths addObject:entry];
		}
	}
	return @{ @"key": [self keyForObject:layer], @"paths": paths };
}

- (NSArray<GSNode *> *)nodesFromValues:(NSArray<NSNumber *> *)values {
	NSMutableArray *nodes = [NSMutableArray array];
	for (NSUInteger i = 0; i + 3 < values.count; i += 4) {
		NSPoint position = NSMakePoint(values[i].doubleValue,
				values[i + 1].doubleValue);
		[nodes addObject:[[GSNode alloc] initWithPosition:position
				type:(GSNodeType)values[i + 2].intValue
				connection:(GSNodeConnection)values[i + 3].intValue]];
	}
	return nodes;
}

// Moves the nodes in place when the path keeps their types, so they keep their
// connections, names and other attributes:
- (BOOL)movePath:(GSPath *)path nodes:(NSArray<NSNumber *> *)values {
	NSArray<GSNode *> *nodes = path.nodes;
	if (values.count != nodes.count * 4)
		return NO;
	for (NSUInteger i = 0; i < nodes.count; i++) {
		if (nodes[i].type != values[i * 4 + 2].intValue)
			return NO;
	}
	for (NSUInteger i = 0; i < nodes.count; i++) {
		NSPoint position = NSMakePoint(values[i * 4].doubleValue,
				values[i * 4 + 1].doubleValue);
		if (!NSEqualPoints(nodes[i].positionPrecise, position))
			nodes[i].position = position;
	}
	return YES;
}

// The path's value of `key`, or '' to remove it:
- (void)setString:(NSString *)string forKey:(NSString *)key
		ofPath:(GSPath *)path {
	if (![string isKindOfClass:[NSString class]]
			|| [string isEqual:[path userDataForKey:key] ?: @""])
		return;
	[path setUserData:string.length ? string : nil forKey:key];
}

// The data and effects of an edit. A closed path with effects is hidden, so
// only what they draw is outline: Glyphs shows it pale, without its handles.
// Open ones are no outline anyway, and keep them. One without effects loses
// what they drew:
- (void)setDataAndEffects:(NSDictionary *)edit ofPath:(GSPath *)path {
	[self setString:edit[@"data"] forKey:dataKey ofPath:path];
	[self setString:edit[@"effects"] forKey:effectsKey ofPath:path];
	BOOL hasEffects = [path userDataForKey:effectsKey] != nil;
	BOOL isHidden = hasEffects && path.closed;
	if (path.hidden != isHidden)
		path.hidden = isHidden;
	if (!hasEffects)
		[self removeEffectOutputOfPath:path];
}

// The paths that the path's effects drew:
- (NSArray<GSPath *> *)effectOutputOfPath:(GSPath *)path {
	NSString *outputId = [path userDataForKey:effectsIdKey];
	GSLayer *layer = (GSLayer *)path.parent;
	NSMutableArray *outputs = [NSMutableArray array];
	for (GSShape *shape in outputId ? layer.shapes : @[]) {
		if ([[shape userDataForKey:effectOfKey] isEqual:outputId])
			[outputs addObject:shape];
	}
	return outputs;
}

// A digest of the nodes of what the path's effects drew:
- (NSString *)effectOutputFingerprintOfPath:(GSPath *)path {
	NSMutableString *string = [NSMutableString string];
	for (GSPath *output in [self effectOutputOfPath:path]) {
		[string appendFormat:@"%d", output.closed];
		for (GSNode *node in output.nodes) {
			NSPoint position = node.positionPrecise;
			[string appendFormat:@" %g,%g,%d", position.x, position.y,
					node.type];
		}
		[string appendString:@";"];
	}
	const char *bytes = string.UTF8String;
	unsigned char digest[CC_SHA256_DIGEST_LENGTH];
	CC_SHA256(bytes, (CC_LONG)strlen(bytes), digest);
	NSMutableString *hex = [NSMutableString string];
	for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
		[hex appendFormat:@"%02x", digest[i]];
	return hex;
}

- (void)removeEffectOutputOfPath:(GSPath *)path {
	[(GSLayer *)path.parent removeShapes:[self effectOutputOfPath:path]];
	[path removeUserDataForKey:effectsInputKey];
	[path removeUserDataForKey:effectsIdKey];
	[path removeUserDataForKey:effectsOutputKey];
}

- (void)setEffectOutput:(NSArray<NSDictionary *> *)outputs
		input:(NSString *)input ofPathKey:(NSNumber *)key {
	GSPath *path = [_objectsByKey objectForKey:key];
	GSLayer *layer = (GSLayer *)path.parent;
	if (![path isKindOfClass:[GSPath class]] || !layer)
		return;
	[self removeEffectOutputOfPath:path];
	NSString *outputId = NSUUID.UUID.UUIDString;
	[path setUserData:outputId forKey:effectsIdKey];
	[path setUserData:input forKey:effectsInputKey];
	// Beneath the path, in their order, locked, as they follow it, also their
	// nodes and handles, which Glyphs' tools edit within locked paths:
	NSInteger index = [layer.shapes indexOfObject:path];
	for (NSDictionary *output in outputs) {
		GSPath *shape = [[GSPath alloc] init];
		NSArray<GSNode *> *nodes = [self nodesFromValues:output[@"nodes"]];
		for (GSNode *node in nodes)
			node.locked = YES;
		shape.nodes = nodes;
		shape.closed = [output[@"closed"] boolValue];
		shape.locked = YES;
		[shape setUserData:outputId forKey:effectOfKey];
		[layer insertObject:shape inShapesAtIndex:index++];
	}
	[path setUserData:[self effectOutputFingerprintOfPath:path]
			forKey:effectsOutputKey];
	_editCount++;
}

- (NSArray *)setPaths:(NSArray<NSDictionary *> *)edits layerKey:(NSNumber *)layerKey {
	GSLayer *layer = [_objectsByKey objectForKey:layerKey];
	NSMutableArray *keys = [NSMutableArray array];
	if (!layer)
		return keys;
	[_editedLayers addObject:layer];
	for (NSDictionary *edit in edits) {
		id key = edit[@"key"];
		GSPath *path = [key isKindOfClass:[NSNumber class]]
				? [_objectsByKey objectForKey:key]
				: nil;
		NSArray *values = edit[@"nodes"];
		BOOL closed = [edit[@"closed"] boolValue];
		if ([edit[@"remove"] boolValue]) {
			if (path) {
				[self removeEffectOutputOfPath:path];
				[layer removeShape:path];
			}
		} else if (path) {
			if (![self movePath:path nodes:values])
				path.nodes = [self nodesFromValues:values];
			if (path.closed != closed)
				path.closed = closed;
			[self setDataAndEffects:edit ofPath:path];
		} else if (!key || key == [NSNull null]) {
			path = [[GSPath alloc] init];
			path.nodes = [self nodesFromValues:values];
			path.closed = closed;
			[layer addShape:path];
			[self setDataAndEffects:edit ofPath:path];
			[keys addObject:[self keyForObject:path]];
		}
	}
	_editCount++;
	return keys;
}

- (void)setSelection:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)selection
		layerKey:(NSNumber *)layerKey {
	GSLayer *layer = [_objectsByKey objectForKey:layerKey];
	NSMutableArray *nodes = [NSMutableArray array];
	for (NSString *key in selection) {
		GSPath *path = [_objectsByKey objectForKey:@(key.integerValue)];
		if (![path isKindOfClass:[GSPath class]] || path.parent != layer)
			continue;
		for (NSNumber *index in selection[key]) {
			if (index.unsignedIntegerValue < path.nodes.count)
				[nodes addObject:path.nodes[index.unsignedIntegerValue]];
		}
	}
	[layer replaceSelection:nodes];
}

#pragma mark - Effects

// Each glyph keeps its own undo steps. Undoing one brings back what its
// effects drew with it:
- (void)undoGroupWillClose:(NSNotification *)notification {
	GSUndoManager *manager = notification.object;
	if (![manager isKindOfClass:[GSUndoManager class]]
			|| manager.groupingLevel > 1 || manager.isUndoing
			|| manager.isRedoing)
		return;
	GSGlyph *glyph = (GSGlyph *)manager.glyph;
	if ([glyph isKindOfClass:[GSGlyph class]])
		[self applyEffectsOfLayers:glyph.layers.allValues interactive:NO];
}

// Glyphs asks its edit view to update with each step of its own tools'
// drags, while their undo step stays open. Interactive effects draw along,
// once Glyphs is done with the step, into that undo step:
- (void)interfaceWillUpdate:(NSNotification *)notification {
	GSEditViewController *controller = notification.object;
	if (![controller isKindOfClass:[GSEditViewController class]])
		return;
	GSLayer *layer = controller.activeLayer;
	if (!layer || !layer.undoManager.groupingLevel || _isApplyingEffects)
		return;
	BOOL isScheduled = _interactiveLayers.count > 0;
	[_interactiveLayers addObject:layer];
	if (!isScheduled) {
		dispatch_async(dispatch_get_main_queue(), ^{
			NSArray *layers = self->_interactiveLayers.allObjects;
			[self->_interactiveLayers removeAllObjects];
			[self applyEffectsOfLayers:layers interactive:YES];
		});
	}
}

// Has the scripts draw the effects of the layers' paths, those that they
// know, where their input changed, only interactive ones when `interactive`:
- (void)applyEffectsOfLayers:(NSArray<GSLayer *> *)layers
		interactive:(BOOL)interactive {
	if (_isApplyingEffects)
		return;
	_isApplyingEffects = YES;
	GSLayer *toolLayer = _toolLayer;
	NSMutableArray<SGScript *> *scripts = [_scripts.allValues mutableCopy];
	if (_console)
		[scripts addObject:_console];
	for (GSLayer *layer in layers) {
		BOOL hasEffects = NO;
		for (GSShape *shape in layer.shapes) {
			if (![shape userDataForKey:effectsKey])
				continue;
			hasEffects = YES;
			// What the effects drew and Glyphs' tools changed, which locking
			// doesn't fully prevent, they draw again, once the edit is done:
			NSString *fingerprint = [shape userDataForKey:effectsOutputKey];
			if (!interactive && fingerprint && ![fingerprint isEqual:
					[self effectOutputFingerprintOfPath:(GSPath *)shape]])
				[shape removeUserDataForKey:effectsInputKey];
		}
		if (!hasEffects)
			continue;
		_toolLayer = layer;
		for (SGScript *script in scripts)
			[script applyEffects:interactive];
	}
	_toolLayer = toolLayer;
	_isApplyingEffects = NO;
}

#pragma mark - Scripts

- (BOOL)runScriptAtURL:(NSURL *)url {
	[self stopScript:_scripts[url.path] notify:YES];
	for (SGScript *other in _scripts.allValues) {
		if (other != _toolScript && ![other keepsAlive])
			[self stopScript:other notify:YES];
	}
	return [self startScriptAtURL:url];
}

- (BOOL)startScriptAtURL:(NSURL *)url {
	NSError *error = nil;
	NSString *source = [NSString stringWithContentsOfURL:url
			encoding:NSUTF8StringEncoding error:&error];
	if (!source) {
		[self print:error.localizedDescription];
		return NO;
	}
	SGScript *script = [[SGScript alloc] initWithURL:url];
	_scripts[url.path] = script;
	_startingScript = script;
	[script execute:source];
	_startingScript = nil;
	BOOL isRunning = _scripts[url.path] == script;
	if (isRunning) {
		// The effects it defines draw what changed while it didn't run:
		GSLayer *layer = [self activeLayer];
		if (layer.parent) {
			[self applyEffectsOfLayers:layer.parent.layers.allValues
					interactive:NO];
		}
		if (_stateHandler)
			_stateHandler();
	}
	return isRunning;
}

- (void)stopScript:(SGScript *)script {
	[self stopScript:script notify:NO];
}

// With `notify`, a script that's stopped hears it first, `onStop`:
- (void)stopScript:(SGScript *)script notify:(BOOL)notify {
	if (!script)
		return;
	if (notify)
		[script callHandler:@"onStop"];
	[script stop];
	if (script == _console)
		_console = nil;
	else if (script.url)
		[_scripts removeObjectForKey:script.url.path];
	if (script == _toolScript)
		_toolScript = nil;
	if (_stateHandler)
		_stateHandler();
}

- (void)stopAllScripts {
	for (SGScript *script in _scripts.allValues)
		[self stopScript:script notify:YES];
	[self stopScript:_console notify:YES];
}

- (void)callHandler:(NSString *)name {
	for (SGScript *script in _scripts.allValues)
		[script callHandler:name];
	[_console callHandler:name];
}

- (void)runInitScriptsIn:(NSArray<NSURL *> *)folders {
	NSMutableArray *started = [NSMutableArray array];
	for (NSURL *folder in folders) {
		NSDirectoryEnumerator *files = [NSFileManager.defaultManager
				enumeratorAtURL:folder includingPropertiesForKeys:nil
				options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
		for (NSURL *url in files) {
			if ([url.lastPathComponent hasPrefix:@"__init__"]
					&& [@[@"js", @"pjs"] containsObject:url.pathExtension]
					&& [self startScriptAtURL:url])
				[started addObject:url];
		}
	}
	for (NSURL *url in started)
		[_scripts[url.path] callHandler:@"onStartup"];
}

- (BOOL)isScriptRunningAtURL:(NSURL *)url {
	return _scripts[url.path] != nil;
}

- (void)evaluate:(NSString *)code {
	if (!_console)
		_console = [[SGScript alloc] initWithURL:nil];
	[_console execute:code];
}

// Scripts that stopped running go, those that ran on with a line in the
// console, as in VectorCraft; the last one to define a tool gets the Script
// tool's events. Only what the browser shows changing tells it.
- (void)scriptDidWork:(SGScript *)script {
	// Within the undo step of a tool's drag, which Glyphs keeps open until the
	// mouse goes up:
	if (_editedLayers.count) {
		NSArray *layers = _editedLayers.allObjects;
		[_editedLayers removeAllObjects];
		[self applyEffectsOfLayers:layers interactive:NO];
	}
	if (script != _console && ![script isRunning]) {
		if (script != _startingScript && _scripts[script.url.path] == script)
			[self print:[NSString stringWithFormat:@"%@ stopped", script.name]];
		[self stopScript:script];
	} else if ([script hasTool] && script != _toolScript) {
		_toolScript = script;
		if (_stateHandler)
			_stateHandler();
	}
}

- (void)scriptDidFail {
	if (_failureHandler)
		_failureHandler();
}

// As browsers ask about a page that hangs:
- (BOOL)shouldStopScript:(SGScript *)script {
	if (_stopHandler)
		return _stopHandler(script);
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = [NSString stringWithFormat:@"“%@” isn't responding",
			script.name ?: @"A script"];
	alert.informativeText = @"The script hasn't finished its work. You can "
			"wait for it, or stop it.";
	[alert addButtonWithTitle:@"Stop"];
	[alert addButtonWithTitle:@"Wait"];
	return [alert runModal] == NSAlertFirstButtonReturn;
}

#pragma mark - Overlays

- (void)drawOverlaysInContext:(CGContextRef)context scale:(double)scale {
	for (SGScript *script in _scripts.allValues)
		[script drawOverlayInContext:context scale:scale];
	[_console drawOverlayInContext:context scale:scale];
}

- (void)redrawView {
	GSDocument *document = (GSDocument *)
			[[NSDocumentController sharedDocumentController] currentDocument];
	if ([document isKindOfClass:[GSDocument class]])
		[document.windowController.activeEditViewController redraw];
}

#pragma mark - Events

- (void)handleMouse:(NSString *)type at:(NSPoint)point
		modifiers:(NSEventModifierFlags)modifiers {
	[_toolScript handleMouse:type at:point modifiers:modifiers];
}

- (BOOL)handleKey:(NSString *)type event:(NSEvent *)event {
	return [_toolScript handleKey:type event:event];
}

@end
