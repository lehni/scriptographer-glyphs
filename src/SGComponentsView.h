//
//  SGComponentsView.h
//  Scriptographer for Glyphs
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// The components of a palette or a prompt, as the scripts describe them (see
// Dialog.prompt() and new Palette()): `{ name, type, label, value, … }` with
// the types number, slider/range, boolean/checkbox, list, color, string,
// button, text and ruler. Labels with a colon, right-aligned in a column, then
// the fields, as in Scriptographer.
@interface SGComponentsView : NSGridView

// The component's new value, as JSON: numbers, booleans, strings, colors as
// `#rrggbb`, and a list's option:
@property (nonatomic, copy, nullable) void (^changeHandler)(NSString *name,
		id value);
@property (nonatomic, copy, nullable) void (^clickHandler)(NSString *name);

- (instancetype)initWithComponents:(NSArray<NSDictionary *> *)components;

// Shows the components' values, when only they changed. Returns NO when the
// components themselves changed and need a new view:
- (BOOL)updateComponents:(NSArray<NSDictionary *> *)components;

// The values by name, as the user left them:
- (NSDictionary<NSString *, id> *)values;

@end

NS_ASSUME_NONNULL_END
