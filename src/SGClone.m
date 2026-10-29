//
//  SGClone.m
//  Scriptographer for Glyphs
//

#import "SGClone.h"

// How deep objects may nest, before serializing would run out of stack:
static const NSUInteger maxDepth = 1000;

// The typed array classes, as Object.prototype.toString() names them, and the
// Error classes kept as themselves:
static NSArray<NSString *> *typedArrays(void) {
	return @[@"Int8Array", @"Uint8Array", @"Uint8ClampedArray", @"Int16Array",
			@"Uint16Array", @"Int32Array", @"Uint32Array", @"Float32Array",
			@"Float64Array", @"BigInt64Array", @"BigUint64Array"];
}

static NSArray<NSString *> *errorClasses(void) {
	return @[@"Error", @"EvalError", @"RangeError", @"ReferenceError",
			@"SyntaxError", @"TypeError", @"URIError"];
}

// The data's tags: each kind of value is an array starting with its tag.
static NSString *const undefinedTag = @"undefined", *const boolTag = @"bool",
		*const numberTag = @"number", *const bigIntTag = @"bigint",
		*const seenTag = @"seen", *const objectTag = @"object",
		*const arrayTag = @"array", *const dateTag = @"date",
		*const regExpTag = @"regexp", *const mapTag = @"map",
		*const setTag = @"set", *const bufferTag = @"buffer",
		*const viewTag = @"view", *const errorTag = @"error",
		*const boxedTag = @"boxed", *const blobTag = @"blob",
		*const pixelsTag = @"pixels", *const geometryTag = @"geometry",
		*const portTag = @"port";

@interface SGSerializer : NSObject
// Why the value can't be kept, once serializing failed:
@property (nonatomic, readonly, nullable) NSString *failure;
@end

@implementation SGSerializer {
	JSContext *_context;
	JSValue *_natives;
	// The objects met, by their number, and the transferred ports:
	JSValue *_seen, *_ports;
	NSUInteger _count;
}

- (instancetype)initWithContext:(JSContext *)context natives:(JSValue *)natives
		ports:(NSArray<JSValue *> *)ports {
	self = [super init];
	if (self) {
		_context = context;
		_natives = natives;
		_seen = [context[@"Map"] constructWithArguments:@[]];
		_ports = [context[@"Map"] constructWithArguments:@[]];
		[ports enumerateObjectsUsingBlock:^(JSValue *port, NSUInteger i,
				BOOL *stop) {
			[self->_ports invokeMethod:@"set" withArguments:@[port, @(i)]];
		}];
	}
	return self;
}

- (id)fail:(NSString *)message {
	_failure = _failure ?: message;
	return nil;
}

- (id)serialize:(JSValue *)value depth:(NSUInteger)depth {
	if (_failure)
		return nil;
	if (value.isUndefined)
		return @[undefinedTag];
	if (value.isNull)
		return [NSNull null];
	if (value.isBoolean)
		return @[boolTag, @(value.toBool)];
	if (value.isNumber)
		return @[numberTag, @(value.toDouble)];
	if (value.isString)
		return value.toString;
	if (depth > maxDepth)
		return [self fail:@"The value nests too deeply."];
	JSValue *seen = [_seen invokeMethod:@"get" withArguments:@[value]];
	if (seen.isNumber)
		return @[seenTag, @(seen.toUInt32)];
	JSValue *port = [_ports invokeMethod:@"get" withArguments:@[value]];
	if (port.isNumber)
		return @[portTag, @(port.toUInt32)];
	NSString *class = [[_context[@"Object"][@"prototype"][@"toString"]
			invokeMethod:@"call" withArguments:@[value]] toString];
	NSString *name = [[class stringByReplacingOccurrencesOfString:@"[object "
			withString:@""] stringByReplacingOccurrencesOfString:@"]"
			withString:@""];
	// A BigInt is a primitive, boxed or not; symbols and functions can't be
	// kept:
	if ([name isEqualToString:@"BigInt"])
		return @[bigIntTag, value.toString];
	if ([name isEqualToString:@"Symbol"])
		return [self fail:@"A symbol can't be cloned."];
	if ([name hasSuffix:@"Function"])
		return [self fail:@"A function can't be cloned."];
	// Numbered before what it holds, so cycles come back to it:
	[_seen invokeMethod:@"set" withArguments:@[value, @(_count++)]];
	NSUInteger next = depth + 1;
	if ([name isEqualToString:@"Array"]) {
		return @[arrayTag, @([value[@"length"] toDouble]),
				[self members:value depth:next] ?: @[]];
	}
	if ([name isEqualToString:@"Object"] || [name isEqualToString:@"Arguments"])
		return @[objectTag, [self members:value depth:next] ?: @[]];
	if ([name isEqualToString:@"Map"] || [name isEqualToString:@"Set"]) {
		JSValue *entries = [_context[@"Array"] invokeMethod:@"from"
				withArguments:@[value]];
		NSMutableArray *items = [NSMutableArray array];
		NSUInteger length = [entries[@"length"] toUInt32];
		for (NSUInteger i = 0; i < length && !_failure; i++) {
			JSValue *entry = entries[i];
			if ([name isEqualToString:@"Map"]) {
				[items addObject:@[[self serialize:entry[0] depth:next]
						?: [NSNull null], [self serialize:entry[1] depth:next]
						?: [NSNull null]]];
			} else {
				[items addObject:[self serialize:entry depth:next]
						?: [NSNull null]];
			}
		}
		return @[[name isEqualToString:@"Map"] ? mapTag : setTag, items];
	}
	if ([name isEqualToString:@"Date"]) {
		return @[dateTag, @([[value invokeMethod:@"getTime" withArguments:@[]]
				toDouble])];
	}
	if ([name isEqualToString:@"RegExp"])
		return @[regExpTag, value[@"source"].toString, value[@"flags"].toString];
	if ([@[@"Boolean", @"Number", @"String"] containsObject:name]) {
		return @[boxedTag, name, [self serialize:[value invokeMethod:@"valueOf"
				withArguments:@[]] depth:next] ?: [NSNull null]];
	}
	if ([name isEqualToString:@"ArrayBuffer"]) {
		JSContextRef context = _context.JSGlobalContextRef;
		JSObjectRef object = (JSObjectRef)value.JSValueRef;
		void *bytes = JSObjectGetArrayBufferBytesPtr(context, object, NULL);
		size_t length = JSObjectGetArrayBufferByteLength(context, object, NULL);
		return bytes ? [NSData dataWithBytes:bytes length:length] : [NSData data];
	}
	if ([name isEqualToString:@"DataView"]
			|| [typedArrays() containsObject:name]) {
		id buffer = [self serialize:value[@"buffer"] depth:next];
		return @[viewTag, name, buffer ?: [NSNull null],
				@([value[@"byteOffset"] toDouble]),
				@([value[[name isEqualToString:@"DataView"] ? @"byteLength"
					: @"length"] toDouble])];
	}
	if ([name isEqualToString:@"Error"]) {
		NSString *errorName = value[@"name"].toString;
		JSValue *stack = value[@"stack"];
		return @[errorTag, [errorClasses() containsObject:errorName]
				? errorName : @"Error", value[@"message"].toString,
				stack.isString ? stack.toString : [NSNull null]];
	}
	if ([name isEqualToString:@"ImageData"]) {
		return @[pixelsTag, [self serialize:value[@"data"] depth:next]
				?: [NSNull null], @([value[@"width"] toDouble]),
				@([value[@"height"] toDouble])];
	}
	if ([name isEqualToString:@"Blob"] || [name isEqualToString:@"File"]) {
		JSValue *bytes = [_natives invokeMethod:@"getBytes"
				withArguments:@[value]];
		return @[blobTag, SGDataOfValue(bytes), value[@"type"].toString];
	}
	JSValue *values = [_natives invokeMethod:@"getGeometryValues"
			withArguments:@[value]];
	if (values.isArray)
		return @[geometryTag, name, values.toArray];
	return [self fail:[NSString stringWithFormat:@"%@ can't be cloned.",
			class]];
}

// The own enumerable properties of `object`, serialized:
- (NSArray *)members:(JSValue *)object depth:(NSUInteger)depth {
	JSValue *keys = [_context[@"Object"] invokeMethod:@"keys"
			withArguments:@[object]];
	NSMutableArray *members = [NSMutableArray array];
	NSUInteger length = [keys[@"length"] toUInt32];
	for (NSUInteger i = 0; i < length && !_failure; i++) {
		NSString *key = keys[i].toString;
		[members addObject:@[key, [self serialize:object[key] depth:depth]
				?: [NSNull null]]];
	}
	return members;
}

@end

@implementation SGClone

+ (id)serialize:(JSValue *)value natives:(JSValue *)natives
		ports:(NSArray<JSValue *> *)ports {
	SGSerializer *serializer = [[SGSerializer alloc]
			initWithContext:value.context natives:natives ports:ports];
	id data = [serializer serialize:value depth:0];
	NSString *failure = serializer.failure;
	if (failure) {
		JSContext *context = value.context;
		JSValue *error = [context[@"DOMException"]
				constructWithArguments:@[failure, @"DataCloneError"]];
		if (error.isObject)
			context.exception = error;
		else
			context.exception = [JSValue valueWithNewErrorFromMessage:failure
					inContext:context];
		return nil;
	}
	return data;
}

+ (JSValue *)deserialize:(id)data inContext:(JSContext *)context
		ports:(NSArray<JSValue *> *)ports {
	NSMutableArray *made = [NSMutableArray array];
	return [self make:data context:context ports:ports made:made];
}

// `data` made, with `made` the objects made so far, by number:
+ (JSValue *)make:(id)data context:(JSContext *)context
		ports:(NSArray<JSValue *> *)ports made:(NSMutableArray *)made {
	if ([data isKindOfClass:[NSString class]])
		return [JSValue valueWithObject:data inContext:context];
	if (data == [NSNull null])
		return [JSValue valueWithNullInContext:context];
	if ([data isKindOfClass:[NSData class]]) {
		JSValue *buffer = SGBytesValue(context, data)[@"buffer"];
		[made addObject:buffer];
		return buffer;
	}
	NSArray *list = data;
	NSString *tag = list[0];
	JSValue *(^construct)(NSString *, NSArray *) = ^JSValue *(NSString *class,
			NSArray *arguments) {
		return [context[class] constructWithArguments:arguments];
	};
	JSValue *(^make)(id) = ^JSValue *(id item) {
		return [self make:item context:context ports:ports made:made];
	};
	if ([tag isEqualToString:undefinedTag])
		return [JSValue valueWithUndefinedInContext:context];
	if ([tag isEqualToString:boolTag])
		return [JSValue valueWithBool:[list[1] boolValue] inContext:context];
	if ([tag isEqualToString:numberTag])
		return [JSValue valueWithDouble:[list[1] doubleValue] inContext:context];
	if ([tag isEqualToString:bigIntTag])
		return [context[@"BigInt"] callWithArguments:@[list[1]]];
	if ([tag isEqualToString:seenTag])
		return made[[list[1] unsignedIntegerValue]];
	if ([tag isEqualToString:portTag])
		return ports[[list[1] unsignedIntegerValue]];
	// An object is numbered when it's made, before what it holds is:
	NSUInteger number = made.count;
	[made addObject:[NSNull null]];
	JSValue *value;
	if ([tag isEqualToString:objectTag] || [tag isEqualToString:arrayTag]) {
		BOOL isArray = [tag isEqualToString:arrayTag];
		value = isArray ? construct(@"Array", @[list[1]])
				: [JSValue valueWithNewObjectInContext:context];
		made[number] = value;
		for (NSArray *member in list[isArray ? 2 : 1])
			value[member[0]] = make(member[1]);
	} else if ([tag isEqualToString:mapTag]) {
		value = made[number] = construct(@"Map", @[]);
		for (NSArray *pair in list[1]) {
			[value invokeMethod:@"set" withArguments:@[make(pair[0]),
					make(pair[1])]];
		}
	} else if ([tag isEqualToString:setTag]) {
		value = made[number] = construct(@"Set", @[]);
		for (id item in list[1])
			[value invokeMethod:@"add" withArguments:@[make(item)]];
	} else if ([tag isEqualToString:dateTag]) {
		value = construct(@"Date", @[list[1]]);
	} else if ([tag isEqualToString:regExpTag]) {
		value = construct(@"RegExp", @[list[1], list[2]]);
	} else if ([tag isEqualToString:boxedTag]) {
		value = construct(list[1], @[make(list[2])]);
	} else if ([tag isEqualToString:viewTag]) {
		value = construct(list[1], @[make(list[2]), list[3], list[4]]);
	} else if ([tag isEqualToString:errorTag]) {
		value = construct(list[1], @[list[2]]);
		if (list[3] != [NSNull null])
			value[@"stack"] = list[3];
	} else if ([tag isEqualToString:pixelsTag]) {
		value = construct(@"ImageData", @[make(list[1]), list[2], list[3]]);
	} else if ([tag isEqualToString:blobTag]) {
		value = construct(@"Blob", @[@[SGBytesValue(context, list[1])],
				@{ @"type": list[2] }]);
	} else {
		value = [self geometry:list[1] values:list[2] context:context];
	}
	made[number] = value;
	return value;
}

// The geometry object of `class` with its values, as getGeometryValues()
// in the bundle's geometry.js gives them:
+ (JSValue *)geometry:(NSString *)class values:(NSArray<NSNumber *> *)values
		context:(JSContext *)context {
	JSValue *constructor = context[class];
	if ([class hasPrefix:@"DOMPoint"] || [class hasPrefix:@"DOMRect"])
		return [constructor constructWithArguments:values];
	if ([class isEqualToString:@"DOMQuad"]) {
		NSMutableArray *points = [NSMutableArray array];
		for (NSUInteger i = 0; i + 3 < values.count; i += 4) {
			[points addObject:[context[@"DOMPoint"] constructWithArguments:
					[values subarrayWithRange:NSMakeRange(i, 4)]]];
		}
		return [constructor constructWithArguments:points];
	}
	// A matrix: a 2D one from its six values, which keep it 2D.
	NSArray *m = [values subarrayWithRange:NSMakeRange(0, 16)];
	NSArray *list = [values[16] boolValue]
			? @[m[0], m[1], m[4], m[5], m[12], m[13]] : m;
	return [constructor constructWithArguments:@[
			[context[@"Float64Array"] constructWithArguments:@[list]]]];
}

@end
