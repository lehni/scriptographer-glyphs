//
//  SGWindowController.h
//  Scriptographer for Glyphs
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// The Scriptographer window, as VectorCraft's panel: the scripts folders as a
// tree (the Examples, sealed, My Scripts, and the folders the user adds), and
// the buttons to run, stop, edit and make scripts, and to show the console.
@interface SGWindowController : NSWindowController

+ (void)addMenuItem;
// Runs the `__init__` scripts of the folders, as Glyphs starts:
+ (void)runInitScripts;
+ (instancetype)sharedController;

@end

NS_ASSUME_NONNULL_END
