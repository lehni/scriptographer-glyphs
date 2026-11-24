//
//  SGConsoleController.m
//  Scriptographer for Glyphs
//

#import "SGConsoleController.h"
#import "SGRuntime.h"

static const NSUInteger maxLines = 1000;

// The divider between the input and the log: as wide as the gaps between the
// panel's views, with a grip in the middle, as the sidebar's sections have.
@interface SGConsoleSplitView : NSSplitView
@end

@implementation SGConsoleSplitView

- (CGFloat)dividerThickness {
	return 6;
}

- (void)drawDividerInRect:(NSRect)rect {
	NSRect grip = NSMakeRect(NSMidX(rect) - 12, NSMidY(rect) - 1, 24, 2);
	[NSColor.tertiaryLabelColor setFill];
	[[NSBezierPath bezierPathWithRoundedRect:grip xRadius:1 yRadius:1] fill];
}

@end

@interface SGConsoleController () <NSTextViewDelegate>
@end

@implementation SGConsoleController {
	NSTextView *_inputView;
	NSTextView *_logView;
	NSUInteger _lineCount;
}

+ (void)addMenuItem {
	NSMenuItem *item = [[NSMenuItem alloc]
			initWithTitle:@"Scriptographer Console"
			action:@selector(showConsole:) keyEquivalent:@""];
	item.target = self;
	[[NSApp windowsMenu] addItem:item];
	// Made now, to keep what the scripts print from the start:
	[self sharedController];
}

+ (void)showConsole:(id)sender {
	[[self sharedController] show];
}

+ (instancetype)sharedController {
	static SGConsoleController *controller;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		controller = [[SGConsoleController alloc] init];
	});
	return controller;
}

- (instancetype)init {
	self = [super initWithTitle:@"Scriptographer Console"
			size:NSMakeSize(420, 300)];
	if (self) {
		[self setupViews];
		__weak SGConsoleController *weakSelf = self;
		SGRuntime *runtime = [SGRuntime sharedRuntime];
		runtime.printHandler = ^(NSString *line) {
			[weakSelf appendLine:line];
		};
		// Errors show, as in VectorCraft:
		runtime.failureHandler = ^{
			[weakSelf show];
		};
	}
	return self;
}

- (void)setupViews {
	NSFont *font = [NSFont monospacedSystemFontOfSize:11
			weight:NSFontWeightRegular];
	// The input, two lines high at first, and at least one, over the log,
	// with the divider between them to resize it, which the log follows:
	CGFloat lineHeight = ceil(font.ascender - font.descender + font.leading);
	NSScrollView *inputScroll = [NSTextView scrollableTextView];
	_inputView = inputScroll.documentView;
	_inputView.font = font;
	_inputView.richText = NO;
	_inputView.automaticQuoteSubstitutionEnabled = NO;
	_inputView.automaticDashSubstitutionEnabled = NO;
	_inputView.delegate = self;
	inputScroll.borderType = NSBezelBorder;
	inputScroll.frame = NSMakeRect(0, 0, 100, lineHeight * 2 + 8);
	[inputScroll.heightAnchor constraintGreaterThanOrEqualToConstant:
			lineHeight + 8].active = YES;

	// The log keeps a few lines, so neither the divider nor the sidebar can
	// hide it:
	NSScrollView *logScroll = [NSTextView scrollableTextView];
	_logView = logScroll.documentView;
	_logView.editable = NO;
	_logView.font = font;
	[logScroll.heightAnchor constraintGreaterThanOrEqualToConstant:
			lineHeight * 3 + 8].active = YES;

	NSSplitView *split = [[SGConsoleSplitView alloc] init];
	[split addArrangedSubview:inputScroll];
	[split addArrangedSubview:logScroll];
	// The log takes the height that the input leaves, also as the panel
	// resizes:
	[split setHoldingPriority:1 forSubviewAtIndex:1];
	split.autosaveName = @"Scriptographer Console Input";

	// The bottom bar, with Clear Console, Scriptographer's refresh arrows:
	NSButton *clear = [NSButton buttonWithImage:[NSImage
			imageWithSystemSymbolName:@"arrow.clockwise"
			accessibilityDescription:@"Clear Console"]
			target:self action:@selector(clear:)];
	clear.bordered = NO;
	clear.toolTip = @"Clear Console";
	[clear.widthAnchor constraintEqualToConstant:24].active = YES;

	[self setContentViews:@[split]
			buttons:[NSStackView stackViewWithViews:@[clear]]];
}

- (void)appendLine:(NSString *)line {
	NSDictionary *attributes = @{
		NSFontAttributeName: _logView.font,
		NSForegroundColorAttributeName: NSColor.textColor
	};
	NSTextStorage *log = _logView.textStorage;
	[log appendAttributedString:[[NSAttributedString alloc] initWithString:
			[line stringByAppendingString:@"\n"] attributes:attributes]];
	// The last lines only, as many as VectorCraft keeps:
	_lineCount += [line componentsSeparatedByString:@"\n"].count;
	if (_lineCount > maxLines) {
		NSString *text = log.string;
		NSUInteger end = 0;
		for (; _lineCount > maxLines; _lineCount--)
			end = NSMaxRange([text lineRangeForRange:NSMakeRange(end, 0)]);
		[log deleteCharactersInRange:NSMakeRange(0, end)];
	}
	[_logView scrollToEndOfDocument:nil];
}

- (void)clear:(id)sender {
	_logView.string = @"";
	_lineCount = 0;
}

// Return goes to a new line as usual, and runs the line it ends. The text
// stays, to run lines again.
- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
	if (selector != @selector(insertNewline:))
		return NO;
	NSString *text = textView.string;
	NSUInteger cursor = textView.selectedRange.location;
	NSRange line = [text lineRangeForRange:NSMakeRange(cursor, 0)];
	NSString *code = [[text substringWithRange:NSMakeRange(line.location,
			cursor - line.location)] stringByTrimmingCharactersInSet:
				NSCharacterSet.whitespaceCharacterSet];
	[textView insertNewlineIgnoringFieldEditor:nil];
	if (code.length) {
		[self appendLine:[@"> " stringByAppendingString:code]];
		[[SGRuntime sharedRuntime] evaluate:code];
	}
	return YES;
}

@end
