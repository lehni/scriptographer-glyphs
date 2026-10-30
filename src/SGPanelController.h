//
//  SGPanelController.h
//  Scriptographer for Glyphs
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// A Scriptographer panel, as VectorCraft's palettes: a floating window, or
// docked in the sidebar of the document window in front, as a section next to
// Glyphs' own (Dimensions, Layers…). Its views move between the two.
@interface SGPanelController : NSWindowController

// Adds the panels' sections to Glyphs' sidebars, also of the windows that
// are open already:
+ (void)addSections;

- (instancetype)initWithTitle:(NSString *)title size:(NSSize)size;

// The panel's views, set by the panels once they're made: `views` one above
// the other, and `buttons` at the bottom, with the sidebar menu on the right.
- (void)setContentViews:(NSArray<NSView *> *)views
		buttons:(NSStackView *)buttons;
@property (nonatomic, getter=isDocked) BOOL docked;

// Shows the panel where it is, the window when it isn't docked, or no
// document window is open:
- (void)show;
// Hides or shows the panel, the window or its section when docked:
- (void)toggle;
// Moves the views to where they show now: into the sidebar of the document
// window in front when docked, or else the window.
- (void)place;
// The items of the panel's menu, above Dock in Sidebar:
- (void)addMenuItems:(NSMenu *)menu;
- (BOOL)validateMenuItem:(NSMenuItem *)item;

@end

NS_ASSUME_NONNULL_END
