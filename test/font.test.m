// Tests SGCSSFont against canvas.rs's own cases and WPT's canvas font and
// spacing tests (BSD license), as VectorCraft's canvas reads them: what a
// font shorthand or a spacing gives back, nil where it leaves the canvas's
// value as it was.

#import <Foundation/Foundation.h>
#import "../src/SGCSSFont.h"

static int count, failures;

static void check(BOOL isPassed, NSString *description) {
	count++;
	if (!isPassed) {
		fprintf(stderr, "failed: %s\n", description.UTF8String);
		failures++;
	}
}

static BOOL isSame(id a, id b) {
	return a == b || [a isEqual:b];
}

int main(void) {
	@autoreleasepool {
		id null = [NSNull null];
		// Shorthand, as it reads back:
		NSArray *fonts = @[
			// canvas.rs's own cases:
			@[@"10px sans-serif", @"10px sans-serif"],
			@[@"italic bold 12pt \"Source Sans 3\", serif",
				@"italic bold 16px \"Source Sans 3\", serif"],
			@[@"300 2em/1.5 'Helvetica Neue'", @"300 20px \"Helvetica Neue\""],
			@[@"700 50% monospace", @"bold 5px monospace"],
			@[@"bold", null],
			@[@"12px", null],
			@[@"big Helvetica", null],
			@[@"20PX   SERIF", @"20px serif"],
			@[@"small-caps italic 400 12px/2 \"Unknown Font #2\", sans-serif",
				@"italic small-caps 12px \"Unknown Font #2\", sans-serif"],
			@[@"bold 12pt / 1.5 Helvetica Neue",
				@"bold 16px \"Helvetica Neue\""],
			@[@"", null],
			@[@"bogus", null],
			@[@"inherit", null],
			@[@"10px {bogus}", null],
			@[@"10px initial", null],
			@[@"10px default", null],
			@[@"var(--x)", null],
			@[@"1em serif; background: green", null],
			// WPT's 2d.text.font.*:
			@[@"20px serif", @"20px serif"],
			@[@"  15px sans-serif  ", @"15px sans-serif"],
			@[@"small-caps italic 400 12px/2 Unknown Font, sans-serif",
				@"italic small-caps 12px \"Unknown Font\", sans-serif"],
			@[(@"20px cursive,fantasy,monospace,sans-serif,serif,"
					@"UnquotedFont,\"QuotedFont\\\\\\\",\""),
				(@"20px cursive, fantasy, monospace, sans-serif, serif, "
					@"UnquotedFont, \"QuotedFont\\\\\\\",\"")],
			@[@"10px inherit", null],
			@[@"10px revert", null],
			@[@"var(--x, 10px serif)", null],
			@[@"1em serif; background: green; margin: 10px", null],
			@[@"if(supports(list-style-type: disc): 13px MyFont)", null],
			@[@"message-box", null],
			@[@"1px sans-serif", @"1px sans-serif"],
			@[@"1em sans-serif", @"10px sans-serif"],
			@[@"italic 400 12px serif", @"italic 12px serif"],
			@[@"italic 300 12px serif", @"italic 300 12px serif"],
			// Sizes:
			@[@"10pt serif", @"13.333333333333332px serif"],
			@[@"xx-small serif", @"9px serif"],
			@[@"x-small serif", @"10px serif"],
			@[@"small serif", @"13px serif"],
			@[@"medium serif", @"16px serif"],
			@[@"large serif", @"18px serif"],
			@[@"x-large serif", @"24px serif"],
			@[@"xx-large serif", @"32px serif"],
			@[@"XXX-LARGE serif", @"48px serif"],
			@[@"larger serif", null],
			@[@"1in serif", @"96px serif"],
			@[@"1pc serif", @"16px serif"],
			@[@"1cm serif", @"37.79527559055118px serif"],
			@[@"10mm serif", @"37.795275590551185px serif"],
			@[@"4q serif", @"3.7795275590551185px serif"],
			@[@"4Q serif", @"3.7795275590551185px serif"],
			@[@"2rem serif", @"20px serif"],
			@[@"150% serif", @"15px serif"],
			@[@".5em serif", @"5px serif"],
			@[@"+5px serif", @"5px serif"],
			@[@"5.px serif", @"5px serif"],
			@[@"1e1px serif", @"10px serif"],
			@[@"1E1PX serif", @"10px serif"],
			@[@"0.1px serif", @"0.1px serif"],
			@[@"1e-7px serif", @"0.0000001px serif"],
			@[@"1e21px serif", @"1000000000000000000000px serif"],
			@[@"0px serif", @"0px serif"],
			@[@"-0px serif", @"-0px serif"],
			@[@"-1px serif", null],
			@[@"infpx serif", null],
			@[@"nanpx serif", null],
			@[@"1e400px serif", null],
			@[@"12 px serif", null],
			@[@"12 serif", null],
			@[@"12px", null],
			@[@"12", null],
			@[@"px serif", null],
			@[@".px serif", null],
			@[@"1e+px serif", null],
			@[@"0x10px serif", null],
			@[@"1 2px serif", @"1 2px serif"],
			@[@"12vh serif", null],
			// Line heights, left out:
			@[@"12px/2 serif", @"12px serif"],
			@[@"12px/ 2 serif", @"12px serif"],
			@[@"12px /2 serif", @"12px serif"],
			@[@"12px / normal serif", @"12px serif"],
			@[@"medium/2 serif", @"16px serif"],
			@[@"12px/2/3 serif", @"12px serif"],
			@[@"12px/ serif", null],
			@[@"12px / 2", null],
			@[@"12px /2", null],
			@[@"/2 serif", null],
			// Style, variant, weight and stretch:
			@[@"oblique small-caps lighter condensed 12px serif",
				@"oblique small-caps 100 condensed 12px serif"],
			@[@"ultra-expanded bolder ITALIC 12px serif",
				@"italic bold ultra-expanded 12px serif"],
			@[@"normal normal normal normal normal 12px serif", @"12px serif"],
			@[@"500 normal 12px serif", @"500 12px serif"],
			@[@"400 12px serif", @"12px serif"],
			@[@"italic italic 12px serif", null],
			@[@"italic oblique 12px serif", null],
			@[@"bold 700 12px serif", null],
			@[@"bold lighter 12px serif", null],
			@[@"small-caps small-caps 12px serif", null],
			@[@"condensed expanded 12px serif", null],
			@[@"1 12px serif", @"1 12px serif"],
			@[@"1000 12px serif", @"1000 12px serif"],
			@[@"1001 12px serif", null],
			@[@"0.5 12px serif", null],
			@[@"450.5 12px serif", @"451 12px serif"],
			@[@"450.4 12px serif", @"450 12px serif"],
			@[@"1e3 12px serif", @"1000 12px serif"],
			@[@"bold\t12px\tserif", @"bold 12px serif"],
			@[@"\u00a0bold\u2003 12px serif\u3000", @"bold 12px serif"],
			// Families:
			@[@"12px 2serif", null],
			@[@"12px --x", null],
			@[@"12px -", null],
			@[@"12px -x", @"12px -x"],
			@[@"12px _x", @"12px _x"],
			@[@"12px \"serif\"", @"12px serif"],
			@[@"12px SANS-SERIF, Serif", @"12px sans-serif, serif"],
			@[@"12px UI-Rounded, MATH, Emoji, FangSong, System-UI",
				@"12px ui-rounded, math, emoji, fangsong, system-ui"],
			@[@"12px \"a\\\"b\"", @"12px \"a\\\"b\""],
			@[@"12px 'it\\'s'", @"12px \"it's\""],
			@[@"12px \"\"", @"12px \"\""],
			@[@"12px \"a\\\\b\"", @"12px \"a\\\\b\""],
			@[@"12px \"\\x\"", @"12px x"],
			@[@"12px \"unterminated", null],
			@[@"12px \"a\\", null],
			@[@"12px \"a\" b", null],
			@[@"12px a,", null],
			@[@"12px ,a", null],
			@[@"12px a,,b", null],
			@[@"12px a, ", null],
			@[@"12px a.b", null],
			@[@"12px a'b", null],
			@[@"12px Font  With   Spaces", @"12px \"Font With Spaces\""],
			@[@"12px Font 2", null],
			@[@"12px Ünïcödé", @"12px Ünïcödé"],
			@[@"12px 日本語", @"12px 日本語"],
			@[@"12px café 😀", @"12px \"café 😀\""],
			@[@"12px 𝐀", @"12px 𝐀"],
			@[@"12px \"inherit\"", @"12px inherit"],
			@[@"12px Inherit Font", @"12px \"Inherit Font\""],
			@[@"12px INHERIT", null],
			@[@"12px revert-layer", null],
			@[@"12px unset", null],
			@[@"12px a\u00a0b", @"12px \"a b\""],
			@[@"12px \"a b\" , c", @"12px \"a b\", c"],
		];
		for (NSArray *test in fonts) {
			NSString *expected = test[1] == null ? nil : test[1];
			NSString *result = [[SGCSSFont parse:test[0]] serialized];
			check(isSame(result, expected), [NSString stringWithFormat:
					@"font <%@>: <%@>, not <%@>", test[0], result, expected]);
		}

		// canvas.rs's parse cases, in parts:
		SGCSSFont *font = [SGCSSFont parse:
				@"italic bold 12pt \"Source Sans 3\", serif"];
		check([font.style isEqualToString:@"italic"] && !font.isSmallCaps
				&& font.weight == 700
				&& [font.stretch isEqualToString:@"normal"]
				&& font.size == 16 && [font.families isEqualToArray:
					@[@"Source Sans 3", @"serif"]], @"parse: italic bold 12pt");
		font = [SGCSSFont parse:@"300 2em/1.5 'Helvetica Neue'"];
		check([font.style isEqualToString:@"normal"] && font.weight == 300
				&& font.size == 20 && [font.families isEqualToArray:
					@[@"Helvetica Neue"]], @"parse: 300 2em/1.5");
		font = [SGCSSFont parse:@"oblique small-caps condensed 50% MONOSPACE"];
		check([font.style isEqualToString:@"oblique"] && font.isSmallCaps
				&& font.weight == 400
				&& [font.stretch isEqualToString:@"condensed"] && font.size == 5
				&& [font.families isEqualToArray:@[@"monospace"]],
				@"parse: oblique small-caps condensed 50%");

		// The generic families' faces, any other family itself:
		NSArray *candidates = @[
			@[@"sans-serif", @"Helvetica", @6],
			@[@"System-UI", @"Helvetica", @6],
			@[@"serif", @"Times", @5], @[@"monospace", @"Menlo", @6],
			@[@"cursive", @"Apple Chancery", @3], @[@"fantasy", @"Papyrus", @2],
			@[@"ui-serif", @"ui-serif", @1], @[@"Helvetica", @"Helvetica", @1]
		];
		for (NSArray *test in candidates) {
			NSArray *result = [SGCSSFont candidatesForFamily:test[0]];
			check(isSame(result.firstObject, test[1])
					&& result.count == [test[2] unsignedIntegerValue],
					[NSString stringWithFormat:@"candidates <%@>: %@", test[0],
						[result componentsJoinedByString:@", "]]);
		}

		// Lengths in pixels for a font size:
		NSArray *lengths = @[
			@[@"0", @10, @0.0],
			@[@"0px", @10, @0.0],
			@[@" 3PX ", @10, @3.0],
			@[@"-1px", @10, @-1.0],
			@[@"1px", @10, @1.0],
			@[@"1em", @20, @20.0],
			@[@"1EM", @20, @20.0],
			@[@"1rem", @20, @10.0],
			@[@"1ex", @20, @10.0],
			@[@"1ch", @20, @10.0],
			@[@"1ic", @20, @20.0],
			@[@"3pt", @10, @4.0],
			@[@"1pc", @10, @16.0],
			@[@"1in", @10, @96.0],
			@[@"1cm", @10, @37.79527559055118],
			@[@"1mm", @10, @3.7795275590551185],
			@[@"4q", @10, @3.7795275590551185],
			@[@"1.5em", @10, @15.0],
			@[@"-.5em", @10, @-5.0],
			@[@"1e1px", @10, @10.0],
			@[@"0s", @10, null],
			@[@"1min", @10, null],
			@[@"1deg", @10, null],
			@[@"1pp", @10, null],
			@[@"initial", @10, null],
			@[@"inherit", @10, null],
			@[@"normal", @10, null],
			@[@"none", @10, null],
			@[@"NaN", @10, null],
			@[@"Infinity", @10, null],
			@[@"-Infinity", @10, null],
			@[@"1", @10, null],
			@[@"", @10, null],
			@[@"px", @10, null],
			@[@"infpx", @10, null],
			@[@"1 px", @10, null],
			@[@"1%", @10, null],
			@[@"-0", @10, null],
		];
		for (NSArray *test in lengths) {
			NSNumber *expected = test[2] == null ? nil : test[2];
			NSNumber *result = [SGCSSFont lengthInPixels:test[0]
					fontSize:[test[1] doubleValue]];
			check(isSame(result, expected), [NSString stringWithFormat:
					@"length <%@>: %@, not %@", test[0], result, expected]);
		}

		// Lengths as they read back:
		NSArray *normalized = @[
			@[@" 3PX ", @"3px"], @[@"1EM", @"1em"], @[@"1EX", @"1ex"],
			@[@"1ch", @"1ch"], @[@"-1px", @"-1px"], @[@"0", @"0"],
			@[@"1PP", null], @[@"NORMAL", null], @[@"", null]
		];
		for (NSArray *test in normalized) {
			NSString *expected = test[1] == null ? nil : test[1];
			NSString *result = [SGCSSFont normalizedLength:test[0]];
			check(isSame(result, expected), [NSString stringWithFormat:
					@"normalized <%@>: <%@>", test[0], result]);
		}

		if (failures)
			fprintf(stderr, "%d of %d failed\n", failures, count);
		else
			printf("font: all %d passed\n", count);
		return failures ? 1 : 0;
	}
}
