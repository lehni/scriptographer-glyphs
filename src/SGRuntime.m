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
			[paths addObject:@{
				@"key": [self keyForObject:path],
				@"closed": @(path.closed),
				@"nodes": nodes,
				@"selection": selection
			}];
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
		} else if (!key || key == [NSNull null]) {
			path = [[GSPath alloc] init];
			path.nodes = [self nodesFromValues:values];
			path.closed = closed;
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
	NSError *error = nil;
	NSString *source = [NSString stringWithContentsOfURL:url
			encoding:NSUTF8StringEncoding error:&error];
	if (!source) {
		[self print:error.localizedDescription];
		return NO;
	}
	[self stopScript:_scripts[url.path]];
	SGScript *script = [[SGScript alloc] initWithURL:url];
	_scripts[url.path] = script;
	[script execute:source];
	BOOL isRunning = _scripts[url.path] == script;
	if (isRunning && _stateHandler)
		_stateHandler();
	return isRunning;
}

- (void)stopScript:(SGScript *)script {
	if (!script)
		return;
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
		[self stopScript:script];
	[self stopScript:_console];
}

- (BOOL)isScriptRunningAtURL:(NSURL *)url {
	return _scripts[url.path] != nil;
}

- (void)evaluate:(NSString *)code {
	if (!_console)
		_console = [[SGScript alloc] initWithURL:nil];
	[_console execute:code];
}

// Scripts that stopped running go; the last one to define a tool gets the
// Script tool's events. Only what the browser shows changing tells it.
- (void)scriptDidWork:(SGScript *)script {
	if (script != _console && ![script isRunning]) {
		[self stopScript:script];
	} else if ([script hasTool] && script != _toolScript) {
		_toolScript = script;
		if (_stateHandler)
			_stateHandler();
	}
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
