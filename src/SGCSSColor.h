//
//  SGCSSColor.h
//  Scriptographer for Glyphs
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// CSS colours as the canvas takes them and gives them back, as VectorCraft's
// css_color.rs and the color crate it uses do, to the bit: CSS Color 4,
// `currentcolor` (black, as for a canvas without an element), the system
// colours, and CSS Color 5's `color-mix()` and relative colours
// (`rgb(from red g r b)`: channel keywords, numbers, percentages and `none`,
// but no `calc()`).
@interface SGCSSColor : NSObject

// The colour `text` is, or nil when it isn't one:
+ (nullable SGCSSColor *)parse:(NSString *)text;

// The colour in sRGB, rounded to 8 bits a channel as a canvas keeps it, each
// from 0 to 1:
@property (nonatomic, readonly) double red, green, blue, alpha;

// Whether it was written in the legacy syntax: a name, hex, `rgb()`, `hsl()`
// or `hwb()`. A gradient interpolates in Oklab once one of its stops isn't.
@property (nonatomic, readonly, getter=isLegacy) BOOL legacy;

// The colour as a canvas gives it back: in the legacy syntax `#rrggbb`, or
// `rgba(r, g, b, a)` when it's not opaque; else as CSS writes the colour, in
// its space (`color(srgb 0.5 0 0.5)`).
- (NSString *)serialized;

@end

NS_ASSUME_NONNULL_END
