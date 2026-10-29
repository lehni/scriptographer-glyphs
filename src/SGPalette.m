//
//  SGPalette.m
//  Scriptographer for Glyphs
//

#import "SGPalette.h"
#import "SGComponentsView.h"

// The open palettes, by their script and number:
static NSMutableDictionary<NSString *, SGPalette *> *palettes;

@interface SGPalette () <NSWindowDelegate>
@end

@implementation SGPalette {
	NSString *_script;
	NSNumber *_paletteId;
	SGPaletteHandler _handler;
	SGComponentsView *_componentsView;
	NSPopUpButton *_menuButton;
	// Whether the script closes it, which it then needn't hear about:
	BOOL _isClosedByScript;
}

static NSString *keyOf(NSString *script, NSNumber *paletteId) {
	return [NSString stringWithFormat:@"%@\x1f%@", script, paletteId];
}

+ (void)showPalettes:(NSArray<NSDictionary *> *)list
		ofScript:(NSString *)script handler:(SGPaletteHandler)handler {
	if (!palettes)
		palettes = [NSMutableDictionary dictionary];
	for (NSDictionary *state in list) {
		NSNumber *paletteId = state[@"id"];
		NSString *key = keyOf(script, paletteId);
		SGPalette *palette = palettes[key];
		if (!palette) {
			palette = [[SGPalette alloc] initWithScript:script
					paletteId:paletteId handler:handler];
			palettes[key] = palette;
		}
		[palette showTitle:state[@"title"] components:state[@"components"]];
	}
}

+ (void)closePalettesOfScript:(NSString *)script {
	for (SGPalette *palette in palettes.allValues) {
		if ([palette->_script isEqualToString:script]) {
			palette->_isClosedByScript = YES;
			[palette close];
		}
	}
}

- (instancetype)initWithScript:(NSString *)script paletteId:(NSNumber *)paletteId
		handler:(SGPaletteHandler)handler {
	NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSZeroRect
			styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
				| NSWindowStyleMaskUtilityWindow
			backing:NSBackingStoreBuffered defer:YES];
	panel.floatingPanel = YES;
	panel.hidesOnDeactivate = YES;
	panel.becomesKeyOnlyIfNeeded = YES;
	panel.releasedWhenClosed = NO;
	self = [super initWithWindow:panel];
	if (self) {
		_script = script;
		_paletteId = paletteId;
		_handler = handler;
		panel.delegate = self;
		// The menu entries, in a menu in the title bar:
		_menuButton = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 36, 22)
				pullsDown:YES];
		_menuButton.bordered = NO;
		_menuButton.controlSize = NSControlSizeSmall;
		NSTitlebarAccessoryViewController *accessory =
				[[NSTitlebarAccessoryViewController alloc] init];
		accessory.view = _menuButton;
		accessory.layoutAttribute = NSLayoutAttributeTrailing;
		[panel addTitlebarAccessoryViewController:accessory];
	}
	return self;
}

- (void)showTitle:(NSString *)title components:(NSArray *)components {
	NSWindow *panel = self.window;
	BOOL isNew = !_componentsView;
	panel.title = [title isKindOfClass:[NSString class]] ? title : @"";
	if (![components isKindOfClass:[NSArray class]])
		components = @[];
	if (isNew || ![_componentsView updateComponents:components]) {
		_componentsView = [[SGComponentsView alloc]
				initWithComponents:components];
		__weak SGPalette *weakSelf = self;
		_componentsView.changeHandler = ^(NSString *name, id value) {
			[weakSelf send:@"change" name:name value:value];
		};
		_componentsView.clickHandler = ^(NSString *name) {
			[weakSelf send:@"click" name:name value:nil];
		};
		NSStackView *content = [NSStackView stackViewWithViews:
				@[_componentsView]];
		content.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
		NSPoint topLeft = NSMakePoint(NSMinX(panel.frame), NSMaxY(panel.frame));
		panel.contentView = content;
		[panel setContentSize:content.fittingSize];
		if (isNew)
			[self placePanel];
		else
			[panel setFrameTopLeftPoint:topLeft];
	}
	[self showMenu:components];
	if (isNew)
		[self showWindow:nil];
}

- (void)showMenu:(NSArray *)components {
	NSMenu *menu = _menuButton.menu;
	[menu removeAllItems];
	// A pull-down's first item is its title:
	NSMenuItem *title = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
	title.image = [NSImage imageNamed:NSImageNameActionTemplate];
	for (NSDictionary *component in components) {
		NSString *type = component[@"type"];
		if ([type isEqual:@"menu-separator"]) {
			[menu addItem:[NSMenuItem separatorItem]];
		} else if ([type isEqual:@"menu-entry"]) {
			id label = component[@"label"] ?: component[@"name"];
			NSMenuItem *item = [menu addItemWithTitle:[label description]
					action:@selector(menuEntrySelected:) keyEquivalent:@""];
			item.target = self;
			item.representedObject = component[@"name"];
			item.enabled = !component[@"enabled"]
					|| [component[@"enabled"] boolValue];
		}
	}
	_menuButton.hidden = menu.numberOfItems < 2;
}

- (void)menuEntrySelected:(NSMenuItem *)item {
	[self send:@"click" name:item.representedObject value:nil];
}

- (void)send:(NSString *)type name:(NSString *)name value:(id)value {
	if (_handler)
		_handler(_paletteId, type, name, value);
}

#pragma mark - Placement

// Where the user last put the script's palette of this title:
- (NSString *)placementKey {
	return [NSString stringWithFormat:@"Scriptographer Palette %@\x1f%@",
			_script, self.window.title];
}

- (void)placePanel {
	NSString *placed = [NSUserDefaults.standardUserDefaults
			stringForKey:[self placementKey]];
	if (placed) {
		[self.window setFrameTopLeftPoint:NSPointFromString(placed)];
	} else {
		[self.window center];
	}
}

- (void)windowDidMove:(NSNotification *)notification {
	NSRect frame = self.window.frame;
	[NSUserDefaults.standardUserDefaults setObject:NSStringFromPoint(
			NSMakePoint(NSMinX(frame), NSMaxY(frame)))
			forKey:[self placementKey]];
}

- (void)windowWillClose:(NSNotification *)notification {
	[palettes removeObjectForKey:keyOf(_script, _paletteId)];
	if (!_isClosedByScript)
		[self send:@"close" name:nil value:nil];
}

@end
