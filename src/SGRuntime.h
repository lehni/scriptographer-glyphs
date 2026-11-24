//
//  SGRuntime.h
//  Scriptographer for Glyphs
//

#import <Cocoa/Cocoa.h>

@class GSLayer, SGScript;

NS_ASSUME_NONNULL_BEGIN

// The running scripts and the console, each an SGScript in a realm of its own,
// and what they share: the keys of Glyphs' layers and paths, and writing their
// changes back. See js/glyphs.js for the JavaScript side.
@interface SGRuntime : NSObject

+ (instancetype)sharedRuntime;

// Receives what scripts print and the errors they throw:
@property (nonatomic, copy, nullable) void (^printHandler)(NSString *line);
// Called when scripts start or stop:
@property (nonatomic, copy, nullable) void (^stateHandler)(void);
// Called when a script's work fails, after its error is printed:
@property (nonatomic, copy, nullable) void (^failureHandler)(void);
// The layer of the Script tool while it handles an event, in place of the
// active layer of the current document:
@property (nonatomic, weak, nullable) GSLayer *toolLayer;
// Counts the edits written to Glyphs, for the tool's undo steps:
@property (nonatomic, readonly) NSUInteger editCount;
// How long a script works before it's asked about, in seconds (5):
@property (nonatomic) double responseTime;
// Whether to stop a script that doesn't respond; without one, the user is
// asked, Wait or Stop:
@property (nonatomic, copy, nullable) BOOL (^stopHandler)(SGScript *script);
// The script that last defined a tool, which the Script tool hands its events:
@property (nonatomic, readonly, nullable) SGScript *toolScript;

// Runs the script, stopping the others unless they keep running
// (`script.keepAlive`) or are the tool's, as VectorCraft does:
- (BOOL)runScriptAtURL:(NSURL *)url;
// Runs the `__init__` scripts in the folders, as Glyphs starts, then calls
// their `onStartup`:
- (void)runInitScriptsIn:(NSArray<NSURL *> *)folders;
// Whether to stop a script that hangs, on the main thread:
- (BOOL)shouldStopScript:(nullable SGScript *)script;
// Stops a script, as one that hangs is when the user asks:
- (void)stopScript:(SGScript *)script;
// Stops every script and the console, as VectorCraft's Stop does:
- (void)stopAllScripts;
// Calls the handler of every script that has it, `onEditOptions`…:
- (void)callHandler:(NSString *)name;
- (BOOL)isScriptRunningAtURL:(NSURL *)url;
// Runs a line of the console, in its own realm, made on the first line and
// kept until the scripts stop:
- (void)evaluate:(NSString *)code;
- (void)print:(NSString *)line;

- (void)handleMouse:(NSString *)type at:(NSPoint)point
		modifiers:(NSEventModifierFlags)modifiers;
// Returns whether the tool's script handles the key:
- (BOOL)handleKey:(NSString *)type event:(NSEvent *)event;

// For SGScript: the active layer with its paths, or any layer's, writing the
// scripts' changes back, and each unit of work's end.
- (nullable NSDictionary *)layerData;
- (NSDictionary *)dataOfLayer:(GSLayer *)layer;
- (NSArray *)setPaths:(NSArray<NSDictionary *> *)edits
		layerKey:(NSNumber *)layerKey;
// Replaces what the path's effects drew with `outputs`, `{ nodes, closed }`,
// beneath it, and keeps the `input` they drew:
- (void)setEffectOutput:(NSArray<NSDictionary *> *)outputs
		input:(NSString *)input ofPathKey:(NSNumber *)key;
// Selects the nodes of the paths, by their keys, and nothing else:
- (void)setSelection:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)selection
		layerKey:(NSNumber *)layerKey;
- (void)scriptDidWork:(SGScript *)script;
- (void)scriptDidFail;

// The edit view draws the scripts' overlays over the layer, and asks for it
// again when they change:
- (void)drawOverlaysInContext:(CGContextRef)context scale:(double)scale;
- (void)redrawView;

@end

NS_ASSUME_NONNULL_END
