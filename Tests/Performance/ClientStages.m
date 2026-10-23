#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <time.h>
#import <sys/resource.h>
#import <mach/mach.h>
#import <SceneKit/SceneKit.h>
#import <stdatomic.h>

// Только наблюдение: аргументы, результаты и ресурсы приложения не меняются.
static FILE *sink;
static _Atomic(unsigned long) captureRun, resourceEpoch;
static double stamp(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1e6; }
static void emitFields(NSString *event, double start, NSDictionary *extra) {
    if (!sink) return;
    NSMutableDictionary *row=[@{@"event":event,@"start_ms":@(start),@"duration_ms":@(stamp()-start),@"main":@(NSThread.isMainThread)} mutableCopy];
    [row addEntriesFromDictionary:extra ?: @{}];
    NSData *data=[NSJSONSerialization dataWithJSONObject:row options:0 error:nil];
    @synchronized(NSImage.class) { fwrite(data.bytes,1,data.length,sink); fputc('\n',sink); fflush(sink); }
}
static void emit(NSString *event, double start) { emitFields(event,start,nil); }
static NSDictionary *usage(void) {
    struct rusage cpu={0};getrusage(RUSAGE_SELF,&cpu);
    mach_task_basic_info_data_t memory={0};mach_msg_type_number_t size=MACH_TASK_BASIC_INFO_COUNT;
    task_info(mach_task_self(),MACH_TASK_BASIC_INFO,(task_info_t)&memory,&size);
    return @{@"cpu_user_ms":@(cpu.ru_utime.tv_sec*1000.0+cpu.ru_utime.tv_usec/1000.0),
             @"cpu_system_ms":@(cpu.ru_stime.tv_sec*1000.0+cpu.ru_stime.tv_usec/1000.0),
             @"resident_bytes":@(memory.resident_size),@"capture_run":@(atomic_load(&captureRun))};
}

// Callback SceneKit отделён от готовности ресурсов. Он не является GPU-present.
@interface LKStageRenderDelegate : NSObject<SCNSceneRendererDelegate>
@property(weak) id<SCNSceneRendererDelegate> original;
@property unsigned long startedEpoch, loggedEpoch;
@property double frameStart;
@end
@implementation LKStageRenderDelegate
- (BOOL)respondsToSelector:(SEL)selector { return [super respondsToSelector:selector] || [self.original respondsToSelector:selector]; }
- (id)forwardingTargetForSelector:(SEL)selector { return self.original; }
- (void)renderer:(id<SCNSceneRenderer>)renderer willRenderScene:(SCNScene *)scene atTime:(NSTimeInterval)time {
    self.startedEpoch=atomic_load(&resourceEpoch);self.frameStart=stamp();
    if([self.original respondsToSelector:_cmd])[self.original renderer:renderer willRenderScene:scene atTime:time];
}
- (void)renderer:(id<SCNSceneRenderer>)renderer didRenderScene:(SCNScene *)scene atTime:(NSTimeInterval)time {
    if([self.original respondsToSelector:_cmd])[self.original renderer:renderer didRenderScene:scene atTime:time];
    if(self.startedEpoch && self.loggedEpoch!=self.startedEpoch) {
        self.loggedEpoch=self.startedEpoch;
        emitFields(@"renderer_callback",self.frameStart,@{@"capture_run":@(atomic_load(&captureRun)),@"resource_epoch":@(self.startedEpoch),@"gpu_present_measured":@NO});
    }
}
@end
static void hookVoid(NSString *name, NSString *selector, NSString *event) {
    SEL sel=NSSelectorFromString(selector); Method method=class_getInstanceMethod(NSClassFromString(name),sel);
    if (!method) return;
    IMP old=method_getImplementation(method);
    method_setImplementation(method,imp_implementationWithBlock(^(id self) {
        double start=stamp(); ((void(*)(id,SEL))old)(self,sel); emit(event,start);
        if([event isEqual:@"notify_progress"])atomic_fetch_add(&resourceEpoch,1);
    }));
}
__attribute__((constructor)) static void install(void) { @autoreleasepool {
    NSString *path=NSProcessInfo.processInfo.environment[@"LKRENDER_LOG"];
    if (!path.length) return;
    sink=fopen(path.UTF8String,"a");
    {
        SEL selector=NSSelectorFromString(@"fetchHierarchyData");
        Method method=class_getInstanceMethod(NSClassFromString(@"LKInspectableApp"),selector);IMP original=method_getImplementation(method);
        method_setImplementation(method,imp_implementationWithBlock(^id(id self){atomic_fetch_add(&captureRun,1);emitFields(@"capture_usage_begin",stamp(),usage());return ((id(*)(id,SEL))original)(self,selector);}));
        selector=NSSelectorFromString(@"didComplete");method=class_getInstanceMethod(NSClassFromString(@"LKPerformanceReporter"),selector);original=method_getImplementation(method);
        SEL completionSelector=selector;IMP completionOriginal=original;
        method_setImplementation(method,imp_implementationWithBlock(^(id self){((void(*)(id,SEL))completionOriginal)(self,completionSelector);emitFields(@"capture_usage_end",stamp(),usage());}));
    }
    {
        SEL selector=NSSelectorFromString(@"initWithDataSource:");Method method=class_getInstanceMethod(NSClassFromString(@"LKPreviewView"),selector);IMP original=method_getImplementation(method);
        method_setImplementation(method,imp_implementationWithBlock(^id(id self,id source){
            SCNView *view=((id(*)(id,SEL,id))original)(self,selector,source);
            LKStageRenderDelegate *delegate=[LKStageRenderDelegate new];delegate.original=view.delegate;
            objc_setAssociatedObject(view,@selector(renderer:didRenderScene:atTime:),delegate,OBJC_ASSOCIATION_RETAIN_NONATOMIC);view.delegate=delegate;return view;
        }));
    }
    hookVoid(@"LKStaticAsyncUpdateManager",@"notifyProgress",@"notify_progress");
    hookVoid(@"LKStaticAsyncUpdateManager",@"pump",@"pump");
    hookVoid(@"LKStaticAsyncUpdateManager",@"checkWaiters",@"check_waiters");
    hookVoid(@"LKPreviewController",@"_updateProgressivePreview",@"preview_update");
    hookVoid(@"LKDisplayItemNode",@"_renderImageAndColor",@"node_texture");
    hookVoid(@"LKPreviewView",@"updateZPosition",@"preview_z");
    {
        SEL selector=NSSelectorFromString(@"ioFrameChannel:didReceiveFrameOfType:tag:payload:");
        Method method=class_getInstanceMethod(NSClassFromString(@"LKConnectionManager"),selector);
        IMP original=method_getImplementation(method);
        method_setImplementation(method,imp_implementationWithBlock(^(id self,id channel,uint32_t type,uint32_t tag,id payload) {
            double start=stamp();
            emitFields(@"receive_begin",start,@{@"type":@(type),@"tag":@(tag)});
            ((void(*)(id,SEL,id,uint32_t,uint32_t,id))original)(self,selector,channel,type,tag,payload);
            emitFields(@"receive",start,@{@"type":@(type),@"tag":@(tag)});
        }));
    }
    {
        SEL selector=NSSelectorFromString(@"sendFrameOfType:tag:withPayload:callback:");
        Method method=class_getInstanceMethod(NSClassFromString(@"Lookin_PTChannel"),selector);
        IMP original=method_getImplementation(method);
        method_setImplementation(method,imp_implementationWithBlock(^(id self,uint32_t type,uint32_t tag,dispatch_data_t payload,id callback) {
            double start=stamp();
            emitFields(@"send_begin",start,@{@"type":@(type),@"tag":@(tag)});
            void (^completion)(NSError *)=callback;
            id observed=completion ? ^(NSError *error){emitFields(@"send_complete",start,@{@"type":@(type),@"tag":@(tag),@"error":@(error.code)});completion(error);} : nil;
            ((void(*)(id,SEL,uint32_t,uint32_t,dispatch_data_t,id))original)(self,selector,type,tag,payload,observed);
            emitFields(@"send",start,@{@"type":@(type),@"tag":@(tag)});
        }));
    }
    {
        SEL selector=@selector(unarchivedObjectOfClass:fromData:error:);
        Method method=class_getClassMethod(NSKeyedUnarchiver.class,selector);
        IMP original=method_getImplementation(method);
        method_setImplementation(method,imp_implementationWithBlock(^id(id self,Class type,NSData *data,NSError **error) {
            double start=stamp();
            id result=((id(*)(id,SEL,Class,id,NSError **))original)(self,selector,type,data,error);
            emitFields(@"unarchive",start,@{@"bytes":@(data.length)}); return result;
        }));
    }
    for (NSString *name in @[@"groupScreenshot",@"soloScreenshot"]) {
        SEL selector=NSSelectorFromString(name);
        Method method=class_getInstanceMethod(NSClassFromString(@"LookinDisplayItem"),selector);
        IMP original=method_getImplementation(method);
        method_setImplementation(method,imp_implementationWithBlock(^id(id self) {
            double start=stamp();id result=((id(*)(id,SEL))original)(self,selector);
            if(stamp()-start>.05)emit(name,start);return result;
        }));
    }
    SEL sel=@selector(TIFFRepresentation); Method method=class_getInstanceMethod(NSImage.class,sel); IMP old=method_getImplementation(method);
    method_setImplementation(method,imp_implementationWithBlock(^id(id self) {
        double start=stamp(); id data=((id(*)(id,SEL))old)(self,sel); emit(@"tiff",start); return data;
    }));
}}
