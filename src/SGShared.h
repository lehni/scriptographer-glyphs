//
//  SGShared.h
//  Scriptographer for Glyphs
//

#import "SGNatives.h"

NS_ASSUME_NONNULL_BEGIN

// `BroadcastChannel` across the scripts, `natives.broadcast`, as VectorCraft's
// broadcast_channel.rs has it: all scripts are of one origin, so a message
// goes to every other channel of its name, as structured serialization keeps
// it, in the order the messages were posted, and to the channels of one in
// the order they were opened. `open(name, receive)`, `post(number, message)`
// and `close(number)`. An open channel keeps its script running.
@interface SGBroadcast : NSObject <SGNativeGroup>

// The script's natives, which serializing reads blobs and geometry with:
@property (nonatomic, strong, nullable) JSValue *scriptNatives;

- (instancetype)initWithDeliver:(SGDeliver)deliver;

@end

// The Web Locks of all scripts, `natives.locks`, as VectorCraft's locks.rs has
// them: a free lock is granted at once, one that frees up later goes to the
// next request for it. `request(name, exclusive, ifAvailable, steal,
// receive)`, which gives the request's number and whether it's `granted`,
// `waiting` or `unavailable`, `release(number)`, `cancel(number)` and
// `query()`. What a request hears later, `granted` or `stolen`, goes to
// `receive()`. A waiting request keeps its script running; a script that
// stops lets go of its locks and requests.
@interface SGLocks : NSObject <SGNativeGroup>

- (instancetype)initWithDeliver:(SGDeliver)deliver;

@end

NS_ASSUME_NONNULL_END
