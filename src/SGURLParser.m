//
//  SGURLParser.m
//  Scriptographer for Glyphs
//

#import "SGURLParser.h"
#import <arpa/inet.h>

// A URL record of the standard: a nil host or query is none, an opaque path
// takes the place of the path's segments.
@interface SGURLRecord : NSObject <NSCopying>
@property (nonatomic, copy) NSString *scheme;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, copy, nullable) NSString *host;
@property (nonatomic, strong, nullable) NSNumber *port;
@property (nonatomic, strong) NSMutableArray<NSString *> *path;
@property (nonatomic, copy, nullable) NSString *opaquePath;
@property (nonatomic, copy, nullable) NSString *query;
@property (nonatomic, copy, nullable) NSString *fragment;
@end

@implementation SGURLRecord

- (instancetype)init {
	self = [super init];
	if (self) {
		_scheme = _username = _password = @"";
		_path = [NSMutableArray array];
	}
	return self;
}

- (id)copyWithZone:(NSZone *)zone {
	SGURLRecord *copy = [[SGURLRecord alloc] init];
	copy.scheme = _scheme;
	copy.username = _username;
	copy.password = _password;
	copy.host = _host;
	copy.port = _port;
	copy.path = [_path mutableCopy];
	copy.opaquePath = _opaquePath;
	copy.query = _query;
	copy.fragment = _fragment;
	return copy;
}

@end

#pragma mark - Code points

typedef uint32_t Char;
static const Char EOF_ = 0xffffffff;

static NSData *codePointsOf(NSString *string) {
	NSMutableData *data = [NSMutableData data];
	NSUInteger length = string.length;
	for (NSUInteger i = 0; i < length; i++) {
		unichar c = [string characterAtIndex:i];
		Char point = c;
		if (CFStringIsSurrogateHighCharacter(c) && i + 1 < length
				&& CFStringIsSurrogateLowCharacter(
					[string characterAtIndex:i + 1])) {
			point = CFStringGetLongCharacterForSurrogatePair(c,
					[string characterAtIndex:++i]);
		} else if (CFStringIsSurrogateHighCharacter(c)
				|| CFStringIsSurrogateLowCharacter(c)) {
			point = 0xfffd;
		}
		[data appendBytes:&point length:sizeof(point)];
	}
	return data;
}

static NSString *stringOf(const Char *points, NSUInteger count) {
	return [[NSString alloc] initWithBytes:points length:count * sizeof(Char)
			encoding:NSUTF32LittleEndianStringEncoding] ?: @"";
}

static BOOL isAlpha(Char c) {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static BOOL isDigit(Char c) {
	return c >= '0' && c <= '9';
}

static BOOL isHex(Char c) {
	return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

#pragma mark - Percent-encoding

typedef BOOL (*EncodeSet)(Char c);

static BOOL inC0Set(Char c) {
	return c < 0x20 || c > 0x7e;
}

static BOOL inFragmentSet(Char c) {
	return inC0Set(c) || c == ' ' || c == '"' || c == '<' || c == '>'
			|| c == '`';
}

static BOOL inQuerySet(Char c) {
	return inC0Set(c) || c == ' ' || c == '"' || c == '#' || c == '<'
			|| c == '>';
}

static BOOL inSpecialQuerySet(Char c) {
	return inQuerySet(c) || c == '\'';
}

static BOOL inPathSet(Char c) {
	return inQuerySet(c) || c == '?' || c == '^' || c == '`' || c == '{'
			|| c == '}';
}

static BOOL inUserinfoSet(Char c) {
	return inPathSet(c) || c == '/' || c == ':' || c == ';' || c == '='
			|| c == '@' || (c >= '[' && c <= ']') || c == '|';
}

static void appendEncoded(NSMutableString *output, Char c, EncodeSet set) {
	if (!set(c)) {
		[output appendFormat:@"%c", (char)c];
		return;
	}
	NSString *string = stringOf(&c, 1);
	NSData *bytes = [string dataUsingEncoding:NSUTF8StringEncoding];
	const uint8_t *b = bytes.bytes;
	for (NSUInteger i = 0; i < bytes.length; i++)
		[output appendFormat:@"%%%02X", b[i]];
}

static NSString *encoded(NSString *string, EncodeSet set) {
	NSData *points = codePointsOf(string);
	const Char *p = points.bytes;
	NSMutableString *output = [NSMutableString string];
	for (NSUInteger i = 0; i < points.length / sizeof(Char); i++)
		appendEncoded(output, p[i], set);
	return output;
}

static NSData *percentDecoded(NSData *bytes) {
	const uint8_t *b = bytes.bytes;
	NSUInteger length = bytes.length;
	NSMutableData *output = [NSMutableData dataWithCapacity:length];
	for (NSUInteger i = 0; i < length; i++) {
		uint8_t byte = b[i];
		if (byte == '%' && i + 2 < length && isHex(b[i + 1])
				&& isHex(b[i + 2])) {
			char hex[3] = { b[i + 1], b[i + 2], 0 };
			byte = (uint8_t)strtol(hex, NULL, 16);
			i += 2;
		}
		[output appendBytes:&byte length:1];
	}
	return output;
}

// UTF-8 with U+FFFD for what isn't, as the standard decodes:
static NSString *decodeUTF8(NSData *data) {
	NSString *text = [[NSString alloc] initWithData:data
			encoding:NSUTF8StringEncoding];
	if (text)
		return text;
	NSMutableString *output = [NSMutableString string];
	const uint8_t *b = data.bytes;
	for (NSUInteger i = 0; i < data.length;) {
		NSUInteger count = b[i] < 0x80 ? 1 : b[i] >= 0xc2 && b[i] <= 0xdf ? 2
				: b[i] >= 0xe0 && b[i] <= 0xef ? 3
				: b[i] >= 0xf0 && b[i] <= 0xf4 ? 4 : 0;
		NSString *piece = count && i + count <= data.length
				? [[NSString alloc] initWithBytes:b + i length:count
					encoding:NSUTF8StringEncoding] : nil;
		[output appendString:piece ?: @"�"];
		i += piece ? count : 1;
	}
	return output;
}

#pragma mark - Schemes

static NSDictionary<NSString *, NSNumber *> *specialSchemes(void) {
	static NSDictionary *schemes;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		schemes = @{
			@"ftp": @21, @"file": [NSNull null], @"http": @80,
			@"https": @443, @"ws": @80, @"wss": @443
		};
	});
	return schemes;
}

static BOOL isSpecial(NSString *scheme) {
	return specialSchemes()[scheme] != nil;
}

static NSNumber *defaultPort(NSString *scheme) {
	id port = specialSchemes()[scheme];
	return [port isKindOfClass:[NSNumber class]] ? port : nil;
}

#pragma mark - Hosts

// RFC 3492 Punycode, for labels that aren't ASCII:
static NSString *punycode(NSData *label) {
	const Char *input = label.bytes;
	NSUInteger length = label.length / sizeof(Char);
	const NSUInteger base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700;
	NSMutableString *output = [NSMutableString string];
	NSUInteger basic = 0;
	for (NSUInteger i = 0; i < length; i++) {
		if (input[i] < 0x80) {
			[output appendFormat:@"%c", (char)input[i]];
			basic++;
		}
	}
	if (basic)
		[output appendString:@"-"];
	Char n = 0x80;
	NSUInteger delta = 0, bias = 72, handled = basic;
	while (handled < length) {
		Char m = 0xffffffff;
		for (NSUInteger i = 0; i < length; i++) {
			if (input[i] >= n && input[i] < m)
				m = input[i];
		}
		delta += (m - n) * (handled + 1);
		n = m;
		for (NSUInteger i = 0; i < length; i++) {
			if (input[i] < n)
				delta++;
			if (input[i] == n) {
				NSUInteger q = delta;
				for (NSUInteger k = base;; k += base) {
					NSUInteger t = k <= bias ? tMin
							: k >= bias + tMax ? tMax : k - bias;
					if (q < t)
						break;
					NSUInteger digit = t + (q - t) % (base - t);
					[output appendFormat:@"%c", (char)(digit < 26
							? 'a' + digit : '0' + digit - 26)];
					q = (q - t) / (base - t);
				}
				[output appendFormat:@"%c", (char)(q < 26
						? 'a' + q : '0' + q - 26)];
				// Adapts the bias:
				NSUInteger d = handled == basic ? delta / damp : delta / 2;
				d += d / (handled + 1);
				NSUInteger k = 0;
				while (d > ((base - tMin) * tMax) / 2) {
					d /= base - tMin;
					k += base;
				}
				bias = k + (base - tMin + 1) * d / (d + skew);
				delta = 0;
				handled++;
			}
		}
		delta++;
		n++;
	}
	return [@"xn--" stringByAppendingString:output];
}

static BOOL isForbiddenHostPoint(Char c) {
	return c == 0 || c == '\t' || c == '\n' || c == '\r' || c == ' '
			|| c == '#' || c == '/' || c == ':' || c == '<' || c == '>'
			|| c == '?' || c == '@' || c == '[' || c == '\\' || c == ']'
			|| c == '^' || c == '|';
}

static BOOL isForbiddenDomainPoint(Char c) {
	return isForbiddenHostPoint(c) || c <= 0x1f || c == '%' || c == 0x7f;
}

// An IPv4 number: decimal, 0x hex or 0 octal, or -1:
static long long ipv4Number(NSString *part) {
	if (!part.length)
		return -1;
	int radix = 10;
	if (part.length >= 2 && ([part hasPrefix:@"0x"] || [part hasPrefix:@"0X"])) {
		radix = 16;
		part = [part substringFromIndex:2];
	} else if (part.length >= 2 && [part hasPrefix:@"0"]) {
		radix = 8;
		part = [part substringFromIndex:1];
	}
	if (!part.length)
		return 0;
	unsigned long long value = 0;
	for (NSUInteger i = 0; i < part.length; i++) {
		unichar c = [part characterAtIndex:i];
		int digit = isDigit(c) ? c - '0' : (c >= 'a' && c <= 'f') ? c - 'a' + 10
				: (c >= 'A' && c <= 'F') ? c - 'A' + 10 : 99;
		if (digit >= radix)
			return -1;
		value = value * radix + digit;
		if (value > 0xffffffffULL * 256)
			value = 0xffffffffULL * 256;
	}
	return (long long)value;
}

static BOOL endsInNumber(NSString *host) {
	NSMutableArray *parts = [[host componentsSeparatedByString:@"."]
			mutableCopy];
	if ([parts.lastObject length] == 0) {
		if (parts.count == 1)
			return NO;
		[parts removeLastObject];
	}
	NSString *last = parts.lastObject;
	NSCharacterSet *digits = [NSCharacterSet
			characterSetWithCharactersInString:@"0123456789"];
	if (last.length && [last stringByTrimmingCharactersInSet:digits].length == 0)
		return YES;
	return ipv4Number(last) >= 0 && [last.lowercaseString hasPrefix:@"0x"];
}

static NSString *parseIPv4(NSString *host) {
	NSMutableArray *parts = [[host componentsSeparatedByString:@"."]
			mutableCopy];
	if ([parts.lastObject length] == 0 && parts.count > 1)
		[parts removeLastObject];
	if (parts.count > 4)
		return nil;
	NSMutableArray *numbers = [NSMutableArray array];
	for (NSString *part in parts) {
		long long number = ipv4Number(part);
		if (number < 0)
			return nil;
		[numbers addObject:@(number)];
	}
	for (NSUInteger i = 0; i + 1 < numbers.count; i++) {
		if ([numbers[i] longLongValue] > 255)
			return nil;
	}
	long long last = [numbers.lastObject longLongValue];
	if (last >= (1LL << (8 * (5 - numbers.count))))
		return nil;
	unsigned long long address = last;
	for (NSUInteger i = 0; i + 1 < numbers.count; i++)
		address += [numbers[i] unsignedLongLongValue] << (8 * (3 - i));
	return [NSString stringWithFormat:@"%llu.%llu.%llu.%llu",
			address >> 24 & 0xff, address >> 16 & 0xff, address >> 8 & 0xff,
			address & 0xff];
}

// An IPv6 address, compressed as the standard serializes it:
static NSString *parseIPv6(NSString *input) {
	// No zone, and no leading zeros in an IPv4 part, unlike inet_pton:
	if ([input containsString:@"%"])
		return nil;
	NSRange colon = [input rangeOfString:@":" options:NSBackwardsSearch];
	if (colon.location == NSNotFound)
		return nil;
	if ([input rangeOfString:@"."].location != NSNotFound) {
		NSString *ipv4 = [input substringFromIndex:colon.location + 1];
		for (NSString *part in [ipv4 componentsSeparatedByString:@"."]) {
			if (part.length > 1 && [part hasPrefix:@"0"])
				return nil;
		}
	}
	struct in6_addr address;
	if (inet_pton(AF_INET6, input.UTF8String, &address) != 1)
		return nil;
	uint16_t pieces[8];
	for (int i = 0; i < 8; i++)
		pieces[i] = address.s6_addr[i * 2] << 8 | address.s6_addr[i * 2 + 1];
	// The first longest run of at least two zero pieces:
	int start = -1, longest = 1;
	for (int i = 0; i < 8;) {
		int j = i;
		while (j < 8 && !pieces[j])
			j++;
		if (j - i > longest) {
			start = i;
			longest = j - i;
		}
		i = j > i ? j : i + 1;
	}
	NSMutableString *output = [NSMutableString stringWithString:@"["];
	for (int i = 0; i < 8; i++) {
		if (i == start) {
			[output appendString:i ? @":" : @"::"];
			i += longest - 1;
			continue;
		}
		[output appendFormat:@"%x", pieces[i]];
		if (i < 7)
			[output appendString:@":"];
	}
	[output appendString:@"]"];
	return output;
}

// What UTS #46 maps a domain to, as near as Foundation gets: compatibility
// forms (full-width letters and digits) composed, lowercase, without the
// code points it ignores; nil with ones it disallows.
static NSString *mapDomain(NSString *domain) {
	NSString *mapped = domain.precomposedStringWithCompatibilityMapping
			.lowercaseString.precomposedStringWithCompatibilityMapping;
	NSData *points = codePointsOf(mapped);
	const Char *p = points.bytes;
	NSMutableData *kept = [NSMutableData data];
	for (NSUInteger i = 0; i < points.length / sizeof(Char); i++) {
		Char c = p[i];
		// Ignored: soft hyphen, zero-width space and joiners, word joiner,
		// variation selectors and the byte order mark:
		if (c == 0xad || c == 0x200b || c == 0x2060 || c == 0xfeff
				|| c == 0x34f || (c >= 0x180b && c <= 0x180d)
				|| (c >= 0xfe00 && c <= 0xfe0f))
			continue;
		// Disallowed: noncharacters and the replacement character:
		if ((c >= 0xfdd0 && c <= 0xfdef) || (c & 0xfffe) == 0xfffe
				|| c == 0xfffd)
			return nil;
		[kept appendBytes:&c length:sizeof(Char)];
	}
	return stringOf(kept.bytes, kept.length / sizeof(Char));
}

static NSString *parseHost(NSString *input, BOOL isOpaque) {
	if ([input hasPrefix:@"["]) {
		return [input hasSuffix:@"]"] && input.length > 2 ? parseIPv6(
				[input substringWithRange:NSMakeRange(1, input.length - 2)])
				: nil;
	}
	NSData *points = codePointsOf(input);
	const Char *p = points.bytes;
	NSUInteger count = points.length / sizeof(Char);
	if (isOpaque) {
		NSMutableString *output = [NSMutableString string];
		for (NSUInteger i = 0; i < count; i++) {
			if (isForbiddenHostPoint(p[i]))
				return nil;
			appendEncoded(output, p[i], inC0Set);
		}
		return output;
	}
	NSString *domain = mapDomain(decodeUTF8(percentDecoded(
			[input dataUsingEncoding:NSUTF8StringEncoding])));
	if (!domain)
		return nil;
	// To ASCII, label by label:
	NSMutableArray *labels = [NSMutableArray array];
	for (NSString *label in [domain componentsSeparatedByCharactersInSet:
			[NSCharacterSet characterSetWithCharactersInString:
				@".。．｡"]]) {
		NSData *labelPoints = codePointsOf(label);
		const Char *l = labelPoints.bytes;
		BOOL isASCII = YES;
		for (NSUInteger i = 0; i < labelPoints.length / sizeof(Char); i++)
			isASCII &= l[i] < 0x80;
		[labels addObject:isASCII ? label : punycode(labelPoints)];
	}
	NSString *ascii = [labels componentsJoinedByString:@"."];
	if (!ascii.length)
		return nil;
	NSData *asciiPoints = codePointsOf(ascii);
	const Char *a = asciiPoints.bytes;
	for (NSUInteger i = 0; i < asciiPoints.length / sizeof(Char); i++) {
		if (isForbiddenDomainPoint(a[i]))
			return nil;
	}
	return endsInNumber(ascii) ? parseIPv4(ascii) : ascii;
}

#pragma mark - Parsing

static BOOL isWindowsDriveLetter(NSString *string, BOOL normalized) {
	if (string.length != 2 || !isAlpha([string characterAtIndex:0]))
		return NO;
	unichar second = [string characterAtIndex:1];
	return second == ':' || (!normalized && second == '|');
}

static BOOL startsWithWindowsDriveLetter(const Char *p, NSUInteger i,
		NSUInteger count) {
	if (i + 2 > count || !isAlpha(p[i]) || (p[i + 1] != ':' && p[i + 1] != '|'))
		return NO;
	if (i + 2 == count)
		return YES;
	Char c = p[i + 2];
	return c == '/' || c == '\\' || c == '?' || c == '#';
}

static void shortenPath(SGURLRecord *url) {
	if ([url.scheme isEqualToString:@"file"] && url.path.count == 1
			&& isWindowsDriveLetter(url.path[0], YES))
		return;
	if (url.path.count)
		[url.path removeLastObject];
}

static BOOL isSingleDot(NSString *s) {
	s = s.lowercaseString;
	return [s isEqualToString:@"."] || [s isEqualToString:@"%2e"];
}

static BOOL isDoubleDot(NSString *s) {
	s = s.lowercaseString;
	return [s isEqualToString:@".."] || [s isEqualToString:@".%2e"]
			|| [s isEqualToString:@"%2e."] || [s isEqualToString:@"%2e%2e"];
}

typedef NS_ENUM(NSInteger, State) {
	SchemeStart, Scheme, NoScheme, SpecialRelativeOrAuthority,
	PathOrAuthority, Relative, RelativeSlash, SpecialAuthoritySlashes,
	SpecialAuthorityIgnoreSlashes, Authority, Host, Port, File, FileSlash,
	FileHost, PathStart, Path, OpaquePath, Query, Fragment
};

// The basic URL parser of the standard, without state overrides, which the
// setters do without by parsing again:
static SGURLRecord *parseURL(NSString *string, SGURLRecord *base) {
	// Leading and trailing C0 controls and spaces go, tabs and newlines too:
	NSMutableData *data = [codePointsOf(string) mutableCopy];
	Char *all = data.mutableBytes;
	NSUInteger start = 0, end = data.length / sizeof(Char);
	while (start < end && all[start] <= 0x20)
		start++;
	while (end > start && all[end - 1] <= 0x20)
		end--;
	NSMutableData *cleaned = [NSMutableData data];
	for (NSUInteger i = start; i < end; i++) {
		if (all[i] != '\t' && all[i] != '\n' && all[i] != '\r')
			[cleaned appendBytes:&all[i] length:sizeof(Char)];
	}
	const Char *p = cleaned.bytes;
	NSUInteger count = cleaned.length / sizeof(Char);

	SGURLRecord *url = [[SGURLRecord alloc] init];
	State state = SchemeStart;
	NSMutableString *buffer = [NSMutableString string];
	BOOL atSignSeen = NO, insideBrackets = NO, passwordTokenSeen = NO;
	for (NSInteger i = 0;; i++) {
		Char c = i < (NSInteger)count ? p[i] : EOF_;
		Char next = i + 1 < (NSInteger)count ? p[i + 1] : EOF_;
		BOOL special = isSpecial(url.scheme);
		switch (state) {
		case SchemeStart:
			if (isAlpha(c)) {
				[buffer appendFormat:@"%c", (char)tolower((int)c)];
				state = Scheme;
			} else {
				state = NoScheme;
				i--;
			}
			break;
		case Scheme:
			if (isAlpha(c) || isDigit(c) || c == '+' || c == '-' || c == '.') {
				[buffer appendFormat:@"%c", (char)tolower((int)c)];
			} else if (c == ':') {
				url.scheme = buffer;
				buffer = [NSMutableString string];
				if ([url.scheme isEqualToString:@"file"]) {
					state = File;
				} else if (isSpecial(url.scheme) && base
						&& [base.scheme isEqualToString:url.scheme]) {
					state = SpecialRelativeOrAuthority;
				} else if (isSpecial(url.scheme)) {
					state = SpecialAuthoritySlashes;
				} else if (next == '/') {
					state = PathOrAuthority;
					i++;
				} else {
					url.opaquePath = @"";
					state = OpaquePath;
				}
			} else {
				buffer = [NSMutableString string];
				state = NoScheme;
				i = -1;
			}
			break;
		case NoScheme:
			if (!base || (base.opaquePath && c != '#'))
				return nil;
			if (base.opaquePath && c == '#') {
				url.scheme = base.scheme;
				url.opaquePath = base.opaquePath;
				url.query = base.query;
				url.fragment = @"";
				state = Fragment;
			} else {
				state = [base.scheme isEqualToString:@"file"] ? File : Relative;
				i--;
			}
			break;
		case SpecialRelativeOrAuthority:
			if (c == '/' && next == '/') {
				state = SpecialAuthorityIgnoreSlashes;
				i++;
			} else {
				state = Relative;
				i--;
			}
			break;
		case PathOrAuthority:
			if (c == '/') {
				state = Authority;
			} else {
				state = Path;
				i--;
			}
			break;
		case Relative:
			url.scheme = base.scheme;
			if (c == '/' || (isSpecial(url.scheme) && c == '\\')) {
				state = RelativeSlash;
			} else {
				url.username = base.username;
				url.password = base.password;
				url.host = base.host;
				url.port = base.port;
				url.path = [base.path mutableCopy];
				url.query = base.query;
				if (c == '?') {
					url.query = @"";
					state = Query;
				} else if (c == '#') {
					url.fragment = @"";
					state = Fragment;
				} else if (c != EOF_) {
					url.query = nil;
					shortenPath(url);
					state = Path;
					i--;
				}
			}
			break;
		case RelativeSlash:
			if (special && (c == '/' || c == '\\')) {
				state = SpecialAuthorityIgnoreSlashes;
			} else if (c == '/') {
				state = Authority;
			} else {
				url.username = base.username;
				url.password = base.password;
				url.host = base.host;
				url.port = base.port;
				state = Path;
				i--;
			}
			break;
		case SpecialAuthoritySlashes:
			state = SpecialAuthorityIgnoreSlashes;
			if (c == '/' && next == '/')
				i++;
			else
				i--;
			break;
		case SpecialAuthorityIgnoreSlashes:
			if (c != '/' && c != '\\') {
				state = Authority;
				i--;
			}
			break;
		case Authority:
			if (c == '@') {
				if (atSignSeen)
					[buffer insertString:@"%40" atIndex:0];
				atSignSeen = YES;
				NSData *points = codePointsOf(buffer);
				const Char *b = points.bytes;
				NSMutableString *username = [url.username mutableCopy];
				NSMutableString *password = [url.password mutableCopy];
				for (NSUInteger j = 0; j < points.length / sizeof(Char); j++) {
					if (b[j] == ':' && !passwordTokenSeen) {
						passwordTokenSeen = YES;
						continue;
					}
					appendEncoded(passwordTokenSeen ? password : username, b[j],
							inUserinfoSet);
				}
				url.username = username;
				url.password = password;
				buffer = [NSMutableString string];
			} else if (c == EOF_ || c == '/' || c == '?' || c == '#'
					|| (special && c == '\\')) {
				if (atSignSeen && !buffer.length)
					return nil;
				i -= codePointsOf(buffer).length / sizeof(Char) + 1;
				buffer = [NSMutableString string];
				state = Host;
			} else {
				[buffer appendString:stringOf(&c, 1)];
			}
			break;
		case Host:
			if (c == ':' && !insideBrackets) {
				if (!buffer.length)
					return nil;
				url.host = parseHost(buffer, !special);
				if (!url.host)
					return nil;
				buffer = [NSMutableString string];
				state = Port;
			} else if (c == EOF_ || c == '/' || c == '?' || c == '#'
					|| (special && c == '\\')) {
				i--;
				if (special && !buffer.length)
					return nil;
				url.host = parseHost(buffer, !special);
				if (!url.host)
					return nil;
				buffer = [NSMutableString string];
				state = PathStart;
			} else {
				if (c == '[')
					insideBrackets = YES;
				if (c == ']')
					insideBrackets = NO;
				[buffer appendString:stringOf(&c, 1)];
			}
			break;
		case Port:
			if (isDigit(c)) {
				[buffer appendFormat:@"%c", (char)c];
			} else if (c == EOF_ || c == '/' || c == '?' || c == '#'
					|| (special && c == '\\')) {
				if (buffer.length) {
					// Leading zeros don't count:
					NSUInteger zeros = 0;
					while (zeros + 1 < buffer.length
							&& [buffer characterAtIndex:zeros] == '0')
						zeros++;
					long long port = buffer.length - zeros > 5 ? 65536
							: buffer.longLongValue;
					if (port > 65535)
						return nil;
					url.port = [defaultPort(url.scheme) isEqual:@(port)]
							? nil : @(port);
					buffer = [NSMutableString string];
				}
				state = PathStart;
				i--;
			} else {
				return nil;
			}
			break;
		case File:
			url.scheme = @"file";
			url.host = @"";
			if (c == '/' || c == '\\') {
				state = FileSlash;
			} else if (base && [base.scheme isEqualToString:@"file"]) {
				url.host = base.host;
				url.path = [base.path mutableCopy];
				url.query = base.query;
				if (c == '?') {
					url.query = @"";
					state = Query;
				} else if (c == '#') {
					url.fragment = @"";
					state = Fragment;
				} else if (c != EOF_) {
					url.query = nil;
					if (!startsWithWindowsDriveLetter(p, i, count))
						shortenPath(url);
					else
						url.path = [NSMutableArray array];
					state = Path;
					i--;
				}
			} else {
				state = Path;
				i--;
			}
			break;
		case FileSlash:
			if (c == '/' || c == '\\') {
				state = FileHost;
			} else {
				if (base && [base.scheme isEqualToString:@"file"]) {
					url.host = base.host;
					if (!startsWithWindowsDriveLetter(p, i, count)
							&& base.path.count
							&& isWindowsDriveLetter(base.path[0], YES))
						[url.path addObject:base.path[0]];
				}
				state = Path;
				i--;
			}
			break;
		case FileHost:
			if (c == EOF_ || c == '/' || c == '\\' || c == '?' || c == '#') {
				i--;
				if (isWindowsDriveLetter(buffer, NO)) {
					state = Path;
				} else if (!buffer.length) {
					url.host = @"";
					state = PathStart;
				} else {
					NSString *host = parseHost(buffer, NO);
					if (!host)
						return nil;
					url.host = [host isEqualToString:@"localhost"] ? @"" : host;
					buffer = [NSMutableString string];
					state = PathStart;
				}
			} else {
				[buffer appendString:stringOf(&c, 1)];
			}
			break;
		case PathStart:
			if (special) {
				state = Path;
				if (c != '/' && c != '\\')
					i--;
			} else if (c == '?') {
				url.query = @"";
				state = Query;
			} else if (c == '#') {
				url.fragment = @"";
				state = Fragment;
			} else if (c != EOF_) {
				state = Path;
				if (c != '/')
					i--;
			}
			break;
		case Path:
			if (c == EOF_ || c == '/' || (special && c == '\\') || c == '?'
					|| c == '#') {
				BOOL isSlash = c == '/' || (special && c == '\\');
				if (isDoubleDot(buffer)) {
					shortenPath(url);
					if (!isSlash)
						[url.path addObject:@""];
				} else if (isSingleDot(buffer) && !isSlash) {
					[url.path addObject:@""];
				} else if (!isSingleDot(buffer)) {
					if ([url.scheme isEqualToString:@"file"] && !url.path.count
							&& isWindowsDriveLetter(buffer, NO)) {
						[buffer replaceCharactersInRange:NSMakeRange(1, 1)
								withString:@":"];
					}
					[url.path addObject:[buffer copy]];
				}
				buffer = [NSMutableString string];
				if (c == '?') {
					url.query = @"";
					state = Query;
				} else if (c == '#') {
					url.fragment = @"";
					state = Fragment;
				}
			} else {
				appendEncoded(buffer, c, inPathSet);
			}
			break;
		case OpaquePath:
			if (c == '?') {
				url.query = @"";
				state = Query;
			} else if (c == '#') {
				url.fragment = @"";
				state = Fragment;
			} else if (c != EOF_) {
				NSMutableString *path = [url.opaquePath mutableCopy];
				// A space before a query or fragment is encoded, so it
				// doesn't end the path:
				if (c == ' ' && (next == '?' || next == '#'))
					[path appendString:@"%20"];
				else
					appendEncoded(path, c, inC0Set);
				url.opaquePath = path;
			}
			break;
		case Query:
			if (c == '#' || c == EOF_) {
				url.query = [url.query stringByAppendingString:encoded(buffer,
						special ? inSpecialQuerySet : inQuerySet)];
				buffer = [NSMutableString string];
				if (c == '#') {
					url.fragment = @"";
					state = Fragment;
				}
			} else {
				[buffer appendString:stringOf(&c, 1)];
			}
			break;
		case Fragment:
			if (c != EOF_) {
				NSMutableString *fragment = [url.fragment mutableCopy];
				appendEncoded(fragment, c, inFragmentSet);
				url.fragment = fragment;
			}
			break;
		}
		if (c == EOF_ && i >= (NSInteger)count)
			break;
	}
	return url;
}

#pragma mark - Serializing

static NSString *pathnameOf(SGURLRecord *url) {
	if (url.opaquePath)
		return url.opaquePath;
	NSMutableString *output = [NSMutableString string];
	for (NSString *segment in url.path)
		[output appendFormat:@"/%@", segment];
	return output;
}

static NSString *hrefOf(SGURLRecord *url) {
	NSMutableString *output = [NSMutableString stringWithFormat:@"%@:",
			url.scheme];
	if (url.host) {
		[output appendString:@"//"];
		if (url.username.length || url.password.length) {
			[output appendString:url.username];
			if (url.password.length)
				[output appendFormat:@":%@", url.password];
			[output appendString:@"@"];
		}
		[output appendString:url.host];
		if (url.port)
			[output appendFormat:@":%@", url.port];
	} else if (!url.opaquePath && url.path.count > 1
			&& ![url.path[0] length]) {
		[output appendString:@"/."];
	}
	[output appendString:pathnameOf(url)];
	if (url.query)
		[output appendFormat:@"?%@", url.query];
	if (url.fragment)
		[output appendFormat:@"#%@", url.fragment];
	return output;
}

static NSDictionary<NSString *, NSString *> *partsOf(SGURLRecord *url) {
	NSString *host = url.host ?: @"";
	NSString *port = url.port ? url.port.stringValue : @"";
	BOOL hasOrigin = isSpecial(url.scheme)
			&& ![url.scheme isEqualToString:@"file"];
	NSString *origin = hasOrigin ? [NSString stringWithFormat:@"%@://%@%@",
			url.scheme, host, url.port ? [@":" stringByAppendingString:port]
				: @""] : @"null";
	// A blob's is its URL's, when that's http(s):
	if ([url.scheme isEqualToString:@"blob"]) {
		SGURLRecord *inner = parseURL(pathnameOf(url), nil);
		origin = [inner.scheme isEqualToString:@"http"]
				|| [inner.scheme isEqualToString:@"https"]
				? partsOf(inner)[@"origin"] : @"null";
	}
	return @{
		@"href": hrefOf(url),
		@"origin": origin,
		@"protocol": [url.scheme stringByAppendingString:@":"],
		@"username": url.username,
		@"password": url.password,
		@"host": url.port ? [NSString stringWithFormat:@"%@:%@", host, port]
				: host,
		@"hostname": host,
		@"port": port,
		@"pathname": pathnameOf(url),
		@"search": url.query.length ? [@"?" stringByAppendingString:url.query]
				: @"",
		@"hash": url.fragment.length
				? [@"#" stringByAppendingString:url.fragment] : @""
	};
}

#pragma mark - SGURLParser

@implementation SGURLParser

+ (NSDictionary *)parse:(NSString *)input base:(NSString *)base {
	SGURLRecord *baseURL = nil;
	if (base) {
		baseURL = parseURL(base, nil);
		if (!baseURL)
			return nil;
	}
	SGURLRecord *url = parseURL(input, baseURL);
	return url ? partsOf(url) : nil;
}

// The setters, each by changing the record as its state override would, or by
// parsing the part in the place it takes in the URL:
+ (NSDictionary *)set:(NSString *)href part:(NSString *)name
		value:(NSString *)value {
	SGURLRecord *url = parseURL(href, nil);
	if (!url)
		return nil;
	if ([name isEqualToString:@"href"])
		return [self parse:value base:nil];
	SGURLRecord *changed = [url copy];
	BOOL hasCredentials = url.host.length
			&& ![url.scheme isEqualToString:@"file"];
	if ([name isEqualToString:@"protocol"]) {
		NSString *scheme = [value componentsSeparatedByString:@":"][0]
				.lowercaseString;
		SGURLRecord *parsed = parseURL([scheme stringByAppendingString:@":"],
				nil);
		if (parsed && isSpecial(scheme) == isSpecial(url.scheme)
				&& !([scheme isEqualToString:@"file"]
					&& (url.username.length || url.password.length || url.port))
				&& !([url.scheme isEqualToString:@"file"] && !url.host.length)) {
			changed.scheme = scheme;
			if ([changed.port isEqual:defaultPort(scheme)])
				changed.port = nil;
		}
	} else if ([name isEqualToString:@"username"]) {
		if (hasCredentials)
			changed.username = encoded(value, inUserinfoSet);
	} else if ([name isEqualToString:@"password"]) {
		if (hasCredentials)
			changed.password = encoded(value, inUserinfoSet);
	} else if ([name isEqualToString:@"host"]
			|| [name isEqualToString:@"hostname"]) {
		if (!url.opaquePath) {
			// The host, up to where the path would start:
			NSRange range = [value rangeOfCharacterFromSet:[NSCharacterSet
					characterSetWithCharactersInString:isSpecial(url.scheme)
						? @"/?#\\" : @"/?#"]];
			NSString *host = range.location == NSNotFound ? value
					: [value substringToIndex:range.location];
			NSString *port = nil;
			NSRange colon = [host rangeOfString:@":"
					options:NSBackwardsSearch];
			if (colon.location != NSNotFound
					&& ![host hasSuffix:@"]"]) {
				port = [host substringFromIndex:colon.location + 1];
				host = [host substringToIndex:colon.location];
			}
			NSString *parsed = host.length || !isSpecial(url.scheme)
					? parseHost(host, !isSpecial(url.scheme)) : nil;
			if (parsed && !(isSpecial(url.scheme) && !parsed.length)) {
				changed.host = [url.scheme isEqualToString:@"file"]
						&& [parsed isEqualToString:@"localhost"] ? @"" : parsed;
				if ([name isEqualToString:@"host"] && port.length) {
					NSDictionary *withPort = [self set:hrefOf(changed)
							part:@"port" value:port];
					return withPort ?: partsOf(changed);
				}
			}
		}
	} else if ([name isEqualToString:@"port"]) {
		if (hasCredentials) {
			NSUInteger digits = 0;
			while (digits < value.length
					&& isDigit([value characterAtIndex:digits]))
				digits++;
			if (!value.length) {
				changed.port = nil;
			} else if (digits) {
				long long port = digits > 5 ? 65536
						: [value substringToIndex:digits].longLongValue;
				if (port <= 65535)
					changed.port = [defaultPort(url.scheme) isEqual:@(port)]
							? nil : @(port);
			}
		}
	} else if ([name isEqualToString:@"pathname"]) {
		if (!url.opaquePath) {
			// The path parsed where it'd be, with what comes after it kept:
			SGURLRecord *empty = [url copy];
			empty.path = [NSMutableArray array];
			empty.query = empty.fragment = nil;
			NSString *prefix = hrefOf(empty);
			NSString *path = [[value stringByReplacingOccurrencesOfString:@"?"
					withString:@"%3F"] stringByReplacingOccurrencesOfString:@"#"
					withString:@"%23"];
			if (![path hasPrefix:@"/"] && !(isSpecial(url.scheme)
					&& [path hasPrefix:@"\\"]))
				path = [@"/" stringByAppendingString:path];
			SGURLRecord *parsed = parseURL([prefix
					stringByAppendingString:path], nil);
			if (parsed)
				changed.path = parsed.path;
		}
	} else if ([name isEqualToString:@"search"]) {
		NSString *query = [value hasPrefix:@"?"]
				? [value substringFromIndex:1] : value;
		changed.query = value.length ? encoded(query, isSpecial(url.scheme)
				? inSpecialQuerySet : inQuerySet) : nil;
	} else if ([name isEqualToString:@"hash"]) {
		NSString *fragment = [value hasPrefix:@"#"]
				? [value substringFromIndex:1] : value;
		changed.fragment = value.length
				? encoded(fragment, inFragmentSet) : nil;
	} else {
		return nil;
	}
	return partsOf(changed);
}

+ (NSArray *)parseQuery:(NSString *)query {
	NSMutableArray *pairs = [NSMutableArray array];
	for (NSString *part in [query componentsSeparatedByString:@"&"]) {
		if (!part.length)
			continue;
		NSRange equals = [part rangeOfString:@"="];
		NSString *name = equals.location == NSNotFound ? part
				: [part substringToIndex:equals.location];
		NSString *value = equals.location == NSNotFound ? @""
				: [part substringFromIndex:equals.location + 1];
		NSString *(^decode)(NSString *) = ^NSString *(NSString *s) {
			s = [s stringByReplacingOccurrencesOfString:@"+" withString:@" "];
			return decodeUTF8(percentDecoded(
					[s dataUsingEncoding:NSUTF8StringEncoding]));
		};
		[pairs addObject:@[decode(name), decode(value)]];
	}
	return pairs;
}

+ (NSString *)serializeQuery:(NSArray *)pairs {
	NSString *(^encode)(NSString *) = ^NSString *(NSString *s) {
		NSData *bytes = [s dataUsingEncoding:NSUTF8StringEncoding];
		const uint8_t *b = bytes.bytes;
		NSMutableString *output = [NSMutableString string];
		for (NSUInteger i = 0; i < bytes.length; i++) {
			uint8_t c = b[i];
			if (c == ' ')
				[output appendString:@"+"];
			else if (isAlpha(c) || isDigit(c) || c == '*' || c == '-'
					|| c == '.' || c == '_')
				[output appendFormat:@"%c", c];
			else
				[output appendFormat:@"%%%02X", c];
		}
		return output;
	};
	NSMutableArray *parts = [NSMutableArray array];
	for (NSArray *pair in pairs) {
		[parts addObject:[NSString stringWithFormat:@"%@=%@",
				encode([pair[0] description]), encode([pair[1] description])]];
	}
	return [parts componentsJoinedByString:@"&"];
}

@end
