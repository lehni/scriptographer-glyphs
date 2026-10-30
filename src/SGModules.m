//
//  SGModules.m
//  Scriptographer for Glyphs
//

#import "SGModules.h"
#import <CommonCrypto/CommonDigest.h>

// The files that keep a download: its text, and what tells the server which
// one it is, `{ url, etag, modified }`, named for its URL.
static NSArray<NSURL *> *cacheFiles(NSURL *url) {
	const char *string = url.absoluteString.UTF8String;
	unsigned char digest[CC_SHA256_DIGEST_LENGTH];
	CC_SHA256(string, (CC_LONG)strlen(string), digest);
	NSMutableString *name = [NSMutableString string];
	for (int i = 0; i < 12; i++)
		[name appendFormat:@"%02x", digest[i]];
	NSURL *support = [[NSFileManager.defaultManager
			URLsForDirectory:NSApplicationSupportDirectory
			inDomains:NSUserDomainMask] firstObject];
	NSURL *cache = [support URLByAppendingPathComponent:
			@"Scriptographer/Cache" isDirectory:YES];
	return @[
		[cache URLByAppendingPathComponent:[name stringByAppendingString:@".js"]],
		[cache URLByAppendingPathComponent:
				[name stringByAppendingString:@".json"]]
	];
}

static NSString *download(NSURL *url, NSString **reason) {
	NSArray<NSURL *> *files = cacheFiles(url);
	NSData *data = [NSData dataWithContentsOfURL:files[1]];
	NSDictionary *about = data ? [NSJSONSerialization JSONObjectWithData:data
			options:0 error:nil] : nil;
	NSString *kept = [about isKindOfClass:[NSDictionary class]]
			&& [about[@"url"] isEqual:url.absoluteString]
			? [NSString stringWithContentsOfURL:files[0]
				encoding:NSUTF8StringEncoding error:nil] : nil;
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
	request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
	if (kept) {
		if ([about[@"etag"] isKindOfClass:[NSString class]])
			[request setValue:about[@"etag"] forHTTPHeaderField:@"If-None-Match"];
		if ([about[@"modified"] isKindOfClass:[NSString class]]) {
			[request setValue:about[@"modified"]
					forHTTPHeaderField:@"If-Modified-Since"];
		}
	}
	// Scripts wait for their imports, as VectorCraft's do:
	__block NSData *body;
	__block NSHTTPURLResponse *response;
	__block NSError *error;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	[[NSURLSession.sharedSession dataTaskWithRequest:request
			completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
		body = d;
		response = (NSHTTPURLResponse *)r;
		error = e;
		dispatch_semaphore_signal(done);
	}] resume];
	dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
	NSInteger status = response.statusCode;
	if (error || (kept && (status == 304 || status >= 500))) {
		if (!kept)
			*reason = error.localizedDescription;
		return kept;
	}
	if (status < 200 || status > 299) {
		*reason = [NSString stringWithFormat:@"%@ answered %ld",
				url.absoluteString, (long)status];
		return nil;
	}
	NSString *text = [[NSString alloc] initWithData:body
			encoding:NSUTF8StringEncoding] ?: [[NSString alloc]
				initWithData:body encoding:NSISOLatin1StringEncoding];
	NSDictionary *headers = response.allHeaderFields;
	NSMutableDictionary *keep = [@{ @"url": url.absoluteString } mutableCopy];
	for (NSString *name in headers) {
		NSString *lower = name.lowercaseString;
		if ([lower isEqual:@"etag"])
			keep[@"etag"] = headers[name];
		else if ([lower isEqual:@"last-modified"])
			keep[@"modified"] = headers[name];
	}
	// A copy that can't be kept only costs the next download:
	[NSFileManager.defaultManager createDirectoryAtURL:
			files[0].URLByDeletingLastPathComponent
			withIntermediateDirectories:YES attributes:nil error:nil];
	[text writeToURL:files[0] atomically:YES encoding:NSUTF8StringEncoding
			error:nil];
	[[NSJSONSerialization dataWithJSONObject:keep options:0 error:nil]
			writeToURL:files[1] atomically:YES];
	return text;
}

NSString *SGReadModule(NSURL *url, NSString **reason) {
	if (url.isFileURL) {
		NSError *error;
		NSString *text = [NSString stringWithContentsOfURL:url
				encoding:NSUTF8StringEncoding error:&error];
		if (!text)
			*reason = error.localizedDescription;
		return text;
	}
	NSString *scheme = url.scheme.lowercaseString;
	if ([scheme isEqual:@"http"] || [scheme isEqual:@"https"])
		return download(url, reason);
	*reason = [NSString stringWithFormat:@"'%@:' modules can't be loaded",
			scheme];
	return nil;
}
