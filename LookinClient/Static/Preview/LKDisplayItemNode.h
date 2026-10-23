//
//  LKDisplayItemNode.h
//  Lookin
//
//  Created by Li Kai on 2019/8/17.
//  https://lookin.work
//

#import <SceneKit/SceneKit.h>

@class LookinDisplayItem, LKPreferenceManager, LKHierarchyDataSource;
@class LKPreviewImageCache;

@interface LKDisplayItemNode : SCNNode

- (instancetype)initWithDataSource:(LKHierarchyDataSource *)dataSource;

/// 在全部 displayItems 里的 idx
@property(nonatomic, assign) NSUInteger index;

@property(nonatomic, assign) CGSize screenSize;

@property(nonatomic, weak) LKPreferenceManager *preferenceManager;

@property(nonatomic, strong) LookinDisplayItem *displayItem;
@property(nonatomic, strong) LKPreviewImageCache *imageCache;

@property(nonatomic, assign) BOOL isDarkMode;
/// 0: normal; 1: render native group overview; 2: retain only geometry/borders.
@property(nonatomic, assign) NSInteger progressiveTextureMode;

@end
