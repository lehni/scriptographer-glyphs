//
//  SGCSSFont.m
//  Scriptographer for Glyphs
//

#import "SGCSSFont.h"
#import <xlocale.h>

// The font sizes CSS names, in pixels.
static const struct { const char *name; double pixels; } sizes[] = {
	{ "xx-small", 9 }, { "x-small", 10 }, { "small", 13 }, { "medium", 16 },
	{ "large", 18 }, { "x-large", 24 }, { "xx-large", 32 }, { "xxx-large", 48 }
};

typedef struct { const char *unit; double scale; } Unit;

#pragma mark - Text

static NSCharacterSet *spaces(void) {
	return NSCharacterSet.whitespaceAndNewlineCharacterSet;
}

static NSString *trimmed(NSString *text) {
	return [text stringByTrimmingCharactersInSet:spaces()];
}

static NSString *trimmedStart(NSString *text) {
	NSUInteger start = [text rangeOfCharacterFromSet:spaces().invertedSet]
			.location;
	return start == NSNotFound ? @"" : [text substringFromIndex:start];
}

// Only ASCII's letters, as CSS's keywords are compared:
static NSString *lowercased(NSString *text) {
	NSMutableString *lower = [text mutableCopy];
	for (NSUInteger i = 0; i < lower.length; i++) {
		unichar c = [lower characterAtIndex:i];
		if (c >= 'A' && c <= 'Z')
			[lower replaceCharactersInRange:NSMakeRange(i, 1)
					withString:[NSString stringWithFormat:@"%C",
						(unichar)(c + 32)]];
	}
	return lower;
}

// What follows the next word, nil when nothing does.
static NSString *skipWord(NSString *text) {
	NSUInteger end = [text rangeOfCharacterFromSet:spaces()].location;
	return end == NSNotFound ? nil : [text substringFromIndex:end];
}

typedef uint32_t Char;

// The code points of `text`, a lone surrogate as U+FFFD, as Rust's chars.
static NSMutableData *codePointsOf(NSString *text) {
	NSMutableData *data = [NSMutableData data];
	NSUInteger length = text.length;
	for (NSUInteger i = 0; i < length; i++) {
		unichar c = [text characterAtIndex:i];
		Char point = c;
		if (CFStringIsSurrogateHighCharacter(c) && i + 1 < length
				&& CFStringIsSurrogateLowCharacter(
					[text characterAtIndex:i + 1])) {
			point = CFStringGetLongCharacterForSurrogatePair(c,
					[text characterAtIndex:++i]);
		} else if (CFStringIsSurrogateHighCharacter(c)
				|| CFStringIsSurrogateLowCharacter(c)) {
			point = 0xfffd;
		}
		[data appendBytes:&point length:sizeof(point)];
	}
	return data;
}

static void append(NSMutableString *text, Char c) {
	UniChar pair[2];
	BOOL isPair = CFStringGetSurrogatePairForLongCharacter(c, pair);
	CFStringAppendCharacters((__bridge CFMutableStringRef)text, pair,
			isPair ? 2 : 1);
}

#pragma mark - Numbers

// `text` as Rust's `f64::from_str` reads it: signs, `inf`, `nan`, exponents
// and bare points, but none of strtod's whitespace or hexadecimal. A NULL
// locale is C's.
static BOOL parseNumber(NSString *text, double *value) {
	const char *chars = [lowercased(text) UTF8String];
	// Not ASCII, or cut short by a NUL:
	if (strlen(chars) != text.length)
		return NO;
	const char *c = chars;
	if (*c == '+' || *c == '-')
		c++;
	if (!strcmp(c, "inf") || !strcmp(c, "infinity") || !strcmp(c, "nan")) {
		*value = strtod_l(chars, NULL, NULL);
		return YES;
	}
	int digits = 0;
	for (; *c >= '0' && *c <= '9'; c++)
		digits++;
	if (*c == '.')
		for (c++; *c >= '0' && *c <= '9'; c++)
			digits++;
	if (!digits)
		return NO;
	if (*c == 'e') {
		c++;
		if (*c == '+' || *c == '-')
			c++;
		if (!(*c >= '0' && *c <= '9'))
			return NO;
		while (*c >= '0' && *c <= '9')
			c++;
	}
	if (*c)
		return NO;
	*value = strtod_l(chars, NULL, NULL);
	return YES;
}

// The first of `units` that `lower` is a finite number of, in pixels.
static NSNumber *pixelsOf(NSString *lower, const Unit *units, size_t count,
		BOOL isNegativeAllowed) {
	for (size_t i = 0; i < count; i++) {
		NSString *unit = @(units[i].unit);
		double number;
		if ([lower hasSuffix:unit] && parseNumber([lower substringToIndex:
					lower.length - unit.length], &number)
				&& isfinite(number) && (isNegativeAllowed || number >= 0))
			return @(number * units[i].scale);
	}
	return nil;
}

// `value` as Rust's `Display` writes it: the fewest digits that read back as
// it, never with an exponent.
static NSString *displayOf(double value) {
	if (value == 0)
		return signbit(value) ? @"-0" : @"0";
	char buffer[32];
	for (int precision = 1; precision <= 17; precision++) {
		snprintf_l(buffer, sizeof buffer, NULL, "%.*e", precision - 1, value);
		if (strtod_l(buffer, NULL, NULL) == value)
			break;
	}
	// `[-]d.ddde±x` written out:
	NSMutableString *digits = [NSMutableString string];
	char *c = buffer;
	BOOL isNegative = *c == '-';
	if (isNegative)
		c++;
	for (; *c != 'e'; c++)
		if (*c != '.')
			[digits appendFormat:@"%c", *c];
	NSInteger point = strtol(c + 1, NULL, 10) + 1;
	NSInteger count = digits.length;
	NSString *text;
	if (point <= 0)
		text = [NSString stringWithFormat:@"0.%@%@",
				[@"" stringByPaddingToLength:-point withString:@"0"
					startingAtIndex:0], digits];
	else if (point >= count)
		text = [digits stringByPaddingToLength:point withString:@"0"
				startingAtIndex:0];
	else
		text = [NSString stringWithFormat:@"%@.%@",
				[digits substringToIndex:point],
				[digits substringFromIndex:point]];
	return isNegative ? [@"-" stringByAppendingString:text] : text;
}

#pragma mark - SGCSSFont

@implementation SGCSSFont

- (instancetype)init {
	self = [super init];
	if (self) {
		_style = _stretch = @"normal";
		_weight = 400;
		_size = 10;
		_families = @[@"sans-serif"];
	}
	return self;
}

+ (SGCSSFont *)parse:(NSString *)text {
	NSArray *stretches = @[@"ultra-condensed", @"extra-condensed",
			@"condensed", @"semi-condensed", @"semi-expanded", @"expanded",
			@"extra-expanded", @"ultra-expanded"];
	SGCSSFont *font = [[SGCSSFont alloc] init];
	BOOL hasStyle = NO, hasVariant = NO, hasWeight = NO, hasStretch = NO;
	NSString *rest = trimmed(text);
	for (;;) {
		NSUInteger end = [rest rangeOfCharacterFromSet:spaces()].location;
		if (end == NSNotFound)
			end = rest.length;
		NSString *word = [rest substringToIndex:end];
		NSString *after = [rest substringFromIndex:end];
		NSString *lower = lowercased(word);
		double number;
		// Each at most once, `normal` for any of them:
		if ([lower isEqualToString:@"normal"]) {
		} else if (!hasStyle && ([lower isEqualToString:@"italic"]
				|| [lower isEqualToString:@"oblique"])) {
			hasStyle = YES;
			font->_style = lower;
		} else if (!hasVariant && [lower isEqualToString:@"small-caps"]) {
			hasVariant = YES;
			font->_smallCaps = YES;
		} else if (!hasWeight && [@[@"bold", @"bolder", @"lighter"]
				containsObject:lower]) {
			hasWeight = YES;
			font->_weight = [lower isEqualToString:@"lighter"] ? 100 : 700;
		} else if (!hasWeight && parseNumber(lower, &number)
				&& number >= 1 && number <= 1000) {
			hasWeight = YES;
			font->_weight = (NSInteger)round(number);
		} else if (!hasStretch && [stretches containsObject:lower]) {
			hasStretch = YES;
			font->_stretch = lower;
		} else {
			// The size, with a line height (`12px/2`, `12px / 2`) that a
			// canvas leaves out:
			NSString *size = word;
			NSRange slash = [word rangeOfString:@"/"];
			if (slash.location != NSNotFound) {
				size = [word substringToIndex:slash.location];
				if (NSMaxRange(slash) == word.length)
					after = skipWord(trimmedStart(after));
			} else if ([trimmedStart(after) hasPrefix:@"/"]) {
				after = skipWord(trimmedStart(
						[trimmedStart(after) substringFromIndex:1]));
			}
			NSNumber *pixels = after ? [self sizeOf:size] : nil;
			NSArray *families = pixels ? [self familiesOf:after] : nil;
			if (!families)
				return nil;
			font->_size = pixels.doubleValue;
			font->_families = families;
			return font;
		}
		rest = trimmedStart(after);
		if (!rest.length)
			return nil;
	}
}

// A CSS font size in pixels: absolute lengths, names, and `em`, `rem` and `%`
// of the default font's 10px.
+ (NSNumber *)sizeOf:(NSString *)size {
	NSString *lower = lowercased(size);
	for (size_t i = 0; i < sizeof sizes / sizeof *sizes; i++) {
		if ([lower isEqualToString:@(sizes[i].name)])
			return @(sizes[i].pixels);
	}
	static const Unit units[] = {
		{ "px", 1 }, { "pt", 96.0 / 72.0 }, { "pc", 16 }, { "in", 96 },
		{ "cm", 96 / 2.54 }, { "mm", 96 / 25.4 }, { "q", 96 / 101.6 },
		{ "rem", 10 }, { "em", 10 }, { "%", 0.1 }
	};
	return pixelsOf(lower, units, sizeof units / sizeof *units, NO);
}

// The families: names quoted (with CSS's escapes) or unquoted, as identifiers.
+ (NSArray<NSString *> *)familiesOf:(NSString *)text {
	NSArray *keywords = @[@"inherit", @"initial", @"unset", @"revert",
			@"revert-layer", @"default"];
	NSArray *generics = @[@"serif", @"sans-serif", @"monospace", @"cursive",
			@"fantasy", @"system-ui", @"ui-serif", @"ui-sans-serif",
			@"ui-monospace", @"ui-rounded", @"math", @"emoji", @"fangsong"];
	NSData *data = codePointsOf(trimmed(text));
	const Char *chars = data.bytes;
	NSUInteger count = data.length / sizeof(Char), i = 0;
	NSMutableArray *families = [NSMutableArray array];
	for (;;) {
		while (i < count && [spaces() longCharacterIsMember:chars[i]])
			i++;
		if (i == count)
			return nil;
		NSMutableString *name = [NSMutableString string];
		Char quote = chars[i];
		if (quote == '"' || quote == '\'') {
			for (i++;; i++) {
				if (i == count)
					return nil;
				if (chars[i] == quote)
					break;
				if (chars[i] == '\\' && ++i == count)
					return nil;
				append(name, chars[i]);
			}
			i++;
		} else {
			NSMutableArray *words = [NSMutableArray array];
			NSMutableString *word = [NSMutableString string];
			for (; i < count && chars[i] != ','; i++) {
				Char c = chars[i];
				if ([spaces() longCharacterIsMember:c]) {
					if (word.length) {
						[words addObject:word];
						word = [NSMutableString string];
					}
				} else if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
						|| (c >= '0' && c <= '9') || c == '-' || c == '_'
						|| c > 0x7f) {
					append(word, c);
				} else {
					return nil;
				}
			}
			if (word.length)
				[words addObject:word];
			for (NSString *word in words) {
				unichar first = [word characterAtIndex:0];
				if ((first >= '0' && first <= '9') || [word hasPrefix:@"--"]
						|| [word isEqualToString:@"-"])
					return nil;
			}
			if (!words.count || (words.count == 1
					&& [keywords containsObject:lowercased(words[0])]))
				return nil;
			[name setString:[words componentsJoinedByString:@" "]];
			// A generic family is a keyword, of any case:
			if ([generics containsObject:lowercased(name)])
				[name setString:lowercased(name)];
		}
		[families addObject:[name copy]];
		while (i < count && [spaces() longCharacterIsMember:chars[i]])
			i++;
		if (i == count)
			return families;
		if (chars[i++] != ',')
			return nil;
	}
}

- (NSString *)serialized {
	NSMutableArray *parts = [NSMutableArray array];
	if (![_style isEqualToString:@"normal"])
		[parts addObject:_style];
	if (_smallCaps)
		[parts addObject:@"small-caps"];
	if (_weight == 700)
		[parts addObject:@"bold"];
	else if (_weight != 400)
		[parts addObject:@(_weight).stringValue];
	if (![_stretch isEqualToString:@"normal"])
		[parts addObject:_stretch];
	[parts addObject:[displayOf(_size) stringByAppendingString:@"px"]];
	NSMutableCharacterSet *identifier =
			[NSCharacterSet.alphanumericCharacterSet mutableCopy];
	[identifier addCharactersInString:@"-_"];
	NSMutableArray *families = [NSMutableArray array];
	for (NSString *family in _families) {
		NSData *data = codePointsOf(family);
		const Char *chars = data.bytes;
		BOOL isIdentifier = data.length > 0;
		for (NSUInteger i = 0; i < data.length / sizeof(Char); i++)
			isIdentifier = isIdentifier
					&& [identifier longCharacterIsMember:chars[i]];
		[families addObject:isIdentifier ? family : [NSString stringWithFormat:
				@"\"%@\"", [[family stringByReplacingOccurrencesOfString:@"\\"
					withString:@"\\\\"] stringByReplacingOccurrencesOfString:
					@"\"" withString:@"\\\""]]];
	}
	[parts addObject:[families componentsJoinedByString:@", "]];
	return [parts componentsJoinedByString:@" "];
}

+ (NSArray<NSString *> *)candidatesForFamily:(NSString *)family {
	NSString *lower = lowercased(family);
	if ([lower isEqualToString:@"sans-serif"]
			|| [lower isEqualToString:@"system-ui"])
		return @[@"Helvetica", @"Arial", @"Helvetica Neue", @"Liberation Sans",
				@"DejaVu Sans", @"Source Sans 3"];
	if ([lower isEqualToString:@"serif"])
		return @[@"Times", @"Times New Roman", @"Georgia", @"Liberation Serif",
				@"DejaVu Serif"];
	if ([lower isEqualToString:@"monospace"])
		return @[@"Menlo", @"Courier New", @"Consolas", @"Liberation Mono",
				@"DejaVu Sans Mono", @"Source Code Pro"];
	if ([lower isEqualToString:@"cursive"])
		return @[@"Apple Chancery", @"Comic Sans MS", @"URW Chancery L"];
	if ([lower isEqualToString:@"fantasy"])
		return @[@"Papyrus", @"Impact"];
	return @[family];
}

+ (NSNumber *)lengthInPixels:(NSString *)text fontSize:(double)size {
	NSString *lower = lowercased(trimmed(text));
	if ([lower isEqualToString:@"0"])
		return @0;
	// `ex` and `ch` as half an em, `ic` as an em, as CSS has them without the
	// font's own.
	Unit units[] = {
		{ "px", 1 }, { "em", size }, { "rem", 10 }, { "ex", size / 2 },
		{ "ch", size / 2 }, { "ic", size }, { "pt", 4.0 / 3.0 }, { "pc", 16 },
		{ "in", 96 }, { "cm", 96 / 2.54 }, { "mm", 96 / 25.4 },
		{ "q", 96 / 101.6 }
	};
	return pixelsOf(lower, units, sizeof units / sizeof *units, YES);
}

+ (NSString *)normalizedLength:(NSString *)text {
	NSString *lower = lowercased(trimmed(text));
	return [self lengthInPixels:lower fontSize:10] ? lower : nil;
}

@end
