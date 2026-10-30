//
//  SGSVGPath.h
//  Scriptographer for Glyphs
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// Adds SVG path data to `path`, as `new Path2D(data)` takes it: up to the
// first error, as browsers parse it, with all of SVG's commands, relative ones
// and arcs too.
void SGAddSVGPath(CGMutablePathRef path, NSString *data);

NS_ASSUME_NONNULL_END
