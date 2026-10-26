#import <Foundation/Foundation.h>
#import <ReactiveObjC/ReactiveObjC.h>
#include <netinet/in.h>
static NSString *Lookin_PTUSBHubErrorDomain = @"usb";
enum { PTUSBHubErrorConnectionRefused = 1 };
@interface NSArray (Discovery)
- (NSArray *)lookin_map:(id (^)(NSUInteger, id))block;
- (NSArray *)lookin_filter:(BOOL (^)(id))block;
- (id)lookin_firstFiltered:(BOOL (^)(id))block;
@end
@implementation NSArray (Discovery)
- (NSArray *)lookin_map:(id (^)(NSUInteger, id))block { NSMutableArray *r = [NSMutableArray new]; [self enumerateObjectsUsingBlock:^(id value, NSUInteger i, BOOL *stop) { id v = block(i, value); if (v) [r addObject:v]; }]; return r; }
- (NSArray *)lookin_filter:(BOOL (^)(id))block { NSMutableArray *r = [NSMutableArray new]; for (id v in self) if (block(v)) [r addObject:v]; return r; }
- (id)lookin_firstFiltered:(BOOL (^)(id))block { for (id v in self) if (block(v)) return v; return nil; }
@end
@interface Lookin_PTAddress : NSObject @end
@implementation Lookin_PTAddress @end
@interface Lookin_PTUSBHub : NSObject
+ (instancetype)sharedHub;
@end
@implementation Lookin_PTUSBHub
+ (instancetype)sharedHub { return nil; }
@end
@interface Lookin_PTChannel : NSObject
@property BOOL isConnected, closed;
@property(copy) dispatch_block_t late;
@property(strong) RACSignal *probeReply;
+ (instancetype)channelWithDelegate:(id)delegate;
- (void)connectToPort:(int)port IPv4Address:(in_addr_t)address callback:(void (^)(NSError *, Lookin_PTAddress *))callback;
- (void)connectToPort:(int)port overUSBHub:(id)hub deviceID:(NSNumber *)device callback:(void (^)(NSError *))callback;
- (void)close;
@end
static NSMutableArray<Lookin_PTChannel *> *created;
static BOOL hangTCP, hangUSB;
@implementation Lookin_PTChannel
+ (instancetype)channelWithDelegate:(id)delegate { Lookin_PTChannel *c = [self new]; [created addObject:c]; return c; }
- (void)connectToPort:(int)port IPv4Address:(in_addr_t)address callback:(void (^)(NSError *, Lookin_PTAddress *))callback {
    dispatch_block_t reply = ^{ self.isConnected = YES; callback(nil, nil); };
    if (hangTCP) self.late = reply; else reply();
}
- (void)connectToPort:(int)port overUSBHub:(id)hub deviceID:(NSNumber *)device callback:(void (^)(NSError *))callback {
    dispatch_block_t reply = ^{ self.isConnected = YES; callback(nil); };
    if (hangUSB) self.late = reply; else reply();
}
- (void)close { self.closed = YES; self.isConnected = NO; }
@end
@interface LKSimulatorConnectionPort : NSObject
@property int portNumber;
@property(strong) Lookin_PTChannel *connectedChannel;
@end
@implementation LKSimulatorConnectionPort @end
@interface LKUSBConnectionPort : LKSimulatorConnectionPort
@property(strong) NSNumber *deviceID;
@end
@implementation LKUSBConnectionPort @end
@interface LKConnectionManager : NSObject
@property(strong) RACSignal *discoverySignal;
@property(copy) NSArray *allSimulatorPorts, *allUSBPorts;
- (RACSignal *)_tryToConnectAllSimulatorPorts;
- (RACSignal *)_tryToConnectAllUSBDevices;
- (RACSignal *)_connectToSimulatorPort:(LKSimulatorConnectionPort *)port;
- (RACSignal *)_connectToUSBPort:(LKUSBConnectionPort *)port;
@end
@implementation LKConnectionManager
#include "Discovery.inc"
@end
@interface LookinAppInfo : NSObject
@property(copy) NSString *appBundleIdentifier;
@property NSTimeInterval cachedTimestamp;
@property NSInteger appInfoIdentifier;
@property BOOL shouldUseCache;
@property(strong) id appIcon;
@end
@implementation LookinAppInfo @end
@interface LKInspectableApp : NSObject
@property(strong) LookinAppInfo *appInfo;
@property(strong) NSError *serverVersionError;
@property(weak) Lookin_PTChannel *channel;
@end
@implementation LKInspectableApp @end
@interface LKAppsManager : NSObject
@property NSUInteger attempts;
@property(copy) NSString *failure;
+ (instancetype)sharedInstance;
- (RACSignal *)fetchAppInfosWithImage:(BOOL)images localInfos:(NSArray *)infos;
@end
@implementation LKAppsManager
+ (instancetype)sharedInstance { static id m; if (!m) m = [self new]; return m; }
- (RACSignal *)fetchAppInfosWithImage:(BOOL)images localInfos:(NSArray *)infos {
    if (++self.attempts == 1) {
        if ([self.failure isEqual:@"never"]) return RACSignal.never;
        if ([self.failure isEqual:@"empty"]) return RACSignal.empty;
        return [RACSignal error:[NSError errorWithDomain:@"fixture" code:1 userInfo:nil]];
    }
    LKInspectableApp *app = [LKInspectableApp new]; app.appInfo = [LookinAppInfo new];
    app.appInfo.appBundleIdentifier = @"local.fixture";
    return [RACSignal return:@[app]];
}
@end
@interface LKSimulatorAutoConnect : NSObject
@property(copy) NSDictionary *rememberedApps;
+ (instancetype)sharedInstance;
@end
@implementation LKSimulatorAutoConnect
+ (instancetype)sharedInstance { static id m; if (!m) m = [self new]; return m; }
@end
@interface TestProgress : NSObject
@property double progress;
- (void)finishWithCompletion:(dispatch_block_t)completion;
@end
@implementation TestProgress
- (void)finishWithCompletion:(dispatch_block_t)completion { self.progress = 0; }
@end
@interface LKLaunchViewController : NSObject
@property BOOL isEnteringApp, isSearching;
@property(copy) NSArray *appInfos;
@property(strong) TestProgress *bottomIndicatorView;
- (void)_renderWithApps:(NSArray *)apps;
- (void)_enterApp:(LKInspectableApp *)app;
@end
@implementation LKLaunchViewController
#include "DiscoveryLoop.inc"
- (void)_renderWithApps:(NSArray *)apps {}
- (void)_enterApp:(LKInspectableApp *)app { self.isEnteringApp = YES; }
@end
static NSString *LookinErrorDomain = @"Lookin";
enum { LookinErrCode_ServerVersionTooHigh = 10, LookinErrCode_ServerVersionTooLow = 11, LookinErrCode_Discard = 12, LookinRequestTypeApp = 1 };
@interface LookinConnectionResponseAttachment : NSObject
@property(strong) id data;
@property(strong) NSError *error;
@end
@implementation LookinConnectionResponseAttachment @end
@interface ProbeConnectionManager : NSObject
@property(copy) NSArray *channels;
+ (instancetype)sharedInstance;
- (RACSignal *)tryToConnectAllPorts;
- (RACSignal *)requestWithType:(unsigned int)type data:(id)data channel:(Lookin_PTChannel *)channel;
@end
@implementation ProbeConnectionManager
+ (instancetype)sharedInstance { static id m; if (!m) m = [self new]; return m; }
- (RACSignal *)tryToConnectAllPorts { return [RACSignal return:self.channels]; }
- (RACSignal *)requestWithType:(unsigned int)type data:(id)data channel:(Lookin_PTChannel *)channel { return channel.probeReply; }
@end
@interface ProbeAppsManager : NSObject @end
@implementation ProbeAppsManager
#define LKConnectionManager ProbeConnectionManager
#include "AppInfoProbe.inc"
#undef LKConnectionManager
@end
static NSArray *Probe(ProbeAppsManager *manager) {
    __block NSArray *result;
    [[manager fetchAppInfosWithImage:NO localInfos:nil] subscribeNext:^(NSArray *value) { result = value; }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!result && deadline.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return result;
}
static NSArray *Discover(LKConnectionManager *manager) {
    __block NSArray *result;
    [[manager tryToConnectAllPorts] subscribeNext:^(NSArray *value) { result = value; }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!result && deadline.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return result;
}
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d\n",__LINE__); return 1; } } while (0)
int main(void) { @autoreleasepool {
    created = [NSMutableArray new];
    {
        hangTCP = YES; hangUSB = NO;
        LKConnectionManager *manager = [LKConnectionManager new];
        manager.allSimulatorPorts = @[[LKSimulatorConnectionPort new]];
        manager.allUSBPorts = @[[LKUSBConnectionPort new]];
        __block NSUInteger results = 0;
        [[manager tryToConnectAllPorts] subscribeNext:^(NSArray *value) { results++; }];
        [[manager tryToConnectAllPorts] subscribeNext:^(NSArray *value) { results++; }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
        while (results < 2 && deadline.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        CHECK(results == 2 && created.count == 2);
        for (Lookin_PTChannel *channel in created) channel.late = nil;
        [created removeAllObjects];
    }
    for (NSNumber *tcp in @[@NO, @YES]) {
        hangTCP = tcp.boolValue; hangUSB = !hangTCP;
        LKConnectionManager *manager = [LKConnectionManager new];
        LKSimulatorConnectionPort *simulator = [LKSimulatorConnectionPort new];
        LKUSBConnectionPort *usb = [LKUSBConnectionPort new];
        manager.allSimulatorPorts = @[simulator]; manager.allUSBPorts = @[usb];
        NSArray *result = Discover(manager); CHECK(result && result.count == 1);
        for (Lookin_PTChannel *channel in created.copy) {
            if (channel.late) { CHECK(channel.closed); dispatch_block_t reply = channel.late; channel.late = nil; reply(); CHECK(channel.closed && !channel.isConnected); }
        }
        CHECK(hangTCP ? !simulator.connectedChannel : !usb.connectedChannel);
        hangTCP = NO; hangUSB = NO;
        result = Discover(manager); CHECK(result.count == 2);
        CHECK(simulator.connectedChannel.isConnected && usb.connectedChannel.isConnected);
        simulator.connectedChannel.isConnected = NO;
        Lookin_PTChannel *stale = simulator.connectedChannel;
        result = Discover(manager); CHECK(result.count == 2 && simulator.connectedChannel != stale);
        [created removeAllObjects];
    }
    LKSimulatorAutoConnect.sharedInstance.rememberedApps = @{@"local.fixture": @"Fixture"};
    for (NSString *failure in @[@"never", @"error", @"empty"]) {
        LKAppsManager.sharedInstance.attempts = 0; LKAppsManager.sharedInstance.failure = failure;
        LKLaunchViewController *launch = [LKLaunchViewController new];
        [launch _reloadWithAutoEntering:YES];
        [launch _reloadWithAutoEntering:YES];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:11];
        while (!launch.isEnteringApp && deadline.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        CHECK(launch.isEnteringApp && !launch.isSearching && LKAppsManager.sharedInstance.attempts == 2);
    }
    puts("PASS: hung USB/TCP, late callbacks, recovery and stale channels");
    puts("PASS: discovery retries after timeout, error and empty completion");
    ProbeAppsManager *apps = [ProbeAppsManager new];
    Lookin_PTChannel *background = [Lookin_PTChannel new]; background.isConnected = YES;
    ProbeConnectionManager.sharedInstance.channels = @[background];
    background.probeReply = [RACSignal error:[NSError errorWithDomain:LookinErrorDomain code:99 userInfo:nil]];
    CHECK(Probe(apps).count == 0 && background.closed);
    background.closed = NO; background.isConnected = YES;
    background.probeReply = [RACSignal error:[NSError errorWithDomain:LookinErrorDomain code:LookinErrCode_Discard userInfo:nil]];
    CHECK(Probe(apps).count == 0 && !background.closed);
    background.probeReply = [RACSignal error:[NSError errorWithDomain:LookinErrorDomain code:LookinErrCode_ServerVersionTooHigh userInfo:nil]];
    CHECK(Probe(apps).count == 1 && !background.closed);
    Lookin_PTChannel *healthy = [Lookin_PTChannel new]; healthy.isConnected = YES;
    LookinConnectionResponseAttachment *reply = [LookinConnectionResponseAttachment new]; reply.data = [LookinAppInfo new];
    healthy.probeReply = [RACSignal return:[RACTuple tupleWithObjects:reply, healthy, nil]];
    background.probeReply = RACSignal.never;
    ProbeConnectionManager.sharedInstance.channels = @[background, healthy];
    CHECK(Probe(apps).count == 1 && background.closed && !healthy.closed);
    puts("PASS: stale/background AppInfo is evicted; concurrent/version probes preserve healthy connections");
} return 0; }
