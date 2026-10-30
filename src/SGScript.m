//
//  SGScript.m
//  Scriptographer for Glyphs
//

#import "SGScript.h"
#import "SGRuntime.h"
#import "SGPalette.h"
#import "SGComponentsView.h"
#import "SGURLParser.h"
#import "SGRequests.h"
#import "SGCodecs.h"
#import "SGSockets.h"
#import "SGEventSources.h"
#import "SGClone.h"
#import "SGShared.h"
#import "SGPorts.h"
#import "SGCanvas.h"
#import "SGWorkers.h"
#import <JavaScriptCore/JavaScriptCore.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// The DOMException browsers give for a file system error: `isWriting` tells
// a change from a read.
static void throwFileError(NSString *path, NSError *error, BOOL isWriting) {
	NSError *posix = error.userInfo[NSUnderlyingErrorKey] ?: error;
	NSInteger code = error.code, errno_ = [posix.domain
			isEqualToString:NSPOSIXErrorDomain] ? posix.code : 0;
	NSString *name = code == NSFileNoSuchFileError
			|| code == NSFileReadNoSuchFileError || errno_ == ENOENT
				? @"NotFoundError"
			: code == NSFileReadNoPermissionError
			|| code == NSFileWriteNoPermissionError || errno_ == EACCES
			|| errno_ == EPERM
				? @"NotAllowedError"
			: isWriting ? @"InvalidModificationError" : @"NotReadableError";
	SGThrowDOMException(name, [NSString stringWithFormat:@"%@: %@", path,
			error.localizedDescription]);
}

// JavaScriptCore's watchdog, which it exports without a public header
// (WebKit's JSContextRefPrivate.h), looked up so the plugin runs without it:
typedef bool (*SGShouldTerminate)(JSContextRef context, void *info);
typedef void (*SGSetTimeLimit)(JSContextGroupRef group, double limit,
		SGShouldTerminate callback, void *info);
typedef void (*SGClearTimeLimit)(JSContextGroupRef group);

// The scripts by the global context of their realm, for the watchdog:
static NSMapTable<NSValue *, SGScript *> *scriptsByContext;

@implementation SGScript {
	JSContext *_context;
	// The bundle's natives, with what it adds for the runtime to call, and
	// js/glyphs.js's API:
	JSValue *_natives;
	JSValue *_scriptographer;
	NSMutableDictionary<NSNumber *, NSTimer *> *_timers;
	NSUInteger _nextTimer;
	CFTimeInterval _start;
	// The run loop of the thread the script runs on:
	CFRunLoopRef _runLoop;
	// `localStorage` as [key, value] pairs in their order, kept in a file per
	// script, and `sessionStorage`:
	NSMutableArray<NSArray<NSString *> *> *_localItems;
	NSMutableArray<NSArray<NSString *> *> *_sessionItems;
	// The natives that work in the background, which may keep it running:
	SGRequests *_requests;
	SGCodecs *_codecs;
	SGSockets *_sockets;
	SGEventSources *_eventSources;
	SGBroadcast *_broadcast;
	SGLocks *_locks;
	SGPorts *_ports;
	SGCanvas *_canvas;
	SGWorkers *_workers;
	// Whether it's being stopped, as it hung:
	BOOL _isStopping;
	// The preferences the script last left, as kept:
	NSString *_preferences;
	// A worker's link to who it works for, and what receives from them:
	SGWorkerLink *_link;
	JSValue *_workerReceive;
}

+ (JSVirtualMachine *)virtualMachine {
	static JSVirtualMachine *machine;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		machine = [[JSVirtualMachine alloc] init];
	});
	return machine;
}

// The sources each realm runs before the script, read once:
+ (NSArray<NSArray *> *)sources {
	static NSArray *sources;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSBundle *bundle = [NSBundle bundleForClass:self];
		NSMutableArray *list = [NSMutableArray array];
		for (NSString *name in @[@"paper-hosted", @"scriptographer",
				@"glyphs"]) {
			NSURL *url = [bundle URLForResource:name withExtension:@"js"];
			[list addObject:@[url, [NSString stringWithContentsOfURL:url
					encoding:NSUTF8StringEncoding error:nil] ?: @""]];
		}
		sources = list;
	});
	return sources;
}

- (instancetype)initWithURL:(NSURL *)url {
	return [self initWithURL:url worker:nil];
}

- (instancetype)initWithURL:(NSURL *)url worker:(SGWorkerLink *)link {
	self = [super init];
	if (self) {
		_url = url;
		_link = link;
		_name = url ? url.lastPathComponent.stringByDeletingPathExtension
				: @"Console";
		_timers = [NSMutableDictionary dictionary];
		_nextTimer = 1;
		_start = CACurrentMediaTime();
		_runLoop = CFRunLoopGetCurrent();
		_sessionItems = [NSMutableArray array];
		__weak SGScript *weakSelf = self;
		SGDeliver deliver = ^(JSValue *receiver, SGMake make) {
			[weakSelf deliver:make to:receiver];
		};
		_requests = [[SGRequests alloc] initWithDeliver:deliver];
		_codecs = [[SGCodecs alloc] init];
		_sockets = [[SGSockets alloc] initWithDeliver:deliver];
		_eventSources = [[SGEventSources alloc] initWithDeliver:deliver];
		_broadcast = [[SGBroadcast alloc] initWithDeliver:deliver];
		_locks = [[SGLocks alloc] initWithDeliver:deliver];
		_ports = [[SGPorts alloc] initWithDeliver:deliver];
		_canvas = [[SGCanvas alloc] init];
		_workers = [[SGWorkers alloc] initWithDeliver:deliver ports:_ports
				url:url link:link];
		[self setupContext];
	}
	return self;
}

// The run loop modes the scripts' timers and deliveries run in: not a modal
// dialog's, so a dialog, a script's own alert() too, holds them off, as a
// browser's does.
+ (NSArray<NSString *> *)modes {
	return @[NSDefaultRunLoopMode, NSEventTrackingRunLoopMode];
}

// A script that works for longer than the limit is asked about, as browsers
// ask about a page that hangs: Wait asks again later, Stop ends its code with
// an exception it can't catch, and the script.
static bool shouldTerminate(JSContextRef context, void *info) {
	SGScript *script;
	@synchronized ([SGScript class]) {
		script = [scriptsByContext objectForKey:[NSValue valueWithPointer:
				JSContextGetGlobalContext(context)]];
	}
	__block BOOL isStopped = NO;
	void (^ask)(void) = ^{
		isStopped = [[SGRuntime sharedRuntime] shouldStopScript:script];
	};
	if (NSThread.isMainThread)
		ask();
	else
		dispatch_sync(dispatch_get_main_queue(), ask);
	if (isStopped) {
		[script stopRunaway];
	} else {
		// Waiting sets the limit again, which asking used up:
		[script limitTime:YES];
	}
	return isStopped;
}

// Restarts the watchdog's clock, which runs from when the script started to
// work, as when it waits for the user:
- (void)limitTime:(BOOL)isLimited {
	static SGSetTimeLimit setLimit;
	static SGClearTimeLimit clearLimit;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		setLimit = dlsym(RTLD_DEFAULT, "JSContextGroupSetExecutionTimeLimit");
		clearLimit = dlsym(RTLD_DEFAULT,
				"JSContextGroupClearExecutionTimeLimit");
	});
	JSContextGroupRef group = JSContextGetGroup(_context.JSGlobalContextRef);
	if (clearLimit)
		clearLimit(group);
	if (isLimited && setLimit)
		setLimit(group, [SGRuntime sharedRuntime].responseTime,
				shouldTerminate, NULL);
}

// Once its code has ended, the script stops, and a worker closes:
- (void)stopRunaway {
	_isStopping = YES;
	SGWorkerLink *link = _link;
	__weak SGScript *weakSelf = self;
	dispatch_async(dispatch_get_main_queue(), ^{
		if (link) {
			link.isClosing = YES;
		} else if (weakSelf) {
			[[SGRuntime sharedRuntime] stopScript:weakSelf];
		}
	});
}

- (void)setupContext {
	// A worker runs on a thread of its own, so in a VM of its own:
	_context = [[JSContext alloc] initWithVirtualMachine:_link
			? [[JSVirtualMachine alloc] init] : [SGScript virtualMachine]];
	_context.name = [@"Scriptographer: " stringByAppendingString:_name];
	@synchronized ([SGScript class]) {
		if (!scriptsByContext) {
			scriptsByContext = [NSMapTable
					strongToWeakObjectsMapTable];
		}
		[scriptsByContext setObject:self forKey:[NSValue valueWithPointer:
				_context.JSGlobalContextRef]];
	}
	[self limitTime:YES];
	SGWorkerLink *link = _link;
	__weak SGScript *weakSelf = self;
	_context.exceptionHandler = ^(JSContext *context, JSValue *exception) {
		// A script stopped as it hung ends with an exception of its own:
		SGScript *script = weakSelf;
		if (script && script->_isStopping)
			return;
		// An uncaught error in a worker goes to its Worker, which shows it
		// unless a handler prevents it, and the worker goes on:
		if (link) {
			[link reportError:exception.toString];
			return;
		}
		JSValue *trace = exception[@"stack"];
		NSString *stack = trace.isString ? trace.toString : nil;
		[SGScript print:stack.length
				? [NSString stringWithFormat:@"%@\n%@", exception, stack]
				: exception.toString];
	};
	_context[@"self"] = _context.globalObject;
	_context[@"navigator"] = @{
		@"userAgent": @"Scriptographer",
		@"language": NSLocale.preferredLanguages.firstObject ?: @"en",
		@"languages": NSLocale.preferredLanguages,
		@"hardwareConcurrency":
				@(NSProcessInfo.processInfo.activeProcessorCount)
	};
	_context[@"__scriptographer"] = [self natives];
	_natives = _context[@"__scriptographer"];
	_broadcast.scriptNatives = _ports.scriptNatives = _natives;
	_context[@"__glyphs"] = [self glyphsNatives];
	for (NSArray *source in [SGScript sources])
		[_context evaluateScript:source[1] withSourceURL:source[0]];
	// structuredClone(), which the runtime gives, as in VectorCraft: the
	// ArrayBuffers it transfers are copied and detached.
	JSValue *natives = _natives;
	_context[@"structuredClone"] = ^JSValue *(JSValue *value) {
		JSContext *context = [JSContext currentContext];
		NSArray *arguments = [JSContext currentArguments];
		JSValue *options = arguments.count > 1 ? arguments[1] : nil;
		JSValue *transfer = options.isObject ? options[@"transfer"] : nil;
		NSArray *buffers = transfer.isArray ? transfer.toArray : @[];
		id data = [SGClone serialize:value natives:natives ports:nil];
		if (!data)
			return nil;
		NSUInteger length = [transfer[@"length"] toUInt32];
		for (NSUInteger i = 0; i < length && buffers.count; i++)
			[transfer[i] invokeMethod:@"transfer" withArguments:@[]];
		return [SGClone deserialize:data inContext:context ports:nil];
	};
	_scriptographer = _context[@"Scriptographer"];
	if (_url)
		[self setLocation:_url];
	// A worker's global object gets what a worker's has, and gives what
	// receives its parent's messages or the ports that connect; a script's
	// gets `script`, with its preferences:
	if (_link) {
		_workerReceive = [_natives invokeMethod:@"setupWorker"
				withArguments:@[_link.name, @(_link.isShared)]];
	} else if (_url) {
		_preferences = [NSString stringWithContentsOfURL:[self preferencesURL]
				encoding:NSUTF8StringEncoding error:nil];
		[_natives invokeMethod:@"setScript" withArguments:@[
			_url.path, _url.URLByDeletingLastPathComponent.path,
			_preferences ?: [NSNull null]
		]];
	}
}

- (void)setLocation:(NSURL *)url {
	[_natives invokeMethod:@"setLocation" withArguments:@[url.absoluteString]];
}

#pragma mark - Natives

- (NSDictionary *)natives {
	__weak SGScript *weakSelf = self;
	return @{
		@"print": ^(NSString *line) {
			[SGScript print:line];
		},
		@"now": ^double {
			SGScript *script = weakSelf;
			return script ? (CACurrentMediaTime() - script->_start) * 1000 : 0;
		},
		@"random": ^JSValue *(NSUInteger length) {
			NSMutableData *data = [NSMutableData dataWithLength:length];
			arc4random_buf(data.mutableBytes, length);
			return SGBytesValue([JSContext currentContext], data);
		},
		@"encoding": @{
			@"encode": ^JSValue *(NSString *text) {
				return SGBytesValue([JSContext currentContext],
						[text dataUsingEncoding:NSUTF8StringEncoding]);
			},
			@"decode": ^id(JSValue *bytes, BOOL fatal) {
				return [weakSelf decode:SGDataOfValue(bytes) fatal:fatal]
						?: [NSNull null];
			}
		},
		@"storage": @{
			@"getItem": ^id(BOOL session, NSString *key) {
				for (NSArray *item in [weakSelf items:session]) {
					if ([item[0] isEqualToString:key])
						return item[1];
				}
				return [NSNull null];
			},
			@"setItem": ^(BOOL session, NSString *key, NSString *value) {
				[weakSelf setItem:key value:value session:session];
			},
			@"removeItem": ^(BOOL session, NSString *key) {
				[weakSelf setItem:key value:nil session:session];
			},
			@"clear": ^(BOOL session) {
				[weakSelf clearItems:session];
			},
			@"keys": ^NSArray *(BOOL session) {
				return [[weakSelf items:session] valueForKey:@"firstObject"];
			}
		},
		// Dialogs show on the main thread, which a worker waits for:
		@"ask": ^id(NSDictionary *question) {
			__block id answer;
			void (^ask)(void) = ^{
				answer = [weakSelf ask:question];
			};
			// The time the user takes isn't the script's:
			SGScript *script = weakSelf;
			[script limitTime:NO];
			if (NSThread.isMainThread)
				ask();
			else
				dispatch_sync(dispatch_get_main_queue(), ask);
			[script limitTime:YES];
			return answer ?: [NSNull null];
		},
		@"fs": [self fileSystemNatives],
		@"fetch": [_requests natives],
		@"compression": [_codecs natives],
		@"socket": [_sockets natives],
		@"eventSource": [_eventSources natives],
		@"broadcast": [_broadcast natives],
		@"locks": [_locks natives],
		@"port": [_ports natives],
		@"url": @{
			@"parse": ^id(NSString *url) {
				NSArray *args = [JSContext currentArguments];
				JSValue *base = args.count > 1 ? args[1] : nil;
				return [SGURLParser parse:url base:base && !base.isUndefined
						? base.toString : nil] ?: [NSNull null];
			},
			@"set": ^id(NSString *href, NSString *part, NSString *value) {
				NSDictionary *parts = [SGURLParser set:href part:part value:value];
				if (!parts) {
					SGThrowError([NSString stringWithFormat:
							@"Invalid URL: '%@'.", value]);
				}
				return parts;
			},
			@"parseQuery": ^NSArray *(NSString *query) {
				return [SGURLParser parseQuery:query];
			},
			@"serializeQuery": ^NSString *(NSArray *pairs) {
				return [SGURLParser serializeQuery:pairs];
			}
		},
		@"canvas": [_canvas natives],
		@"worker": [_workers natives]
	};
}

- (NSDictionary *)glyphsNatives {
	__weak SGScript *weakSelf = self;
	SGRuntime *runtime = [SGRuntime sharedRuntime];
	return @{
		// Workers have no document:
		@"getLayer": ^id {
			SGScript *script = weakSelf;
			return script && !script->_link ? [runtime layerData] ?: [NSNull null]
					: [NSNull null];
		},
		@"setPaths": ^NSArray *(NSNumber *layerKey, NSArray *edits) {
			return [runtime setPaths:edits layerKey:layerKey];
		},
		@"setSelection": ^(NSNumber *layerKey, NSDictionary *selection) {
			[runtime setSelection:selection layerKey:layerKey];
		},
		@"bindView": ^{
			SGScript *script = weakSelf;
			[script->_canvas bindView];
		},
		@"setTimer": ^NSNumber *(double delay, BOOL repeat, JSValue *callback) {
			return [weakSelf setTimer:delay repeat:repeat callback:callback];
		},
		@"clearTimer": ^(NSNumber *timer) {
			[weakSelf clearTimer:timer];
		}
	};
}

// UTF-8 as browsers decode it: each invalid sequence, as long as it could be
// the start of a valid one, becomes U+FFFD, or the text is null when `fatal`.
- (NSString *)decode:(NSData *)data fatal:(BOOL)fatal {
	NSString *text = [[NSString alloc] initWithData:data
			encoding:NSUTF8StringEncoding];
	if (text || fatal)
		return text;
	const uint8_t *bytes = data.bytes;
	NSUInteger length = data.length;
	NSMutableString *result = [NSMutableString stringWithCapacity:length];
	for (NSUInteger i = 0; i < length;) {
		uint8_t byte = bytes[i];
		// The sequence's length, and the range of its second byte:
		NSUInteger count = byte < 0x80 ? 1 : byte >= 0xc2 && byte <= 0xdf ? 2
				: byte >= 0xe0 && byte <= 0xef ? 3
				: byte >= 0xf0 && byte <= 0xf4 ? 4 : 0;
		uint8_t lower = byte == 0xe0 ? 0xa0 : byte == 0xf0 ? 0x90 : 0x80;
		uint8_t upper = byte == 0xed ? 0x9f : byte == 0xf4 ? 0x8f : 0xbf;
		NSUInteger valid = count ? 1 : 0;
		while (valid && valid < count && i + valid < length) {
			uint8_t next = bytes[i + valid];
			if (next < (valid == 1 ? lower : 0x80)
					|| next > (valid == 1 ? upper : 0xbf))
				break;
			valid++;
		}
		if (count && valid == count) {
			[result appendString:[[NSString alloc] initWithBytes:bytes + i
					length:count encoding:NSUTF8StringEncoding]];
			i += count;
		} else {
			[result appendString:@"\uFFFD"];
			i += MAX(valid, 1);
		}
	}
	return result;
}

#pragma mark - File system

// The script's folder, which relative paths start from, or none for the
// console:
- (NSURL *)directoryURL {
	return _url.URLByDeletingLastPathComponent;
}

- (NSString *)absolutePath:(NSString *)path {
	path = [path isKindOfClass:[NSString class]] ? path : [path description];
	NSURL *directory = [self directoryURL];
	return path.isAbsolutePath || !directory ? path
			: [directory URLByAppendingPathComponent:path].path;
}

// The folder of the script's own files, next to its `localStorage`:
- (NSURL *)privateDirectoryURL {
	return _url ? [[self storageURL] URLByDeletingPathExtension] : nil;
}

// What VectorCraft's fs.rs gives `LocalFile`, the File System Access API and
// `fetch()` of `file:` URLs: the file system by path, relative paths from the
// script's folder.
- (NSDictionary *)fileSystemNatives {
	__weak SGScript *weakSelf = self;
	NSFileManager *files = NSFileManager.defaultManager;
	return @{
		@"path": ^NSString * {
			NSString *path = @"";
			for (JSValue *part in [JSContext currentArguments]) {
				NSString *name = part.toString;
				path = name.isAbsolutePath ? name
						: [path stringByAppendingPathComponent:name];
			}
			return [weakSelf absolutePath:path];
		},
		@"info": ^NSDictionary *(NSString *path) {
			path = [weakSelf absolutePath:path];
			NSDictionary *attributes = [files attributesOfItemAtPath:path
					error:nil];
			NSString *parent = path.stringByDeletingLastPathComponent;
			return @{
				@"name": path.lastPathComponent,
				@"parent": parent.length ? parent : [NSNull null],
				@"extension": path.pathExtension,
				@"exists": @(attributes != nil),
				@"isDirectory": @([attributes.fileType
						isEqualToString:NSFileTypeDirectory]),
				@"size": @(attributes.fileSize),
				@"lastModified": @(floor(attributes.fileModificationDate
						.timeIntervalSince1970 * 1000))
			};
		},
		@"fromURL": ^id(NSString *href) {
			NSURL *url = [NSURL URLWithString:href];
			if (!url.isFileURL) {
				SGThrowError([NSString stringWithFormat:
						@"fetch failed: '%@' is no file's URL.", href]);
				return nil;
			}
			return url.path;
		},
		@"read": ^JSValue *(NSString *path) {
			path = [weakSelf absolutePath:path];
			NSError *error = nil;
			NSData *data = [NSData dataWithContentsOfFile:path options:0
					error:&error];
			if (!data) {
				throwFileError(path, error, NO);
				return nil;
			}
			return SGBytesValue([JSContext currentContext], data);
		},
		@"write": ^(NSString *path, JSValue *bytes, BOOL append) {
			path = [weakSelf absolutePath:path];
			NSData *data = bytes.isObject ? SGDataOfValue(bytes) : [NSData data];
			NSError *error = nil;
			if (append && [files fileExistsAtPath:path]) {
				NSFileHandle *handle = [NSFileHandle
						fileHandleForWritingToURL:[NSURL fileURLWithPath:path]
						error:&error];
				if (handle && [handle seekToEndReturningOffset:nil error:&error])
					[handle writeData:data error:&error];
				[handle closeAndReturnError:nil];
			} else {
				[data writeToFile:path options:0 error:&error];
			}
			if (error)
				throwFileError(path, error, YES);
		},
		@"list": ^NSArray *(NSString *path) {
			path = [weakSelf absolutePath:path];
			NSError *error = nil;
			NSArray *names = [files contentsOfDirectoryAtPath:path error:&error];
			if (!names) {
				throwFileError(path, error, NO);
				return nil;
			}
			NSMutableArray *paths = [NSMutableArray array];
			for (NSString *name in [names sortedArrayUsingSelector:
					@selector(compare:)])
				[paths addObject:[path stringByAppendingPathComponent:name]];
			return paths;
		},
		@"makeDirectory": ^(NSString *path, BOOL recursive) {
			path = [weakSelf absolutePath:path];
			NSError *error = nil;
			if (![files createDirectoryAtPath:path
					withIntermediateDirectories:recursive attributes:nil
					error:&error])
				throwFileError(path, error, YES);
		},
		@"remove": ^(NSString *path, BOOL recursive) {
			path = [weakSelf absolutePath:path];
			BOOL isDirectory = NO;
			NSError *error = nil;
			if (![files fileExistsAtPath:path isDirectory:&isDirectory]) {
				throwFileError(path, [NSError errorWithDomain:NSCocoaErrorDomain
						code:NSFileNoSuchFileError userInfo:nil], YES);
			} else if (isDirectory && !recursive
					&& [files contentsOfDirectoryAtPath:path error:nil].count) {
				throwFileError(path, [NSError errorWithDomain:NSPOSIXErrorDomain
						code:ENOTEMPTY userInfo:nil], YES);
			} else if (![files removeItemAtPath:path error:&error]) {
				throwFileError(path, error, YES);
			}
		},
		// A name renames it where it is, a path moves it:
		@"rename": ^id(NSString *path, NSString *given) {
			path = [weakSelf absolutePath:path];
			NSString *to = given.pathComponents.count == 1
					? [path.stringByDeletingLastPathComponent
						stringByAppendingPathComponent:given]
					: [weakSelf absolutePath:given];
			NSError *error = nil;
			if (![files moveItemAtPath:path toPath:to error:&error]) {
				throwFileError(path, error, YES);
				return nil;
			}
			return to;
		},
		@"copy": ^(NSString *from, NSString *to) {
			from = [weakSelf absolutePath:from];
			to = [weakSelf absolutePath:to];
			NSError *error = nil;
			[files removeItemAtPath:to error:nil];
			if (![files copyItemAtPath:from toPath:to error:&error])
				throwFileError(from, error, YES);
		},
		@"relative": ^id(NSString *directory, NSString *path) {
			NSArray *outer = [weakSelf absolutePath:directory].pathComponents;
			NSArray *inner = [weakSelf absolutePath:path].pathComponents;
			if (inner.count < outer.count || ![[inner subarrayWithRange:
					NSMakeRange(0, outer.count)] isEqualToArray:outer])
				return [NSNull null];
			return [inner subarrayWithRange:NSMakeRange(outer.count,
					inner.count - outer.count)];
		},
		@"userDirectory": ^id(NSString *name) {
			NSString *folder = @{
				@"desktop": @"Desktop", @"documents": @"Documents",
				@"downloads": @"Downloads", @"music": @"Music",
				@"pictures": @"Pictures", @"videos": @"Movies"
			}[name];
			if (!folder) {
				SGThrowError([NSString stringWithFormat:
						@"Unknown directory: '%@'.", name]);
				return nil;
			}
			return [NSHomeDirectory() stringByAppendingPathComponent:folder];
		},
		@"privateDirectory": ^id {
			NSURL *directory = [weakSelf privateDirectoryURL];
			if (!directory)
				return [NSNull null];
			[files createDirectoryAtURL:directory
					withIntermediateDirectories:YES attributes:nil error:nil];
			return directory.path;
		},
		// The bytes the script keeps, in its own files and its localStorage:
		@"usage": ^double {
			SGScript *script = weakSelf;
			unsigned long long bytes = [files attributesOfItemAtPath:
					[script storageURL].path error:nil].fileSize;
			NSURL *directory = [script privateDirectoryURL];
			for (NSURL *url in directory ? [files enumeratorAtURL:directory
					includingPropertiesForKeys:@[NSURLFileSizeKey]
					options:0 errorHandler:nil] : @[]) {
				NSNumber *size = nil;
				[url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
				bytes += size.unsignedLongLongValue;
			}
			return bytes;
		}
	};
}

#pragma mark - Delivering

// What the natives that work in the background give the script, as a unit of
// its work:
// On the script's next turn, on its run loop, unless it stopped meanwhile:
- (void)deliver:(SGMake)make to:(JSValue *)receiver {
	__weak SGScript *weakSelf = self;
	CFRunLoopPerformBlock(_runLoop, (__bridge CFTypeRef)[SGScript modes], ^{
		SGScript *script = weakSelf;
		if (!script || !script->_context)
			return;
		id value = make(script->_context) ?: [NSNull null];
		[script->_scriptographer invokeMethod:@"call"
				withArguments:@[receiver, @[value]]];
		[script didWork];
	});
	CFRunLoopWakeUp(_runLoop);
}

#pragma mark - Storage

- (NSURL *)storageURL {
	const char *path = (_url.path ?: _name).UTF8String;
	unsigned char digest[CC_SHA256_DIGEST_LENGTH];
	CC_SHA256(path, (CC_LONG)strlen(path), digest);
	NSMutableString *name = [NSMutableString string];
	for (int i = 0; i < 16; i++)
		[name appendFormat:@"%02x", digest[i]];
	NSURL *support = [[NSFileManager.defaultManager
			URLsForDirectory:NSApplicationSupportDirectory
			inDomains:NSUserDomainMask] firstObject];
	return [[support URLByAppendingPathComponent:
			@"Scriptographer/Storage" isDirectory:YES]
			URLByAppendingPathComponent:[name stringByAppendingString:@".json"]];
}

- (NSMutableArray<NSArray<NSString *> *> *)items:(BOOL)session {
	if (session)
		return _sessionItems;
	if (!_localItems) {
		NSData *data = [NSData dataWithContentsOfURL:[self storageURL]];
		NSArray *items = data ? [NSJSONSerialization JSONObjectWithData:data
				options:NSJSONReadingMutableContainers error:nil] : nil;
		_localItems = [items isKindOfClass:[NSArray class]]
				? (NSMutableArray *)items : [NSMutableArray array];
	}
	return _localItems;
}

- (void)setItem:(NSString *)key value:(NSString *)value session:(BOOL)session {
	NSMutableArray *items = [self items:session];
	NSUInteger index = [items indexOfObjectPassingTest:
			^BOOL(NSArray *item, NSUInteger i, BOOL *stop) {
		return [item[0] isEqualToString:key];
	}];
	if (value && index != NSNotFound)
		items[index] = @[key, value];
	else if (value)
		[items addObject:@[key, value]];
	else if (index != NSNotFound)
		[items removeObjectAtIndex:index];
	if (!session)
		[self saveItems];
}

- (void)clearItems:(BOOL)session {
	[[self items:session] removeAllObjects];
	if (!session)
		[self saveItems];
}

- (void)saveItems {
	NSURL *url = [self storageURL];
	[NSFileManager.defaultManager
			createDirectoryAtURL:url.URLByDeletingLastPathComponent
			withIntermediateDirectories:YES attributes:nil error:nil];
	[[NSJSONSerialization dataWithJSONObject:_localItems options:0 error:nil]
			writeToURL:url atomically:YES];
}

#pragma mark - Dialogs

// What the script asks, while it waits for the answer, as VectorCraft's `ask`:
// `alert`, `confirm` and `prompt` dialogs, and the clipboard.
- (id)ask:(NSDictionary *)question {
	NSString *type = question[@"type"];
	if ([type isEqualToString:@"clipboardRead"]) {
		return @{ @"text": [NSPasteboard.generalPasteboard
				stringForType:NSPasteboardTypeString] ?: @"" };
	}
	if ([type isEqualToString:@"clipboardWrite"]) {
		NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
		[pasteboard clearContents];
		[pasteboard setString:question[@"text"] ?: @""
				forType:NSPasteboardTypeString];
		return @YES;
	}
	if ([@[@"openFile", @"openFiles", @"saveFile", @"chooseDirectory"]
			containsObject:type])
		return [self pick:question];
	BOOL isPrompt = [type isEqualToString:@"prompt"];
	if (!isPrompt && ![type isEqualToString:@"alert"]
			&& ![type isEqualToString:@"confirm"])
		return nil;
	NSAlert *alert = [[NSAlert alloc] init];
	NSString *title = question[@"title"], *message = question[@"message"];
	alert.messageText = [title isKindOfClass:[NSString class]] ? title : @"";
	if ([message isKindOfClass:[NSString class]])
		alert.informativeText = message;
	[alert addButtonWithTitle:@"OK"];
	if (![type isEqualToString:@"alert"])
		[alert addButtonWithTitle:@"Cancel"];
	SGComponentsView *components = nil;
	if (isPrompt) {
		components = [[SGComponentsView alloc]
				initWithComponents:question[@"components"] ?: @[]];
		components.frame = (NSRect){ NSZeroPoint, components.fittingSize };
		alert.accessoryView = components;
	}
	BOOL isOK = [alert runModal] == NSAlertFirstButtonReturn;
	if (isPrompt)
		return isOK ? components.values : nil;
	return @(isOK);
}

// The paths the user picks for the script, or nil: `path` is where the
// picker starts, a folder or a file in one, and `filters` the script's file
// types, `[description, extensions]`, where one without extensions shows all.
- (id)pick:(NSDictionary *)question {
	NSString *type = question[@"type"], *path = question[@"path"];
	BOOL isSave = [type isEqualToString:@"saveFile"];
	NSSavePanel *panel = isSave ? [NSSavePanel savePanel]
			: [NSOpenPanel openPanel];
	if ([path isKindOfClass:[NSString class]]) {
		BOOL isDirectory = NO;
		path = [self absolutePath:path];
		if ([NSFileManager.defaultManager fileExistsAtPath:path
				isDirectory:&isDirectory] && isDirectory) {
			panel.directoryURL = [NSURL fileURLWithPath:path];
		} else {
			panel.directoryURL = [NSURL fileURLWithPath:
					path.stringByDeletingLastPathComponent];
			panel.nameFieldStringValue = path.lastPathComponent;
		}
	}
	NSMutableArray *extensions = [NSMutableArray array];
	BOOL showsAll = NO;
	for (NSArray *filter in question[@"filters"]) {
		NSArray *list = [filter isKindOfClass:[NSArray class]]
				&& filter.count > 1 ? filter[1] : @[];
		showsAll |= !list.count;
		[extensions addObjectsFromArray:list];
	}
	if (extensions.count && !showsAll) {
		NSMutableArray *types = [NSMutableArray array];
		for (NSString *extension in extensions) {
			UTType *type = [UTType typeWithFilenameExtension:extension];
			if (type)
				[types addObject:type];
		}
		panel.allowedContentTypes = types;
	}
	if (!isSave) {
		NSOpenPanel *open = (NSOpenPanel *)panel;
		BOOL isDirectory = [type isEqualToString:@"chooseDirectory"];
		open.canChooseDirectories = isDirectory;
		open.canChooseFiles = !isDirectory;
		open.canCreateDirectories = isDirectory;
		open.allowsMultipleSelection = [type isEqualToString:@"openFiles"];
	}
	if ([panel runModal] != NSModalResponseOK)
		return nil;
	if ([type isEqualToString:@"openFiles"])
		return [((NSOpenPanel *)panel).URLs valueForKey:@"path"];
	return panel.URL.path;
}

#pragma mark - Timers

- (NSNumber *)setTimer:(double)delay repeat:(BOOL)repeat
		callback:(JSValue *)callback {
	NSNumber *timer = @(_nextTimer++);
	// The timer holds the callback, and with it the realm, until it's cleared
	// or the script stops:
	__weak SGScript *weakSelf = self;
	NSTimer *instance = [NSTimer timerWithTimeInterval:MAX(delay, 1) / 1000
			repeats:repeat block:^(NSTimer *instance) {
		SGScript *script = weakSelf;
		if (!script)
			return;
		if (!repeat)
			[script->_timers removeObjectForKey:timer];
		[callback callWithArguments:@[]];
		[script didWork];
	}];
	for (NSString *mode in [SGScript modes])
		[[self runLoop] addTimer:instance forMode:mode];
	_timers[timer] = instance;
	return timer;
}

- (void)clearTimer:(NSNumber *)timer {
	[_timers[timer] invalidate];
	[_timers removeObjectForKey:timer];
}

#pragma mark - Running

- (void)execute:(NSString *)source {
	[_scriptographer invokeMethod:@"execute"
			withArguments:@[source, _url.path ?: _name,
				_natives[@"executeScript"]]];
	[self didWork];
}

- (void)evaluate:(NSString *)source {
	[_context evaluateScript:source withSourceURL:_url];
	[self didWork];
}

// Output goes to the console, from any thread:
+ (void)print:(NSString *)line {
	if (NSThread.isMainThread) {
		[[SGRuntime sharedRuntime] print:line];
	} else {
		dispatch_async(dispatch_get_main_queue(), ^{
			[[SGRuntime sharedRuntime] print:line];
		});
	}
}

// The run loop of the script's thread, where its timers fire:
- (NSRunLoop *)runLoop {
	return _link ? NSRunLoop.currentRunLoop : NSRunLoop.mainRunLoop;
}

- (void)receiveWorkerMessage:(NSArray *)message {
	SGPorts *ports = _ports;
	[self deliver:^id(JSContext *context) {
		NSArray *received = nil;
		JSValue *event = [JSValue valueWithNewObjectInContext:context];
		event[@"type"] = @"message";
		event[@"data"] = [ports receive:message inContext:context
				ports:&received];
		event[@"ports"] = received;
		return event;
	} to:_workerReceive];
}

- (void)connectWorkerPort:(id)port {
	SGPorts *ports = _ports;
	[self deliver:^id(JSContext *context) {
		return [ports adoptPort:port];
	} to:_workerReceive];
}

// Kept next to its localStorage, when they changed:
- (NSURL *)preferencesURL {
	return [[self storageURL].URLByDeletingPathExtension
			URLByAppendingPathExtension:@"preferences.json"];
}

- (void)keepPreferences {
	JSValue *value = [_natives invokeMethod:@"getPreferences"
			withArguments:@[]];
	NSString *preferences = value.isString ? value.toString : nil;
	if (_url && preferences && ![preferences isEqualToString:_preferences]) {
		_preferences = preferences;
		[NSFileManager.defaultManager
				createDirectoryAtURL:[self preferencesURL]
					.URLByDeletingLastPathComponent
				withIntermediateDirectories:YES attributes:nil error:nil];
		[preferences writeToURL:[self preferencesURL] atomically:YES
				encoding:NSUTF8StringEncoding error:nil];
	}
}

- (BOOL)keepsAlive {
	return [_natives invokeMethod:@"keepsAlive" withArguments:@[]].toBool;
}

- (BOOL)callHandler:(NSString *)name {
	BOOL hasHandler = [_scriptographer invokeMethod:@"call" withArguments:@[
		_natives[@"callHandler"], @[name]
	]].toBool;
	if (hasHandler)
		[self didWork];
	return hasHandler;
}

- (BOOL)isRunning {
	return _context && (_timers.count || [self isBusy]
			|| [_scriptographer invokeMethod:@"isRunning" withArguments:@[]]
				.toBool
			|| [_natives invokeMethod:@"hasPalettes" withArguments:@[]]
				.toBool);
}

- (NSArray<id<SGNativeGroup>> *)groups {
	return @[_requests, _codecs, _sockets, _eventSources, _broadcast,
			_locks, _ports, _canvas, _workers];
}

- (BOOL)isBusy {
	for (id<SGNativeGroup> group in [self groups]) {
		if ([group isBusy])
			return YES;
	}
	return NO;
}

// Scripts' coordinates have y down, the layer's up:
- (void)drawOverlayInContext:(CGContextRef)context scale:(double)scale {
	if (!_context)
		return;
	[_canvas drawView:context draw:^{
		[self->_scriptographer invokeMethod:@"drawOverlay" withArguments:@[
			@[@1, @0, @0, @-1, @0, @0], @(scale)
		]];
	}];
}

- (BOOL)hasTool {
	return [_scriptographer invokeMethod:@"hasTool" withArguments:@[]].toBool;
}

// After each unit of work: the palettes it opened or changed show, and the
// runtime learns whether the script still runs.
- (void)didWork {
	// A worker runs until it's closed, and shows no palettes or overlays:
	if (!_context || _link)
		return;
	NSArray *palettes = [[_natives invokeMethod:@"takePalettes"
			withArguments:@[]] toArray];
	if (palettes.count) {
		__weak SGScript *weakSelf = self;
		[SGPalette showPalettes:palettes ofScript:[self paletteKey]
				handler:^(NSNumber *paletteId, NSString *type, NSString *name,
					id value) {
			[weakSelf handlePalette:paletteId type:type name:name value:value];
		}];
	}
	[self keepPreferences];
	// What the overlay draws may have changed with the work:
	if ([[_scriptographer invokeMethod:@"hasDrawHandlers" withArguments:@[]]
			toBool])
		[[SGRuntime sharedRuntime] redrawView];
	[[SGRuntime sharedRuntime] scriptDidWork:self];
}

- (NSString *)paletteKey {
	return _url.path ?: _name;
}

- (void)handlePalette:(NSNumber *)paletteId type:(NSString *)type
		name:(NSString *)name value:(id)value {
	if (!_context)
		return;
	[_scriptographer invokeMethod:@"call" withArguments:@[
		_natives[@"handlePaletteEvent"],
		@[paletteId, type, name ?: [NSNull null], value ?: [NSNull null]]
	]];
	[self didWork];
}

- (void)stop {
	for (NSTimer *timer in _timers.allValues)
		[timer invalidate];
	[_timers removeAllObjects];
	[SGPalette closePalettesOfScript:[self paletteKey]];
	for (id<SGNativeGroup> group in [self groups])
		[group stop];
	[_scriptographer invokeMethod:@"stop" withArguments:@[]];
	_scriptographer = nil;
	_natives = nil;
	_context = nil;
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
	[self didWork];
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
	BOOL isHandled = [[_scriptographer invokeMethod:@"key" withArguments:@[
		type, key, character, [self modifiersFromFlags:event.modifierFlags]
	]] toBool];
	if (isHandled)
		[self didWork];
	return isHandled;
}

@end
