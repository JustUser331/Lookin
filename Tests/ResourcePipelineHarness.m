#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <LookinShared/LookinShared-umbrella.h>
#import "LKConnectionRequest.h"
#import <objc/runtime.h>
#import <stdatomic.h>

static NSUInteger checks;
#define CHECK(value,message) do { checks++; if (!(value)) { fprintf(stderr,"FAIL: %s\n",message); exit(1); } } while(0)
@interface Lookin_PTChannel (TestingResources)
@property(strong) NSMutableSet *activeRequests;
@end
@implementation Lookin_PTChannel (TestingResources)
- (void)setActiveRequests:(NSMutableSet *)value { objc_setAssociatedObject(self,@selector(activeRequests),value,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSMutableSet *)activeRequests { return objc_getAssociatedObject(self,@selector(activeRequests)); }
@end
@interface TestResourceChannel : Lookin_PTChannel
@property BOOL testConnected;
@end
@implementation TestResourceChannel
- (BOOL)isConnected { return self.testConnected; }
@end
#include "ResourceResponseClass.inc"
@interface LKConnectionManager : NSObject
@property(strong) dispatch_queue_t resourceDecodeQueue;
@property(strong) NSMutableArray<LKQueuedResourceResponse *> *resourceResponses;
@property NSUInteger queuedResourceBytes;
@property BOOL resourceDrainScheduled;
@end
@implementation LKConnectionManager
#include "ResourcePipelineMethods.inc"
@end
static BOOL spinUntil(BOOL (^condition)(void)) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:3];
    while (!condition() && end.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    return condition();
}
static NSData *packet(LookinResourceCodec *codec, NSUInteger start, NSUInteger count, NSUInteger total) {
    NSMutableArray *details=[NSMutableArray array];
    for (NSUInteger i=0;i<count;i++) { LookinDisplayItemDetail *d=[LookinDisplayItemDetail new]; d.displayItemOid=start+i; d.providedFields=@[@"attributes"]; d.attributesGroupList=@[]; [details addObject:d]; }
    LookinConnectionResponseAttachment *r=[LookinConnectionResponseAttachment new]; r.data=details; r.dataTotalCount=total; r.currentDataCount=count;
    return [codec encodeResponse:r requestIdentity:@"test" error:nil];
}
int main(void) { @autoreleasepool {
    LKConnectionManager *manager=[LKConnectionManager new]; manager.resourceDecodeQueue=dispatch_queue_create("test.decode",DISPATCH_QUEUE_SERIAL); manager.resourceResponses=[NSMutableArray array];
    TestResourceChannel *channel=[TestResourceChannel new]; channel.testConnected=YES; channel.activeRequests=[NSMutableSet set];
    LookinResourceCodec *codec=[LookinResourceCodec new];
    NSData *one=packet(codec,1,12,24), *two=packet(codec,13,12,24);
    LKConnectionRequest *request=[LKConnectionRequest new]; request.timeoutInterval=0.01;
    __block NSUInteger localTimeouts=0; request.timeoutBlock=^(LKConnectionRequest *r){localTimeouts++;};
    NSMutableArray *oids=[NSMutableArray array]; __block NSUInteger complete=0, failures=0, chunks=0;
    request.succBlock=^(LookinConnectionResponseAttachment *r) { CHECK(NSThread.isMainThread,"models apply on main"); CHECK([(NSArray *)r.data count]<=4,"apply has bounded slices"); chunks++; for (LookinDisplayItemDetail *d in (NSArray *)r.data) [oids addObject:@(d.displayItemOid)]; };
    request.completionBlock=^{complete++;}; request.failBlock=^(NSError *error){failures++;};
    [channel.activeRequests addObject:request];
    dispatch_semaphore_t gate=dispatch_semaphore_create(0);
    dispatch_async(manager.resourceDecodeQueue,^{dispatch_semaphore_wait(gate,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC));});
    [manager enqueueResourceData:one request:request channel:channel]; [manager enqueueResourceData:two request:request channel:channel];
    __block BOOL heartbeat=NO; dispatch_async(dispatch_get_main_queue(),^{heartbeat=YES;});
    CHECK(spinUntil(^BOOL{return heartbeat;}),"main remains responsive while decode queue is blocked"); CHECK(oids.count==0,"decode has not applied early");
    NSDate *delay=[NSDate dateWithTimeIntervalSinceNow:0.04]; while(delay.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    CHECK(localTimeouts==0,"wire timeout is paused during local decode");
    dispatch_semaphore_signal(gate);
    CHECK(spinUntil(^BOOL{return complete==1;}),"multi-frame request completes after all slices");
    CHECK(failures==0 && chunks==6 && oids.count==24,"all details are applied exactly once");
    for (NSUInteger i=0;i<24;i++) CHECK([oids[i] unsignedIntegerValue]==i+1,"packet ordering is preserved");
    CHECK(manager.queuedResourceBytes==0 && manager.resourceResponses.count==0,"input reservation released after apply");

    LKConnectionRequest *cancelled=[LKConnectionRequest new]; cancelled.timeoutInterval=5; __block BOOL stale=NO;
    cancelled.succBlock=^(id r){stale=YES;}; [channel.activeRequests addObject:cancelled];
    gate=dispatch_semaphore_create(0); dispatch_async(manager.resourceDecodeQueue,^{dispatch_semaphore_wait(gate,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC));});
    [manager enqueueResourceData:one request:cancelled channel:channel]; cancelled.resourceCancelled=YES; [channel.activeRequests removeObject:cancelled]; [cancelled endTimeoutCount]; dispatch_semaphore_signal(gate);
    CHECK(spinUntil(^BOOL{return manager.queuedResourceBytes==0;}) && !stale,"cancelled generation is not applied and releases budget");

    LKConnectionRequest *broken=[LKConnectionRequest new]; broken.timeoutInterval=5; __block NSInteger errorCode=0;
    broken.failBlock=^(NSError *error){errorCode=error.code;}; [channel.activeRequests addObject:broken];
    [manager enqueueResourceData:[@"malformed" dataUsingEncoding:NSUTF8StringEncoding] request:broken channel:channel];
    CHECK(spinUntil(^BOOL{return errorCode!=0;}) && manager.queuedResourceBytes==0,"invalid packet terminates with error and cleanup");

    broken=[LKConnectionRequest new]; broken.timeoutInterval=5; errorCode=0; broken.failBlock=^(NSError *error){errorCode=error.code;}; [channel.activeRequests addObject:broken];
    manager.queuedResourceBytes=64*1024*1024;
    [manager enqueueResourceData:one request:broken channel:channel]; CHECK(errorCode==413,"backlog obeys encoded-byte budget"); manager.queuedResourceBytes=0;
    printf("PASS: %lu resource pipeline assertions\n",checks); return 0;
}}
