//
//  SGShared.m
//  Scriptographer for Glyphs
//

#import "SGShared.h"
#import "SGClone.h"

#pragma mark - BroadcastChannel

// An open channel of any script.
@interface SGChannel : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) JSValue *receive;
@property (nonatomic, weak) SGBroadcast *owner;
@end

@implementation SGChannel
@end

// The open channels of all scripts, in the order they were opened:
static NSMutableArray<SGChannel *> *openChannels;

@implementation SGBroadcast {
	SGDeliver _deliver;
	NSMutableDictionary<NSNumber *, SGChannel *> *_channels;
	NSUInteger _nextChannel;
}

- (instancetype)initWithDeliver:(SGDeliver)deliver {
	self = [super init];
	if (self) {
		_deliver = deliver;
		_channels = [NSMutableDictionary dictionary];
		_nextChannel = 1;
		if (!openChannels)
			openChannels = [NSMutableArray array];
	}
	return self;
}

- (NSDictionary *)natives {
	__weak SGBroadcast *weakSelf = self;
	return @{
		@"open": ^NSNumber *(NSString *name, JSValue *receive) {
			return [weakSelf open:name receive:receive];
		},
		@"post": ^(NSNumber *number, JSValue *message) {
			[weakSelf post:message from:number];
		},
		@"close": ^(NSNumber *number) {
			[weakSelf close:number];
		}
	};
}

- (BOOL)isBusy {
	return _channels.count > 0;
}

- (void)stop {
	@synchronized ([SGBroadcast class]) {
		for (NSNumber *number in _channels.allKeys)
			[self close:number];
	}
}

- (NSNumber *)open:(NSString *)name receive:(JSValue *)receive {
	@synchronized ([SGBroadcast class]) {
		SGChannel *channel = [[SGChannel alloc] init];
		channel.name = name;
		channel.receive = receive;
		channel.owner = self;
		[openChannels addObject:channel];
		NSNumber *number = @(_nextChannel++);
		_channels[number] = channel;
		return number;
	}
}

- (void)close:(NSNumber *)number {
	@synchronized ([SGBroadcast class]) {
		[openChannels removeObject:_channels[number]];
		[_channels removeObjectForKey:number];
	}
}

// To the other channels of its name, which receive it on their scripts'
// next turn, in order:
- (void)post:(JSValue *)message from:(NSNumber *)number {
	@synchronized ([SGBroadcast class]) {
		SGChannel *sender = _channels[number];
		if (!sender)
			return;
		id data = [SGClone serialize:message natives:_scriptNatives ports:nil];
		if (!data)
			return;
		for (SGChannel *channel in openChannels) {
			if (channel == sender || ![channel.name isEqualToString:sender.name])
				continue;
			channel.owner->_deliver(channel.receive, ^id(JSContext *context) {
				JSValue *received = [JSValue valueWithNewObjectInContext:context];
				received[@"type"] = @"message";
				received[@"data"] = [SGClone deserialize:data inContext:context
						ports:nil];
				return received;
			});
		}
	}
}

@end

#pragma mark - Locks

// A request for a lock, held or waiting, of any script.
@interface SGLockRequest : NSObject
@property (nonatomic) NSUInteger number;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL isExclusive;
@property (nonatomic, weak) SGLocks *owner;
@property (nonatomic) NSUInteger client;
@end

@implementation SGLockRequest
@end

// The locks held, and the requests waiting for them, in the order they came:
static NSMutableArray<SGLockRequest *> *heldLocks, *waitingLocks;
static NSUInteger nextLockRequest = 1, nextLockClient = 1;

// Whether the lock `name` can be granted, exclusive or shared, with the
// requests waiting ahead of it:
static BOOL isLockFree(NSString *name, BOOL isExclusive, NSArray *ahead) {
	for (SGLockRequest *held in heldLocks) {
		if ([held.name isEqualToString:name]
				&& (isExclusive || held.isExclusive))
			return NO;
	}
	for (SGLockRequest *waiting in ahead) {
		if ([waiting.name isEqualToString:name])
			return NO;
	}
	return YES;
}

@implementation SGLocks {
	SGDeliver _deliver;
	NSUInteger _client;
	// The script's requests by number, with what receives what they hear:
	NSMutableDictionary<NSNumber *, JSValue *> *_receivers;
	NSMutableSet<NSNumber *> *_granted;
}

- (instancetype)initWithDeliver:(SGDeliver)deliver {
	self = [super init];
	if (self) {
		_deliver = deliver;
		_client = nextLockClient++;
		_receivers = [NSMutableDictionary dictionary];
		_granted = [NSMutableSet set];
		if (!heldLocks) {
			heldLocks = [NSMutableArray array];
			waitingLocks = [NSMutableArray array];
		}
	}
	return self;
}

- (NSDictionary *)natives {
	__weak SGLocks *weakSelf = self;
	void (^release)(NSNumber *) = ^(NSNumber *number) {
		[weakSelf release:number];
	};
	return @{
		@"request": ^NSArray *(NSString *name, BOOL exclusive,
				BOOL ifAvailable, BOOL steal, JSValue *receive) {
			return [weakSelf request:name exclusive:exclusive
					ifAvailable:ifAvailable steal:steal receive:receive];
		},
		@"release": release,
		@"cancel": release,
		@"query": ^NSDictionary * {
			return [SGLocks query];
		}
	};
}

- (BOOL)isBusy {
	return _granted.count < _receivers.count;
}

// Lets go of the script's locks and requests:
- (void)stop {
	@synchronized ([SGLocks class]) {
		NSPredicate *others = [NSPredicate predicateWithBlock:
				^BOOL(SGLockRequest *request, NSDictionary *bindings) {
			return request.client != self->_client;
		}];
		[heldLocks filterUsingPredicate:others];
		[waitingLocks filterUsingPredicate:others];
		[_receivers removeAllObjects];
		[_granted removeAllObjects];
		[SGLocks grant];
	}
}

- (NSArray *)request:(NSString *)name exclusive:(BOOL)exclusive
		ifAvailable:(BOOL)ifAvailable steal:(BOOL)steal
		receive:(JSValue *)receive {
	@synchronized ([SGLocks class]) {
		SGLockRequest *request = [[SGLockRequest alloc] init];
		request.number = nextLockRequest++;
		request.name = name;
		request.isExclusive = exclusive;
		request.owner = self;
		request.client = _client;
		if (steal) {
			for (SGLockRequest *held in [heldLocks copy]) {
				if ([held.name isEqualToString:name]) {
					[heldLocks removeObject:held];
					[held.owner hear:@"stolen" number:held.number];
				}
			}
		}
		// One that steals the lock gets it ahead of those waiting:
		NSString *state;
		if (steal || isLockFree(name, exclusive, waitingLocks)) {
			[heldLocks addObject:request];
			state = @"granted";
		} else if (ifAvailable) {
			state = @"unavailable";
		} else {
			[waitingLocks addObject:request];
			state = @"waiting";
		}
		NSNumber *number = @(request.number);
		if (![state isEqualToString:@"unavailable"]) {
			_receivers[number] = receive;
			if ([state isEqualToString:@"granted"])
				[_granted addObject:number];
		}
		return @[number, state];
	}
}

// Once the request's callback is done, or its signal aborted: the lock goes
// to the next request for it.
- (void)release:(NSNumber *)number {
	@synchronized ([SGLocks class]) {
		[_receivers removeObjectForKey:number];
		[_granted removeObject:number];
		NSPredicate *others = [NSPredicate predicateWithBlock:
				^BOOL(SGLockRequest *request, NSDictionary *bindings) {
			return request.number != number.unsignedIntegerValue;
		}];
		[heldLocks filterUsingPredicate:others];
		[waitingLocks filterUsingPredicate:others];
		[SGLocks grant];
	}
}

// Grants the requests waiting that can be, in their order:
+ (void)grant {
	for (NSUInteger i = 0; i < waitingLocks.count;) {
		SGLockRequest *request = waitingLocks[i];
		if (isLockFree(request.name, request.isExclusive,
				[waitingLocks subarrayWithRange:NSMakeRange(0, i)])) {
			[waitingLocks removeObjectAtIndex:i];
			[heldLocks addObject:request];
			[request.owner hear:@"granted" number:request.number];
		} else {
			i++;
		}
	}
}

// What a request hears, on its script's next turn:
- (void)hear:(NSString *)state number:(NSUInteger)number {
	@synchronized ([SGLocks class]) {
		JSValue *receive = _receivers[@(number)];
		if (receive) {
			[_granted addObject:@(number)];
			_deliver(receive, SGValue(state));
		}
	}
}

+ (NSDictionary *)query {
	@synchronized ([SGLocks class]) {
		NSArray *(^list)(NSArray *) = ^NSArray *(NSArray *requests) {
			NSMutableArray *infos = [NSMutableArray array];
			for (SGLockRequest *request in requests) {
				[infos addObject:@{
					@"name": request.name,
					@"mode": request.isExclusive ? @"exclusive" : @"shared",
					@"clientId": [NSString stringWithFormat:@"%lu",
							(unsigned long)request.client]
				}];
			}
			return infos;
		};
		return @{ @"held": list(heldLocks), @"pending": list(waitingLocks) };
	}
}

@end
