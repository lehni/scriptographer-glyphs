//
//  SGWindowController.m
//  Scriptographer for Glyphs
//

#import "SGWindowController.h"
#import "SGRuntime.h"
#import <GlyphsCore/GlyphsCore.h>
#import <GlyphsApp/GlyphsApp.h>

@interface SGWindowController () <NSTableViewDataSource, NSTableViewDelegate,
		NSTextFieldDelegate, NSWindowDelegate>
@end

@implementation SGWindowController {
	NSURL *_scriptsURL;
	NSArray<NSURL *> *_scripts;
	NSTableView *_tableView;
	NSTextView *_consoleView;
	NSTextField *_inputField;
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
	NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 320, 520)
			styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
				| NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow
			backing:NSBackingStoreBuffered defer:YES];
	panel.title = @"Scriptographer";
	panel.floatingPanel = YES;
	panel.hidesOnDeactivate = YES;
	panel.becomesKeyOnlyIfNeeded = YES;
	panel.frameAutosaveName = @"Scriptographer";
	self = [super initWithWindow:panel];
	if (self) {
		panel.delegate = self;
		[self setupScripts];
		[self setupViews];
		SGRuntime *runtime = [SGRuntime sharedRuntime];
		__weak SGWindowController *weakSelf = self;
		runtime.printHandler = ^(NSString *line) {
			[weakSelf appendToConsole:line];
		};
		runtime.stateHandler = ^{
			[weakSelf reloadScripts];
		};
		[panel center];
	}
	return self;
}

#pragma mark - Scripts

// The scripts folder, with the examples on first use:
- (void)setupScripts {
	NSFileManager *files = [NSFileManager defaultManager];
	NSURL *support = [[files URLsForDirectory:NSApplicationSupportDirectory
			inDomains:NSUserDomainMask] firstObject];
	_scriptsURL = [support URLByAppendingPathComponent:@"Scriptographer/Scripts"
			isDirectory:YES];
	if (![files fileExistsAtPath:_scriptsURL.path]) {
		[files createDirectoryAtURL:_scriptsURL withIntermediateDirectories:YES
				attributes:nil error:nil];
		NSURL *examples = [[NSBundle bundleForClass:[self class]]
				URLForResource:@"Examples" withExtension:nil];
		for (NSURL *url in [files contentsOfDirectoryAtURL:examples
				includingPropertiesForKeys:nil options:0 error:nil]) {
			[files copyItemAtURL:url toURL:[_scriptsURL
					URLByAppendingPathComponent:url.lastPathComponent]
					error:nil];
		}
	}
	[self reloadScripts];
}

- (void)reloadScripts {
	NSMutableArray *scripts = [NSMutableArray array];
	NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager]
			enumeratorAtURL:_scriptsURL includingPropertiesForKeys:nil
			options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
	for (NSURL *url in enumerator) {
		if ([url.pathExtension isEqualToString:@"js"])
			[scripts addObject:url];
	}
	[scripts sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
		return [a.path localizedStandardCompare:b.path];
	}];
	_scripts = scripts;
	[_tableView reloadData];
}

- (NSURL *)selectedScript {
	NSInteger row = _tableView.clickedRow >= 0
			? _tableView.clickedRow
			: _tableView.selectedRow;
	return row >= 0 && row < (NSInteger)_scripts.count ? _scripts[row] : nil;
}

- (void)runScript:(id)sender {
	NSURL *url = [self selectedScript];
	SGRuntime *runtime = [SGRuntime sharedRuntime];
	if (url && [runtime runScriptAtURL:url]
			&& [url.path isEqualToString:runtime.toolScriptURL.path]) {
		// Tool scripts select the Script tool:
		GSDocument *document = (GSDocument *)
				[[NSDocumentController sharedDocumentController] currentDocument];
		if ([document isKindOfClass:[GSDocument class]]) {
			[document.windowController
					setToolForClass:NSClassFromString(@"SGScriptTool")];
		}
	}
}

- (void)stopScript:(id)sender {
	NSURL *url = [self selectedScript];
	if (url)
		[[SGRuntime sharedRuntime] stopScriptAtURL:url];
}

- (void)revealScripts:(id)sender {
	NSURL *url = [self selectedScript];
	[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:
			@[url ?: _scriptsURL]];
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
	[self reloadScripts];
}

#pragma mark - Views

- (NSButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
	NSButton *button = [NSButton buttonWithTitle:title target:self
			action:action];
	button.controlSize = NSControlSizeSmall;
	button.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
	return button;
}

- (void)setupViews {
	// The scripts:
	_tableView = [[NSTableView alloc] init];
	NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"name"];
	column.resizingMask = NSTableColumnAutoresizingMask;
	[_tableView addTableColumn:column];
	_tableView.headerView = nil;
	_tableView.dataSource = self;
	_tableView.delegate = self;
	_tableView.target = self;
	_tableView.doubleAction = @selector(runScript:);
	_tableView.style = NSTableViewStyleSourceList;
	NSScrollView *scriptsScroll = [[NSScrollView alloc] init];
	scriptsScroll.documentView = _tableView;
	scriptsScroll.hasVerticalScroller = YES;

	NSStackView *buttons = [NSStackView stackViewWithViews:@[
		[self buttonWithTitle:@"Run" action:@selector(runScript:)],
		[self buttonWithTitle:@"Stop" action:@selector(stopScript:)],
		[self buttonWithTitle:@"Reveal" action:@selector(revealScripts:)]
	]];
	buttons.spacing = 6;

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

	NSSplitView *split = [[NSSplitView alloc] init];
	split.vertical = NO;
	split.dividerStyle = NSSplitViewDividerStyleThin;
	[split addArrangedSubview:top];
	[split addArrangedSubview:bottom];
	self.window.contentView = split;
	[split setPosition:280 ofDividerAtIndex:0];
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

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
	return _scripts.count;
}

- (NSView *)tableView:(NSTableView *)tableView
		viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
	NSTableCellView *cell = [tableView makeViewWithIdentifier:@"script"
			owner:self];
	if (!cell) {
		cell = [[NSTableCellView alloc] init];
		cell.identifier = @"script";
		NSTextField *field = [NSTextField labelWithString:@""];
		field.translatesAutoresizingMaskIntoConstraints = NO;
		[cell addSubview:field];
		cell.textField = field;
		[field.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor
				constant:2].active = YES;
		[field.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
				.active = YES;
	}
	NSURL *url = _scripts[row];
	SGRuntime *runtime = [SGRuntime sharedRuntime];
	NSString *name = [url.path substringFromIndex:_scriptsURL.path.length + 1]
			.stringByDeletingPathExtension;
	// Running scripts are marked, and the tool's script as such:
	NSString *mark = [url.path isEqualToString:runtime.toolScriptURL.path]
			? @"✎ "
			: [runtime isScriptRunningAtURL:url] ? @"▶︎ " : @"";
	cell.textField.stringValue = [mark stringByAppendingString:name];
	return cell;
}

@end
