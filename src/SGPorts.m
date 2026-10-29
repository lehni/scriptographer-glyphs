//
//  SGPorts.m
//  Scriptographer for Glyphs
//

#import "SGPorts.h"
#import "SGClone.h"

// A port: its other port, the messages waiting for it, and the script it's
// in, with its number there and what receives its messages once started.
@interface SGPortEnd : NSObject
@property (nonatomic, weak, nullable) SGPortEnd *peer;
@property (nonatomic, strong) NSMutableArray<NSArray *> *queue;
@property (nonatomic, weak, nullable) SGPorts *owner;
@property (nonatomic, strong, nullable) JSValue *receive;
@end

@implementation SGPortEnd

- (instancetype)init {
	self = [super init];
	if (self)
		_queue = [NSMutableArray array];
	return self;
}

@end

@interface SGPorts ()
- (void)flush:(SGPortEnd *)end;
@end

@implementation SGPorts {
	SGDeliver _deliver;
	// The script's ports by number, which also keeps them, and their ends
	// once crossed:
	NSMutableDictionary<NSNumber *, SGPortEnd *> *_ends;
	NSUInteger _nextPort;
}

- (instancetype)initWithDeliver:(SGDeliver)deliver {
	self = [super init];
	if (self) {
		_deliver = deliver;
		_ends = [NSMutableDictionary dictionary];
		_nextPort = 1;
	}
	return self;
}

- (NSDictionary *)natives {
	__weak SGPorts *weakSelf = self;
	return @{
		@"channel": ^NSArray * {
			return [weakSelf channel];
		},
		@"post": ^(NSNumber *number, JSValue *value, JSValue *ports,
				JSValue *numbers, JSValue *buffers) {
			[weakSelf post:value from:number ports:ports numbers:numbers
					buffers:buffers];
		},
		@"start": ^(NSNumber *number, JSValue *receive) {
			[weakSelf start:number receive:receive];
		},
		@"close": ^(NSNumber *number) {
			[weakSelf close:number];
		}
	};
}

// Started, with its other port still there to send:
- (BOOL)isBusy {
	for (SGPortEnd *end in _ends.allValues) {
		if (end.receive && end.peer)
			return YES;
	}
	return NO;
}

- (void)stop {
	for (NSNumber *number in _ends.allKeys)
		[self close:number];
}

- (NSNumber *)adopt:(SGPortEnd *)end {
	NSNumber *number = @(_nextPort++);
	end.owner = self;
	end.receive = nil;
	_ends[number] = end;
	return number;
}

- (NSArray *)channel {
	SGPortEnd *first = [[SGPortEnd alloc] init];
	SGPortEnd *second = [[SGPortEnd alloc] init];
	first.peer = second;
	second.peer = first;
	return @[[self adopt:first], [self adopt:second]];
}

- (NSArray *)messageOf:(JSValue *)value ports:(JSValue *)ports
		numbers:(JSValue *)numbers buffers:(JSValue *)buffers {
	NSArray *list = ports.isArray ? ports.toArray : @[];
	NSMutableArray *portValues = [NSMutableArray array];
	for (NSUInteger i = 0; i < list.count; i++)
		[portValues addObject:ports[i]];
	id data = [SGClone serialize:value natives:_scriptNatives
			ports:portValues];
	if (!data)
		return nil;
	// The ports it transfers leave the script, and the buffers are copied
	// and detached:
	NSMutableArray *ends = [NSMutableArray array];
	for (NSNumber *number in numbers.isArray ? numbers.toArray : @[]) {
		SGPortEnd *end = _ends[number];
		if (end) {
			[_ends removeObjectForKey:number];
			end.owner = nil;
			[ends addObject:end];
		}
	}
	NSUInteger length = [buffers[@"length"] toUInt32];
	for (NSUInteger i = 0; buffers.isArray && i < length; i++)
		[buffers[i] invokeMethod:@"transfer" withArguments:@[]];
	return @[data, ends];
}

- (JSValue *)receive:(NSArray *)message inContext:(JSContext *)context
		ports:(NSArray<JSValue *> **)ports {
	NSMutableArray *made = [NSMutableArray array];
	for (SGPortEnd *end in message[1]) {
		[made addObject:[_scriptNatives invokeMethod:@"makePort"
				withArguments:@[[self adopt:end]]]];
	}
	if (ports)
		*ports = made;
	return [SGClone deserialize:message[0] inContext:context ports:made];
}

// A port whose other port is gone takes nothing, as in browsers:
- (void)post:(JSValue *)value from:(NSNumber *)number ports:(JSValue *)ports
		numbers:(JSValue *)numbers buffers:(JSValue *)buffers {
	SGPortEnd *end = _ends[number];
	NSArray *message = [self messageOf:value ports:ports numbers:numbers
			buffers:buffers];
	SGPortEnd *peer = end.peer;
	if (!message || !peer)
		return;
	[peer.queue addObject:message];
	[peer.owner flush:peer];
}

- (void)start:(NSNumber *)number receive:(JSValue *)receive {
	SGPortEnd *end = _ends[number];
	end.receive = receive;
	[self flush:end];
}

- (void)close:(NSNumber *)number {
	SGPortEnd *end = _ends[number];
	[_ends removeObjectForKey:number];
	end.peer.peer = nil;
	end.peer = nil;
}

// Hands the port's messages to its script on its next turn, once started:
- (void)flush:(SGPortEnd *)end {
	if (!end.receive || !end.queue.count)
		return;
	while (end.queue.count) {
		NSArray *message = end.queue.firstObject;
		[end.queue removeObjectAtIndex:0];
		_deliver(end.receive, ^id(JSContext *context) {
			NSArray *ports = nil;
			JSValue *received = [JSValue valueWithNewObjectInContext:context];
			received[@"type"] = @"message";
			received[@"data"] = [self receive:message inContext:context
					ports:&ports];
			received[@"ports"] = ports;
			return received;
		});
	}
}

@end
