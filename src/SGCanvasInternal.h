//
//  SGCanvasInternal.h
//  Scriptographer for Glyphs
//

#import "SGCanvas.h"
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>

@class SGCSSColor, SGCSSFont, SGCanvasPaint;

NS_ASSUME_NONNULL_BEGIN

// globalCompositeOperation's modes, as CoreGraphics composites them:
NSDictionary<NSString *, NSNumber *> *blendModes(void);

// A clip of the context, in device coordinates.
@interface SGCanvasClip : NSObject
@property (nonatomic) CGPathRef path;
@property (nonatomic) BOOL isEvenOdd;
@end

// What save() keeps of a context: its properties, as `get()` gives them, and
// what they parse to, its transform, clips and dashes.
@interface SGCanvasState : NSObject <NSCopying>
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *properties;
@property (nonatomic, strong, nullable) SGCSSColor *fillColor, *strokeColor;
@property (nonatomic, strong, nullable) SGCanvasPaint *fillPaint, *strokePaint;
@property (nonatomic, strong) SGCSSColor *shadowColor;
@property (nonatomic, strong) SGCSSFont *font;
@property (nonatomic) CGAffineTransform transform;
@property (nonatomic, copy) NSArray<SGCanvasClip *> *clips;
@property (nonatomic, copy) NSArray<NSNumber *> *dash;
- (double)number:(NSString *)name;
- (NSString *)text:(NSString *)name;
@end

// A gradient (`linear`, `radial`, `conic`, with its numbers and stops) or a
// pattern (its image, repetition and transform).
@interface SGCanvasPaint : NSObject
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSArray<NSNumber *> *values;
@property (nonatomic, strong) NSMutableArray<NSArray *> *stops;
@property (nonatomic, nullable) CGImageRef image;
@property (nonatomic, copy) NSString *repetition;
@property (nonatomic) CGAffineTransform patternTransform;
@end

// A Path2D, in its own coordinates.
@interface SGCanvasPath : NSObject
@property (nonatomic, readonly) CGMutablePathRef path;
@end

// A canvas or bitmap: its pixels, premultiplied RGBA in sRGB, drawn in
// canvas coordinates (y down), with its context's state and current path,
// in device coordinates.
@interface SGCanvasSurface : NSObject
@property (nonatomic, readonly) NSUInteger width, height;
@property (nonatomic, readonly, nullable) CGContextRef context;
// The context of the view an overlay draws into, in place of its pixels,
// while it draws (see SGCanvas's -drawView:):
@property (nonatomic, nullable) CGContextRef viewContext;
@property (nonatomic) BOOL isOpaque;
@property (nonatomic, strong) SGCanvasState *state;
@property (nonatomic, strong) NSMutableArray<SGCanvasState *> *stack;
@property (nonatomic) CGMutablePathRef path;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height;
- (void)resizeTo:(NSUInteger)width height:(NSUInteger)height;
- (void)reset;
- (void)clear;
- (void)makeOpaque;
- (nullable CGImageRef)copyImage CF_RETURNS_RETAINED;
@end

@interface SGCanvas ()

- (void)fill:(CGPathRef)path evenOdd:(BOOL)evenOdd
		color:(nullable SGCSSColor *)color paint:(nullable SGCanvasPaint *)paint
		surface:(SGCanvasSurface *)surface;
- (void)stroke:(CGPathRef)path surface:(SGCanvasSurface *)surface;

@end

// The text of the canvas, on CoreText: fillText(), strokeText(),
// measureText() and the fonts scripts add (SGCanvasText.m).
@interface SGCanvas (Text)

- (void)drawText:(NSString *)text arguments:(NSArray<JSValue *> *)args
		stroke:(BOOL)stroke surface:(SGCanvasSurface *)surface;
- (nullable NSDictionary *)measureText:(NSString *)text
		surface:(SGCanvasSurface *)surface;
- (NSArray<NSString *> *)addFont:(JSValue *)bytes;
- (void)setFontFace:(NSString *)name families:(NSArray<NSString *> *)families
		shown:(BOOL)shown;

@end

NS_ASSUME_NONNULL_END
