//
//  SGRuntime.m
//  Scriptographer for Glyphs
//

#import "SGRuntime.h"
#import <JavaScriptCore/JavaScriptCore.h>
#import <GlyphsCore/GlyphsCore.h>
#import <GlyphsApp/GlyphsApp.h>

@implementation SGRuntime {
	JSContext *_context;
	JSValue *_scriptographer;
	// Keys for the layers and paths that scripts see, both ways:
	NSMapTable<id, NSNumber *> *_keysByObject;
	NSMapTable<NSNumber *, id> *_objectsByKey;
	NSUInteger _nextKey;
	NSMutableDictionary<NSNumber *, NSTimer *> *_timers;
	NSUInteger _nextTimer;
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
		_keysByObject = [NSMapTable weakToStrongObjectsMapTable];
		_objectsByKey = [NSMapTable strongToWeakObjectsMapTable];
		_nextKey = 1;
		_timers = [NSMutableDictionary dictionary];
		_nextTimer = 1;
		[self setupContext];
	}
	return self;
}

- (void)setupContext {
	_context = [[JSContext alloc] init];
	_context.name = @"Scriptographer";
	__weak SGRuntime *weakSelf = self;
	_context.exceptionHandler = ^(JSContext *context, JSValue *exception) {
		NSString *stack = [exception[@"stack"] toString];
		[weakSelf print:stack.length
				? [NSString stringWithFormat:@"%@\n%@", exception, stack]
				: exception.toString];
	};
	[_context evaluateScript:@"var self = globalThis;"
		"var navigator = { userAgent: 'Scriptographer' };"];
	_context[@"__glyphs"] = @{
		@"getLayer": ^id {
			return [weakSelf layerData] ?: [NSNull null];
		},
		@"setPaths": ^NSArray *(NSNumber *layerKey, NSArray *edits) {
			return [weakSelf setPaths:edits layerKey:layerKey];
		},
		@"print": ^(NSString *line) {
			[weakSelf print:line];
		},
		@"setTimer": ^NSNumber *(double delay, BOOL repeat, JSValue *callback) {
			return [weakSelf setTimer:delay repeat:repeat callback:callback];
		},
		@"clearTimer": ^(NSNumber *timer) {
			[weakSelf clearTimer:timer];
		}
	};
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];
	for (NSString *name in @[@"paper-hosted", @"glyphs"]) {
		NSURL *url = [bundle URLForResource:name withExtension:@"js"];
		NSString *source = [NSString stringWithContentsOfURL:url
				encoding:NSUTF8StringEncoding error:nil];
		[_context evaluateScript:source withSourceURL:url];
	}
	_scriptographer = _context[@"Scriptographer"];
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
			for (GSNode *node in path.nodes) {
				NSPoint position = node.position;
				[nodes addObject:@(position.x)];
				[nodes addObject:@(position.y)];
				[nodes addObject:@(node.type)];
				[nodes addObject:@(node.connection)];
			}
			[paths addObject:@{
				@"key": [self keyForObject:path],
				@"closed": @(path.closed),
				@"nodes": nodes
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

#pragma mark - Timers

- (NSNumber *)setTimer:(double)delay repeat:(BOOL)repeat
		callback:(JSValue *)callback {
	NSNumber *timer = @(_nextTimer++);
	NSTimer *instance = [NSTimer timerWithTimeInterval:MAX(delay, 1) / 1000
			repeats:repeat block:^(NSTimer *instance) {
		if (!repeat)
			[self->_timers removeObjectForKey:timer];
		[callback callWithArguments:@[]];
	}];
	[[NSRunLoop mainRunLoop] addTimer:instance forMode:NSRunLoopCommonModes];
	_timers[timer] = instance;
	return timer;
}

- (void)clearTimer:(NSNumber *)timer {
	[_timers[timer] invalidate];
	[_timers removeObjectForKey:timer];
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
	BOOL isRunning = [[_scriptographer invokeMethod:@"run"
			withArguments:@[source, url.path]] toBool];
	if (_stateHandler)
		_stateHandler();
	return isRunning;
}

- (void)stopScriptAtURL:(NSURL *)url {
	[_scriptographer invokeMethod:@"stop" withArguments:@[url.path]];
	if (_stateHandler)
		_stateHandler();
}

- (BOOL)isScriptRunningAtURL:(NSURL *)url {
	return [[_scriptographer invokeMethod:@"isRunning"
			withArguments:@[url.path]] toBool];
}

- (NSURL *)toolScriptURL {
	JSValue *file = [_scriptographer invokeMethod:@"getToolFile"
			withArguments:@[]];
	return file.isString ? [NSURL fileURLWithPath:file.toString] : nil;
}

- (void)evaluate:(NSString *)code {
	[_scriptographer invokeMethod:@"evaluate" withArguments:@[code]];
}

#pragma mark - Events

- (NSDictionary *)modifiersFromFlags:(NSEventModifierFlags)flags {
	return @{
		@"shift": @((flags & NSEventModifierFlagShift) != 0),
		@"control": @((flags & NSEventModifierFlagControl) != 0),
		@"alt": @((flags & NSEventModifierFlagOption) != 0),
		@"meta": @((flags & NSEventModifierFlagCommand) != 0),
		@"capsLock": @((flags & NSEventModifierFlagCapsLock) != 0)
	};
}

- (void)handleMouse:(NSString *)type at:(NSPoint)point
		modifiers:(NSEventModifierFlags)modifiers {
	[_scriptographer invokeMethod:@"mouse" withArguments:@[
		type, @(point.x), @(point.y), [self modifiersFromFlags:modifiers]
	]];
}

- (BOOL)handleKey:(NSString *)type event:(NSEvent *)event {
	// The names of Paper.js for the keys without characters:
	static NSDictionary<NSNumber *, NSString *> *names;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		names = @{
			@123: @"left", @124: @"right", @125: @"down", @126: @"up",
			@36: @"enter", @76: @"enter", @49: @"space", @53: @"escape",
			@51: @"backspace", @117: @"delete", @48: @"tab"
		};
	});
	NSString *character = event.characters ?: @"";
	NSString *key = names[@(event.keyCode)]
			?: event.charactersIgnoringModifiers.lowercaseString ?: @"";
	return [[_scriptographer invokeMethod:@"key" withArguments:@[
		type, key, character, [self modifiersFromFlags:event.modifierFlags]
	]] toBool];
}

@end
