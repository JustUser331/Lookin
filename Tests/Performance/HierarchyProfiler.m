#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <time.h>
#import <unistd.h>
#import <math.h>

// Measurement only: no preferences, image conversion, network calls, UI actions,
// or changes to arguments/results. All model observation runs on the main thread.
static FILE *sink;
static id benchmarkActivity;
static NSUInteger runID;
static double start, wireStart, firstFrame, applyStart, applyEnd, decodeMS;
static double detailDecodeMS, detailApplyMS;
static NSUInteger detailFrames, detailBytes;
static BOOL treeReady, finished;
static NSMutableSet<NSString *> *milestones;
static NSMutableDictionary *lastLegacyWork;
static __thread uint32_t receivingType;
static __thread NSUInteger decodeDepth;
static double now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }
static id get(id object, NSString *key) {
    if (!object || ![object respondsToSelector:NSSelectorFromString(key)]) return nil;
    return [object valueForKey:key];
}
static id singleton(NSString *name) {
    Class cls = NSClassFromString(name);
    return [cls respondsToSelector:@selector(sharedInstance)] ? ((id(*)(id,SEL))objc_msgSend)(cls,@selector(sharedInstance)) : nil;
}
static id storedImage(id item, NSString *kind) {
    // Reading the ivar is intentional: the candidate's public getter can decode PNG.
    Ivar ivar = class_getInstanceVariable([item class], [[@"_" stringByAppendingString:kind] UTF8String]);
    return ivar ? object_getIvar(item, ivar) : nil;
}
static BOOL hasImage(id item, NSString *kind) {
    return [get(item,[kind stringByAppendingString:@"Data"]) length] > 0 || storedImage(item,kind) != nil;
}
static NSArray *allItems(id source) { return get(source,@"rawFlatItems") ?: get(source,@"flatItems") ?: @[]; }
static NSDictionary *previewRequirements(void) {
    id source=singleton(@"LKStaticHierarchyDataSource");
    NSArray *visible=get(source,@"displayingFlatItems") ?: @[];
    id preferences=get(source,@"preferenceManager");
    BOOL showHidden=[get(get(preferences,@"showHiddenItems"),@"currentBOOLValue") boolValue];
    NSUInteger required=0, custom=0, hidden=0, excluded=0, empty=0;
    NSMutableArray *missing=[NSMutableArray array];
    for(id item in visible) {
        // LKPreviewController filters no-preview branches; LKDisplayItemNode
        // renders collapsed Quick Selection nodes as borders without textures.
        if([get(item,@"inNoPreviewHierarchy") boolValue] || ![get(item,@"displayingInHierarchy") boolValue] ||
           [get(item,@"doNotFetchScreenshotReason") integerValue]!=0) {excluded++;continue;}
        if([get(item,@"inHiddenHierarchy") boolValue] && !showHidden) {hidden++;continue;}
        // Custom nodes carry their optional image in the hierarchy and have no
        // async texture request. A frame-only custom node is already renderable.
        if(get(item,@"customInfo")) {custom++;continue;}
        CGRect frame=CGRectZero; NSValue *value=get(item,@"frame");
        if(value)[value getValue:&frame size:sizeof(frame)];
        if(!isfinite(frame.size.width)||!isfinite(frame.size.height)||frame.size.width<=0||frame.size.height<=0) {empty++;continue;}
        BOOL solo=[get(item,@"isExpandable") boolValue] && [get(item,@"isExpanded") boolValue];
        BOOL hasLayerChild=NO;
        for(id child in get(item,@"subitems")) if(!get(child,@"customInfo") && [get(get(child,@"layerObject"),@"oid") unsignedLongLongValue]) {hasLayerChild=YES;break;}
        // A real leaf can have virtual children. There is no real solo capture
        // for such a layer, so its only texture resource is its group image.
        solo=solo && hasLayerChild;
        NSString *kind=solo ? @"soloScreenshot" : @"groupScreenshot";
        required++;
        if(!hasImage(item,kind)) [missing addObject:@{@"oid":get(get(item,@"layerObject"),@"oid") ?: @0,
            @"title":get(item,@"title") ?: @"",@"kind":solo ? @"solo" : @"group"}];
    }
    return @{@"ready":@(visible.count>0 && missing.count==0),@"required_textures":@(required),
        @"custom_geometry_or_embedded_image":@(custom),@"hidden":@(hidden),@"excluded":@(excluded),
        @"empty_geometry":@(empty),@"showHiddenItems":@(showHidden),@"missing":missing};
}
static NSDictionary *coverage(void) {
    id source = singleton(@"LKStaticHierarchyDataSource");
    NSArray *items = allItems(source);
    NSUInteger real=0, custom=0, attrs=0, customAttrs=0, group=0, solo=0, pngBytes=0;
    NSMutableDictionary *states = [NSMutableDictionary dictionary];
    NSArray *stateKeys = @[@"attributesState",@"customAttributesState",@"metadataState",@"groupImageState",@"soloImageState"];
    for (id item in items) {
        real += [get(get(item,@"layerObject"),@"oid") unsignedLongLongValue] != 0;
        custom += get(item,@"customInfo") != nil;
        attrs += [get(item,@"attributesGroupList") count] > 0;
        customAttrs += [get(item,@"customAttrGroupList") count] > 0;
        group += hasImage(item,@"groupScreenshot"); solo += hasImage(item,@"soloScreenshot");
        pngBytes += [get(item,@"groupScreenshotData") length] + [get(item,@"soloScreenshotData") length];
        for (NSString *key in stateKeys) {
            NSNumber *state = get(item,key); if (!state) continue;
            NSMutableDictionary *counts = states[key];
            if (!counts) states[key] = counts = [NSMutableDictionary dictionary];
            NSString *name = state.stringValue; counts[name] = @([counts[name] unsignedIntegerValue]+1);
        }
    }
    return @{@"nodes":@(items.count), @"physical_nodes":@(real), @"custom_nodes":@(custom),
             @"displaying_items":@([get(source,@"displayingFlatItems") count]),
             @"attr_nonempty_nodes":@(attrs), @"custom_attr_nonempty_nodes":@(customAttrs),
             @"group_images":@(group), @"solo_images":@(solo), @"retained_png_bytes":@(pngBytes), @"resource_states":states,
             @"preview_requirements":previewRequirements()};
}
static void emit(NSString *event, NSDictionary *extra) {
    if (!sink) return;
    NSMutableDictionary *row = [@{@"event":event,@"run":@(runID),@"pid":@(getpid()),
        @"monotonic_ms":@(now()),@"elapsed_ms":start ? @(now()-start) : @0} mutableCopy];
    if (extra) [row addEntriesFromDictionary:extra];
    NSData *data = [NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];
    flockfile(sink); fwrite(data.bytes,1,data.length,sink); fputc('\n',sink); fflush(sink); funlockfile(sink);
}
static BOOL candidate(void) { return class_getInstanceMethod(NSClassFromString(@"LKStaticAsyncUpdateManager"),NSSelectorFromString(@"snapshotComplete")) != NULL; }
static void milestone(NSString *name, NSDictionary *extra) {
    if ([milestones containsObject:name]) return;
    [milestones addObject:name]; emit(name,extra);
}
static void observe(void) {
    if (!treeReady || finished) return;
    id manager = singleton(@"LKStaticAsyncUpdateManager");
    if (candidate()) {
        if([get(manager,@"previewReady") boolValue]) milestone(@"coordinatorPreviewReady",nil);
        for (NSString *key in @[@"metadataComplete",@"imagesComplete"])
            if ([get(manager,key) boolValue]) milestone(key,nil);
    }
    if(![milestones containsObject:@"previewReady"] && [previewRequirements()[@"ready"] boolValue])
        milestone(@"previewReady",@{@"basis":@"same visible physical texture predicate for both clients; custom/hidden/empty geometry does not request PNG; GPU presentation not measured"});
}
static void begin(void) {
    if (start && !finished) emit(@"abandoned",@{@"reason":@"another hierarchy request started"});
    runID++; start=now(); wireStart=firstFrame=applyStart=applyEnd=decodeMS=0;
    detailDecodeMS=detailApplyMS=0; detailFrames=detailBytes=0; treeReady=finished=NO;
    milestones=[NSMutableSet set]; lastLegacyWork=nil;
    id preferences = ((id(*)(id,SEL))objc_msgSend)(NSClassFromString(@"LKPreferenceManager"),NSSelectorFromString(@"mainManager"));
    NSMutableDictionary *info=[NSMutableDictionary dictionary];
    info[@"implementation"] = candidate() ? @"candidate" : @"baseline";
    info[@"loadingMode"] = get(preferences,@"loadingMode") ?: @"legacy";
    info[@"app_active"] = @(NSApp.isActive);
    info[@"thermal_state"] = @(NSProcessInfo.processInfo.thermalState);
    id fast=get(preferences,@"fastMode");
    info[@"legacyFastMode"] = get(fast,@"currentBOOLValue") ?: [NSNull null];
    emit(@"request_start",info);
}
static Method lookup(NSString *cls, NSString *name, BOOL classMethod) {
    Method m=classMethod ? class_getClassMethod(NSClassFromString(cls),NSSelectorFromString(name)) : class_getInstanceMethod(NSClassFromString(cls),NSSelectorFromString(name));
    if (!m) emit(@"hook_missing",@{@"class":cls,@"selector":name});
    return m;
}
static void hookVoid(NSString *cls, NSString *name, void(^after)(id)) {
    SEL sel=NSSelectorFromString(name); Method m=lookup(cls,name,NO); if(!m)return; IMP old=method_getImplementation(m);
    method_setImplementation(m,imp_implementationWithBlock(^(id obj){ ((void(*)(id,SEL))old)(obj,sel); after(obj); }));
}
__attribute__((constructor)) static void install(void) { @autoreleasepool {
    NSString *path=NSProcessInfo.processInfo.environment[@"LKPERF_CLIENT_LOG"];
    if(!path.length)return;
    benchmarkActivity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep reason:@"Bounded Lookin hierarchy benchmark"];
    sink=fopen(path.UTF8String,"a");
    emit(@"profiler_installed",@{@"format":@2,@"executable":NSBundle.mainBundle.executablePath ?: @"",
        @"bundle_id":NSBundle.mainBundle.bundleIdentifier ?: @"",@"measurement_only":@YES,@"app_nap_suppressed":@YES});
    {
        SEL sel=NSSelectorFromString(@"fetchHierarchyData"); Method m=lookup(@"LKInspectableApp",NSStringFromSelector(sel),NO);
        if(m){ IMP old=method_getImplementation(m); method_setImplementation(m,imp_implementationWithBlock(^id(id obj){begin();return ((id(*)(id,SEL))old)(obj,sel);})); }
    }
    {
        SEL sel=NSSelectorFromString(@"_requestWithType:channel:data:timeoutInterval:succ:fail:completion:"); Method m=lookup(@"LKConnectionManager",NSStringFromSelector(sel),NO);
        if(m){ IMP old=method_getImplementation(m); char type[8]={0}; method_getReturnType(m,type,sizeof(type));
            void(^before)(uint32_t)=^(uint32_t requestType){if(requestType==202){if(!start||finished)begin();wireStart=now();emit(@"wire_request",nil);}};
            if(type[0]=='v') method_setImplementation(m,imp_implementationWithBlock(^(id obj,uint32_t requestType,id channel,id data,double timeout,id succ,id fail,id complete){before(requestType);((void(*)(id,SEL,uint32_t,id,id,double,id,id,id))old)(obj,sel,requestType,channel,data,timeout,succ,fail,complete);}));
            else method_setImplementation(m,imp_implementationWithBlock(^id(id obj,uint32_t requestType,id channel,id data,double timeout,id succ,id fail,id complete){before(requestType);return ((id(*)(id,SEL,uint32_t,id,id,double,id,id,id))old)(obj,sel,requestType,channel,data,timeout,succ,fail,complete);}));
        }
    }
    {
        SEL sel=NSSelectorFromString(@"ioFrameChannel:didReceiveFrameOfType:tag:payload:"); Method m=lookup(@"LKConnectionManager",NSStringFromSelector(sel),NO);
        if(m){ IMP old=method_getImplementation(m); method_setImplementation(m,imp_implementationWithBlock(^(id obj,id channel,uint32_t type,uint32_t tag,id payload){
            uint32_t previous=receivingType; receivingType=type;
            if(type==202 && start && !firstFrame){firstFrame=now();emit(@"hierarchy_frame",@{@"tag":@(tag),@"server_transport_ms":@(firstFrame-wireStart)});}
            if((type==203||type==215) && start && !finished){ detailFrames++; detailBytes+=[get(payload,@"length") unsignedIntegerValue]; }
            ((void(*)(id,SEL,id,uint32_t,uint32_t,id))old)(obj,sel,channel,type,tag,payload);
            receivingType=previous; observe();
        })); }
    }
    {
        SEL sel=@selector(unarchivedObjectOfClass:fromData:error:); Method m=class_getClassMethod(NSKeyedUnarchiver.class,sel); IMP old=method_getImplementation(m);
        method_setImplementation(m,imp_implementationWithBlock(^id(id cls,Class objectClass,NSData *data,NSError **error){
            BOOL tracked=receivingType==202||receivingType==203||receivingType==215;
            BOOL outer=tracked && decodeDepth++==0; double t=now();
            id result=((id(*)(id,SEL,Class,id,NSError **))old)(cls,sel,objectClass,data,error);
            if(outer){double duration=now()-t;if(receivingType==202)decodeMS+=duration;else detailDecodeMS+=duration;}
            if(tracked)decodeDepth--;return result;
        }));
    }
    if(class_getClassMethod(NSClassFromString(@"LookinHierarchyInfo"),NSSelectorFromString(@"hierarchyFromCompactJSONData:error:"))) {
        SEL sel=NSSelectorFromString(@"hierarchyFromCompactJSONData:error:"); Method m=lookup(@"LookinHierarchyInfo",NSStringFromSelector(sel),YES); IMP old=method_getImplementation(m);
        method_setImplementation(m,imp_implementationWithBlock(^id(id cls,id data,NSError **error){
            double t=now(); decodeDepth++; id result=((id(*)(id,SEL,id,NSError **))old)(cls,sel,data,error); decodeDepth--; decodeMS+=now()-t; return result;
        }));
    }
    {
        SEL sel=NSSelectorFromString(@"reloadWithHierarchyInfo:keepState:"); Method m=lookup(@"LKStaticHierarchyDataSource",NSStringFromSelector(sel),NO);
        if(m){IMP old=method_getImplementation(m);method_setImplementation(m,imp_implementationWithBlock(^(id obj,id info,BOOL keep){
            double t=now(); if(start&&!finished)applyStart=t;
            ((void(*)(id,SEL,id,BOOL))old)(obj,sel,info,keep);
            if(!start||finished)return; applyEnd=now(); treeReady=YES;
            milestone(@"treeReady",@{@"elapsed_ms":@(applyEnd-start),@"client_apply_ms":@(applyEnd-t),@"client_decode_ms":@(decodeMS),
                @"frame_to_apply_ms":firstFrame ? @(applyEnd-firstFrame) : NSNull.null,
                @"snapshotID":get(info,@"snapshotID") ?: NSNull.null,@"coverage":coverage()}); observe();
        }));}
    }
    {
        SEL sel=NSSelectorFromString(@"modifyWithDisplayItemDetail:"); Method m=lookup(@"LKStaticHierarchyDataSource",NSStringFromSelector(sel),NO);
        if(m){IMP old=method_getImplementation(m);method_setImplementation(m,imp_implementationWithBlock(^(id obj,id detail){double t=now();((void(*)(id,SEL,id))old)(obj,sel,detail);if(start&&!finished)detailApplyMS+=now()-t;}));}
    }
    if(!candidate()) hookVoid(@"LKStaticAsyncUpdateManager",@"notifyTasksCountToDelegate",^(id obj){
        id request=get(obj,@"ongoingRequest"); if(request)lastLegacyWork=[@{
            @"total":get(request,@"tasksTotalCount") ?: @0,@"finished":get(request,@"finishedTasksCount") ?: @0,
            @"failed":get(request,@"failedTasksCount") ?: @0} mutableCopy];
    });
    hookVoid(@"LKPerformanceReporter",@"didComplete",^(id obj){
        if(!treeReady||finished)return;observe();double completedAt=now();
        BOOL complete=candidate() ? [get(singleton(@"LKStaticAsyncUpdateManager"),@"snapshotComplete") boolValue] :
            lastLegacyWork && [lastLegacyWork[@"total"] unsignedIntegerValue]>0 && [lastLegacyWork[@"total"] isEqual:lastLegacyWork[@"finished"]] && ![lastLegacyWork[@"failed"] unsignedIntegerValue];
        if(!candidate()&&complete){milestone(@"metadataComplete",@{@"elapsed_ms":@(completedAt-start),@"basis":@"upper bound: legacy exposes no independent metadata readiness"});milestone(@"imagesComplete",@{@"elapsed_ms":@(completedAt-start),@"basis":@"legacy requested tasks completed without reported failures"});}
        emit(@"complete",@{@"elapsed_ms":@(completedAt-start),@"verified_scheduler_complete":@(complete),@"coverage":coverage(),
            @"legacy_work":lastLegacyWork ?: @{},@"detail_frames":@(detailFrames),@"detail_bytes_if_available":@(detailBytes),
            @"detail_decode_ms":@(detailDecodeMS),@"detail_apply_ms":@(detailApplyMS),
            @"client_decode_ms":@(decodeMS),@"client_apply_ms":@(applyEnd-applyStart)});finished=YES;
    });
}}
