//
//  SGNatives.h
//  Scriptographer for Glyphs
//

#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

NS_ASSUME_NONNULL_BEGIN

// Makes a value in a script's realm, on its thread:
typedef id _Nullable (^SGMake)(JSContext *context);

// Hands a value to a function of the script, `receiver`, on the script's next
// turn, as a unit of its work: what the natives that work in the background
// give the script, made by `make` in its realm. Callable from any thread.
typedef void (^SGDeliver)(JSValue *receiver, SGMake make);

// A value made of Foundation objects, the same in every realm:
SGMake SGValue(id value);

// A group of the bundle's natives (see VectorCraft's crates/scriptographer)
// that works in the background for a script, as `fetch()` and `WebSocket` do.
@protocol SGNativeGroup <NSObject>

// The natives, as the bundle reads them, e.g. `natives.fetch`:
- (NSDictionary *)natives;

// Whether its work keeps the script running:
- (BOOL)isBusy;

// Ends its work, as the script stops:
- (void)stop;

@end

// Bytes as a Uint8Array of the context, and back from a typed array:
JSValue *SGBytesValue(JSContext *context, NSData *data);
NSData *SGDataOfValue(JSValue *value);

// Throws an Error, or a DOMException of `name`, in the calling context:
void SGThrowError(NSString *message);
void SGThrowDOMException(NSString *name, NSString *message);

NS_ASSUME_NONNULL_END
