//
//  SGEventSources.h
//  Scriptographer for Glyphs
//

#import "SGNatives.h"

NS_ASSUME_NONNULL_BEGIN

// The connections of a script's `EventSource`, `natives.eventSource`, as
// VectorCraft's event_source.rs has them: `open(url, receive)` and
// `close(number)`. A connection reads its stream's events as the HTML
// standard parses them, and once the stream ends or breaks, connects again
// after the reconnection time, with the last event's id. `receive()` gets
// `{ state, … }`: `open` with the URL, `event` with its type, data and
// last event id, `reconnecting`, and `failed` with the reason. An open
// connection keeps the script running.
@interface SGEventSources : NSObject <SGNativeGroup>

- (instancetype)initWithDeliver:(SGDeliver)deliver;

@end

NS_ASSUME_NONNULL_END
