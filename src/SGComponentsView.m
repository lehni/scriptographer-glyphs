//
//  SGComponentsView.m
//  Scriptographer for Glyphs
//

#import "SGComponentsView.h"

// The keys that only show a component's state, which change without a new
// view:
static NSArray<NSString *> *stateKeys;

@implementation SGComponentsView {
	NSArray<NSDictionary *> *_components;
	NSMutableDictionary<NSString *, id> *_values;
	// The control that shows each component's value, by name, and the number
	// field beside a slider or the stepper beside a number field:
	NSMutableDictionary<NSString *, NSControl *> *_controls;
	NSMutableDictionary<NSString *, NSControl *> *_companions;
	NSMutableDictionary<NSString *, NSGridRow *> *_rows;
	CGFloat _h;
}

+ (void)initialize {
	stateKeys = @[@"value", @"enabled", @"visible"];
}

- (instancetype)initWithComponents:(NSArray<NSDictionary *> *)components {
	self = [super initWithFrame:NSZeroRect];
	if (self) {
		_components = [[NSArray alloc] initWithArray:components copyItems:YES];
		_values = [NSMutableDictionary dictionary];
		_controls = [NSMutableDictionary dictionary];
		_companions = [NSMutableDictionary dictionary];
		_rows = [NSMutableDictionary dictionary];
		_h = [@"H" sizeWithAttributes:@{ NSFontAttributeName: [self font] }]
				.width;
		self.rowSpacing = 6;
		self.columnSpacing = 8;
		self.rowAlignment = NSGridRowAlignmentFirstBaseline;
		for (NSDictionary *component in components)
			[self addComponent:component];
		if (self.numberOfColumns > 0)
			[self columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
		[self updateComponents:components];
	}
	return self;
}

- (NSFont *)font {
	return [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
}

#pragma mark - Components

static NSString *typeOf(NSDictionary *component) {
	NSString *type = component[@"type"];
	return [type isKindOfClass:[NSString class]] ? type : @"string";
}

static BOOL isMenu(NSDictionary *component) {
	NSString *type = typeOf(component);
	return [type isEqualToString:@"menu-entry"]
			|| [type isEqualToString:@"menu-separator"];
}

static NSString *textOf(id value) {
	if ([value isKindOfClass:[NSString class]])
		return value;
	if (!value || value == [NSNull null])
		return @"";
	NSData *data = [NSJSONSerialization dataWithJSONObject:value
			options:NSJSONWritingFragmentsAllowed error:nil];
	return data ? [[NSString alloc] initWithData:data
			encoding:NSUTF8StringEncoding] : [value description];
}

static double numberOf(id value, double fallback) {
	return [value isKindOfClass:[NSNumber class]] ? [value doubleValue]
			: fallback;
}

// Lengths are points, shown in their unit, as Scriptographer's `units` had
// them: the points per unit, and its suffix:
static double unitFactor(NSString *units, NSString **suffix) {
	NSDictionary<NSString *, NSArray *> *all = @{
		@"point": @[@1, @" pt"],
		@"pica": @[@12, @" pc"],
		@"inch": @[@72, @" in"],
		@"millimeter": @[@(72 / 25.4), @" mm"],
		@"centimeter": @[@(72 / 2.54), @" cm"],
		@"percent": @[@1, @"%"],
		@"degree": @[@1, @"°"]
	};
	NSArray *unit = [units isKindOfClass:[NSString class]] ? all[units] : nil;
	*suffix = unit ? unit[1] : @"";
	return unit ? [unit[0] doubleValue] : 1;
}

// A component's label with a colon, when it has one: rulers, texts and
// buttons without a label have none:
- (NSTextField *)labelFor:(NSDictionary *)component {
	NSString *label = component[@"label"];
	if (![label isKindOfClass:[NSString class]] || !label.length)
		return nil;
	NSTextField *field = [NSTextField labelWithString:
			[label stringByAppendingString:@":"]];
	field.font = [self font];
	field.textColor = [NSColor secondaryLabelColor];
	return field;
}

- (NSNumberFormatter *)formatterFor:(NSDictionary *)component
		digits:(NSUInteger)digits {
	NSString *suffix;
	double factor = unitFactor(component[@"units"], &suffix);
	NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
	formatter.numberStyle = NSNumberFormatterDecimalStyle;
	formatter.usesGroupingSeparator = NO;
	formatter.minimumFractionDigits = 0;
	formatter.maximumFractionDigits = (NSUInteger)numberOf(
			component[@"fractionDigits"], digits);
	formatter.positiveSuffix = formatter.negativeSuffix = suffix;
	formatter.lenient = YES;
	formatter.multiplier = @(1 / factor);
	return formatter;
}

- (NSNumber *)minOf:(NSDictionary *)component {
	id min = component[@"min"];
	NSArray *range = component[@"range"];
	if (![min isKindOfClass:[NSNumber class]]
			&& [range isKindOfClass:[NSArray class]] && range.count == 2)
		min = range[0];
	return [min isKindOfClass:[NSNumber class]] ? min : nil;
}

- (NSNumber *)maxOf:(NSDictionary *)component {
	id max = component[@"max"];
	NSArray *range = component[@"range"];
	if (![max isKindOfClass:[NSNumber class]]
			&& [range isKindOfClass:[NSArray class]] && range.count == 2)
		max = range[1];
	return [max isKindOfClass:[NSNumber class]] ? max : nil;
}

// The width of a component's field: its `width`, or its `length` in H's,
// 16 for text and 8 for numbers:
- (CGFloat)widthOf:(NSDictionary *)component length:(NSUInteger)length {
	id width = component[@"width"];
	if ([width isKindOfClass:[NSNumber class]])
		return [width doubleValue];
	return numberOf(component[@"length"], length) * _h + 8;
}

- (NSTextField *)textFieldFor:(NSDictionary *)component width:(CGFloat)width {
	NSTextField *field = [[NSTextField alloc] init];
	field.font = [self font];
	field.controlSize = NSControlSizeSmall;
	field.target = self;
	field.action = @selector(fieldChanged:);
	[field.widthAnchor constraintEqualToConstant:width].active = YES;
	return field;
}

- (void)addComponent:(NSDictionary *)component {
	NSString *name = component[@"name"], *type = typeOf(component);
	if (![name isKindOfClass:[NSString class]] || isMenu(component))
		return;
	NSView *view = nil;
	NSControl *control = nil;
	BOOL spans = NO;
	if ([type isEqualToString:@"ruler"]) {
		NSBox *box = [[NSBox alloc] init];
		box.boxType = NSBoxSeparator;
		view = box;
		spans = YES;
	} else if ([type isEqualToString:@"text"]) {
		NSTextField *field = [NSTextField wrappingLabelWithString:@""];
		field.font = [self font];
		view = control = field;
		spans = YES;
	} else if ([type isEqualToString:@"number"]) {
		NSTextField *field = [self textFieldFor:component
				width:[self widthOf:component length:8]];
		field.formatter = [self formatterFor:component digits:3];
		field.alignment = NSTextAlignmentRight;
		view = control = field;
		if ([component[@"steppers"] boolValue]) {
			NSString *suffix;
			double factor = unitFactor(component[@"units"], &suffix);
			NSStepper *stepper = [[NSStepper alloc] init];
			stepper.controlSize = NSControlSizeSmall;
			stepper.valueWraps = NO;
			stepper.increment = numberOf(component[@"increment"], 1) * factor;
			stepper.minValue = numberOf([self minOf:component], -DBL_MAX);
			stepper.maxValue = numberOf([self maxOf:component], DBL_MAX);
			stepper.target = self;
			stepper.action = @selector(stepperChanged:);
			_companions[name] = stepper;
			view = [NSStackView stackViewWithViews:@[field, stepper]];
			((NSStackView *)view).spacing = 2;
		}
	} else if ([type isEqualToString:@"slider"]
			|| [type isEqualToString:@"range"]) {
		double min = numberOf([self minOf:component], 0);
		NSSlider *slider = [NSSlider sliderWithValue:min
				minValue:min
				maxValue:MAX(numberOf([self maxOf:component], 1), min)
				target:self action:@selector(sliderChanged:)];
		slider.controlSize = NSControlSizeSmall;
		[slider.widthAnchor constraintEqualToConstant:
				[self widthOf:component length:12]].active = YES;
		NSTextField *field = [self textFieldFor:component width:5 * _h + 8];
		field.formatter = [self formatterFor:component digits:2];
		field.alignment = NSTextAlignmentRight;
		_companions[name] = field;
		control = slider;
		view = [NSStackView stackViewWithViews:@[slider, field]];
	} else if ([type isEqualToString:@"boolean"]
			|| [type isEqualToString:@"checkbox"]) {
		NSButton *button = [NSButton checkboxWithTitle:@"" target:self
				action:@selector(checkboxChanged:)];
		button.controlSize = NSControlSizeSmall;
		view = control = button;
	} else if ([type isEqualToString:@"list"]) {
		NSPopUpButton *button = [[NSPopUpButton alloc] init];
		button.controlSize = NSControlSizeSmall;
		button.font = [self font];
		NSArray *options = component[@"options"];
		if ([options isKindOfClass:[NSArray class]]) {
			for (id option in options)
				[button addItemWithTitle:textOf(option)];
		}
		button.target = self;
		button.action = @selector(listChanged:);
		[button.widthAnchor constraintGreaterThanOrEqualToConstant:
				[self widthOf:component length:16]].active = YES;
		view = control = button;
	} else if ([type isEqualToString:@"color"]) {
		NSColorWell *well = [[NSColorWell alloc] init];
		[well.widthAnchor constraintEqualToConstant:44].active = YES;
		[well.heightAnchor constraintEqualToConstant:22].active = YES;
		well.target = self;
		well.action = @selector(colorChanged:);
		view = control = well;
	} else if ([type isEqualToString:@"button"]) {
		NSButton *button = [NSButton buttonWithTitle:@"" target:self
				action:@selector(buttonClicked:)];
		button.controlSize = NSControlSizeSmall;
		button.font = [self font];
		view = control = button;
	} else if ([type isEqualToString:@"string"]) {
		NSTextField *field = [self textFieldFor:component
				width:[self widthOf:component length:16]];
		if ([component[@"multiline"] boolValue]) {
			field.usesSingleLineMode = NO;
			field.cell.wraps = YES;
			field.cell.scrollable = NO;
			CGFloat rows = numberOf(component[@"rows"], 4);
			[field.heightAnchor constraintEqualToConstant:
					rows * ([self font].boundingRectForFont.size.height + 1)
					+ 6].active = YES;
		}
		view = control = field;
	} else {
		// Fonts: not yet, as in VectorCraft.
		return;
	}
	if ([component[@"fullSize"] boolValue]) {
		[view setContentHuggingPriority:NSLayoutPriorityDefaultLow
				forOrientation:NSLayoutConstraintOrientationHorizontal];
	}
	NSString *tip = component[@"toolTip"];
	if ([tip isKindOfClass:[NSString class]] && tip.length)
		view.toolTip = tip;
	if (control) {
		control.identifier = name;
		_controls[name] = control;
	}
	_companions[name].identifier = name;
	NSView *label = spans ? nil : [self labelFor:component];
	NSGridRow *row = [self addRowWithViews:spans
			? @[view, [NSGridCell emptyContentView]]
			: @[label ?: [NSGridCell emptyContentView], view]];
	if (spans)
		[row mergeCellsInRange:NSMakeRange(0, 2)];
	_rows[name] = row;
}

#pragma mark - Values

// The component without what only shows its state:
static NSDictionary *structureOf(NSDictionary *component) {
	NSMutableDictionary *structure = [component mutableCopy];
	[structure removeObjectsForKeys:stateKeys];
	return structure;
}

- (BOOL)updateComponents:(NSArray<NSDictionary *> *)components {
	if (components.count != _components.count)
		return NO;
	for (NSUInteger i = 0; i < components.count; i++) {
		if (![structureOf(components[i]) isEqual:structureOf(_components[i])])
			return NO;
	}
	_components = [[NSArray alloc] initWithArray:components copyItems:YES];
	for (NSDictionary *component in components) {
		NSString *name = component[@"name"];
		if (![name isKindOfClass:[NSString class]] || isMenu(component))
			continue;
		id value = component[@"value"] ?: [NSNull null];
		_values[name] = value;
		BOOL enabled = component[@"enabled"]
				? [component[@"enabled"] boolValue] : YES;
		_controls[name].enabled = enabled;
		_companions[name].enabled = enabled;
		_rows[name].hidden = component[@"visible"]
				&& ![component[@"visible"] boolValue];
		[self showValue:value of:component];
	}
	return YES;
}

- (void)showValue:(id)value of:(NSDictionary *)component {
	NSString *name = component[@"name"], *type = typeOf(component);
	NSControl *control = _controls[name];
	// Leave the field the user is typing in as it is:
	NSText *editor = control.currentEditor;
	if (editor && editor == control.window.firstResponder)
		return;
	if ([type isEqualToString:@"text"]) {
		id text = value != [NSNull null] ? value : component[@"label"];
		control.stringValue = textOf(text);
	} else if ([type isEqualToString:@"number"]) {
		control.objectValue = @(numberOf(value, 0));
		_companions[name].doubleValue = numberOf(value, 0);
	} else if ([type isEqualToString:@"slider"]
			|| [type isEqualToString:@"range"]) {
		control.doubleValue = numberOf(value, 0);
		_companions[name].objectValue = @(numberOf(value, 0));
	} else if ([type isEqualToString:@"boolean"]
			|| [type isEqualToString:@"checkbox"]) {
		((NSButton *)control).state = [value isKindOfClass:[NSNumber class]]
				&& [value boolValue] ? NSControlStateValueOn
				: NSControlStateValueOff;
	} else if ([type isEqualToString:@"list"]) {
		[(NSPopUpButton *)control selectItemWithTitle:textOf(value)];
	} else if ([type isEqualToString:@"color"]) {
		((NSColorWell *)control).color = colorOf(value);
	} else if ([type isEqualToString:@"button"]) {
		((NSButton *)control).title = textOf(value);
	} else {
		control.stringValue = textOf(value);
	}
}

static NSColor *colorOf(id value) {
	unsigned int rgb = 0;
	if ([value isKindOfClass:[NSString class]] && [value length] == 7
			&& [value hasPrefix:@"#"]) {
		[[NSScanner scannerWithString:[value substringFromIndex:1]]
				scanHexInt:&rgb];
	}
	return [NSColor colorWithSRGBRed:(rgb >> 16 & 0xff) / 255.0
			green:(rgb >> 8 & 0xff) / 255.0 blue:(rgb & 0xff) / 255.0
			alpha:1];
}

static NSString *hexOf(NSColor *color) {
	color = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
	return [NSString stringWithFormat:@"#%02x%02x%02x",
			(int)round(color.redComponent * 255),
			(int)round(color.greenComponent * 255),
			(int)round(color.blueComponent * 255)];
}

- (NSDictionary<NSString *, id> *)values {
	return [_values copy];
}

- (void)change:(NSString *)name to:(id)value {
	_values[name] = value;
	if (_changeHandler)
		_changeHandler(name, value);
}

#pragma mark - Actions

- (NSDictionary *)componentNamed:(NSString *)name {
	for (NSDictionary *component in _components) {
		if ([component[@"name"] isEqual:name])
			return component;
	}
	return nil;
}

- (void)fieldChanged:(NSTextField *)sender {
	NSString *name = sender.identifier;
	if (sender.formatter) {
		NSDictionary *component = [self componentNamed:name];
		double value = MIN(MAX(numberOf(sender.objectValue, 0),
				numberOf([self minOf:component], -DBL_MAX)),
				numberOf([self maxOf:component], DBL_MAX));
		sender.objectValue = @(value);
		NSControl *companion = _companions[name];
		if ([companion isKindOfClass:[NSSlider class]]
				|| [companion isKindOfClass:[NSStepper class]])
			companion.doubleValue = value;
		if (_controls[name] != sender)
			_controls[name].doubleValue = value;
		[self change:name to:@(value)];
	} else {
		[self change:name to:sender.stringValue];
	}
}

- (void)stepperChanged:(NSStepper *)sender {
	_controls[sender.identifier].objectValue = @(sender.doubleValue);
	[self change:sender.identifier to:@(sender.doubleValue)];
}

- (void)sliderChanged:(NSSlider *)sender {
	_companions[sender.identifier].objectValue = @(sender.doubleValue);
	[self change:sender.identifier to:@(sender.doubleValue)];
}

- (void)checkboxChanged:(NSButton *)sender {
	[self change:sender.identifier
			to:@(sender.state == NSControlStateValueOn)];
}

- (void)listChanged:(NSPopUpButton *)sender {
	NSArray *options = [self componentNamed:sender.identifier][@"options"];
	NSInteger index = sender.indexOfSelectedItem;
	if (index >= 0 && index < (NSInteger)options.count)
		[self change:sender.identifier to:options[index]];
}

- (void)colorChanged:(NSColorWell *)sender {
	[self change:sender.identifier to:hexOf(sender.color)];
}

- (void)buttonClicked:(NSButton *)sender {
	if (_clickHandler)
		_clickHandler(sender.identifier);
}

@end
