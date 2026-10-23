#import <AppKit/AppKit.h>
#import <LookinShared/LookinShared-umbrella.h>
#import <time.h>
@interface LookinDisplayItem (GeometryTesting)
- (CGRect)calculateFrameToRoot;
@end
@implementation LookinDisplayItem (GeometryTesting)
#include "FrameFormula.inc"
@end
@interface GeometryBefore : NSObject
@property(copy) NSArray<LookinDisplayItem *> *flatDisplayItems;
@property BOOL showHiddenItems;
@property NSUInteger updates;
@end
@implementation GeometryBefore
- (void)_updateZPositionByZIndex { self.updates++; }
#include "GeometryBefore.inc"
@end
@interface GeometryAfter : GeometryBefore
@end
@implementation GeometryAfter
#include "GeometryAfter.inc"
@end
static NSUInteger checks;
#define CHECK(value,message) do {checks++;if(!(value)){fprintf(stderr,"FAIL: %s\n",message);exit(1);}}while(0)
int main(void) { @autoreleasepool {
    NSMutableArray *roots=[NSMutableArray array];
    for (NSUInteger i=0;i<100;i++) {
        LookinDisplayItem *root=[LookinDisplayItem new]; root.frame=CGRectMake((i%10)*20,(i/10)*20,100,100); root.bounds=CGRectMake(2,-3,100,100);
        LookinDisplayItem *parent=root;
        for (NSUInteger depth=0;depth<9;depth++) { LookinDisplayItem *child=[LookinDisplayItem new]; child.frame=CGRectMake((CGFloat)depth-3,depth*2,80-depth*2,70); child.bounds=CGRectMake(-1,2,80-depth*2,70); parent.subitems=@[child]; parent=child; }
        [roots addObject:root];
    }
    LookinDisplayItem *custom=[LookinDisplayItem new]; custom.customInfo=[LookinCustomDisplayItemInfo new]; custom.customInfo.frameInWindow=[NSValue valueWithRect:CGRectMake(-10,4,200,50)]; [roots addObject:custom];
    NSArray *items=[LookinDisplayItem flatItemsFromHierarchicalItems:roots]; GeometryBefore *before=[GeometryBefore new]; GeometryAfter *after=[GeometryAfter new]; before.flatDisplayItems=items; after.flatDisplayItems=items;
    for (NSUInteger scenario=0;scenario<5;scenario++) {
        for (NSUInteger i=0;i<items.count;i++) { LookinDisplayItem *item=items[i]; item.alpha=1; item.isExpanded=scenario!=1 || i%4!=0; item.isHidden=scenario==2 && i%13==0; }
        before.showHiddenItems=after.showHiddenItems=scenario==3;
        if (scenario==4) { ((LookinDisplayItem *)roots[3]).frame=CGRectMake(500,200,50,75); ((LookinDisplayItem *)roots[8]).bounds=CGRectMake(30,40,100,100); }
        double start=clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1e6; [before updateZPosition]; double oldTime=clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1e6-start;
        NSArray *expected=[items valueForKey:@"previewZIndex"]; start=clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1e6; [after updateZPosition]; double newTime=clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1e6-start;
        CHECK([expected isEqual:[items valueForKey:@"previewZIndex"]],"production Z matches original for expansion, hidden, scrolling and custom geometry");
        printf("GEOMETRY scenario=%lu nodes=%lu before_ms=%.3f after_ms=%.3f\n",scenario,items.count,oldTime,newTime);
    }
    CHECK(after.updates==5,"position and tie-breaking stage is still invoked"); printf("PASS: %lu geometry assertions\n",checks); return 0;
}}
