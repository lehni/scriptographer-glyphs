//
//  SGWindowController.m
//  Scriptographer for Glyphs
//

#import "SGWindowController.h"
#import "SGRuntime.h"
#import "SGScript.h"
#import <GlyphsCore/GlyphsCore.h>
#import <GlyphsApp/GlyphsApp.h>

// The folders the user added, by path:
static NSString *const foldersKey = @"Scriptographer Folders";
// How deep the tree lists folders:
static const NSUInteger maxDepth = 8;

// A scripts folder at the top of the tree.
@interface SGFolder : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSURL *url;
// The Examples: their scripts can't be changed, and nothing goes in them.
@property (nonatomic) BOOL isSealed;
@end

@implementation SGFolder
@end

// The tree, which gives Return and ⌘E to its controller, as Scriptographer's
// did.
@interface SGOutlineView : NSOutlineView
@end

@implementation SGOutlineView

- (void)keyDown:(NSEvent *)event {
	NSString *key = event.charactersIgnoringModifiers;
	BOOL isCommand = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
	if (!isCommand && ([key isEqualToString:@"\r"]
			|| [key isEqualToString:@"\x03"])) {
		[NSApp sendAction:@selector(runScript:) to:self.target from:self];
	} else if (isCommand && [key isEqualToString:@"e"]) {
		[NSApp sendAction:@selector(editScript:) to:self.target from:self];
	} else {
		[super keyDown:event];
	}
}

@end

@interface SGWindowController () <NSOutlineViewDataSource,
		NSOutlineViewDelegate, NSWindowDelegate>
@end

@implementation SGWindowController {
	NSArray<SGFolder *> *_folders;
	// The tree's items: the folders, and the URLs of their folders and
	// scripts, the same objects across reloads, so the tree keeps what's open:
	NSMutableDictionary<NSString *, NSURL *> *_items;
	NSMapTable<id, NSArray *> *_children;
	SGOutlineView *_outlineView;
	NSSplitView *_splitView;
	NSTextView *_consoleView;
	NSTextField *_inputField;
	NSButton *_runButton, *_editButton, *_revealButton;
}

+ (void)addMenuItem {
	NSMenu *menu = [NSApp windowsMenu];
	if (menu) {
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Scriptographer"
				action:@selector(showScriptographer:) keyEquivalent:@""];
		item.target = self;
		[menu addItem:[NSMenuItem separatorItem]];
		[menu addItem:item];
	}
}

+ (void)runInitScripts {
	SGWindowController *controller = [self sharedController];
	[[SGRuntime sharedRuntime] runInitScriptsIn:
			[controller->_folders valueForKey:@"url"]];
}

+ (void)showScriptographer:(id)sender {
	[[self sharedController] showWindow:sender];
}

+ (instancetype)sharedController {
	static SGWindowController *controller;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		controller = [[SGWindowController alloc] init];
	});
	return controller;
}

- (instancetype)init {
	NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 320, 560)
			styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
				| NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow
			backing:NSBackingStoreBuffered defer:YES];
	panel.title = @"Scriptographer";
	panel.floatingPanel = YES;
	panel.hidesOnDeactivate = YES;
	panel.becomesKeyOnlyIfNeeded = YES;
	self = [super initWithWindow:panel];
	if (self) {
		panel.delegate = self;
		_items = [NSMutableDictionary dictionary];
		_children = [NSMapTable strongToStrongObjectsMapTable];
		[self setupViews];
		[self setupMenu];
		[self reloadScripts];
		SGRuntime *runtime = [SGRuntime sharedRuntime];
		__weak SGWindowController *weakSelf = self;
		runtime.printHandler = ^(NSString *line) {
			[weakSelf appendToConsole:line];
		};
		runtime.stateHandler = ^{
			[weakSelf reloadData];
		};
		// The folders are listed again when Glyphs comes to the front:
		[NSNotificationCenter.defaultCenter addObserver:self
				selector:@selector(reloadScripts)
				name:NSApplicationDidBecomeActiveNotification object:nil];
		[panel center];
		panel.frameAutosaveName = @"Scriptographer";
	}
	return self;
}

#pragma mark - Folders

- (NSURL *)myScriptsURL {
	NSURL *support = [[NSFileManager.defaultManager
			URLsForDirectory:NSApplicationSupportDirectory
			inDomains:NSUserDomainMask] firstObject];
	return [support URLByAppendingPathComponent:@"Scriptographer/Scripts"
			isDirectory:YES];
}

// The Examples, sealed in the plugin, My Scripts, made on first use, and the
// folders the user added:
- (NSArray<SGFolder *> *)loadFolders {
	NSMutableArray *folders = [NSMutableArray array];
	SGFolder *examples = [[SGFolder alloc] init];
	examples.name = @"Examples";
	examples.url = [[NSBundle bundleForClass:[self class]]
			URLForResource:@"Examples" withExtension:nil];
	examples.isSealed = YES;
	[folders addObject:examples];
	NSURL *myScripts = [self myScriptsURL];
	[NSFileManager.defaultManager createDirectoryAtURL:myScripts
			withIntermediateDirectories:YES attributes:nil error:nil];
	SGFolder *mine = [[SGFolder alloc] init];
	mine.name = @"My Scripts";
	mine.url = myScripts;
	[folders addObject:mine];
	for (NSString *path in [NSUserDefaults.standardUserDefaults
			stringArrayForKey:foldersKey]) {
		SGFolder *folder = [[SGFolder alloc] init];
		folder.url = [NSURL fileURLWithPath:path isDirectory:YES];
		folder.name = folder.url.lastPathComponent;
		[folders addObject:folder];
	}
	return folders;
}

- (NSURL *)itemForURL:(NSURL *)url {
	NSURL *item = _items[url.path];
	if (!item) {
		item = url;
		_items[url.path] = item;
	}
	return item;
}

// The folders and scripts in a folder, folders first, by name:
- (NSArray<NSURL *> *)listFolder:(NSURL *)folder depth:(NSUInteger)depth {
	NSMutableArray *folders = [NSMutableArray array];
	NSMutableArray *scripts = [NSMutableArray array];
	for (NSURL *url in [NSFileManager.defaultManager
			contentsOfDirectoryAtURL:folder
			includingPropertiesForKeys:@[NSURLIsDirectoryKey]
			options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) {
		NSNumber *isDirectory = nil;
		[url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
		if (isDirectory.boolValue) {
			if (depth < maxDepth) {
				NSURL *item = [self itemForURL:url];
				[_children setObject:[self listFolder:url depth:depth + 1]
						forKey:item];
				[folders addObject:item];
			}
		} else if ([@[@"js", @"pjs"] containsObject:
				url.pathExtension.lowercaseString]) {
			[scripts addObject:[self itemForURL:url]];
		}
	}
	NSComparator byName = ^NSComparisonResult(NSURL *a, NSURL *b) {
		return [a.lastPathComponent localizedStandardCompare:
				b.lastPathComponent];
	};
	[folders sortUsingComparator:byName];
	[scripts sortUsingComparator:byName];
	return [folders arrayByAddingObjectsFromArray:scripts];
}

- (void)reloadScripts {
	id selected = [self selectedItem];
	NSString *selectedPath = [selected isKindOfClass:[SGFolder class]]
			? [selected url].path : [selected path];
	_folders = [self loadFolders];
	[_children removeAllObjects];
	for (SGFolder *folder in _folders)
		[_children setObject:[self listFolder:folder.url depth:0] forKey:folder];
	[_outlineView reloadData];
	if (selectedPath)
		[self selectPath:selectedPath];
	[self updateButtons];
}

// Shows which scripts run, without listing the folders again, or losing the
// selection:
- (void)reloadData {
	id selected = [self selectedItem];
	[_outlineView reloadData];
	NSInteger row = selected ? [_outlineView rowForItem:selected] : -1;
	if (row >= 0) {
		[_outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
				byExtendingSelection:NO];
	}
	[self updateButtons];
}

- (void)selectPath:(NSString *)path {
	id item = _items[path];
	for (SGFolder *folder in _folders) {
		if ([folder.url.path isEqualToString:path])
			item = folder;
	}
	if (!item)
		return;
	// Its folders open:
	NSMutableArray *parents = [NSMutableArray array];
	for (NSURL *url = [item isKindOfClass:[NSURL class]]
				? [item URLByDeletingLastPathComponent] : nil;
			url.path.length > 1; url = url.URLByDeletingLastPathComponent) {
		id parent = _items[url.path];
		for (SGFolder *folder in _folders) {
			if ([folder.url.path isEqualToString:url.path])
				parent = folder;
		}
		if (parent)
			[parents insertObject:parent atIndex:0];
	}
	for (id parent in parents)
		[_outlineView expandItem:parent];
	NSInteger row = [_outlineView rowForItem:item];
	if (row >= 0) {
		[_outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
				byExtendingSelection:NO];
		[_outlineView scrollRowToVisible:row];
	}
}

- (id)selectedItem {
	NSInteger row = _outlineView.clickedRow >= 0
			? _outlineView.clickedRow : _outlineView.selectedRow;
	return row >= 0 ? [_outlineView itemAtRow:row] : nil;
}

- (NSURL *)selectedScript {
	id item = [self selectedItem];
	return [item isKindOfClass:[NSURL class]]
			&& ![_children objectForKey:item] ? item : nil;
}

- (SGFolder *)folderOf:(id)item {
	if ([item isKindOfClass:[SGFolder class]])
		return item;
	for (SGFolder *folder in _folders) {
		if ([[item path] hasPrefix:[folder.url.path
				stringByAppendingString:@"/"]])
			return folder;
	}
	return nil;
}

// Where new scripts and folders go: the selected folder, or the selected
// script's, unless sealed, then My Scripts:
- (NSURL *)targetFolder {
	id item = [self selectedItem];
	SGFolder *folder = [self folderOf:item];
	if (!item || folder.isSealed)
		return [self myScriptsURL];
	if ([item isKindOfClass:[SGFolder class]])
		return [item url];
	return [_children objectForKey:item] ? item
			: [item URLByDeletingLastPathComponent];
}

// Whether a script is a tool: it defines mouse or key handlers, or uses
// `tool`, as VectorCraft tells them apart:
- (BOOL)isTool:(NSURL *)url {
	NSString *source = [NSString stringWithContentsOfURL:url
			encoding:NSUTF8StringEncoding error:nil];
	if ([source containsString:@"tool."])
		return YES;
	for (NSString *handler in @[@"onMouseDown", @"onMouseUp", @"onMouseDrag",
			@"onMouseMove", @"onKeyDown", @"onKeyUp"]) {
		if ([source containsString:handler])
			return YES;
	}
	return NO;
}

#pragma mark - Actions

- (void)runScript:(id)sender {
	NSURL *url = [self selectedScript];
	SGRuntime *runtime = [SGRuntime sharedRuntime];
	if (url && [runtime runScriptAtURL:url]
			&& [url isEqual:runtime.toolScript.url]) {
		// Tool scripts select the Script tool:
		GSDocument *document = (GSDocument *)
				[[NSDocumentController sharedDocumentController] currentDocument];
		if ([document isKindOfClass:[GSDocument class]]) {
			[document.windowController
					setToolForClass:NSClassFromString(@"SGScriptTool")];
		}
	}
}

// Stops every script and the console, as VectorCraft's Stop does:
- (void)stopScripts:(id)sender {
	[[SGRuntime sharedRuntime] stopAllScripts];
}

- (void)editScript:(id)sender {
	NSURL *url = [self selectedScript];
	if (url)
		[NSWorkspace.sharedWorkspace openURL:url];
}

- (void)revealItem:(id)sender {
	id item = [self selectedItem];
	NSURL *url = [item isKindOfClass:[SGFolder class]] ? [item url] : item;
	if (url)
		[NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[url]];
}

// A path in `folder` for `name` that isn't taken, numbered when it is:
- (NSURL *)freeURLIn:(NSURL *)folder name:(NSString *)name
		extension:(NSString *)extension {
	for (NSUInteger i = 1;; i++) {
		NSString *file = i == 1 ? name
				: [NSString stringWithFormat:@"%@ %lu", name, (unsigned long)i];
		NSURL *url = [folder URLByAppendingPathComponent:extension
				? [file stringByAppendingPathExtension:extension] : file];
		if (![NSFileManager.defaultManager fileExistsAtPath:url.path])
			return url;
	}
}

- (void)newScript:(id)sender {
	NSURL *url = [self freeURLIn:[self targetFolder] name:@"New Script"
			extension:@"js"];
	if ([@"// A new script.\n" writeToURL:url atomically:YES
			encoding:NSUTF8StringEncoding error:nil]) {
		[self reloadScripts];
		[self selectPath:url.path];
		[NSWorkspace.sharedWorkspace openURL:url];
	}
}

- (void)newFolder:(id)sender {
	NSURL *url = [self freeURLIn:[self targetFolder] name:@"New Folder"
			extension:nil];
	if ([NSFileManager.defaultManager createDirectoryAtURL:url
			withIntermediateDirectories:NO attributes:nil error:nil]) {
		[self reloadScripts];
		[self selectPath:url.path];
	}
}

- (void)toggleConsole:(id)sender {
	NSView *console = _splitView.arrangedSubviews.lastObject;
	console.hidden = !console.hidden;
	[_splitView adjustSubviews];
}

- (void)addFolder:(id)sender {
	NSOpenPanel *panel = [NSOpenPanel openPanel];
	panel.canChooseFiles = NO;
	panel.canChooseDirectories = YES;
	panel.prompt = @"Add";
	if ([panel runModal] == NSModalResponseOK) {
		NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
		NSMutableArray *paths = [[defaults stringArrayForKey:foldersKey]
				mutableCopy] ?: [NSMutableArray array];
		if (![paths containsObject:panel.URL.path])
			[paths addObject:panel.URL.path];
		[defaults setObject:paths forKey:foldersKey];
		[self reloadScripts];
	}
}

// Removes the selected folder that the user added from the tree, not from
// the disk:
- (void)removeFolder:(id)sender {
	SGFolder *folder = [self selectedItem];
	if ([self isAddedFolder:folder]) {
		NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
		NSMutableArray *paths = [[defaults stringArrayForKey:foldersKey]
				mutableCopy];
		[paths removeObject:folder.url.path];
		[defaults setObject:paths forKey:foldersKey];
		[self reloadScripts];
	}
}

- (BOOL)isAddedFolder:(id)item {
	return [item isKindOfClass:[SGFolder class]]
			&& [_folders indexOfObject:item] >= 2;
}

- (void)openReference:(id)sender {
	[NSWorkspace.sharedWorkspace openURL:
			[NSURL URLWithString:@"https://paperjs.org/reference/"]];
}

// The tool script's options, its `onEditOptions`, as a double-click on its
// tool button opens them in VectorCraft:
- (void)editToolOptions:(id)sender {
	[[SGRuntime sharedRuntime].toolScript callHandler:@"onEditOptions"];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
	if (item.action == @selector(editToolOptions:))
		return [SGRuntime sharedRuntime].toolScript != nil;
	if (item.action == @selector(removeFolder:))
		return [self isAddedFolder:[self selectedItem]];
	return YES;
}

- (void)updateButtons {
	id item = [self selectedItem];
	_runButton.enabled = _editButton.enabled = [self selectedScript] != nil;
	_revealButton.enabled = item != nil;
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
	[self reloadScripts];
}

#pragma mark - Views

- (NSButton *)buttonWithSymbol:(NSString *)symbol toolTip:(NSString *)toolTip
		action:(SEL)action {
	NSButton *button = [NSButton buttonWithImage:[NSImage
			imageWithSystemSymbolName:symbol accessibilityDescription:toolTip]
			target:self action:action];
	button.bordered = NO;
	button.toolTip = toolTip;
	[button.widthAnchor constraintEqualToConstant:24].active = YES;
	return button;
}

- (void)setupViews {
	// The scripts:
	_outlineView = [[SGOutlineView alloc] init];
	NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"name"];
	column.resizingMask = NSTableColumnAutoresizingMask;
	[_outlineView addTableColumn:column];
	_outlineView.outlineTableColumn = column;
	_outlineView.headerView = nil;
	_outlineView.dataSource = self;
	_outlineView.delegate = self;
	_outlineView.target = self;
	_outlineView.doubleAction = @selector(editScript:);
	_outlineView.style = NSTableViewStyleSourceList;
	_outlineView.floatsGroupRows = NO;
	NSScrollView *scriptsScroll = [[NSScrollView alloc] init];
	scriptsScroll.documentView = _outlineView;
	scriptsScroll.hasVerticalScroller = YES;

	// Scriptographer's buttons, in its groups: execute and stop, edit and show,
	// new script and folder, and the console on the right.
	_runButton = [self buttonWithSymbol:@"play.fill"
			toolTip:@"Execute Script" action:@selector(runScript:)];
	_editButton = [self buttonWithSymbol:@"square.and.pencil"
			toolTip:@"Edit Script" action:@selector(editScript:)];
	_revealButton = [self buttonWithSymbol:@"folder"
			toolTip:@"Show in Finder" action:@selector(revealItem:)];
	NSStackView *buttons = [NSStackView stackViewWithViews:@[
		_runButton,
		[self buttonWithSymbol:@"stop.fill" toolTip:@"Stop Running Scripts"
				action:@selector(stopScripts:)],
		_editButton,
		_revealButton,
		[self buttonWithSymbol:@"doc.badge.plus" toolTip:@"New Script"
				action:@selector(newScript:)],
		[self buttonWithSymbol:@"folder.badge.plus" toolTip:@"New Folder"
				action:@selector(newFolder:)],
		[self buttonWithSymbol:@"terminal" toolTip:@"Show or Hide the Console"
				action:@selector(toggleConsole:)]
	]];
	buttons.spacing = 2;
	[buttons setCustomSpacing:10 afterView:buttons.views[1]];
	[buttons setCustomSpacing:10 afterView:buttons.views[3]];
	[buttons setCustomSpacing:10 afterView:buttons.views[5]];

	// The console:
	NSScrollView *consoleScroll = [NSTextView scrollableTextView];
	_consoleView = consoleScroll.documentView;
	_consoleView.editable = NO;
	_consoleView.font = [NSFont monospacedSystemFontOfSize:11
			weight:NSFontWeightRegular];
	_inputField = [NSTextField textFieldWithString:@""];
	_inputField.placeholderString = @"Evaluate";
	_inputField.font = _consoleView.font;
	_inputField.target = self;
	_inputField.action = @selector(evaluateInput:);

	NSStackView *top = [NSStackView stackViewWithViews:@[scriptsScroll, buttons]];
	NSStackView *bottom = [NSStackView stackViewWithViews:@[consoleScroll,
			_inputField]];
	for (NSStackView *stack in @[top, bottom]) {
		stack.orientation = NSUserInterfaceLayoutOrientationVertical;
		stack.alignment = NSLayoutAttributeLeading;
		stack.edgeInsets = NSEdgeInsetsMake(6, 6, 6, 6);
		stack.spacing = 6;
	}
	for (NSView *view in @[scriptsScroll, consoleScroll, _inputField]) {
		[view.widthAnchor constraintEqualToAnchor:view.superview.widthAnchor
				constant:-12].active = YES;
	}

	_splitView = [[NSSplitView alloc] init];
	_splitView.vertical = NO;
	_splitView.dividerStyle = NSSplitViewDividerStyleThin;
	[_splitView addArrangedSubview:top];
	[_splitView addArrangedSubview:bottom];
	self.window.contentView = _splitView;
	[_splitView setPosition:320 ofDividerAtIndex:0];
}

// The panel's menu, in its title bar: the folders, and the reference.
- (void)setupMenu {
	NSPopUpButton *button = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 36, 22)
			pullsDown:YES];
	button.bordered = NO;
	NSMenu *menu = button.menu;
	NSMenuItem *title = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
	title.image = [NSImage imageNamed:NSImageNameActionTemplate];
	[menu addItemWithTitle:@"Add Folder…" action:@selector(addFolder:)
			keyEquivalent:@""].target = self;
	[menu addItemWithTitle:@"Remove Folder" action:@selector(removeFolder:)
			keyEquivalent:@""].target = self;
	[menu addItem:[NSMenuItem separatorItem]];
	[menu addItemWithTitle:@"Tool Options…" action:@selector(editToolOptions:)
			keyEquivalent:@""].target = self;
	[menu addItem:[NSMenuItem separatorItem]];
	[menu addItemWithTitle:@"Paper.js Reference"
			action:@selector(openReference:) keyEquivalent:@""].target = self;
	NSTitlebarAccessoryViewController *accessory =
			[[NSTitlebarAccessoryViewController alloc] init];
	accessory.view = button;
	accessory.layoutAttribute = NSLayoutAttributeTrailing;
	[self.window addTitlebarAccessoryViewController:accessory];
}

- (void)appendToConsole:(NSString *)line {
	NSDictionary *attributes = @{
		NSFontAttributeName: _consoleView.font,
		NSForegroundColorAttributeName: NSColor.textColor
	};
	[_consoleView.textStorage appendAttributedString:
			[[NSAttributedString alloc] initWithString:
				[line stringByAppendingString:@"\n"] attributes:attributes]];
	[_consoleView scrollToEndOfDocument:nil];
}

- (void)evaluateInput:(NSTextField *)sender {
	NSString *code = sender.stringValue;
	if (code.length) {
		[self appendToConsole:[@"> " stringByAppendingString:code]];
		sender.stringValue = @"";
		[[SGRuntime sharedRuntime] evaluate:code];
	}
}

#pragma mark - NSOutlineViewDataSource

- (NSInteger)outlineView:(NSOutlineView *)outlineView
		numberOfChildrenOfItem:(id)item {
	return item ? [_children objectForKey:item].count : _folders.count;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index
		ofItem:(id)item {
	return item ? [_children objectForKey:item][index] : _folders[index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
	return [_children objectForKey:item] != nil;
}

#pragma mark - NSOutlineViewDelegate

- (NSView *)outlineView:(NSOutlineView *)outlineView
		viewForTableColumn:(NSTableColumn *)column item:(id)item {
	NSTableCellView *cell = [outlineView makeViewWithIdentifier:@"item"
			owner:self];
	if (!cell) {
		cell = [[NSTableCellView alloc] init];
		cell.identifier = @"item";
		NSImageView *image = [[NSImageView alloc] init];
		NSTextField *field = [NSTextField labelWithString:@""];
		field.lineBreakMode = NSLineBreakByTruncatingTail;
		for (NSView *view in @[image, field]) {
			view.translatesAutoresizingMaskIntoConstraints = NO;
			[cell addSubview:view];
			[view.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
					.active = YES;
		}
		cell.imageView = image;
		cell.textField = field;
		[image.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor]
				.active = YES;
		[image.widthAnchor constraintEqualToConstant:16].active = YES;
		[field.leadingAnchor constraintEqualToAnchor:image.trailingAnchor
				constant:4].active = YES;
		[field.trailingAnchor constraintLessThanOrEqualToAnchor:
				cell.trailingAnchor].active = YES;
	}
	SGRuntime *runtime = [SGRuntime sharedRuntime];
	NSString *symbol;
	NSColor *tint = nil, *color = NSColor.labelColor;
	if ([item isKindOfClass:[SGFolder class]]) {
		cell.textField.stringValue = [item name];
		symbol = [item isSealed] ? @"lock" : @"folder";
	} else if ([_children objectForKey:item]) {
		cell.textField.stringValue = [item lastPathComponent];
		symbol = @"folder";
	} else {
		NSURL *url = item;
		cell.textField.stringValue =
				url.lastPathComponent.stringByDeletingPathExtension;
		// Tool scripts have a pencil, the one the Script tool stands for a
		// coloured one, running scripts their name in the accent colour:
		BOOL isActiveTool = [url isEqual:runtime.toolScript.url];
		symbol = isActiveTool || [self isTool:url] ? @"pencil" : @"doc";
		if (isActiveTool)
			tint = NSColor.controlAccentColor;
		if ([runtime isScriptRunningAtURL:url])
			color = NSColor.controlAccentColor;
	}
	cell.imageView.image = [NSImage imageWithSystemSymbolName:symbol
			accessibilityDescription:nil];
	cell.imageView.contentTintColor = tint;
	cell.textField.textColor = color;
	return cell;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
	[self updateButtons];
}

@end
