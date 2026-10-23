// Native regression harness. The runner inserts the unmodified production
// coordinator implementation; only its transport/model/UI dependencies are fake.
#import <Cocoa/Cocoa.h>
#import <math.h>
#include "SwiftCoreUnderTest.inc"

static NSMutableArray *HCPumps, *HCTimers, *HCTimerDelays;
static void HCDispatch(dispatch_block_t block) { [HCPumps addObject:[block copy]]; }
static void HCAfter(int64_t delay, dispatch_block_t block) { [HCTimers addObject:[block copy]]; [HCTimerDelays addObject:@(delay)]; }
#define dispatch_async(queue, block) HCDispatch(block)
#define dispatch_time(now, delta) (delta)
#define dispatch_after(delay, queue, block) HCAfter(delay, block)
#define weakify(x) try {} @finally {} __weak __typeof__(x) x##_weak_ = x
#define strongify(x) try {} @finally {} __strong __typeof__(x##_weak_) x = x##_weak_
#define RACObserve(...) [RACSignal new]

@interface RACDisposable : NSObject
@property BOOL disposed;
- (void)dispose;
@end
@implementation RACDisposable
- (void)dispose { self.disposed = YES; }
@end
@interface RACSerialDisposable : RACDisposable
@property(nonatomic, strong) RACDisposable *disposable;
+ (instancetype)serialDisposableWithDisposable:(RACDisposable *)value;
@end
@implementation RACSerialDisposable
+ (instancetype)serialDisposableWithDisposable:(RACDisposable *)value { RACSerialDisposable *s=[self new]; s.disposable=value; return s; }
- (void)setDisposable:(RACDisposable *)value { if (self.disposed) { [value dispose]; return; } _disposable=value; }
- (void)dispose { [super dispose]; [_disposable dispose]; _disposable=nil; }
@end
@interface RACSignal : NSObject
@property(copy) void (^next)(id);
@property(copy) void (^error)(NSError *);
@property(copy) void (^completed)(void);
@property(strong) NSError *synchronousError;
@property(nonatomic, strong) RACDisposable *disposable;
- (RACDisposable *)subscribeNext:(void (^)(id))next;
- (RACSignal *)distinctUntilChanged;
- (RACDisposable *)subscribeNext:(void (^)(id))next error:(void (^)(NSError *))error completed:(void (^)(void))completed;
@end
@implementation RACSignal
- (RACSignal *)distinctUntilChanged { return self; }
- (RACDisposable *)subscribeNext:(void (^)(id))next { return [self subscribeNext:next error:nil completed:nil]; }
- (RACDisposable *)subscribeNext:(void (^)(id))next error:(void (^)(NSError *))error completed:(void (^)(void))completed {
    self.next=next; self.error=error; self.completed=completed; self.disposable=[RACDisposable new];
    if (self.synchronousError && error) error(self.synchronousError);
    return self.disposable;
}
@end
@interface RACSubject : RACSignal
@property NSUInteger sentCount;
+ (instancetype)subject;
- (void)sendNext:(id)value;
@end
@implementation RACSubject
+ (instancetype)subject { return [self new]; }
- (void)sendNext:(id)value { self.sentCount++; if (self.next) self.next(value); }
@end
@interface RACTwoTuple : NSObject
+ (instancetype)tupleWithObjectsFromArray:(NSArray *)objects;
@end
@implementation RACTwoTuple
+ (instancetype)tupleWithObjectsFromArray:(NSArray *)objects { return [self new]; }
@end

typedef NS_ENUM(NSInteger, LookinResourceState) { LookinResourceStateMissing, LookinResourceStateLoading, LookinResourceStateReady, LookinResourceStateNotApplicable, LookinResourceStateFailed };
typedef NS_ENUM(NSInteger, LookinDoNotFetchScreenshotReason) { LookinFetchScreenshotPermitted, LookinDoNotFetchScreenshotForUserConfig };
@interface LookinObject : NSObject
@property unsigned long oid;
@end
@implementation LookinObject
@end
@interface LookinDisplayItem : NSObject
@property(strong) LookinObject *layerObject;
@property(strong) id customInfo;
@property(strong) NSArray *attributesGroupList;
@property(strong) id groupScreenshot, soloScreenshot;
@property(copy) NSData *groupScreenshotData, *soloScreenshotData;
@property NSUInteger resourceRevision;
@property LookinResourceState attributesState, customAttributesState, metadataState, groupImageState, soloImageState;
@property LookinDoNotFetchScreenshotReason doNotFetchScreenshotReason;
@property BOOL isUserCustom, isExpandable, isExpanded, representedAsKeyWindow, inNoPreviewHierarchy, inHiddenHierarchy;
@property CGRect frame;
@property(copy) NSArray<LookinDisplayItem *> *subitems;
@property(weak) LookinDisplayItem *superItem;
+ (NSArray *)flatItemsFromHierarchicalItems:(NSArray *)items;
- (void)enumerateSelfAndAncestors:(void (^)(LookinDisplayItem *, BOOL *))block;
- (void)enumerateAncestors:(void (^)(LookinDisplayItem *, BOOL *))block;
- (void)enumerateSelfAndChildren:(void (^)(LookinDisplayItem *))block;
- (BOOL)hasPhysicalSublayers;
- (NSString *)appropriateScreenshotResourceKind;
- (NSImage *)appropriateScreenshot;
@end
@implementation LookinDisplayItem
+ (NSArray *)flatItemsFromHierarchicalItems:(NSArray *)items { NSMutableArray *flat=[NSMutableArray array]; for (LookinDisplayItem *i in items) [i enumerateSelfAndChildren:^(LookinDisplayItem *j) { [flat addObject:j]; }]; return flat; }
- (void)enumerateSelfAndAncestors:(void (^)(LookinDisplayItem *, BOOL *))block { BOOL stop=NO; for (LookinDisplayItem *i=self; i && !stop; i=i.superItem) block(i,&stop); }
- (void)enumerateAncestors:(void (^)(LookinDisplayItem *, BOOL *))block { [self.superItem enumerateSelfAndAncestors:block]; }
- (void)enumerateSelfAndChildren:(void (^)(LookinDisplayItem *))block { block(self); for (LookinDisplayItem *i in self.subitems) [i enumerateSelfAndChildren:block]; }
#include "ScreenshotSelectionUnderTest.inc"
@end
@interface LookinAppInfo : NSObject
@property(copy) NSArray *capabilities;
@property CGFloat screenScale;
@end
@implementation LookinAppInfo
@end
@interface LookinHierarchyInfo : NSObject
@property(copy) NSString *snapshotID;
@property BOOL metadataDeferred;
@property(copy) NSArray *displayItems;
@end
@implementation LookinHierarchyInfo
@end
@interface LookinDisplayItemDetail : NSObject
@property unsigned long displayItemOid;
@property NSUInteger resourceRevision;
@property(copy) NSString *snapshotID;
@property(copy) NSArray *providedFields;
@property NSInteger failureCode;
@property(copy) NSData *groupScreenshotData, *soloScreenshotData;
@property(strong) id groupScreenshot, soloScreenshot;
@property(copy) NSArray *subitems;
@end
@implementation LookinDisplayItemDetail
@end

typedef NS_ENUM(NSInteger, LookinStaticAsyncUpdateTaskType) { LookinStaticAsyncUpdateTaskTypeNoScreenshot, LookinStaticAsyncUpdateTaskTypeSoloScreenshot, LookinStaticAsyncUpdateTaskTypeGroupScreenshot };
typedef NS_ENUM(NSInteger, LookinDetailUpdateTaskAttrRequest) { LookinDetailUpdateTaskAttrRequest_Automatic, LookinDetailUpdateTaskAttrRequest_Need, LookinDetailUpdateTaskAttrRequest_NotNeed };
@interface LookinStaticAsyncUpdateTask : NSObject
@property unsigned long oid;
@property CGSize frameSize;
@property(copy) NSString *clientReadableVersion, *snapshotID;
@property NSUInteger resourceRevision;
@property LookinStaticAsyncUpdateTaskType taskType;
@property LookinDetailUpdateTaskAttrRequest attrRequest;
@property BOOL needMetadata, forceMetadataRefresh, needBasisVisualInfo, needSubitems, useCompactResources;
@end
@implementation LookinStaticAsyncUpdateTask
@end
@interface LookinStaticAsyncUpdateTasksPackage : NSObject
@property(copy) NSArray<LookinStaticAsyncUpdateTask *> *tasks;
@end
@implementation LookinStaticAsyncUpdateTasksPackage
@end
@interface LKInspectableApp : NSObject
@property(strong) LookinAppInfo *appInfo;
@property(strong) NSMutableArray<RACSignal *> *signals;
@property(strong) NSMutableArray<NSArray<LookinStaticAsyncUpdateTask *> *> *batches;
@property(strong) NSError *nextSynchronousError;
@property NSUInteger cancels;
- (RACSignal *)fetchHierarchyDetailWithTaskPackages:(NSArray *)packages;
- (RACSignal *)fetchMetadataWithTaskPackages:(NSArray *)packages;
- (void)cancelHierarchyDetailFetching;
@end
@implementation LKInspectableApp
- (instancetype)init { if ((self=[super init])) { _signals=[NSMutableArray array]; _batches=[NSMutableArray array]; _appInfo=[LookinAppInfo new]; _appInfo.capabilities=@[@"deferredMetadataV1",@"resourceRevisionsV1"]; } return self; }
- (RACSignal *)fetchHierarchyDetailWithTaskPackages:(NSArray *)packages { RACSignal *s=[RACSignal new]; s.synchronousError=self.nextSynchronousError; self.nextSynchronousError=nil; [self.signals addObject:s]; [self.batches addObject:((LookinStaticAsyncUpdateTasksPackage *)packages.firstObject).tasks]; return s; }
- (RACSignal *)fetchMetadataWithTaskPackages:(NSArray *)packages { return [self fetchHierarchyDetailWithTaskPackages:packages]; }
- (void)cancelHierarchyDetailFetching { self.cancels++; }
@end
#define HC_SINGLETON(cls, selector) + (instancetype)selector { static cls *v; static dispatch_once_t once; dispatch_once(&once, ^{ v=[cls new]; }); return v; }
@interface LKAppsManager : NSObject
@property(strong) LKInspectableApp *inspectingApp;
+ (instancetype)sharedInstance;
@end
@implementation LKAppsManager
HC_SINGLETON(LKAppsManager, sharedInstance)
@end
@interface LKPreferenceManager : NSObject
@property(copy) NSString *loadingMode;
+ (instancetype)mainManager;
@end
@implementation LKPreferenceManager
HC_SINGLETON(LKPreferenceManager, mainManager)
@end
@interface LKPerformanceReporter : NSObject
+ (instancetype)sharedInstance;
- (void)didComplete;
@end
@implementation LKPerformanceReporter
HC_SINGLETON(LKPerformanceReporter, sharedInstance)
- (void)didComplete {}
@end
@interface LKHelper : NSObject
+ (NSString *)lookinReadableVersion;
@end
@implementation LKHelper
+ (NSString *)lookinReadableVersion { return @"1.2.8"; }
@end
typedef NS_ENUM(NSInteger, LKHierarchyDataSourceState) { LKHierarchyDataSourceStateNormal, LKHierarchyDataSourceStateFocus, LKHierarchyDataSourceStateSearch };
@interface LKStaticHierarchyDataSource : NSObject
@property LKHierarchyDataSourceState state;
@property(copy) NSArray<LookinDisplayItem *> *rawFlatItems, *displayingFlatItems;
@property(strong) LookinDisplayItem *selectedItem;
@property NSUInteger applied;
@property(copy) dispatch_block_t onApply;
+ (instancetype)sharedInstance;
- (void)modifyWithDisplayItemDetail:(LookinDisplayItemDetail *)detail;
- (void)modifySubtreeWithDisplayItemDetail:(LookinDisplayItemDetail *)detail;
@end
@implementation LKStaticHierarchyDataSource
HC_SINGLETON(LKStaticHierarchyDataSource, sharedInstance)
- (void)modifyWithDisplayItemDetail:(LookinDisplayItemDetail *)detail { self.applied++; if (self.onApply) self.onApply(); }
- (void)modifySubtreeWithDisplayItemDetail:(LookinDisplayItemDetail *)detail {
    self.applied++;
    for (LookinDisplayItem *i in self.rawFlatItems) if (i.layerObject.oid==detail.displayItemOid) {
        i.subitems=detail.subitems;
        for (LookinDisplayItem *child in detail.subitems) child.superItem=i;
        self.rawFlatItems=[LookinDisplayItem flatItemsFromHierarchicalItems:@[i]];
        self.displayingFlatItems=self.rawFlatItems;
        break;
    }
    if (self.onApply) self.onApply();
}
@end

static NSUInteger HCJobValuesVisited;
@interface HCIndexedJobs : NSMutableDictionary
@property NSMutableDictionary *storage;
@end
@implementation HCIndexedJobs
- (instancetype)init { if ((self=[super init])) _storage=[NSMutableDictionary dictionary]; return self; }
- (NSUInteger)count { return self.storage.count; }
- (NSEnumerator *)keyEnumerator { return self.storage.keyEnumerator; }
- (id)objectForKey:(id)key { return self.storage[key]; }
- (void)setObject:(id)object forKey:(id<NSCopying>)key { self.storage[key]=object; }
- (void)removeObjectForKey:(id)key { [self.storage removeObjectForKey:key]; }
- (NSArray *)allValues { HCJobValuesVisited+=self.storage.count; return self.storage.allValues; }
@end

#include "CoordinatorUnderTest.inc"

static NSUInteger tests;
#define CHECK(condition, message) do { tests++; if (!(condition)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,message); exit(1); } } while(0)
static LookinDisplayItem *HCItem(unsigned long oid) { LookinDisplayItem *i=[LookinDisplayItem new]; i.layerObject=[LookinObject new]; i.layerObject.oid=oid; i.frame=CGRectMake(0,0,100,100); return i; }
static LKInspectableApp *HCPrepare(NSArray *roots, BOOL metadataDeferred) {
    LKStaticAsyncUpdateManager *m=LKStaticAsyncUpdateManager.sharedInstance;
    [m endUpdating];
    LKInspectableApp *app=[LKInspectableApp new]; LKAppsManager.sharedInstance.inspectingApp=app;
    LookinHierarchyInfo *info=[LookinHierarchyInfo new]; info.snapshotID=NSUUID.UUID.UUIDString; info.displayItems=roots; info.metadataDeferred=metadataDeferred;
    [m prepareForSnapshot:info];
    LKStaticHierarchyDataSource.sharedInstance.rawFlatItems=[LookinDisplayItem flatItemsFromHierarchicalItems:roots];
    LKStaticHierarchyDataSource.sharedInstance.displayingFlatItems=LKStaticHierarchyDataSource.sharedInstance.rawFlatItems;
    LKStaticHierarchyDataSource.sharedInstance.selectedItem=nil;
    LKStaticHierarchyDataSource.sharedInstance.onApply=nil;
    LKStaticHierarchyDataSource.sharedInstance.state=LKHierarchyDataSourceStateNormal;
    [HCPumps removeAllObjects]; [HCTimers removeAllObjects]; [HCTimerDelays removeAllObjects];
    [m setValue:@NO forKey:@"scheduled"];
    [m startLoadingSnapshot];
    return app;
}
static NSString *HCKind(LookinStaticAsyncUpdateTask *t) { return t.needMetadata ? @"metadata" : t.attrRequest==LookinDetailUpdateTaskAttrRequest_Need ? @"attributes" : t.taskType==LookinStaticAsyncUpdateTaskTypeGroupScreenshot ? @"group" : @"solo"; }
static LookinDisplayItemDetail *HCReply(LookinStaticAsyncUpdateTask *t) {
    LookinDisplayItemDetail *d=[LookinDisplayItemDetail new]; d.displayItemOid=t.oid; d.snapshotID=t.snapshotID; d.resourceRevision=t.resourceRevision;
    NSMutableArray *fields=[NSMutableArray array];
    if (t.needMetadata) [fields addObject:@"metadata"];
    if (t.attrRequest==LookinDetailUpdateTaskAttrRequest_Need) [fields addObject:@"attributes"];
    if (t.taskType==LookinStaticAsyncUpdateTaskTypeGroupScreenshot) [fields addObject:@"group"];
    if (t.taskType==LookinStaticAsyncUpdateTaskTypeSoloScreenshot) [fields addObject:@"solo"];
    d.providedFields=fields;
    if (t.taskType==LookinStaticAsyncUpdateTaskTypeGroupScreenshot) d.groupScreenshotData=[@"png" dataUsingEncoding:NSUTF8StringEncoding];
    if (t.taskType==LookinStaticAsyncUpdateTaskTypeSoloScreenshot) d.soloScreenshotData=[@"png" dataUsingEncoding:NSUTF8StringEncoding];
    return d;
}
static void HCSucceedLatest(LKInspectableApp *app) { RACSignal *s=app.signals.lastObject; NSMutableArray *details=[NSMutableArray array]; for (LookinStaticAsyncUpdateTask *t in app.batches.lastObject) [details addObject:HCReply(t)]; s.next(details); s.completed(); }
static void HCFinish(LKInspectableApp *app) { LKStaticAsyncUpdateManager *m=LKStaticAsyncUpdateManager.sharedInstance; NSUInteger guard=0; while (m.isUpdating && guard++<100) { [m pump]; if (m.requestActive) HCSucceedLatest(app); } CHECK(!m.isUpdating,"queue drains"); }

int main(void) { @autoreleasepool {
    HCPumps=[NSMutableArray array]; HCTimers=[NSMutableArray array]; HCTimerDelays=[NSMutableArray array];
    LKPreferenceManager.mainManager.loadingMode=@"hybrid";
    LKStaticAsyncUpdateManager *m=LKStaticAsyncUpdateManager.sharedInstance;

    // Пустая очередь тоже завершает ожидание и обновляет индикаторы готовности.
    LKInspectableApp *emptyApp=HCPrepare(@[],YES);
    NSUInteger emptyNotifications=m.resourcesDidChange.sentCount;
    [m pump];
    CHECK(m.resourcesDidChange.sentCount==emptyNotifications+1,"empty queue notifies resource observers");
    CHECK(emptyApp.batches.count==0,"empty queue never sends a wire request");

    LookinDisplayItem *item=HCItem(1); item.isExpandable=YES; item.subitems=@[HCItem(99)];
    LKInspectableApp *app=HCPrepare(@[item],YES);
    __block NSUInteger completed=0;
    [m ensureResourcesForItem:item kinds:@[@"attributes",@"group",@"solo",@"metadata"] completion:^(NSError *e) { CHECK(!e,"full waiter succeeds"); completed++; }];
    [m pump]; CHECK(app.batches.lastObject.count==1,"one resource per oid in a batch");
    RACSignal *first=app.signals.lastObject; LookinStaticAsyncUpdateTask *firstTask=app.batches.lastObject.firstObject;
    LookinDisplayItemDetail *stale=HCReply(firstTask); stale.resourceRevision++;
    NSUInteger applies=LKStaticHierarchyDataSource.sharedInstance.applied;
    first.next(@[stale]); CHECK(LKStaticHierarchyDataSource.sharedInstance.applied==applies,"wrong revision rejected");
    CHECK(m.jobs.count==7,"wrong revision does not consume job");
    HCSucceedLatest(app); HCFinish(app); CHECK(completed==1 && m.snapshotComplete,"all resource families complete exactly once");

    // Reentrant completion cancellation must never deliver a waiter twice.
    item=HCItem(2); app=HCPrepare(@[item],NO); __block NSUInteger callbacks=0;
    for (NSUInteger i=0;i<2;i++) [m ensureResourcesForItem:item kinds:@[@"attributes"] completion:^(NSError *e) { callbacks++; [m endUpdating]; }];
    [m pump]; HCSucceedLatest(app); CHECK(callbacks==2,"reentrant Stop delivers each waiter once");
    CHECK(!m.isUpdating,"Stop leaves queue empty"); CHECK(item.groupImageState!=LookinResourceStateLoading,"Stop clears pending Loading");
    [m loadingModeDidChange]; HCFinish(app); CHECK(m.snapshotComplete,"mode switch resumes stopped snapshot");

    // Disconnect during an active response resets Loading and rejects old replies.
    item=HCItem(3); app=HCPrepare(@[item],NO); [m pump]; first=app.signals.lastObject; firstTask=app.batches.lastObject.firstObject;
    [m cancelCurrentGenerationWithMessage:@"disconnect"]; LKAppsManager.sharedInstance.inspectingApp=nil;
    CHECK(item.groupImageState==LookinResourceStateMissing,"disconnect resets active resource");
    applies=LKStaticHierarchyDataSource.sharedInstance.applied; first.next(@[HCReply(firstTask)]); CHECK(applies==LKStaticHierarchyDataSource.sharedInstance.applied,"late generation reply rejected");
    LKAppsManager.sharedInstance.inspectingApp=[LKInspectableApp new]; item.attributesState=LookinResourceStateReady; item.customAttributesState=LookinResourceStateReady;
    __block NSError *error=nil;
    [m ensureResourcesForItem:item kinds:@[@"attributes"] completion:^(NSError *e) { error=e; }]; CHECK(error.code==409,"ready fast path rejects a different app session");

    // Failed captures are failures, not a false complete/export state.
    item=HCItem(4); app=HCPrepare(@[item],NO);
    error=nil; [m ensureResourcesForItem:item kinds:@[@"group"] completion:^(NSError *e) { error=e; }]; [m pump];
    LookinDisplayItemDetail *empty=HCReply(app.batches.lastObject.firstObject); empty.groupScreenshotData=nil;
    app.signals.lastObject.next(@[empty]); app.signals.lastObject.completed();
    CHECK(item.groupImageState==LookinResourceStateFailed && error.code==502,"empty applicable image fails"); CHECK(!m.snapshotComplete,"failed bitmap prevents full export");
    error=nil; [m ensureResourcesForItem:item kinds:@[@"group"] completion:^(NSError *e) { error=e; }]; HCFinish(app); CHECK(!error && m.snapshotComplete,"explicit request retries failed resource");

    // Interactive waits time out, whereas complete export may take over 30 seconds.
    item=HCItem(5); app=HCPrepare(@[item],YES);
    NSUInteger before=HCTimers.count; [m ensureCompleteWithCompletion:^(NSError *e) {}]; CHECK(HCTimers.count==before,"export barrier has no interactive timeout");
    [m ensureResourcesForItem:item kinds:@[@"group"] completion:^(NSError *e) { error=e; }]; CHECK([(NSNumber *)HCTimerDelays.lastObject longLongValue]==30LL*NSEC_PER_SEC,"interactive timeout is 30 sec");
    ((dispatch_block_t)HCTimers.lastObject)(); CHECK(error.code==408,"timeout terminates waiter"); HCFinish(app);

    // Revision invalidation must clear decoded legacy NSImages as well as PNG data.
    item.groupScreenshot=[NSObject new]; item.soloScreenshot=[NSObject new]; NSUInteger changes=m.resourcesDidChange.sentCount;
    [m invalidateItem:item attributes:YES]; CHECK(!item.groupScreenshot && !item.soloScreenshot,"legacy image cache cleared"); CHECK(item.metadataState==LookinResourceStateMissing,"manual reload invalidates metadata"); CHECK(m.resourcesDidChange.sentCount>changes,"invalidation notifies caches");
    [m updateAll]; HCFinish(app);
    BOOL refreshed=NO; for (NSArray *batch in app.batches) for (LookinStaticAsyncUpdateTask *t in batch) if (t.needMetadata && t.resourceRevision>1) refreshed|=t.forceMetadataRefresh;
    CHECK(refreshed,"manual metadata refresh reaches server");

    // Virtual nodes preserve embedded resources; no network oid is necessary.
    LookinDisplayItem *custom=HCItem(0); custom.isUserCustom=YES; custom.customInfo=[NSObject new]; custom.groupScreenshot=[NSObject new];
    app=HCPrepare(@[custom],YES); HCFinish(app); CHECK(m.snapshotComplete,"custom node participates in completeness");
    [m invalidateItem:custom attributes:YES]; CHECK(custom.groupScreenshot!=nil && custom.groupImageState==LookinResourceStateReady,"custom image survives live invalidation");

    // Synchronous transport failure must not leave a live stale subscription.
    item=HCItem(6); app=HCPrepare(@[item],NO); app.nextSynchronousError=[NSError errorWithDomain:@"test" code:503 userInfo:nil]; [m pump];
    CHECK(!m.requestActive && m.subscription==nil,"synchronous failure clears active subscription"); CHECK(app.signals.lastObject.disposable.disposed,"synchronously returned disposable is disposed");

    // Structural requests are cancellable and late responses cannot replace children.
    item=HCItem(7); app=HCPrepare(@[item],YES); [m reloadDisplayItemAndChildren:item]; first=app.signals.lastObject;
    CHECK(m.subscription!=nil && m.preparing,"structural request owns cancellable subscription"); [m endUpdating]; CHECK(first.disposable.disposed && !m.preparing,"Stop cancels structural request and unblocks resume");
    LookinDisplayItemDetail *subtree=[LookinDisplayItemDetail new]; subtree.displayItemOid=7; subtree.subitems=@[HCItem(8)]; first.next(@[subtree]); CHECK(item.subitems.count==0,"late structural response ignored");
    [m reloadDisplayItemAndChildren:item]; first=app.signals.lastObject; subtree=HCReply(app.batches.lastObject.firstObject); subtree.subitems=@[HCItem(8)];
    first.next(@[subtree]); first.completed();
    LookinDisplayItem *child=item.subitems.firstObject; CHECK(child.resourceRevision==1 && child.metadataState==LookinResourceStateLoading,"new subtree metadata is initialized and queued"); HCFinish(app); CHECK(m.snapshotComplete,"refreshed subtree reaches completeness");

    // Invalid kinds cannot silently load a solo image.
    error=nil; [m ensureResourcesForItem:item kinds:@[@"unknown"] completion:^(NSError *e) { error=e; }]; CHECK(error.code==400,"unknown kind rejected");

    // A zero-size node can receive a usable frame in a later attributes reply.
    item=HCItem(9); item.frame=CGRectZero; app=HCPrepare(@[item],NO);
    CHECK(item.groupImageState==LookinResourceStateNotApplicable,"zero-size image is initially not applicable");
    __block LookinDisplayItem *resized=item;
    LKStaticHierarchyDataSource.sharedInstance.onApply=^{ resized.frame=CGRectMake(0,0,120,80); };
    [m pump]; HCSucceedLatest(app);
    CHECK(item.groupImageState==LookinResourceStateLoading,"basis resize schedules previously inapplicable image");
    CHECK(!m.snapshotComplete,"resized node is incomplete before image arrives"); HCFinish(app);
    CHECK(item.groupImageState==LookinResourceStateReady && m.snapshotComplete,"resized node captures image before complete");

    // Custom virtual children make the GUI expandable, but do not create CALayers.
    item=HCItem(10); item.isExpandable=YES; item.isExpanded=YES; custom=HCItem(0); custom.isUserCustom=YES; custom.customInfo=[NSObject new]; item.subitems=@[custom];
    app=HCPrepare(@[item],NO);
    CHECK([item.appropriateScreenshotResourceKind isEqual:@"group"],"expanded custom-only container selects group");
    CHECK(!m.previewReady,"custom-only preview waits for group image rather than accepting solo NA");
    [m pump]; CHECK(app.batches.lastObject.firstObject.taskType==LookinStaticAsyncUpdateTaskTypeGroupScreenshot,"custom-only preview prioritizes group capture");
    HCFinish(app);
    CHECK(item.soloImageState==LookinResourceStateNotApplicable && m.snapshotComplete,"custom-only children do not require an impossible solo capture");
    NSObject *groupImage=[NSObject new], *soloImage=[NSObject new]; item.groupScreenshot=groupImage; item.soloScreenshot=soloImage;
    CHECK(item.appropriateScreenshot==(id)groupImage,"custom-only preview renders the group texture");
    item.subitems=@[custom,HCItem(11)];
    CHECK([item.appropriateScreenshotResourceKind isEqual:@"solo"] && item.appropriateScreenshot==(id)soloImage,"expanded physical children select solo");
    item.isExpanded=NO;
    CHECK([item.appropriateScreenshotResourceKind isEqual:@"group"] && item.appropriateScreenshot==(id)groupImage,"collapsed physical container selects group");
    // Full mode coalesces attributes and an image into one per-oid wire task.
    LKPreferenceManager.mainManager.loadingMode=@"full";
    item=HCItem(12); app=HCPrepare(@[item],NO); [m pump];
    LookinStaticAsyncUpdateTask *combined=app.batches.lastObject.firstObject;
    CHECK(app.batches.lastObject.count==1 && combined.attrRequest==LookinDetailUpdateTaskAttrRequest_Need && combined.taskType==LookinStaticAsyncUpdateTaskTypeGroupScreenshot,"full combines image and attributes into one wire task");
    applies=LKStaticHierarchyDataSource.sharedInstance.applied; HCSucceedLatest(app);
    CHECK(item.attributesState==LookinResourceStateReady && item.groupImageState==LookinResourceStateReady,"combined reply completes both resources");
    CHECK(LKStaticHierarchyDataSource.sharedInstance.applied==applies+1,"combined reply is applied once"); HCFinish(app);
    item=HCItem(13); app=HCPrepare(@[item],NO); [m pump];
    LookinDisplayItemDetail *failure=HCReply(app.batches.lastObject.firstObject); failure.failureCode=-1;
    app.signals.lastObject.next(@[failure]); app.signals.lastObject.completed();
    CHECK(item.attributesState==LookinResourceStateFailed && item.groupImageState==LookinResourceStateFailed,"combined failure rejects both resources");
    item=HCItem(14); app=HCPrepare(@[item],NO); [m pump];
    LookinDisplayItemDetail *legacy=HCReply(app.batches.lastObject.firstObject); legacy.providedFields=nil;
    app.signals.lastObject.next(@[legacy]); app.signals.lastObject.completed();
    CHECK(item.attributesState==LookinResourceStateReady && item.groupImageState==LookinResourceStateReady,"legacy combined reply remains unambiguous"); HCFinish(app);
    LKPreferenceManager.mainManager.loadingMode=@"hybrid";
    item=HCItem(15); item.representedAsKeyWindow=YES; item.isExpandable=YES; item.isExpanded=YES; item.subitems=@[HCItem(16)];
    app=HCPrepare(@[item],YES); [m pump];
    CHECK(app.batches.lastObject.firstObject.oid==15 && app.batches.lastObject.firstObject.taskType==LookinStaticAsyncUpdateTaskTypeGroupScreenshot,"hybrid prioritizes complete key-window image");
    item.groupScreenshotData=[@"png" dataUsingEncoding:NSUTF8StringEncoding]; item.groupImageState=LookinResourceStateReady;
    CHECK(m.progressivePreviewItem==item && m.previewReady && !m.layerTexturesReady && !m.snapshotComplete,"working overview is separate from complete layer textures and snapshot");
    LKStaticHierarchyDataSource.sharedInstance.state=LKHierarchyDataSourceStateSearch;
    CHECK(m.progressivePreviewItem==nil,"search never displays unrelated whole-window overview");
    LKStaticHierarchyDataSource.sharedInstance.state=LKHierarchyDataSourceStateFocus; item.representedAsKeyWindow=NO;
    CHECK(m.progressivePreviewItem==item,"Focus uses its own subtree group overview");
    item.inHiddenHierarchy=YES; CHECK(m.progressivePreviewItem==nil,"hidden scope does not become a visible overview"); item.inHiddenHierarchy=NO;
    [m invalidateItem:item attributes:NO]; CHECK(m.progressivePreviewItem==nil,"invalidation removes stale overview immediately");
    LKPreferenceManager.mainManager.loadingMode=@"full"; CHECK(m.progressivePreviewItem==nil,"full mode retains progressive per-layer rendering");
    LKPreferenceManager.mainManager.loadingMode=@"hybrid";
    item=HCItem(17); app=HCPrepare(@[item],YES);
    [m ensureResourcesForItem:item kinds:@[@"metadata"] completion:^(NSError *e) { CHECK(!e,"metadata consumer succeeds"); }];
    [m pump]; CHECK(app.batches.lastObject.firstObject.needMetadata,"interactive metadata is requested first");
    LookinDisplayItemDetail *withAttributes=HCReply(app.batches.lastObject.firstObject);
    withAttributes.providedFields=@[@"metadata",@"attributes"];
    app.signals.lastObject.next(@[withAttributes]); app.signals.lastObject.completed();
    CHECK(item.attributesState==LookinResourceStateReady,"metadata patch completes queued trace-dependent attributes");
    CHECK(m.jobs[[m keyForItem:item kind:@"attributes"]]==nil,"metadata patch does not leave a duplicate attribute request"); HCFinish(app);
    // Background properties are collected after traces once, while a demanded
    // property still resolves before metadata and never waits for that phase.
    item=HCItem(18); item.groupScreenshotData=[@"png" dataUsingEncoding:NSUTF8StringEncoding]; app=HCPrepare(@[item],YES); [m pump];
    combined=app.batches.lastObject.firstObject;
    CHECK(combined.needMetadata && combined.attrRequest==LookinDetailUpdateTaskAttrRequest_Need,"hybrid combines background metadata and attributes");
    applies=LKStaticHierarchyDataSource.sharedInstance.applied; HCSucceedLatest(app);
    CHECK(item.metadataState==LookinResourceStateReady && item.attributesState==LookinResourceStateReady,"one metadata response completes both background resources");
    CHECK(LKStaticHierarchyDataSource.sharedInstance.applied==applies+1,"combined metadata is applied once"); HCFinish(app);
    item=HCItem(19); app=HCPrepare(@[item],YES);
    __block BOOL propertyCompleted=NO;
    [m ensureResourcesForItem:item kinds:@[@"attributes"] completion:^(NSError *e) { CHECK(!e,"early property request succeeds"); propertyCompleted=YES; }];
    [m pump]; combined=app.batches.lastObject.firstObject;
    CHECK(!combined.needMetadata && combined.attrRequest==LookinDetailUpdateTaskAttrRequest_Need,"demanded attributes do not wait for metadata");
    HCSucceedLatest(app);
    CHECK(propertyCompleted && item.metadataState!=LookinResourceStateReady,"property consumer resolves while metadata is still pending"); HCFinish(app);
    item=HCItem(19); app=HCPrepare(@[item],YES); LKStaticHierarchyDataSource.sharedInstance.selectedItem=item; [m pump];
    combined=app.batches.lastObject.firstObject;
    CHECK(!combined.needMetadata && combined.attrRequest==LookinDetailUpdateTaskAttrRequest_Need,"selected properties keep their early priority"); HCFinish(app);
    LKPreferenceManager.mainManager.loadingMode=@"full";
    NSMutableArray *largeItems=[NSMutableArray array];
    for(NSUInteger i=0;i<8;i++){LookinDisplayItem *node=HCItem(20+i);node.frame=CGRectMake(0,0,500,500);[largeItems addObject:node];}
    app=HCPrepare(largeItems,NO); app.appInfo.screenScale=3; [m pump];
    CHECK(app.batches.lastObject.count==6,"3x full packets respect the 60 MiB client budget including combined attributes"); HCFinish(app);
    app=HCPrepare(largeItems,NO); app.appInfo.screenScale=1; [m pump];
    CHECK(app.batches.lastObject.count==8,"native scale drives batching without lowering image quality"); HCFinish(app);
    NSMutableArray *hugeTree=[NSMutableArray array];
    for(NSUInteger i=0;i<1000;i++)[hugeTree addObject:HCItem(1000+i)];
    app=HCPrepare(hugeTree,YES);
    HCIndexedJobs *indexed=[HCIndexedJobs new];[indexed addEntriesFromDictionary:m.jobs];m.jobs=indexed;
    [m pump];
    RACSignal *largeSignal=app.signals.lastObject;
    NSMutableArray *largeDetails=[NSMutableArray array];
    for(LookinStaticAsyncUpdateTask *task in app.batches.lastObject)[largeDetails addObject:HCReply(task)];
    HCJobValuesVisited=0;NSUInteger appliedBefore=LKStaticHierarchyDataSource.sharedInstance.applied;
    CFAbsoluteTime responseStart=CFAbsoluteTimeGetCurrent();largeSignal.next(largeDetails);
    fprintf(stdout,"RESPONSE_BENCHMARK nodes=1000 replies=%lu visited_jobs=%lu elapsed_ms=%.3f\n",(unsigned long)largeDetails.count,(unsigned long)HCJobValuesVisited,(CFAbsoluteTimeGetCurrent()-responseStart)*1000);
    if (!getenv("HC_RESPONSE_BENCHMARK_ONLY")) CHECK(HCJobValuesVisited==0,"resource delivery does not scan the unrelated 1000-node job queue");
    CHECK(LKStaticHierarchyDataSource.sharedInstance.applied==appliedBefore+largeDetails.count,"every indexed resource reply is applied once");
    largeSignal.completed();[m endUpdating];m.jobs=[NSMutableDictionary dictionary];
    // Исчезнувший потомок обновляет родителя один раз, сохраняя явную ошибку при повторе.
    LookinDisplayItem *repairRoot=HCItem(40001), *gone=HCItem(40002); repairRoot.subitems=@[gone]; gone.superItem=repairRoot;
    app=HCPrepare(@[repairRoot],NO); [m pump];
    first=app.signals.lastObject; NSMutableArray *repairReplies=[NSMutableArray array];
    for (LookinStaticAsyncUpdateTask *t in app.batches.lastObject) { LookinDisplayItemDetail *d=HCReply(t); if(t.oid==gone.layerObject.oid)d.failureCode=-1; [repairReplies addObject:d]; }
    first.next(repairReplies); first.completed();
    CHECK(app.batches.lastObject.firstObject.needSubitems && m.preparing,"missing child triggers a bounded parent refresh");
    LookinDisplayItem *replacement=HCItem(40003); LookinDisplayItemDetail *structure=HCReply(app.batches.lastObject.firstObject); structure.subitems=@[replacement];
    first=app.signals.lastObject; first.next(@[structure]); first.completed(); HCFinish(app);
    CHECK(m.snapshotComplete && m.failedResourceCount==0,"refreshed snapshot completes without stale failures");
    [m invalidateItem:replacement attributes:YES]; [m updateAll]; [m pump]; first=app.signals.lastObject;
    [repairReplies removeAllObjects]; for (LookinStaticAsyncUpdateTask *t in app.batches.lastObject) { LookinDisplayItemDetail *d=HCReply(t); if(t.oid==replacement.layerObject.oid)d.failureCode=-1; [repairReplies addObject:d]; }
    first.next(repairReplies); first.completed(); HCFinish(app);
    CHECK([m.loadingState isEqual:@"failed"] && m.resourceFailures.count>0 && !m.snapshotComplete,"repeated disappearance terminates with explicit failure");

    // Interactive оставляет невидимые ресурсы незагруженными до явного спроса.
    LKPreferenceManager.mainManager.loadingMode=@"interactive";
    LookinDisplayItem *visible=HCItem(41001), *offscreen=HCItem(41002);
    app=HCPrepare(@[visible,offscreen],YES); LKStaticHierarchyDataSource.sharedInstance.displayingFlatItems=@[visible];
    [m updateForDisplayingItems]; HCFinish(app);
    CHECK(!m.snapshotComplete && offscreen.groupImageState==LookinResourceStateMissing && offscreen.attributesState==LookinResourceStateMissing,"interactive does not eagerly fetch offscreen images and metadata");
    NSUInteger previousBatches=app.batches.count; error=nil;
    [m ensureResourcesForItem:offscreen kinds:@[@"group",@"metadata"] completion:^(NSError *e){error=e;}]; HCFinish(app);
    CHECK(!error && app.batches.count>previousBatches && offscreen.metadataState==LookinResourceStateReady,"explicit offscreen demand is fulfilled");
    __block BOOL exported=NO; [m ensureCompleteWithCompletion:^(NSError *e){exported=e==nil;}]; HCFinish(app);
    CHECK(exported && m.snapshotComplete,"interactive export materializes the complete snapshot");
    LKPreferenceManager.mainManager.loadingMode=@"hybrid";
    if (getenv("HC_PLANNER_BENCHMARK")) {
        for (NSNumber *nodeCount in @[@35,@1000]) {
            NSMutableArray *nodes=[NSMutableArray array];
            for (NSUInteger index=0;index<nodeCount.unsignedIntegerValue;index++) [nodes addObject:HCItem(30000+index)];
            app=HCPrepare(nodes,YES);
            NSMutableArray *samples=[NSMutableArray array];
            for (NSUInteger iteration=0;iteration<110;iteration++) {
                CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();
                [m pump];
                double elapsed=(CFAbsoluteTimeGetCurrent()-start)*1000;
                if (iteration>=10) [samples addObject:@(elapsed)];
                [m.subscription dispose];m.subscription=nil;m.requestActive=NO;
                for (LKResourceJob *job in m.jobs.allValues) job.active=NO;
                [app.signals removeAllObjects];[app.batches removeAllObjects];
            }
            [samples sortUsingSelector:@selector(compare:)];
            fprintf(stdout,"PLANNER_BENCHMARK nodes=%lu samples=100 median_ms=%.3f p95_ms=%.3f\n",nodeCount.unsignedIntegerValue,[samples[50] doubleValue],[samples[94] doubleValue]);
            [m endUpdating];
        }
    }
    const char *tracePath=getenv("HC_PLANNER_TRACES");
    if (tracePath) {
        NSMutableArray *traces=[NSMutableArray array];
        for(NSUInteger scenario=0;scenario<500;scenario++) {
            LKPreferenceManager.mainManager.loadingMode=scenario%2 ? @"hybrid" : @"full";
            NSMutableArray *roots=[NSMutableArray array];
            NSUInteger count=1+(scenario*37)%90;
            for(NSUInteger index=0;index<count;index++) {
                LookinDisplayItem *node=HCItem(20000+scenario*128+index);
                CGFloat size=(CGFloat[]){0,1,100,500,1200,10000}[(scenario+index*3)%6];
                node.frame=CGRectMake(0,0,size,size);
                if ((scenario+index)%7==0) node.attributesGroupList=@[];
                if ((scenario+index)%11==0) node.groupScreenshotData=[@"png" dataUsingEncoding:NSUTF8StringEncoding];
                [roots addObject:node];
            }
            app=HCPrepare(roots,scenario%3!=0);
            app.appInfo.screenScale=(CGFloat[]){0,1,2,3}[(scenario/2)%4];
            if (scenario%5==0) LKStaticHierarchyDataSource.sharedInstance.selectedItem=roots.lastObject;
            if (scenario%7==0) ((LookinDisplayItem *)roots.firstObject).representedAsKeyWindow=YES;
            if (scenario%13==0) ((LookinDisplayItem *)roots.lastObject).resourceRevision++;
            if (scenario%17==0) for(LKResourceJob *job in m.jobs.allValues) if(job.item==roots.firstObject) job.active=YES;
            NSMutableArray *callbacks=[NSMutableArray array];
            if (scenario%4==0) [m ensureResourcesForItem:roots.lastObject kinds:@[@"attributes"] completion:^(NSError *error){[callbacks addObject:@(error.code)];}];
            [m pump];
            NSMutableArray *wire=[NSMutableArray array];
            for(LookinStaticAsyncUpdateTask *task in app.batches.lastObject) {
                [wire addObject:@[@(task.oid),@(task.taskType),@(task.attrRequest),@(task.needMetadata),@(task.forceMetadataRefresh),@(task.resourceRevision),@(task.frameSize.width),@(task.frameSize.height)]];
            }
            [traces addObject:wire];[m endUpdating];
        }
        NSData *data=[NSJSONSerialization dataWithJSONObject:traces options:NSJSONWritingSortedKeys error:nil];
        CHECK([data writeToFile:@(tracePath) atomically:YES],"differential planner trace is saved");
    }
    fprintf(stdout,"PASS: %lu native coordinator assertions\n",(unsigned long)tests);
} return 0; }
