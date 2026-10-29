//
//  SGPalette.h
//  Scriptographer for Glyphs
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// What the user did in a script's palette: `change` a component's value,
// `click` a button or menu entry, or `close` it, without a name and value.
typedef void (^SGPaletteHandler)(NSNumber *paletteId, NSString *type,
		NSString *_Nullable name, id _Nullable value);

// The scripts' palettes, `new Palette(title, components, values)`, as floating
// panels with their components (see SGComponentsView), and their menu entries
// in a menu of their own. A palette opens where the user last put the
// script's palette of that title.
@interface SGPalette : NSWindowController

// Shows the palettes that a script reports as new or changed, as
// `{ id, title, components }`:
+ (void)showPalettes:(NSArray<NSDictionary *> *)palettes
		ofScript:(NSString *)script handler:(SGPaletteHandler)handler;

// Closes the script's palettes without telling it, as it stopped:
+ (void)closePalettesOfScript:(NSString *)script;

@end

NS_ASSUME_NONNULL_END
