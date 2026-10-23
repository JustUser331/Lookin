#import <Cocoa/Cocoa.h>
#import "LKSimulatorAutoConnect.h"

// Хост использует production manager, но его simctl runner ограничен временными устройствами.
int main(int argc, char **argv) { @autoreleasepool {
    NSString *directory = @(argv[1]);
    NSArray *allowedDevices = [@(argv[4]) componentsSeparatedByString:@","];
    LKSimulatorCommandRunner runner = ^LKSimulatorCommandResult *(NSArray *arguments) {
        LKSimulatorCommandResult *result = [LKSimulatorCommandResult new];
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
        task.arguments = [@[@"simctl"] arrayByAddingObjectsFromArray:arguments];
        NSPipe *output = [NSPipe pipe]; task.standardOutput = output;
        task.standardError = NSFileHandle.fileHandleWithNullDevice;
        [task launch];
        NSData *data = [output.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        result.status = task.terminationStatus;
        result.error = @"Live simctl command failed";
        if ([arguments.firstObject isEqual:@"list"]) {
            NSMutableDictionary *json = [[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] mutableCopy];
            for (NSString *runtime in [json[@"devices"] allKeys]) {
                json[@"devices"][runtime] = [json[@"devices"][runtime] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *device, NSDictionary *bindings) {
                    return [allowedDevices containsObject:device[@"udid"]];
                }]];
            }
            data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
        }
        result.output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        return result;
    };
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"local.lookin.autoconnect.live-test"];
    [defaults setObject:@{@"local.lookin.research.autoconnect": @"Research"} forKey:LKSimulatorAutoConnectDefaultsKey];
    LKSimulatorAutoConnect *manager = [[LKSimulatorAutoConnect alloc] initWithDefaults:defaults directory:directory loaderSource:@(argv[2]) serverPath:@(argv[3]) runner:runner];
    [[NSNotificationCenter defaultCenter] addObserverForName:LKSimulatorAutoConnectDidChangeNotification object:manager queue:nil usingBlock:^(NSNotification *notification) {
        printf("%s\n", manager.statusText.UTF8String); fflush(stdout);
    }];
    [manager start];
    NSString *stop = [directory stringByAppendingPathComponent:@"stop"];
    while (![NSFileManager.defaultManager fileExistsAtPath:stop]) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    __block BOOL finished = NO;
    [manager stopWithCompletion:^{ finished = YES; }];
    while (!finished) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    [defaults removePersistentDomainForName:@"local.lookin.autoconnect.live-test"];
    return 0;
}}
