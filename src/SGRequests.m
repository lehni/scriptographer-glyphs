//
//  SGRequests.m
//  Scriptographer for Glyphs
//

#import "SGRequests.h"

@interface SGRequests () <NSURLSessionDataDelegate>
@end

@implementation SGRequests {
	SGDeliver _deliver;
	NSURLSession *_session;
	// The requests by their number, with what receives their responses:
	NSMutableDictionary<NSNumber *, NSURLSessionDataTask *> *_requests;
	NSMapTable<NSURLSessionTask *, JSValue *> *_receivers;
	NSMutableSet<NSURLSessionTask *> *_followsRedirects;
	NSUInteger _nextRequest;
}

- (instancetype)initWithDeliver:(SGDeliver)deliver {
	self = [super init];
	if (self) {
		_deliver = deliver;
		_requests = [NSMutableDictionary dictionary];
		_receivers = [NSMapTable strongToStrongObjectsMapTable];
		_followsRedirects = [NSMutableSet set];
		_nextRequest = 1;
	}
	return self;
}

- (NSDictionary *)natives {
	__weak SGRequests *weakSelf = self;
	return @{
		@"request": ^NSNumber *(NSString *method, NSString *url,
				NSArray *headers, JSValue *body, BOOL follow,
				JSValue *receive) {
			return [weakSelf request:method url:url headers:headers
					body:body.isObject ? SGDataOfValue(body) : nil
					follow:follow receive:receive];
		},
		@"cancel": ^(NSNumber *number) {
			[weakSelf cancel:number];
		}
	};
}

- (BOOL)isBusy {
	return _requests.count > 0;
}

- (void)stop {
	@synchronized (self) {
		[_session invalidateAndCancel];
		_session = nil;
		[_requests removeAllObjects];
		[_receivers removeAllObjects];
		[_followsRedirects removeAllObjects];
	}
}

// What the server answers goes to `receive()`: the response's head, then its
// body a part at a time as Uint8Arrays, and null at its end; or why it
// failed, as a string.
- (NSNumber *)request:(NSString *)method url:(NSString *)url
		headers:(NSArray<NSArray<NSString *> *> *)headers body:(NSData *)body
		follow:(BOOL)follow receive:(JSValue *)receive {
	@synchronized (self) {
		NSURL *target = [NSURL URLWithString:url];
		NSNumber *number = @(_nextRequest++);
		if (!target) {
			_deliver(receive, SGValue([NSString stringWithFormat:
					@"Invalid URL: '%@'.", url]));
			return number;
		}
		if (!_session) {
			_session = [NSURLSession sessionWithConfiguration:
					NSURLSessionConfiguration.ephemeralSessionConfiguration
					delegate:self delegateQueue:NSOperationQueue.mainQueue];
		}
		NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:target];
		request.HTTPMethod = method;
		request.timeoutInterval = 300;
		for (NSArray *header in headers)
			[request addValue:header[1] forHTTPHeaderField:header[0]];
		if (body.length)
			request.HTTPBody = body;
		NSURLSessionDataTask *task = [_session dataTaskWithRequest:request];
		_requests[number] = task;
		[_receivers setObject:receive forKey:task];
		if (follow)
			[_followsRedirects addObject:task];
		[task resume];
		return number;
	}
}

// Also once the response is in, which has ended its request already:
- (void)cancel:(NSNumber *)number {
	@synchronized (self) {
		NSURLSessionDataTask *task = _requests[number];
		if (!task)
			return;
		[_requests removeObjectForKey:number];
		[_receivers removeObjectForKey:task];
		[_followsRedirects removeObject:task];
		[task cancel];
	}
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
		willPerformHTTPRedirection:(NSHTTPURLResponse *)response
		newRequest:(NSURLRequest *)request
		completionHandler:(void (^)(NSURLRequest *))completionHandler {
	@synchronized (self) {
		completionHandler([_followsRedirects containsObject:task] ? request : nil);
	}
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
		didReceiveResponse:(NSURLResponse *)response
		completionHandler:(void (^)(NSURLSessionResponseDisposition))
			completionHandler {
	@synchronized (self) {
		JSValue *receive = [_receivers objectForKey:task];
		NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
				? (NSHTTPURLResponse *)response : nil;
		NSMutableArray *headers = [NSMutableArray array];
		[http.allHeaderFields enumerateKeysAndObjectsUsingBlock:
				^(NSString *name, NSString *value, BOOL *stop) {
			[headers addObject:@[name.lowercaseString, value]];
		}];
		NSInteger status = http ? http.statusCode : 200;
		if (receive) {
			_deliver(receive, SGValue(@{
				@"status": @(status),
				@"statusText": [NSHTTPURLResponse
						localizedStringForStatusCode:status].capitalizedString,
				@"url": response.URL.absoluteString ?: @"",
				@"redirected": @(![response.URL
						isEqual:task.originalRequest.URL]),
				@"headers": headers
			}));
		}
		completionHandler(NSURLSessionResponseAllow);
	}
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
		didReceiveData:(NSData *)data {
	@synchronized (self) {
		JSValue *receive = [_receivers objectForKey:task];
		if (receive)
			_deliver(receive, ^id(JSContext *context) {
				return SGBytesValue(context, data);
			});
	}
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
		didCompleteWithError:(NSError *)error {
	@synchronized (self) {
		JSValue *receive = [_receivers objectForKey:task];
		for (NSNumber *number in [_requests allKeysForObject:
				(NSURLSessionDataTask *)task])
			[_requests removeObjectForKey:number];
		[_receivers removeObjectForKey:task];
		[_followsRedirects removeObject:task];
		if (receive && error.code != NSURLErrorCancelled)
			_deliver(receive, SGValue(error ? error.localizedDescription
					: [NSNull null]));
	}
}

@end
