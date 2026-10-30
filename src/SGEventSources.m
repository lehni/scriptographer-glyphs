//
//  SGEventSources.m
//  Scriptographer for Glyphs
//

#import "SGEventSources.h"

// How long a connection waits before it connects again, unless the server
// says otherwise, in milliseconds, and the most of an event kept while it's
// read, in bytes, as in VectorCraft:
static const NSUInteger reconnectionTime = 3000;
static const NSUInteger most = 16 * 1024 * 1024;

// A connection, and what it keeps of its stream across reconnections and of
// the event it's reading.
@interface SGEventStream : NSObject
@property (nonatomic, copy) NSString *url;
@property (nonatomic, strong) JSValue *receive;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *task;
@property (nonatomic, strong, nullable) NSTimer *timer;
@property (nonatomic) NSUInteger reconnectionTime;
@property (nonatomic, copy) NSString *lastEventId;
@property (nonatomic, copy) NSString *type, *data, *eventId;
@property (nonatomic, strong) NSMutableData *line;
@property (nonatomic) BOOL isAfterCR, hasStarted;
@end

@implementation SGEventStream
@end

@interface SGEventSources () <NSURLSessionDataDelegate>
@end

@implementation SGEventSources {
	SGDeliver _deliver;
	NSURLSession *_session;
	NSMutableDictionary<NSNumber *, SGEventStream *> *_streams;
	NSUInteger _nextStream;
}

- (instancetype)initWithDeliver:(SGDeliver)deliver {
	self = [super init];
	if (self) {
		_deliver = deliver;
		_streams = [NSMutableDictionary dictionary];
		_nextStream = 1;
	}
	return self;
}

- (NSDictionary *)natives {
	__weak SGEventSources *weakSelf = self;
	return @{
		@"open": ^NSNumber *(NSString *url, JSValue *receive) {
			return [weakSelf open:url receive:receive];
		},
		@"close": ^(NSNumber *number) {
			[weakSelf close:number];
		}
	};
}

- (BOOL)isBusy {
	return _streams.count > 0;
}

- (void)stop {
	@synchronized (self) {
		for (NSNumber *number in _streams.allKeys)
			[self close:number];
		[_session invalidateAndCancel];
		_session = nil;
	}
}

- (NSNumber *)open:(NSString *)url receive:(JSValue *)receive {
	@synchronized (self) {
		NSNumber *number = @(_nextStream++);
		SGEventStream *stream = [[SGEventStream alloc] init];
		stream.url = url;
		stream.receive = receive;
		stream.reconnectionTime = reconnectionTime;
		stream.lastEventId = @"";
		_streams[number] = stream;
		[self connect:stream];
		return number;
	}
}

- (void)close:(NSNumber *)number {
	@synchronized (self) {
		SGEventStream *stream = _streams[number];
		[_streams removeObjectForKey:number];
		[stream.timer invalidate];
		[stream.task cancel];
	}
}

- (void)connect:(SGEventStream *)stream {
	@synchronized (self) {
		if (![stream.url hasPrefix:@"http://"] && ![stream.url hasPrefix:@"https://"]) {
			[self fail:stream reason:[NSString stringWithFormat:
					@"only http: and https: URLs, not '%@'", stream.url]];
			return;
		}
		if (!_session) {
			_session = [NSURLSession sessionWithConfiguration:
					NSURLSessionConfiguration.ephemeralSessionConfiguration
					delegate:self delegateQueue:NSOperationQueue.mainQueue];
		}
		NSMutableURLRequest *request = [NSMutableURLRequest
				requestWithURL:[NSURL URLWithString:stream.url]];
		[request setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
		[request setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
		if (stream.lastEventId.length) {
			[request setValue:stream.lastEventId
					forHTTPHeaderField:@"Last-Event-ID"];
		}
		request.timeoutInterval = 24 * 60 * 60;
		// A new stream starts with a new line and event:
		stream.line = [NSMutableData data];
		stream.isAfterCR = stream.hasStarted = NO;
		stream.type = stream.data = stream.eventId = @"";
		stream.task = [_session dataTaskWithRequest:request];
		[stream.task resume];
	}
}

- (SGEventStream *)streamOf:(NSURLSessionTask *)task {
	for (SGEventStream *stream in _streams.allValues) {
		if (stream.task == task)
			return stream;
	}
	return nil;
}

- (void)fail:(SGEventStream *)stream reason:(NSString *)reason {
	for (NSNumber *number in [_streams allKeysForObject:stream])
		[_streams removeObjectForKey:number];
	[stream.task cancel];
	stream.task = nil;
	_deliver(stream.receive, SGValue(@{ @"state": @"failed",
			@"reason": reason }));
}

#pragma mark - Parsing

- (void)read:(NSData *)data of:(SGEventStream *)stream {
	const uint8_t *bytes = data.bytes;
	NSUInteger count = data.length, start = 0;
	// A byte order mark at its start is no part of the stream:
	if (!stream.hasStarted) {
		stream.hasStarted = YES;
		if (count >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb
				&& bytes[2] == 0xbf)
			start = 3;
	}
	for (NSUInteger i = start; i < count; i++) {
		uint8_t byte = bytes[i];
		BOOL isAfterCR = stream.isAfterCR;
		stream.isAfterCR = byte == '\r';
		if (byte == '\n' && isAfterCR)
			continue;
		if (byte == '\r' || byte == '\n') {
			NSString *line = [[NSString alloc] initWithData:stream.line
					encoding:NSUTF8StringEncoding] ?: @"";
			stream.line = [NSMutableData data];
			[self readLine:line of:stream];
			if (!_streams.count || ![_streams allKeysForObject:stream].count)
				return;
		} else {
			[stream.line appendBytes:&byte length:1];
		}
		if (stream.line.length + stream.data.length > most) {
			[self fail:stream reason:@"an event is too long"];
			return;
		}
	}
}

- (void)readLine:(NSString *)line of:(SGEventStream *)stream {
	if (!line.length) {
		[self dispatch:stream];
		return;
	}
	if ([line hasPrefix:@":"])
		return;
	NSRange colon = [line rangeOfString:@":"];
	NSString *field = colon.location == NSNotFound ? line
			: [line substringToIndex:colon.location];
	NSString *value = colon.location == NSNotFound ? @""
			: [line substringFromIndex:colon.location + 1];
	if ([value hasPrefix:@" "])
		value = [value substringFromIndex:1];
	if ([field isEqualToString:@"event"]) {
		stream.type = value;
	} else if ([field isEqualToString:@"data"]) {
		stream.data = [NSString stringWithFormat:@"%@%@\n", stream.data, value];
	} else if ([field isEqualToString:@"id"]
			&& [value rangeOfString:@"\0"].location == NSNotFound) {
		stream.eventId = value;
	} else if ([field isEqualToString:@"retry"] && value.length
			&& [value rangeOfCharacterFromSet:NSCharacterSet
				.decimalDigitCharacterSet.invertedSet].location == NSNotFound) {
		stream.reconnectionTime = (NSUInteger)value.longLongValue;
	}
}

// The event read, at an empty line: none without data.
- (void)dispatch:(SGEventStream *)stream {
	stream.lastEventId = stream.eventId;
	NSString *type = stream.type, *data = stream.data;
	stream.type = stream.data = @"";
	if (!data.length)
		return;
	_deliver(stream.receive, SGValue(@{
		@"state": @"event",
		@"type": type.length ? type : @"message",
		@"data": [data substringToIndex:data.length - 1],
		@"lastEventId": stream.lastEventId
	}));
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
		didReceiveResponse:(NSURLResponse *)response
		completionHandler:(void (^)(NSURLSessionResponseDisposition))
			completionHandler {
	@synchronized (self) {
		SGEventStream *stream = [self streamOf:task];
		NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
		NSString *type = [[http.allHeaderFields[@"Content-Type"] ?: @""
				componentsSeparatedByString:@";"][0]
				stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		if (!stream) {
			completionHandler(NSURLSessionResponseCancel);
		} else if (http.statusCode != 200) {
			completionHandler(NSURLSessionResponseCancel);
			[self fail:stream reason:[NSString stringWithFormat:
					@"the server answered %ld", (long)http.statusCode]];
		} else if (![type isEqualToString:@"text/event-stream"]) {
			completionHandler(NSURLSessionResponseCancel);
			[self fail:stream reason:[NSString stringWithFormat:
					@"not an event stream, but '%@'", type]];
		} else {
			completionHandler(NSURLSessionResponseAllow);
			_deliver(stream.receive, SGValue(@{ @"state": @"open",
					@"url": response.URL.absoluteString ?: stream.url }));
		}
	}
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
		didReceiveData:(NSData *)data {
	@synchronized (self) {
		SGEventStream *stream = [self streamOf:task];
		if (stream)
			[self read:data of:stream];
	}
}

// The stream ended or broke: it connects again after the reconnection time.
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
		didCompleteWithError:(NSError *)error {
	@synchronized (self) {
		SGEventStream *stream = [self streamOf:task];
		if (!stream || error.code == NSURLErrorCancelled)
			return;
		stream.task = nil;
		_deliver(stream.receive, SGValue(@{ @"state": @"reconnecting" }));
		__weak SGEventSources *weakSelf = self;
		stream.timer = [NSTimer scheduledTimerWithTimeInterval:
				stream.reconnectionTime / 1000.0 repeats:NO
				block:^(NSTimer *timer) {
			SGEventSources *sources = weakSelf;
			if (sources && [sources->_streams allKeysForObject:stream].count)
				[sources connect:stream];
		}];
	}
}

@end
