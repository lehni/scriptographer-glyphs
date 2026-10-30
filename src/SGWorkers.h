//
//  SGWorkers.h
//  Scriptographer for Glyphs
//

#import "SGNatives.h"

@class SGPorts, SGScript;

NS_ASSUME_NONNULL_BEGIN

// What connects a worker to the scripts it works for: its realm on a thread
// of its own, and its parent's, or for a shared worker, the realms of the
// scripts connected to it.
@interface SGWorkerLink : NSObject

@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) BOOL isShared;
// Set by `close()`, `terminate()` or its parent stopping: the worker ends
// once its current work is done.
@property (atomic) BOOL isClosing;

// Hands the worker's message to its parent, from the worker's thread:
- (void)postToParent:(NSArray *)message;
// Hands an uncaught error of the worker to its parent, or the scripts
// connected to a shared one:
- (void)reportError:(NSString *)message;

@end

// The workers of a script's `Worker` and `SharedWorker`, `natives.worker`,
// as VectorCraft's web_worker.rs has them: each runs a classic script on a
// thread of its own, in a realm of its own with the same APIs and Paper.js,
// but no document. Messages go both ways as structured serialization keeps
// them, with the ports they transfer. `start(url, name, receive)`,
// `post(number, data, ports, numbers, buffers)`, `terminate(number)`,
// `connect(url, name, port, onError)`, and in a worker, `self.postMessage`,
// `self.close` and `self.importScripts`. A dedicated worker keeps its parent
// running.
@interface SGWorkers : NSObject <SGNativeGroup>

// The realm the group is of, whose file workers' URLs are relative to, and
// its link to its own parent when it's a worker:
- (instancetype)initWithDeliver:(SGDeliver)deliver ports:(SGPorts *)ports
		url:(nullable NSURL *)url link:(nullable SGWorkerLink *)link;

@end

NS_ASSUME_NONNULL_END
