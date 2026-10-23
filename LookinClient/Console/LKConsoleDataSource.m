//
//  LKConsoleDataSource.m
//  Lookin
//
//  Created by Li Kai on 2019/6/1.
//  https://lookin.work
//

#import "LKConsoleDataSource.h"
#import "LKConsoleDataSourceRowItem.h"
#import "LKStaticHierarchyDataSource.h"
#import "LookinDisplayItem.h"
#import "LKAppsManager.h"
#import "LKPreferenceManager.h"
#import "LKStaticAsyncUpdateManager.h"

@interface LKConsoleDataSource ()

/**
 @{
     @"UIView": @{
         @"selector": @[@"layoutSubviews", ...],
         @"ivar": @[@"_name", ...]
     },
     @"UIViewController": @{
         @"selector": @[@"viewDidAppear:", ...],
         @"ivar": @[@"_didAppear", ...]
     },
     ...
 };
 */
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSArray<NSString *> *> *classesToSelsDict;
@property(nonatomic, strong, readwrite) LookinObject *currentObject;
@property(nonatomic, strong, readwrite) NSArray<LookinObject *> *selectedObjects;
@property(nonatomic, weak) LKHierarchyDataSource *hierarchyDataSource;
@property(nonatomic, assign) NSUInteger contextVersion;
@property(nonatomic, assign) NSUInteger objectSelectionVersion;

@end

@implementation LKConsoleDataSource

- (instancetype)initWithHierarchyDataSource:(LKHierarchyDataSource *)hierarchyDataSource {
    if (self = [self init]) {
        self.hierarchyDataSource = hierarchyDataSource;
        self.classesToSelsDict = [NSMutableDictionary dictionary];
        
        LKConsoleDataSourceRowItem *item = [LKConsoleDataSourceRowItem new];
        item.type = LKConsoleDataSourceRowItemTypeInput;
        self.rowItems = @[item];
        
        RAC(self, selectedObjects) = [RACObserve(hierarchyDataSource, selectedItem)
                                      map:^id _Nullable(LookinDisplayItem *item) {
                                          if (!item) {
                                              return nil;
                                          }
                                          NSArray<LookinObject *> *objs = $(item.hostViewControllerObject, item.layerObject, item.viewObject).array;
                                          return objs;
                                      }];
        if (!hierarchyDataSource.isReadOnly) {
            @weakify(self);
            [[LKStaticAsyncUpdateManager sharedInstance].resourcesDidChange subscribeNext:^(id value) {
                @strongify(self);
                LookinDisplayItem *selected = hierarchyDataSource.selectedItem;
                if (selected && self.isShowingConsole) {
                    NSArray *objects = $(selected.hostViewControllerObject, selected.layerObject, selected.viewObject).array;
                    if (![self.selectedObjects isEqualToArray:objects]) self.selectedObjects = objects;
                }
            }];
            [hierarchyDataSource.willReloadHierarchyInfo subscribeNext:^(id value) {
                @strongify(self);
                self.contextVersion++; self.objectSelectionVersion++;
                [self.classesToSelsDict removeAllObjects]; self.currentObject = nil;
                [self willChangeValueForKey:@"recentObjects"];
                self->_recentObjects = [NSMutableArray array];
                [self didChangeValueForKey:@"recentObjects"];
            }];
        }
    }
    return self;
}

- (RACSignal *)submit:(NSString *)text {
    return [self submitWithObj:self.currentObject text:text];
}

- (RACSignal *)submitWithObj:(LookinObject *)obj text:(NSString *)text {
    if (self.hierarchyDataSource.isReadOnly || ![LKStaticAsyncUpdateManager sharedInstance].snapshotID.length) return [RACSignal error:LookinErr_NoConnect];
    if (!obj) {
        return [RACSignal error:LookinErr_Inner];
    }
    if (!text.length) {
        return [RACSignal error:LookinErrorMake(NSLocalizedString(@"Content is empty.", nil), @"")];
    }
    if (![LKAppsManager sharedInstance].inspectingApp) {
        return [RACSignal error:LookinErr_NoConnect];
    }
    if ([text containsString:@":"]) {
        NSString *className = obj.rawClassName;
        NSString *address = obj.memoryAddress;
        NSString *errDesc = [NSString stringWithFormat:NSLocalizedString(@"You can click \"Pause\" button near the bottom-left corner in Xcode to pause your iOS app, and input in Xcode console like the contents below:\nexpr [((%@ *)%@) %@]", nil), className, address, text];
        return [RACSignal error:LookinErrorMake(NSLocalizedString(@"Lookin doesn't support invoking methods with arguments yet.", nil), errDesc)];
    }
    if ([text containsString:@"."]) {
        return [RACSignal error:LookinErrorMake(NSLocalizedString(@"Lookin doesn't support this syntax yet. Please input a method or property name.", nil), @"")];
    }
    LKInspectableApp *app = [LKAppsManager sharedInstance].inspectingApp;
    NSString *snapshotID = [LKStaticAsyncUpdateManager sharedInstance].snapshotID;
    NSUInteger context = self.contextVersion;
    @weakify(self);
    RACSignal *response = [[app invokeMethodWithOid:obj.oid text:text] filter:^BOOL(id value) {
        @strongify(self);
        return self && self.contextVersion == context && app == [LKAppsManager sharedInstance].inspectingApp && [snapshotID isEqual:[LKStaticAsyncUpdateManager sharedInstance].snapshotID];
    }];
    return [response doNext:^(NSDictionary *dict) {
        NSString *returnDescription = dict[@"description"];
        LookinObject *returnObject = dict[@"object"];

        @strongify(self);
        NSMutableArray<LKConsoleDataSourceRowItem *> *rowItems = self.rowItems.mutableCopy;
        [rowItems insertObject:({
            LKConsoleDataSourceRowItem *item = [LKConsoleDataSourceRowItem new];
            item.type = LKConsoleDataSourceRowItemTypeSubmit;
            item.normalText = text;
            item.highlightText = [NSString stringWithFormat:@"<%@: %@>", obj.lk_simpleDemangledClassName, obj.memoryAddress];
            item;
        }) atIndex:(rowItems.count - 1)];
        if (returnDescription.length) {
            [rowItems insertObject:({
                LKConsoleDataSourceRowItem *item = [LKConsoleDataSourceRowItem new];
                item.type = LKConsoleDataSourceRowItemTypeReturn;
                item.normalText = returnDescription;
                item;
            }) atIndex:(rowItems.count - 1)];
        }
        if (returnObject) {
            NSString *message = [NSString stringWithFormat:@"<%@: %@> => %@", obj.lk_simpleDemangledClassName, obj.memoryAddress, text];
            [self _addRecentObject:returnObject message:message];
        }
        
        self.rowItems = rowItems;
    }];
}

- (RACSignal *)makeObjectAsCurrent:(LookinObject *)obj {
    NSUInteger selection = ++self.objectSelectionVersion;
    if (self.hierarchyDataSource.isReadOnly || ![LKStaticAsyncUpdateManager sharedInstance].snapshotID.length) return [RACSignal error:LookinErr_NoConnect];
    NSString *className = obj.rawClassName;
    if (!className.length) {
        return [RACSignal error:LookinErr_Inner];
    }
    if (![LKAppsManager sharedInstance].inspectingApp) {
        return [RACSignal error:LookinErr_NoConnect];
    }
    if ([self.classesToSelsDict objectForKey:className]) {
        self.currentObject = obj;
        return [RACSignal return:nil];
    }
    
    LKInspectableApp *app = [LKAppsManager sharedInstance].inspectingApp;
    NSString *snapshotID = [LKStaticAsyncUpdateManager sharedInstance].snapshotID;
    NSUInteger context = self.contextVersion;
    @weakify(self);
    RACSignal *response = [[app fetchSelectorNamesWithClass:obj.rawClassName hasArg:YES] filter:^BOOL(id value) {
        @strongify(self);
        return self && self.objectSelectionVersion == selection && self.contextVersion == context && app == [LKAppsManager sharedInstance].inspectingApp && [snapshotID isEqual:[LKStaticAsyncUpdateManager sharedInstance].snapshotID];
    }];
    return [response doNext:^(NSArray<NSString *> *sels) {
        @strongify(self);
        self.classesToSelsDict[className] = sels;
        self.currentObject = obj;
    }];
}

- (NSArray<NSString *> *)currentObjectSelectorNameList {
    return self.classesToSelsDict[self.currentObject.rawClassName];
}

- (void)clearHistoryContents {
    LKConsoleDataSourceRowItem *item = [LKConsoleDataSourceRowItem new];
    item.type = LKConsoleDataSourceRowItemTypeInput;
    self.rowItems = @[item];
}

- (void)setSelectedObjects:(NSArray<LookinObject *> *)selectedObjects {
    _selectedObjects = selectedObjects.copy;
    [self _syncConsoleTargetIfNeeded];
}

- (void)setIsShowingConsole:(BOOL)isShowingConsole {
    _isShowingConsole = isShowingConsole;
    [self _syncConsoleTargetIfNeeded];
}

- (void)_syncConsoleTargetIfNeeded {
    if (self.isShowingConsole && self.selectedObjects.count) {
        if ([LKPreferenceManager mainManager].syncConsoleTarget || !self.currentObject) {
            [[self makeObjectAsCurrent:self.selectedObjects.lastObject] subscribeNext:^(id  _Nullable x) {
                
            } error:^(NSError * _Nullable error) {
                
            }];
        }
    }
}

- (void)_addRecentObject:(LookinObject *)object message:(NSString *)message {
    if (!object) {
        return;
    }
    NSUInteger sameObjIdx = [self.recentObjects indexOfObjectPassingTest:^BOOL(RACTwoTuple * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        return ((LookinObject *)obj.first).oid == object.oid;
    }];
    if (sameObjIdx != NSNotFound) {
        [self.recentObjects removeObjectAtIndex:sameObjIdx];
    }
    
    NSUInteger maxCount = 5;
    if (!self.recentObjects) {
        _recentObjects = [NSMutableArray arrayWithCapacity:maxCount];
    }
    
    RACTwoTuple *newTuple = [RACTwoTuple tupleWithObjectsFromArray:@[object, message]];
    [self.recentObjects insertObject:newTuple atIndex:0];
    
    if (self.recentObjects.count > maxCount) {
        [self.recentObjects removeLastObject];
    }
}

@end
