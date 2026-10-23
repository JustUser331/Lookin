#import "LKStaticAsyncUpdateManager.h"
#import "LKStaticHierarchyDataSource.h"
#import "LKAppsManager.h"
#import "LKPreferenceManager.h"
#import "LKPerformanceReporter.h"
#import "LookinHierarchyInfo.h"
#import "LookinDisplayItemDetail.h"
#import "LookinStaticAsyncUpdateTask.h"
#import "LookinDisplayItem+LookinClient.h"
#import <ReactiveObjC/RACSerialDisposable.h>
#import <math.h>
@import LookinResourceCore;

@interface LKResourceJob : NSObject
@property(nonatomic, strong) LookinDisplayItem *item;
@property(nonatomic, copy) NSString *kind;
@property(nonatomic, copy) NSString *key;
@property(nonatomic, assign) NSUInteger revision;
@property(nonatomic, assign) NSUInteger order;
@property(nonatomic, assign) BOOL active;
@end
@implementation LKResourceJob
@end

@interface LKResourceWaiter : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSArray<LookinDisplayItem *> *items;
@property(nonatomic, copy) NSArray<NSString *> *kinds;
@property(nonatomic, copy) NSArray<NSNumber *> *revisions;
@property(nonatomic, assign) NSUInteger generation;
@property(nonatomic, assign) NSInteger priority;
@property(nonatomic, copy) void (^completion)(NSError *);
@end
@implementation LKResourceWaiter
@end

@interface LKStaticAsyncUpdateManager ()
@property(nonatomic, strong) LKResourceSessionState *sessionState;
@property(nonatomic, copy, readwrite) NSString *snapshotID;
@property(nonatomic, strong) NSMutableDictionary<NSString *, LKResourceJob *> *jobs;
@property(nonatomic, strong) NSMutableDictionary<NSString *, LKResourceWaiter *> *waiters;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSError *> *failures;
@property(nonatomic, strong) LKInspectableApp *activeApp;
@property(nonatomic, strong) RACDisposable *subscription;
@property(nonatomic, assign) BOOL requestActive;
@property(nonatomic, assign) BOOL scheduled;
@property(nonatomic, assign) BOOL backgroundStopped;
@property(nonatomic, assign) BOOL preparing;
@property(nonatomic, assign) BOOL cancelling;
@property(nonatomic, assign) BOOL reportedComplete;
@property(nonatomic, assign) NSUInteger completedTasks;
@property(nonatomic, strong) NSMutableOrderedSet<LookinDisplayItem *> *repairCandidates;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *repairedParents;
@end

@implementation LKStaticAsyncUpdateManager

+ (instancetype)sharedInstance {
    static LKStaticAsyncUpdateManager *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [super allocWithZone:NULL]; instance = [instance init]; });
    return instance;
}
+ (id)allocWithZone:(NSZone *)zone { return self.sharedInstance; }

- (instancetype)init {
    if ((self = [super init])) {
        self.sessionState = [LKResourceSessionState new];
        self.jobs = [NSMutableDictionary dictionary]; self.waiters = [NSMutableDictionary dictionary]; self.failures = [NSMutableDictionary dictionary];
        self.repairCandidates = [NSMutableOrderedSet orderedSet]; self.repairedParents = [NSMutableSet set];
        _modifyingUpdateProgressSignal = [RACSubject subject]; _modifyingUpdateErrorSignal = [RACSubject subject]; _resourcesDidChange = [RACSubject subject];
        @weakify(self);
        [RACObserve([LKAppsManager sharedInstance], inspectingApp) subscribeNext:^(LKInspectableApp *app) {
            @strongify(self);
            if (self.activeApp && self.activeApp != app) [self cancelCurrentGenerationWithMessage:@"The app connection changed. Reload the hierarchy."];
        }];
        [[RACObserve([LKPreferenceManager mainManager], loadingMode) distinctUntilChanged] subscribeNext:^(id value) { @strongify(self); [self loadingModeDidChange]; }];
    }
    return self;
}

- (LKStaticHierarchyDataSource *)dataSource { return [LKStaticHierarchyDataSource sharedInstance]; }
- (NSString *)loadingMode { return [LKPreferenceManager mainManager].loadingMode; }
- (BOOL)isPreparingSnapshot { return self.preparing; }
- (NSString *)snapshotID { return self.sessionState.snapshotID; }
- (void)setSnapshotID:(NSString *)value { self.sessionState.snapshotID = value; }
- (NSUInteger)snapshotGeneration { return self.sessionState.generation; }
- (void)advanceSnapshotGeneration {
    [self willChangeValueForKey:@"snapshotGeneration"];
    [self.sessionState advanceGeneration];
    [self didChangeValueForKey:@"snapshotGeneration"];
}
- (NSUInteger)completedTasks { return self.sessionState.completedTasks; }
- (void)setCompletedTasks:(NSUInteger)value { self.sessionState.completedTasks = value; }
- (BOOL)requestActive { return self.sessionState.isRequestActive; }
- (void)setRequestActive:(BOOL)value { self.sessionState.isRequestActive = value; }
- (BOOL)scheduled { return self.sessionState.isScheduled; }
- (void)setScheduled:(BOOL)value { self.sessionState.isScheduled = value; }
- (BOOL)backgroundStopped { return self.sessionState.isBackgroundStopped; }
- (void)setBackgroundStopped:(BOOL)value { self.sessionState.isBackgroundStopped = value; }
- (BOOL)preparing { return self.sessionState.isPreparing; }
- (void)setPreparing:(BOOL)value { self.sessionState.isPreparing = value; }
- (BOOL)cancelling { return self.sessionState.isCancelling; }
- (void)setCancelling:(BOOL)value { self.sessionState.isCancelling = value; }
- (BOOL)reportedComplete { return self.sessionState.hasReportedComplete; }
- (void)setReportedComplete:(BOOL)value { self.sessionState.hasReportedComplete = value; }
- (NSError *)error:(NSString *)message code:(NSInteger)code { return [NSError errorWithDomain:@"LookinResources" code:code userInfo:@{NSLocalizedDescriptionKey:message}]; }
- (NSArray<NSString *> *)allKinds { return LKResourceIdentity.allKinds; }
- (NSString *)keyForItem:(LookinDisplayItem *)item kind:(NSString *)kind { return [LKResourceIdentity keyWithOid:item.layerObject.oid revision:item.resourceRevision kind:kind]; }

- (LookinResourceState)stateOf:(LookinDisplayItem *)item kind:(NSString *)kind {
    if ([kind isEqual:@"attributes"]) {
        if (item.attributesState == LookinResourceStateReady || item.attributesState == LookinResourceStateNotApplicable) return item.customAttributesState;
        return item.attributesState;
    }
    if ([kind isEqual:@"metadata"]) return item.metadataState;
    if ([kind isEqual:@"group"]) return item.groupImageState;
    return item.soloImageState;
}
- (void)setState:(LookinResourceState)state item:(LookinDisplayItem *)item kind:(NSString *)kind {
    if ([kind isEqual:@"attributes"]) { item.attributesState = state; item.customAttributesState = state; }
    else if ([kind isEqual:@"metadata"]) item.metadataState = state;
    else if ([kind isEqual:@"group"]) item.groupImageState = state;
    else item.soloImageState = state;
}
- (BOOL)ready:(LookinDisplayItem *)item kind:(NSString *)kind {
    LookinResourceState state = [self stateOf:item kind:kind];
    if (state == LookinResourceStateNotApplicable && ([kind isEqual:@"group"] || [kind isEqual:@"solo"]) && [self imageApplicable:item solo:[kind isEqual:@"solo"]]) return NO;
    return state == LookinResourceStateReady || state == LookinResourceStateNotApplicable;
}

- (void)cancelCurrentGenerationWithMessage:(NSString *)message {
    [self advanceSnapshotGeneration];
    self.preparing = YES;
    [self.subscription dispose]; self.subscription = nil;
    LKInspectableApp *oldApp = self.activeApp;
    self.activeApp = nil; self.requestActive = NO;
    [oldApp cancelHierarchyDetailFetching];
    for (LKResourceJob *job in self.jobs.allValues) if (job.revision == job.item.resourceRevision) [self setState:LookinResourceStateMissing item:job.item kind:job.kind];
    [self.jobs removeAllObjects]; [self.failures removeAllObjects];
    [self.repairCandidates removeAllObjects];
    NSArray *waiting = self.waiters.allValues; [self.waiters removeAllObjects];
    NSError *error = [self error:message code:409];
    for (LKResourceWaiter *waiter in waiting) waiter.completion(error);
    self.preparing = NO;
    [self notifyProgress];
}

- (void)prepareForSnapshot:(LookinHierarchyInfo *)info {
    [self cancelCurrentGenerationWithMessage:@"The hierarchy changed. Resolve the view again in the new snapshot."];
    self.preparing = YES; self.snapshotID = info.snapshotID ?: NSUUID.UUID.UUIDString;
    self.activeApp = [LKAppsManager sharedInstance].inspectingApp;
    self.backgroundStopped = NO; self.reportedComplete = NO; self.completedTasks = 0;
    [self.repairedParents removeAllObjects];
    NSArray *items = [LookinDisplayItem flatItemsFromHierarchicalItems:info.displayItems];
    for (LookinDisplayItem *item in items) [self initializeItem:item metadataDeferred:info.metadataDeferred];
}

- (void)initializeItem:(LookinDisplayItem *)item metadataDeferred:(BOOL)metadataDeferred {
    item.resourceRevision = 1;
    item.attributesState = item.customInfo || item.attributesGroupList != nil ? LookinResourceStateReady : LookinResourceStateMissing;
    item.customAttributesState = item.attributesState;
    item.metadataState = metadataDeferred && !item.customInfo ? LookinResourceStateMissing : LookinResourceStateReady;
    item.groupImageState = item.groupScreenshotData || item.groupScreenshot ? LookinResourceStateReady : LookinResourceStateMissing;
    item.soloImageState = item.soloScreenshotData || item.soloScreenshot ? LookinResourceStateReady : LookinResourceStateMissing;
}

- (void)startLoadingSnapshot {
    self.preparing = NO;
    [self enqueueAll]; [self schedulePump]; [self notifyProgress];
}

- (BOOL)imageApplicable:(LookinDisplayItem *)item solo:(BOOL)solo {
    CGSize size = item.frame.size;
    return !item.isUserCustom && item.layerObject.oid && item.doNotFetchScreenshotReason == LookinFetchScreenshotPermitted && isfinite(size.width) && isfinite(size.height) && size.width > 0 && size.height > 0 && size.width <= 20000 && size.height <= 20000 && (!solo || item.hasPhysicalSublayers);
}

- (void)enqueueItem:(LookinDisplayItem *)item kind:(NSString *)kind retry:(BOOL)retry {
    if (!item) return;
    // A custom node can contain an embedded screenshot/attributes. Keep those
    // resources Ready rather than replacing their state with NotApplicable.
    if ([self ready:item kind:kind]) return;
    if (item.isUserCustom || !item.layerObject.oid) { [self setState:LookinResourceStateNotApplicable item:item kind:kind]; return; }
    if (([kind isEqual:@"group"] || [kind isEqual:@"solo"]) && ![self imageApplicable:item solo:[kind isEqual:@"solo"]]) { [self setState:LookinResourceStateNotApplicable item:item kind:kind]; return; }
    if ([kind isEqual:@"metadata"] && ![self.activeApp.appInfo.capabilities containsObject:@"deferredMetadataV1"]) { item.metadataState = LookinResourceStateReady; return; }
    NSString *key = [self keyForItem:item kind:kind];
    if (self.jobs[key]) return;
    if ([self stateOf:item kind:kind] == LookinResourceStateFailed && !retry) return;
    [self.failures removeObjectForKey:key];
    LKResourceJob *job = [LKResourceJob new]; job.item = item; job.kind = kind; job.key = key; job.revision = item.resourceRevision; job.order = [self.sessionState takeNextOrder];
    self.jobs[key] = job; [self setState:LookinResourceStateLoading item:item kind:kind];
}
- (void)enqueueAll {
    if (self.preparing || self.backgroundStopped || !self.activeApp) return;
    if ([self.loadingMode isEqual:@"interactive"]) {
        LookinDisplayItem *overview = [self overviewCandidateItem];
        if (overview) [self enqueueItem:overview kind:@"group" retry:NO];
        for (LookinDisplayItem *item in self.dataSource.displayingFlatItems) [self enqueueItem:item kind:item.appropriateScreenshotResourceKind retry:NO];
        LookinDisplayItem *selected = self.dataSource.selectedItem;
        if (selected) { [self enqueueItem:selected kind:@"attributes" retry:NO]; [self enqueueItem:selected kind:@"metadata" retry:NO]; }
        return;
    }
    for (LookinDisplayItem *item in self.dataSource.rawFlatItems) for (NSString *kind in self.allKinds) [self enqueueItem:item kind:kind retry:NO];
}

- (void)pruneInteractiveJobs {
    if (![self.loadingMode isEqual:@"interactive"]) return;
    NSMutableSet *demand = [NSMutableSet set];
    for (LKResourceWaiter *waiter in self.waiters.allValues) for (LookinDisplayItem *item in waiter.items) for (NSString *kind in waiter.kinds) [demand addObject:[self keyForItem:item kind:kind]];
    for (LookinDisplayItem *item in self.dataSource.displayingFlatItems) [demand addObject:[self keyForItem:item kind:item.appropriateScreenshotResourceKind]];
    LookinDisplayItem *overview = [self overviewCandidateItem], *selected = self.dataSource.selectedItem;
    if (overview) [demand addObject:[self keyForItem:overview kind:@"group"]];
    if (selected) for (NSString *kind in @[@"attributes", @"metadata"]) [demand addObject:[self keyForItem:selected kind:kind]];
    for (LKResourceJob *job in self.jobs.allValues.copy) if (!job.active && ![demand containsObject:job.key]) {
        [self.jobs removeObjectForKey:job.key];
        if (job.revision == job.item.resourceRevision) [self setState:LookinResourceStateMissing item:job.item kind:job.kind];
    }
}

- (LookinStaticAsyncUpdateTask *)taskForJob:(LKResourceJob *)job {
    LookinStaticAsyncUpdateTask *task = [LookinStaticAsyncUpdateTask new];
    task.oid = job.item.layerObject.oid; task.frameSize = job.item.frame.size; task.clientReadableVersion = [LKHelper lookinReadableVersion];
    task.taskType = [job.kind isEqual:@"group"] ? LookinStaticAsyncUpdateTaskTypeGroupScreenshot : ([job.kind isEqual:@"solo"] ? LookinStaticAsyncUpdateTaskTypeSoloScreenshot : LookinStaticAsyncUpdateTaskTypeNoScreenshot);
    task.attrRequest = [job.kind isEqual:@"attributes"] ? LookinDetailUpdateTaskAttrRequest_Need : LookinDetailUpdateTaskAttrRequest_NotNeed;
    task.needMetadata = [job.kind isEqual:@"metadata"];
    task.forceMetadataRefresh = task.needMetadata && job.revision > 1;
    task.needBasisVisualInfo = !task.needMetadata;
    task.useCompactResources = [self.activeApp.appInfo.capabilities containsObject:@"compactResourcesV1"];
    if ([self.activeApp.appInfo.capabilities containsObject:@"resourceRevisionsV1"]) { task.snapshotID = self.snapshotID; task.resourceRevision = job.revision; }
    return task;
}

- (void)schedulePump {
    if (self.scheduled || self.preparing) return;
    self.scheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ self.scheduled = NO; [self pump]; });
}
- (void)pump {
    if (self.preparing || self.requestActive || !self.activeApp || self.activeApp != [LKAppsManager sharedInstance].inspectingApp) return;
    if (!self.jobs.count) { [self checkWaiters]; [self notifyProgress]; return; }
    // Compute demand once. Scanning every export waiter's full item list inside
    // the sort comparator otherwise makes large snapshots quadratic per packet.
    NSMutableDictionary<NSString *, NSNumber *> *priorities = [NSMutableDictionary dictionaryWithCapacity:self.jobs.count];
    for (LKResourceWaiter *waiter in self.waiters.allValues) {
        if (waiter.generation != self.snapshotGeneration) continue;
        for (LookinDisplayItem *item in waiter.items) for (NSString *kind in waiter.kinds) {
            NSString *key = [self keyForItem:item kind:kind];
            NSNumber *existing = priorities[key];
            if (!existing || waiter.priority < existing.integerValue) priorities[key] = @(waiter.priority);
        }
    }
    NSSet *displayedItems = [NSSet setWithArray:self.dataSource.displayingFlatItems ?: @[]];
    LookinDisplayItem *overview = [self overviewCandidateItem];
    LookinDisplayItem *selected = self.dataSource.selectedItem;
    NSMutableArray<LKResourceJobInput *> *inputs = [NSMutableArray arrayWithCapacity:self.jobs.count];
    for (LKResourceJob *job in self.jobs.allValues) {
        LookinDisplayItem *item = job.item;
        [inputs addObject:[[LKResourceJobInput alloc] initWithKey:job.key oid:item.layerObject.oid
            revision:job.revision currentRevision:item.resourceRevision kind:job.kind order:job.order
            active:job.active width:item.frame.size.width height:item.frame.size.height
            appropriateKind:item.appropriateScreenshotResourceKind overview:item == overview
            selected:item == selected displayed:[displayedItems containsObject:item]]];
    }
    LKResourceBatchPlan *plan = [LKResourceBatchPlanner planWithJobs:inputs priorities:priorities
        full:[self.loadingMode isEqual:@"full"] screenScale:self.activeApp.appInfo.screenScale];
    NSMutableArray<LKResourceJob *> *batch = [NSMutableArray array];
    NSMutableArray *tasks = [NSMutableArray array];
    BOOL metadata = plan.isMetadata;
    for (LKPlannedResourceTask *planned in plan.tasks) {
        LKResourceJob *job = self.jobs[planned.jobKey];
        LKResourceJob *companion = planned.companionKey ? self.jobs[planned.companionKey] : nil;
        LKResourceJob *wireJob = self.jobs[planned.wireJobKey];
        job.active = YES; [batch addObject:job];
        if (companion) { companion.active = YES; [batch addObject:companion]; }
        LookinStaticAsyncUpdateTask *task = [self taskForJob:wireJob];
        if (planned.needsAttributes) task.attrRequest = LookinDetailUpdateTaskAttrRequest_Need;
        [tasks addObject:task];
    }
    if (!batch.count) return;
    LookinStaticAsyncUpdateTasksPackage *package = [LookinStaticAsyncUpdateTasksPackage new]; package.tasks = tasks;
    // В пакете один wire-task на oid. Индекс исключает повторный просмотр
    // всего batch и всей фоновой очереди для каждого ответа.
    NSMutableDictionary<NSNumber *, NSMutableArray<LKResourceJob *> *> *jobsByOid = [NSMutableDictionary dictionary];
    for (LKResourceJob *job in batch) {
        NSNumber *oid = @(job.item.layerObject.oid);
        if (!jobsByOid[oid]) jobsByOid[oid] = [NSMutableArray array];
        [jobsByOid[oid] addObject:job];
    }
    NSUInteger generation = self.snapshotGeneration;
    self.requestActive = YES;
    RACSignal *signal = metadata ? [self.activeApp fetchMetadataWithTaskPackages:@[package]] : [self.activeApp fetchHierarchyDetailWithTaskPackages:@[package]];
    RACSerialDisposable *subscription = [RACSerialDisposable serialDisposableWithDisposable:nil];
    self.subscription = subscription;
    @weakify(self);
    subscription.disposable = [signal subscribeNext:^(NSArray<LookinDisplayItemDetail *> *details) {
        @strongify(self); if (!self || generation != self.snapshotGeneration) return;
        for (LookinDisplayItemDetail *detail in details) {
            if (generation != self.snapshotGeneration) break;
            NSMutableArray<LKResourceJob *> *matches = [NSMutableArray array];
            for (LKResourceJob *candidate in jobsByOid[@(detail.displayItemOid)]) {
                if (candidate.item.layerObject.oid != detail.displayItemOid || self.jobs[candidate.key] != candidate) continue;
                if (detail.providedFields && ![detail.providedFields containsObject:candidate.kind] && !detail.failureCode) continue;
                if (candidate.revision != candidate.item.resourceRevision || (detail.resourceRevision && detail.resourceRevision != candidate.revision) || (detail.snapshotID.length && ![detail.snapshotID isEqual:self.snapshotID])) continue;
                [matches addObject:candidate];
            }
            if (!matches.count) continue;
            // A negotiated metadata response may also refresh trace-dependent
            // attributes. Fulfil a queued consumer from that same version.
            if (!detail.failureCode && detail.providedFields) {
                LookinDisplayItem *item = ((LKResourceJob *)matches.firstObject).item;
                for (NSString *kind in detail.providedFields) {
                    LKResourceJob *candidate = self.jobs[[self keyForItem:item kind:kind]];
                    if (!candidate || [matches containsObject:candidate] || candidate.active) continue;
                    if (![detail.providedFields containsObject:candidate.kind] || candidate.revision != candidate.item.resourceRevision || candidate.revision != ((LKResourceJob *)matches.firstObject).revision) continue;
                    [matches addObject:candidate];
                }
            }
            if (!detail.failureCode) [self.dataSource modifyWithDisplayItemDetail:detail];
            for (LKResourceJob *job in matches) {
                // Model notifications can synchronously reload or modify a view.
                if (generation != self.snapshotGeneration || job.revision != job.item.resourceRevision || self.jobs[job.key] != job) continue;
                if (detail.failureCode) {
                    [self.jobs removeObjectForKey:job.key];
                    [self setState:LookinResourceStateFailed item:job.item kind:job.kind];
                    self.failures[job.key] = [self error:@"The view is no longer available in this snapshot. Reload the hierarchy." code:409];
                    LookinDisplayItem *parent = job.item.superItem;
                    if (detail.failureCode == -1 && parent && ![self.repairedParents containsObject:@(parent.layerObject.oid)]) [self.repairCandidates addObject:parent];
                } else {
                    [self.jobs removeObjectForKey:job.key];
                    BOOL emptyImage = ([job.kind isEqual:@"group"] && !detail.groupScreenshotData && !detail.groupScreenshot) || ([job.kind isEqual:@"solo"] && !detail.soloScreenshotData && !detail.soloScreenshot);
                    if (emptyImage && [self imageApplicable:job.item solo:[job.kind isEqual:@"solo"]]) {
                        [self setState:LookinResourceStateFailed item:job.item kind:job.kind];
                        self.failures[job.key] = [self error:@"The layer returned no image. Reload the layer or hierarchy before exporting a complete snapshot." code:502];
                    } else {
                        [self setState:emptyImage ? LookinResourceStateNotApplicable : LookinResourceStateReady item:job.item kind:job.kind];
                    }
                }
                self.completedTasks++;
            }
        }
        [self checkWaiters]; [self notifyProgress];
    } error:^(NSError *error) {
        @strongify(self); if (!self || generation != self.snapshotGeneration) return;
        for (LKResourceJob *job in batch) if (self.jobs[job.key] == job && job.revision == job.item.resourceRevision) {
            [self.jobs removeObjectForKey:job.key]; [self setState:LookinResourceStateFailed item:job.item kind:job.kind]; self.failures[job.key] = error;
        }
        self.requestActive = NO; [self.subscription dispose]; self.subscription = nil;
        [self checkWaiters]; [self notifyProgress]; [self schedulePump];
    } completed:^{
        @strongify(self); if (!self || generation != self.snapshotGeneration) return;
        for (LKResourceJob *job in batch) if (self.jobs[job.key] == job) {
            [self.jobs removeObjectForKey:job.key];
            if (job.revision == job.item.resourceRevision) { [self setState:LookinResourceStateFailed item:job.item kind:job.kind]; self.failures[job.key] = [self error:@"The response did not include the requested resource." code:502]; }
        }
        self.requestActive = NO; [self.subscription dispose]; self.subscription = nil;
        if ([self repairMissingSubtree]) return;
        [self enqueueAll]; [self checkWaiters]; [self notifyProgress]; [self schedulePump];
    }];
}

- (NSError *)validationErrorForItems:(NSArray<LookinDisplayItem *> *)items kinds:(NSArray<NSString *> *)kinds {
    if (self.cancelling) return [self error:@"Resource loading is being cancelled." code:499];
    LKInspectableApp *connectedApp = [LKAppsManager sharedInstance].inspectingApp;
    if (connectedApp && connectedApp != self.activeApp) return [self error:@"The connected app differs from this snapshot. Reload the hierarchy." code:409];
    for (NSString *kind in kinds) if (![self.allKinds containsObject:kind]) return [self error:@"Unknown hierarchy resource kind." code:400];
    NSSet *snapshotItems = [NSSet setWithArray:self.dataSource.rawFlatItems ?: @[]];
    for (LookinDisplayItem *item in items) if (![snapshotItems containsObject:item]) return [self error:@"The view belongs to an old snapshot." code:409];
    return nil;
}

- (NSString *)waitForItems:(NSArray<LookinDisplayItem *> *)items kinds:(NSArray<NSString *> *)kinds priority:(NSInteger)priority timeout:(NSTimeInterval)timeout completion:(void (^)(NSError *))completion {
    NSString *identifier = NSUUID.UUID.UUIDString;
    if (!self.activeApp || self.activeApp != [LKAppsManager sharedInstance].inspectingApp) { completion([self error:@"No app connected. Unloaded resources are unavailable offline." code:503]); return identifier; }
    LKResourceWaiter *waiter = [LKResourceWaiter new]; waiter.identifier = identifier; waiter.items = items; waiter.kinds = kinds; waiter.generation = self.snapshotGeneration; waiter.completion = completion;
    waiter.priority = priority;
    waiter.revisions = [items valueForKey:@"resourceRevision"];
    self.waiters[identifier] = waiter;
    for (LookinDisplayItem *item in items) for (NSString *kind in kinds) [self enqueueItem:item kind:kind retry:YES];
    [self checkWaiters]; [self schedulePump];
    if (timeout > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LKResourceWaiter *pending = self.waiters[identifier]; if (!pending) return;
        [self.waiters removeObjectForKey:identifier]; pending.completion([self error:@"Resource loading timed out. Retry or reload the hierarchy." code:408]);
    });
    return identifier;
}
- (NSString *)ensureResourcesForItem:(LookinDisplayItem *)item kinds:(NSArray<NSString *> *)kinds completion:(void (^)(NSError *))completion {
    if (!item) { completion([self error:@"The view belongs to an old snapshot." code:409]); return @""; }
    return [self ensureResourcesForItems:@[item] kinds:kinds completion:completion];
}
- (NSString *)ensureCompleteWithCompletion:(void (^)(NSError *))completion {
    NSError *validationError = [self validationErrorForItems:self.dataSource.rawFlatItems kinds:self.allKinds];
    if (validationError) { completion(validationError); return @""; }
    if (!self.snapshotID.length || !self.dataSource.rawFlatItems.count || self.preparing) { completion([self error:@"No hierarchy is ready to export." code:409]); return @""; }
    if (self.snapshotComplete) { completion(nil); return @""; }
    self.backgroundStopped = NO; [self enqueueAll];
    // Export is a completeness barrier, not an interactive request timeout.
    // Individual transport requests still have their own timeout/error handling.
    return [self waitForItems:self.dataSource.rawFlatItems kinds:self.allKinds priority:15 timeout:0 completion:completion];
}
- (NSString *)ensureResourcesForItems:(NSArray<LookinDisplayItem *> *)items kinds:(NSArray<NSString *> *)kinds completion:(void (^)(NSError *))completion {
    NSError *validationError = [self validationErrorForItems:items kinds:kinds];
    if (validationError) { completion(validationError); return @""; }
    BOOL complete = YES;
    for (LookinDisplayItem *item in items) {
        for (NSString *kind in kinds) if (![self ready:item kind:kind]) complete = NO;
    }
    if (complete) { completion(nil); return @""; }
    return [self waitForItems:items kinds:kinds priority:0 timeout:30 completion:completion];
}
- (void)cancelWaiterWithID:(NSString *)identifier {
    if (!identifier.length) return;
    LKResourceWaiter *waiter = self.waiters[identifier]; if (!waiter) return;
    [self.waiters removeObjectForKey:identifier]; waiter.completion([self error:@"Resource request cancelled." code:499]);
    [self pruneInteractiveJobs];
}
- (void)checkWaiters {
    for (LKResourceWaiter *waiter in self.waiters.allValues.copy) {
        // A previous completion may cancel another waiter or replace the snapshot.
        if (self.waiters[waiter.identifier] != waiter) continue;
        NSError *error = nil; BOOL complete = YES;
        if (waiter.generation != self.snapshotGeneration) error = [self error:@"The snapshot changed." code:409];
        for (NSUInteger i=0; i<waiter.items.count; i++) {
            LookinDisplayItem *item = waiter.items[i];
            if (item.resourceRevision != waiter.revisions[i].unsignedIntegerValue) error = [self error:@"The view changed while loading. Retry using its current state." code:409];
            for (NSString *kind in waiter.kinds) {
                if ([self stateOf:item kind:kind] == LookinResourceStateFailed) error = self.failures[[self keyForItem:item kind:kind]] ?: [self error:@"The resource could not be loaded." code:502];
                if (![self ready:item kind:kind]) complete = NO;
            }
        }
        if (complete || error) { [self.waiters removeObjectForKey:waiter.identifier]; waiter.completion(error); }
    }
}

- (BOOL)allReadyForKinds:(NSArray<NSString *> *)kinds {
    if (!self.snapshotID.length || self.preparing || !self.dataSource.rawFlatItems.count) return NO;
    for (LookinDisplayItem *item in self.dataSource.rawFlatItems) for (NSString *kind in kinds) if (![self ready:item kind:kind]) return NO;
    return YES;
}
- (BOOL)metadataComplete { return [self allReadyForKinds:@[@"attributes", @"metadata"]]; }
- (BOOL)imagesComplete { return [self allReadyForKinds:@[@"group", @"solo"]]; }
- (BOOL)snapshotComplete { return self.metadataComplete && self.imagesComplete; }
- (NSUInteger)pendingResourceCount { return self.jobs.count; }
- (NSArray<NSDictionary *> *)resourceFailures {
    if (!self.failures.count) return @[];
    NSMutableArray *result = [NSMutableArray array];
    for (LookinDisplayItem *item in self.dataSource.rawFlatItems) for (NSString *kind in self.allKinds) {
        if ([self stateOf:item kind:kind] != LookinResourceStateFailed) continue;
        NSError *error = self.failures[[self keyForItem:item kind:kind]];
        [result addObject:@{@"oid":@(item.layerObject.oid), @"kind":kind, @"code":@(error.code), @"message":error.localizedDescription ?: @"Resource unavailable"}];
        if (result.count >= 64) return result;
    }
    return result;
}
- (NSUInteger)failedResourceCount {
    if (!self.failures.count) return 0;
    NSUInteger count = 0;
    for (LookinDisplayItem *item in self.dataSource.rawFlatItems) for (NSString *kind in self.allKinds) if ([self stateOf:item kind:kind] == LookinResourceStateFailed) count++;
    return count;
}
- (NSString *)loadingState {
    if (!self.snapshotID.length) return @"empty";
    if (self.preparing || self.isUpdating || self.repairCandidates.count) return @"loading";
    if (self.failedResourceCount) return @"failed";
    if (self.snapshotComplete) return @"complete";
    return self.backgroundStopped ? @"stopped" : @"idle";
}
- (BOOL)repairMissingSubtree {
    // Ограничиваем восстановление, даже если приложение постоянно пересоздаёт UI.
    if (self.repairedParents.count >= 3) { [self.repairCandidates removeAllObjects]; return NO; }
    while (self.repairCandidates.count) {
        LookinDisplayItem *parent = self.repairCandidates.firstObject;
        [self.repairCandidates removeObjectAtIndex:0];
        if (!parent.layerObject.oid || parent.isUserCustom || ![self.dataSource.rawFlatItems containsObject:parent] || [self.repairedParents containsObject:@(parent.layerObject.oid)]) continue;
        [self.repairedParents addObject:@(parent.layerObject.oid)];
        [self reloadDisplayItemAndChildren:parent]; return YES;
    }
    return NO;
}
- (BOOL)layerTexturesReady {
    if (self.preparing || !self.snapshotID.length || !self.dataSource.displayingFlatItems.count) return NO;
    for (LookinDisplayItem *item in self.dataSource.displayingFlatItems) {
        if (item.inNoPreviewHierarchy || item.doNotFetchScreenshotReason != LookinFetchScreenshotPermitted) continue;
        if (![self ready:item kind:item.appropriateScreenshotResourceKind]) return NO;
    }
    return YES;
}
- (LookinDisplayItem *)overviewCandidateItem {
    if ([[LKPreferenceManager mainManager].loadingMode isEqual:@"full"] || self.dataSource.state == LKHierarchyDataSourceStateSearch) return nil;
    LookinDisplayItem *candidate = nil;
    if (self.dataSource.state == LKHierarchyDataSourceStateFocus) candidate = self.dataSource.displayingFlatItems.firstObject;
    else for (LookinDisplayItem *item in self.dataSource.displayingFlatItems) if (item.representedAsKeyWindow) { candidate = item; break; }
    if (!candidate || candidate.inNoPreviewHierarchy || candidate.inHiddenHierarchy || ![self imageApplicable:candidate solo:NO]) return nil;
    return candidate;
}
- (LookinDisplayItem *)progressivePreviewItem {
    if (self.preparing || !self.snapshotID.length) return nil;
    LookinDisplayItem *candidate = [self overviewCandidateItem];
    return candidate.groupImageState == LookinResourceStateReady && (candidate.groupScreenshotData || candidate.groupScreenshot) ? candidate : nil;
}
- (BOOL)previewReady { return self.layerTexturesReady || self.progressivePreviewItem != nil; }
- (void)notifyProgress {
    [self.resourcesDidChange sendNext:nil];
    [self.delegate detailUpdateTasksTotalCount:self.completedTasks + self.jobs.count finishedCount:self.completedTasks];
    if (!self.reportedComplete && self.snapshotComplete) { self.reportedComplete = YES; [LKPerformanceReporter.sharedInstance didComplete]; }
}
- (void)updateAll { [self enqueueAll]; [self schedulePump]; }
- (void)updateForDisplayingItems {
    if (self.preparing || !self.activeApp || self.activeApp != [LKAppsManager sharedInstance].inspectingApp) return;
    if ([self.loadingMode isEqual:@"interactive"]) { [self pruneInteractiveJobs]; [self enqueueAll]; [self schedulePump]; [self notifyProgress]; return; }
    for (LookinDisplayItem *item in self.dataSource.displayingFlatItems) {
        [self enqueueItem:item kind:@"attributes" retry:NO];
        [self enqueueItem:item kind:item.appropriateScreenshotResourceKind retry:NO];
    }
    LookinDisplayItem *overview = [self overviewCandidateItem];
    if (overview) [self enqueueItem:overview kind:@"group" retry:NO];
    [self schedulePump];
}
- (void)loadingModeDidChange {
    if (!self.snapshotID.length || self.preparing) return;
    self.backgroundStopped = NO;
    [self pruneInteractiveJobs];
    for (LookinDisplayItem *item in self.dataSource.rawFlatItems) for (NSString *kind in self.allKinds) if ([self stateOf:item kind:kind] == LookinResourceStateFailed) [self setState:LookinResourceStateMissing item:item kind:kind];
    [self enqueueAll]; [self schedulePump]; [self notifyProgress];
}
- (BOOL)isUpdating { return self.jobs.count > 0 || self.requestActive; }
- (void)endUpdating {
    self.backgroundStopped = YES;
    self.cancelling = YES;
    [self advanceSnapshotGeneration];
    [self.subscription dispose]; self.subscription = nil; [self.activeApp cancelHierarchyDetailFetching]; self.requestActive = NO;
    for (LKResourceJob *job in self.jobs.allValues) if (job.revision == job.item.resourceRevision) [self setState:LookinResourceStateMissing item:job.item kind:job.kind];
    [self.jobs removeAllObjects];
    NSArray *waiters = self.waiters.allValues; [self.waiters removeAllObjects];
    for (LKResourceWaiter *waiter in waiters) waiter.completion([self error:@"Loading stopped." code:499]);
    self.cancelling = NO;
    self.preparing = NO;
    [self notifyProgress];
}

- (void)invalidateItem:(LookinDisplayItem *)item attributes:(BOOL)attributes {
    if (!item || item.isUserCustom || ![self.dataSource.rawFlatItems containsObject:item]) return;
    item.resourceRevision++; self.reportedComplete = NO;
    for (NSString *kind in self.allKinds) if ([self stateOf:item kind:kind] == LookinResourceStateLoading) [self setState:LookinResourceStateMissing item:item kind:kind];
    item.groupScreenshot = nil; item.soloScreenshot = nil;
    item.groupScreenshotData = nil; item.soloScreenshotData = nil; item.groupImageState = LookinResourceStateMissing; item.soloImageState = LookinResourceStateMissing;
    if (attributes) {
        item.attributesState = LookinResourceStateMissing; item.customAttributesState = LookinResourceStateMissing;
        item.metadataState = [self.activeApp.appInfo.capabilities containsObject:@"deferredMetadataV1"] ? LookinResourceStateMissing : LookinResourceStateReady;
    }
    NSString *oidPrefix = [NSString stringWithFormat:@"%lu:", item.layerObject.oid];
    for (NSString *key in self.jobs.allKeys.copy) if (self.jobs[key].item == item) [self.jobs removeObjectForKey:key];
    for (NSString *key in self.failures.allKeys.copy) if ([key hasPrefix:oidPrefix]) [self.failures removeObjectForKey:key];
    [self checkWaiters];
    [self notifyProgress];
}
- (void)updateAfterModifyingDisplayItem:(LookinDisplayItem *)item {
    NSError *validationError = [self validationErrorForItems:item ? @[item] : @[] kinds:self.allKinds];
    if (!item || validationError || !self.activeApp) { [self.modifyingUpdateErrorSignal sendNext:validationError ?: [self error:@"The app is no longer connected." code:503]]; return; }
    [self.modifyingUpdateProgressSignal sendNext:[RACTwoTuple tupleWithObjectsFromArray:@[@0, @1]]];
    NSMutableArray *affectedItems = [NSMutableArray array];
    [item enumerateSelfAndAncestors:^(LookinDisplayItem *node, BOOL *stop) { [self invalidateItem:node attributes:NO]; [affectedItems addObject:node]; }];
    // Setter контейнера может изменить текст и layout его потомков.
    [item enumerateSelfAndChildren:^(LookinDisplayItem *node) {
        if (node == item || node.isUserCustom) return;
        [self invalidateItem:node attributes:YES];
        [affectedItems addObject:node];
    }];
    [self waitForItems:affectedItems kinds:@[@"group", @"solo"] priority:-10 timeout:30 completion:^(NSError *error) {
        [self.modifyingUpdateProgressSignal sendNext:[RACTwoTuple tupleWithObjectsFromArray:@[@1, @1]]];
        if (error) [self.modifyingUpdateErrorSignal sendNext:error];
    }];
    [self enqueueAll]; [self schedulePump];
}
- (void)reloadSingleDisplayItem:(LookinDisplayItem *)item {
    NSError *validationError = [self validationErrorForItems:item ? @[item] : @[] kinds:self.allKinds];
    if (!item || validationError || !self.activeApp || item.isUserCustom) { [self.delegate detailUpdateReceivedError:validationError ?: [self error:@"Reload the live parent layer of this item." code:409]]; return; }
    [self invalidateItem:item attributes:YES];
    [item enumerateAncestors:^(LookinDisplayItem *node, BOOL *stop) { [self invalidateItem:node attributes:NO]; [self enqueueItem:node kind:@"group" retry:YES]; [self enqueueItem:node kind:@"solo" retry:YES]; }];
    [self waitForItems:@[item] kinds:self.allKinds priority:-10 timeout:30 completion:^(NSError *error) { if (error) [self.delegate detailUpdateReceivedError:error]; }];
    [self enqueueAll]; [self schedulePump];
}
- (void)reloadDisplayItemAndChildren:(LookinDisplayItem *)item {
    NSError *validationError = [self validationErrorForItems:item ? @[item] : @[] kinds:self.allKinds];
    if (!item || validationError || !self.activeApp || item.isUserCustom) { [self.delegate detailUpdateReceivedError:validationError ?: [self error:@"Reload the live parent layer of this item." code:409]]; return; }
    // Структурный запрос отделён от ресурсной очереди и заменяет текущее поколение.
    [self endUpdating]; self.backgroundStopped = NO;
    self.preparing = YES;
    NSUInteger generation = self.snapshotGeneration;
    LookinStaticAsyncUpdateTask *task = [LookinStaticAsyncUpdateTask new]; task.oid = item.layerObject.oid; task.needSubitems = YES; task.needBasisVisualInfo = YES; task.attrRequest = LookinDetailUpdateTaskAttrRequest_NotNeed; task.clientReadableVersion = [LKHelper lookinReadableVersion];
    if ([self.activeApp.appInfo.capabilities containsObject:@"resourceRevisionsV1"]) { task.snapshotID = self.snapshotID; task.resourceRevision = item.resourceRevision; }
    LookinStaticAsyncUpdateTasksPackage *package = [LookinStaticAsyncUpdateTasksPackage new]; package.tasks = @[task];
    self.requestActive = YES;
    RACSerialDisposable *subscription = [RACSerialDisposable serialDisposableWithDisposable:nil]; self.subscription = subscription;
    __block BOOL receivedSubtree = NO;
    __block NSError *subtreeError = nil;
    subscription.disposable = [[self.activeApp fetchHierarchyDetailWithTaskPackages:@[package]] subscribeNext:^(NSArray *details) {
        if (generation != self.snapshotGeneration) return;
        for (LookinDisplayItemDetail *detail in details) {
            if (generation != self.snapshotGeneration || detail.displayItemOid != item.layerObject.oid) continue;
            if (detail.failureCode || (detail.snapshotID.length && ![detail.snapshotID isEqual:self.snapshotID]) || (detail.resourceRevision && detail.resourceRevision != item.resourceRevision) || !detail.subitems) {
                subtreeError = [self error:@"The subtree could not be refreshed. Reload the hierarchy." code:409]; continue;
            }
            receivedSubtree = YES;
            BOOL metadataDeferred = [self.activeApp.appInfo.capabilities containsObject:@"deferredMetadataV1"];
            for (LookinDisplayItem *node in [LookinDisplayItem flatItemsFromHierarchicalItems:detail.subitems]) [self initializeItem:node metadataDeferred:metadataDeferred];
            [self.dataSource modifySubtreeWithDisplayItemDetail:detail];
            if (generation != self.snapshotGeneration) return;
            [self invalidateItem:item attributes:YES];
            [item enumerateAncestors:^(LookinDisplayItem *node, BOOL *stop) { [self invalidateItem:node attributes:NO]; }];
        }
    } error:^(NSError *error) {
        if (generation != self.snapshotGeneration) return;
        self.requestActive=NO; self.preparing=NO; [self.subscription dispose]; self.subscription=nil;
        [self.delegate detailUpdateReceivedError:error]; [self enqueueAll]; [self schedulePump]; [self notifyProgress];
    } completed:^{
        if (generation != self.snapshotGeneration) return;
        self.requestActive=NO; self.preparing=NO; [self.subscription dispose]; self.subscription=nil;
        if (subtreeError || !receivedSubtree) [self.delegate detailUpdateReceivedError:subtreeError ?: [self error:@"The response did not contain the requested subtree." code:502]];
        [self enqueueAll]; [self checkWaiters]; [self schedulePump]; [self notifyProgress];
    }];
}
@end
