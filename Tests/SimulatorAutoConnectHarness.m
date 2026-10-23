#import <Foundation/Foundation.h>
#import "LKSimulatorAutoConnect.h"
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>

static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static void Wait(BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
    while (!condition() && deadline.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Check(condition(), @"Timed out");
}
static BOOL GateIsHeld(NSString *directory) {
    int fd = open([[directory stringByAppendingPathComponent:@"owner.lock"] fileSystemRepresentation], O_RDONLY);
    if (fd < 0) return NO;
    BOOL held = flock(fd, LOCK_SH | LOCK_NB) == -1;
    if (!held) flock(fd, LOCK_UN);
    close(fd);
    return held;
}

int main(int argc, char **argv) { @autoreleasepool {
    NSString *directory = @(argv[1]);
    NSString *loader = [directory stringByAppendingPathComponent:@"loader.dylib"];
    Check([[LKSimulatorAutoConnect environment:@"/existing/a.dylib:/existing/b.dylib" addingLoader:loader]
        isEqual:[NSString stringWithFormat:@"/existing/a.dylib:/existing/b.dylib:%@", loader]], @"Preserve other loaders");
    Check([[LKSimulatorAutoConnect environment:[NSString stringWithFormat:@"%@:/other:%@", loader, loader] removingLoader:loader] isEqual:@"/other"], @"Remove only owned duplicate entries");
    Check(![LKSimulatorAutoConnect isValidBundleID:@"app;rm -rf /"], @"Reject invalid identifier");
    NSString *suite = [@"lookin.autoconnect.tests." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults setObject:@{@"test.selected": @"Selected"} forKey:LKSimulatorAutoConnectDefaultsKey];
    NSMutableArray *devices = [@[@{@"udid": @"A", @"name": @"Simulator A", @"state": @"Booted"}] mutableCopy];
    NSMutableDictionary *environments = [@{@"A": @"/existing/a.dylib"} mutableCopy];
    NSObject *mutex = [NSObject new];
    __block BOOL listedInstalledApps = NO;
    __block BOOL failWrites = NO;
    __block BOOL bootReady = NO;
    LKSimulatorCommandRunner runner = ^LKSimulatorCommandResult *(NSArray *arguments) {
        LKSimulatorCommandResult *result = [LKSimulatorCommandResult new];
        result.status = 0; result.output = @""; result.error = @"";
        @synchronized(mutex) {
            if ([arguments.firstObject isEqual:@"list"]) {
                NSDictionary *json = @{@"devices": @{@"com.apple.CoreSimulator.SimRuntime.iOS-18-6": devices.copy,
                    @"com.apple.CoreSimulator.SimRuntime.watchOS-26-5": @[@{@"udid": @"W", @"state": @"Booted"}]}};
                result.output = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:json options:0 error:nil] encoding:NSUTF8StringEncoding];
            } else if ([arguments.firstObject isEqual:@"bootstatus"]) {
                result.status = bootReady ? 0 : 1;
            } else if ([arguments.firstObject isEqual:@"listapps"]) {
                listedInstalledApps = YES;
                NSDictionary *apps = @{@"test.selected": @{@"ApplicationType": @"User", @"CFBundleIdentifier": @"test.selected", @"CFBundleName": @"Selected"},
                    @"apple.system": @{@"ApplicationType": @"System", @"CFBundleIdentifier": @"apple.system"}};
                result.output = [[NSString alloc] initWithData:[NSPropertyListSerialization dataWithPropertyList:apps format:NSPropertyListXMLFormat_v1_0 options:0 error:nil] encoding:NSUTF8StringEncoding];
            } else {
                Check(![arguments[1] isEqual:@"W"], @"Never configure watchOS");
                NSString *action = arguments[3], *udid = arguments[1];
                if ([action isEqual:@"getenv"]) result.output = [(environments[udid] ?: @"") stringByAppendingString:@"\n"];
                else if (failWrites) { result.status = 1; result.error = @"Fixture write failure"; }
                else if ([action isEqual:@"setenv"]) environments[udid] = arguments[5];
                else if ([action isEqual:@"unsetenv"]) [environments removeObjectForKey:udid];
                else Check(NO, @"Unexpected mutation");
            }
        }
        return result;
    };
    NSString *source = [directory stringByAppendingPathComponent:@"source"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    [@"loader fixture" writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:nil];
    LKSimulatorAutoConnect *manager = [[LKSimulatorAutoConnect alloc] initWithDefaults:defaults directory:directory loaderSource:source serverPath:source runner:runner];
    manager.catalogVisible = YES;
    [manager start];
    Wait(^BOOL{ return [manager.statusText containsString:@"Waiting for the Simulator"]; });
    @synchronized(mutex) {
        Check(![environments[@"A"] containsString:loader], @"Do not change launch environment before boot completes");
        bootReady = YES;
    }
    [manager refresh];
    Wait(^BOOL{ @synchronized(mutex) { return [environments[@"A"] containsString:loader] && manager.availableApps.count == 1; } });
    Check(GateIsHeld(directory), @"Keep desktop lifetime gate");
    Check(listedInstalledApps, @"Discover installed applications");
    Check([[NSDictionary dictionaryWithContentsOfFile:[directory stringByAppendingPathComponent:@"config.plist"]][@"bundleIDs"] containsObject:@"test.selected"], @"Persist bundle identity, no installation paths");

    @synchronized(mutex) { [devices addObject:@{@"udid": @"B", @"name": @"Simulator B", @"state": @"Booted"}]; }
    [manager refresh];
    Wait(^BOOL{ @synchronized(mutex) { return [environments[@"B"] isEqual:loader]; } });
    @synchronized(mutex) { environments[@"A"] = @"/other-injected-later"; }
    [manager refresh];
    Wait(^BOOL{ @synchronized(mutex) { return [environments[@"A"] isEqual:[@"/other-injected-later:" stringByAppendingString:loader]]; } });

    LKSimulatorAutoConnect *second = [[LKSimulatorAutoConnect alloc] initWithDefaults:defaults directory:directory loaderSource:source serverPath:source runner:runner];
    [second start];
    Wait(^BOOL{ return [second.statusText containsString:@"Another Lookin"]; });
    __block BOOL secondStopped = NO;
    [second stopWithCompletion:^{ secondStopped = YES; }];
    Wait(^BOOL{ return secondStopped; });
    Check(GateIsHeld(directory), @"Rejected second owner must not release first owner");

    [manager setBundleID:@"test.selected" name:@"Selected" enabled:NO];
    Wait(^BOOL{ @synchronized(mutex) { return ![environments[@"A"] containsString:loader] && manager.rememberedApps.count == 0; } });
    @synchronized(mutex) { Check([environments[@"A"] isEqual:@"/other-injected-later"], @"Disable preserves concurrent third-party changes"); }
    [manager setBundleID:@"test.selected" name:@"Selected" enabled:YES];
    Wait(^BOOL{ @synchronized(mutex) { return [environments[@"A"] containsString:loader] && manager.rememberedApps.count == 1; } });
    @synchronized(mutex) { failWrites = YES; }
    __block BOOL stopped = NO;
    @synchronized(mutex) {
        [manager refresh];
        [manager setBundleID:@"test.queued" name:@"Queued before quit" enabled:YES];
        [manager stopWithCompletion:^{ stopped = YES; }];
    }
    Wait(^BOOL{ return stopped; });
    Check(!GateIsHeld(directory), @"Quit releases gate even if simctl cleanup fails");
    Check(![[NSDictionary dictionaryWithContentsOfFile:[directory stringByAppendingPathComponent:@"config.plist"]][@"enabled"] boolValue], @"Quit disables stale environment");
    Check([defaults dictionaryForKey:LKSimulatorAutoConnectDefaultsKey][@"test.selected"] != nil, @"Selection survives desktop quit");
    Check([defaults dictionaryForKey:LKSimulatorAutoConnectDefaultsKey][@"test.queued"] != nil, @"Accepted selection survives immediate quit while simulator commands are pending");
    [defaults removePersistentDomainForName:suite];
    puts("PASS: Simulator manager discovery, cross-device activation, environment ownership, selection and lifecycle");
    return 0;
}}
