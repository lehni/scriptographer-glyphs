//
//  SGWindowController.h
//  Scriptographer for Glyphs
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// The Scriptographer window, as VectorCraft's panel: the scripts folders as a
// tree (the Examples, sealed, My Scripts, and the folders the user adds), the
// buttons to run, stop, edit and make scripts, and the console with what they
// print.
@interface SGWindowController : NSWindowController

+ (void)addMenuItem;
+ (instancetype)sharedController;

@end

NS_ASSUME_NONNULL_END
