//
//  SGWorkers.m
//  Scriptographer for Glyphs
//

#import "SGWorkers.h"
#import "SGPorts.h"
#import "SGScript.h"

// A script connected to a shared worker: what tells it of the worker's
// errors.
@interface SGWorkerClient : NSObject
@property (nonatomic, weak) SGWorkers *owner;
@property (nonatomic, copy) SGDeliver deliver;
@property (nonatomic, strong) JSValue *onError;
@end

@implementation SGWorkerClient
@end

@interface SGWorkerLink ()
@property (nonatomic, copy) NSURL *url;
// The worker's realm and the run loop of its thread, once it runs:
@property (atomic, strong, nullable) SGScript *script;
@property (atomic) CFRunLoopRef runLoop;
// A dedicated worker's parent: what it hands messages to, and with:
@property (nonatomic, copy, nullable) SGDeliver parentDeliver;
@property (nonatomic, strong, nullable) JSValue *parentReceive;
@property (nonatomic, weak, nullable) SGPorts *parentPorts;
// A shared worker's scripts:
@property (nonatomic, strong) NSMutableArray<SGWorkerClient *> *clients;
@end

@implementation SGWorkerLink {
	// What waits for the worker's realm to run:
	NSMutableArray<void (^)(SGScript *)> *_pending;
}

- (instancetype)initWithURL:(NSURL *)url name:(NSString *)name
		shared:(BOOL)isShared {
	self = [super init];
	if (self) {
		_url = url;
		_name = name;
		_isShared = isShared;
		_clients = [NSMutableArray array];
		_pending = [NSMutableArray array];
	}
	return self;
}

// Runs the worker's script on a thread of its own, until it closes:
- (void)start {
	NSThread *thread = [[NSThread alloc] initWithBlock:^{
		NSRunLoop *loop = NSRunLoop.currentRunLoop;
		// A port keeps the run loop waiting for work:
		[loop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
		self.runLoop = CFRunLoopGetCurrent();
		SGScript *script = [[SGScript alloc] initWithURL:self.url worker:self];
		NSError *error = nil;
		NSString *source = [NSString stringWithContentsOfURL:self.url
				encoding:NSUTF8StringEncoding error:&error];
		if (!source) {
			[self reportError:[NSString stringWithFormat:
					@"Failed to load the worker's script '%@': %@",
					self.url.absoluteString, error.localizedDescription]];
			self.isClosing = YES;
		} else {
			[script evaluate:source];
			[self ready:script];
		}
		while (!self.isClosing) {
			@autoreleasepool {
				[loop runMode:NSDefaultRunLoopMode
						beforeDate:[NSDate distantFuture]];
			}
		}
		self.script = nil;
		[script stop];
	}];
	thread.name = [@"Scriptographer Worker " stringByAppendingString:_name];
	[thread start];
}

- (void)ready:(SGScript *)script {
	NSArray *pending;
	@synchronized (self) {
		self.script = script;
		pending = [_pending copy];
		[_pending removeAllObjects];
	}
	for (void (^block)(SGScript *) in pending)
		block(script);
}

// Runs `block` with the worker's realm, on its thread, once it runs:
- (void)perform:(void (^)(SGScript *script))block {
	@synchronized (self) {
		if (!self.script) {
			[_pending addObject:block];
			return;
		}
	}
	CFRunLoopPerformBlock(self.runLoop, kCFRunLoopDefaultMode, ^{
		SGScript *script = self.script;
		if (script)
			block(script);
	});
	CFRunLoopWakeUp(self.runLoop);
}

- (void)close {
	self.isClosing = YES;
	CFRunLoopRef loop = self.runLoop;
	if (loop) {
		CFRunLoopPerformBlock(loop, kCFRunLoopDefaultMode, ^{});
		CFRunLoopWakeUp(loop);
	}
}

- (void)postToParent:(NSArray *)message {
	SGPorts *ports = _parentPorts;
	if (_parentDeliver && _parentReceive && ports) {
		_parentDeliver(_parentReceive, ^id(JSContext *context) {
			NSArray *received = nil;
			JSValue *event = [JSValue valueWithNewObjectInContext:context];
			event[@"type"] = @"message";
			event[@"data"] = [ports receive:message inContext:context
					ports:&received];
			event[@"ports"] = received;
			return event;
		});
	}
}

- (void)reportError:(NSString *)message {
	if (_parentDeliver && _parentReceive) {
		_parentDeliver(_parentReceive, SGValue(@{ @"type": @"error",
				@"message": message }));
	}
	NSArray *clients;
	@synchronized (self) {
		clients = [_clients copy];
	}
	for (SGWorkerClient *client in clients)
		client.deliver(client.onError, SGValue(@{ @"message": message }));
}

@end

// The shared workers of all scripts, by their URL and name:
static NSMutableDictionary<NSString *, SGWorkerLink *> *sharedWorkers;

@implementation SGWorkers {
	SGDeliver _deliver;
	SGPorts *_ports;
	NSURL *_url;
	SGWorkerLink *_link;
	// The dedicated workers by their number, and the shared ones connected:
	NSMutableDictionary<NSNumber *, SGWorkerLink *> *_children;
	NSMutableArray<SGWorkerLink *> *_shared;
	NSUInteger _nextWorker;
}

- (instancetype)initWithDeliver:(SGDeliver)deliver ports:(SGPorts *)ports
		url:(NSURL *)url link:(SGWorkerLink *)link {
	self = [super init];
	if (self) {
		_deliver = deliver;
		_ports = ports;
		_url = url;
		_link = link;
		_children = [NSMutableDictionary dictionary];
		_shared = [NSMutableArray array];
		_nextWorker = 1;
	}
	return self;
}

- (NSDictionary *)natives {
	__weak SGWorkers *weakSelf = self;
	return @{
		@"start": ^NSNumber *(NSString *url, NSString *name,
				JSValue *receive) {
			return [weakSelf start:url name:name receive:receive];
		},
		@"post": ^(NSNumber *number, JSValue *data, JSValue *ports,
				JSValue *numbers, JSValue *buffers) {
			[weakSelf post:data to:number ports:ports numbers:numbers
					buffers:buffers];
		},
		@"terminate": ^(NSNumber *number) {
			[weakSelf terminate:number];
		},
		@"connect": ^(NSString *url, NSString *name, NSNumber *port,
				JSValue *onError) {
			[weakSelf connect:url name:name port:port onError:onError];
		},
		@"self": @{
			@"postMessage": ^(JSValue *data, JSValue *ports, JSValue *numbers,
					JSValue *buffers) {
				[weakSelf postToParent:data ports:ports numbers:numbers
						buffers:buffers];
			},
			@"close": ^{
				SGWorkers *workers = weakSelf;
				workers->_link.isClosing = YES;
			},
			@"importScripts": ^{
				[weakSelf importScripts:[JSContext currentArguments]];
			}
		}
	};
}

- (BOOL)isBusy {
	for (SGWorkerLink *child in _children.allValues) {
		if (!child.isClosing)
			return YES;
	}
	return NO;
}

// Its workers end with it, and it leaves the shared ones, which end once no
// script is connected to them:
- (void)stop {
	for (SGWorkerLink *child in _children.allValues)
		[child close];
	[_children removeAllObjects];
	for (SGWorkerLink *link in _shared) {
		BOOL isUnused;
		@synchronized (link) {
			[link.clients filterUsingPredicate:[NSPredicate predicateWithBlock:
					^BOOL(SGWorkerClient *client, NSDictionary *bindings) {
				return client.owner && client.owner != self;
			}]];
			isUnused = !link.clients.count;
		}
		if (isUnused) {
			@synchronized ([SGWorkers class]) {
				[sharedWorkers removeObjectsForKeys:
						[sharedWorkers allKeysForObject:link]];
			}
			[link close];
		}
	}
	[_shared removeAllObjects];
}

// The script at `path`, from the realm's folder, or a URL:
- (NSURL *)resolve:(NSString *)path {
	NSURL *url = [NSURL URLWithString:path relativeToURL:_url];
	if (!url.scheme || !url.scheme.length)
		url = [NSURL fileURLWithPath:path relativeToURL:_url];
	return url.absoluteURL;
}

- (NSNumber *)start:(NSString *)path name:(NSString *)name
		receive:(JSValue *)receive {
	SGWorkerLink *link = [[SGWorkerLink alloc] initWithURL:[self resolve:path]
			name:name shared:NO];
	link.parentDeliver = _deliver;
	link.parentReceive = receive;
	link.parentPorts = _ports;
	NSNumber *number = @(_nextWorker++);
	_children[number] = link;
	[link start];
	return number;
}

- (void)post:(JSValue *)data to:(NSNumber *)number ports:(JSValue *)ports
		numbers:(JSValue *)numbers buffers:(JSValue *)buffers {
	SGWorkerLink *link = _children[number];
	NSArray *message = [_ports messageOf:data ports:ports numbers:numbers
			buffers:buffers];
	if (link && message) {
		[link perform:^(SGScript *script) {
			[script receiveWorkerMessage:message];
		}];
	}
}

- (void)terminate:(NSNumber *)number {
	[_children[number] close];
	[_children removeObjectForKey:number];
}

// The one worker of the script and name that all scripts share, started by
// the first, which gets the other end of the script's port:
- (void)connect:(NSString *)path name:(NSString *)name port:(NSNumber *)port
		onError:(JSValue *)onError {
	NSURL *url = [self resolve:path];
	NSString *key = [NSString stringWithFormat:@"%@\x1f%@", url, name];
	SGWorkerLink *link;
	BOOL isNew = NO;
	@synchronized ([SGWorkers class]) {
		if (!sharedWorkers)
			sharedWorkers = [NSMutableDictionary dictionary];
		link = sharedWorkers[key];
		if (!link || link.isClosing) {
			link = sharedWorkers[key] = [[SGWorkerLink alloc] initWithURL:url
					name:name shared:YES];
			isNew = YES;
		}
	}
	SGWorkerClient *client = [[SGWorkerClient alloc] init];
	client.owner = self;
	client.deliver = _deliver;
	client.onError = onError;
	@synchronized (link) {
		[link.clients addObject:client];
	}
	if (![_shared containsObject:link])
		[_shared addObject:link];
	id end = [_ports takePort:port];
	if (end) {
		[link perform:^(SGScript *script) {
			[script connectWorkerPort:end];
		}];
	}
	if (isNew)
		[link start];
}

- (void)postToParent:(JSValue *)data ports:(JSValue *)ports
		numbers:(JSValue *)numbers buffers:(JSValue *)buffers {
	NSArray *message = [_ports messageOf:data ports:ports numbers:numbers
			buffers:buffers];
	if (message)
		[_link postToParent:message];
}

// Runs each script, in order, as a classic script, from the worker's folder
// or a URL:
- (void)importScripts:(NSArray<JSValue *> *)paths {
	JSContext *context = [JSContext currentContext];
	for (JSValue *path in paths) {
		NSURL *url = [self resolve:path.toString];
		NSError *error = nil;
		NSString *source = [NSString stringWithContentsOfURL:url
				encoding:NSUTF8StringEncoding error:&error];
		if (!source) {
			SGThrowDOMException(@"NetworkError", [NSString stringWithFormat:
					@"importScripts '%@': %@", path.toString,
					error.localizedDescription]);
			return;
		}
		[context evaluateScript:source withSourceURL:url];
		if (context.exception)
			return;
	}
}

@end
