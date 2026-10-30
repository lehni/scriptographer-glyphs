//
//  SGPanelController.m
//  Scriptographer for Glyphs
//

#import "SGPanelController.h"
#import "SGWindowController.h"
#import "SGConsoleController.h"
#import <GlyphsCore/GlyphsCore.h>
#import <GlyphsApp/GlyphsApp.h>
#import <GlyphsApp/GlyphsPaletteProtocol.h>
#import <GlyphsApp/GSPluginHandler.h>
#import <GlyphsApp/GSPaletteView.h>

@class SGPanelSection;

// Where Glyphs' palette view takes clicks to resize, at its bottom:
static const CGFloat handleHeight = 5;

@interface SGPanelController ()
- (void)addSection:(SGPanelSection *)section;
@end

// A section's view, which has its panel placed again once Glyphs has put it
// into a sidebar. Glyphs' palette view draws the handle that resizes it, as
// in Layers.
@interface SGSectionView : GSPaletteView
@property (nonatomic, weak) SGPanelController *panel;
@end

@implementation SGSectionView

- (void)viewDidMoveToWindow {
	[super viewDidMoveToWindow];
	__weak SGPanelController *panel = self.panel;
	// Once Glyphs is done with the sidebar:
	dispatch_async(dispatch_get_main_queue(), ^{
		[panel place];
	});
}

@end

// A panel's section in the sidebar. Glyphs makes one in each document window,
// and the panel shows in the one in front, with the others hidden.
@interface SGPanelSection : NSObject <GlyphsPalette>
@end

@implementation SGPanelSection {
	SGSectionView *_view;
}

@synthesize windowController;

+ (SGPanelController *)controller {
	return nil;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		SGPanelController *controller = [self.class controller];
		_view = [[SGSectionView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
		// Its height comes from the palette view's intrinsic size, which the
		// handle changes:
		_view.translatesAutoresizingMaskIntoConstraints = NO;
		_view.panel = controller;
		// The palette view takes the heights from its section:
		_view.controller = self;
		[controller addSection:self];
	}
	return self;
}

- (NSUInteger)interfaceVersion {
	return 1;
}

- (NSString *)title {
	return [self.class controller].window.title;
}

- (NSView *)theView {
	return _view;
}

- (NSInteger)minHeight {
	return 80;
}

- (NSInteger)maxHeight {
	return 2000;
}

- (NSString *)heightKey {
	return [self.title stringByAppendingString:@" Height"];
}

- (NSUInteger)currentHeight {
	NSInteger height = [NSUserDefaults.standardUserDefaults
			integerForKey:self.heightKey];
	return height > 0 ? height : 240;
}

- (void)setCurrentHeight:(NSUInteger)height {
	[NSUserDefaults.standardUserDefaults setInteger:height
			forKey:self.heightKey];
}

- (NSUInteger)sortID {
	return 50;
}

// The box Glyphs puts the view in, with the title, which hides the whole
// section, or nil before it's in the sidebar:
- (NSView *)pane {
	NSView *pane = _view;
	while (pane.superview && ![pane.superview isKindOfClass:[NSStackView class]])
		pane = pane.superview;
	return pane.superview ? pane : nil;
}

@end

@interface SGScriptsSection : SGPanelSection
@end

@implementation SGScriptsSection

+ (SGPanelController *)controller {
	return [SGWindowController sharedController];
}

@end

@interface SGConsoleSection : SGPanelSection
@end

@implementation SGConsoleSection

+ (SGPanelController *)controller {
	return [SGConsoleController sharedController];
}

- (NSUInteger)sortID {
	return 51;
}

@end

@implementation SGPanelController {
	NSHashTable<SGPanelSection *> *_sections;
	NSView *_content;
	// Whether the docked panel is hidden, its section with it:
	BOOL _isHidden;
	// The panel's menu in the sidebar, at the right of the buttons:
	NSPopUpButton *_sidebarMenuButton;
}

+ (void)addSections {
	NSArray<Class> *classes = @[[SGScriptsSection class],
			[SGConsoleSection class]];
	[[GSPluginHandler sharedHandler].paletteClasses
			addObjectsFromArray:classes];
	for (NSDocument *document in
			NSDocumentController.sharedDocumentController.documents) {
		for (NSWindowController *controller in document.windowControllers) {
			if ([controller isKindOfClass:[GSWindowController class]]) {
				[(GSWindowController *)controller
						reloadPalettePlugins:classes];
			}
		}
	}
}

- (instancetype)initWithTitle:(NSString *)title size:(NSSize)size {
	NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0,
				size.width, size.height)
			styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
				| NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow
			backing:NSBackingStoreBuffered defer:YES];
	panel.title = title;
	panel.floatingPanel = YES;
	panel.hidesOnDeactivate = YES;
	panel.becomesKeyOnlyIfNeeded = YES;
	// The sidebar's background, as when docked:
	NSVisualEffectView *background = [[NSVisualEffectView alloc] init];
	background.material = NSVisualEffectMaterialSidebar;
	background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
	panel.contentView = background;
	self = [super initWithWindow:panel];
	if (self) {
		_sections = [NSHashTable weakObjectsHashTable];
		_docked = [NSUserDefaults.standardUserDefaults
				boolForKey:self.dockedKey];
		[self addMenuButtons];
		NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
		for (NSNotificationName name in @[NSWindowDidBecomeMainNotification,
				NSWindowWillCloseNotification]) {
			[center addObserver:self selector:@selector(windowsDidChange:)
					name:name object:nil];
		}
		[panel center];
		panel.frameAutosaveName = title;
	}
	return self;
}

- (NSString *)dockedKey {
	return [self.window.title stringByAppendingString:@" Docked"];
}

- (void)setContentViews:(NSArray<NSView *> *)views
		buttons:(NSStackView *)buttons {
	NSView *space = [[NSView alloc] init];
	[space setContentHuggingPriority:NSLayoutPriorityDefaultLow
			forOrientation:NSLayoutConstraintOrientationHorizontal];
	[buttons addArrangedSubview:space];
	[buttons addArrangedSubview:_sidebarMenuButton];
	NSStackView *stack = [NSStackView stackViewWithViews:
			[views arrayByAddingObject:buttons]];
	stack.orientation = NSUserInterfaceLayoutOrientationVertical;
	stack.alignment = NSLayoutAttributeLeading;
	stack.edgeInsets = NSEdgeInsetsMake(6, 6, 6, 6);
	stack.spacing = 6;
	for (NSView *view in stack.arrangedSubviews) {
		[view.widthAnchor constraintEqualToAnchor:stack.widthAnchor
				constant:-12].active = YES;
	}
	_content = stack;
	[self place];
}

- (void)setDocked:(BOOL)docked {
	_docked = docked;
	[NSUserDefaults.standardUserDefaults setBool:docked forKey:self.dockedKey];
	[self show];
}

- (void)addSection:(SGPanelSection *)section {
	[_sections addObject:section];
}

- (void)windowsDidChange:(NSNotification *)notification {
	// A closing window is still in the list until it's closed:
	dispatch_async(dispatch_get_main_queue(), ^{
		[self place];
	});
}

#pragma mark - Placing

// The section in the document window in front, when docked:
- (SGPanelSection *)targetSection {
	if (!_docked)
		return nil;
	for (NSWindow *window in NSApp.orderedWindows) {
		if (![window.windowController isKindOfClass:[GSWindowController class]]
				|| !window.visible)
			continue;
		for (SGPanelSection *section in _sections) {
			if (section.windowController.window == window && section.pane)
				return section;
		}
	}
	return nil;
}

- (void)place {
	if (!_content)
		return;
	SGPanelSection *target = [self targetSection];
	for (SGPanelSection *section in _sections)
		section.pane.hidden = section != target || _isHidden;
	_sidebarMenuButton.hidden = !target;
	NSView *view = target ? target.theView : self.window.contentView;
	if (_content.superview == view)
		return;
	if (target)
		[self close];
	[_content removeFromSuperview];
	_content.translatesAutoresizingMaskIntoConstraints = NO;
	[view addSubview:_content];
	// In a section, clear of the handle at the bottom, which takes the clicks
	// there:
	[NSLayoutConstraint activateConstraints:@[
		[_content.topAnchor constraintEqualToAnchor:view.topAnchor],
		[_content.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
		[_content.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
		[_content.bottomAnchor constraintEqualToAnchor:view.bottomAnchor
				constant:target ? -handleHeight : 0]
	]];
}

- (BOOL)isInWindow {
	return _content.superview == self.window.contentView;
}

- (void)show {
	_isHidden = NO;
	[self place];
	if (self.isInWindow)
		[self showWindow:nil];
}

- (void)toggle {
	if (!self.isInWindow) {
		_isHidden = !_isHidden;
		[self place];
	} else if (self.window.visible) {
		[self close];
	} else {
		[self show];
	}
}

#pragma mark - Menu

- (void)addMenuItems:(NSMenu *)menu {
}

// A pull-down with the panel's menu, showing `image`:
- (NSPopUpButton *)menuButtonWithImage:(NSImage *)image {
	NSPopUpButton *button = [[NSPopUpButton alloc]
			initWithFrame:NSMakeRect(0, 0, 36, 22) pullsDown:YES];
	button.bordered = NO;
	NSMenu *menu = button.menu;
	[menu addItemWithTitle:@"" action:nil keyEquivalent:@""].image = image;
	[self addMenuItems:menu];
	if (menu.numberOfItems > 1)
		[menu addItem:[NSMenuItem separatorItem]];
	[menu addItemWithTitle:@"Dock in Sidebar" action:@selector(toggleDocked:)
			keyEquivalent:@""].target = self;
	return button;
}

// The window has the menu in its title bar, the section at the right of the
// buttons at the bottom, as Layers:
- (void)addMenuButtons {
	NSTitlebarAccessoryViewController *accessory =
			[[NSTitlebarAccessoryViewController alloc] init];
	accessory.view = [self menuButtonWithImage:
			[NSImage imageNamed:NSImageNameActionTemplate]];
	accessory.layoutAttribute = NSLayoutAttributeTrailing;
	[self.window addTitlebarAccessoryViewController:accessory];
	_sidebarMenuButton = [self menuButtonWithImage:[NSImage
			imageWithSystemSymbolName:@"ellipsis.circle"
			accessibilityDescription:@"Menu"]];
	((NSPopUpButtonCell *)_sidebarMenuButton.cell).arrowPosition =
			NSPopUpNoArrow;
	[_sidebarMenuButton.widthAnchor constraintEqualToConstant:24].active = YES;
	_sidebarMenuButton.hidden = YES;
}

- (void)toggleDocked:(id)sender {
	self.docked = !_docked;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
	if (item.action == @selector(toggleDocked:))
		item.state = _docked ? NSControlStateValueOn : NSControlStateValueOff;
	return YES;
}

@end
