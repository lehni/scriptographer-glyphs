//
//  SGCSSColor.m
//  Scriptographer for Glyphs
//

#import "SGCSSColor.h"
#import <xlocale.h>

// The color crate computes in f32, operation by operation: so does this, and
// clang mustn't fuse a multiplication and an addition into one.
#pragma clang fp contract(off)

#pragma mark - Colours

// The colour spaces, and a colour in one: its components as the color crate
// keeps them, and which of them are missing (`none`), a bit each.
typedef enum {
	Srgb, LinearSrgb, Lab, Lch, Hsl, Hwb, Oklab, Oklch, DisplayP3, A98Rgb,
	ProphotoRgb, Rec2020, XyzD50, XyzD65
} Space;

typedef enum { Shorter, Longer, Increasing, Decreasing } Direction;

typedef struct {
	Space space;
	unsigned missing;
	float c[4];
} Color;

typedef struct {
	float v[3];
} Vec3;

typedef float Matrix[3][3];

static Vec3 vec(float x, float y, float z) {
	return (Vec3){{ x, y, z }};
}

static Vec3 multiply(const Matrix m, Vec3 x) {
	Vec3 result;
	for (int i = 0; i < 3; i++)
		result.v[i] = m[i][0] * x.v[0] + m[i][1] * x.v[1] + m[i][2] * x.v[2];
	return result;
}

static Vec3 map(Vec3 x, float (*f)(float)) {
	return vec(f(x.v[0]), f(x.v[1]), f(x.v[2]));
}

// Rust's clamp, which lets NaN through:
static float clampf(float x, float min, float max) {
	return x < min ? min : x > max ? max : x;
}

static double clamp(double x, double min, double max) {
	return x < min ? min : x > max ? max : x;
}

// The component that is the hue, or -1:
static int hueIndex(Space space) {
	return space == Lch || space == Oklch ? 2
			: space == Hsl || space == Hwb ? 0 : -1;
}

// The components scaled by `scale`, but not the hue, to premultiply them:
static Vec3 scaled(Space space, Vec3 x, float scale) {
	int hue = hueIndex(space);
	for (int i = 0; i < 3; i++) {
		if (i != hue)
			x.v[i] = x.v[i] * scale;
	}
	return x;
}

#pragma mark - Conversions

static const float degreesPerRadian = 57.2957795130823208767981548141051703f;
static const float radiansPerDegree = 3.14159265358979323846f / 180.0f;

static float srgbToLinear(float x) {
	return fabsf(x) <= 0.04045f ? x * (1.0f / 12.92f)
			: copysignf(powf((fabsf(x) + 0.055f) * (1.0f / 1.055f), 2.4f), x);
}

static float linearToSrgb(float x) {
	return fabsf(x) <= 0.0031308f ? x * 12.92f
			: copysignf(1.055f * powf(fabsf(x), 1.0f / 2.4f) - 0.055f, x);
}

static float a98ToLinear(float x) {
	return copysignf(powf(fabsf(x), 563.f / 256.f), x);
}

static float linearToA98(float x) {
	return copysignf(powf(fabsf(x), 256.f / 563.f), x);
}

static float prophotoToLinear(float x) {
	return fabsf(x) <= 16.f / 512.f ? x / 16.f
			: copysignf(powf(fabsf(x), 1.8f), x);
}

static float linearToProphoto(float x) {
	return fabsf(x) <= 1.f / 512.f ? x * 16.f
			: copysignf(powf(fabsf(x), 1.f / 1.8f), x);
}

// Rec. 2020's transfer function, its parameters truncated to f32:
static const float rec2020A = 1.0992968f, rec2020B = 0.01805397f;

static float rec2020ToLinear(float x) {
	return fabsf(x) < rec2020B * 4.5f ? x * (1.f / 4.5f)
			: copysignf(powf((fabsf(x) + (rec2020A - 1.f)) / rec2020A,
				1.f / 0.45f), x);
}

static float linearToRec2020(float x) {
	return fabsf(x) < rec2020B ? x * 4.5f
			: copysignf(rec2020A * powf(fabsf(x), 0.45f) - (rec2020A - 1.f), x);
}

static float cube(float x) {
	return x * x * x;
}

static const Matrix p3ToSrgb = {
	{ 1.2249402f, -0.22494018f, 0.0f },
	{ -0.042056955f, 1.0420569f, 0.0f },
	{ -0.019637555f, -0.07863604f, 1.0982736f }
};
static const Matrix srgbToP3 = {
	{ 0.82246196f, 0.17753804f, 0.0f },
	{ 0.0331942f, 0.9668058f, 0.0f },
	{ 0.017082632f, 0.07239744f, 0.91051996f }
};
// The color crate's exact fractions, rounded to f32 once:
static const Matrix a98ToSrgb = {
	{ (float)(66942405. / 47872228.), (float)(-19070177. / 47872228.), 0.f },
	{ 0.f, 1.f, 0.f },
	{ 0.f, (float)(-11512411. / 268173353.), (float)(279685764. / 268173353.) }
};
static const Matrix srgbToA98 = {
	{ (float)(47872228. / 66942405.), (float)(19070177. / 66942405.), 0.f },
	{ 0.f, 1.f, 0.f },
	{ 0.f, (float)(11512411. / 279685764.), (float)(268173353. / 279685764.) }
};
static const Matrix prophotoToSrgb = {
	{ 2.0343676f, -0.7276345f, -0.30673307f },
	{ -0.22882679f, 1.2317533f, -0.002926598f },
	{ -0.008558424f, -0.1532682f, 1.1618266f }
};
static const Matrix srgbToProphoto = {
	{ 0.5292804f, 0.330153f, 0.1405666f },
	{ 0.09836622f, 0.8734639f, 0.028169824f },
	{ 0.016875342f, 0.11765941f, 0.8654652f }
};
static const Matrix rec2020ToSrgb = {
	{ (float)(2785571537. / 1677558947.), (float)(-985802650. / 1677558947.),
		(float)(-122209940. / 1677558947.) },
	{ (float)(-4638020506. / 37238079773.),
		(float)(42187016744. / 37238079773.),
		(float)(-310916465. / 37238079773.) },
	{ (float)(-97469024. / 5369968309.), (float)(-3780738464. / 37589778163.),
		(float)(42052799795. / 37589778163.) }
};
static const Matrix srgbToRec2020 = {
	{ (float)(2939026994. / 4684425795.), (float)(9255011753. / 28106554770.),
		(float)(173911579. / 4015222110.) },
	{ (float)(76515593. / 1107360270.), (float)(6109575001. / 6644161620.),
		(float)(75493061. / 6644161620.) },
	{ (float)(12225392. / 745840075.), (float)(1772384008. / 20137682025.),
		(float)(18035212433. / 20137682025.) }
};
static const Matrix xyzD50ToSrgb = {
	{ 3.134136f, -1.617386f, -0.49066222f },
	{ -0.97879547f, 1.9162544f, 0.033442874f },
	{ 0.07195539f, -0.22897676f, 1.4053861f }
};
static const Matrix srgbToXyzD50 = {
	{ 0.43606573f, 0.3851515f, 0.14307842f },
	{ 0.22249317f, 0.716887f, 0.06061981f },
	{ 0.013923922f, 0.097081326f, 0.71409935f }
};
// Fractions the crate divides in f32:
static const Matrix xyzD65ToSrgb = {
	{ 12831.f / 3959.f, -329.f / 214.f, -1974.f / 3959.f },
	{ -851781.f / 878810.f, 1648619.f / 878810.f, 36519.f / 878810.f },
	{ 705.f / 12673.f, -2585.f / 12673.f, 705.f / 667.f }
};
static const Matrix srgbToXyzD65 = {
	{ 506752.f / 1228815.f, 87881.f / 245763.f, 12673.f / 70218.f },
	{ 87098.f / 409605.f, 175762.f / 245763.f, 12673.f / 175545.f },
	{ 7918.f / 409605.f, 87881.f / 737289.f, 1001167.f / 1053270.f }
};
static const Matrix oklabToLms = {
	{ 1.0f, 0.39633778f, 0.21580376f },
	{ 1.0f, -0.105561346f, -0.06385417f },
	{ 1.0f, -0.08948418f, -1.2914855f }
};
static const Matrix lmsToSrgb = {
	{ 4.0767417f, -3.3077116f, 0.23096994f },
	{ -1.268438f, 2.6097574f, -0.34131938f },
	{ -0.0041960863f, -0.7034186f, 1.7076147f }
};
static const Matrix srgbToLms = {
	{ 0.41222146f, 0.53633255f, 0.051445995f },
	{ 0.2119035f, 0.6806995f, 0.10739696f },
	{ 0.08830246f, 0.28171885f, 0.6299787f }
};
static const Matrix lmsToOklab = {
	{ 0.21045426f, 0.7936178f, -0.004072047f },
	{ 1.9779985f, -2.4285922f, 0.4505937f },
	{ 0.025904037f, 0.78277177f, -0.80867577f }
};
static const Matrix srgbToLabXyz = {
	{ 0.45221165f, 0.39941224f, 0.14837609f },
	{ 0.22249317f, 0.716887f, 0.06061981f },
	{ 0.016875342f, 0.11765941f, 0.8654652f }
};
static const Matrix labXyzToSrgb = {
	{ 3.0222337f, -1.617386f, -0.40484765f },
	{ -0.94384825f, 1.9162544f, 0.027593868f },
	{ 0.06938627f, -0.22897676f, 1.1595905f }
};

static const float labEpsilon = 216.f / 24389.f;
static const float labKappa = 24389.f / 27.f;

static float labToXyz(float value) {
	return value > 0.20689656f ? value * value * value
			: (116.f / labKappa) * value - (16.f / labKappa);
}

static float xyzToLab(float value) {
	return value > labEpsilon ? cbrtf(value)
			: (labKappa / 116.f) * value + (16.f / 116.f);
}

static Vec3 labToLch(Vec3 lab) {
	float h = atan2f(lab.v[2], lab.v[1]) * degreesPerRadian;
	if (h < 0.0f)
		h += 360.0f;
	return vec(lab.v[0], hypotf(lab.v[2], lab.v[1]), h);
}

static Vec3 lchToLab(Vec3 lch) {
	float h = lch.v[2] * radiansPerDegree;
	return vec(lch.v[0], lch.v[1] * cosf(h), lch.v[1] * sinf(h));
}

static Vec3 hslToRgb(Vec3 hsl) {
	float saturation = hsl.v[1] * 0.01f, light = hsl.v[2] * 0.01f;
	float a = saturation * fminf(light, 1.0f - light);
	const float ns[3] = { 0.0f, 8.0f, 4.0f };
	Vec3 rgb;
	for (int i = 0; i < 3; i++) {
		float x = ns[i] + hsl.v[0] * (1.0f / 30.0f);
		float k = x - 12.0f * floorf(x * (1.0f / 12.0f));
		rgb.v[i] = light - a * clampf(fminf(k - 3.0f, 9.0f - k), -1.0f, 1.0f);
	}
	return rgb;
}

// `isHueTurned` turns the hue of a negative saturation, out of gamut:
static Vec3 rgbToHsl(Vec3 rgb, BOOL isHueTurned) {
	float r = rgb.v[0], g = rgb.v[1], b = rgb.v[2];
	float max = fmaxf(fmaxf(r, g), b), min = fminf(fminf(r, g), b);
	float hue = 0.0f, saturation = 0.0f;
	float light = 0.5f * (min + max), d = max - min;
	if (d > 1e-6f) {
		float denominator = fminf(light, 1.0f - light);
		if (fabsf(denominator) > 1e-6f)
			saturation = (max - light) / denominator;
		hue = max == r ? (g - b) / d
				: max == g ? (b - r) / d + 2.0f : (r - g) / d + 4.0f;
		hue *= 60.0f;
		if (isHueTurned && saturation < 0.0f) {
			hue += 180.0f;
			saturation = fabsf(saturation);
		}
		hue -= 360.f * floorf(hue * (1.0f / 360.0f));
	}
	return vec(hue, saturation * 100.0f, light * 100.0f);
}

static Vec3 hwbToRgb(Vec3 hwb) {
	float white = hwb.v[1] * 0.01f, black = hwb.v[2] * 0.01f;
	if (white + black >= 1.0f) {
		float gray = white / (white + black);
		return vec(gray, gray, gray);
	}
	Vec3 rgb = hslToRgb(vec(hwb.v[0], 100.f, 50.f));
	for (int i = 0; i < 3; i++)
		rgb.v[i] = white + rgb.v[i] * (1.0f - white - black);
	return rgb;
}

static Vec3 rgbToHwb(Vec3 rgb) {
	float r = rgb.v[0], g = rgb.v[1], b = rgb.v[2];
	Vec3 hsl = rgbToHsl(rgb, NO);
	float white = fminf(fminf(r, g), b), black = 1.0f - fmaxf(fmaxf(r, g), b);
	return vec(hsl.v[0], white * 100.f, black * 100.f);
}

static Vec3 toLinear(Space space, Vec3 x) {
	switch (space) {
	case Srgb: return map(x, srgbToLinear);
	case LinearSrgb: return x;
	case Lab: {
		float f1 = x.v[0] * (1.f / 116.f) + (16.f / 116.f);
		float f0 = x.v[1] * (1.f / 500.f) + f1;
		float f2 = f1 - x.v[2] * (1.f / 200.f);
		return multiply(labXyzToSrgb, map(vec(f0, f1, f2), labToXyz));
	}
	case Lch: return toLinear(Lab, lchToLab(x));
	case Hsl: return map(hslToRgb(x), srgbToLinear);
	case Hwb: return map(hwbToRgb(x), srgbToLinear);
	case Oklab: return multiply(lmsToSrgb, map(multiply(oklabToLms, x), cube));
	case Oklch: return toLinear(Oklab, lchToLab(x));
	case DisplayP3: return multiply(p3ToSrgb, map(x, srgbToLinear));
	case A98Rgb: return multiply(a98ToSrgb, map(x, a98ToLinear));
	case ProphotoRgb: return multiply(prophotoToSrgb, map(x, prophotoToLinear));
	case Rec2020: return multiply(rec2020ToSrgb, map(x, rec2020ToLinear));
	case XyzD50: return multiply(xyzD50ToSrgb, x);
	case XyzD65: return multiply(xyzD65ToSrgb, x);
	}
}

static Vec3 fromLinear(Space space, Vec3 x) {
	switch (space) {
	case Srgb: return map(x, linearToSrgb);
	case LinearSrgb: return x;
	case Lab: {
		Vec3 f = map(multiply(srgbToLabXyz, x), xyzToLab);
		return vec(116.f * f.v[1] - 16.f, 500.f * (f.v[0] - f.v[1]),
				200.f * (f.v[1] - f.v[2]));
	}
	case Lch: return labToLch(fromLinear(Lab, x));
	case Hsl: return rgbToHsl(map(x, linearToSrgb), YES);
	case Hwb: return rgbToHwb(map(x, linearToSrgb));
	case Oklab: return multiply(lmsToOklab, map(multiply(srgbToLms, x), cbrtf));
	case Oklch: return labToLch(fromLinear(Oklab, x));
	case DisplayP3: return map(multiply(srgbToP3, x), linearToSrgb);
	case A98Rgb: return map(multiply(srgbToA98, x), linearToA98);
	case ProphotoRgb: return map(multiply(srgbToProphoto, x), linearToProphoto);
	case Rec2020: return map(multiply(srgbToRec2020, x), linearToRec2020);
	case XyzD50: return multiply(srgbToXyzD50, x);
	case XyzD65: return multiply(srgbToXyzD65, x);
	}
}

// The crate's shortcuts between related spaces, else through linear sRGB:
static Vec3 convertComponents(Space from, Space to, Vec3 x) {
	if ((from == Oklab && to == Oklch) || (from == Lab && to == Lch))
		return labToLch(x);
	if ((from == Oklch && to == Oklab) || (from == Lch && to == Lab))
		return lchToLab(x);
	if (from == Srgb && to == Hsl)
		return rgbToHsl(x, YES);
	if (from == Hsl && to == Srgb)
		return hslToRgb(x);
	if (from == Srgb && to == Hwb)
		return rgbToHwb(x);
	if (from == Hwb && to == Srgb)
		return hwbToRgb(x);
	if (from == Hsl && to == Hwb)
		return rgbToHwb(hslToRgb(x));
	if (from == Hwb && to == Hsl)
		return rgbToHsl(hwbToRgb(x), YES);
	return fromLinear(to, toLinear(from, x));
}

#pragma mark - Missing components

static BOOL isRectangular(Space space) {
	return space != Lab && space != Lch && space != Oklab && space != Oklch
			&& space != Hsl && space != Hwb;
}

static BOOL isLabLike(Space space) {
	return space == Lab || space == Lch || space == Oklab || space == Oklch;
}

static BOOL isAnalogous(Space a, Space b) {
	return (isRectangular(a) && isRectangular(b))
			|| ((a == Lab || a == Oklab) && (b == Lab || b == Oklab))
			|| ((a == Lch || a == Oklch) && (b == Lch || b == Oklch));
}

// The component that is the lightness, the chroma or saturation, or -1:
static int lightnessIndex(Space space) {
	return isLabLike(space) ? 0 : space == Hsl ? 2 : -1;
}

static int chromaIndex(Space space) {
	return isLabLike(space) || space == Hsl ? 1 : -1;
}

static void setMissing(Color *color, int index) {
	if (index >= 0) {
		color->missing |= 1 << index;
		color->c[index] = 0.0f;
	}
}

static BOOL isMissing(unsigned missing, int index) {
	return index >= 0 && (missing & (1 << index));
}

// CSS Color 4 § 12.2: missing components carry over to analogous ones.
static Color convert(Color color, Space space) {
	if (color.space == space)
		return color;
	Vec3 x = convertComponents(color.space, space,
			vec(color.c[0], color.c[1], color.c[2]));
	Color result = { space, 0, { x.v[0], x.v[1], x.v[2], color.c[3] } };
	unsigned missing = color.missing;
	if (missing && isAnalogous(color.space, space)) {
		for (int i = 0; i < 4; i++) {
			if (missing & (1 << i))
				result.c[i] = 0.0f;
		}
		result.missing = missing;
	} else if (missing) {
		result.missing = missing & 8;
		if (isMissing(missing, hueIndex(color.space)))
			setMissing(&result, hueIndex(space));
		if (isMissing(missing, chromaIndex(color.space)))
			setMissing(&result, chromaIndex(space));
		if (isMissing(missing, lightnessIndex(color.space)))
			setMissing(&result, lightnessIndex(space));
	}
	// Powerless hues are missing:
	if (((space == Hsl || space == Lch || space == Oklch) && result.c[1] < 1e-6f)
			|| (space == Hwb && result.c[1] + result.c[2] > 100.f - 1e-4f))
		setMissing(&result, hueIndex(space));
	return result;
}

#pragma mark - Interpolation

// CSS Color 4 § 12.4, changing the second hue only:
static float fixedHue(float h1, float h2, Direction direction) {
	float dh = (h2 - h1) * (1.f / 360.f);
	switch (direction) {
	case Shorter:
		return h2 - 360.f * copysignf(ceilf((fabsf(dh) - 0.25f) - 0.25f), dh);
	case Longer: {
		float t = 2.0f * ceilf(fabsf(dh)) - floorf(fabsf(dh) + 1.5f);
		return h2 + 360.0f * copysignf(t, 0.0f - dh);
	}
	case Increasing: return h2 - 360.0f * floorf(dh);
	case Decreasing: return h2 - 360.0f * ceilf(dh);
	}
}

// `a` and `b` mixed at `t` in `space`, premultiplied, as the crate's
// interpolator evaluates them:
static Color interpolate(Color a, Color b, Space space, Direction direction,
		float t) {
	a = convert(a, space);
	b = convert(b, space);
	unsigned missing = a.missing & b.missing;
	for (int i = 0; i < 4; i++) {
		if ((a.missing & ~b.missing) & (1 << i))
			a.c[i] = b.c[i];
		else if ((~a.missing & b.missing) & (1 << i))
			b.c[i] = a.c[i];
	}
	Vec3 x1 = vec(a.c[0], a.c[1], a.c[2]), x2 = vec(b.c[0], b.c[1], b.c[2]);
	float alpha1 = a.c[3], alpha2 = b.c[3];
	if (!(alpha1 == 1.0f || (a.missing & 8)))
		x1 = scaled(space, x1, alpha1);
	if (!(alpha2 == 1.0f || (b.missing & 8)))
		x2 = scaled(space, x2, alpha2);
	int hue = hueIndex(space);
	if (hue >= 0)
		x2.v[hue] = fixedHue(x1.v[hue], x2.v[hue], direction);
	Vec3 x;
	for (int i = 0; i < 3; i++)
		x.v[i] = x1.v[i] + t * (x2.v[i] - x1.v[i]);
	float alpha = alpha1 + t * (alpha2 - alpha1);
	if (alpha != 0.0f && alpha != 1.0f)
		x = scaled(space, x, 1.0f / alpha);
	return (Color){ space, missing, { x.v[0], x.v[1], x.v[2], alpha } };
}

#pragma mark - Text

// ASCII's classes, whatever the locale:
static BOOL isDigit(char c) {
	return c >= '0' && c <= '9';
}

static BOOL isAlpha(char c) {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static int hexDigit(char c) {
	return isDigit(c) ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10
			: c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
}

// A piece of UTF-8 text, not terminated:
typedef struct {
	const char *p;
	size_t n;
} Text;

static Text textOf(const char *string) {
	return (Text){ string, strlen(string) };
}

static BOOL isText(Text text, const char *string) {
	size_t n = strlen(string);
	return text.n == n && !memcmp(text.p, string, n);
}

static BOOL hasPrefix(Text text, const char *string) {
	size_t n = strlen(string);
	return text.n >= n && !memcmp(text.p, string, n);
}

// The length of the white space (Unicode's White_Space, as Rust trims it)
// that `p` starts with, or ends with when `isEnd`:
static size_t spaceLength(const unsigned char *p, size_t n, BOOL isEnd) {
	static const char *const spaces[] = {
		"\xc2\x85", "\xc2\xa0", "\xe1\x9a\x80", "\xe2\x80\x80", "\xe2\x80\x81",
		"\xe2\x80\x82", "\xe2\x80\x83", "\xe2\x80\x84", "\xe2\x80\x85",
		"\xe2\x80\x86", "\xe2\x80\x87", "\xe2\x80\x88", "\xe2\x80\x89",
		"\xe2\x80\x8a", "\xe2\x80\xa8", "\xe2\x80\xa9", "\xe2\x80\xaf",
		"\xe2\x81\x9f", "\xe3\x80\x80"
	};
	if (!n)
		return 0;
	unsigned char c = isEnd ? p[n - 1] : p[0];
	if (c == ' ' || (c >= '\t' && c <= '\r'))
		return 1;
	for (size_t i = 0; i < sizeof(spaces) / sizeof(*spaces); i++) {
		size_t length = strlen(spaces[i]);
		if (n >= length && !memcmp(isEnd ? p + n - length : p, spaces[i],
				length))
			return length;
	}
	return 0;
}

static Text trimmed(Text text) {
	size_t length;
	while ((length = spaceLength((const unsigned char *)text.p, text.n, NO))) {
		text.p += length;
		text.n -= length;
	}
	while ((length = spaceLength((const unsigned char *)text.p, text.n, YES)))
		text.n -= length;
	return text;
}

// `text` split at `separator` outside parentheses, trimmed, without empty
// parts: the first `capacity` of them, and how many there are.
static size_t split(Text text, char separator, Text *parts, size_t capacity) {
	size_t count = 0, start = 0;
	long depth = 0;
	for (size_t i = 0; i <= text.n; i++) {
		char c = i < text.n ? text.p[i] : 0;
		if (i < text.n && c == '(') {
			depth++;
		} else if (i < text.n && c == ')') {
			depth--;
		} else if (i == text.n || (c == separator && depth == 0)) {
			Text part = trimmed((Text){ text.p + start, i - start });
			if (part.n) {
				if (count < capacity)
					parts[count] = part;
				count++;
			}
			start = i + 1;
		}
	}
	return count;
}

// The arguments of the function `name` in `css`, which the end of `css`
// closes too:
static BOOL getArguments(Text css, const char *name, Text *arguments) {
	size_t n = strlen(name);
	if (!hasPrefix(css, name) || css.n <= n || css.p[n] != '(')
		return NO;
	*arguments = (Text){ css.p + n + 1, css.n - n - 1 };
	if (arguments->n && arguments->p[arguments->n - 1] == ')')
		arguments->n--;
	return YES;
}

// A number as Rust's `str::parse::<f64>()` reads it, finite or not:
static BOOL parseDouble(Text text, double *value) {
	size_t i = 0, digits = 0;
	if (i < text.n && (text.p[i] == '+' || text.p[i] == '-'))
		i++;
	for (; i < text.n && isDigit(text.p[i]); i++)
		digits++;
	if (i < text.n && text.p[i] == '.') {
		for (i++; i < text.n && isDigit(text.p[i]); i++)
			digits++;
	}
	if (!digits)
		return NO;
	if (i < text.n && (text.p[i] == 'e' || text.p[i] == 'E')) {
		i++;
		if (i < text.n && (text.p[i] == '+' || text.p[i] == '-'))
			i++;
		size_t start = i;
		for (; i < text.n && isDigit(text.p[i]); i++);
		if (i == start)
			return NO;
	}
	if (i != text.n)
		return NO;
	char *string = strndup(text.p, text.n);
	*value = strtod_l(string, NULL, LC_C_LOCALE);
	free(string);
	return YES;
}

// `n` as browsers write a colour's numbers: to six significant digits,
// without trailing zeros.
static NSString *numberString(double n) {
	if (isnan(n))
		return @"NaN";
	double magnitude = floor(log10(fabs(n)));
	int digits = n == 0.0 ? 1 : isinf(magnitude) ? INT_MAX : (int)magnitude + 1;
	int decimals = digits >= 6 ? 0 : MIN(6 - digits, 6);
	char buffer[400];
	snprintf_l(buffer, sizeof(buffer), LC_C_LOCALE, "%.*f", decimals, n);
	size_t length = strlen(buffer);
	if (strchr(buffer, '.')) {
		while (buffer[length - 1] == '0')
			length--;
		if (buffer[length - 1] == '.')
			length--;
	}
	buffer[length] = 0;
	// No negative zero:
	return !strcmp(buffer, "-0") ? @"0" : @(buffer);
}

#pragma mark - Parsing

// The color crate's CSS parser, over `s`:
typedef struct {
	const char *s;
	size_t n, ix;
} Parser;

// An optional number, for a component that may be `none`:
typedef struct {
	BOOL has;
	double value;
} Optional;

typedef enum { None, Number, Percent, Dimension, Symbol } Kind;

typedef struct {
	Kind kind;
	double number;
	Text unit;
} Value;

static BOOL consumeComments(Parser *p) {
	while (p->ix + 1 < p->n && p->s[p->ix] == '/' && p->s[p->ix + 1] == '*') {
		size_t i = p->ix + 2;
		while (i + 1 < p->n && !(p->s[i] == '*' && p->s[i + 1] == '/'))
			i++;
		if (i + 1 >= p->n)
			return NO;
		p->ix = i + 2;
	}
	return YES;
}

static BOOL readNumber(Parser *p, double *value) {
	if (!consumeComments(p))
		return NO;
	const char *tail = p->s + p->ix;
	size_t n = p->n - p->ix, i = 0;
	BOOL isValid = NO;
	if (i < n && (tail[i] == '+' || tail[i] == '-'))
		i++;
	for (; i < n && isDigit(tail[i]); i++)
		isValid = YES;
	if (i + 1 < n && tail[i] == '.' && isDigit(tail[i + 1])) {
		isValid = YES;
		for (i += 2; i < n && isDigit(tail[i]); i++);
	}
	if (i < n && (tail[i] == 'e' || tail[i] == 'E')) {
		size_t j = i + 1;
		if (j < n && (tail[j] == '+' || tail[j] == '-'))
			j++;
		if (j < n && isDigit(tail[j]))
			for (i = j + 1; i < n && isDigit(tail[i]); i++);
	}
	if (!isValid || !parseDouble((Text){ tail, i }, value))
		return NO;
	p->ix += i;
	return YES;
}

// An ident-token, without escapes or non-ASCII characters:
static BOOL readIdent(Parser *p, Text *ident) {
	const char *tail = p->s + p->ix;
	size_t n = p->n - p->ix, i = 0;
	while (i < n) {
		char c = tail[i];
		if (isAlpha(c) || c == '_' || c == '-' || ((i >= 2
				|| (i == 1 && tail[0] != '-')) && isDigit(c)))
			i++;
		else
			break;
	}
	// Not '', '-', or anything starting with '--':
	for (size_t j = 0; j < MIN(i, 2); j++) {
		if (tail[j] != '-') {
			*ident = (Text){ tail, i };
			p->ix += i;
			return YES;
		}
	}
	return NO;
}

static BOOL readRawCharacter(Parser *p, char c) {
	if (p->ix < p->n && p->s[p->ix] == c) {
		p->ix++;
		return YES;
	}
	return NO;
}

static BOOL readCharacter(Parser *p, char c) {
	return consumeComments(p) && readRawCharacter(p, c);
}

static BOOL readSpaceOnce(Parser *p) {
	if (!consumeComments(p))
		return NO;
	size_t start = p->ix;
	while (p->ix < p->n && (p->s[p->ix] == ' ' || p->s[p->ix] == '\t'
			|| p->s[p->ix] == '\r' || p->s[p->ix] == '\n'))
		p->ix++;
	return p->ix > start;
}

static void readSpace(Parser *p) {
	if (readSpaceOnce(p)) {
		while (consumeComments(p) && readSpaceOnce(p));
	}
}

static Value readValue(Parser *p) {
	Value value = { None };
	if (readNumber(p, &value.number)) {
		value.kind = readRawCharacter(p, '%') ? Percent
				: readIdent(p, &value.unit) ? Dimension : Number;
	} else if (readIdent(p, &value.unit)) {
		value.kind = Symbol;
	}
	return value;
}

static BOOL isNone(Value value) {
	return value.kind == Symbol && value.unit.n == 4
			&& !strncasecmp(value.unit.p, "none", 4);
}

// A component, as written: a number, a percentage, or `none` (kind None).
static BOOL readComponent(Parser *p, Value *component) {
	readSpace(p);
	Value value = readValue(p);
	if (value.kind == Number || value.kind == Percent) {
		*component = value;
		return YES;
	}
	*component = (Value){ None };
	return isNone(value);
}

static Optional scaledComponent(Value component, double scale,
		double percentScale) {
	return component.kind == None ? (Optional){ NO }
			: (Optional){ YES, component.number
				* (component.kind == Number ? scale : percentScale) };
}

static BOOL readScaled(Parser *p, double scale, double percentScale,
		Optional *value) {
	Value component;
	if (!readComponent(p, &component))
		return NO;
	*value = scaledComponent(component, scale, percentScale);
	return YES;
}

static BOOL readAngle(Parser *p, Optional *angle) {
	readSpace(p);
	Value value = readValue(p);
	if (value.kind == Number) {
		*angle = (Optional){ YES, value.number };
	} else if (isNone(value)) {
		*angle = (Optional){ NO };
	} else if (value.kind == Dimension) {
		double scale = isText(value.unit, "deg") ? 1.0
				: isText(value.unit, "rad") ? 180.0 / M_PI
				: isText(value.unit, "grad") ? 0.9
				: isText(value.unit, "turn") ? 360.0 : 0;
		if (!scale)
			return NO;
		*angle = (Optional){ YES, value.number * scale };
	} else {
		return NO;
	}
	return YES;
}

// The closing parenthesis, which the end of the text closes too, as CSS's
// parser closes what's open there:
static BOOL readClosing(Parser *p) {
	readSpace(p);
	return readCharacter(p, ')') || p->ix == p->n;
}

static BOOL readComma(Parser *p, BOOL hasComma) {
	readSpace(p);
	return !hasComma || readCharacter(p, ',');
}

// The alpha after its separator, `,` in the legacy syntax, `/` in the modern
// one, clamped, or 1 without one:
static BOOL readAlpha(Parser *p, BOOL isLegacy, Optional *alpha) {
	readSpace(p);
	*alpha = (Optional){ YES, 1.0 };
	if (readCharacter(p, isLegacy ? ',' : '/')) {
		Value component;
		// The legacy syntax has no `none`:
		if (!readComponent(p, &component)
				|| (isLegacy && component.kind == None))
			return NO;
		*alpha = scaledComponent(component, 1., 0.01);
		alpha->value = clamp(alpha->value, 0., 1.);
	}
	return YES;
}

static Color colorOf(Optional components[4], Space space) {
	Color color = { space, 0 };
	for (int i = 0; i < 4; i++) {
		if (!components[i].has)
			color.missing |= 1 << i;
		color.c[i] = components[i].has ? (float)components[i].value : 0.0f;
	}
	return color;
}

static Color colorOfBytes(const uint8_t rgba[4]) {
	Color color = { Srgb, 0 };
	for (int i = 0; i < 4; i++)
		color.c[i] = (float)rgba[i] * (1.0f / 255.0f);
	return color;
}

static BOOL readRgb(Parser *p, Color *color) {
	if (!readRawCharacter(p, '('))
		return NO;
	Value r, g, b;
	if (!readComponent(p, &r))
		return NO;
	readSpace(p);
	BOOL isLegacy = readCharacter(p, ',');
	if (!readComponent(p, &g) || !readComma(p, isLegacy)
			|| !readComponent(p, &b))
		return NO;
	// The legacy syntax takes numbers or percentages, not both, and no `none`:
	if (isLegacy && !(r.kind == Number && g.kind == Number && b.kind == Number)
			&& !(r.kind == Percent && g.kind == Percent && b.kind == Percent))
		return NO;
	Optional components[4];
	Value rgb[3] = { r, g, b };
	for (int i = 0; i < 3; i++) {
		components[i] = scaledComponent(rgb[i], 1. / 255., 0.01);
		components[i].value = clamp(components[i].value, 0., 1.);
	}
	if (!readAlpha(p, isLegacy, &components[3]) || !readClosing(p))
		return NO;
	*color = colorOf(components, Srgb);
	return YES;
}

static BOOL readLab(Parser *p, double lightness, double chroma, Space space,
		Color *color) {
	Optional c[4];
	if (!readRawCharacter(p, '(')
			|| !readScaled(p, 1., 0.01 * lightness, &c[0]))
		return NO;
	c[0].value = clamp(c[0].value, 0., lightness);
	if (space == Lch || space == Oklch) {
		if (!readScaled(p, 1., chroma, &c[1]))
			return NO;
		c[1].value = fmax(c[1].value, 0.);
		if (!readAngle(p, &c[2]))
			return NO;
	} else if (!readScaled(p, 1., chroma, &c[1])
			|| !readScaled(p, 1., chroma, &c[2])) {
		return NO;
	}
	if (!readAlpha(p, NO, &c[3]) || !readClosing(p))
		return NO;
	*color = colorOf(c, space);
	return YES;
}

static BOOL readHsl(Parser *p, Color *color) {
	Optional c[4];
	if (!readRawCharacter(p, '(') || !readAngle(p, &c[0]))
		return NO;
	readSpace(p);
	BOOL isLegacy = readCharacter(p, ',');
	Value s, l;
	if (!readComponent(p, &s) || !readComma(p, isLegacy)
			|| !readComponent(p, &l))
		return NO;
	// The legacy syntax takes percentages for saturation and lightness, and
	// no `none`:
	if (isLegacy && (!c[0].has || s.kind != Percent || l.kind != Percent))
		return NO;
	c[1] = scaledComponent(s, 1., 1.);
	c[1].value = fmax(c[1].value, 0.);
	c[2] = scaledComponent(l, 1., 1.);
	if (!readAlpha(p, isLegacy, &c[3]) || !readClosing(p))
		return NO;
	*color = colorOf(c, Hsl);
	return YES;
}

static BOOL readHwb(Parser *p, Color *color) {
	Optional c[4];
	if (!readRawCharacter(p, '(') || !readAngle(p, &c[0])
			|| !readScaled(p, 1., 1., &c[1]) || !readScaled(p, 1., 1., &c[2])
			|| !readAlpha(p, NO, &c[3]) || !readClosing(p))
		return NO;
	*color = colorOf(c, Hwb);
	return YES;
}

// The spaces `color()` takes, and those color-mix() mixes in besides:
static BOOL getSpace(Text name, BOOL isMixed, Space *space) {
	static const struct { const char *name; Space space; } spaces[] = {
		{ "srgb", Srgb }, { "srgb-linear", LinearSrgb },
		{ "display-p3", DisplayP3 }, { "a98-rgb", A98Rgb },
		{ "prophoto-rgb", ProphotoRgb }, { "rec2020", Rec2020 },
		{ "xyz", XyzD65 }, { "xyz-d65", XyzD65 }, { "xyz-d50", XyzD50 },
		{ "hsl", Hsl }, { "hwb", Hwb }, { "lab", Lab }, { "lch", Lch },
		{ "oklab", Oklab }, { "oklch", Oklch }
	};
	for (size_t i = 0; i < sizeof(spaces) / sizeof(*spaces); i++) {
		if (isText(name, spaces[i].name) && (isMixed
				|| isRectangular(spaces[i].space))) {
			*space = spaces[i].space;
			return YES;
		}
	}
	return NO;
}

static BOOL readColorFunction(Parser *p, Color *color) {
	Text name;
	Space space;
	Optional c[4];
	if (!readRawCharacter(p, '('))
		return NO;
	readSpace(p);
	if (!readIdent(p, &name) || !getSpace(name, NO, &space)
			|| !readScaled(p, 1., 0.01, &c[0])
			|| !readScaled(p, 1., 0.01, &c[1])
			|| !readScaled(p, 1., 0.01, &c[2])
			|| !readAlpha(p, NO, &c[3]) || !readClosing(p))
		return NO;
	*color = colorOf(c, space);
	return YES;
}

// The named colours, sorted, as the color crate has them:
typedef struct {
	const char *name;
	uint8_t rgba[4];
} NamedColor;

static const NamedColor namedColors[] = {
	{"aliceblue", {240, 248, 255, 255}}, {"antiquewhite", {250, 235, 215, 255}},
	{"aqua", {0, 255, 255, 255}}, {"aquamarine", {127, 255, 212, 255}},
	{"azure", {240, 255, 255, 255}}, {"beige", {245, 245, 220, 255}},
	{"bisque", {255, 228, 196, 255}}, {"black", {0, 0, 0, 255}},
	{"blanchedalmond", {255, 235, 205, 255}}, {"blue", {0, 0, 255, 255}},
	{"blueviolet", {138, 43, 226, 255}}, {"brown", {165, 42, 42, 255}},
	{"burlywood", {222, 184, 135, 255}}, {"cadetblue", {95, 158, 160, 255}},
	{"chartreuse", {127, 255, 0, 255}}, {"chocolate", {210, 105, 30, 255}},
	{"coral", {255, 127, 80, 255}}, {"cornflowerblue", {100, 149, 237, 255}},
	{"cornsilk", {255, 248, 220, 255}}, {"crimson", {220, 20, 60, 255}},
	{"cyan", {0, 255, 255, 255}}, {"darkblue", {0, 0, 139, 255}},
	{"darkcyan", {0, 139, 139, 255}}, {"darkgoldenrod", {184, 134, 11, 255}},
	{"darkgray", {169, 169, 169, 255}}, {"darkgreen", {0, 100, 0, 255}},
	{"darkgrey", {169, 169, 169, 255}}, {"darkkhaki", {189, 183, 107, 255}},
	{"darkmagenta", {139, 0, 139, 255}}, {"darkolivegreen", {85, 107, 47, 255}},
	{"darkorange", {255, 140, 0, 255}}, {"darkorchid", {153, 50, 204, 255}},
	{"darkred", {139, 0, 0, 255}}, {"darksalmon", {233, 150, 122, 255}},
	{"darkseagreen", {143, 188, 143, 255}},
	{"darkslateblue", {72, 61, 139, 255}}, {"darkslategray", {47, 79, 79, 255}},
	{"darkslategrey", {47, 79, 79, 255}}, {"darkturquoise", {0, 206, 209, 255}},
	{"darkviolet", {148, 0, 211, 255}}, {"deeppink", {255, 20, 147, 255}},
	{"deepskyblue", {0, 191, 255, 255}}, {"dimgray", {105, 105, 105, 255}},
	{"dimgrey", {105, 105, 105, 255}}, {"dodgerblue", {30, 144, 255, 255}},
	{"firebrick", {178, 34, 34, 255}}, {"floralwhite", {255, 250, 240, 255}},
	{"forestgreen", {34, 139, 34, 255}}, {"fuchsia", {255, 0, 255, 255}},
	{"gainsboro", {220, 220, 220, 255}}, {"ghostwhite", {248, 248, 255, 255}},
	{"gold", {255, 215, 0, 255}}, {"goldenrod", {218, 165, 32, 255}},
	{"gray", {128, 128, 128, 255}}, {"green", {0, 128, 0, 255}},
	{"greenyellow", {173, 255, 47, 255}}, {"grey", {128, 128, 128, 255}},
	{"honeydew", {240, 255, 240, 255}}, {"hotpink", {255, 105, 180, 255}},
	{"indianred", {205, 92, 92, 255}}, {"indigo", {75, 0, 130, 255}},
	{"ivory", {255, 255, 240, 255}}, {"khaki", {240, 230, 140, 255}},
	{"lavender", {230, 230, 250, 255}}, {"lavenderblush", {255, 240, 245, 255}},
	{"lawngreen", {124, 252, 0, 255}}, {"lemonchiffon", {255, 250, 205, 255}},
	{"lightblue", {173, 216, 230, 255}}, {"lightcoral", {240, 128, 128, 255}},
	{"lightcyan", {224, 255, 255, 255}},
	{"lightgoldenrodyellow", {250, 250, 210, 255}},
	{"lightgray", {211, 211, 211, 255}}, {"lightgreen", {144, 238, 144, 255}},
	{"lightgrey", {211, 211, 211, 255}}, {"lightpink", {255, 182, 193, 255}},
	{"lightsalmon", {255, 160, 122, 255}},
	{"lightseagreen", {32, 178, 170, 255}},
	{"lightskyblue", {135, 206, 250, 255}},
	{"lightslategray", {119, 136, 153, 255}},
	{"lightslategrey", {119, 136, 153, 255}},
	{"lightsteelblue", {176, 196, 222, 255}},
	{"lightyellow", {255, 255, 224, 255}}, {"lime", {0, 255, 0, 255}},
	{"limegreen", {50, 205, 50, 255}}, {"linen", {250, 240, 230, 255}},
	{"magenta", {255, 0, 255, 255}}, {"maroon", {128, 0, 0, 255}},
	{"mediumaquamarine", {102, 205, 170, 255}},
	{"mediumblue", {0, 0, 205, 255}}, {"mediumorchid", {186, 85, 211, 255}},
	{"mediumpurple", {147, 112, 219, 255}},
	{"mediumseagreen", {60, 179, 113, 255}},
	{"mediumslateblue", {123, 104, 238, 255}},
	{"mediumspringgreen", {0, 250, 154, 255}},
	{"mediumturquoise", {72, 209, 204, 255}},
	{"mediumvioletred", {199, 21, 133, 255}},
	{"midnightblue", {25, 25, 112, 255}}, {"mintcream", {245, 255, 250, 255}},
	{"mistyrose", {255, 228, 225, 255}}, {"moccasin", {255, 228, 181, 255}},
	{"navajowhite", {255, 222, 173, 255}}, {"navy", {0, 0, 128, 255}},
	{"oldlace", {253, 245, 230, 255}}, {"olive", {128, 128, 0, 255}},
	{"olivedrab", {107, 142, 35, 255}}, {"orange", {255, 165, 0, 255}},
	{"orangered", {255, 69, 0, 255}}, {"orchid", {218, 112, 214, 255}},
	{"palegoldenrod", {238, 232, 170, 255}},
	{"palegreen", {152, 251, 152, 255}},
	{"paleturquoise", {175, 238, 238, 255}},
	{"palevioletred", {219, 112, 147, 255}},
	{"papayawhip", {255, 239, 213, 255}}, {"peachpuff", {255, 218, 185, 255}},
	{"peru", {205, 133, 63, 255}}, {"pink", {255, 192, 203, 255}},
	{"plum", {221, 160, 221, 255}}, {"powderblue", {176, 224, 230, 255}},
	{"purple", {128, 0, 128, 255}}, {"rebeccapurple", {102, 51, 153, 255}},
	{"red", {255, 0, 0, 255}}, {"rosybrown", {188, 143, 143, 255}},
	{"royalblue", {65, 105, 225, 255}}, {"saddlebrown", {139, 69, 19, 255}},
	{"salmon", {250, 128, 114, 255}}, {"sandybrown", {244, 164, 96, 255}},
	{"seagreen", {46, 139, 87, 255}}, {"seashell", {255, 245, 238, 255}},
	{"sienna", {160, 82, 45, 255}}, {"silver", {192, 192, 192, 255}},
	{"skyblue", {135, 206, 235, 255}}, {"slateblue", {106, 90, 205, 255}},
	{"slategray", {112, 128, 144, 255}}, {"slategrey", {112, 128, 144, 255}},
	{"snow", {255, 250, 250, 255}}, {"springgreen", {0, 255, 127, 255}},
	{"steelblue", {70, 130, 180, 255}}, {"tan", {210, 180, 140, 255}},
	{"teal", {0, 128, 128, 255}}, {"thistle", {216, 191, 216, 255}},
	{"tomato", {255, 99, 71, 255}}, {"transparent", {0, 0, 0, 0}},
	{"turquoise", {64, 224, 208, 255}}, {"violet", {238, 130, 238, 255}},
	{"wheat", {245, 222, 179, 255}}, {"white", {255, 255, 255, 255}},
	{"whitesmoke", {245, 245, 245, 255}}, {"yellow", {255, 255, 0, 255}},
	{"yellowgreen", {154, 205, 50, 255}}
};

static int compareName(const void *key, const void *entry) {
	const Text *name = key;
	const char *other = *(const char *const *)entry;
	size_t n = strlen(other);
	int result = strncmp(name->p, other, MIN(name->n, n));
	return result ? result : name->n < n ? -1 : name->n > n ? 1 : 0;
}

// A colour as the color crate's `parse_color` parses it:
static BOOL parseColor(Text css, Color *color) {
	css = trimmed(css);
	Parser p = { css.p, css.n, 0 };
	if (css.n && css.p[0] == '#') {
		uint8_t hex[8];
		size_t i = 0;
		for (; i < 8 && i + 1 < css.n && hexDigit(css.p[i + 1]) >= 0; i++)
			hex[i] = hexDigit(css.p[i + 1]);
		if (i == 3 || i == 4) {
			for (int j = 3; j >= 0; j--)
				hex[j * 2] = hex[j * 2 + 1] = j < (int)i ? hex[j] : 15;
		} else if (i == 6) {
			hex[6] = hex[7] = 15;
		} else if (i != 8) {
			return NO;
		}
		uint8_t rgba[4];
		for (int j = 0; j < 4; j++)
			rgba[j] = hex[j * 2] << 4 | hex[j * 2 + 1];
		*color = colorOfBytes(rgba);
		p.ix = i + 1;
	} else {
		Text name;
		if (!readIdent(&p, &name))
			return NO;
		BOOL isParsed;
		if (isText(name, "rgb") || isText(name, "rgba"))
			isParsed = readRgb(&p, color);
		else if (isText(name, "lab"))
			isParsed = readLab(&p, 100.0, 1.25, Lab, color);
		else if (isText(name, "lch"))
			isParsed = readLab(&p, 100.0, 1.25, Lch, color);
		else if (isText(name, "oklab"))
			isParsed = readLab(&p, 1.0, 0.004, Oklab, color);
		else if (isText(name, "oklch"))
			isParsed = readLab(&p, 1.0, 0.004, Oklch, color);
		else if (isText(name, "hsl") || isText(name, "hsla"))
			isParsed = readHsl(&p, color);
		else if (isText(name, "hwb"))
			isParsed = readHwb(&p, color);
		else if (isText(name, "color"))
			isParsed = readColorFunction(&p, color);
		else {
			const NamedColor *entry = bsearch(&name, namedColors,
					sizeof(namedColors) / sizeof(*namedColors),
					sizeof(*namedColors), compareName);
			if ((isParsed = !!entry))
				*color = colorOfBytes(entry->rgba);
		}
		if (!isParsed)
			return NO;
	}
	return p.ix == css.n;
}

#pragma mark - CSS colours

// The most colours nested in a colour (`color-mix()`, relative colours),
// each a level of recursion: deeper than CSS anyone writes.
static const int mostNested = 16;

static BOOL parseAt(Text css, int depth, Color *color, BOOL *isLegacy);

// The value of the system colour `name`, as browsers have them in a light
// colour scheme; the deprecated ones as CSS Color 4 maps them.
static const char *systemColor(Text name) {
	static const char *const colors[][2] = {
		{ "canvas", "#ffffff" }, { "activecaption", "#ffffff" },
		{ "appworkspace", "#ffffff" }, { "background", "#ffffff" },
		{ "inactivecaption", "#ffffff" }, { "infobackground", "#ffffff" },
		{ "menu", "#ffffff" }, { "scrollbar", "#ffffff" },
		{ "window", "#ffffff" }, { "canvastext", "#000000" },
		{ "captiontext", "#000000" }, { "infotext", "#000000" },
		{ "menutext", "#000000" }, { "windowtext", "#000000" },
		{ "buttontext", "#000000" }, { "fieldtext", "#000000" },
		{ "highlighttext", "#000000" }, { "marktext", "#000000" },
		{ "linktext", "#0000ee" }, { "visitedtext", "#551a8b" },
		{ "activetext", "#ff0000" }, { "buttonface", "#efefef" },
		{ "buttonhighlight", "#efefef" }, { "buttonshadow", "#efefef" },
		{ "threedface", "#efefef" }, { "buttonborder", "#767676" },
		{ "activeborder", "#767676" }, { "inactiveborder", "#767676" },
		{ "threeddarkshadow", "#767676" }, { "threedhighlight", "#767676" },
		{ "threedlightshadow", "#767676" }, { "threedshadow", "#767676" },
		{ "windowframe", "#767676" }, { "field", "#ffffff" },
		{ "highlight", "#b5d5ff" }, { "selecteditem", "#0075ff" },
		{ "accentcolor", "#0075ff" }, { "selecteditemtext", "#ffffff" },
		{ "accentcolortext", "#ffffff" }, { "mark", "#ffff00" },
		{ "graytext", "#808080" }, { "inactivecaptiontext", "#808080" }
	};
	for (size_t i = 0; i < sizeof(colors) / sizeof(*colors); i++) {
		if (isText(name, colors[i][0]))
			return colors[i][1];
	}
	return NULL;
}

// A share of a colour in `color-mix()`, as a fraction:
static BOOL getShare(Text word, double *share) {
	double percent;
	if (!word.n || word.p[word.n - 1] != '%'
			|| !parseDouble((Text){ word.p, word.n - 1 }, &percent)
			|| !(percent >= 0.0 && percent <= 100.0))
		return NO;
	*share = percent / 100.0;
	return YES;
}

// A colour of `color-mix()`, and its share when it's given one:
static BOOL parseMixed(Text text, int depth, Color *color, Optional *share) {
	Text words[2];
	BOOL isLegacy;
	*share = (Optional){ NO };
	switch (split(text, ' ', words, 2)) {
	case 1:
		return parseAt(words[0], depth + 1, color, &isLegacy);
	case 2:
		if (getShare(words[1], &share->value)) {
			share->has = YES;
			return parseAt(words[0], depth + 1, color, &isLegacy);
		}
		if (getShare(words[0], &share->value)) {
			share->has = YES;
			return parseAt(words[1], depth + 1, color, &isLegacy);
		}
	}
	return NO;
}

// `color-mix(in <space> [<direction> hue], <color> [<p>], <color> [<p>])`, as
// CSS Color 5 mixes.
static BOOL parseMix(Text arguments, int depth, Color *color) {
	Text parts[3], words[4];
	if (split(arguments, ',', parts, 3) != 3)
		return NO;
	// The method's words, split at any white space:
	size_t count = 0;
	Text method = trimmed(parts[0]);
	while (method.n) {
		size_t n = 0, length = 0;
		while (n < method.n && !(length = spaceLength(
				(const unsigned char *)method.p + n, method.n - n, NO)))
			n++;
		if (count < 4)
			words[count] = (Text){ method.p, n };
		count++;
		method = trimmed((Text){ method.p + n, method.n - n });
	}
	Space space;
	Direction direction = Shorter;
	if (count == 4 && isText(words[3], "hue")) {
		const char *names[] = { "shorter", "longer", "increasing",
				"decreasing" };
		int i = 0;
		while (i < 4 && !isText(words[2], names[i]))
			i++;
		if (i == 4)
			return NO;
		direction = (Direction)i;
	} else if (count != 2) {
		return NO;
	}
	if (!isText(words[0], "in") || !getSpace(words[1], YES, &space))
		return NO;
	Color first, second;
	Optional p1, p2;
	if (!parseMixed(parts[1], depth, &first, &p1)
			|| !parseMixed(parts[2], depth, &second, &p2))
		return NO;
	double share1 = p1.has ? p1.value : p2.has ? 1.0 - p2.value : 0.5;
	double share2 = p2.has ? p2.value : p1.has ? 1.0 - p1.value : 0.5;
	double sum = share1 + share2;
	if (sum <= 0.0)
		return NO;
	*color = interpolate(first, second, space, direction,
			(float)(share2 / sum));
	// Less than all of them together is that much transparent.
	if (sum < 1.0)
		color->c[3] *= (float)sum;
	return YES;
}

// A relative colour, `<function>(from <color> <channels> [/ <alpha>])`: its
// channels keywords of the origin colour's in the function's space, numbers,
// percentages or `none`. -1 when `css` isn't one, NO when it is, but invalid.
static int parseRelative(Text css, int depth, Color *color) {
	static const char *const functions[] = { "rgb", "rgba", "hsl", "hsla",
			"hwb", "lab", "lch", "oklab", "oklch", "color" };
	const char *function = NULL;
	Text arguments;
	for (size_t i = 0; i < sizeof(functions) / sizeof(*functions)
			&& !function; i++) {
		if (getArguments(css, functions[i], &arguments))
			function = functions[i];
	}
	if (!function)
		return -1;
	NSMutableData *spaced = [NSMutableData dataWithCapacity:arguments.n];
	for (size_t i = 0; i < arguments.n; i++) {
		if (arguments.p[i] == '/')
			[spaced appendBytes:" / " length:3];
		else
			[spaced appendBytes:arguments.p + i length:1];
	}
	Text words[8];
	size_t count = split((Text){ spaced.bytes, spaced.length }, ' ', words, 8);
	if (count < 2 || !isText(words[0], "from"))
		return -1;
	Color origin;
	BOOL isLegacy;
	if (!parseAt(words[1], depth + 1, &origin, &isLegacy))
		return NO;
	// More words than any channels take:
	if (count > 8)
		return NO;
	Text *rest = words + 2;
	count -= 2;
	Text space = { NULL, 0 };
	BOOL isColor = !strcmp(function, "color");
	if (isColor && count) {
		space = rest[0];
		rest++;
		count--;
	}
	Space tag;
	const char *keywords = "rgb";
	double scale = 1.0;
	if (!strcmp(function, "rgb") || !strcmp(function, "rgba")) {
		tag = Srgb;
		scale = 255.0;
	} else if (!strcmp(function, "hsl") || !strcmp(function, "hsla")) {
		tag = Hsl;
		keywords = "hsl";
	} else if (!strcmp(function, "hwb")) {
		tag = Hwb;
		keywords = "hwb";
	} else if (!strcmp(function, "lab") || !strcmp(function, "oklab")) {
		tag = function[0] == 'l' ? Lab : Oklab;
		keywords = "lab";
	} else if (!strcmp(function, "lch") || !strcmp(function, "oklch")) {
		tag = function[0] == 'l' ? Lch : Oklch;
		keywords = "lch";
	} else if (space.p && getSpace(space, YES, &tag)) {
		if (tag == XyzD50 || tag == XyzD65)
			keywords = "xyz";
	} else {
		return NO;
	}
	Color channels = convert(origin, tag);
	// A channel's value, as text: a keyword's, or what's written.
	NSString *(^value)(Text) = ^NSString *(Text word) {
		const char *keyword = word.n == 1 ? strchr(keywords, word.p[0]) : NULL;
		if (keyword && *keyword)
			return numberString((double)channels.c[keyword - keywords] * scale);
		if (isText(word, "alpha"))
			return numberString((double)channels.c[3]);
		if (isText(word, "none") || isDigit(word.p[0]) || word.p[0] == '.'
				|| word.p[0] == '-' || word.p[0] == '+')
			return [[NSString alloc] initWithBytes:word.p length:word.n
					encoding:NSUTF8StringEncoding];
		return nil;
	};
	Text alpha;
	if (count == 3)
		alpha = textOf("alpha");
	else if (count == 5 && isText(rest[3], "/"))
		alpha = rest[4];
	else
		return NO;
	NSMutableArray *values = [NSMutableArray array];
	for (int i = 0; i < 4; i++) {
		NSString *text = value(i < 3 ? rest[i] : alpha);
		if (!text)
			return NO;
		[values addObject:text];
	}
	NSString *joined = [values componentsJoinedByString:@" "];
	NSRange last = [joined rangeOfString:@" " options:NSBackwardsSearch];
	joined = [joined stringByReplacingCharactersInRange:last withString:@" / "];
	// `rgba` and `hsla` as `rgb` and `hsl`:
	size_t length = strlen(function);
	while (function[length - 1] == 'a')
		length--;
	NSString *relative = isColor
			? [NSString stringWithFormat:@"color(%.*s %@)", (int)space.n,
				space.p, joined]
			: [NSString stringWithFormat:@"%.*s(%@)", (int)length, function,
				joined];
	return parseColor(textOf(relative.UTF8String), color);
}

static BOOL parseAt(Text css, int depth, Color *color, BOOL *isLegacy) {
	if (depth > mostNested)
		return NO;
	css = trimmed(css);
	*isLegacy = YES;
	if (isText(css, "currentcolor")) {
		*color = (Color){ Srgb, 0, { 0, 0, 0, 1 } };
		return YES;
	}
	const char *hex = systemColor(css);
	if (hex)
		return parseColor(textOf(hex), color);
	*isLegacy = NO;
	Text arguments;
	if (getArguments(css, "color-mix", &arguments))
		return parseMix(arguments, depth, color);
	int relative = parseRelative(css, depth, color);
	if (relative >= 0)
		return relative;
	const char *end = memchr(css.p, '(', css.n);
	Text name = { css.p, end ? (size_t)(end - css.p) : css.n };
	*isLegacy = !isText(name, "color") && !isText(name, "lab")
			&& !isText(name, "lch") && !isText(name, "oklab")
			&& !isText(name, "oklch");
	return parseColor(css, color);
}

#pragma mark - Serializing

// The crate's rounding to 8 bits, saturating as Rust's casts do:
static uint8_t byteOf(float x) {
	float value = x * 255.f + 0.5f;
	return isnan(value) || value <= 0.f ? 0 : value >= 255.f ? 255
			: (uint8_t)value;
}

// `color` as CSS writes it in its space: `color(srgb 0.5 0 0.5)`,
// `lab(50 20 -30 / 0.5)`; a colour in `hsl` or `hwb` as sRGB.
static NSString *modernString(Color color) {
	if (color.space == Hsl || color.space == Hwb)
		color = convert(color, Srgb);
	NSString *function = @{
		@(Lab): @"lab(", @(Lch): @"lch(", @(Oklab): @"oklab(",
		@(Oklch): @"oklch(", @(LinearSrgb): @"color(srgb-linear ",
		@(DisplayP3): @"color(display-p3 ", @(A98Rgb): @"color(a98-rgb ",
		@(ProphotoRgb): @"color(prophoto-rgb ", @(Rec2020): @"color(rec2020 ",
		@(XyzD50): @"color(xyz-d50 ", @(XyzD65): @"color(xyz-d65 "
	}[@(color.space)] ?: @"color(srgb ";
	NSMutableString *string = [function mutableCopy];
	for (int i = 0; i < 3; i++) {
		[string appendFormat:i ? @" %@" : @"%@", color.missing & (1 << i)
				? @"none" : numberString(color.c[i])];
	}
	if (color.c[3] < 1.0f)
		[string appendFormat:@" / %@", numberString(color.c[3])];
	[string appendString:@")"];
	return string;
}

@implementation SGCSSColor {
	Color _color;
	uint8_t _rgba[4];
}

+ (SGCSSColor *)parse:(NSString *)text {
	NSMutableData *data = [[text dataUsingEncoding:NSUTF8StringEncoding
			allowLossyConversion:YES] mutableCopy];
	char *bytes = data.mutableBytes;
	for (NSUInteger i = 0; i < data.length; i++)
		if (bytes[i] >= 'A' && bytes[i] <= 'Z')
			bytes[i] += 'a' - 'A';
	SGCSSColor *color = [[SGCSSColor alloc] init];
	if (!parseAt((Text){ data.bytes, data.length }, 0, &color->_color,
			&color->_legacy))
		return nil;
	Color srgb = convert(color->_color, Srgb);
	for (int i = 0; i < 4; i++)
		color->_rgba[i] = byteOf(srgb.c[i]);
	return color;
}

- (double)red {
	return _rgba[0] / 255.0;
}

- (double)green {
	return _rgba[1] / 255.0;
}

- (double)blue {
	return _rgba[2] / 255.0;
}

- (double)alpha {
	return _rgba[3] / 255.0;
}

- (NSString *)serialized {
	if (!_legacy)
		return modernString(_color);
	uint8_t r = _rgba[0], g = _rgba[1], b = _rgba[2], a = _rgba[3];
	if (a == 255)
		return [NSString stringWithFormat:@"#%02x%02x%02x", r, g, b];
	// The fewest decimals that give the same 8 bits back, as CSS serializes
	// alpha:
	double exact = a / 255.0, alpha = exact;
	for (double scale = 100.0; scale <= 1000.0; scale *= 10.0) {
		double rounded = round(exact * scale) / scale;
		if ((uint8_t)round(rounded * 255.0) == a) {
			alpha = rounded;
			break;
		}
	}
	// As Rust writes it, in the fewest digits that read back the same:
	char buffer[32];
	for (int digits = 1; digits <= 17; digits++) {
		snprintf_l(buffer, sizeof(buffer), LC_C_LOCALE, "%.*g", digits, alpha);
		if (strtod_l(buffer, NULL, LC_C_LOCALE) == alpha)
			break;
	}
	return [NSString stringWithFormat:@"rgba(%d, %d, %d, %s)", r, g, b, buffer];
}

@end
