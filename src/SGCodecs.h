//
//  SGCodecs.h
//  Scriptographer for Glyphs
//

#import "SGNatives.h"

NS_ASSUME_NONNULL_BEGIN

// The codecs of a script's `CompressionStream` and `DecompressionStream`,
// `natives.compression`, as VectorCraft's compression.rs has them: gzip,
// deflate and deflate-raw over zlib, brotli over the Compression framework.
// `open(format, decompress)`, `write(number, bytes)`, which gives what it
// made and why it failed, `finish(number)` and `close(number)`.
@interface SGCodecs : NSObject <SGNativeGroup>
@end

NS_ASSUME_NONNULL_END
