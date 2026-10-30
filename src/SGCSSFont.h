//
//  SGCSSFont.h
//  Scriptographer for Glyphs
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A canvas's `font`, the CSS shorthand as browsers read it and write it back,
// and its `letterSpacing` and `wordSpacing`, as VectorCraft's canvas does, so
// scripts see the same values in both apps.
@interface SGCSSFont : NSObject

// `normal`, `italic` or `oblique`:
@property (nonatomic, readonly, copy) NSString *style;
@property (nonatomic, readonly, getter=isSmallCaps) BOOL smallCaps;
// From 1 to 1000: 400 is `normal`, 700 `bold`:
@property (nonatomic, readonly) NSInteger weight;
// `normal`, `condensed` or one of the other stretch keywords:
@property (nonatomic, readonly, copy) NSString *stretch;
// In CSS pixels, which are Paper.js's points:
@property (nonatomic, readonly) double size;
// The generic families lowercased, the others as given:
@property (nonatomic, readonly, copy) NSArray<NSString *> *families;

// `text` as a font shorthand, or nil when it isn't one, which leaves a
// canvas's font as it was in browsers:
+ (nullable SGCSSFont *)parse:(NSString *)text;

// The shorthand as the canvas gives it back: what isn't `normal`, the size in
// pixels, the families unquoted where they're identifiers.
- (NSString *)serialized;

// The faces to try for `family` in turn: typical ones for the generic
// families, the family itself for any other.
+ (NSArray<NSString *> *)candidatesForFamily:(NSString *)family;

// A CSS length in pixels, an `em` the font's `size`, a `rem` the default
// font's 10 pixels, or nil when it isn't one:
+ (nullable NSNumber *)lengthInPixels:(NSString *)text fontSize:(double)size;

// The length as the canvas's `letterSpacing` and `wordSpacing` give it back,
// trimmed and lowercased, or nil when it isn't one:
+ (nullable NSString *)normalizedLength:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
