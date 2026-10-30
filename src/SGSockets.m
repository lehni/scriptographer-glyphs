//
//  SGSockets.m
//  Scriptographer for Glyphs
//

#import "SGSockets.h"

@interface SGSockets () <NSURLSessionWebSocketDelegate>
@end

@implementation SGSockets {
	SGDeliver _deliver;
	NSURLSession *_session;
	// The open sockets by their number, with what receives what they read:
	NSMutableDictionary<NSNumber *, NSURLSessionWebSocketTask *> *_sockets;
	NSMapTable<NSURLSessionTask *, JSValue *> *_receivers;
	NSUInteger _nextSocket;
}

- (instancetype)initWithDeliver:(SGDeliver)deliver {
	self = [super init];
	if (self) {
		_deliver = deliver;
		_sockets = [NSMutableDictionary dictionary];
		_receivers = [NSMapTable strongToStrongObjectsMapTable];
		_nextSocket = 1;
	}
	return self;
}

- (NSDictionary *)natives {
	__weak SGSockets *weakSelf = self;
	return @{
		@"open": ^NSNumber *(NSString *url, NSArray *protocols,
				JSValue *receive) {
			return [weakSelf open:url protocols:protocols receive:receive];
		},
		@"send": ^(NSNumber *number, JSValue *data) {
			[weakSelf send:data.isString ? data.toString : SGDataOfValue(data)
					to:number];
		},
		@"close": ^(NSNumber *number, NSInteger code, NSString *reason) {
			[weakSelf close:number code:code reason:reason];
		}
	};
}

- (BOOL)isBusy {
	return _sockets.count > 0;
}

- (void)stop {
	@synchronized (self) {
		[_session invalidateAndCancel];
		_session = nil;
		[_sockets removeAllObjects];
		[_receivers removeAllObjects];
	}
}

- (NSNumber *)open:(NSString *)url protocols:(NSArray<NSString *> *)protocols
		receive:(JSValue *)receive {
	@synchronized (self) {
		if (!_session) {
			_session = [NSURLSession sessionWithConfiguration:
					NSURLSessionConfiguration.ephemeralSessionConfiguration
					delegate:self delegateQueue:NSOperationQueue.mainQueue];
		}
		NSNumber *number = @(_nextSocket++);
		NSURLSessionWebSocketTask *task = [_session
				webSocketTaskWithURL:[NSURL URLWithString:url]
				protocols:protocols];
		_sockets[number] = task;
		[_receivers setObject:receive forKey:task];
		[task resume];
		[self read:task];
		return number;
	}
}

// Reads the socket's messages, one after another, until it closes:
- (void)read:(NSURLSessionWebSocketTask *)task {
	__weak SGSockets *weakSelf = self;
	[task receiveMessageWithCompletionHandler:
			^(NSURLSessionWebSocketMessage *message, NSError *error) {
		SGSockets *sockets = weakSelf;
		JSValue *receive = [sockets->_receivers objectForKey:task];
		if (!sockets || !receive)
			return;
		if (message) {
			sockets->_deliver(receive, ^id(JSContext *context) {
				return @{
					@"type": @"message",
					@"data": message.type
							== NSURLSessionWebSocketMessageTypeString
						? message.string
						: SGBytesValue(context, message.data)
				};
			});
			[sockets read:task];
		} else {
			// A read fails as the socket closes, cleanly too:
			BOOL isClosed = task.closeCode
					!= NSURLSessionWebSocketCloseCodeInvalid;
			[sockets closed:task code:task.closeCode
					reason:task.closeReason error:isClosed ? nil : error];
		}
	}];
}

- (void)send:(id)data to:(NSNumber *)number {
	@synchronized (self) {
		NSURLSessionWebSocketMessage *message = [data isKindOfClass:[NSString class]]
				? [[NSURLSessionWebSocketMessage alloc] initWithString:data]
				: [[NSURLSessionWebSocketMessage alloc] initWithData:data];
		[_sockets[number] sendMessage:message completionHandler:^(NSError *error) {
		}];
	}
}

- (void)close:(NSNumber *)number code:(NSInteger)code
		reason:(NSString *)reason {
	@synchronized (self) {
		[_sockets[number] cancelWithCloseCode:code
				reason:[reason dataUsingEncoding:NSUTF8StringEncoding]];
	}
}

// Tells the script once that its socket closed, cleanly or not:
- (void)closed:(NSURLSessionTask *)task code:(NSInteger)code
		reason:(NSData *)reason error:(NSError *)error {
	@synchronized (self) {
		JSValue *receive = [_receivers objectForKey:task];
		if (!receive)
			return;
		[_receivers removeObjectForKey:task];
		for (NSNumber *number in [_sockets allKeysForObject:
				(NSURLSessionWebSocketTask *)task])
			[_sockets removeObjectForKey:number];
		BOOL isClean = code != NSURLSessionWebSocketCloseCodeInvalid && !error;
		if (error) {
			_deliver(receive, SGValue(@{ @"type": @"error",
					@"message": error.localizedDescription }));
		}
		_deliver(receive, SGValue(@{
			@"type": @"close",
			@"code": @(isClean ? code : 1006),
			@"reason": reason ? [[NSString alloc] initWithData:reason
					encoding:NSUTF8StringEncoding] ?: @"" : @"",
			@"wasClean": @(isClean)
		}));
	}
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session
		webSocketTask:(NSURLSessionWebSocketTask *)task
		didOpenWithProtocol:(NSString *)protocol {
	JSValue *receive = [_receivers objectForKey:task];
	if (receive)
		_deliver(receive, SGValue(@{ @"type": @"open",
				@"protocol": protocol ?: @"" }));
}

- (void)URLSession:(NSURLSession *)session
		webSocketTask:(NSURLSessionWebSocketTask *)task
		didCloseWithCode:(NSURLSessionWebSocketCloseCode)code
		reason:(NSData *)reason {
	[self closed:task code:code reason:reason error:nil];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
		didCompleteWithError:(NSError *)error {
	NSURLSessionWebSocketTask *socket = (NSURLSessionWebSocketTask *)task;
	[self closed:task code:error ? NSURLSessionWebSocketCloseCodeInvalid
			: socket.closeCode reason:socket.closeReason error:error];
}

@end
