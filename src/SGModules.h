//
//  SGModules.h
//  Scriptographer for Glyphs
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The text of the module at a `file:`, `http:` or `https:` URL, for
// `natives.readModule`, as VectorCraft's modules.rs reads them: a download
// waits for its answer, and is kept in Scriptographer's Cache folder, which
// gives it back when the server says it's still the one (304), fails (5xx) or
// can't be reached. Returns nil with the reason in `reason`.
NSString *_Nullable SGReadModule(NSURL *url, NSString *_Nullable *_Nonnull reason);

NS_ASSUME_NONNULL_END
