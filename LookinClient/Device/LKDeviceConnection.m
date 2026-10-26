#import "LKDeviceConnection.h"
#import "LKAppsManager.h"
#import "LKStaticHierarchyDataSource.h"
#import "LKNavigationManager.h"
#include <signal.h>

@interface LKDeviceConnection ()
@property(nonatomic, readwrite) BOOL busy;
@end

@implementation LKDeviceConnection
+ (instancetype)sharedInstance {
    static LKDeviceConnection *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [self new]; });
    return instance;
}

- (void)run:(NSArray<NSString *> *)arguments completion:(void (^)(NSDictionary *))completion {
    [self runScript:@"device_connect.py" arguments:arguments completion:completion];
}

- (void)runScript:(NSString *)name arguments:(NSArray<NSString *> *)arguments completion:(void (^)(NSDictionary *))completion {
    if (self.busy) { completion(@{@"success": @NO, @"error": @"A device operation is already in progress."}); return; }
    self.busy = YES;
    NSString *script = [[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"DeviceSupport"] stringByAppendingPathComponent:name];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result;
        FILE *output = tmpfile(), *errors = tmpfile();
        if (!output || !errors) {
            result = @{@"success": @NO, @"error": @"Unable to create command output."};
        } else {
            NSTask *task = [NSTask new];
            task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
            task.arguments = [@[@"python3", @"-B", script] arrayByAddingObjectsFromArray:arguments];
            task.standardOutput = [[NSFileHandle alloc] initWithFileDescriptor:fileno(output) closeOnDealloc:NO];
            task.standardError = [[NSFileHandle alloc] initWithFileDescriptor:fileno(errors) closeOnDealloc:NO];
            NSMutableDictionary *environment = NSProcessInfo.processInfo.environment.mutableCopy;
            for (NSString *key in environment.allKeys) {
                if ([key hasPrefix:@"DYLD_"] || [key hasPrefix:@"PYTHON"] || [key hasPrefix:@"SIMCTL_CHILD_"]) [environment removeObjectForKey:key];
            }
            task.environment = environment;
            NSError *error;
            if ([task launchAndReturnError:&error]) {
                [task waitUntilExit];
                [task.standardOutput seekToFileOffset:0];
                result = [NSJSONSerialization JSONObjectWithData:[task.standardOutput readDataToEndOfFile] options:0 error:nil];
                if (![result isKindOfClass:NSDictionary.class]) {
                    [task.standardError seekToFileOffset:0];
                    NSString *message = [[NSString alloc] initWithData:[task.standardError readDataToEndOfFile] encoding:NSUTF8StringEncoding];
                    result = @{@"success": @NO, @"error": message.length ? message : @"Device helper failed. Check the Xcode command-line tools installation."};
                }
            } else result = @{@"success": @NO, @"error": error.localizedDescription ?: @"Unable to launch device helper."};
        }
        if (output) fclose(output);
        if (errors) fclose(errors);
        dispatch_async(dispatch_get_main_queue(), ^{ self.busy = NO; completion(result); });
    });
}

- (void)connectXcodeApp:(void (^)(NSDictionary *))completion {
    [self xcodeIntegrationStatus:^(NSDictionary *state) {
        if (state[@"error"]) { completion(state); return; }
        NSDictionary *session = state[@"lastSession"];
        if (![session[@"success"] boolValue] || ![session[@"session"] length] || ![session[@"bundleID"] length]) {
            completion(@{@"success": @NO, @"error": @"No ready Xcode session. Enable Xcode Integration, then Run a development iOS app from Xcode."});
            return;
        }
        self.busy = YES;
        NSDictionary *request = @{@"success": @YES, @"session": session[@"session"], @"bundleID": session[@"bundleID"], @"mode": @"xcode",
                                  @"log": [state[@"supportPath"] stringByAppendingPathComponent:@"last-session.json"]};
        [self selectSession:request attempts:20 completion:^(NSDictionary *result) {
            self.busy = NO;
            completion(result);
        }];
    }];
}

- (void)xcodeIntegrationStatus:(void (^)(NSDictionary *))completion {
    [self runScript:@"xcode_integration.py" arguments:@[@"refresh"] completion:completion];
}

- (void)setXcodeIntegrationEnabled:(BOOL)enabled completion:(void (^)(NSDictionary *))completion {
    [self runScript:@"xcode_integration.py" arguments:@[enabled ? @"enable" : @"disable"] completion:completion];
}

- (void)listDevices:(void (^)(NSDictionary *))completion { [self run:@[@"list"] completion:completion]; }

- (void)connectDevice:(NSString *)identifier appPath:(NSString *)path mode:(NSString *)mode completion:(void (^)(NSDictionary *))completion {
    [self run:@[@"connect", @"--device", identifier, @"--app", path, @"--mode", mode] completion:^(NSDictionary *result) {
        if (![result[@"success"] boolValue]) { completion(result); return; }
        self.busy = YES;
        [self selectSession:result attempts:20 completion:^(NSDictionary *response) {
            self.busy = NO;
            completion(response);
        }];
    }];
}

- (void)selectSession:(NSDictionary *)result attempts:(NSUInteger)attempts completion:(void (^)(NSDictionary *))completion {
    // Идентификатор процесса исключает выбор одноимённого приложения на другом устройстве.
    [[[LKAppsManager sharedInstance] fetchAppInfosWithImage:NO localInfos:nil] subscribeNext:^(NSArray<LKInspectableApp *> *apps) {
        LKInspectableApp *match;
        for (LKInspectableApp *app in apps) {
            if ([app.appInfo.deviceConnectionToken isEqual:result[@"session"]] && [app.appInfo.appBundleIdentifier isEqual:result[@"bundleID"]]) { match = app; break; }
        }
        if (match) {
            [[match fetchHierarchyData] subscribeNext:^(LookinHierarchyInfo *info) {
                if (!info) { completion(@{@"success": @NO, @"error": @"The device returned an empty hierarchy."}); return; }
                LKAppsManager.sharedInstance.inspectingApp = match;
                [LKStaticHierarchyDataSource.sharedInstance reloadWithHierarchyInfo:info keepState:NO];
                [LKNavigationManager.sharedInstance showStaticWorkspace];
                [LKNavigationManager.sharedInstance closeLaunch];
                completion(result);
            } error:^(NSError *error) { completion(@{@"success": @NO, @"error": error.localizedDescription}); }];
        } else if (attempts > 1) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [self selectSession:result attempts:attempts - 1 completion:completion];
            });
        } else completion(@{@"success": @NO, @"error": @"The server loaded, but its connection did not appear. Keep the app running in the foreground and resume Xcode if it is paused.", @"log": result[@"log"] ?: @""});
    } error:^(NSError *error) { completion(@{@"success": @NO, @"error": error.localizedDescription}); }];
}
@end
