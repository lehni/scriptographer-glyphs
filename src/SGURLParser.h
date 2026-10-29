//
//  SGURLParser.h
//  Scriptographer for Glyphs
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// URLs as the WHATWG URL standard parses them, for the bundle's `URL` and
// `URLSearchParams` (natives.url), as VectorCraft's url crate does. Domains
// are lowercased and Punycode-encoded, without the rest of UTS #46's mapping.
@interface SGURLParser : NSObject

// The parts of `input` against `base`, as the getters read them (`href`,
// `origin`, `protocol`, `username`, `password`, `host`, `hostname`, `port`,
// `pathname`, `search`, `hash`), or nil when it isn't a URL:
+ (nullable NSDictionary<NSString *, NSString *> *)parse:(NSString *)input
		base:(nullable NSString *)base;

// The parts of `href` once its part `name` is set to `value`, as its setter
// sets it: a value it can't take changes nothing. Nil for an invalid href:
+ (nullable NSDictionary<NSString *, NSString *> *)set:(NSString *)href
		part:(NSString *)name value:(NSString *)value;

// An application/x-www-form-urlencoded query's [name, value] pairs, and back:
+ (NSArray<NSArray<NSString *> *> *)parseQuery:(NSString *)query;
+ (NSString *)serializeQuery:(NSArray<NSArray<NSString *> *> *)pairs;

@end

NS_ASSUME_NONNULL_END
