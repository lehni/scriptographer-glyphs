//
//  SGSockets.h
//  Scriptographer for Glyphs
//

#import "SGNatives.h"

NS_ASSUME_NONNULL_BEGIN

// The sockets of a script's `WebSocket`, `natives.socket`, as VectorCraft's
// websocket.rs has them: `open(url, protocols, receive)`, `send(number,
// data)` and `close(number, code, reason)`. `receive()` gets `{ type, … }`:
// `open` with its protocol, `message` with its data, a string or bytes,
// `error` with a message and `close` with its code, reason and whether it
// closed cleanly. An open socket keeps the script running.
@interface SGSockets : NSObject <SGNativeGroup>

- (instancetype)initWithDeliver:(SGDeliver)deliver;

@end

NS_ASSUME_NONNULL_END
