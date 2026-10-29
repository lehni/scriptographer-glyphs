//
//  SGClone.h
//  Scriptographer for Glyphs
//

#import "SGNatives.h"

NS_ASSUME_NONNULL_BEGIN

// Structured serialization, as browsers copy values between windows and
// workers, and as VectorCraft's clone.rs keeps them: primitives as they are;
// arrays and objects deeply, as plain ones (their own enumerable properties),
// each object once, so shared and cyclic ones stay so; `Date`, `RegExp`,
// `Map`, `Set`, `ArrayBuffer`, typed arrays and `DataView`, the `Error`
// classes, boxed primitives, `Blob`, `ImageData` and the geometry classes as
// themselves. Functions, symbols and other objects can't be kept. The data is
// made of Foundation objects, which any realm, on any thread, makes again.
@interface SGClone : NSObject

// The data of `value`, with `natives` its realm's bundle natives (for blobs
// and geometry) and `ports` the ports the message transfers, which the data
// refers to by their place. Throws a DataCloneError in the realm, and returns
// nil, for what it can't keep.
+ (nullable id)serialize:(JSValue *)value natives:(JSValue *)natives
		ports:(nullable NSArray<JSValue *> *)ports;

// `data` made again in `context`, with `ports` the ports the message brought:
+ (JSValue *)deserialize:(id)data inContext:(JSContext *)context
		ports:(nullable NSArray<JSValue *> *)ports;

@end

NS_ASSUME_NONNULL_END
