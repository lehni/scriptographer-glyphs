//
//  SGConsoleController.h
//  Scriptographer for Glyphs
//

#import "SGPanelController.h"

NS_ASSUME_NONNULL_BEGIN

// The Scriptographer Console, as VectorCraft's panel and the original
// Scriptographer's console: a multi-line field on top where Return runs the
// line it ends, and under it everything the scripts printed.
@interface SGConsoleController : SGPanelController

+ (void)addMenuItem;
+ (instancetype)sharedController;

@end

NS_ASSUME_NONNULL_END
