#import "LKSimulatorAutoConnect.h"
#include <sys/file.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

NSNotificationName const LKSimulatorAutoConnectDidChangeNotification = @"LKSimulatorAutoConnectDidChange";
NSString *const LKSimulatorAutoConnectDefaultsKey = @"SimulatorAutoConnectApps";

@implementation LKSimulatorCommandResult
@end

static LKSimulatorCommandResult *RunSimctl(NSArray<NSString *> *arguments) {
    LKSimulatorCommandResult *result = [LKSimulatorCommandResult new];
    result.status = -1;
    result.output = @"";
    result.error = @"";
    FILE *output = tmpfile(), *errors = tmpfile();
    if (!output || !errors) {
        if (output) fclose(output);
        if (errors) fclose(errors);
        result.error = @"Unable to create simulator command output.";
        return result;
    }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = [@[@"simctl"] arrayByAddingObjectsFromArray:arguments];
    NSMutableDictionary *environment = NSProcessInfo.processInfo.environment.mutableCopy;
    for (NSString *key in environment.allKeys) {
        if ([key hasPrefix:@"SIMCTL_CHILD_"] || [key hasPrefix:@"DYLD_"]) [environment removeObjectForKey:key];
    }
    task.environment = environment;
    task.standardOutput = [[NSFileHandle alloc] initWithFileDescriptor:fileno(output) closeOnDealloc:NO];
    task.standardError = [[NSFileHandle alloc] initWithFileDescriptor:fileno(errors) closeOnDealloc:NO];
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *process) { dispatch_semaphore_signal(finished); };
    NSError *error = nil;
    if ([task launchAndReturnError:&error]) {
        if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
            [task terminate];
            if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4))) {
                kill(task.processIdentifier, SIGKILL);
                dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
            }
            result.error = @"Simulator command timed out.";
        } else {
            result.status = task.terminationStatus;
        }
    } else {
        result.error = error.localizedDescription;
    }
    [task.standardOutput seekToFileOffset:0];
    [task.standardError seekToFileOffset:0];
    result.output = [[NSString alloc] initWithData:[task.standardOutput readDataToEndOfFile] encoding:NSUTF8StringEncoding] ?: @"";
    NSString *stderrText = [[NSString alloc] initWithData:[task.standardError readDataToEndOfFile] encoding:NSUTF8StringEncoding];
    if (!result.error.length) result.error = stderrText ?: @"";
    fclose(output);
    fclose(errors);
    return result;
}

@interface LKSimulatorAutoConnect () {
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    int _ownerFD;
    BOOL _started;
    BOOL _ownsConfiguration;
    NSTimeInterval _lastCatalogRefresh;
    NSData *_lastConfiguration;
}
@property(nonatomic, strong) NSUserDefaults *defaults;
@property(nonatomic, copy) NSString *directory;
@property(nonatomic, copy) NSString *loaderSource;
@property(nonatomic, copy) NSString *serverPath;
@property(nonatomic, copy) LKSimulatorCommandRunner runner;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *selection;
@property(nonatomic, copy) NSArray<NSDictionary *> *devices;
@property(nonatomic, copy) NSArray<NSDictionary *> *catalog;
@property(atomic) BOOL stopping;
@property(atomic, copy, readwrite) NSDictionary<NSString *, NSString *> *rememberedApps;
@property(atomic, copy, readwrite) NSArray<NSDictionary *> *availableApps;
@property(atomic, copy, readwrite) NSString *statusText;
@end

@implementation LKSimulatorAutoConnect

+ (instancetype)sharedInstance {
    static LKSimulatorAutoConnect *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *bundle = NSBundle.mainBundle;
        NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        NSString *directory = [[support stringByAppendingPathComponent:bundle.bundleIdentifier ?: @"Lookin"] stringByAppendingPathComponent:@"SimulatorAutoConnect"];
        instance = [[self alloc] initWithDefaults:NSUserDefaults.standardUserDefaults directory:directory
                                    loaderSource:[bundle.resourcePath stringByAppendingPathComponent:@"LookinSimulatorLoader.dylib"]
                                      serverPath:[bundle.resourcePath stringByAppendingPathComponent:@"LookinServer.framework/LookinServer"]
                                          runner:^LKSimulatorCommandResult *(NSArray *arguments) { return RunSimctl(arguments); }];
    });
    return instance;
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults directory:(NSString *)directory
                    loaderSource:(NSString *)loaderSource serverPath:(NSString *)serverPath
                          runner:(LKSimulatorCommandRunner)runner {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("work.lookin.simulator-autoconnect", DISPATCH_QUEUE_SERIAL);
        _ownerFD = -1;
        _defaults = defaults;
        _directory = directory;
        _loaderSource = loaderSource;
        _serverPath = serverPath;
        _runner = [runner copy];
        _selection = [NSMutableDictionary dictionary];
        NSDictionary *saved = [defaults dictionaryForKey:LKSimulatorAutoConnectDefaultsKey];
        for (NSString *bundleID in saved) {
            if ([self.class isValidBundleID:bundleID] && [saved[bundleID] isKindOfClass:NSString.class]) _selection[bundleID] = saved[bundleID];
        }
        _rememberedApps = _selection.copy;
        _catalog = @[];
        _availableApps = @[];
        _devices = @[];
        _statusText = NSLocalizedString(@"Checking simulators…", nil);
    }
    return self;
}

+ (BOOL)isValidBundleID:(NSString *)bundleID {
    if (![bundleID isKindOfClass:NSString.class] || !bundleID.length || bundleID.length > 255) return NO;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"] invertedSet];
    return [bundleID rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

+ (NSString *)environment:(NSString *)environment removingLoader:(NSString *)loader {
    NSMutableArray *paths = [[environment componentsSeparatedByString:@":"] mutableCopy];
    [paths removeObject:loader];
    return [paths componentsJoinedByString:@":"];
}

+ (NSString *)environment:(NSString *)environment addingLoader:(NSString *)loader {
    NSString *other = [self environment:environment removingLoader:loader];
    return other.length ? [other stringByAppendingFormat:@":%@", loader] : loader;
}

- (NSString *)loaderPath { return [self.directory stringByAppendingPathComponent:@"loader.dylib"]; }

- (void)publish:(NSString *)status {
    NSDictionary *selection = self.selection.copy;
    NSArray *catalog = self.catalog.copy;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.rememberedApps isEqualToDictionary:selection] &&
            [self.availableApps isEqualToArray:catalog] && [self.statusText isEqualToString:status]) return;
        self.rememberedApps = selection;
        self.availableApps = catalog;
        self.statusText = status;
        [[NSNotificationCenter defaultCenter] postNotificationName:LKSimulatorAutoConnectDidChangeNotification object:self];
    });
}

- (BOOL)writeConfigurationEnabled:(BOOL)enabled error:(NSError **)error {
    NSDictionary *config = @{@"enabled": @(enabled), @"bundleIDs": [self.selection.allKeys sortedArrayUsingSelector:@selector(compare:)],
                             @"serverPath": self.serverPath};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:config format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (data && [_lastConfiguration isEqual:data]) return YES;
    BOOL written = data && [data writeToFile:[self.directory stringByAppendingPathComponent:@"config.plist"] options:NSDataWritingAtomic error:error];
    if (written) _lastConfiguration = data;
    return written;
}

- (BOOL)prepare:(NSError **)error {
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
    _ownerFD = open([[self.directory stringByAppendingPathComponent:@"owner.lock"] fileSystemRepresentation], O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (_ownerFD < 0 || flock(_ownerFD, LOCK_EX | LOCK_NB)) {
        if (_ownerFD >= 0) close(_ownerFD);
        _ownerFD = -1;
        *error = [NSError errorWithDomain:@"LookinSimulatorAutoConnect" code:1 userInfo:@{NSLocalizedDescriptionKey:NSLocalizedString(@"Another Lookin instance is managing simulator auto-connect.", nil)}];
        return NO;
    }
    _ownsConfiguration = YES;
    if (![self writeConfigurationEnabled:NO error:error]) return NO;
    NSData *loader = [NSData dataWithContentsOfFile:self.loaderSource options:0 error:error];
    if (!loader || ![files fileExistsAtPath:self.serverPath]) {
        if (!*error) *error = [NSError errorWithDomain:@"LookinSimulatorAutoConnect" code:2 userInfo:@{NSLocalizedDescriptionKey:NSLocalizedString(@"This Lookin build is missing the Simulator server or loader.", nil)}];
        return NO;
    }
    NSData *existing = [NSData dataWithContentsOfFile:self.loaderPath];
    if (![existing isEqual:loader] && ![loader writeToFile:self.loaderPath options:NSDataWritingAtomic error:error]) return NO;
    return YES;
}

- (void)start {
    dispatch_async(_queue, ^{
        if (self->_started || self.stopping) return;
        self->_started = YES;
        NSError *error = nil;
        if (![self prepare:&error]) {
            if (self->_ownerFD >= 0) { close(self->_ownerFD); self->_ownerFD = -1; }
            self->_ownsConfiguration = NO;
            [self publish:error.localizedDescription ?: NSLocalizedString(@"Unable to prepare simulator auto-connect.", nil)];
            return;
        }
        self->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
        dispatch_source_set_timer(self->_timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(self->_timer, ^{ [weakSelf reconcile:NO]; });
        dispatch_resume(self->_timer);
    });
}

- (void)refresh {
    dispatch_async(_queue, ^{ if (!self.stopping && self->_ownerFD >= 0) [self reconcile:YES]; });
}

- (void)setBundleID:(NSString *)bundleID name:(NSString *)name enabled:(BOOL)enabled {
    if (![self.class isValidBundleID:bundleID] || self.stopping) return;
    dispatch_async(_queue, ^{
        if (enabled) self.selection[bundleID] = name.length ? name : bundleID;
        else [self.selection removeObjectForKey:bundleID];
        [self.defaults setObject:self.selection.copy forKey:LKSimulatorAutoConnectDefaultsKey];
        if (self->_ownerFD >= 0 && !self.stopping) [self reconcile:YES];
        else [self publish:self.statusText];
    });
}

- (NSArray<NSDictionary *> *)bootedDevices:(NSString **)failure {
    LKSimulatorCommandResult *result = self.runner(@[@"list", @"devices", @"booted", @"--json"]);
    NSDictionary *json = result.status == 0 ? [NSJSONSerialization JSONObjectWithData:[result.output dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
    if (![json isKindOfClass:NSDictionary.class] || ![json[@"devices"] isKindOfClass:NSDictionary.class]) {
        *failure = result.error.length ? result.error : NSLocalizedString(@"Unable to list simulators. Check the selected Xcode installation.", nil);
        return nil;
    }
    NSMutableArray *devices = [NSMutableArray array];
    for (NSString *runtime in json[@"devices"]) {
        if (![runtime hasPrefix:@"com.apple.CoreSimulator.SimRuntime.iOS-"]) continue;
        for (NSDictionary *device in json[@"devices"][runtime]) {
            if ([device[@"state"] isEqual:@"Booted"] && [device[@"udid"] isKindOfClass:NSString.class]) [devices addObject:device];
        }
    }
    return devices;
}

- (BOOL)setEnvironmentOnDevice:(NSString *)udid enabled:(BOOL)enabled failure:(NSString **)failure {
    LKSimulatorCommandResult *read = self.runner(@[@"spawn", udid, @"launchctl", @"getenv", @"DYLD_INSERT_LIBRARIES"]);
    if (read.status != 0) { *failure = read.error.length ? read.error : NSLocalizedString(@"Unable to read the Simulator launch environment.", nil); return NO; }
    NSString *current = [read.output stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSString *updated = enabled ? [self.class environment:current addingLoader:self.loaderPath] : [self.class environment:current removingLoader:self.loaderPath];
    if ([updated isEqualToString:current]) return YES;
    if (enabled) {
        // Booted появляется раньше готовности SpringBoard и миграций первого запуска.
        LKSimulatorCommandResult *boot = self.runner(@[@"bootstatus", udid]);
        if (boot.status != 0) { *failure = NSLocalizedString(@"Waiting for the Simulator to finish starting…", nil); return NO; }
        if (self.stopping) return NO;
    }
    NSArray *arguments = updated.length ? @[@"spawn", udid, @"launchctl", @"setenv", @"DYLD_INSERT_LIBRARIES", updated] : @[@"spawn", udid, @"launchctl", @"unsetenv", @"DYLD_INSERT_LIBRARIES"];
    LKSimulatorCommandResult *write = self.runner(arguments);
    if (write.status != 0) { *failure = write.error.length ? write.error : NSLocalizedString(@"Unable to update the Simulator launch environment.", nil); return NO; }
    return YES;
}

- (void)refreshCatalog {
    NSMutableDictionary *apps = [NSMutableDictionary dictionary];
    for (NSDictionary *device in self.devices) {
        if (self.stopping) break;
        LKSimulatorCommandResult *result = self.runner(@[@"listapps", device[@"udid"]]);
        NSDictionary *installed = result.status == 0 ? [NSPropertyListSerialization propertyListWithData:[result.output dataUsingEncoding:NSUTF8StringEncoding] options:NSPropertyListImmutable format:nil error:nil] : nil;
        if (![installed isKindOfClass:NSDictionary.class]) continue;
        for (NSString *key in installed) {
            NSDictionary *info = installed[key];
            if (![info isKindOfClass:NSDictionary.class] || ![info[@"ApplicationType"] isEqual:@"User"]) continue;
            NSString *bundleID = info[@"CFBundleIdentifier"] ?: key;
            if (![self.class isValidBundleID:bundleID]) continue;
            NSMutableDictionary *entry = apps[bundleID];
            if (!entry) {
                NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: bundleID;
                entry = [@{@"bundleID": bundleID, @"name": name, @"simulators": [NSMutableArray array]} mutableCopy];
                apps[bundleID] = entry;
            }
            [entry[@"simulators"] addObject:device[@"name"] ?: device[@"udid"]];
        }
    }
    self.catalog = [apps.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"bundleID"] compare:right[@"bundleID"]];
    }];
    _lastCatalogRefresh = NSDate.date.timeIntervalSince1970;
}

- (void)reconcile:(BOOL)forceCatalog {
    if (self.stopping) return;
    NSError *error = nil;
    if (![self writeConfigurationEnabled:self.selection.count > 0 error:&error]) {
        // При ошибке записи блокировка снимается: старое разрешение больше не действует.
        close(_ownerFD); _ownerFD = -1;
        _ownsConfiguration = NO;
        if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
        [self publish:error.localizedDescription];
        return;
    }
    NSString *failure = nil;
    NSArray *devices = [self bootedDevices:&failure];
    if (!devices) { [self publish:failure]; return; }
    BOOL devicesChanged = ![self.devices isEqualToArray:devices];
    self.devices = devices;
    NSUInteger ready = 0;
    for (NSDictionary *device in devices) {
        if (self.stopping) break;
        if ([self setEnvironmentOnDevice:device[@"udid"] enabled:self.selection.count > 0 failure:&failure]) ready++;
    }
    if (forceCatalog || (self.catalogVisible && (devicesChanged || NSDate.date.timeIntervalSince1970 - _lastCatalogRefresh > 10))) [self refreshCatalog];
    NSString *status = failure.length ? failure : (self.selection.count ?
        [NSString stringWithFormat:NSLocalizedString(@"Ready on %lu simulators. Open or restart a selected app to connect.", nil), (unsigned long)ready] :
        NSLocalizedString(@"Select apps to auto-connect on every Simulator while Lookin is open.", nil));
    [self publish:status];
}

- (void)stopWithCompletion:(void (^)(void))completion {
    self.stopping = YES;
    dispatch_async(_queue, ^{
        if (self->_timer) { dispatch_source_cancel(self->_timer); self->_timer = nil; }
        if (self->_ownsConfiguration) {
            [self writeConfigurationEnabled:NO error:nil];
            NSString *failure = nil;
            NSArray *devices = [self bootedDevices:&failure] ?: self.devices;
            NSTimeInterval deadline = NSDate.date.timeIntervalSince1970 + 5;
            for (NSDictionary *device in devices) {
                if (NSDate.date.timeIntervalSince1970 > deadline) break;
                [self setEnvironmentOnDevice:device[@"udid"] enabled:NO failure:&failure];
            }
            if (self->_ownerFD >= 0) { close(self->_ownerFD); self->_ownerFD = -1; }
            self->_ownsConfiguration = NO;
        }
        dispatch_async(dispatch_get_main_queue(), completion);
    });
}

- (void)dealloc {
    if (_timer) dispatch_source_cancel(_timer);
    if (_ownerFD >= 0) close(_ownerFD);
}
@end
