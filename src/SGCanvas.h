//
//  SGCanvas.h
//  Scriptographer for Glyphs
//

#import "SGNatives.h"
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// The canvases of a script's `OffscreenCanvas`, `Path2D`, `ImageBitmap`,
// `CanvasGradient` and `CanvasPattern`, `natives.canvas`, on CoreGraphics, as
// VectorCraft's canvas.rs and drawing.rs have them: each object of the bundle
// keeps the number of its slot here, surfaces, paths and paints alike, and
// the methods of a surface or a path are called with its slot as `this`.
@interface SGCanvas : NSObject <SGNativeGroup>

// The canvas the script made last becomes the overlay's, which draws into
// the view's context in -drawView:.
- (void)bindView;

// Runs `draw` with the overlay's canvas drawing into `context`, the view's,
// in its coordinates, its state as new:
- (void)drawView:(CGContextRef)context draw:(void (^)(void))draw;

@end

NS_ASSUME_NONNULL_END
