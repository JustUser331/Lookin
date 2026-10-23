//
//  LKStaticAsyncUpdateManager.h
//  Lookin
//
//  Created by Li Kai on 2019/2/19.
//  https://lookin.work
//

#import <Foundation/Foundation.h>

@class LookinDisplayItem, LookinStaticDisplayItem;
@class LookinHierarchyInfo;

@protocol LKStaticAsyncUpdateManagerDelegate <NSObject>

/// 当剩余未完成的 task 数量变化时，该方法会被调用。表示当前一共有 totalCount 个任务，其中 finishedCount 已经完成。
- (void)detailUpdateTasksTotalCount:(NSUInteger)totalCount finishedCount:(NSUInteger)finishedCount;

- (void)detailUpdateReceivedError:(NSError *)error;

@end

@interface LKStaticAsyncUpdateManager : NSObject

+ (instancetype)sharedInstance;

@property(nonatomic, copy, readonly) NSString *snapshotID;
@property(nonatomic, readonly) NSUInteger snapshotGeneration;
@property(nonatomic, readonly) BOOL metadataComplete;
@property(nonatomic, readonly) BOOL imagesComplete;
@property(nonatomic, readonly) BOOL snapshotComplete;
@property(nonatomic, readonly) NSUInteger pendingResourceCount;
@property(nonatomic, readonly) NSUInteger failedResourceCount;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *resourceFailures;
@property(nonatomic, copy, readonly) NSString *loadingState;
@property(nonatomic, readonly) BOOL previewReady;
@property(nonatomic, readonly, getter=isPreparingSnapshot) BOOL preparingSnapshot;
@property(nonatomic, readonly) BOOL layerTexturesReady;
/// Temporary native group image for the current window or focused subtree.
@property(nonatomic, strong, readonly) LookinDisplayItem *progressivePreviewItem;
@property(nonatomic, copy, readonly) NSString *loadingMode;
@property(nonatomic, strong, readonly) RACSubject *resourcesDidChange;
- (void)prepareForSnapshot:(LookinHierarchyInfo *)info;
- (void)startLoadingSnapshot;
- (void)loadingModeDidChange;
- (NSString *)ensureResourcesForItem:(LookinDisplayItem *)item kinds:(NSArray<NSString *> *)kinds completion:(void (^)(NSError *error))completion NS_SWIFT_NAME(ensureResources(for:kinds:completion:));
- (NSString *)ensureResourcesForItems:(NSArray<LookinDisplayItem *> *)items kinds:(NSArray<NSString *> *)kinds completion:(void (^)(NSError *error))completion NS_SWIFT_NAME(ensureResources(forItems:kinds:completion:));
- (NSString *)ensureCompleteWithCompletion:(void (^)(NSError *error))completion;
- (void)cancelWaiterWithID:(NSString *)identifier NS_SWIFT_NAME(cancelWaiter(id:));
- (void)invalidateItem:(LookinDisplayItem *)item attributes:(BOOL)attributes;

@property(nonatomic, weak) id<LKStaticAsyncUpdateManagerDelegate> delegate;

/// 关闭“极速模式”时，reload 之后应该调用该方法来拉取所有 items 的 detail 数据
- (void)updateAll;

/// 打开“极速模式”时，每次 displayingItems 变化时，都应该调用该方法来拉取可见 items 的 detail 数据（已经拉取过 detail 的 items 不会再次被拉取）
- (void)updateForDisplayingItems;

/// 终止拉取
- (void)endUpdating;

- (void)updateAfterModifyingDisplayItem:(LookinDisplayItem *)displayItem;
/// updateAfterModifyingDisplayItem 的更新进度，data 是 RACTwoTuple<NSNumber *>，分别为已经收到的图像数量、总的图像数量
@property(nonatomic, strong, readonly) RACSubject *modifyingUpdateProgressSignal;
/// updateAfterModifyingDisplayItem 遇到了错误，data 为 NSError
@property(nonatomic, strong, readonly) RACSubject *modifyingUpdateErrorSignal;

- (BOOL)isUpdating;

/// 重新拉取一个 displayItem 的数据（图像+Attr），不包括子图层
- (void)reloadSingleDisplayItem:(LookinDisplayItem *)item;
- (void)reloadDisplayItemAndChildren:(LookinDisplayItem *)rootItem;

@end
