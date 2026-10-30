//
//  SGNatives.m
//  Scriptographer for Glyphs
//

#import "SGNatives.h"

SGMake SGValue(id value) {
	return ^id(JSContext *context) {
		return value;
	};
}

JSValue *SGBytesValue(JSContext *context, NSData *data) {
	JSValue *array = [context[@"Uint8Array"]
			constructWithArguments:@[@(data.length)]];
	void *bytes = JSObjectGetTypedArrayBytesPtr(context.JSGlobalContextRef,
			(JSObjectRef)array.JSValueRef, NULL);
	if (bytes && data.length)
		memcpy(bytes, data.bytes, data.length);
	return array;
}

NSData *SGDataOfValue(JSValue *value) {
	JSContextRef context = value.context.JSGlobalContextRef;
	JSObjectRef object = JSValueToObject(context, value.JSValueRef, NULL);
	void *bytes = object
			? JSObjectGetTypedArrayBytesPtr(context, object, NULL) : NULL;
	return bytes ? [NSData dataWithBytes:bytes
			length:JSObjectGetTypedArrayByteLength(context, object, NULL)]
			: [NSData data];
}

void SGThrowError(NSString *message) {
	JSContext *context = [JSContext currentContext];
	context.exception = [JSValue valueWithNewErrorFromMessage:message
			inContext:context];
}

void SGThrowErrorOfClass(NSString *name, NSString *message) {
	JSContext *context = [JSContext currentContext];
	context.exception = [context[name] constructWithArguments:@[message]];
}

void SGThrowDOMException(NSString *name, NSString *message) {
	JSContext *context = [JSContext currentContext];
	context.exception = [context[@"DOMException"]
			constructWithArguments:@[message, name]];
}
