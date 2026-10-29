// Tests SGComponentsView offscreen: it shows the components' values, and
// reports what the user changes through its controls' own actions.

#import <Cocoa/Cocoa.h>
#import "../src/SGComponentsView.h"

static int failures = 0;

#define CHECK(condition) do { \
	if (!(condition)) { \
		fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #condition); \
		failures++; \
	} \
} while (0)

// The control of the component `name` of class `class`:
static id find(NSView *view, NSString *name, Class class) {
	if ([view isKindOfClass:class] && [view.identifier isEqual:name])
		return view;
	for (NSView *subview in view.subviews) {
		id found = find(subview, name, class);
		if (found)
			return found;
	}
	return nil;
}

static void act(NSControl *control) {
	[NSApp sendAction:control.action to:control.target from:control];
}

static NSArray *components(void) {
	return @[
		@{ @"name": @"size", @"type": @"number", @"label": @"Size",
				@"units": @"millimeter", @"min": @0, @"max": @144,
				@"steppers": @YES, @"value": @72 },
		@{ @"name": @"amount", @"type": @"slider", @"label": @"Amount",
				@"range": @[@0, @10], @"value": @5 },
		@{ @"name": @"closed", @"type": @"boolean", @"label": @"Closed",
				@"value": @NO },
		@{ @"name": @"shape", @"type": @"list", @"label": @"Shape",
				@"options": @[@"Circle", @"Square"], @"value": @"Square" },
		@{ @"name": @"color", @"type": @"color", @"label": @"Color",
				@"value": @"#ff8000" },
		@{ @"name": @"title", @"type": @"string", @"label": @"Title",
				@"value": @"A" },
		@{ @"name": @"apply", @"type": @"button", @"value": @"Apply" },
		@{ @"name": @"line", @"type": @"ruler" },
		@{ @"name": @"note", @"type": @"text", @"value": @"Hello",
				@"visible": @NO }
	];
}

int main(void) {
	@autoreleasepool {
		[NSApplication sharedApplication];
		SGComponentsView *view = [[SGComponentsView alloc]
				initWithComponents:components()];
		NSMutableArray *changes = [NSMutableArray array];
		view.changeHandler = ^(NSString *name, id value) {
			[changes addObject:@[name, value]];
		};
		__block NSString *clicked = nil;
		view.clickHandler = ^(NSString *name) {
			clicked = name;
		};

		// The values show, lengths in their unit:
		NSTextField *size = find(view, @"size", [NSTextField class]);
		CHECK([size.stringValue isEqualToString:@"25.4 mm"]);
		CHECK([find(view, @"amount", [NSSlider class]) doubleValue] == 5);
		CHECK([find(view, @"shape", [NSPopUpButton class])
				indexOfSelectedItem] == 1);
		CHECK([[find(view, @"title", [NSTextField class]) stringValue]
				isEqualToString:@"A"]);
		CHECK([[find(view, @"apply", [NSButton class]) title]
				isEqualToString:@"Apply"]);
		CHECK(view.numberOfRows == 9);
		CHECK([view rowAtIndex:8].hidden);

		// Typed lengths come back in points, within their range:
		size.stringValue = @"10 mm";
		act(size);
		CHECK(fabs([changes.lastObject[1] doubleValue] - 72 / 2.54) < 1e-9);
		size.stringValue = @"100 mm";
		act(size);
		CHECK([changes.lastObject[1] doubleValue] == 144);
		NSStepper *stepper = find(view, @"size", [NSStepper class]);
		CHECK(stepper.doubleValue == 144);

		NSSlider *slider = find(view, @"amount", [NSSlider class]);
		slider.doubleValue = 7.5;
		act(slider);
		CHECK([changes.lastObject isEqual:(@[@"amount", @7.5])]);
		CHECK([[find(view, @"amount", [NSTextField class]) stringValue]
				isEqualToString:@"7.5"]);

		NSButton *closed = find(view, @"closed", [NSButton class]);
		[closed performClick:nil];
		CHECK([changes.lastObject isEqual:(@[@"closed", @YES])]);

		NSPopUpButton *shape = find(view, @"shape", [NSPopUpButton class]);
		[shape selectItemAtIndex:0];
		act(shape);
		CHECK([changes.lastObject isEqual:(@[@"shape", @"Circle"])]);

		NSColorWell *color = find(view, @"color", [NSColorWell class]);
		NSColor *shown = [color.color
				colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
		CHECK(round(shown.greenComponent * 255) == 128);
		color.color = [NSColor colorWithSRGBRed:0 green:0 blue:1 alpha:1];
		act(color);
		CHECK([changes.lastObject isEqual:(@[@"color", @"#0000ff"])]);

		[find(view, @"apply", [NSButton class]) performClick:nil];
		CHECK([clicked isEqualToString:@"apply"]);
		CHECK([view.values[@"shape"] isEqual:@"Circle"]);

		// New values of the same components show in place; other components
		// need a new view:
		NSMutableArray *next = [components() mutableCopy];
		NSMutableDictionary *title = [next[5] mutableCopy];
		title[@"value"] = @"B";
		title[@"enabled"] = @NO;
		next[5] = title;
		CHECK([view updateComponents:next]);
		NSTextField *field = find(view, @"title", [NSTextField class]);
		CHECK([field.stringValue isEqualToString:@"B"]);
		CHECK(!field.enabled);
		title[@"label"] = @"Name";
		next[5] = title;
		CHECK(![view updateComponents:next]);
	}
	if (failures)
		fprintf(stderr, "%d failed\n", failures);
	else
		printf("components: all passed\n");
	return failures ? 1 : 0;
}
