//
//  SGRequests.h
//  Scriptographer for Glyphs
//

#import "SGNatives.h"

NS_ASSUME_NONNULL_BEGIN

// The requests of a script's `fetch()`, `natives.fetch`, as VectorCraft's
// fetch.rs sends them: `request(method, url, headers, body, follow,
// receive)` and `cancel(number)`.
@interface SGRequests : NSObject <SGNativeGroup>

- (instancetype)initWithDeliver:(SGDeliver)deliver;

@end

NS_ASSUME_NONNULL_END
