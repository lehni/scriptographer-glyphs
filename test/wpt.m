// Runs WPT's OffscreenCanvas tests (html/canvas/offscreen, its worker tests)
// in script realms, as VectorCraft's tests/wpt.rs runs them, and lists the
// subtests that fail here but pass in VectorCraft. `make wpt WPT=<corpus>`,
// with an optional FILTER for the test paths.

#import <Cocoa/Cocoa.h>
#import "../src/SGScript.h"
#import "../src/SGRuntime.h"
#import <netinet/in.h>

// Serves the corpus's files on localhost, as VectorCraft's harness does, on a
// thread of its own, and returns its port:
static int serve(NSString *root) {
	int server = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in address = {
		.sin_family = AF_INET,
		.sin_addr.s_addr = htonl(INADDR_LOOPBACK)
	};
	bind(server, (struct sockaddr *)&address, sizeof(address));
	socklen_t length = sizeof(address);
	getsockname(server, (struct sockaddr *)&address, &length);
	listen(server, 16);
	NSDictionary *types = @{ @"png": @"image/png", @"jpg": @"image/jpeg",
			@"gif": @"image/gif", @"svg": @"image/svg+xml",
			@"webp": @"image/webp", @"bmp": @"image/bmp",
			@"ttf": @"font/ttf", @"otf": @"font/otf", @"woff": @"font/woff",
			@"woff2": @"font/woff2", @"js": @"text/javascript",
			@"json": @"application/json" };
	[NSThread detachNewThreadWithBlock:^{
		while (YES) {
			int client = accept(server, NULL, NULL);
			char buffer[8192];
			ssize_t count = read(client, buffer, sizeof(buffer) - 1);
			buffer[MAX(count, 0)] = 0;
			NSArray *words = [@(buffer) componentsSeparatedByString:@" "];
			NSString *path = words.count > 1 ? [[words[1]
					componentsSeparatedByString:@"?"][0]
					stringByRemovingPercentEncoding] : @"";
			NSData *body = [NSData dataWithContentsOfFile:
					[root stringByAppendingPathComponent:path]];
			NSString *head = body
					? [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\n"
						"Content-Type: %@\r\nContent-Length: %lu\r\n"
						"Connection: close\r\n\r\n",
						types[path.pathExtension.lowercaseString]
							?: @"application/octet-stream",
						(unsigned long)body.length]
					: @"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n"
						"Connection: close\r\n\r\n";
			write(client, head.UTF8String, strlen(head.UTF8String));
			if (body)
				write(client, body.bytes, body.length);
			close(client);
		}
	}];
	return ntohs(address.sin_port);
}

int main(int argc, char **argv) {
	@autoreleasepool {
		[NSApplication sharedApplication];
		NSString *root = @(argv[1]);
		NSString *filter = argc > 2 ? @(argv[2]) : @"";
		NSString *expectedFile = argc > 3 ? @(argv[3]) : nil;
		NSString *harness = [[NSString stringWithContentsOfFile:[root
				stringByAppendingPathComponent:@"resources/testharness.js"]
				encoding:NSUTF8StringEncoding error:nil]
				stringByAppendingString:@"\n"];
		NSString *canvasTests = [NSString stringWithContentsOfFile:[root
				stringByAppendingPathComponent:
					@"html/canvas/resources/canvas-tests.js"]
				encoding:NSUTF8StringEncoding error:nil];
		// VectorCraft's expected failures, as `file: subtest` lines:
		NSSet *expected = [NSSet setWithArray:[[NSString
				stringWithContentsOfFile:expectedFile encoding:NSUTF8StringEncoding
				error:nil] componentsSeparatedByString:@"\n"]];
		__block NSString *result = nil;
		[SGRuntime sharedRuntime].printHandler = ^(NSString *line) {
			if ([line hasPrefix:@"WPT:"])
				result = [line substringFromIndex:4];
		};
		int port = serve(root);
		NSString *base = @"html/canvas/offscreen";
		NSDirectoryEnumerator *files = [NSFileManager.defaultManager
				enumeratorAtPath:[root stringByAppendingPathComponent:base]];
		NSMutableArray *paths = [NSMutableArray array];
		for (NSString *path in files) {
			if ([path hasSuffix:@".worker.js"] && ![path hasPrefix:@"manual/"]
					&& (!filter.length || [path containsString:filter]))
				[paths addObject:path];
		}
		[paths sortUsingSelector:@selector(compare:)];
		NSUInteger passed = 0, failed = 0, unexpected = 0;
		for (NSString *path in paths) {
			NSString *file = [[root stringByAppendingPathComponent:base]
					stringByAppendingPathComponent:path];
			NSString *source = [NSString stringWithContentsOfFile:file
					encoding:NSUTF8StringEncoding error:nil];
			// The scripts it imports, inlined:
			source = [source stringByReplacingOccurrencesOfString:
					@"importScripts(\"/resources/testharness.js\");"
					withString:harness];
			source = [source stringByReplacingOccurrencesOfString:
					@"importScripts(\"/html/canvas/resources/canvas-tests.js\");"
					withString:canvasTests];
			NSString *report = @"add_completion_callback(function(tests) {"
				"  print('WPT:' + JSON.stringify(tests.map(function(t) {"
				"    return [t.name, t.status, t.message]"
				"  })))"
				"});\n";
			NSRange start = [source rangeOfString:@"var t = "];
			if (start.location == NSNotFound)
				start = NSMakeRange(source.length, 0);
			source = [source stringByReplacingCharactersInRange:
					NSMakeRange(start.location, 0) withString:report];
			result = nil;
			SGScript *script = [[SGScript alloc] initWithURL:
					[NSURL fileURLWithPath:file]];
			[script setLocation:[NSURL URLWithString:[NSString stringWithFormat:
					@"http://127.0.0.1:%d/%@/%@", port, base, path]]];
			[script evaluate:source];
			for (int i = 0; i < 100 && !result; i++) {
				[NSRunLoop.mainRunLoop runUntilDate:
						[NSDate dateWithTimeIntervalSinceNow:0.02]];
			}
			[script stop];
			NSString *name = [@"html/canvas/offscreen" stringByAppendingPathComponent:
					path];
			NSArray *tests = result ? [NSJSONSerialization JSONObjectWithData:
					[result dataUsingEncoding:NSUTF8StringEncoding] options:0
					error:nil] : @[@[@"(no result)", @1, @"timed out"]];
			for (NSArray *test in tests) {
				NSString *line = [NSString stringWithFormat:@"%@: %@", name,
						test[0]];
				if ([test[1] intValue] == 0) {
					passed++;
				} else {
					failed++;
					if (![expected containsObject:line]) {
						unexpected++;
						printf("FAIL %s — %s\n", line.UTF8String,
								[[test[2] description] UTF8String]);
					}
				}
			}
		}
		printf("wpt: %lu passed, %lu failed, %lu of them pass in VectorCraft\n",
				(unsigned long)passed, (unsigned long)failed,
				(unsigned long)unexpected);
	}
	return 0;
}
