//
//  SGRuntime.m
//  Scriptographer for Glyphs
//

#import "SGRuntime.h"
#import "SGScript.h"
#import <GlyphsCore/GlyphsCore.h>
#import <GlyphsApp/GlyphsApp.h>

@implementation SGRuntime {
	NSMutableDictionary<NSString *, SGScript *> *_scripts;
	SGScript *_console;
	// The script that runs its code for the first time:
	SGScript *_startingScript;
	// Keys for the layers and paths that scripts see, both ways:
	NSMapTable<id, NSNumber *> *_keysByObject;
	NSMapTable<NSNumber *, id> *_objectsByKey;
	NSUInteger _nextKey;
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

// Where paths keep the scripts' `item.data`, as JSON:
static NSString *const dataKey = @"com.scriptographer.data";

// The active layer with its paths, nodes flat as x, y, type, connection:
- (NSDictionary *)layerData {
	GSLayer *layer = [self activeLayer];
	if (!layer)
		return nil;
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
				NSPoint position = node.position;
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
			id json = [path userDataForKey:dataKey];
			if ([json isKindOfClass:[NSString class]])
				entry[@"data"] = json;
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
		if (!NSEqualPoints(nodes[i].position, position))
			nodes[i].position = position;
	}
	return YES;
}

// The data as JSON, or '' to remove it:
- (void)setData:(NSString *)json ofPath:(GSPath *)path {
	if (![json isKindOfClass:[NSString class]]
			|| [json isEqual:[path userDataForKey:dataKey] ?: @""])
		return;
	[path setUserData:json.length ? json : nil forKey:dataKey];
}

- (NSArray *)setPaths:(NSArray<NSDictionary *> *)edits layerKey:(NSNumber *)layerKey {
	GSLayer *layer = [_objectsByKey objectForKey:layerKey];
	NSMutableArray *keys = [NSMutableArray array];
	if (!layer)
		return keys;
	for (NSDictionary *edit in edits) {
		id key = edit[@"key"];
		GSPath *path = [key isKindOfClass:[NSNumber class]]
				? [_objectsByKey objectForKey:key]
				: nil;
		NSArray *values = edit[@"nodes"];
		BOOL closed = [edit[@"closed"] boolValue];
		if ([edit[@"remove"] boolValue]) {
			if (path)
				[layer removeShape:path];
		} else if (path) {
			if (![self movePath:path nodes:values])
				path.nodes = [self nodesFromValues:values];
			if (path.closed != closed)
				path.closed = closed;
			[self setData:edit[@"data"] ofPath:path];
		} else if (!key || key == [NSNull null]) {
			path = [[GSPath alloc] init];
			path.nodes = [self nodesFromValues:values];
			path.closed = closed;
			[self setData:edit[@"data"] ofPath:path];
			[layer addShape:path];
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
	if (isRunning && _stateHandler)
		_stateHandler();
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
