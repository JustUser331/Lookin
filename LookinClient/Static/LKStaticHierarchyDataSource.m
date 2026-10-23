//
//  LKStaticHierarchyDataSource.m
//  Lookin
//
//  Created by Li Kai on 2018/12/21.
//  https://lookin.work
//

#import "LKStaticHierarchyDataSource.h"
#import "LookinHierarchyInfo.h"
#import "LookinDisplayItem.h"
#import "LookinAttributesGroup.h"
#import "LookinAttribute.h"
#import "LookinAttributesSection.h"
#import "LKPreferenceManager.h"
#import "LKStaticAsyncUpdateManager.h"
#import "LookinDisplayItemDetail.h"
#import "LookinDisplayItem.h"
#import "LookinAppInfo.h"
#import "LKMessageManager.h"
#import "LKServerVersionRequestor.h"
#import "LKVersionComparer.h"
#import "LKAppsManager.h"
#import "LKDanceUIAttrMaker.h"
@import AppCenter;
@import AppCenterAnalytics;

static void LKUpdateScreenshotEligibility(LookinDisplayItem *item, CGFloat scale) {
    if (item.isUserCustom || (item.doNotFetchScreenshotReason != LookinFetchScreenshotPermitted && item.doNotFetchScreenshotReason != LookinDoNotFetchScreenshotForTooLarge)) return;
    CGSize size = item.bounds.size;
    CGFloat limit = LookinNodeImageMaxLengthInPx - 100;
    BOOL tooLarge = !isfinite(size.width) || !isfinite(size.height) || ceil(size.width * MAX(scale, 1)) > limit || ceil(size.height * MAX(scale, 1)) > limit;
    item.doNotFetchScreenshotReason = tooLarge ? LookinDoNotFetchScreenshotForTooLarge : LookinFetchScreenshotPermitted;
}

@interface LKStaticHierarchyDataSource ()

@property(nonatomic, assign) BOOL shouldIgnoreFastModeAutoUpdate;
@property(nonatomic, assign) BOOL isUsingDanceUI;
@property(nonatomic, strong) NSMapTable<LookinDisplayItem *, NSArray *> *relationsByItem;

@end

@implementation LKStaticHierarchyDataSource

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static LKStaticHierarchyDataSource *instance = nil;
    dispatch_once(&onceToken,^{
        instance = [[super allocWithZone:NULL] init];
    });
    return instance;
}

+ (id)allocWithZone:(struct _NSZone *)zone{
    return [self sharedInstance];
}

- (instancetype)init {
    if (self = [super init]) {
        _itemsDidChangeFrame = [RACSubject subject];
        _relationsByItem = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}

#pragma mark - Public

- (void)reloadWithHierarchyInfo:(LookinHierarchyInfo *)info keepState:(BOOL)keepState {
    // Hyperion пересоздаёт snapshot каждую секунду. Исключаем его окно до построения
    // дерева и запросов подробностей, иначе сохранённый oid слоя успевает устареть.
    info.displayItems = [info.displayItems lookin_filter:^BOOL(LookinDisplayItem *item) {
        return ![item.viewObject.classChainList containsObject:@"HYPSnapshotDebuggingWindow"];
    }];

    [[LKStaticAsyncUpdateManager sharedInstance] prepareForSnapshot:info];
    [self.relationsByItem removeAllObjects];

    [super reloadWithHierarchyInfo:info keepState:keepState];
    
    _appInfo = info.appInfo;
    
    NSAssert(info.appInfo.screenScale > 0, @"");
    CGFloat screenScale = MAX(info.appInfo.screenScale, 1);

    // SCNNode 的图片的长和宽均不能超过 16384px，这里再随手减掉 100，注意单位是 px 不是 pt
    [self.rawFlatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        LKUpdateScreenshotEligibility(obj, screenScale);
    }];
    
    [self updateMessageStatus];

    [[LKStaticAsyncUpdateManager sharedInstance] startLoadingSnapshot];
}

- (void)modifyWithDisplayItemDetail:(LookinDisplayItemDetail *)detail {
    [self applyDisplayItemDetail:detail replacingSubtree:NO];
}

- (void)modifySubtreeWithDisplayItemDetail:(LookinDisplayItemDetail *)detail {
    [self applyDisplayItemDetail:detail replacingSubtree:YES];
}

- (void)applyDisplayItemDetail:(LookinDisplayItemDetail *)detail replacingSubtree:(BOOL)replacingSubtree {
    if (!detail) {
        return;
    }
    LookinDisplayItem *displayItem = [self displayItemWithOid:detail.displayItemOid];
    if (!displayItem) {
        // A removed object can still have an in-flight legacy response.
        return;
    }
    LKStaticAsyncUpdateManager *coordinator = [LKStaticAsyncUpdateManager sharedInstance];
    if (detail.snapshotID.length && ![detail.snapshotID isEqual:coordinator.snapshotID]) return;
    if (detail.resourceRevision && detail.resourceRevision != displayItem.resourceRevision) return;
    if (detail.failureCode) return;
    BOOL hasAttributes = [detail.providedFields containsObject:@"attributes"] || (!detail.providedFields && detail.attributesGroupList != nil);
    BOOL hasMetadata = [detail.providedFields containsObject:@"metadata"];
    if (detail.customDisplayTitle) {
        displayItem.customDisplayTitle = detail.customDisplayTitle;
    }
    if (detail.danceUISource) {
        displayItem.danceuiSource = detail.danceUISource;
        
        if (!self.isUsingDanceUI) {
            self.isUsingDanceUI = YES;
            [MSACAnalytics trackEvent:@"UseDance"];
        }
    }
    if ([detail.providedFields containsObject:@"group"] || detail.groupScreenshotData || detail.groupScreenshot) {
        if (detail.groupScreenshotData) displayItem.groupScreenshotData = detail.groupScreenshotData;
        else { displayItem.groupScreenshotData = nil; displayItem.groupScreenshot = detail.groupScreenshot; }
    }
    if ([detail.providedFields containsObject:@"solo"] || detail.soloScreenshotData || detail.soloScreenshot) {
        if (detail.soloScreenshotData) displayItem.soloScreenshotData = detail.soloScreenshotData;
        else { displayItem.soloScreenshotData = nil; displayItem.soloScreenshot = detail.soloScreenshot; }
    }
    
    if (detail.frameValue || detail.boundsValue) {
        [self _modifyDisplayItem:displayItem newFrame:detail.frameValue ? [detail.frameValue rectValue] : displayItem.frame newBounds:detail.boundsValue ? [detail.boundsValue rectValue] : displayItem.bounds];
    }
    
    BOOL didChangeHiddenAlpha = NO;
    if (detail.hiddenValue && detail.hiddenValue.boolValue != displayItem.isHidden) {
        displayItem.isHidden = [detail.hiddenValue boolValue];
        didChangeHiddenAlpha = YES;
    }
    if (detail.alphaValue && detail.alphaValue.floatValue != displayItem.alpha) {
        displayItem.alpha = [detail.alphaValue floatValue];
        didChangeHiddenAlpha = YES;
    }
    if (didChangeHiddenAlpha) {
        [self.itemDidChangeHiddenAlphaValue sendNext:displayItem];
    }

    BOOL attrChanged = NO;
    if (hasAttributes) {
        displayItem.attributesGroupList = detail.attributesGroupList ?: @[];
        displayItem.customAttrGroupList = detail.customAttrGroupList ?: @[];
        displayItem.attributesState = LookinResourceStateReady;
        displayItem.customAttributesState = LookinResourceStateReady;
        displayItem.customDisplayTitle = detail.customDisplayTitle;
        displayItem.danceuiSource = detail.danceUISource;
        attrChanged = YES;
    }
    if (!hasAttributes && detail.customAttrGroupList.count) {
        displayItem.customAttrGroupList = detail.customAttrGroupList;
        attrChanged = YES;
    }
    if (hasMetadata) {
        unsigned long oldViewOid = displayItem.viewObject.oid;
        unsigned long oldLayerOid = displayItem.layerObject.oid;
        displayItem.viewObject = detail.viewObject;
        displayItem.layerObject = detail.layerObject ?: displayItem.layerObject;
        displayItem.hostViewControllerObject = detail.hostViewControllerObject;
        displayItem.eventHandlers = detail.eventHandlers ?: @[];
        displayItem.metadataState = LookinResourceStateReady;
        [self.relationsByItem setObject:detail.relationInfo ?: @[] forKey:displayItem];
        if (oldViewOid != displayItem.viewObject.oid || oldLayerOid != displayItem.layerObject.oid) self.rawFlatItems = self.rawFlatItems;
    }
    // Metadata can win the race against attributes (e.g. an events request).
    // Retain the relation patch and apply it after either resource arrives.
    NSArray *relations = [self.relationsByItem objectForKey:displayItem];
    if ((hasMetadata || hasAttributes) && relations && displayItem.attributesState == LookinResourceStateReady) {
        NSMutableArray *groups = [NSMutableArray array];
        for (LookinAttributesGroup *group in displayItem.attributesGroupList) if (![group.identifier isEqual:LookinAttrGroup_Relation]) [groups addObject:group];
        if (relations.count) {
            LookinAttribute *attribute = [LookinAttribute new]; attribute.identifier = LookinAttr_Relation_Relation_Relation; attribute.attrType = LookinAttrTypeCustomObj; attribute.value = relations;
            LookinAttributesSection *section = [LookinAttributesSection new]; section.identifier = LookinAttrSec_Relation_Relation; section.attributes = @[attribute];
            LookinAttributesGroup *group = [LookinAttributesGroup new]; group.identifier = LookinAttrGroup_Relation; group.attrSections = @[section]; [groups addObject:group];
        }
        displayItem.attributesGroupList = groups; attrChanged = YES;
    }
    if (hasMetadata || hasAttributes) { [displayItem notifyMetadataChangeToDelegates]; [self refreshSearchAfterMetadata]; }
    if (attrChanged) {
        [self.itemDidChangeAttrGroup sendNext:displayItem];        
    }
    if (replacingSubtree && detail.subitems) {
        self.shouldIgnoreFastModeAutoUpdate = YES;
        @try {
            CGFloat screenScale = MAX(self.appInfo.screenScale, 1);
            for (LookinDisplayItem *root in detail.subitems) {
                [root enumerateSelfAndChildren:^(LookinDisplayItem *node) {
                    BOOL inheritedCaptureBan = displayItem.doNotFetchScreenshotReason == LookinDoNotFetchScreenshotForUserConfig;
                    if (inheritedCaptureBan || (!node.isUserCustom && !node.shouldCaptureImage)) {
                        [node enumerateSelfAndChildren:^(LookinDisplayItem *child) {
                            child.noPreview = YES;
                            child.doNotFetchScreenshotReason = LookinDoNotFetchScreenshotForUserConfig;
                        }];
                    }
                    LKUpdateScreenshotEligibility(node, screenScale);
                    if (node.customInfo.danceuiSource.length) [LKDanceUIAttrMaker makeDanceUIJumpAttribute:node danceSource:node.customInfo.danceuiSource];
                }];
            }
            [self replaceSubitems:detail.subitems ofItem:displayItem];
        } @finally {
            self.shouldIgnoreFastModeAutoUpdate = NO;
        }
    }
}

- (void)buildDisplayingFlatItems {
    [super buildDisplayingFlatItems];
    if (!self.shouldIgnoreFastModeAutoUpdate) {
        [[LKStaticAsyncUpdateManager sharedInstance] updateForDisplayingItems];
    }
}

- (LKPreferenceManager *)preferenceManager {
    return [LKPreferenceManager mainManager];
}

#pragma mark - Private

- (void)_modifyDisplayItem:(LookinDisplayItem *)item newFrame:(CGRect)frame newBounds:(CGRect)bounds {
    if (!item) {
        NSAssert(NO, @"");
        return;
    }
    if (CGRectEqualToRect(item.frame, frame) && CGRectEqualToRect(item.bounds, bounds)) {
        return;
    }
    item.frame = frame;
    item.bounds = bounds;
    LKUpdateScreenshotEligibility(item, self.appInfo.screenScale);
    
    [self.itemsDidChangeFrame sendNext:item];
}

- (void)updateMessageStatus {
    if (self.serverSideIsSwiftProject && self.appInfo.swiftEnabledInLookinServer == -1) {
        [[LKMessageManager sharedInstance] addMessage:LKMessage_SwiftSubspec];
    } else {
        [[LKMessageManager sharedInstance] removeMessage:LKMessage_SwiftSubspec];
    }
    
    if ([self queryIfUsingNewestServerVersion]) {
        [[LKMessageManager sharedInstance] removeMessage:LKMessage_NewServerVersion];
    } else {
        [[LKMessageManager sharedInstance] addMessage:LKMessage_NewServerVersion];
    }
}

/// 如果 Server 端使用的是最新版，或者无法判断，那么就返回 YES
- (BOOL)queryIfUsingNewestServerVersion {
    NSString *newestVersion = [[LKServerVersionRequestor shared] query];
    if (!newestVersion) {
        return YES;
    }
    NSString *userVersion = [self.appInfo serverReadableVersion];
    if (!userVersion) {
        // LookinServer 1.2.3 之前的版本没有该字段
        return NO;
    }
    [MSACAnalytics trackEvent:@"ServerVersion" withProperties:@{@"version":userVersion}];
    BOOL isNew = [LKVersionComparer compareWithNewest:newestVersion user:userVersion];
    return isNew;
}

- (BOOL)isReadOnly {
    return NO;
}

@end
