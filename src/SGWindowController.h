//
//  SGWindowController.h
//  Scriptographer for Glyphs
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// The Scriptographer window: the scripts in the scripts folder, to run and
// stop, and the console with what they print.
@interface SGWindowController : NSWindowController

+ (void)addMenuItem;
+ (instancetype)sharedController;

@end

NS_ASSUME_NONNULL_END
