// Tests SGURLParser against WPT's URL parsing cases (test/wpt, BSD license):
// what parses, its parts, and what fails.

#import <Foundation/Foundation.h>
#import "../src/SGURLParser.h"

int main(int argc, char **argv) {
	@autoreleasepool {
		NSString *file = [@(argv[1]) stringByAppendingPathComponent:
				@"wpt/urltestdata.json"];
		NSArray *cases = [NSJSONSerialization JSONObjectWithData:
				[NSData dataWithContentsOfFile:file] options:0 error:nil];
		NSArray *keys = @[@"href", @"origin", @"protocol", @"username",
				@"password", @"host", @"hostname", @"port", @"pathname",
				@"search", @"hash"];
		int count = 0, failures = 0;
		for (NSDictionary *test in cases) {
			// Strings are comments:
			if (![test isKindOfClass:[NSDictionary class]])
				continue;
			count++;
			id base = test[@"base"];
			NSDictionary *parts = [SGURLParser parse:test[@"input"]
					base:base == [NSNull null] ? nil : base];
			BOOL isPassed = [test[@"failure"] boolValue] ? !parts : !!parts;
			for (NSString *key in keys) {
				if (isPassed && parts && test[key]
						&& ![parts[key] isEqual:test[key]])
					isPassed = NO;
			}
			if (!isPassed) {
				fprintf(stderr, "failed: <%s> against <%s>: %s\n",
						[test[@"input"] UTF8String], [[base description]
						UTF8String], [parts[@"href"] ?: @"failure" UTF8String]);
				failures++;
			}
		}
		if (failures)
			fprintf(stderr, "%d of %d failed\n", failures, count);
		else
			printf("url: all %d passed\n", count);
		return failures ? 1 : 0;
	}
}
