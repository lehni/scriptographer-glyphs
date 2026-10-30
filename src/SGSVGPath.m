//
//  SGSVGPath.m
//  Scriptographer for Glyphs
//

#import "SGSVGPath.h"

// Reads SVG path data a number, a flag or a command at a time.
typedef struct {
	const char *text;
	size_t at, length;
} Reader;

static void skip(Reader *reader, BOOL comma) {
	while (reader->at < reader->length) {
		char c = reader->text[reader->at];
		if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'
				|| (comma && c == ',')) {
			reader->at++;
			if (c == ',')
				comma = NO;
		} else {
			break;
		}
	}
}

static BOOL readNumber(Reader *reader, double *number) {
	skip(reader, YES);
	const char *start = reader->text + reader->at;
	char *end;
	*number = strtod(start, &end);
	// strtod takes what SVG doesn't: hex, infinity and nan.
	if (end == start || !isfinite(*number))
		return NO;
	for (const char *c = start; c < end; c++) {
		if (*c == 'x' || *c == 'X' || *c == 'n' || *c == 'N' || *c == 'i'
				|| *c == 'I')
			return NO;
	}
	reader->at += end - start;
	return YES;
}

static BOOL readFlag(Reader *reader, BOOL *flag) {
	skip(reader, YES);
	if (reader->at >= reader->length)
		return NO;
	char c = reader->text[reader->at];
	if (c != '0' && c != '1')
		return NO;
	*flag = c == '1';
	reader->at++;
	return YES;
}

// An SVG arc, from `from` to `to`, as cubic curves (SVG 1.1, appendix F.6):
static void addArc(CGMutablePathRef path, CGPoint from, double rx, double ry,
		double angle, BOOL large, BOOL sweep, CGPoint to) {
	if (CGPointEqualToPoint(from, to))
		return;
	rx = fabs(rx);
	ry = fabs(ry);
	if (rx == 0 || ry == 0) {
		CGPathAddLineToPoint(path, NULL, to.x, to.y);
		return;
	}
	double phi = angle * M_PI / 180, c = cos(phi), s = sin(phi);
	double dx = (from.x - to.x) / 2, dy = (from.y - to.y) / 2;
	double x1 = c * dx + s * dy, y1 = -s * dx + c * dy;
	double lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry);
	if (lambda > 1) {
		rx *= sqrt(lambda);
		ry *= sqrt(lambda);
	}
	double numerator = rx * rx * ry * ry - rx * rx * y1 * y1
			- ry * ry * x1 * x1;
	double factor = sqrt(MAX(numerator, 0)
			/ (rx * rx * y1 * y1 + ry * ry * x1 * x1));
	if (large == sweep)
		factor = -factor;
	double cx1 = factor * rx * y1 / ry, cy1 = -factor * ry * x1 / rx;
	double cx = c * cx1 - s * cy1 + (from.x + to.x) / 2;
	double cy = s * cx1 + c * cy1 + (from.y + to.y) / 2;
	double start = atan2((y1 - cy1) / ry, (x1 - cx1) / rx);
	double delta = atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx) - start;
	if (sweep && delta < 0)
		delta += 2 * M_PI;
	else if (!sweep && delta > 0)
		delta -= 2 * M_PI;
	CGAffineTransform matrix = CGAffineTransformScale(
			CGAffineTransformRotate(CGAffineTransformMakeTranslation(cx, cy),
				phi), rx, ry);
	CGPathAddRelativeArc(path, &matrix, 0, 0, 1, start, delta);
}

void SGAddSVGPath(CGMutablePathRef path, NSString *data) {
	NSData *bytes = [data dataUsingEncoding:NSUTF8StringEncoding];
	Reader reader = { bytes.bytes, 0, bytes.length };
	CGPoint current = CGPointZero, start = CGPointZero, control = CGPointZero;
	char command = 0, previous = 0;
	BOOL isFirst = YES;
	while (YES) {
		skip(&reader, NO);
		if (reader.at >= reader.length)
			return;
		char c = reader.text[reader.at];
		if (isalpha(c)) {
			command = c;
			reader.at++;
		} else if (!command || command == 'z' || command == 'Z') {
			// Numbers go on with the last command, but none after a close:
			return;
		} else {
			// Repeated moves are lines:
			command = command == 'm' ? 'l' : command == 'M' ? 'L' : command;
		}
		// The data starts with a move:
		if (isFirst && command != 'm' && command != 'M')
			return;
		isFirst = NO;
		BOOL relative = islower(command);
		double ox = relative ? current.x : 0, oy = relative ? current.y : 0;
		double n[7];
		BOOL flags[2];
		char upper = toupper(command);
		switch (upper) {
		case 'Z':
			CGPathCloseSubpath(path);
			current = start;
			break;
		case 'M':
		case 'L':
		case 'T':
			if (!readNumber(&reader, &n[0]) || !readNumber(&reader, &n[1]))
				return;
			n[0] += ox;
			n[1] += oy;
			if (upper == 'M') {
				CGPathMoveToPoint(path, NULL, n[0], n[1]);
				start = CGPointMake(n[0], n[1]);
			} else if (upper == 'L') {
				CGPathAddLineToPoint(path, NULL, n[0], n[1]);
			} else {
				// The control point mirrors the last quadratic one's:
				BOOL isQuad = strchr("QqTt", previous) != NULL;
				control = isQuad ? CGPointMake(2 * current.x - control.x,
						2 * current.y - control.y) : current;
				CGPathAddQuadCurveToPoint(path, NULL, control.x, control.y,
						n[0], n[1]);
			}
			current = CGPointMake(n[0], n[1]);
			break;
		case 'H':
		case 'V':
			if (!readNumber(&reader, &n[0]))
				return;
			if (upper == 'H')
				current.x = n[0] + ox;
			else
				current.y = n[0] + oy;
			CGPathAddLineToPoint(path, NULL, current.x, current.y);
			break;
		case 'C':
		case 'S':
		case 'Q': {
			int count = upper == 'C' ? 6 : 4;
			for (int i = 0; i < count; i++) {
				if (!readNumber(&reader, &n[i]))
					return;
				n[i] += i % 2 ? oy : ox;
			}
			if (upper == 'Q') {
				control = CGPointMake(n[0], n[1]);
				CGPathAddQuadCurveToPoint(path, NULL, n[0], n[1], n[2], n[3]);
				current = CGPointMake(n[2], n[3]);
			} else {
				CGPoint first;
				if (upper == 'S') {
					BOOL isCubic = strchr("CcSs", previous) != NULL;
					first = isCubic ? CGPointMake(2 * current.x - control.x,
							2 * current.y - control.y) : current;
					memmove(n + 2, n, 4 * sizeof(double));
				} else {
					first = CGPointMake(n[0], n[1]);
				}
				CGPathAddCurveToPoint(path, NULL, first.x, first.y, n[2], n[3],
						n[4], n[5]);
				control = CGPointMake(n[2], n[3]);
				current = CGPointMake(n[4], n[5]);
			}
			break;
		}
		case 'A':
			if (!readNumber(&reader, &n[0]) || !readNumber(&reader, &n[1])
					|| !readNumber(&reader, &n[2])
					|| !readFlag(&reader, &flags[0])
					|| !readFlag(&reader, &flags[1])
					|| !readNumber(&reader, &n[3])
					|| !readNumber(&reader, &n[4]))
				return;
			n[3] += ox;
			n[4] += oy;
			addArc(path, current, n[0], n[1], n[2], flags[0], flags[1],
					CGPointMake(n[3], n[4]));
			current = CGPointMake(n[3], n[4]);
			break;
		default:
			return;
		}
		previous = command;
	}
}
