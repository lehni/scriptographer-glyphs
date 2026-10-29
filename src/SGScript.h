//
//  SGScript.h
//  Scriptographer for Glyphs
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// A running script, or the console, in a JavaScriptCore realm of its own with
// Paper.js, Scriptographer's bundle (vendor/scriptographer.js, shared with
// VectorCraft) and js/glyphs.js, as VectorCraft gives each script its own
// runtime. It provides the bundle's natives (see VectorCraft's
// crates/scriptographer) and the plugin's, `__glyphs`, through SGRuntime.
@interface SGScript : NSObject

// The script's file, or nil for the console:
@property (nonatomic, readonly, nullable) NSURL *url;
@property (nonatomic, readonly) NSString *name;

- (instancetype)initWithURL:(nullable NSURL *)url;

// Runs the script's code, or a line of the console:
- (void)execute:(NSString *)source;

// Whether it keeps running: with a tool, animation, timers or palettes.
- (BOOL)isRunning;
- (BOOL)hasTool;

// Stops it, closing its palettes, and lets go of its realm:
- (void)stop;

- (void)handleMouse:(NSString *)type at:(NSPoint)point
		modifiers:(NSEventModifierFlags)modifiers;
// Returns whether the script handles the key:
- (BOOL)handleKey:(NSString *)type event:(NSEvent *)event;

@end

NS_ASSUME_NONNULL_END
