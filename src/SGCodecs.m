//
//  SGCodecs.m
//  Scriptographer for Glyphs
//

#import "SGCodecs.h"
#import <compression.h>
#import <zlib.h>

// The most a stream may make, in bytes, as in VectorCraft: more fails it.
static const NSUInteger most = 512 * 1024 * 1024;
// How much a codec makes at a time:
enum { part = 64 * 1024 };

// A stream's codec, over zlib or, for brotli, the Compression framework.
@interface SGCodec : NSObject
@property (nonatomic, readonly) BOOL hasEnded;
- (nullable instancetype)initWithFormat:(NSString *)format
		decompress:(BOOL)decompress;
// Writes the bytes through the codec, or with `finish` the rest of what it
// makes: what it made, and why it failed, if it did.
- (NSData *)write:(NSData *)bytes finish:(BOOL)finish
		failure:(NSString *_Nullable *_Nullable)failure;
@end

@implementation SGCodec {
	BOOL _isBrotli, _decompress;
	z_stream _zlib;
	compression_stream _brotli;
	NSUInteger _made;
}

- (instancetype)initWithFormat:(NSString *)format decompress:(BOOL)decompress {
	// zlib's window bits: gzip's header, zlib's, or none:
	NSDictionary *bits = @{ @"gzip": @(15 + 16), @"deflate": @15,
			@"deflate-raw": @(-15) };
	BOOL isBrotli = [format isEqualToString:@"brotli"];
	if (!isBrotli && !bits[format])
		return nil;
	self = [super init];
	if (self) {
		_isBrotli = isBrotli;
		_decompress = decompress;
		int status;
		if (isBrotli) {
			status = compression_stream_init(&_brotli, decompress
					? COMPRESSION_STREAM_DECODE : COMPRESSION_STREAM_ENCODE,
					COMPRESSION_BROTLI) == COMPRESSION_STATUS_OK ? Z_OK : -1;
		} else if (decompress) {
			status = inflateInit2(&_zlib, [bits[format] intValue]);
		} else {
			status = deflateInit2(&_zlib, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
					[bits[format] intValue], 8, Z_DEFAULT_STRATEGY);
		}
		if (status != Z_OK)
			return nil;
	}
	return self;
}

- (void)dealloc {
	if (_isBrotli)
		compression_stream_destroy(&_brotli);
	else if (_decompress)
		inflateEnd(&_zlib);
	else
		deflateEnd(&_zlib);
}

- (NSData *)write:(NSData *)bytes finish:(BOOL)finish
		failure:(NSString **)failure {
	NSMutableData *made = [NSMutableData data];
	uint8_t buffer[part];
	if (_hasEnded && bytes.length) {
		*failure = @"The compressed data goes on after its end.";
		return made;
	}
	if (_isBrotli) {
		_brotli.src_ptr = bytes.bytes;
		_brotli.src_size = bytes.length;
	} else {
		_zlib.next_in = (Bytef *)bytes.bytes;
		_zlib.avail_in = (uInt)bytes.length;
	}
	while (!_hasEnded) {
		size_t left;
		BOOL isDone;
		if (_isBrotli) {
			_brotli.dst_ptr = buffer;
			_brotli.dst_size = part;
			compression_status status = compression_stream_process(&_brotli,
					finish ? COMPRESSION_STREAM_FINALIZE : 0);
			if (status == COMPRESSION_STATUS_ERROR) {
				*failure = @"The compressed data is invalid.";
				break;
			}
			left = _brotli.dst_size;
			_hasEnded = status == COMPRESSION_STATUS_END;
			isDone = !_brotli.src_size && left;
		} else {
			_zlib.next_out = buffer;
			_zlib.avail_out = part;
			int status = _decompress ? inflate(&_zlib, Z_NO_FLUSH)
					: deflate(&_zlib, finish ? Z_FINISH : Z_NO_FLUSH);
			if (status != Z_OK && status != Z_STREAM_END
					&& status != Z_BUF_ERROR) {
				*failure = @"The compressed data is invalid.";
				break;
			}
			left = _zlib.avail_out;
			_hasEnded = status == Z_STREAM_END;
			isDone = !_zlib.avail_in && left;
			if (_hasEnded && _decompress && _zlib.avail_in)
				*failure = @"The compressed data goes on after its end.";
		}
		[made appendBytes:buffer length:part - left];
		_made += part - left;
		if (_made > most) {
			*failure = @"The data makes more than a stream may have.";
			break;
		}
		if (isDone)
			break;
	}
	if (finish && _decompress && !_hasEnded && !*failure)
		*failure = @"The compressed data ended before its end.";
	return made;
}

@end

@implementation SGCodecs {
	NSMutableDictionary<NSNumber *, SGCodec *> *_codecs;
	NSUInteger _nextCodec;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		_codecs = [NSMutableDictionary dictionary];
		_nextCodec = 1;
	}
	return self;
}

- (NSDictionary *)natives {
	__weak SGCodecs *weakSelf = self;
	return @{
		@"open": ^id(NSString *format, BOOL decompress) {
			return [weakSelf open:format decompress:decompress];
		},
		@"write": ^id(NSNumber *number, JSValue *bytes) {
			return [weakSelf write:SGDataOfValue(bytes) to:number
					finish:NO];
		},
		@"finish": ^id(NSNumber *number) {
			NSArray *result = [weakSelf write:[NSData data] to:number
					finish:YES];
			[weakSelf close:number];
			if (result.count > 1 && [result[1] isKindOfClass:[NSString class]])
				SGThrowError(result[1]);
			return result.firstObject;
		},
		@"close": ^(NSNumber *number) {
			[weakSelf close:number];
		}
	};
}

// The codecs run while the script writes to them, and keep nothing going:
- (BOOL)isBusy {
	return NO;
}

- (void)stop {
	[_codecs removeAllObjects];
}

- (NSNumber *)open:(NSString *)format decompress:(BOOL)decompress {
	SGCodec *codec = [[SGCodec alloc] initWithFormat:format
			decompress:decompress];
	if (!codec) {
		SGThrowError([NSString stringWithFormat:
				@"Unsupported compression format: '%@'.", format]);
		return nil;
	}
	NSNumber *number = @(_nextCodec++);
	_codecs[number] = codec;
	return number;
}

// What the codec made of the bytes, and why it failed, if it did:
- (NSArray *)write:(NSData *)bytes to:(NSNumber *)number finish:(BOOL)finish {
	SGCodec *codec = _codecs[number];
	if (!codec) {
		SGThrowError(@"The stream is closed.");
		return nil;
	}
	NSString *failure = nil;
	NSData *made = [codec write:bytes finish:finish failure:&failure];
	return @[SGBytesValue([JSContext currentContext], made),
			failure ?: [JSValue valueWithUndefinedInContext:
				[JSContext currentContext]]];
}

- (void)close:(NSNumber *)number {
	[_codecs removeObjectForKey:number];
}

@end
