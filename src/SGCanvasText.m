//
//  SGCanvasText.m
//  Scriptographer for Glyphs
//

#import "SGCanvasInternal.h"
#import "SGCSSFont.h"
#import <CoreText/CoreText.h>

// The FontFace aliases scripts show, by their lowercased names, and the
// families they stand for:
static NSMutableDictionary<NSString *, NSArray<NSString *> *> *fontFaces;
// The fonts scripts added, by family, kept to the scripts rather than
// registered with the system, where they'd show in Glyphs' own font lists:
static NSMutableDictionary<NSString *, NSMutableArray *> *addedFonts;

// A line of text as the context's settings lay it out, with what places it:
// its anchor, from textAlign and textBaseline, and the font's heights.
@interface SGTextLine : NSObject
@property (nonatomic) CTLineRef line;
@property (nonatomic, copy) NSString *text;
@property (nonatomic) double width, anchorX, baseline;
@property (nonatomic) double ascent, descent, emAscent, emDescent, hanging,
		ideographic;
// The spacing added after each character, as UTF-16 offsets: before
// character i, the line has moved on by `spacing[i]`.
@property (nonatomic, strong) NSArray<NSNumber *> *spacing;
@end

@implementation SGTextLine

- (double)spacingBefore:(NSUInteger)index {
	return index < _spacing.count ? _spacing[index].doubleValue
			: _spacing.lastObject.doubleValue;
}

- (void)dealloc {
	if (_line)
		CFRelease(_line);
}

@end

// ICU's break iterator, which libicucore exports, without headers:
typedef struct UBreakIterator UBreakIterator;
extern UBreakIterator *ubrk_open(int type, const char *locale,
		const uint16_t *text, int32_t length, int *status);
extern int32_t ubrk_first(UBreakIterator *iterator);
extern int32_t ubrk_next(UBreakIterator *iterator);
extern void ubrk_close(UBreakIterator *iterator);

// The text's extended grapheme clusters, as UAX #29 splits them, as
// VectorCraft's do: a zero-width joiner joins pictographs only, unlike
// Foundation's composed character sequences.
static void enumerateClusters(NSString *text,
		void (^block)(NSString *cluster, NSRange range)) {
	NSUInteger length = text.length;
	unichar *characters = malloc(MAX(length, 1) * sizeof(unichar));
	[text getCharacters:characters range:NSMakeRange(0, length)];
	int status = 0;
	// UBRK_CHARACTER:
	UBreakIterator *iterator = ubrk_open(0, "", characters, (int32_t)length,
			&status);
	if (iterator && status <= 0) {
		int32_t start = ubrk_first(iterator);
		for (int32_t end = ubrk_next(iterator); end >= 0;
				start = end, end = ubrk_next(iterator)) {
			NSRange range = NSMakeRange(start, end - start);
			block([text substringWithRange:range], range);
		}
	}
	if (iterator)
		ubrk_close(iterator);
	free(characters);
}

// A baseline of the font's BASE table, above the alphabetic one, in its
// units: `hang` or `ideo`, of the Latin script or the default one; nil
// without.
static NSNumber *baseBaseline(CTFontRef font, uint32_t wanted) {
	NSData *table = CFBridgingRelease(CTFontCopyTable(font,
			kCTFontTableBASE, kCTFontTableOptionNoOptions));
	const uint8_t *b = table.bytes;
	NSUInteger length = table.length;
	uint16_t (^u16)(NSUInteger) = ^uint16_t(NSUInteger at) {
		return at + 2 <= length ? (uint16_t)(b[at] << 8 | b[at + 1]) : 0;
	};
	uint32_t (^u32)(NSUInteger) = ^uint32_t(NSUInteger at) {
		return (uint32_t)u16(at) << 16 | u16(at + 2);
	};
	NSUInteger axis = u16(4);
	if (!axis)
		return nil;
	NSUInteger tags = axis + u16(axis), scripts = axis + u16(axis + 2);
	if (tags == axis || scripts == axis)
		return nil;
	NSUInteger tagCount = u16(tags), scriptCount = u16(scripts);
	NSUInteger script = 0;
	for (NSUInteger i = 0; i < scriptCount; i++) {
		uint32_t tag = u32(scripts + 2 + i * 6);
		if (tag == 'latn' || (tag == 'DFLT' && !script) || !script)
			script = scripts + u16(scripts + 2 + i * 6 + 4);
		if (tag == 'latn')
			break;
	}
	NSUInteger values = script ? script + u16(script) : 0;
	if (!values || values == script)
		return nil;
	NSUInteger coordCount = u16(values + 2);
	// The coordinates, by tag, above the Roman baseline:
	double romn = 0, found = NAN;
	for (NSUInteger i = 0; i < tagCount && i < coordCount; i++) {
		uint32_t tag = u32(tags + 2 + i * 4);
		NSUInteger coord = values + u16(values + 4 + i * 2);
		double value = (int16_t)u16(coord + 2);
		if (tag == 'romn')
			romn = value;
		if (tag == wanted)
			found = value;
	}
	return isnan(found) ? nil : @(found - romn);
}

// Whether a family is installed:
static BOOL isInstalled(NSString *family) {
	CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(
			(__bridge CFDictionaryRef)@{ (__bridge NSString *)
				kCTFontFamilyNameAttribute: family });
	CTFontDescriptorRef match = CTFontDescriptorCreateMatchingFontDescriptor(
			descriptor, (__bridge CFSetRef)[NSSet setWithObject:(__bridge
				NSString *)kCTFontFamilyNameAttribute]);
	CFRelease(descriptor);
	if (match)
		CFRelease(match);
	return match != NULL;
}

// The font of the shorthand, at `size`: its aliases first, then the first
// family installed, with the four faces canvas.rs tells apart.
static CTFontRef createFont(SGCSSFont *font, double size) {
	// The fonts are the scripts', workers' too:
	@synchronized ([SGCanvas class]) {
		NSMutableArray *families = [NSMutableArray array];
		for (NSString *family in font.families) {
			NSArray *alias = fontFaces[family.lowercaseString];
			for (NSString *name in alias ?: @[family])
				[families addObjectsFromArray:[SGCSSFont candidatesForFamily:name]];
		}
		CTFontSymbolicTraits traits = (font.weight >= 600 ? kCTFontBoldTrait : 0)
				| (![font.style isEqualToString:@"normal"] ? kCTFontItalicTrait : 0);
		NSString *chosen = @"Helvetica";
		for (NSString *family in families) {
			// An added family's face with the traits asked, or its first:
			NSArray *added = addedFonts[family];
			if (added.count) {
				id face = added.firstObject;
				for (id descriptor in added) {
					NSDictionary *faceTraits = CFBridgingRelease(
							CTFontDescriptorCopyAttribute((__bridge
								CTFontDescriptorRef)descriptor,
								kCTFontTraitsAttribute));
					CTFontSymbolicTraits symbolic = [faceTraits[(__bridge NSString *)
							kCTFontSymbolicTrait] unsignedIntValue];
					if ((symbolic & (kCTFontBoldTrait | kCTFontItalicTrait))
							== traits)
						face = descriptor;
				}
				return CTFontCreateWithFontDescriptor((__bridge
						CTFontDescriptorRef)face, size, NULL);
			}
			if (isInstalled(family)) {
				chosen = family;
				break;
			}
		}
		CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(
				(__bridge CFDictionaryRef)@{
			(__bridge NSString *)kCTFontFamilyNameAttribute: chosen,
			(__bridge NSString *)kCTFontTraitsAttribute: @{
				(__bridge NSString *)kCTFontSymbolicTrait: @(traits)
			}
		});
		CTFontRef result = CTFontCreateWithFontDescriptor(descriptor, size, NULL);
		CFRelease(descriptor);
		return result;
	}
}

@implementation SGCanvas (Text)

// The text as the context lays it out: controls as spaces, NUL as a
// zero-width space; spacing after every character and space; small caps
// drawn at 70%.
- (SGTextLine *)layOut:(NSString *)text state:(SGCanvasState *)state {
	NSMutableString *clean = [text mutableCopy];
	for (NSString *control in @[@"\t", @"\n", @"\f", @"\r"]) {
		[clean replaceOccurrencesOfString:control withString:@" " options:0
				range:NSMakeRange(0, clean.length)];
	}
	[clean replaceOccurrencesOfString:@"\0" withString:@"​" options:0
			range:NSMakeRange(0, clean.length)];
	SGCSSFont *shorthand = state.font;
	double size = shorthand.size;
	CTFontRef font = createFont(shorthand, size);
	BOOL isSmallCaps = shorthand.isSmallCaps
			|| [[state text:@"fontVariantCaps"] hasSuffix:@"small-caps"];
	NSString *letterText = [state text:@"letterSpacing"];
	NSString *wordText = [state text:@"wordSpacing"];
	double letter = [SGCSSFont lengthInPixels:letterText fontSize:size]
			.doubleValue;
	double word = [SGCSSFont lengthInPixels:wordText fontSize:size].doubleValue;
	BOOL hasKerning = ![[state text:@"fontKerning"] isEqualToString:@"none"];
	BOOL isRTL = [[state text:@"direction"] isEqualToString:@"rtl"];
	CTWritingDirection direction = isRTL ? kCTWritingDirectionRightToLeft
			: kCTWritingDirectionLeftToRight;
	CTParagraphStyleSetting setting = {
		kCTParagraphStyleSpecifierBaseWritingDirection,
		sizeof(direction), &direction
	};
	CTParagraphStyleRef paragraph = CTParagraphStyleCreate(&setting, 1);
	NSMutableAttributedString *string = [[NSMutableAttributedString alloc]
			initWithString:clean attributes:@{
		(__bridge NSString *)kCTFontAttributeName: (__bridge id)font,
		(__bridge NSString *)kCTParagraphStyleAttributeName:
				(__bridge id)paragraph
	}];
	CFRelease(paragraph);
	if (!hasKerning) {
		[string addAttribute:(__bridge NSString *)kCTKernAttributeName
				value:@0 range:NSMakeRange(0, clean.length)];
	}
	// The spacing after every character and space, which the layout adds
	// to the font's own advances, kerned or not:
	NSMutableArray *spacing = [NSMutableArray arrayWithCapacity:
			clean.length + 1];
	__block double moved = 0;
	[spacing addObject:@0];
	enumerateClusters(clean, ^(NSString *character, NSRange range) {
		for (NSUInteger i = 1; i < range.length; i++)
			[spacing addObject:@(moved)];
		moved += letter + ([character isEqualToString:@" "] ? word : 0);
		[spacing addObject:@(moved)];
	});
	if (isSmallCaps) {
		CTFontRef small = CTFontCreateCopyWithAttributes(font, size * 0.7,
				NULL, NULL);
		enumerateClusters(clean, ^(NSString *character, NSRange range) {
			NSString *upper = character.uppercaseString;
			if (![upper isEqualToString:character]
					&& upper.length == character.length) {
				[string replaceCharactersInRange:range withString:upper];
				[string addAttribute:(__bridge NSString *)kCTFontAttributeName
						value:(__bridge id)small range:range];
			}
		});
		CFRelease(small);
	}
	SGTextLine *line = [[SGTextLine alloc] init];
	line.text = clean;
	line.line = CTLineCreateWithAttributedString(
			(__bridge CFAttributedStringRef)string);
	line.spacing = spacing;
	line.width = CTLineGetTypographicBounds(line.line, NULL, NULL, NULL)
			+ moved;
	// The em box is the font's size, split as its ascent and descent are,
	// from its units, which CoreText's floats round:
	CGFontRef graphics = CTFontCopyGraphicsFont(font, NULL);
	double units = CGFontGetUnitsPerEm(graphics);
	double ascent = CGFontGetAscent(graphics) * size / units;
	double descent = -CGFontGetDescent(graphics) * size / units;
	CGFontRelease(graphics);
	line.ascent = ascent;
	line.descent = descent;
	line.emAscent = ascent + descent > 0
			? size * ascent / (ascent + descent) : size;
	line.emDescent = size - line.emAscent;
	NSNumber *hanging = baseBaseline(font, 'hang');
	NSNumber *ideographic = baseBaseline(font, 'ideo');
	line.hanging = hanging ? hanging.doubleValue * size / units : 0.8 * ascent;
	line.ideographic = ideographic ? ideographic.doubleValue * size / units
			: -descent;
	CFRelease(font);
	NSString *align = [state text:@"textAlign"];
	BOOL isEnd = [align isEqualToString:@"right"]
			|| ([align isEqualToString:@"end"] && !isRTL)
			|| ([align isEqualToString:@"start"] && isRTL);
	line.anchorX = [align isEqualToString:@"center"] ? line.width / 2
			: isEnd ? line.width : 0;
	// How far below the anchor the alphabetic baseline lies:
	NSDictionary *baselines = @{
		@"top": @(line.emAscent), @"hanging": @(line.hanging),
		@"middle": @((line.emAscent - line.emDescent) / 2),
		@"ideographic": @(line.ideographic), @"bottom": @(-line.emDescent),
		@"alphabetic": @0
	};
	line.baseline = [baselines[[state text:@"textBaseline"]] doubleValue];
	return line;
}

// The outlines of the line's glyphs, with the matrix from the line's own
// coordinates (y up, from its start on the baseline) to where they go:
- (CGPathRef)copyOutlinesOf:(SGTextLine *)line
		transform:(CGAffineTransform)transform {
	CGMutablePathRef path = CGPathCreateMutable();
	for (id object in (__bridge NSArray *)CTLineGetGlyphRuns(line.line)) {
		CTRunRef run = (__bridge CTRunRef)object;
		CTFontRef font = (CTFontRef)CFDictionaryGetValue(
				CTRunGetAttributes(run), kCTFontAttributeName);
		CFIndex count = CTRunGetGlyphCount(run);
		CGGlyph *glyphs = malloc(count * sizeof(CGGlyph));
		CGPoint *positions = malloc(count * sizeof(CGPoint));
		CFIndex *indices = malloc(count * sizeof(CFIndex));
		CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphs);
		CTRunGetPositions(run, CFRangeMake(0, 0), positions);
		CTRunGetStringIndices(run, CFRangeMake(0, 0), indices);
		for (CFIndex i = 0; i < count; i++) {
			CGAffineTransform matrix = CGAffineTransformConcat(
					CGAffineTransformMakeTranslation(positions[i].x
						+ [line spacingBefore:indices[i]], positions[i].y),
					transform);
			CGPathRef glyph = CTFontCreatePathForGlyph(font, glyphs[i],
					&matrix);
			if (glyph) {
				CGPathAddPath(path, NULL, glyph);
				CGPathRelease(glyph);
			}
		}
		free(glyphs);
		free(positions);
		free(indices);
	}
	return path;
}

// fillText() and strokeText(), at x, y, squeezed into a maxWidth when given;
// one that isn't more than 0 draws nothing.
- (void)drawText:(NSString *)text arguments:(NSArray<JSValue *> *)args
		stroke:(BOOL)stroke surface:(SGCanvasSurface *)surface {
	if (!surface || args.count < 3)
		return;
	double x = args[1].isNumber ? args[1].toDouble : NAN;
	double y = args[2].isNumber ? args[2].toDouble : NAN;
	if (!isfinite(x + y))
		return;
	SGCanvasState *state = surface.state;
	SGTextLine *line = [self layOut:text state:state];
	double squeeze = 1;
	if (args.count > 3) {
		double maxWidth = args[3].isNumber ? args[3].toDouble : NAN;
		if (!(maxWidth > 0))
			return;
		if (line.width > maxWidth)
			squeeze = maxWidth / line.width;
	}
	// Glyphs go up, the canvas down, from the anchor:
	CGAffineTransform placed = CGAffineTransformConcat(
			CGAffineTransformMakeScale(squeeze, -1),
			CGAffineTransformMakeTranslation(x - line.anchorX * squeeze,
				y + line.baseline));
	CGAffineTransform device = CGAffineTransformConcat(placed, state.transform);
	CGPathRef path = [self copyOutlinesOf:line transform:device];
	if (stroke) {
		[self stroke:path surface:surface];
	} else {
		[self fill:path evenOdd:NO color:state.fillColor paint:state.fillPaint
				surface:surface];
	}
	CGPathRelease(path);
}

// The measures of the text from its anchor, as canvas.rs gives them, with
// its grapheme clusters, 8 numbers each: their UTF-16 start and end, left,
// advance, ink left and right, top and bottom, heights above the anchor.
- (NSDictionary *)measureText:(NSString *)text
		surface:(SGCanvasSurface *)surface {
	if (!surface)
		return nil;
	SGTextLine *line = [self layOut:text state:surface.state];
	double offset = line.baseline, anchorX = line.anchorX;
	CGRect ink = CGRectNull;
	NSMutableData *clusters = [NSMutableData data];
	NSArray *runs = (__bridge NSArray *)CTLineGetGlyphRuns(line.line);
	enumerateClusters(line.text, ^(NSString *cluster, NSRange range) {
		double start = CTLineGetOffsetForStringIndex(line.line,
				range.location, NULL) + [line spacingBefore:range.location];
		double end = CTLineGetOffsetForStringIndex(line.line,
				NSMaxRange(range), NULL) + [line spacingBefore:NSMaxRange(range)];
		CGRect bounds = [self inkOf:runs range:range line:line];
		double values[8] = {
			range.location, NSMaxRange(range), MIN(start, end) - anchorX,
			fabs(end - start),
			CGRectIsNull(bounds) ? 0 : CGRectGetMinX(bounds) - anchorX,
			CGRectIsNull(bounds) ? 0 : CGRectGetMaxX(bounds) - anchorX,
			CGRectIsNull(bounds) ? 0 : CGRectGetMaxY(bounds) - offset,
			CGRectIsNull(bounds) ? 0 : CGRectGetMinY(bounds) - offset
		};
		[clusters appendBytes:values length:sizeof(values)];
	});
	ink = [self inkOf:runs range:NSMakeRange(0, line.text.length) line:line];
	BOOL hasInk = !CGRectIsNull(ink);
	JSContext *context = [JSContext currentContext];
	JSValue *list = [context[@"Float64Array"] constructWithArguments:
			@[@(clusters.length / sizeof(double))]];
	void *bytes = JSObjectGetTypedArrayBytesPtr(context.JSGlobalContextRef,
			(JSObjectRef)list.JSValueRef, NULL);
	if (bytes && clusters.length)
		memcpy(bytes, clusters.bytes, clusters.length);
	return @{
		@"width": @(line.width),
		@"actualBoundingBoxLeft": @(hasInk ? anchorX - CGRectGetMinX(ink) : 0),
		@"actualBoundingBoxRight": @(hasInk ? CGRectGetMaxX(ink) - anchorX : 0),
		@"actualBoundingBoxAscent": @(hasInk ? CGRectGetMaxY(ink) - offset
				: 0),
		@"actualBoundingBoxDescent": @(hasInk ? offset - CGRectGetMinY(ink)
				: 0),
		@"fontBoundingBoxAscent": @(line.ascent - offset),
		@"fontBoundingBoxDescent": @(line.descent + offset),
		@"emHeightAscent": @(line.emAscent - offset),
		@"emHeightDescent": @(line.emDescent + offset),
		@"hangingBaseline": @(line.hanging - offset),
		@"alphabeticBaseline": @(-offset),
		@"ideographicBaseline": @(line.ideographic - offset),
		@"clusters": list
	};
}

// The ink of the glyphs of the runs for the characters in `range`, in the
// line's coordinates, y up:
- (CGRect)inkOf:(NSArray *)runs range:(NSRange)range line:(SGTextLine *)line {
	CGRect ink = CGRectNull;
	for (id object in runs) {
		CTRunRef run = (__bridge CTRunRef)object;
		CTFontRef font = (CTFontRef)CFDictionaryGetValue(
				CTRunGetAttributes(run), kCTFontAttributeName);
		CFIndex count = CTRunGetGlyphCount(run);
		CGGlyph *glyphs = malloc(count * sizeof(CGGlyph));
		CGPoint *positions = malloc(count * sizeof(CGPoint));
		CFIndex *indices = malloc(count * sizeof(CFIndex));
		CGRect *rects = malloc(count * sizeof(CGRect));
		CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphs);
		CTRunGetPositions(run, CFRangeMake(0, 0), positions);
		CTRunGetStringIndices(run, CFRangeMake(0, 0), indices);
		CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationDefault,
				glyphs, rects, count);
		for (CFIndex i = 0; i < count; i++) {
			if (NSLocationInRange(indices[i], range)
					&& !CGRectIsEmpty(rects[i])) {
				ink = CGRectUnion(ink, CGRectOffset(rects[i], positions[i].x
						+ [line spacingBefore:indices[i]], positions[i].y));
			}
		}
		free(glyphs);
		free(positions);
		free(indices);
		free(rects);
	}
	return ink;
}

// The families of the font file's bytes, kept for the scripts; none when it's
// no font.
- (NSArray<NSString *> *)addFont:(JSValue *)bytes {
	// The fonts are the scripts', workers' too:
	@synchronized ([SGCanvas class]) {
		if (!bytes.isObject) {
			SGThrowErrorOfClass(@"TypeError", @"Invalid font: no bytes.");
			return nil;
		}
		NSData *data = SGDataOfValue(bytes);
		CFArrayRef descriptors = CTFontManagerCreateFontDescriptorsFromData(
				(__bridge CFDataRef)data);
		NSMutableArray *families = [NSMutableArray array];
		if (!addedFonts)
			addedFonts = [NSMutableDictionary dictionary];
		for (id descriptor in (__bridge NSArray *)descriptors) {
			NSString *family = CFBridgingRelease(CTFontDescriptorCopyAttribute(
					(__bridge CTFontDescriptorRef)descriptor,
					kCTFontFamilyNameAttribute));
			if (!family)
				continue;
			if (!addedFonts[family])
				addedFonts[family] = [NSMutableArray array];
			[addedFonts[family] addObject:descriptor];
			if (![families containsObject:family])
				[families addObject:family];
		}
		if (descriptors)
			CFRelease(descriptors);
		return families;
	}
}

- (void)setFontFace:(NSString *)name families:(NSArray<NSString *> *)families
		shown:(BOOL)shown {
	// The fonts are the scripts', workers' too:
	@synchronized ([SGCanvas class]) {
		if (!fontFaces)
			fontFaces = [NSMutableDictionary dictionary];
		if (shown)
			fontFaces[name.lowercaseString] = families;
		else
			[fontFaces removeObjectForKey:name.lowercaseString];
	}
}

@end
