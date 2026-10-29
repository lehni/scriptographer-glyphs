//
//  SGRuntime.h
//  Scriptographer for Glyphs
//

#import <Cocoa/Cocoa.h>

@class GSLayer;

NS_ASSUME_NONNULL_BEGIN

// Runs the scripts in one JavaScriptCore context with Paper.js, see
// js/glyphs.js for the JavaScript side.
@interface SGRuntime : NSObject

+ (instancetype)sharedRuntime;

// Receives what scripts print and the errors they throw:
@property (nonatomic, copy, nullable) void (^printHandler)(NSString *line);
// Called when scripts start or stop:
@property (nonatomic, copy, nullable) void (^stateHandler)(void);
// The layer of the Script tool while it handles an event, in place of the
// active layer of the current document:
@property (nonatomic, weak, nullable) GSLayer *toolLayer;
// Counts the edits written to Glyphs, for the tool's undo steps:
@property (nonatomic, readonly) NSUInteger editCount;

- (BOOL)runScriptAtURL:(NSURL *)url;
- (void)stopScriptAtURL:(NSURL *)url;
- (BOOL)isScriptRunningAtURL:(NSURL *)url;
- (nullable NSURL *)toolScriptURL;
- (void)evaluate:(NSString *)code;
- (void)print:(NSString *)line;

- (void)handleMouse:(NSString *)type at:(NSPoint)point
        modifiers:(NSEventModifierFlags)modifiers;
// Returns whether the tool's script handles the key:
- (BOOL)handleKey:(NSString *)type event:(NSEvent *)event;

@end

NS_ASSUME_NONNULL_END
