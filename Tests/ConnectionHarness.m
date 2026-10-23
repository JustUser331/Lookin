// Deterministic tests for the actual request/cancellation methods. No sockets/UI.
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#define weakify(x) try {} @finally {} __weak __typeof__(x) x##_weak_ = x
#define strongify(x) try {} @finally {} __strong __typeof__(x##_weak_) x = x##_weak_
static const unsigned int LookinRequestTypeApp=1, LookinRequestTypePing=2, LookinRequestTypeHierarchyDetails=3, LookinRequestTypeHierarchy=4, LookinRequestTypeMetadata=5;
static NSString *LookinErrorDomain=@"Lookin", *LookinErrorText_Timeout=@"timeout";
static const NSInteger LookinErrCode_Discard=1, LookinErrCode_Timeout=2, LookinErrCode_PeerTalk=3;
#define LookinErr_Inner [NSError errorWithDomain:LookinErrorDomain code:500 userInfo:nil]
#define LookinErr_NoConnect [NSError errorWithDomain:LookinErrorDomain code:503 userInfo:nil]

@interface RACDisposable : NSObject
@property(getter=isDisposed) BOOL disposed;
@property(copy) dispatch_block_t block;
+ (instancetype)disposableWithBlock:(dispatch_block_t)block;
- (void)dispose;
@end
@implementation RACDisposable
+ (instancetype)disposableWithBlock:(dispatch_block_t)block { RACDisposable *d=[self new]; d.block=block; return d; }
- (void)dispose { if (self.disposed) return; self.disposed=YES; dispatch_block_t block=self.block; self.block=nil; if (block) block(); }
@end
@interface RACCompoundDisposable : RACDisposable
@property(strong) NSMutableArray *children;
+ (instancetype)compoundDisposable;
- (void)addDisposable:(RACDisposable *)d;
@end
@implementation RACCompoundDisposable
+ (instancetype)compoundDisposable { RACCompoundDisposable *d=[self new]; d.children=[NSMutableArray array]; return d; }
- (void)addDisposable:(RACDisposable *)d { if (!d) return; if (self.isDisposed) [d dispose]; else [self.children addObject:d]; }
- (void)dispose { if (self.isDisposed) return; [super dispose]; NSArray *copy=self.children.copy; [self.children removeAllObjects]; for (RACDisposable *d in copy) [d dispose]; }
@end
@protocol RACSubscriber <NSObject>
- (void)sendNext:(id)value;
- (void)sendError:(NSError *)error;
- (void)sendCompleted;
@end
@interface HCSubscriber : NSObject<RACSubscriber>
@property NSUInteger values, errors, completed;
@end
@implementation HCSubscriber
- (void)sendNext:(id)value { self.values++; }
- (void)sendError:(NSError *)error { self.errors++; }
- (void)sendCompleted { self.completed++; }
@end
@interface RACSignal : NSObject
@property(copy) RACDisposable *(^producer)(id<RACSubscriber>);
+ (instancetype)createSignal:(RACDisposable *(^)(id<RACSubscriber>))producer;
@end
@implementation RACSignal
+ (instancetype)createSignal:(RACDisposable *(^)(id<RACSubscriber>))producer { RACSignal *s=[self new]; s.producer=producer; return s; }
@end
@interface RACTuple : NSObject
+ (instancetype)tupleWithObjects:(id)first, ...;
@end
@implementation RACTuple
+ (instancetype)tupleWithObjects:(id)first, ... { return [self new]; }
@end
@interface NSSet (HCFilters)
- (NSSet *)lookin_filter:(BOOL (^)(id))predicate;
- (id)lookin_firstFiltered:(BOOL (^)(id))predicate;
@end
@implementation NSSet (HCFilters)
- (NSSet *)lookin_filter:(BOOL (^)(id))predicate { NSMutableSet *out=[NSMutableSet set]; for (id v in self) if (predicate(v)) [out addObject:v]; return out; }
- (id)lookin_firstFiltered:(BOOL (^)(id))predicate { for (id v in self) if (predicate(v)) return v; return nil; }
@end
@interface NSData (HCDispatch)
- (dispatch_data_t)createReferencingDispatchData;
@end
@implementation NSData (HCDispatch)
- (dispatch_data_t)createReferencingDispatchData { return dispatch_data_empty; }
@end
@interface LookinConnectionAttachment : NSObject<NSSecureCoding>
@property(strong) id data;
@end
@implementation LookinConnectionAttachment
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:self.data forKey:@"data"]; }
- (instancetype)initWithCoder:(NSCoder *)coder { return [super init]; }
@end
@interface LookinConnectionResponseAttachment : NSObject
@property(strong) id data;
@end
@implementation LookinConnectionResponseAttachment
@end
@interface LKConnectionRequest : NSObject
@property(atomic) BOOL resourceCancelled;
@property NSUInteger resourceFramesPending;
@property uint32_t type, tag;
@property(copy) void (^succBlock)(id);
@property(copy) void (^failBlock)(NSError *);
@property(copy) void (^completionBlock)(void);
@property(copy) void (^timeoutBlock)(LKConnectionRequest *);
@property NSTimeInterval timeoutInterval;
@property BOOL timerArmed;
- (void)resetTimeoutCount;
- (void)endTimeoutCount;
@end
@implementation LKConnectionRequest
- (void)resetTimeoutCount { self.timerArmed=YES; }
- (void)endTimeoutCount { self.timerArmed=NO; }
@end
@interface Lookin_PTChannel : NSObject
@property BOOL isConnected;
@property BOOL guardedResourceRequests;
@property(strong) NSMutableSet<LKConnectionRequest *> *activeRequests;
@property(strong) NSMutableArray<NSDictionary *> *writes;
- (void)sendFrameOfType:(uint32_t)type tag:(uint32_t)tag withPayload:(dispatch_data_t)payload callback:(void (^)(NSError *))callback;
- (void)close;
@end
@implementation Lookin_PTChannel
- (instancetype)init { if ((self=[super init])) { _isConnected=YES; _writes=[NSMutableArray array]; } return self; }
- (void)close { self.isConnected=NO; }
- (void)sendFrameOfType:(uint32_t)type tag:(uint32_t)tag withPayload:(dispatch_data_t)payload callback:(void (^)(NSError *))callback { [self.writes addObject:@{@"type":@(type),@"tag":@(tag),@"callback":[callback copy]}]; }
@end
@interface LKSimulatorConnectionPort : NSObject
@property(strong) Lookin_PTChannel *connectedChannel;
@end
@implementation LKSimulatorConnectionPort
@end
@interface LKUSBConnectionPort : LKSimulatorConnectionPort
@end
@implementation LKUSBConnectionPort
@end
@interface LKConnectionManager : NSObject
@property BOOL rejectVersion;
@property(strong) NSArray *allSimulatorPorts, *allUSBPorts;
@property(strong) HCSubscriber *channelWillEnd;
- (NSError *)_checkServerVersionWithResponse:(LookinConnectionResponseAttachment *)response;
@end
@implementation LKConnectionManager
- (NSError *)_checkServerVersionWithResponse:(LookinConnectionResponseAttachment *)response { return self.rejectVersion ? LookinErr_Inner : nil; }
#include "ConnectionMethodsUnderTest.inc"
@end

static NSUInteger tests;
#define CHECK(condition, message) do { tests++; if (!(condition)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,message); exit(1); } } while(0)
static void HCWriteCompleted(Lookin_PTChannel *channel, NSUInteger index) { void (^callback)(NSError *)=channel.writes[index][@"callback"]; callback(nil); }
int main(void) { @autoreleasepool {
    LKConnectionManager *manager=[LKConnectionManager new]; Lookin_PTChannel *channel=[Lookin_PTChannel new]; HCSubscriber *subscriber=[HCSubscriber new];
    RACSignal *signal=[manager requestWithType:LookinRequestTypeHierarchyDetails data:nil channel:channel];
    RACDisposable *first=signal.producer(subscriber);
    CHECK(channel.activeRequests.count==1,"pending send is cancellable before write completion");
    LKConnectionRequest *ping=channel.activeRequests.anyObject;
    void (^latePing)(id)=[ping.succBlock copy];
    [first dispose]; CHECK(channel.activeRequests.count==0,"dispose removes pending ping");
    HCWriteCompleted(channel,0); CHECK(channel.activeRequests.count==0 && !ping.timerArmed,"late write does not resurrect cancelled ping");
    latePing([LookinConnectionResponseAttachment new]); CHECK(channel.writes.count==1,"late ping cannot issue cancelled detail request");

    // Start a replacement before delivering the old ping; it must survive.
    RACDisposable *second=signal.producer(subscriber); LKConnectionRequest *newPing=channel.activeRequests.anyObject;
    HCWriteCompleted(channel,1); newPing.succBlock([LookinConnectionResponseAttachment new]);
    LKConnectionRequest *detail=[channel.activeRequests lookin_firstFiltered:^BOOL(LKConnectionRequest *r) { return r.type==LookinRequestTypeHierarchyDetails; }];
    CHECK(detail!=nil,"live ping starts detail request"); NSUInteger writes=channel.writes.count;
    latePing([LookinConnectionResponseAttachment new]); CHECK(channel.writes.count==writes && [channel.activeRequests containsObject:detail],"old ping cannot discard current detail request");
    [second dispose]; CHECK(channel.activeRequests.count==0,"dispose cancels ping and actual request by identity");
    HCWriteCompleted(channel,2); CHECK(channel.activeRequests.count==0 && !detail.timerArmed,"pending actual write stays cancelled");
    CHECK(subscriber.values==0 && subscriber.errors==0 && subscriber.completed==0,"disposed request sends no events");

    // Public type cancellation also covers pending sends before callbacks run.
    RACDisposable *third=signal.producer(subscriber); ping=channel.activeRequests.anyObject; ping.succBlock([LookinConnectionResponseAttachment new]);
    detail=[channel.activeRequests lookin_firstFiltered:^BOOL(LKConnectionRequest *r) { return r.type==LookinRequestTypeHierarchyDetails; }];
    [manager cancelRequestWithType:LookinRequestTypeHierarchyDetails channel:channel]; CHECK(![channel.activeRequests containsObject:detail],"type cancellation removes pending detail send");
    HCWriteCompleted(channel,channel.writes.count-1); CHECK(![channel.activeRequests containsObject:detail] && !detail.timerArmed,"type-cancelled write does not re-arm timeout"); [third dispose];

    // Cancelling an old lifetime cannot remove a later request of the same type.
    RACDisposable *old=signal.producer(subscriber); LKConnectionRequest *oldPing=channel.activeRequests.anyObject; oldPing.succBlock([LookinConnectionResponseAttachment new]);
    RACDisposable *replacement=signal.producer(subscriber); newPing=[channel.activeRequests lookin_firstFiltered:^BOOL(LKConnectionRequest *r) { return r.type==LookinRequestTypePing && r!=oldPing; }]; newPing.succBlock([LookinConnectionResponseAttachment new]);
    detail=[channel.activeRequests lookin_firstFiltered:^BOOL(LKConnectionRequest *r) { return r.type==LookinRequestTypeHierarchyDetails; }];
    [old dispose]; CHECK([channel.activeRequests containsObject:detail],"old disposer cannot cancel replacement request"); [replacement dispose];
    // Новая возможность разрешает прямые запросы только после проверки версии.
    channel=[Lookin_PTChannel new];subscriber=[HCSubscriber new];
    RACDisposable *handshake=[manager requestWithType:LookinRequestTypeHierarchy data:nil channel:channel].producer(subscriber);
    CHECK([channel.writes.lastObject[@"type"] unsignedIntValue]==LookinRequestTypePing,"new connection starts with a handshake");
    LookinConnectionResponseAttachment *capability=[LookinConnectionResponseAttachment new];capability.data=@{@"capabilities":@[@"guardedResourceRequestsV1"]};
    ping=channel.activeRequests.anyObject;ping.succBlock(capability);
    CHECK(channel.guardedResourceRequests,"successful supported handshake is cached per channel");[handshake dispose];
    NSUInteger before=channel.writes.count;
    RACDisposable *direct=[manager requestWithType:LookinRequestTypeMetadata data:nil channel:channel].producer(subscriber);
    CHECK(channel.writes.count==before+1 && [channel.writes.lastObject[@"type"] unsignedIntValue]==LookinRequestTypeMetadata,"metadata does not send a redundant ping");
    detail=channel.activeRequests.anyObject;[direct dispose];HCWriteCompleted(channel,channel.writes.count-1);
    CHECK(channel.activeRequests.count==0 && !detail.timerArmed,"direct queued send remains cancellable");
    direct=[manager requestWithType:LookinRequestTypeHierarchyDetails data:nil channel:channel].producer(subscriber);
    CHECK([channel.writes.lastObject[@"type"] unsignedIntValue]==LookinRequestTypeHierarchyDetails,"images use direct path");
    detail=channel.activeRequests.anyObject;HCWriteCompleted(channel,channel.writes.count-1);CHECK(detail.timerArmed,"direct request keeps timeout");[direct dispose];
    direct=[manager requestWithType:LookinRequestTypeHierarchyDetails data:nil channel:channel].producer(subscriber);
    detail=channel.activeRequests.anyObject;detail.resourceFramesPending=1;HCWriteCompleted(channel,channel.writes.count-1);
    CHECK(!detail.timerArmed,"late send completion cannot arm timeout during local decode");[direct dispose];
    direct=[manager requestWithType:LookinRequestTypeApp data:nil channel:channel].producer(subscriber);
    CHECK([channel.writes.lastObject[@"type"] unsignedIntValue]==LookinRequestTypePing,"discovery retains its original preflight");[direct dispose];
    [manager ioFrameChannel:channel didEndWithError:nil];CHECK(!channel.guardedResourceRequests,"disconnect clears negotiated capability");
    channel.isConnected=YES;direct=[manager requestWithType:LookinRequestTypeHierarchy data:nil channel:channel].producer(subscriber);
    CHECK([channel.writes.lastObject[@"type"] unsignedIntValue]==LookinRequestTypePing,"reconnect requires new handshake");
    ping=channel.activeRequests.anyObject;channel.isConnected=NO;ping.succBlock(capability);
    CHECK(!channel.guardedResourceRequests,"late handshake cannot validate closed channel");[direct dispose];
    channel=[Lookin_PTChannel new];manager.rejectVersion=YES;subscriber=[HCSubscriber new];
    direct=[manager requestWithType:LookinRequestTypeHierarchy data:nil channel:channel].producer(subscriber);ping=channel.activeRequests.anyObject;ping.succBlock(capability);
    CHECK(subscriber.errors==1 && channel.writes.count==1 && !channel.guardedResourceRequests,"unsupported version cannot enable direct requests");[direct dispose];manager.rejectVersion=NO;
    channel=[Lookin_PTChannel new];direct=[manager requestWithType:LookinRequestTypeHierarchy data:nil channel:channel].producer(subscriber);ping=channel.activeRequests.anyObject;ping.succBlock([LookinConnectionResponseAttachment new]);[direct dispose];
    direct=[manager requestWithType:LookinRequestTypeMetadata data:nil channel:channel].producer(subscriber);
    CHECK(!channel.guardedResourceRequests && [channel.writes.lastObject[@"type"] unsignedIntValue]==LookinRequestTypePing,"old server keeps per-request ping fallback");[direct dispose];
    fprintf(stdout,"PASS: %lu native connection assertions\n",(unsigned long)tests);
} return 0; }
