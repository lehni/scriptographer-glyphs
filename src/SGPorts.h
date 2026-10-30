//
//  SGPorts.h
//  Scriptographer for Glyphs
//

#import "SGNatives.h"

NS_ASSUME_NONNULL_BEGIN

@class SGPortEnd;

// The ports of a script's `MessageChannel`, `natives.port`, as VectorCraft's
// message_port.rs has them: a channel is two ports, whose ends are crossed, so
// it works the same whether both are in one script or in two. A port sent in
// a message's transfer list moves to the script that receives it, which
// numbers it as one of its own. Messages wait in a port until its script
// starts it. `channel()`, `post(number, message, ports, numbers, buffers)`,
// `start(number, receive)` and `close(number)`. A started port whose other
// port is still there keeps its script running.
@interface SGPorts : NSObject <SGNativeGroup>

// The script's natives, which serializing reads blobs and geometry with, and
// which make the ports a message brings (`makePort()`):
@property (nonatomic, strong, nullable) JSValue *scriptNatives;

- (instancetype)initWithDeliver:(SGDeliver)deliver;

// The value of a message, as structured serialization keeps it, with the
// ends of the ports it transfers, by their numbers here, which leave the
// script: nil when it can't be kept.
- (nullable NSArray *)messageOf:(JSValue *)value ports:(JSValue *)ports
		numbers:(JSValue *)numbers buffers:(JSValue *)buffers;

// The port of `number`, which leaves the script, to move to another one, as
// a SharedWorker's does: nil when it has none of that number.
- (nullable id)takePort:(NSNumber *)number;

// A port that moved here, as a MessagePort of the script:
- (JSValue *)adoptPort:(id)port;

// A message made again here: its value with the ports it brought, which the
// script numbers as its own.
- (JSValue *)receive:(NSArray *)message inContext:(JSContext *)context
		ports:(NSArray<JSValue *> *_Nullable *_Nullable)ports;

@end

NS_ASSUME_NONNULL_END
