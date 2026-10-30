//
//  SGScriptTool.m
//  Scriptographer for Glyphs
//

#import <Cocoa/Cocoa.h>
#import <GlyphsCore/GlyphsCore.h>
#import <GlyphsApp/GlyphsApp.h>
#import "SGRuntime.h"
#import "SGScript.h"
#import "SGWindowController.h"

// The tool in Glyphs' toolbar that hands its mouse and key events to the
// script that last defined tool handlers. Loading it also adds Scriptographer
// to the Window menu.
@interface SGScriptTool : GlyphsPathPlugin
@end

@implementation SGScriptTool {
	NSImage *_icon;
	// The layer of the current drag and its shapes before, to make the whole
	// drag one undo step:
	GSLayer *_dragLayer;
	NSArray<GSShape *> *_dragShapes;
	NSUInteger _dragEditCount;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		_icon = [[NSImage imageWithSystemSymbolName:@"scribble.variable"
				accessibilityDescription:@"Script"]
				imageWithSymbolConfiguration:[NSImageSymbolConfiguration
					configurationWithPointSize:17 weight:NSFontWeightRegular]];
		_icon.template = YES;
		[self hideNodes];
		static dispatch_once_t once;
		dispatch_once(&once, ^{
			dispatch_async(dispatch_get_main_queue(), ^{
				[SGPanelController addSections];
				[SGWindowController addMenuItem];
				[SGWindowController runInitScripts];
			});
		});
	}
	return self;
}

// Paths show as outlines while scripts draw, without their nodes and
// handles, as in Scriptographer. Glyphs draws them by its `_showNodes`, which
// it sets from View › Show Nodes, not by asking `showNodes`:
- (void)hideNodes {
	[self setValue:@NO forKey:@"showNodes"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
		change:(NSDictionary *)change context:(void *)context {
	[super observeValueForKeyPath:keyPath ofObject:object change:change
			context:context];
	[self hideNodes];
}

- (NSUInteger)interfaceVersion {
	return 1;
}

- (NSUInteger)groupID {
	return 60;
}

- (NSString *)title {
	NSString *name = [SGRuntime sharedRuntime].toolScript.name;
	return name ? [NSString stringWithFormat:@"Script: %@", name] : @"Script";
}

- (NSImage *)toolBarIcon {
	return _icon;
}

// The scripts' overlays, over the layer, in its coordinates:
- (void)drawForegroundForLayer:(GSLayer *)layer options:(NSDictionary *)options {
	double scale = [options[@"Scale"] doubleValue] ?: 1;
	[[SGRuntime sharedRuntime] drawOverlaysInContext:
			NSGraphicsContext.currentContext.CGContext scale:scale];
}

- (NSString *)trigger {
	return nil;
}

- (NSEventModifierFlags)tempTrigger {
	return 0;
}

- (BOOL)willSelectTempTool:(id)tempTool {
	return _dragLayer == nil;
}

#pragma mark - Events

- (GSLayer *)activeLayer {
	self.editViewController = [self.windowController activeEditViewController];
	return self.editViewController.graphicView.activeLayer;
}

- (NSPoint)locationOfEvent:(NSEvent *)event {
	return [self.editViewController.graphicView getActiveLocation:event];
}

- (void)handleMouse:(NSString *)type event:(NSEvent *)event {
	SGRuntime *runtime = [SGRuntime sharedRuntime];
	runtime.toolLayer = _dragLayer ?: [self activeLayer];
	[runtime handleMouse:type at:[self locationOfEvent:event]
			modifiers:event.modifierFlags];
	runtime.toolLayer = nil;
}

// Without a tool script, the tool selects and moves as Glyphs' own do:
- (BOOL)hasScript {
	return [SGRuntime sharedRuntime].toolScript != nil;
}

- (void)mouseDown:(NSEvent *)event {
	if (![self hasScript]) {
		[super mouseDown:event];
		return;
	}
	GSLayer *layer = [self activeLayer];
	if (layer) {
		// Changes during the drag register no undo, see -mouseUp:
		_dragLayer = layer;
		_dragShapes = [[NSArray alloc] initWithArray:layer.shapes
				copyItems:YES];
		_dragEditCount = [SGRuntime sharedRuntime].editCount;
		[layer.undoManager disableUndoRegistration];
	}
	[self handleMouse:@"mousedown" event:event];
}

- (void)mouseDragged:(NSEvent *)event {
	if (_dragLayer) {
		[self handleMouse:@"mousemove" event:event];
	} else {
		[super mouseDragged:event];
	}
}

- (void)mouseUp:(NSEvent *)event {
	GSLayer *layer = _dragLayer;
	if (layer) {
		[self handleMouse:@"mouseup" event:event];
		NSUndoManager *undoManager = layer.undoManager;
		// Register the whole drag as one change of the layer's shapes, from
		// the ones before to the ones now:
		if ([SGRuntime sharedRuntime].editCount != _dragEditCount) {
			NSArray *shapes = [layer.shapes copy];
			layer.shapes = _dragShapes;
			[undoManager enableUndoRegistration];
			layer.shapes = shapes;
			[undoManager setActionName:self.title];
		} else {
			[undoManager enableUndoRegistration];
		}
		_dragLayer = nil;
		_dragShapes = nil;
	} else {
		[super mouseUp:event];
	}
}

- (void)mouseMoved:(NSEvent *)event {
	if ([self hasScript] && !_dragLayer) {
		[self handleMouse:@"mousemove" event:event];
	} else {
		[super mouseMoved:event];
	}
}

- (void)keyDown:(NSEvent *)event {
	if (![[SGRuntime sharedRuntime] handleKey:@"keydown" event:event])
		[super keyDown:event];
}

- (void)keyUp:(NSEvent *)event {
	if (![[SGRuntime sharedRuntime] handleKey:@"keyup" event:event])
		[super keyUp:event];
}

@end
