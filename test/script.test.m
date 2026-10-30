// Tests SGScript outside Glyphs: a script's realm with the bundle, and the
// natives the plugin gives it. Run by `make test` with HOME in build/, so its
// storage stays there.

#import <Cocoa/Cocoa.h>
#import "../src/SGScript.h"
#import "../src/SGRuntime.h"
#import <netinet/in.h>
#import <CommonCrypto/CommonDigest.h>

// Serves one HTTP response on localhost, on a thread of its own, and returns
// its port:
static int serve(NSString *response) {
	int server = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in address = {
		.sin_family = AF_INET,
		.sin_addr.s_addr = htonl(INADDR_LOOPBACK)
	};
	bind(server, (struct sockaddr *)&address, sizeof(address));
	socklen_t length = sizeof(address);
	getsockname(server, (struct sockaddr *)&address, &length);
	listen(server, 1);
	NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];
	[NSThread detachNewThreadWithBlock:^{
		int client = accept(server, NULL, NULL);
		char buffer[4096];
		read(client, buffer, sizeof(buffer));
		write(client, data.bytes, data.length);
		close(client);
		close(server);
	}];
	return ntohs(address.sin_port);
}

// A WebSocket server on localhost for one client: it answers the handshake,
// echoes the first message and closes with 1000. Returns its port.
static int serveSocket(void) {
	int server = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in address = {
		.sin_family = AF_INET,
		.sin_addr.s_addr = htonl(INADDR_LOOPBACK)
	};
	bind(server, (struct sockaddr *)&address, sizeof(address));
	socklen_t length = sizeof(address);
	getsockname(server, (struct sockaddr *)&address, &length);
	listen(server, 1);
	[NSThread detachNewThreadWithBlock:^{
		int client = accept(server, NULL, NULL);
		char buffer[4096];
		ssize_t count = read(client, buffer, sizeof(buffer) - 1);
		buffer[MAX(count, 0)] = 0;
		NSString *request = @(buffer);
		NSRange start = [request rangeOfString:@"Sec-WebSocket-Key: "
				options:NSCaseInsensitiveSearch];
		NSString *key = [[request substringFromIndex:NSMaxRange(start)]
				componentsSeparatedByString:@"\r\n"][0];
		NSData *accept = [[key stringByAppendingString:
				@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"]
				dataUsingEncoding:NSUTF8StringEncoding];
		unsigned char digest[CC_SHA1_DIGEST_LENGTH];
		CC_SHA1(accept.bytes, (CC_LONG)accept.length, digest);
		NSString *response = [NSString stringWithFormat:
				@"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
				"Connection: Upgrade\r\nSec-WebSocket-Accept: %@\r\n\r\n",
				[[NSData dataWithBytes:digest length:sizeof(digest)]
					base64EncodedStringWithOptions:0]];
		write(client, response.UTF8String, strlen(response.UTF8String));
		// The client's first frame, short and masked, echoed unmasked:
		uint8_t frame[256];
		count = read(client, frame, sizeof(frame));
		size_t size = frame[1] & 0x7f;
		uint8_t echo[256] = { 0x81, (uint8_t)size };
		for (size_t i = 0; i < size; i++)
			echo[2 + i] = frame[6 + i] ^ frame[2 + i % 4];
		write(client, echo, 2 + size);
		uint8_t close_[] = { 0x88, 2, 0x03, 0xe8 };
		write(client, close_, sizeof(close_));
		read(client, frame, sizeof(frame));
		close(client);
		close(server);
	}];
	return ntohs(address.sin_port);
}

static void runLoop(NSTimeInterval seconds) {
	[NSRunLoop.mainRunLoop runUntilDate:
			[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static int failures = 0;

#define CHECK(condition) do { \
	if (!(condition)) { \
		fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #condition); \
		failures++; \
	} \
} while (0)

int main(void) {
	@autoreleasepool {
		[NSApplication sharedApplication];
		NSMutableArray<NSString *> *output = [NSMutableArray array];
		[SGRuntime sharedRuntime].printHandler = ^(NSString *line) {
			[output addObject:line];
		};
		NSString *folder = [NSTemporaryDirectory()
				stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
		[NSFileManager.defaultManager createDirectoryAtPath:folder
				withIntermediateDirectories:YES attributes:nil error:nil];
		NSURL *url = [NSURL fileURLWithPath:
				[folder stringByAppendingPathComponent:@"test.js"]];

		// The web's APIs over the natives:
		SGScript *script = [[SGScript alloc] initWithURL:url];
		[script execute:@
			"print(new TextDecoder().decode(new TextEncoder().encode('é')));"
			"print(new TextDecoder().decode(new Uint8Array([0xff, 0x41])));"
			"print(crypto.getRandomValues(new Uint8Array(4)).length);"
			"print(performance.now() >= 0);"
			"localStorage.setItem('a', '1');"
			"sessionStorage.setItem('b', '2');"
			"var canvas = new OffscreenCanvas(4, 4), ctx = canvas.getContext('2d');"
			"ctx.fillStyle = 'rgb(255 0 0 / 50%)'; ctx.fillRect(1, 1, 2, 2);"
			"print(ctx.fillStyle, ctx.getImageData(1, 1, 1, 1).data.join());"];
		CHECK([output isEqualToArray:(@[
			@"é", @"�A", @"4", @"true",
			@"rgba(255, 0, 0, 0.5) 255,0,0,128"
		])]);
		[output removeAllObjects];

		// Controls other than spaces take the width of the font's .notdef,
		// and draw nothing:
		[script execute:@
			"var ctx = new OffscreenCanvas(100, 100).getContext('2d');"
			"ctx.font = '50px sans-serif';"
			"ctx.fillText('\\x0b', 20, 70);"
			"print(ctx.measureText('\\x0b').width > 0,"
			"  ctx.getImageData(0, 0, 100, 100).data.some(v => v))"];
		CHECK([output isEqualToArray:(@[@"true false"])]);
		[output removeAllObjects];

		// Clusters where the direction changes are where their glyphs are:
		// in right-to-left text, the leading '-' is at the right, the digits
		// left to right in the middle:
		[script execute:@
			"var ctx = new OffscreenCanvas(100, 100).getContext('2d');"
			"ctx.font = '50px sans-serif';"
			"ctx.direction = 'rtl'; ctx.textAlign = 'center';"
			"var metrics = ctx.measureText('-0123456789-'),"
			"  dash = metrics.getSelectionRects(0, 1)[0],"
			"  nine = metrics.getSelectionRects(10, 11)[0];"
			"print(dash.x + dash.width === metrics.width / 2,"
			"  nine.x + nine.width <= dash.x, metrics.getIndexFromOffset(0))"];
		CHECK([output isEqualToArray:(@[@"true true 6"])]);
		[output removeAllObjects];

		// Files, relative to the script's folder, through LocalFile:
		[script execute:@
			"var file = new LocalFile('notes.txt');"
			"file.write('héllo').then(function() {"
			"  return file.append('!')"
			"}).then(function() {"
			"  return file.text()"
			"}).then(function(text) {"
			"  print(text, file.size, file.parent.name);"
			"  return new LocalFile('missing.txt').text()"
			"}).catch(function(e) {"
			"  print(e.name)"
			"})"];
		CHECK([output isEqualToArray:(@[
			[NSString stringWithFormat:@"héllo! 7 %@",
					folder.lastPathComponent],
			@"NotFoundError"
		])]);
		CHECK([[NSString stringWithContentsOfFile:[folder
				stringByAppendingPathComponent:@"notes.txt"]
				encoding:NSUTF8StringEncoding error:nil]
				isEqualToString:@"héllo!"]);
		[output removeAllObjects];

		// Without a tool, timers or palettes, a script stops once its work is
		// done, the view's update included; with a palette it keeps running:
		runLoop(0.1);
		CHECK(![script isRunning]);
		script = [[SGScript alloc] initWithURL:url];
		[script execute:@"new Palette('Test', { a: { value: 1 } })"];
		CHECK([script isRunning]);
		[script stop];
		CHECK(![script isRunning]);

		// structuredClone() keeps cycles, shared objects and classes, and
		// can't keep functions:
		script = [[SGScript alloc] initWithURL:url];
		[script execute:@
			"var a = { n: 1 }; a.self = a;"
			"var clone = structuredClone({ a: a, b: a, d: new Date(5),"
			"  m: new Map([[1, 'x']]), s: new Set([2]), r: /x/g,"
			"  u: new Uint8Array([1, 2]).subarray(1), e: new RangeError('no'),"
			"  blob: new Blob(['hi'], { type: 'text/plain' }) });"
			"print(clone.a === clone.b, clone.a.self === clone.a, clone !== a,"
			"  clone.d.getTime(), clone.m.get(1), clone.s.has(2), clone.r.flags,"
			"  clone.u[0], clone.u.byteOffset, clone.e instanceof RangeError,"
			"  clone.e.message, clone.blob.type, clone.blob.size);"
			"try { structuredClone(print) } catch (e) { print(e.name) }"];
		CHECK([output isEqualToArray:(@[
			@"true true true 5 x true g 2 1 true no text/plain 2",
			@"DataCloneError"
		])]);
		[output removeAllObjects];
		[script stop];

		// Compression round trips, and fails on what isn't compressed:
		script = [[SGScript alloc] initWithURL:url];
		[script execute:@
			"function pipe(bytes, stream) {"
			"  return new Response(new Blob([bytes]).stream()"
			"      .pipeThrough(stream)).arrayBuffer()"
			"}"
			"['gzip', 'deflate', 'deflate-raw', 'brotli'].forEach(function(f) {"
			"  var text = 'hello hello hello hello';"
			"  pipe(new TextEncoder().encode(text), new CompressionStream(f))"
			"  .then(function(packed) {"
			"    return pipe(new Uint8Array(packed), new DecompressionStream(f))"
			"  }).then(function(bytes) {"
			"    print(f, new TextDecoder().decode(bytes) === text)"
			"  })"
			"});"
			"pipe(new Uint8Array([1, 2, 3]), new DecompressionStream('gzip'))"
			"  .catch(function(e) { print(e.name) })"];
		runLoop(0.1);
		CHECK(([[NSSet setWithArray:output] isEqualToSet:[NSSet setWithArray:@[
			@"gzip true", @"deflate true", @"deflate-raw true",
			@"brotli true", @"TypeError"
		]]]));
		[output removeAllObjects];
		[script stop];

		// fetch() keeps the script running until its response is in:
		int port = serve(@"HTTP/1.1 201 Created\r\nContent-Type: text/plain"
				"\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello");
		script = [[SGScript alloc] initWithURL:url];
		[script execute:[NSString stringWithFormat:@
			"fetch('http://127.0.0.1:%d/a').then(function(response) {"
			"  print(response.status, response.headers.get('content-type'));"
			"  return response.text()"
			"}).then(print, function(e) { print(e) })", port]];
		CHECK([script isRunning]);
		for (int i = 0; i < 50 && output.count < 2; i++)
			runLoop(0.1);
		CHECK([output isEqualToArray:(@[@"201 text/plain", @"hello"])]);
		[output removeAllObjects];
		[script stop];

		// An EventSource reads its stream's events, and keeps the script
		// running until it's closed:
		port = serve(@"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream"
				"\r\nConnection: close\r\n\r\n\xEF\xBB\xBFretry: 60000\r\n"
				": a comment\r\ndata: a\r\ndata: b\r\n\r\n"
				"event: ping\nid: 7\ndata:c\n\n");
		script = [[SGScript alloc] initWithURL:url];
		[script execute:[NSString stringWithFormat:@
			"var source = new EventSource('http://127.0.0.1:%d/');"
			"source.onopen = function() { print('open') };"
			"source.onmessage = function(event) { print(event.data) };"
			"source.addEventListener('ping', function(event) {"
			"  print('ping', event.data, event.lastEventId);"
			"  source.close()"
			"})", port]];
		for (int i = 0; i < 50 && output.count < 3; i++)
			runLoop(0.1);
		CHECK([output isEqualToArray:(@[@"open", @"a\nb", @"ping c 7"])]);
		CHECK(![script isRunning]);
		[output removeAllObjects];
		[script stop];

		// A WebSocket opens, echoes and closes, and keeps the script running
		// while it's open:
		script = [[SGScript alloc] initWithURL:url];
		[script execute:[NSString stringWithFormat:@
			"var socket = new WebSocket('ws://127.0.0.1:%d/');"
			"socket.onopen = function() { print('open'); socket.send('hi') };"
			"socket.onmessage = function(event) { print(event.data) };"
			"socket.onclose = function(event) {"
			"  print('close', event.code, event.wasClean)"
			"}", serveSocket()]];
		CHECK([script isRunning]);
		for (int i = 0; i < 50 && output.count < 3; i++)
			runLoop(0.1);
		CHECK([output isEqualToArray:(@[@"open", @"hi", @"close 1000 true"])]);
		CHECK(![script isRunning]);
		[output removeAllObjects];
		[script stop];

		// Scripts talk through BroadcastChannel, and wait for each other's
		// locks:
		SGScript *first = [[SGScript alloc] initWithURL:url];
		SGScript *second = [[SGScript alloc] initWithURL:url];
		[first execute:@
			"new BroadcastChannel('c').onmessage = function(event) {"
			"  print('got', event.data.list[1], event.data.map.get('k'))"
			"};"
			"navigator.locks.request('l', function() {"
			"  return new Promise(function(resolve) { self.done = resolve })"
			"})"];
		[second execute:@
			"new BroadcastChannel('c').postMessage({"
			"  list: [1, 2], map: new Map([['k', 'v']])"
			"});"
			"navigator.locks.request('l', function(lock) {"
			"  print('locked', lock.name, lock.mode)"
			"})"];
		runLoop(0.1);
		CHECK([output isEqualToArray:(@[@"got 2 v"])]);
		CHECK([second isRunning]);
		[first execute:@"self.done()"];
		runLoop(0.1);
		CHECK([output isEqualToArray:(@[@"got 2 v", @"locked l exclusive"])]);
		[output removeAllObjects];
		[first stop];
		[second stop];

		// Ports carry messages, and other ports, which answer back:
		script = [[SGScript alloc] initWithURL:url];
		[script execute:@
			"var c = new MessageChannel(), d = new MessageChannel();"
			"c.port1.onmessage = function(event) {"
			"  print('got', event.data.a, event.ports.length);"
			"  event.ports[0].postMessage('back')"
			"};"
			"d.port1.onmessage = function(event) {"
			"  print(event.data); c.port1.close(); d.port1.close()"
			"};"
			"c.port2.postMessage({ a: 1 }, [d.port2])"];
		CHECK([script isRunning]);
		for (int i = 0; i < 20 && output.count < 2; i++)
			runLoop(0.05);
		CHECK([output isEqualToArray:(@[@"got 1 1", @"back"])]);
		CHECK(![script isRunning]);
		[output removeAllObjects];
		[script stop];

		// Workers answer messages on their threads, and keep the script
		// running until they're terminated; their errors reach the Worker:
		[@"onmessage = function(event) { postMessage(event.data * 2) }"
				writeToFile:[folder stringByAppendingPathComponent:@"double.js"]
				atomically:YES encoding:NSUTF8StringEncoding error:nil];
		[@"onconnect = function(event) {"
				"  event.ports[0].postMessage('hello ' + self.name)"
				"}"
				writeToFile:[folder stringByAppendingPathComponent:@"greet.js"]
				atomically:YES encoding:NSUTF8StringEncoding error:nil];
		[@"throw new Error('broken')"
				writeToFile:[folder stringByAppendingPathComponent:@"broken.js"]
				atomically:YES encoding:NSUTF8StringEncoding error:nil];
		script = [[SGScript alloc] initWithURL:url];
		[script execute:@
			"var worker = new Worker('double.js');"
			"worker.onmessage = function(event) {"
			"  print('doubled', event.data); worker.terminate()"
			"};"
			"worker.postMessage(21);"
			"new SharedWorker('greet.js', 'all').port.onmessage = function(e) {"
			"  print(e.data)"
			"};"
			"new Worker('broken.js').onerror = function(event) {"
			"  print('error', event.message); event.preventDefault()"
			"}"];
		for (int i = 0; i < 50 && output.count < 3; i++)
			runLoop(0.1);
		CHECK(([[NSSet setWithArray:output] isEqualToSet:[NSSet setWithArray:@[
			@"doubled 42", @"hello all", @"error Error: broken"
		]]]));
		[output removeAllObjects];
		[script stop];

		// The lifecycle: preferences come back, as Paper.js objects; a script
		// that keeps alive goes on when another runs, others hear `onStop`:
		SGRuntime *runtime = [SGRuntime sharedRuntime];
		NSString *(^file)(NSString *, NSString *) = ^NSString *(NSString *name,
				NSString *source) {
			NSString *path = [folder stringByAppendingPathComponent:name];
			[source writeToFile:path atomically:YES encoding:NSUTF8StringEncoding
					error:nil];
			return path;
		};
		NSURL *kept = [NSURL fileURLWithPath:file(@"kept.js",
				@"script.keepAlive = true; setInterval(function() {}, 1000);"
				"function onStop() { print('kept stops') }")];
		NSURL *other = [NSURL fileURLWithPath:file(@"other.js",
				@"setInterval(function() {}, 1000);"
				"function onStop() { print('other stops') }")];
		NSURL *remember = [NSURL fileURLWithPath:file(@"remember.js",
				@"print(script.file.name, script.preferences.point);"
				"script.preferences.point = new Point(3, 4)")];
		[runtime runScriptAtURL:kept];
		[runtime runScriptAtURL:other];
		[runtime runScriptAtURL:remember];
		[runtime runScriptAtURL:remember];
		CHECK([output isEqualToArray:(@[@"other stops", @"remember.js undefined",
				@"remember.js { x: 3, y: 4 }"])]);
		CHECK([runtime isScriptRunningAtURL:kept]);
		CHECK(![runtime isScriptRunningAtURL:other]);
		[output removeAllObjects];
		[runtime stopAllScripts];
		CHECK([output isEqualToArray:(@[@"kept stops"])]);
		[output removeAllObjects];

		// Imports: PaperScript from .pjs files, JavaScript from others, each
		// once; cycles and missing modules throw:
		file(@"shapes.pjs", @"export var moved = new Point(1, 2) + 3");
		file(@"count.js", @"export var count = (globalThis.runs = "
				"(globalThis.runs || 0) + 1)");
		file(@"sum.js", @"export var sum = new Point(1, 2) + 3");
		file(@"a.js", @"import { b } from './b.js'; export var a = 1");
		file(@"b.js", @"import { a } from './a.js'; export var b = 2");
		[runtime runScriptAtURL:[NSURL fileURLWithPath:file(@"imports.js",
				@"import { moved } from './shapes.pjs';"
				"import { count } from './count.js';"
				"import { count as again } from './count.js';"
				"import { sum } from './sum.js';"
				"print(moved, count, again, sum);"
				"import('./a.js').catch(e => print(e.message));"
				"import('./missing.js').catch(e => print(e.message))")]];
		runLoop(0.1);
		CHECK(([output isEqualToArray:@[
			@"{ x: 4, y: 5 } 1 1 { x: 1, y: 2 }3",
			@"import './a.js': it imports itself, through its imports",
			@"import './missing.js': The file “missing.js” couldn’t be opened "
				"because there is no such file.",
			@"imports stopped"
		]]));
		[output removeAllObjects];

		// Modules from the web are kept, and come from there when the server
		// can't be reached:
		int webPort = serve(@"HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\n"
				"ETag: \"1\"\r\nContent-Length: 20\r\n\r\nexport var web = 'w'");
		NSString *web = [NSString stringWithFormat:@"import { web } from "
				"'http://localhost:%d/web.js'; print(web)", webPort];
		[runtime runScriptAtURL:[NSURL fileURLWithPath:file(@"web.js", web)]];
		[runtime runScriptAtURL:[NSURL fileURLWithPath:file(@"web.js", web)]];
		NSString *imported = [NSString stringWithFormat:
				@"import http://localhost:%d/web.js", webPort];
		CHECK(([output isEqualToArray:@[imported, @"w", imported, @"w"]]));
		[output removeAllObjects];

		// A script that runs on says when it stops on its own, one that's
		// done at once doesn't:
		[runtime runScriptAtURL:[NSURL fileURLWithPath:file(@"brief.js",
				@"setTimeout(function() { print('done') }, 10)")]];
		runLoop(0.1);
		CHECK([output isEqualToArray:(@[@"done", @"brief stopped"])]);
		[output removeAllObjects];

		// A script that hangs is asked about once it worked too long, and
		// stops when it should:
		__block NSUInteger asked = 0;
		runtime.responseTime = 0.2;
		runtime.stopHandler = ^BOOL(SGScript *hanging) {
			return ++asked == 2;
		};
		NSURL *hang = [NSURL fileURLWithPath:file(@"hang.js",
				@"setInterval(function() {}, 1000); while (true) {}")];
		[runtime runScriptAtURL:hang];
		runLoop(0.1);
		CHECK(asked == 2);
		CHECK(![runtime isScriptRunningAtURL:hang]);
		runtime.stopHandler = nil;
		runtime.responseTime = 5;

		// Errors show where they are in the script, not the runtime's frames:
		NSURL *broken = [NSURL fileURLWithPath:file(@"broken.js",
				@"function draw() {\n  [1].forEach(function() { undefined.x })\n}"
				"\ndraw()")];
		NSURL *invalid = [NSURL fileURLWithPath:file(@"invalid.js",
				@"var a = 1;\nconsole.log(import)")];
		__block NSUInteger failed = 0;
		runtime.failureHandler = ^{
			failed++;
		};
		[runtime runScriptAtURL:broken];
		[runtime runScriptAtURL:invalid];
		[runtime evaluate:@"console.log(import)"];
		CHECK(failed == 3);
		runtime.failureHandler = nil;
		NSString *at = broken.absoluteString;
		CHECK(([output isEqualToArray:@[
			[NSString stringWithFormat:@"Uncaught TypeError: undefined is not "
				"an object (evaluating 'undefined.x')\n@%@:2:37\n"
				"draw@%@:2:14\n@%@:4:5", at, at, at],
			[NSString stringWithFormat:@"Uncaught SyntaxError: Unexpected "
				"token (at %@:2:19)", invalid.absoluteString],
			@"Uncaught SyntaxError: Unexpected token (at Console:1:19)"
		]]));
		[output removeAllObjects];

		// localStorage stays with the script, sessionStorage doesn't:
		SGScript *again = [[SGScript alloc] initWithURL:url];
		[again execute:@
			"print(localStorage.getItem('a'), sessionStorage.getItem('b'))"];
		CHECK([output isEqualToArray:(@[@"1 null"])]);
		[again stop];
		[NSFileManager.defaultManager removeItemAtPath:folder error:nil];
	}
	if (failures)
		fprintf(stderr, "%d failed\n", failures);
	else
		printf("script: all passed\n");
	return failures ? 1 : 0;
}
