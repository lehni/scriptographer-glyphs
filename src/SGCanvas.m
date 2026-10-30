//
//  SGCanvas.m
//  Scriptographer for Glyphs
//

#import "SGCanvas.h"
#import "SGCanvasInternal.h"
#import "SGCSSColor.h"
#import "SGCSSFont.h"
#import "SGSVGPath.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// The largest side of a canvas, and the most pixels it may have, as in
// VectorCraft; larger ones have no pixels:
static const double maxSide = 16384;
static const double maxArea = 16384.0 * 16384 / 4;

#pragma mark - Properties

// The context's properties and their initial values, as drawing.rs lists them:
static NSArray<NSString *> *propertyNames(void) {
	return @[
		@"fillStyle", @"strokeStyle", @"lineWidth", @"lineCap", @"lineJoin",
		@"miterLimit", @"lineDashOffset", @"globalAlpha",
		@"globalCompositeOperation", @"font", @"textAlign", @"textBaseline",
		@"direction", @"lang", @"imageSmoothingEnabled",
		@"imageSmoothingQuality", @"shadowBlur", @"shadowColor",
		@"shadowOffsetX", @"shadowOffsetY", @"filter", @"letterSpacing",
		@"wordSpacing", @"fontKerning", @"fontStretch", @"fontVariantCaps",
		@"textRendering"
	];
}

static NSDictionary<NSString *, id> *initialProperties(void) {
	return @{
		@"fillStyle": @"#000000", @"strokeStyle": @"#000000",
		@"lineWidth": @1, @"lineCap": @"butt", @"lineJoin": @"miter",
		@"miterLimit": @10, @"lineDashOffset": @0, @"globalAlpha": @1,
		@"globalCompositeOperation": @"source-over",
		@"font": @"10px sans-serif", @"textAlign": @"start",
		@"textBaseline": @"alphabetic", @"direction": @"inherit",
		@"lang": @"inherit", @"imageSmoothingEnabled": @YES,
		@"imageSmoothingQuality": @"low", @"shadowBlur": @0,
		@"shadowColor": @"rgba(0, 0, 0, 0)", @"shadowOffsetX": @0,
		@"shadowOffsetY": @0, @"filter": @"none", @"letterSpacing": @"0px",
		@"wordSpacing": @"0px", @"fontKerning": @"auto",
		@"fontStretch": @"normal", @"fontVariantCaps": @"normal",
		@"textRendering": @"auto"
	};
}

// The keywords the keyword properties take:
static NSDictionary<NSString *, NSArray *> *propertyKeywords(void) {
	static NSDictionary *keywords;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		keywords = @{
			@"lineCap": @[@"butt", @"round", @"square"],
			@"lineJoin": @[@"round", @"bevel", @"miter"],
			@"globalCompositeOperation": blendModes().allKeys,
			@"textAlign": @[@"start", @"end", @"left", @"right", @"center"],
			@"textBaseline": @[@"top", @"hanging", @"middle", @"alphabetic",
					@"ideographic", @"bottom"],
			@"direction": @[@"ltr", @"rtl", @"inherit"],
			@"imageSmoothingQuality": @[@"low", @"medium", @"high"],
			@"fontKerning": @[@"auto", @"normal", @"none"],
			@"fontStretch": @[@"ultra-condensed", @"extra-condensed",
					@"condensed", @"semi-condensed", @"normal",
					@"semi-expanded", @"expanded", @"extra-expanded",
					@"ultra-expanded"],
			@"fontVariantCaps": @[@"normal", @"small-caps",
					@"all-small-caps", @"petite-caps", @"all-petite-caps",
					@"unicase", @"titling-caps"],
			@"textRendering": @[@"auto", @"optimizeSpeed",
					@"optimizeLegibility", @"geometricPrecision"]
		};
	});
	return keywords;
}

// globalCompositeOperation as CoreGraphics composites:
NSDictionary<NSString *, NSNumber *> *blendModes(void) {
	static NSDictionary *modes;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		modes = @{
			@"source-over": @(kCGBlendModeNormal),
			@"normal": @(kCGBlendModeNormal),
			@"clear": @(kCGBlendModeClear), @"copy": @(kCGBlendModeCopy),
			@"source-in": @(kCGBlendModeSourceIn),
			@"source-out": @(kCGBlendModeSourceOut),
			@"source-atop": @(kCGBlendModeSourceAtop),
			@"destination-over": @(kCGBlendModeDestinationOver),
			@"destination-in": @(kCGBlendModeDestinationIn),
			@"destination-out": @(kCGBlendModeDestinationOut),
			@"destination-atop": @(kCGBlendModeDestinationAtop),
			@"xor": @(kCGBlendModeXOR),
			@"lighter": @(kCGBlendModePlusLighter),
			@"plus-lighter": @(kCGBlendModePlusLighter),
			@"multiply": @(kCGBlendModeMultiply),
			@"screen": @(kCGBlendModeScreen),
			@"overlay": @(kCGBlendModeOverlay),
			@"darken": @(kCGBlendModeDarken),
			@"lighten": @(kCGBlendModeLighten),
			@"color-dodge": @(kCGBlendModeColorDodge),
			@"color-burn": @(kCGBlendModeColorBurn),
			@"hard-light": @(kCGBlendModeHardLight),
			@"soft-light": @(kCGBlendModeSoftLight),
			@"difference": @(kCGBlendModeDifference),
			@"exclusion": @(kCGBlendModeExclusion),
			@"hue": @(kCGBlendModeHue),
			@"saturation": @(kCGBlendModeSaturation),
			@"color": @(kCGBlendModeColor),
			@"luminosity": @(kCGBlendModeLuminosity)
		};
	});
	return modes;
}

// The modes that change the canvas outside the shape too, which CoreGraphics
// does only for a transparency layer the size of the clip:
static BOOL isUnbounded(NSString *mode) {
	return [@[@"clear", @"copy", @"source-in", @"source-out",
			@"destination-in", @"destination-atop"] containsObject:mode];
}

// A number as the natives take it: only a JS number, NaN otherwise.
static double numberOf(JSValue *value) {
	return value.isNumber ? value.toDouble : NAN;
}

#pragma mark - State

@implementation SGCanvasState

- (instancetype)init {
	self = [super init];
	if (self) {
		_properties = [initialProperties() mutableCopy];
		_fillColor = _strokeColor = [SGCSSColor parse:@"#000000"];
		_shadowColor = [SGCSSColor parse:@"rgba(0, 0, 0, 0)"];
		_font = [SGCSSFont parse:@"10px sans-serif"];
		_transform = CGAffineTransformIdentity;
		_clips = @[];
		_dash = @[];
	}
	return self;
}

- (id)copyWithZone:(NSZone *)zone {
	SGCanvasState *copy = [[SGCanvasState alloc] init];
	copy.properties = [_properties mutableCopy];
	copy.fillColor = _fillColor;
	copy.strokeColor = _strokeColor;
	copy.fillPaint = _fillPaint;
	copy.strokePaint = _strokePaint;
	copy.shadowColor = _shadowColor;
	copy.font = _font;
	copy.transform = _transform;
	copy.clips = _clips;
	copy.dash = _dash;
	return copy;
}

- (double)number:(NSString *)name {
	return [_properties[name] doubleValue];
}

- (NSString *)text:(NSString *)name {
	return _properties[name];
}

@end

@implementation SGCanvasClip

- (void)dealloc {
	CGPathRelease(_path);
}

@end

@implementation SGCanvasPaint

- (void)dealloc {
	CGImageRelease(_image);
}

@end

@implementation SGCanvasPath

- (instancetype)init {
	self = [super init];
	if (self)
		_path = CGPathCreateMutable();
	return self;
}

- (void)dealloc {
	CGPathRelease(_path);
}

@end

#pragma mark - Surfaces

@implementation SGCanvasSurface

@synthesize context = _context;

- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height {
	self = [super init];
	if (self) {
		[self resizeTo:width height:height];
	}
	return self;
}

- (void)dealloc {
	CGContextRelease(_context);
	CGPathRelease(_path);
}

- (CGContextRef)context {
	return _viewContext ?: _context;
}

// Cleared to the new size, its state reset; one too large has no pixels:
- (void)resizeTo:(NSUInteger)width height:(NSUInteger)height {
	if (width > maxSide || height > maxSide
			|| (double)width * height > maxArea)
		width = height = 0;
	_width = width;
	_height = height;
	CGContextRelease(_context);
	_context = NULL;
	if (width && height) {
		CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
		_context = CGBitmapContextCreate(NULL, width, height, 8, width * 4,
				space, kCGImageAlphaPremultipliedLast
					| kCGBitmapByteOrder32Big);
		CGColorSpaceRelease(space);
		// Canvas coordinates: y points down.
		CGContextTranslateCTM(_context, 0, height);
		CGContextScaleCTM(_context, 1, -1);
	}
	[self reset];
}

// Its state and path as new, its pixels cleared, or black when opaque:
- (void)reset {
	_state = [[SGCanvasState alloc] init];
	_stack = [NSMutableArray array];
	CGPathRelease(_path);
	_path = CGPathCreateMutable();
	[self clear];
}

// Its own pixels; a view's are the view's:
- (void)clear {
	if (_context && !_viewContext) {
		memset(CGBitmapContextGetData(_context), 0,
				CGBitmapContextGetBytesPerRow(_context) * _height);
		[self makeOpaque];
	}
}

// An opaque canvas has no transparent pixels: what's drawn goes on black.
- (void)makeOpaque {
	if (_isOpaque && _context && !_viewContext) {
		CGContextSaveGState(_context);
		CGContextSetBlendMode(_context, kCGBlendModeDestinationOver);
		CGContextSetRGBFillColor(_context, 0, 0, 0, 1);
		CGContextFillRect(_context, CGRectMake(0, 0, _width, _height));
		CGContextRestoreGState(_context);
	}
}

- (CGImageRef)copyImage {
	return _context ? CGBitmapContextCreateImage(_context) : NULL;
}

@end

#pragma mark - SGCanvas

@implementation SGCanvas {
	// The slots of the surfaces, paths and paints, NSNull where free:
	NSMutableArray *_slots;
	// The surface made last, and the overlay's, with the view's context
	// while it draws:
	SGCanvasSurface *_lastSurface, *_viewSurface;
	CGContextRef _viewContext;
}

// Also while the view draws, when the overlay's canvas is made for it:
- (void)bindView {
	_viewSurface = _lastSurface;
	_viewSurface.viewContext = _viewContext;
	[_viewSurface reset];
}

- (void)drawView:(CGContextRef)context draw:(void (^)(void))draw {
	_viewContext = context;
	_viewSurface.viewContext = context;
	[_viewSurface reset];
	CGContextSaveGState(context);
	draw();
	CGContextRestoreGState(context);
	_viewSurface.viewContext = NULL;
	_viewContext = NULL;
}

- (instancetype)init {
	self = [super init];
	if (self)
		_slots = [NSMutableArray array];
	return self;
}

- (BOOL)isBusy {
	return NO;
}

- (void)stop {
	[_slots removeAllObjects];
}

#pragma mark - Slots

- (NSNumber *)keep:(id)object {
	NSUInteger index = [_slots indexOfObject:[NSNull null]];
	if (index == NSNotFound) {
		index = _slots.count;
		[_slots addObject:object];
	} else {
		_slots[index] = object;
	}
	return @(index);
}

- (id)slot:(id)number ofClass:(Class)class {
	if (![number isKindOfClass:[NSNumber class]])
		return nil;
	NSUInteger index = [number unsignedIntegerValue];
	id object = index < _slots.count ? _slots[index] : nil;
	return [object isKindOfClass:class] ? object : nil;
}

// The surface the method is called on, as `this`:
- (SGCanvasSurface *)thisSurface {
	SGCanvasSurface *surface = [self slot:@([[JSContext currentThis]
			toUInt32]) ofClass:[SGCanvasSurface class]];
	if (!surface)
		SGThrowError(@"the canvas is gone");
	return surface;
}

- (SGCanvasPath *)thisPath {
	SGCanvasPath *path = [self slot:@([[JSContext currentThis] toUInt32])
			ofClass:[SGCanvasPath class]];
	if (!path)
		SGThrowErrorOfClass(@"TypeError", @"The path is gone.");
	return path;
}

- (SGCanvasPaint *)thisPaint {
	return [self slot:@([[JSContext currentThis] toUInt32])
			ofClass:[SGCanvasPaint class]];
}

#pragma mark - Natives

- (NSDictionary *)natives {
	__weak SGCanvas *weakSelf = self;
	return @{
		@"properties": propertyNames(),
		@"create": ^NSNumber *(double width, double height) {
			SGCanvas *canvas = weakSelf;
			SGCanvasSurface *surface = [[SGCanvasSurface alloc]
					initWithWidth:(NSUInteger)width height:(NSUInteger)height];
			canvas->_lastSurface = surface;
			return [canvas keep:surface];
		},
		@"width": ^double {
			return [weakSelf thisSurface].width;
		},
		@"height": ^double {
			return [weakSelf thisSurface].height;
		},
		@"resize": ^(double width, double height) {
			SGCanvasSurface *surface = [weakSelf thisSurface];
			BOOL isOpaque = surface.isOpaque;
			[surface resizeTo:(NSUInteger)width height:(NSUInteger)height];
			surface.isOpaque = isOpaque;
			[surface clear];
		},
		@"encode": ^NSArray *(NSString *type, JSValue *quality) {
			return [weakSelf encode:[weakSelf thisSurface] type:type
					quality:quality];
		},
		@"setOpaque": ^{
			SGCanvasSurface *surface = [weakSelf thisSurface];
			surface.isOpaque = YES;
			[surface makeOpaque];
		},
		@"clear": ^{
			[[weakSelf thisSurface] clear];
		},
		@"get": ^id(NSString *name) {
			return [weakSelf get:name of:[weakSelf thisSurface]];
		},
		@"set": ^(NSString *name, JSValue *value, JSValue *paint) {
			[weakSelf set:name value:value paint:paint
					of:[weakSelf thisSurface]];
		},
		@"methods": [self contextMethods],
		@"pathMethods": [self pathMethods],
		@"createGradient": ^NSNumber *(NSString *kind) {
			return [weakSelf createGradient:kind
					arguments:[JSContext currentArguments]];
		},
		@"addColorStop": ^(double offset, JSValue *color) {
			[weakSelf addColorStop:offset color:color to:[weakSelf thisPaint]];
		},
		@"createPattern": ^NSNumber *(NSNumber *surface, JSValue *repetition) {
			return [weakSelf createPattern:surface repetition:repetition];
		},
		@"setPatternTransform": ^(double a, double b, double c, double d,
				double e, double f) {
			CGAffineTransform matrix = CGAffineTransformMake(a, b, c, d, e, f);
			if (isfinite(a + b + c + d + e + f))
				[weakSelf thisPaint].patternTransform = matrix;
		},
		@"createPath": ^NSNumber *(JSValue *source) {
			return [weakSelf createPath:source];
		},
		@"createImageBitmap": ^NSNumber *(JSValue *source) {
			return [weakSelf createImageBitmap:source
					arguments:[JSContext currentArguments]];
		},
		@"addFont": ^NSArray *(JSValue *bytes) {
			return [weakSelf addFont:bytes];
		},
		@"fontFamilies": ^id(NSString *font) {
			return [SGCSSFont parse:font].families ?: [NSNull null];
		},
		@"setFontFace": ^(NSString *name, NSArray *families, BOOL shown) {
			[weakSelf setFontFace:name families:families shown:shown];
		},
		@"release": ^(NSString *kind, NSNumber *slot) {
			SGCanvas *canvas = weakSelf;
			if (canvas && slot.unsignedIntegerValue < canvas->_slots.count)
				canvas->_slots[slot.unsignedIntegerValue] = [NSNull null];
		}
	};
}

#pragma mark - Getting and setting

- (id)get:(NSString *)name of:(SGCanvasSurface *)surface {
	if (!surface)
		return nil;
	id value = surface.state.properties[name];
	if (!value) {
		SGThrowErrorOfClass(@"TypeError", [NSString stringWithFormat:
				@"Unknown canvas property: '%@'.", name]);
	}
	return value;
}

// Sets the property as browsers do: a value it can't take changes nothing.
- (void)set:(NSString *)name value:(JSValue *)value paint:(JSValue *)paintSlot
		of:(SGCanvasSurface *)surface {
	if (!surface)
		return;
	SGCanvasState *state = surface.state;
	NSMutableDictionary *properties = state.properties;
	BOOL isFill = [name isEqualToString:@"fillStyle"];
	if (isFill || [name isEqualToString:@"strokeStyle"]) {
		SGCanvasPaint *paint = [self slot:paintSlot.isNumber
				? @(paintSlot.toUInt32) : nil ofClass:[SGCanvasPaint class]];
		SGCSSColor *color = paint ? nil : [SGCSSColor parse:value.toString];
		if (!paint && !color)
			return;
		properties[name] = paint ? value : color.serialized;
		if (isFill) {
			state.fillPaint = paint;
			state.fillColor = color;
		} else {
			state.strokePaint = paint;
			state.strokeColor = color;
		}
		return;
	}
	NSArray *keywords = propertyKeywords()[name];
	if (keywords) {
		if ([keywords containsObject:value.toString])
			properties[name] = value.toString;
	} else if ([@[@"lineWidth", @"miterLimit"] containsObject:name]) {
		double number = value.toDouble;
		if (isfinite(number) && number > 0)
			properties[name] = @(number);
	} else if ([@[@"lineDashOffset", @"shadowOffsetX", @"shadowOffsetY"]
			containsObject:name]) {
		double number = value.toDouble;
		if (isfinite(number))
			properties[name] = @(number);
	} else if ([name isEqualToString:@"shadowBlur"]) {
		double number = value.toDouble;
		if (isfinite(number) && number >= 0)
			properties[name] = @(number);
	} else if ([name isEqualToString:@"globalAlpha"]) {
		double number = value.toDouble;
		if (number >= 0 && number <= 1)
			properties[name] = @(number);
	} else if ([name isEqualToString:@"imageSmoothingEnabled"]) {
		properties[name] = @(value.toBool);
	} else if ([name isEqualToString:@"lang"]) {
		properties[name] = value.toString;
	} else if ([name isEqualToString:@"shadowColor"]) {
		SGCSSColor *color = [SGCSSColor parse:value.toString];
		if (color) {
			state.shadowColor = color;
			properties[name] = color.serialized;
		}
	} else if ([name isEqualToString:@"font"]) {
		SGCSSFont *font = [SGCSSFont parse:value.toString];
		if (font) {
			state.font = font;
			properties[name] = font.serialized;
		}
	} else if ([@[@"letterSpacing", @"wordSpacing"] containsObject:name]) {
		NSString *text = value.toString;
		if ([SGCSSFont lengthInPixels:text fontSize:state.font.size]) {
			properties[name] = [text stringByTrimmingCharactersInSet:
					NSCharacterSet.whitespaceCharacterSet].lowercaseString;
		}
	} else if ([name isEqualToString:@"filter"]) {
		NSString *text = value.toString;
		if ([self filterOf:text])
			properties[name] = text;
	} else {
		SGThrowErrorOfClass(@"TypeError", [NSString stringWithFormat:
				@"Unknown canvas property: '%@'.", name]);
	}
}

// The filter's functions, as drawing.rs takes them: `none`, `blur(…)` and
// `drop-shadow(…)` with lengths in px, and the color functions it accepts
// and doesn't draw; nil when it's invalid.
- (NSArray<NSArray *> *)filterOf:(NSString *)text {
	NSString *trimmed = [text stringByTrimmingCharactersInSet:
			NSCharacterSet.whitespaceCharacterSet];
	if ([trimmed isEqualToString:@"none"])
		return @[];
	NSMutableArray *functions = [NSMutableArray array];
	NSScanner *scanner = [NSScanner scannerWithString:trimmed];
	scanner.charactersToBeSkipped = NSCharacterSet.whitespaceCharacterSet;
	NSArray *ignored = @[@"brightness", @"contrast", @"grayscale",
			@"hue-rotate", @"invert", @"opacity", @"saturate", @"sepia", @"url"];
	while (!scanner.isAtEnd) {
		NSString *name = nil, *arguments = @"";
		if (![scanner scanUpToString:@"(" intoString:&name]
				|| ![scanner scanString:@"(" intoString:nil])
			return nil;
		// Up to the parenthesis that closes it, with what nests in it:
		NSUInteger depth = 1, start = scanner.scanLocation, at = start;
		for (; at < trimmed.length && depth; at++) {
			unichar c = [trimmed characterAtIndex:at];
			depth += c == '(' ? 1 : c == ')' ? -1 : 0;
		}
		if (depth)
			return nil;
		arguments = [trimmed substringWithRange:NSMakeRange(start,
				at - 1 - start)];
		scanner.scanLocation = at;
		name = [name stringByTrimmingCharactersInSet:
				NSCharacterSet.whitespaceCharacterSet].lowercaseString;
		NSArray *parts = [[arguments stringByTrimmingCharactersInSet:
				NSCharacterSet.whitespaceCharacterSet]
				componentsSeparatedByCharactersInSet:
					NSCharacterSet.whitespaceCharacterSet];
		parts = [parts filteredArrayUsingPredicate:
				[NSPredicate predicateWithFormat:@"length > 0"]];
		if ([name isEqualToString:@"blur"]) {
			NSNumber *radius = parts.count ? pixels(parts[0]) : @0;
			if (parts.count > 1 || !radius || radius.doubleValue < 0)
				return nil;
			[functions addObject:@[@"blur", radius]];
		} else if ([name isEqualToString:@"drop-shadow"]) {
			// Two or three lengths, with a color first or last:
			NSMutableArray *lengths = [NSMutableArray array];
			SGCSSColor *color = nil;
			NSString *rest = arguments;
			NSNumber *length;
			for (NSString *part in parts) {
				if ((length = pixels(part)) && !color) {
					[lengths addObject:length];
				} else if ((length = pixels(part)) && color) {
					return nil;
				}
			}
			NSString *colorText = [[parts filteredArrayUsingPredicate:
					[NSPredicate predicateWithBlock:^BOOL(NSString *part,
						NSDictionary *bindings) {
				return !pixels(part);
			}]] componentsJoinedByString:@" "];
			if (colorText.length) {
				color = [SGCSSColor parse:colorText];
				if (!color)
					return nil;
			}
			(void)rest;
			if (lengths.count < 2 || lengths.count > 3)
				return nil;
			[functions addObject:@[@"drop-shadow", lengths,
					color ?: [SGCSSColor parse:@"black"]]];
		} else if (![ignored containsObject:name]) {
			return nil;
		}
	}
	return functions.count || [trimmed isEqualToString:@"none"]
			? functions : nil;
}

// A length in px, or `0`:
static NSNumber *pixels(NSString *text) {
	if ([text isEqualToString:@"0"])
		return @0;
	if (![text hasSuffix:@"px"])
		return nil;
	NSScanner *scanner = [NSScanner scannerWithString:
			[text substringToIndex:text.length - 2]];
	double value;
	return [scanner scanDouble:&value] && scanner.isAtEnd && isfinite(value)
			? @(value) : nil;
}

#pragma mark - Drawing

- (void)applyClips:(SGCanvasState *)state to:(CGContextRef)context {
	for (SGCanvasClip *clip in state.clips) {
		// An empty path clips everything out:
		if (CGPathIsEmpty(clip.path)) {
			CGContextClipToRect(context, CGRectZero);
			continue;
		}
		CGContextAddPath(context, clip.path);
		if (clip.isEvenOdd)
			CGContextEOClip(context);
		else
			CGContextClip(context);
	}
}

// Draws with the context's compositing: the clips, globalAlpha, the
// composite operation, shadows and filters, around `draw`, which draws the
// shape in device coordinates.
- (void)composite:(SGCanvasSurface *)surface
		draw:(void (^)(CGContextRef context))draw {
	CGContextRef context = surface.context;
	if (!context)
		return;
	SGCanvasState *state = surface.state;
	NSString *mode = [state text:@"globalCompositeOperation"];
	SGCSSColor *shadow = state.shadowColor;
	double blur = [state number:@"shadowBlur"];
	CGSize offset = CGSizeMake([state number:@"shadowOffsetX"],
			-[state number:@"shadowOffsetY"]);
	BOOL hasShadow = shadow.alpha > 0 && (blur > 0 || offset.width
			|| offset.height);
	// Filters work on pixels, which a view has none of:
	NSArray *filter = surface.viewContext ? nil
			: [self filterOf:[state text:@"filter"]];
	CGContextSaveGState(context);
	[self applyClips:state to:context];
	CGContextSetAlpha(context, [state number:@"globalAlpha"]);
	CGContextSetBlendMode(context, blendModes()[mode].intValue);
	if (hasShadow) {
		CGColorRef color = [self colorOf:shadow];
		CGContextSetShadowWithColor(context, offset, blur, color);
		CGColorRelease(color);
	}
	BOOL hasLayer = hasShadow || isUnbounded(mode) || filter.count;
	if (hasLayer) {
		CGContextBeginTransparencyLayer(context, NULL);
		CGContextSetBlendMode(context, kCGBlendModeNormal);
	}
	if (filter.count)
		[self filter:filter surface:surface draw:draw];
	else
		draw(context);
	if (hasLayer)
		CGContextEndTransparencyLayer(context);
	CGContextRestoreGState(context);
	[surface makeOpaque];
}

// The filter's blurs and drop shadows, in device pixels, on what `draw`
// draws: drawn into a layer of its own, then blurred through CoreImage.
- (void)filter:(NSArray<NSArray *> *)functions surface:(SGCanvasSurface *)surface
		draw:(void (^)(CGContextRef context))draw {
	SGCanvasSurface *layer = [[SGCanvasSurface alloc]
			initWithWidth:surface.width height:surface.height];
	draw(layer.context);
	CGImageRef image = [layer copyImage];
	CIImage *result = [CIImage imageWithCGImage:image];
	CGRect extent = result.extent;
	for (NSArray *function in functions) {
		if ([function[0] isEqualToString:@"blur"]) {
			result = [result imageByApplyingGaussianBlurWithSigma:
					[function[1] doubleValue]];
		} else {
			NSArray *lengths = function[1];
			SGCSSColor *color = function[2];
			CIImage *shadow = [[result imageByApplyingFilter:@"CIColorMatrix"
					withInputParameters:@{
				@"inputRVector": [CIVector vectorWithX:0 Y:0 Z:0 W:0],
				@"inputGVector": [CIVector vectorWithX:0 Y:0 Z:0 W:0],
				@"inputBVector": [CIVector vectorWithX:0 Y:0 Z:0 W:0],
				@"inputAVector": [CIVector vectorWithX:0 Y:0 Z:0
					W:color.alpha],
				@"inputBiasVector": [CIVector vectorWithX:color.red
					Y:color.green Z:color.blue W:0]
			}] imageByApplyingTransform:CGAffineTransformMakeTranslation(
				[lengths[0] doubleValue], -[lengths[1] doubleValue])];
			if (lengths.count > 2) {
				shadow = [shadow imageByApplyingGaussianBlurWithSigma:
						[lengths[2] doubleValue] / 2];
			}
			result = [result imageByCompositingOverImage:shadow];
		}
	}
	CIContext *ci = [CIContext contextWithOptions:nil];
	CGImageRef filtered = [ci createCGImage:result fromRect:extent];
	CGContextRef context = surface.context;
	CGContextSaveGState(context);
	// The image's rows go top down, against the context's flip:
	CGContextTranslateCTM(context, 0, surface.height);
	CGContextScaleCTM(context, 1, -1);
	CGContextDrawImage(context, CGRectMake(0, 0, surface.width,
			surface.height), filtered);
	CGContextRestoreGState(context);
	CGImageRelease(filtered);
	CGImageRelease(image);
}

- (CGColorRef)colorOf:(SGCSSColor *)color {
	CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGFloat components[] = { color.red, color.green, color.blue, color.alpha };
	CGColorRef result = CGColorCreate(space, components);
	CGColorSpaceRelease(space);
	return result;
}

// Fills the path, in device coordinates, with a color or a paint in the
// coordinates of the current transform:
- (void)fill:(CGPathRef)path evenOdd:(BOOL)evenOdd color:(SGCSSColor *)color
		paint:(SGCanvasPaint *)paint surface:(SGCanvasSurface *)surface {
	CGAffineTransform transform = surface.state.transform;
	BOOL isSmooth = [surface.state.properties[@"imageSmoothingEnabled"]
			boolValue];
	[self composite:surface draw:^(CGContextRef context) {
		CGContextAddPath(context, path);
		if (!paint) {
			CGContextSetRGBFillColor(context, color.red, color.green,
					color.blue, color.alpha);
			if (evenOdd)
				CGContextEOFillPath(context);
			else
				CGContextFillPath(context);
			return;
		}
		if (evenOdd)
			CGContextEOClip(context);
		else
			CGContextClip(context);
		CGContextConcatCTM(context, transform);
		[self drawPaint:paint context:context smooth:isSmooth];
	}];
}

- (void)drawPaint:(SGCanvasPaint *)paint context:(CGContextRef)context
		smooth:(BOOL)isSmooth {
	if (paint.image) {
		[self drawPattern:paint context:context smooth:isSmooth];
		return;
	}
	CGGradientRef gradient = [self gradientOf:paint];
	if (!gradient)
		return;
	NSArray<NSNumber *> *v = paint.values;
	CGGradientDrawingOptions extend = kCGGradientDrawsBeforeStartLocation
			| kCGGradientDrawsAfterEndLocation;
	if ([paint.kind isEqualToString:@"linear"]) {
		CGPoint start = CGPointMake(v[0].doubleValue, v[1].doubleValue);
		CGPoint end = CGPointMake(v[2].doubleValue, v[3].doubleValue);
		// Between equal points it paints nothing:
		if (!CGPointEqualToPoint(start, end))
			CGContextDrawLinearGradient(context, gradient, start, end, extend);
	} else if ([paint.kind isEqualToString:@"radial"]) {
		CGPoint start = CGPointMake(v[0].doubleValue, v[1].doubleValue);
		CGPoint end = CGPointMake(v[3].doubleValue, v[4].doubleValue);
		if (!(CGPointEqualToPoint(start, end)
				&& v[2].doubleValue == v[5].doubleValue)) {
			CGContextDrawRadialGradient(context, gradient, start,
					v[2].doubleValue, end, v[5].doubleValue, extend);
		}
	} else if (@available(macOS 14, *)) {
		// Conic: clockwise from its angle, as the canvas turns.
		CGContextDrawConicGradient(context, gradient,
				CGPointMake(v[1].doubleValue, v[2].doubleValue),
				v[0].doubleValue);
	}
	CGGradientRelease(gradient);
}

// The gradient of the paint's stops, in their order, or NULL without any:
- (CGGradientRef)gradientOf:(SGCanvasPaint *)paint {
	NSArray *stops = [paint.stops sortedArrayUsingComparator:
			^NSComparisonResult(NSArray *a, NSArray *b) {
		return [a[0] compare:b[0]];
	}];
	if (!stops.count)
		return NULL;
	// Interpolated in Oklab once a stop is in modern syntax, as drawing.rs
	// does, through stops in between that CoreGraphics then joins in sRGB:
	BOOL isOklab = NO;
	for (NSArray *stop in stops)
		isOklab |= ![stop[1] isLegacy];
	NSUInteger steps = isOklab ? 32 : 1;
	NSUInteger count = (stops.count - 1) * steps + 1;
	CGFloat *components = malloc(count * 4 * sizeof(CGFloat));
	CGFloat *locations = malloc(count * sizeof(CGFloat));
	for (NSUInteger i = 0; i < count; i++) {
		NSUInteger segment = MIN(i / steps, stops.count - 1);
		double t = (double)(i - segment * steps) / steps;
		NSArray *from = stops[segment], *to = stops[MIN(segment + 1,
				stops.count - 1)];
		locations[i] = [from[0] doubleValue] + t * ([to[0] doubleValue]
				- [from[0] doubleValue]);
		mixColors(from[1], to[1], t, isOklab, components + i * 4);
	}
	CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGGradientRef gradient = CGGradientCreateWithColorComponents(space,
			components, locations, count);
	CGColorSpaceRelease(space);
	free(components);
	free(locations);
	return gradient;
}

static double toLinear(double c) {
	return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

static double fromLinear(double c) {
	return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055;
}

// sRGB to Oklab, and back:
static void toOklab(SGCSSColor *color, double *lab) {
	double r = toLinear(color.red), g = toLinear(color.green);
	double b = toLinear(color.blue);
	double l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
	double m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
	double s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
	lab[0] = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s;
	lab[1] = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
	lab[2] = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
}

static void fromOklab(const double *lab, CGFloat *rgb) {
	double l = lab[0] + 0.3963377774 * lab[1] + 0.2158037573 * lab[2];
	double m = lab[0] - 0.1055613458 * lab[1] - 0.0638541728 * lab[2];
	double s = lab[0] - 0.0894841775 * lab[1] - 1.2914855480 * lab[2];
	l = l * l * l;
	m = m * m * m;
	s = s * s * s;
	double linear[] = {
		4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
	};
	for (int i = 0; i < 3; i++)
		rgb[i] = MIN(MAX(fromLinear(linear[i]), 0), 1);
}

// The color `t` of the way from one to the other, in sRGB, or in Oklab,
// into `rgba`, its alpha in the same way:
static void mixColors(SGCSSColor *from, SGCSSColor *to, double t, BOOL isOklab,
		CGFloat *rgba) {
	if (isOklab) {
		double a[3], b[3], mixed[3];
		toOklab(from, a);
		toOklab(to, b);
		for (int i = 0; i < 3; i++)
			mixed[i] = a[i] + t * (b[i] - a[i]);
		fromOklab(mixed, rgba);
	} else {
		rgba[0] = from.red + t * (to.red - from.red);
		rgba[1] = from.green + t * (to.green - from.green);
		rgba[2] = from.blue + t * (to.blue - from.blue);
	}
	rgba[3] = from.alpha + t * (to.alpha - from.alpha);
}

// The pattern's image, repeated as asked, in its own transform:
- (void)drawPattern:(SGCanvasPaint *)paint context:(CGContextRef)context
		smooth:(BOOL)isSmooth {
	CGContextConcatCTM(context, paint.patternTransform);
	CGContextSetInterpolationQuality(context, isSmooth
			? kCGInterpolationDefault : kCGInterpolationNone);
	double width = CGImageGetWidth(paint.image);
	double height = CGImageGetHeight(paint.image);
	NSString *repetition = paint.repetition;
	BOOL repeatsX = [repetition isEqualToString:@"repeat"]
			|| [repetition isEqualToString:@"repeat-x"];
	BOOL repeatsY = [repetition isEqualToString:@"repeat"]
			|| [repetition isEqualToString:@"repeat-y"];
	// A non-repeating axis paints nothing outside the image:
	CGRect bounds = CGContextGetClipBoundingBox(context);
	CGRect band = CGRectMake(repeatsX ? CGRectGetMinX(bounds) : 0,
			repeatsY ? CGRectGetMinY(bounds) : 0,
			repeatsX ? CGRectGetWidth(bounds) : width,
			repeatsY ? CGRectGetHeight(bounds) : height);
	CGContextClipToRect(context, band);
	// Images go up, the canvas down:
	CGContextScaleCTM(context, 1, -1);
	if (repeatsX || repeatsY) {
		CGContextDrawTiledImage(context, CGRectMake(0, -height, width, height),
				paint.image);
	} else {
		CGContextDrawImage(context, CGRectMake(0, -height, width, height),
				paint.image);
	}
}

// The outline of the path's stroke, in device coordinates, as the current
// line style draws it in the coordinates of the current transform; NULL for
// a transform that collapses it.
- (CGPathRef)copyStrokeOf:(CGPathRef)path state:(SGCanvasState *)state {
	return [self copyStrokeOf:path state:state local:NO];
}

// With `local`, the outline stays in the coordinates of the transform.
- (CGPathRef)copyStrokeOf:(CGPathRef)path state:(SGCanvasState *)state
		local:(BOOL)isLocal {
	CGAffineTransform transform = state.transform;
	if (!isInvertible(transform))
		return NULL;
	CGAffineTransform inverse = CGAffineTransformInvert(transform);
	CGPathRef transformed = CGPathCreateCopyByTransformingPath(path, &inverse);
	CGPathRef local = copyPruned(transformed);
	CGPathRelease(transformed);
	NSArray<NSNumber *> *dash = state.dash;
	// More dashes than would ever show draw the line solid:
	if (dash.count && dash.count <= 1000000) {
		CGFloat *lengths = malloc(dash.count * sizeof(CGFloat));
		double total = 0;
		for (NSUInteger i = 0; i < dash.count; i++)
			total += lengths[i] = dash[i].doubleValue;
		if (total > 0) {
			CGPathRef dashed = CGPathCreateCopyByDashingPath(local, NULL,
					[state number:@"lineDashOffset"], lengths, dash.count);
			CGPathRelease(local);
			local = dashed;
		}
		free(lengths);
	}
	NSDictionary *caps = @{ @"butt": @(kCGLineCapButt),
			@"round": @(kCGLineCapRound), @"square": @(kCGLineCapSquare) };
	NSDictionary *joins = @{ @"miter": @(kCGLineJoinMiter),
			@"round": @(kCGLineJoinRound), @"bevel": @(kCGLineJoinBevel) };
	CGPathRef stroke = CGPathCreateCopyByStrokingPath(local, NULL,
			[state number:@"lineWidth"],
			[caps[[state text:@"lineCap"]] intValue],
			[joins[[state text:@"lineJoin"]] intValue],
			[state number:@"miterLimit"]);
	CGPathRelease(local);
	if (isLocal)
		return stroke;
	CGPathRef device = CGPathCreateCopyByTransformingPath(stroke, &transform);
	CGPathRelease(stroke);
	return device;
}

static BOOL isInvertible(CGAffineTransform t) {
	return fabs(t.a * t.d - t.b * t.c) >= 1e-12;
}

// The path without its zero-length segments, and without the subpaths that
// have none left, which the canvas doesn't stroke:
typedef struct {
	CGMutablePathRef path;
	CGPoint start, current;
	BOOL hasSegment;
} Pruning;

static void prune(void *info, const CGPathElement *element) {
	Pruning *pruning = info;
	CGPoint *p = element->points;
	switch (element->type) {
	case kCGPathElementMoveToPoint:
		pruning->start = pruning->current = p[0];
		pruning->hasSegment = NO;
		break;
	case kCGPathElementAddLineToPoint:
	case kCGPathElementAddQuadCurveToPoint:
	case kCGPathElementAddCurveToPoint: {
		int count = element->type == kCGPathElementAddLineToPoint ? 1
				: element->type == kCGPathElementAddQuadCurveToPoint ? 2 : 3;
		BOOL isZero = YES;
		for (int i = 0; i < count; i++)
			isZero &= CGPointEqualToPoint(p[i], pruning->current);
		if (isZero)
			break;
		if (!pruning->hasSegment) {
			CGPathMoveToPoint(pruning->path, NULL, pruning->current.x,
					pruning->current.y);
			pruning->hasSegment = YES;
		}
		if (count == 1)
			CGPathAddLineToPoint(pruning->path, NULL, p[0].x, p[0].y);
		else if (count == 2)
			CGPathAddQuadCurveToPoint(pruning->path, NULL, p[0].x, p[0].y,
					p[1].x, p[1].y);
		else
			CGPathAddCurveToPoint(pruning->path, NULL, p[0].x, p[0].y,
					p[1].x, p[1].y, p[2].x, p[2].y);
		pruning->current = p[count - 1];
		break;
	}
	case kCGPathElementCloseSubpath:
		if (pruning->hasSegment)
			CGPathCloseSubpath(pruning->path);
		pruning->current = pruning->start;
		pruning->hasSegment = NO;
		break;
	}
}

static CGPathRef copyPruned(CGPathRef path) {
	Pruning pruning = { CGPathCreateMutable(), CGPointZero, CGPointZero, NO };
	CGPathApply(path, &pruning, prune);
	return pruning.path;
}

- (void)stroke:(CGPathRef)path surface:(SGCanvasSurface *)surface {
	SGCanvasState *state = surface.state;
	CGPathRef stroke = [self copyStrokeOf:path state:state];
	if (stroke) {
		[self fill:stroke evenOdd:NO color:state.strokeColor
				paint:state.strokePaint surface:surface];
		CGPathRelease(stroke);
	}
}

#pragma mark - Context methods

// The path a method is given, by its slot, transformed into device
// coordinates, or the current path for null:
- (CGPathRef)copyPathOf:(JSValue *)slot surface:(SGCanvasSurface *)surface {
	if (!slot.isNumber)
		return CGPathCreateCopy(surface.path);
	SGCanvasPath *path = [self slot:@(slot.toUInt32)
			ofClass:[SGCanvasPath class]];
	CGAffineTransform transform = surface.state.transform;
	return path ? CGPathCreateCopyByTransformingPath(path.path, &transform)
			: NULL;
}

- (NSDictionary *)contextMethods {
	__weak SGCanvas *weakSelf = self;
	SGCanvasSurface *(^this)(void) = ^SGCanvasSurface * {
		return [weakSelf thisSurface];
	};
	NSMutableDictionary *methods = [[self pathBuilders:^CGMutablePathRef {
		return this().path;
	} transform:^CGAffineTransform {
		return this().state.transform;
	}] mutableCopy];
	[methods addEntriesFromDictionary:@{
		@"beginPath": ^{
			SGCanvasSurface *surface = this();
			CGPathRelease(surface.path);
			surface.path = CGPathCreateMutable();
		},
		@"fill": ^(JSValue *slot, NSString *rule) {
			SGCanvasSurface *surface = this();
			CGPathRef path = [weakSelf copyPathOf:slot surface:surface];
			if (path) {
				[weakSelf fill:path evenOdd:[rule isEqualToString:@"evenodd"]
						color:surface.state.fillColor
						paint:surface.state.fillPaint surface:surface];
				CGPathRelease(path);
			}
		},
		@"stroke": ^(JSValue *slot) {
			SGCanvasSurface *surface = this();
			CGPathRef path = [weakSelf copyPathOf:slot surface:surface];
			if (path) {
				[weakSelf stroke:path surface:surface];
				CGPathRelease(path);
			}
		},
		@"clip": ^(JSValue *slot, NSString *rule) {
			SGCanvasSurface *surface = this();
			CGPathRef path = [weakSelf copyPathOf:slot surface:surface];
			if (path) {
				SGCanvasClip *clip = [[SGCanvasClip alloc] init];
				clip.path = path;
				clip.isEvenOdd = [rule isEqualToString:@"evenodd"];
				surface.state.clips = [surface.state.clips
						arrayByAddingObject:clip];
			}
		},
		@"isPointInPath": ^BOOL(JSValue *slot, JSValue *x, JSValue *y,
				NSString *rule) {
			SGCanvasSurface *surface = this();
			CGPathRef path = [weakSelf copyPathOf:slot surface:surface];
			CGPoint point = CGPointMake(numberOf(x), numberOf(y));
			BOOL isInside = path && isfinite(point.x + point.y)
					&& isInvertible(surface.state.transform)
					&& [weakSelf path:path contains:point
						evenOdd:[rule isEqualToString:@"evenodd"]];
			CGPathRelease(path);
			return isInside;
		},
		@"isPointInStroke": ^BOOL(JSValue *slot, JSValue *x, JSValue *y) {
			SGCanvasSurface *surface = this();
			CGPathRef path = [weakSelf copyPathOf:slot surface:surface];
			// In the coordinates of the current transform, where the stroke
			// is made, so its rounding isn't scaled:
			CGAffineTransform transform = surface.state.transform;
			CGPathRef stroke = path && isInvertible(transform)
					? [weakSelf copyStrokeOf:path state:surface.state
						local:YES] : NULL;
			CGPoint point = CGPointApplyAffineTransform(CGPointMake(
					numberOf(x), numberOf(y)), CGAffineTransformInvert(transform));
			BOOL isInside = stroke && isfinite(point.x + point.y)
					&& [weakSelf path:stroke contains:point evenOdd:NO];
			CGPathRelease(path);
			CGPathRelease(stroke);
			return isInside;
		},
		@"fillRect": ^(JSValue *x, JSValue *y, JSValue *w, JSValue *h) {
			SGCanvasSurface *surface = this();
			CGPathRef path = [weakSelf copyRect:x :y :w :h surface:surface];
			if (path) {
				[weakSelf fill:path evenOdd:NO color:surface.state.fillColor
						paint:surface.state.fillPaint surface:surface];
				CGPathRelease(path);
			}
		},
		@"strokeRect": ^(JSValue *x, JSValue *y, JSValue *w, JSValue *h) {
			SGCanvasSurface *surface = this();
			CGPathRef path = [weakSelf copyStrokeRect:x :y :w :h
					surface:surface];
			if (path) {
				[weakSelf stroke:path surface:surface];
				CGPathRelease(path);
			}
		},
		// Inside the clips, whatever the alpha, composite operation and
		// shadow:
		@"clearRect": ^(JSValue *x, JSValue *y, JSValue *w, JSValue *h) {
			SGCanvasSurface *surface = this();
			CGPathRef path = [weakSelf copyRect:x :y :w :h surface:surface];
			CGContextRef context = surface.context;
			if (path && context) {
				CGContextSaveGState(context);
				[weakSelf applyClips:surface.state to:context];
				CGContextSetBlendMode(context, kCGBlendModeClear);
				CGContextAddPath(context, path);
				CGContextFillPath(context);
				CGContextRestoreGState(context);
				[surface makeOpaque];
			}
			CGPathRelease(path);
		},
		@"drawImage": ^(NSNumber *slot) {
			[weakSelf drawImage:slot arguments:[JSContext currentArguments]
					surface:this()];
		},
		@"getImageData": ^JSValue *(double x, double y, double w, double h) {
			return [weakSelf imageDataOf:this() x:x y:y width:w height:h];
		},
		@"putImageData": ^(JSValue *image) {
			[weakSelf putImageData:image arguments:[JSContext currentArguments]
					surface:this()];
		},
		@"translate": ^(JSValue *x, JSValue *y) {
			[weakSelf transform:this() by:CGAffineTransformMakeTranslation(
					numberOf(x), numberOf(y))];
		},
		@"rotate": ^(JSValue *angle) {
			[weakSelf transform:this() by:CGAffineTransformMakeRotation(
					numberOf(angle))];
		},
		@"scale": ^(JSValue *x, JSValue *y) {
			[weakSelf transform:this() by:CGAffineTransformMakeScale(
					numberOf(x), numberOf(y))];
		},
		@"transform": ^(JSValue *a, JSValue *b, JSValue *c, JSValue *d,
				JSValue *e, JSValue *f) {
			[weakSelf transform:this() by:CGAffineTransformMake(numberOf(a),
					numberOf(b), numberOf(c), numberOf(d), numberOf(e),
					numberOf(f))];
		},
		@"setTransform": ^{
			[weakSelf setTransform:this() arguments:
					[JSContext currentArguments]];
		},
		@"resetTransform": ^{
			this().state.transform = CGAffineTransformIdentity;
		},
		@"getTransform": ^JSValue * {
			CGAffineTransform t = this().state.transform;
			JSContext *context = [JSContext currentContext];
			JSValue *values = [context[@"Float64Array"] constructWithArguments:
					@[@[@(t.a), @(t.b), @(t.c), @(t.d), @(t.tx), @(t.ty)]]];
			return [context[@"DOMMatrix"] constructWithArguments:@[values]];
		},
		@"save": ^{
			SGCanvasSurface *surface = this();
			[surface.stack addObject:[surface.state copy]];
		},
		@"restore": ^{
			SGCanvasSurface *surface = this();
			if (surface.stack.count) {
				surface.state = surface.stack.lastObject;
				[surface.stack removeLastObject];
			}
		},
		@"reset": ^{
			[this() reset];
		},
		@"setLineDash": ^(JSValue *list) {
			[weakSelf setLineDash:list surface:this()];
		},
		@"getLineDash": ^NSArray * {
			return this().state.dash;
		},
		@"fillText": ^(NSString *text, JSValue *x, JSValue *y) {
			[weakSelf drawText:text arguments:[JSContext currentArguments]
					stroke:NO surface:this()];
		},
		@"strokeText": ^(NSString *text, JSValue *x, JSValue *y) {
			[weakSelf drawText:text arguments:[JSContext currentArguments]
					stroke:YES surface:this()];
		},
		@"measureText": ^NSDictionary *(NSString *text) {
			return [weakSelf measureText:text surface:this()];
		}
	}];
	return methods;
}

- (NSDictionary *)pathMethods {
	__weak SGCanvas *weakSelf = self;
	NSMutableDictionary *methods = [[self pathBuilders:^CGMutablePathRef {
		return [weakSelf thisPath].path;
	} transform:^CGAffineTransform {
		return CGAffineTransformIdentity;
	}] mutableCopy];
	methods[@"addPath"] = ^(JSValue *slot, JSValue *transform) {
		SGCanvasPath *path = [weakSelf thisPath];
		SGCanvasPath *other = [weakSelf slot:slot.isNumber ? @(slot.toUInt32)
				: nil ofClass:[SGCanvasPath class]];
		if (!other) {
			SGThrowErrorOfClass(@"TypeError",
					@"Invalid addPath(): not a Path2D.");
			return;
		}
		JSContext *context = [JSContext currentContext];
		JSValue *matrix = [context[@"DOMMatrix"] invokeMethod:@"fromMatrix"
				withArguments:transform.isUndefined ? @[] : @[transform]];
		if (context.exception)
			return;
		CGAffineTransform m = CGAffineTransformMake(
				[matrix[@"a"] toDouble], [matrix[@"b"] toDouble],
				[matrix[@"c"] toDouble], [matrix[@"d"] toDouble],
				[matrix[@"e"] toDouble], [matrix[@"f"] toDouble]);
		if (isfinite(m.a + m.b + m.c + m.d + m.tx + m.ty))
			CGPathAddPath(path.path, &m, other.path);
	};
	return methods;
}

// The methods that build paths, the context's in device coordinates through
// its transform, a Path2D's in its own:
- (NSDictionary *)pathBuilders:(CGMutablePathRef (^)(void))target
		transform:(CGAffineTransform (^)(void))getTransform {
	// A segment without a subpath starts one at its first point:
	void (^ensure)(CGMutablePathRef, CGAffineTransform *, double, double) =
			^(CGMutablePathRef path, CGAffineTransform *t, double x, double y) {
		if (CGPathIsEmpty(path))
			CGPathMoveToPoint(path, t, x, y);
	};
	BOOL (^finite)(NSArray<JSValue *> *) = ^BOOL(NSArray<JSValue *> *values) {
		for (JSValue *value in values) {
			if (!isfinite(numberOf(value)))
				return NO;
		}
		return YES;
	};
	return @{
		@"closePath": ^{
			CGMutablePathRef path = target();
			if (path && !CGPathIsEmpty(path))
				CGPathCloseSubpath(path);
		},
		@"moveTo": ^(JSValue *x, JSValue *y) {
			CGMutablePathRef path = target();
			CGAffineTransform t = getTransform();
			if (path && finite(@[x, y]))
				CGPathMoveToPoint(path, &t, x.toDouble, y.toDouble);
		},
		@"lineTo": ^(JSValue *x, JSValue *y) {
			CGMutablePathRef path = target();
			CGAffineTransform t = getTransform();
			if (path && finite(@[x, y])) {
				ensure(path, &t, x.toDouble, y.toDouble);
				CGPathAddLineToPoint(path, &t, x.toDouble, y.toDouble);
			}
		},
		@"quadraticCurveTo": ^(JSValue *cx, JSValue *cy, JSValue *x,
				JSValue *y) {
			CGMutablePathRef path = target();
			CGAffineTransform t = getTransform();
			if (path && finite(@[cx, cy, x, y])) {
				ensure(path, &t, cx.toDouble, cy.toDouble);
				CGPathAddQuadCurveToPoint(path, &t, cx.toDouble, cy.toDouble,
						x.toDouble, y.toDouble);
			}
		},
		@"bezierCurveTo": ^(JSValue *c1x, JSValue *c1y, JSValue *c2x,
				JSValue *c2y, JSValue *x, JSValue *y) {
			CGMutablePathRef path = target();
			CGAffineTransform t = getTransform();
			if (path && finite(@[c1x, c1y, c2x, c2y, x, y])) {
				ensure(path, &t, c1x.toDouble, c1y.toDouble);
				CGPathAddCurveToPoint(path, &t, c1x.toDouble, c1y.toDouble,
						c2x.toDouble, c2y.toDouble, x.toDouble, y.toDouble);
			}
		},
		@"rect": ^(JSValue *x, JSValue *y, JSValue *w, JSValue *h) {
			CGMutablePathRef path = target();
			CGAffineTransform t = getTransform();
			if (path && finite(@[x, y, w, h])) {
				double left = x.toDouble, top = y.toDouble;
				double right = left + w.toDouble, bottom = top + h.toDouble;
				CGPathMoveToPoint(path, &t, left, top);
				CGPathAddLineToPoint(path, &t, right, top);
				CGPathAddLineToPoint(path, &t, right, bottom);
				CGPathAddLineToPoint(path, &t, left, bottom);
				CGPathCloseSubpath(path);
				CGPathMoveToPoint(path, &t, left, top);
			}
		},
		@"roundRect": ^{
			NSArray<JSValue *> *args = [JSContext currentArguments];
			CGMutablePathRef path = target();
			CGAffineTransform t = getTransform();
			if (path && args.count >= 12 && finite(args))
				addRoundRect(path, &t, args);
		},
		@"arc": ^(JSValue *x, JSValue *y, JSValue *r, JSValue *start,
				JSValue *end, JSValue *ccw) {
			CGMutablePathRef path = target();
			CGAffineTransform t = getTransform();
			if (!path || !finite(@[x, y, r, start, end]))
				return;
			if (r.toDouble < 0) {
				SGThrowDOMException(@"IndexSizeError",
						@"Invalid arc(): the radius is negative.");
				return;
			}
			addEllipse(path, &t, x.toDouble, y.toDouble, r.toDouble,
					r.toDouble, 0, start.toDouble, end.toDouble,
					ccw.isBoolean && ccw.toBool);
		},
		@"ellipse": ^{
			NSArray<JSValue *> *args = [JSContext currentArguments];
			CGMutablePathRef path = target();
			CGAffineTransform t = getTransform();
			if (!path || args.count < 7
					|| !finite([args subarrayWithRange:NSMakeRange(0, 7)]))
				return;
			if (args[2].toDouble < 0 || args[3].toDouble < 0) {
				SGThrowDOMException(@"IndexSizeError",
						@"Invalid ellipse(): a radius is negative.");
				return;
			}
			addEllipse(path, &t, args[0].toDouble, args[1].toDouble,
					args[2].toDouble, args[3].toDouble, args[4].toDouble,
					args[5].toDouble, args[6].toDouble, args.count > 7
						&& args[7].isBoolean && args[7].toBool);
		},
		@"arcTo": ^(JSValue *x1, JSValue *y1, JSValue *x2, JSValue *y2,
				JSValue *r) {
			CGMutablePathRef path = target();
			CGAffineTransform t = getTransform();
			if (!path || !finite(@[x1, y1, x2, y2, r]))
				return;
			if (r.toDouble < 0) {
				SGThrowDOMException(@"IndexSizeError",
						@"Invalid arcTo(): the radius is negative.");
				return;
			}
			ensure(path, &t, x1.toDouble, y1.toDouble);
			CGPathAddArcToPoint(path, &t, x1.toDouble, y1.toDouble,
					x2.toDouble, y2.toDouble, r.toDouble);
		}
	};
}

// An arc of an ellipse, as the canvas sweeps it: a whole turn at most, and
// from its start to its end in the direction asked.
static void addEllipse(CGMutablePathRef path, CGAffineTransform *transform,
		double x, double y, double rx, double ry, double rotation,
		double start, double end, BOOL ccw) {
	// As browsers sweep it: an end behind the start goes round to it, a
	// whole turn when they're whole turns apart.
	double turn = 2 * M_PI, sweep = end - start;
	if (!ccw && sweep >= turn)
		sweep = turn;
	else if (ccw && -sweep >= turn)
		sweep = -turn;
	else if (!ccw && start > end)
		sweep = turn - fmod(start - end, turn);
	else if (ccw && end > start)
		sweep = -(turn - fmod(end - start, turn));
	CGAffineTransform matrix = CGAffineTransformScale(
			CGAffineTransformRotate(CGAffineTransformConcat(
				CGAffineTransformMakeTranslation(x, y), *transform), rotation),
			rx || ry ? MAX(rx, 1e-300) : 0, ry);
	// A radius of zero is a line to its center:
	if (rx == 0 || ry == 0) {
		CGAffineTransform t = *transform;
		if (CGPathIsEmpty(path))
			CGPathMoveToPoint(path, &t, x, y);
		else
			CGPathAddLineToPoint(path, &t, x, y);
		return;
	}
	CGPathAddRelativeArc(path, &matrix, 0, 0, 1, start, sweep);
}

// A rectangle with elliptical corners: the radii of its top-left, top-right,
// bottom-right and bottom-left corners as it shows, as canvas.js gives them.
static void addRoundRect(CGMutablePathRef path, CGAffineTransform *t,
		NSArray<JSValue *> *args) {
	double x = args[0].toDouble, y = args[1].toDouble;
	double w = args[2].toDouble, h = args[3].toDouble;
	// One negative side turns it the other way, which fill rules see:
	BOOL isReversed = (w < 0) != (h < 0);
	if (w < 0) {
		x += w;
		w = -w;
	}
	if (h < 0) {
		y += h;
		h = -h;
	}
	double r[8];
	for (int i = 0; i < 8; i++)
		r[i] = args[4 + i].toDouble;
	// Radii that overlap shrink, all by the same factor:
	double scale = 1;
	double sums[] = { r[0] + r[2], r[4] + r[6], r[1] + r[7], r[3] + r[5] };
	double sides[] = { w, w, h, h };
	for (int i = 0; i < 4; i++) {
		if (sums[i] > sides[i])
			scale = MIN(scale, sides[i] / sums[i]);
	}
	for (int i = 0; i < 8; i++)
		r[i] *= scale;
	// Clockwise from the top-left corner's end, each corner a quarter of an
	// ellipse:
	double corners[4][6] = {
		{ x + w - r[2], y + r[3], r[2], r[3], -M_PI_2, 0 },
		{ x + w - r[4], y + h - r[5], r[4], r[5], 0, M_PI_2 },
		{ x + r[6], y + h - r[7], r[6], r[7], M_PI_2, M_PI },
		{ x + r[0], y + r[1], r[0], r[1], M_PI, 3 * M_PI_2 }
	};
	if (isReversed)
		CGPathMoveToPoint(path, t, x, y + r[1]);
	else
		CGPathMoveToPoint(path, t, x + r[0], y);
	for (int n = 0; n < 4; n++) {
		double *c = corners[isReversed ? (6 - n) % 4 : n];
		double from = isReversed ? c[5] : c[4], to = isReversed ? c[4] : c[5];
		if (c[2] > 0 && c[3] > 0) {
			CGAffineTransform corner = CGAffineTransformScale(
					CGAffineTransformConcat(CGAffineTransformMakeTranslation(
						c[0], c[1]), *t), c[2], c[3]);
			CGPathAddRelativeArc(path, &corner, 0, 0, 1, from, to - from);
		} else {
			CGPathAddLineToPoint(path, t, c[0] + c[2] * cos(to),
					c[1] + c[3] * sin(to));
		}
	}
	CGPathCloseSubpath(path);
	CGPathMoveToPoint(path, t, x, y);
}

- (CGPathRef)copyRect:(JSValue *)x :(JSValue *)y :(JSValue *)w :(JSValue *)h
		surface:(SGCanvasSurface *)surface {
	double values[] = { numberOf(x), numberOf(y), numberOf(w), numberOf(h) };
	if (!surface || !isfinite(values[0] + values[1] + values[2] + values[3])
			|| !values[2] || !values[3])
		return NULL;
	CGAffineTransform t = surface.state.transform;
	CGMutablePathRef path = CGPathCreateMutable();
	CGPathAddRect(path, &t, CGRectMake(values[0], values[1], values[2],
			values[3]));
	return path;
}

// A rectangle to stroke: with one side of 0, a closed line, which shows its
// joins at its ends; with both, nothing.
- (CGPathRef)copyStrokeRect:(JSValue *)x :(JSValue *)y :(JSValue *)w
		:(JSValue *)h surface:(SGCanvasSurface *)surface {
	double values[] = { numberOf(x), numberOf(y), numberOf(w), numberOf(h) };
	if (!surface || !isfinite(values[0] + values[1] + values[2] + values[3])
			|| (!values[2] && !values[3]))
		return NULL;
	if (values[2] && values[3])
		return [self copyRect:x :y :w :h surface:surface];
	CGAffineTransform t = surface.state.transform;
	CGMutablePathRef path = CGPathCreateMutable();
	CGPathMoveToPoint(path, &t, values[0], values[1]);
	CGPathAddLineToPoint(path, &t, values[0] + values[2],
			values[1] + values[3]);
	CGPathCloseSubpath(path);
	return path;
}

// Points on its edge count as inside, and open subpaths close:
- (BOOL)path:(CGPathRef)path contains:(CGPoint)point evenOdd:(BOOL)evenOdd {
	if (CGPathContainsPoint(path, NULL, point, evenOdd))
		return YES;
	CGPathRef edge = CGPathCreateCopyByStrokingPath(path, NULL, 1e-4,
			kCGLineCapButt, kCGLineJoinMiter, 10);
	BOOL isOnEdge = CGPathContainsPoint(edge, NULL, point, NO);
	CGPathRelease(edge);
	return isOnEdge;
}

- (void)transform:(SGCanvasSurface *)surface by:(CGAffineTransform)matrix {
	CGAffineTransform t = CGAffineTransformConcat(matrix,
			surface.state.transform);
	if (isfinite(t.a + t.b + t.c + t.d + t.tx + t.ty))
		surface.state.transform = t;
}

// Six numbers, a DOMMatrix2DInit, or none for the identity:
- (void)setTransform:(SGCanvasSurface *)surface arguments:(NSArray *)args {
	CGAffineTransform t;
	if (args.count >= 6) {
		t = CGAffineTransformMake(numberOf(args[0]), numberOf(args[1]),
				numberOf(args[2]), numberOf(args[3]), numberOf(args[4]),
				numberOf(args[5]));
	} else if (args.count == 1) {
		JSContext *context = [JSContext currentContext];
		JSValue *m = [context[@"DOMMatrix"] invokeMethod:@"fromMatrix"
				withArguments:args];
		if (context.exception)
			return;
		t = CGAffineTransformMake([m[@"a"] toDouble], [m[@"b"] toDouble],
				[m[@"c"] toDouble], [m[@"d"] toDouble], [m[@"e"] toDouble],
				[m[@"f"] toDouble]);
	} else {
		t = CGAffineTransformIdentity;
	}
	if (isfinite(t.a + t.b + t.c + t.d + t.tx + t.ty))
		surface.state.transform = t;
}

// Up to 1024 numbers, all finite and none negative, or nothing changes; an
// odd count is doubled.
- (void)setLineDash:(JSValue *)list surface:(SGCanvasSurface *)surface {
	if (!list.isObject)
		return;
	NSUInteger length = MIN([list[@"length"] toUInt32], 1024);
	NSMutableArray *dash = [NSMutableArray array];
	for (NSUInteger i = 0; i < length; i++) {
		double value = list[i].toDouble;
		if (!isfinite(value) || value < 0)
			return;
		[dash addObject:@(value)];
	}
	if (dash.count % 2)
		[dash addObjectsFromArray:[dash copy]];
	surface.state.dash = dash;
}

#pragma mark - Images

// The 3, 5 or 9 argument forms, chosen by their count; negative sizes are
// made positive, and the source cut to the image.
- (void)drawImage:(NSNumber *)slot arguments:(NSArray<JSValue *> *)args
		surface:(SGCanvasSurface *)surface {
	SGCanvasSurface *source = [self slot:slot ofClass:[SGCanvasSurface class]];
	if (!source) {
		SGThrowErrorOfClass(@"TypeError", @"the image isn't a canvas");
		return;
	}
	double width = source.width, height = source.height;
	double n[8];
	NSUInteger count = args.count;
	for (NSUInteger i = 1; i < count && i <= 8; i++)
		n[i - 1] = numberOf(args[i]);
	CGRect from, to;
	if (count == 3) {
		from = CGRectMake(0, 0, width, height);
		to = CGRectMake(n[0], n[1], width, height);
	} else if (count == 5) {
		from = CGRectMake(0, 0, width, height);
		to = CGRectMake(n[0], n[1], n[2], n[3]);
	} else {
		from = CGRectMake(n[0], n[1], n[2], n[3]);
		to = CGRectMake(n[4], n[5], n[6], n[7]);
	}
	from = CGRectStandardize(from);
	to = CGRectStandardize(to);
	if (!isfinite(from.origin.x + from.origin.y + from.size.width
			+ from.size.height + to.origin.x + to.origin.y + to.size.width
			+ to.size.height) || !from.size.width || !from.size.height
			|| !to.size.width || !to.size.height)
		return;
	// The part of the source outside the image draws nothing:
	CGRect cut = CGRectIntersection(from, CGRectMake(0, 0, width, height));
	if (CGRectIsEmpty(cut))
		return;
	double sx = to.size.width / from.size.width;
	double sy = to.size.height / from.size.height;
	to = CGRectMake(to.origin.x + (cut.origin.x - from.origin.x) * sx,
			to.origin.y + (cut.origin.y - from.origin.y) * sy,
			cut.size.width * sx, cut.size.height * sy);
	CGImageRef image = [source copyImage];
	CGImageRef part = CGImageCreateWithImageInRect(image, cut);
	CGImageRelease(image);
	SGCanvasState *state = surface.state;
	CGAffineTransform transform = state.transform;
	BOOL isSmooth = [state.properties[@"imageSmoothingEnabled"] boolValue];
	[self composite:surface draw:^(CGContextRef context) {
		CGContextConcatCTM(context, transform);
		CGContextSetInterpolationQuality(context, isSmooth
				? kCGInterpolationDefault : kCGInterpolationNone);
		// Images go up, the canvas down:
		CGContextTranslateCTM(context, to.origin.x, to.origin.y
				+ to.size.height);
		CGContextScaleCTM(context, 1, -1);
		CGContextDrawImage(context, CGRectMake(0, 0, to.size.width,
				to.size.height), part);
	}];
	CGImageRelease(part);
}

// The pixels, not premultiplied, as an ImageData of the realm; off the
// canvas they're transparent black.
- (JSValue *)imageDataOf:(SGCanvasSurface *)surface x:(double)x y:(double)y
		width:(double)w height:(double)h {
	if (!surface)
		return nil;
	if (w < 0) {
		x += w;
		w = -w;
	}
	if (h < 0) {
		y += h;
		h = -h;
	}
	if (w > maxSide || h > maxSide) {
		SGThrowError(@"Invalid getImageData(): the area is too large.");
		return nil;
	}
	if (w * h > maxArea) {
		SGThrowErrorOfClass(@"RangeError",
				@"Invalid getImageData(): the area is too large.");
		return nil;
	}
	NSUInteger width = (NSUInteger)w, height = (NSUInteger)h;
	NSMutableData *data = [NSMutableData dataWithLength:width * height * 4];
	uint8_t *target = data.mutableBytes;
	const uint8_t *pixels = surface.context
			? CGBitmapContextGetData(surface.context) : NULL;
	size_t row = surface.context
			? CGBitmapContextGetBytesPerRow(surface.context) : 0;
	for (NSUInteger j = 0; j < height && pixels; j++) {
		long sy = (long)y + (long)j;
		if (sy < 0 || sy >= (long)surface.height)
			continue;
		for (NSUInteger i = 0; i < width; i++) {
			long sx = (long)x + (long)i;
			if (sx < 0 || sx >= (long)surface.width)
				continue;
			const uint8_t *p = pixels + sy * row + sx * 4;
			uint8_t *q = target + (j * width + i) * 4;
			unsigned a = p[3];
			for (int c = 0; c < 3; c++)
				q[c] = a ? (uint8_t)MIN(255, (p[c] * 255 + a / 2) / a) : 0;
			q[3] = (uint8_t)a;
		}
	}
	JSContext *context = [JSContext currentContext];
	JSValue *bytes = [context[@"Uint8ClampedArray"]
			constructWithArguments:@[SGBytesValue(context, data)]];
	return [context[@"ImageData"] constructWithArguments:@[bytes, @(width),
			@(height)]];
}

// Replaces pixels, premultiplied, without blending, clips, transform or
// alpha; the dirty rectangle may have negative sizes, and is cut to the
// image.
- (void)putImageData:(JSValue *)image arguments:(NSArray<JSValue *> *)args
		surface:(SGCanvasSurface *)surface {
	if (!surface.context)
		return;
	long width = [image[@"width"] toInt32], height = [image[@"height"] toInt32];
	NSData *data = SGDataOfValue(image[@"data"]);
	if (data.length < (NSUInteger)(width * height * 4))
		return;
	long dx = args[1].toInt32, dy = args[2].toInt32;
	long left = 0, top = 0, right = width, bottom = height;
	if (args.count >= 7) {
		long x = args[3].toInt32, y = args[4].toInt32;
		long w = args[5].toInt32, h = args[6].toInt32;
		if (w < 0) {
			x += w;
			w = -w;
		}
		if (h < 0) {
			y += h;
			h = -h;
		}
		left = MAX(x, 0);
		top = MAX(y, 0);
		right = MIN(x + w, width);
		bottom = MIN(y + h, height);
	}
	const uint8_t *source = data.bytes;
	uint8_t *pixels = CGBitmapContextGetData(surface.context);
	size_t row = CGBitmapContextGetBytesPerRow(surface.context);
	// A view has no pixels of its own:
	if (!pixels)
		return;
	for (long j = top; j < bottom; j++) {
		long ty = dy + j;
		if (ty < 0 || ty >= (long)surface.height)
			continue;
		for (long i = left; i < right; i++) {
			long tx = dx + i;
			if (tx < 0 || tx >= (long)surface.width)
				continue;
			const uint8_t *p = source + (j * width + i) * 4;
			uint8_t *q = pixels + ty * row + tx * 4;
			unsigned a = p[3];
			for (int c = 0; c < 3; c++)
				q[c] = (uint8_t)((p[c] * a + 127) / 255);
			q[3] = (uint8_t)a;
		}
	}
	[surface makeOpaque];
}

// A PNG, or a JPEG for `image/jpeg`, on black, at the quality asked:
- (NSArray *)encode:(SGCanvasSurface *)surface type:(NSString *)type
		quality:(JSValue *)quality {
	if (!surface)
		return nil;
	BOOL isJPEG = [type.lowercaseString isEqualToString:@"image/jpeg"];
	CGImageRef image = [surface copyImage];
	if (isJPEG && image) {
		CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
		CGContextRef context = CGBitmapContextCreate(NULL, surface.width,
				surface.height, 8, surface.width * 4, space,
				(CGBitmapInfo)kCGImageAlphaNoneSkipLast);
		CGColorSpaceRelease(space);
		CGContextSetRGBFillColor(context, 0, 0, 0, 1);
		CGContextFillRect(context, CGRectMake(0, 0, surface.width,
				surface.height));
		CGContextDrawImage(context, CGRectMake(0, 0, surface.width,
				surface.height), image);
		CGImageRelease(image);
		image = CGBitmapContextCreateImage(context);
		CGContextRelease(context);
	}
	NSMutableData *data = [NSMutableData data];
	CGImageDestinationRef destination = CGImageDestinationCreateWithData(
			(__bridge CFMutableDataRef)data, (__bridge CFStringRef)(isJPEG
				? UTTypeJPEG : UTTypePNG).identifier, 1, NULL);
	double level = quality.isNumber && quality.toDouble >= 0
			&& quality.toDouble <= 1 ? quality.toDouble : 0.92;
	if (destination && image) {
		CGImageDestinationAddImage(destination, image, (__bridge
				CFDictionaryRef)@{ (__bridge NSString *)
					kCGImageDestinationLossyCompressionQuality: @(level) });
		CGImageDestinationFinalize(destination);
	}
	if (destination)
		CFRelease(destination);
	CGImageRelease(image);
	return @[SGBytesValue([JSContext currentContext], data),
			isJPEG ? @"image/jpeg" : @"image/png"];
}

#pragma mark - Paints, paths and bitmaps

// Linear: 4 numbers, radial: 6, conic: 3; all of them finite.
- (NSNumber *)createGradient:(NSString *)kind
		arguments:(NSArray<JSValue *> *)args {
	NSUInteger count = [kind isEqualToString:@"linear"] ? 4
			: [kind isEqualToString:@"radial"] ? 6 : 3;
	NSMutableArray *values = [NSMutableArray array];
	for (NSUInteger i = 1; i <= count; i++) {
		double value = i < args.count ? numberOf(args[i]) : NAN;
		if (!isfinite(value)) {
			SGThrowErrorOfClass(@"TypeError",
					@"Invalid gradient: its numbers must be finite.");
			return nil;
		}
		[values addObject:@(value)];
	}
	if (count == 6 && ([values[2] doubleValue] < 0
			|| [values[5] doubleValue] < 0)) {
		SGThrowDOMException(@"IndexSizeError",
				@"Invalid radial gradient: a radius is negative.");
		return nil;
	}
	SGCanvasPaint *paint = [[SGCanvasPaint alloc] init];
	paint.kind = count == 4 ? @"linear" : count == 6 ? @"radial" : @"conic";
	paint.values = values;
	paint.stops = [NSMutableArray array];
	return [self keep:paint];
}

- (void)addColorStop:(double)offset color:(JSValue *)value
		to:(SGCanvasPaint *)paint {
	if (offset < 0 || offset > 1) {
		SGThrowDOMException(@"IndexSizeError",
				@"Invalid color stop: its offset isn't between 0 and 1.");
		return;
	}
	SGCSSColor *color = [SGCSSColor parse:value.toString];
	if (!color) {
		SGThrowDOMException(@"SyntaxError", [NSString stringWithFormat:
				@"Invalid color: '%@'.", value.toString]);
		return;
	}
	[paint.stops addObject:@[@(offset), color]];
}

// The image as it is now, repeated as asked: null, undefined and '' repeat.
- (NSNumber *)createPattern:(NSNumber *)slot repetition:(JSValue *)value {
	// As WebIDL converts it, null to '', undefined to 'undefined':
	NSString *repetition = value.isNull ? @"" : value.toString;
	if (!repetition.length)
		repetition = @"repeat";
	if (![@[@"repeat", @"repeat-x", @"repeat-y", @"no-repeat"]
			containsObject:repetition]) {
		SGThrowDOMException(@"SyntaxError", [NSString stringWithFormat:
				@"Invalid pattern repetition: '%@'.", repetition]);
		return nil;
	}
	SGCanvasSurface *surface = [self slot:slot ofClass:[SGCanvasSurface class]];
	SGCanvasPaint *paint = [[SGCanvasPaint alloc] init];
	paint.kind = @"pattern";
	paint.image = [surface copyImage];
	paint.repetition = repetition;
	paint.patternTransform = CGAffineTransformIdentity;
	return [self keep:paint];
}

// Empty, a copy of another path, or SVG path data:
- (NSNumber *)createPath:(JSValue *)source {
	SGCanvasPath *path = [[SGCanvasPath alloc] init];
	if (source.isNumber) {
		SGCanvasPath *other = [self slot:@(source.toUInt32)
				ofClass:[SGCanvasPath class]];
		if (other)
			CGPathAddPath(path.path, NULL, other.path);
	} else if (source.isString) {
		SGAddSVGPath(path.path, source.toString);
	}
	return [self keep:path];
}

// A bitmap of a surface, an ImageData or an image file's bytes, cropped,
// flipped and resized as asked.
- (NSNumber *)createImageBitmap:(JSValue *)source
		arguments:(NSArray<JSValue *> *)args {
	CGImageRef image = NULL;
	if (source.isNumber) {
		SGCanvasSurface *surface = [self slot:@(source.toUInt32)
				ofClass:[SGCanvasSurface class]];
		image = [surface copyImage];
	} else if ([source isInstanceOf:[JSContext currentContext][@"Uint8Array"]]) {
		NSData *bytes = SGDataOfValue(source);
		CGImageSourceRef reader = CGImageSourceCreateWithData(
				(__bridge CFDataRef)bytes, NULL);
		image = reader ? CGImageSourceCreateImageAtIndex(reader, 0, NULL)
				: NULL;
		if (reader)
			CFRelease(reader);
		if (!image || CGImageGetWidth(image) > maxSide
				|| CGImageGetHeight(image) > maxSide) {
			CGImageRelease(image);
			SGThrowDOMException(@"InvalidStateError",
					@"Invalid image: it can't be decoded.");
			return nil;
		}
	} else if (source.isObject && source[@"data"].isObject) {
		image = [self copyImageOfImageData:source];
		if (!image) {
			SGThrowErrorOfClass(@"TypeError", @"Invalid ImageData.");
			return nil;
		}
	}
	if (!image) {
		SGThrowErrorOfClass(@"TypeError", @"Invalid image source.");
		return nil;
	}
	double width = CGImageGetWidth(image), height = CGImageGetHeight(image);
	CGRect crop = CGRectMake(0, 0, width, height);
	NSUInteger next = 1;
	if (args.count > 4 && args[1].isNumber) {
		crop = CGRectMake(numberOf(args[1]), numberOf(args[2]),
				numberOf(args[3]), numberOf(args[4]));
		next = 5;
		if (!crop.size.width || !crop.size.height
				|| isnan(crop.size.width) || isnan(crop.size.height)) {
			CGImageRelease(image);
			SGThrowErrorOfClass(@"RangeError",
					@"Invalid createImageBitmap(): the size is 0.");
			return nil;
		}
		crop = CGRectStandardize(crop);
	}
	JSValue *options = args.count > next ? args[next] : nil;
	double outWidth = crop.size.width, outHeight = crop.size.height;
	JSValue *resizeWidth = options.isObject ? options[@"resizeWidth"] : nil;
	JSValue *resizeHeight = options.isObject ? options[@"resizeHeight"] : nil;
	BOOL hasWidth = resizeWidth.isNumber, hasHeight = resizeHeight.isNumber;
	if (hasWidth)
		outWidth = resizeWidth.toDouble;
	if (hasHeight)
		outHeight = resizeHeight.toDouble;
	if (hasWidth && !hasHeight)
		outHeight = ceil(crop.size.height * outWidth / crop.size.width);
	if (hasHeight && !hasWidth)
		outWidth = ceil(crop.size.width * outHeight / crop.size.height);
	if (outWidth < 1 || outHeight < 1 || outWidth > maxSide
			|| outHeight > maxSide || outWidth * outHeight > maxArea) {
		CGImageRelease(image);
		SGThrowDOMException(@"InvalidStateError",
				@"Invalid createImageBitmap(): the bitmap is too large.");
		return nil;
	}
	SGCanvasSurface *bitmap = [[SGCanvasSurface alloc]
			initWithWidth:(NSUInteger)outWidth height:(NSUInteger)outHeight];
	CGContextRef context = bitmap.context;
	BOOL isFlipped = options.isObject
			&& [options[@"imageOrientation"].toString isEqualToString:@"flipY"];
	BOOL isPixelated = options.isObject
			&& [options[@"resizeQuality"].toString isEqualToString:@"pixelated"];
	CGContextSaveGState(context);
	CGContextSetInterpolationQuality(context, isPixelated
			? kCGInterpolationNone : kCGInterpolationDefault);
	// In canvas coordinates, the crop's area scaled to the bitmap, with the
	// image's rows going up:
	CGContextScaleCTM(context, outWidth / crop.size.width,
			outHeight / crop.size.height);
	CGContextTranslateCTM(context, -crop.origin.x, -crop.origin.y);
	if (!isFlipped) {
		CGContextTranslateCTM(context, 0, height);
		CGContextScaleCTM(context, 1, -1);
	} else {
		CGContextTranslateCTM(context, 0, crop.origin.y * 2 + crop.size.height
				- height);
	}
	CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
	CGContextRestoreGState(context);
	CGImageRelease(image);
	return [self keep:bitmap];
}

- (CGImageRef)copyImageOfImageData:(JSValue *)image {
	long width = [image[@"width"] toInt32], height = [image[@"height"] toInt32];
	NSData *data = SGDataOfValue(image[@"data"]);
	if (width <= 0 || height <= 0
			|| data.length < (NSUInteger)(width * height * 4))
		return NULL;
	CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGDataProviderRef provider = CGDataProviderCreateWithCFData(
			(__bridge CFDataRef)data);
	CGImageRef result = CGImageCreate(width, height, 8, 32, width * 4, space,
			kCGImageAlphaLast | kCGBitmapByteOrder32Big, provider, NULL, NO,
			kCGRenderingIntentDefault);
	CGDataProviderRelease(provider);
	CGColorSpaceRelease(space);
	return result;
}

@end
