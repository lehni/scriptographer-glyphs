//
//  SGScript.h
//  Scriptographer for Glyphs
//

#import <Cocoa/Cocoa.h>

@class SGWorkerLink;

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

// A worker's realm, on its thread, with its link to who it works for:
- (instancetype)initWithURL:(NSURL *)url worker:(nullable SGWorkerLink *)link;

// A worker's: a message from its parent, as `message`, and the port of a
// script that connects to a shared one, as `connect`:
- (void)receiveWorkerMessage:(NSArray *)message;
- (void)connectWorkerPort:(id)port;

// Runs the script's code, or a line of the console, as PaperScript:
- (void)execute:(NSString *)source;
// Runs code as a classic script, as workers run theirs:
- (void)evaluate:(NSString *)source;

// The URL relative ones resolve against, `location`: the script's file, as
// in VectorCraft.
- (void)setLocation:(NSURL *)url;

// Whether it keeps running: with a tool, animation, timers or palettes.
- (BOOL)isRunning;
- (BOOL)hasTool;

// Whether the script set `script.keepAlive`, to keep running when another
// script runs:
- (BOOL)keepsAlive;

// Calls the handler the script exported, `onStop`, `onStartup`…: whether it
// has it.
- (BOOL)callHandler:(NSString *)name;

// Draws the script's overlay into the edit view's context, in the layer's
// coordinates, `scale` the view's points per unit:
- (void)drawOverlayInContext:(CGContextRef)context scale:(double)scale;

// Stops it, closing its palettes, and lets go of its realm:
- (void)stop;

- (void)handleMouse:(NSString *)type at:(NSPoint)point
		modifiers:(NSEventModifierFlags)modifiers;
// Returns whether the script handles the key:
- (BOOL)handleKey:(NSString *)type event:(NSEvent *)event;

@end

NS_ASSUME_NONNULL_END
