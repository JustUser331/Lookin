//
//  LKDeviceItem.m
//  Lookin
//
//  Created by Li Kai on 2018/11/3.
//  https://lookin.work
//

#import "LKInspectableApp.h"
#import "LKConnectionManager.h"
#import "LookinConnectionResponseAttachment.h"
#import "LKNavigationManager.h"
#import "LKPreferenceManager.h"
#import "LookinHierarchyInfo.h"

@implementation LKInspectableApp

- (RACSignal *)fetchHierarchyData {
    /// Lookin 1.0.4 开始加入这个参数
    BOOL compact = [self.appInfo.capabilities containsObject:@"compactHierarchyV1"];
    BOOL deferred = ![[LKPreferenceManager mainManager].loadingMode isEqual:@"full"] && [self.appInfo.capabilities containsObject:@"deferredMetadataV1"];
    NSString *snapshotID = NSUUID.UUID.UUIDString;
    NSDictionary *param = @{@"clientVersion": [LKHelper lookinReadableVersion], @"snapshotID":snapshotID, @"compactJSON":@(compact), @"deferMetadata":@(deferred)};
    return [[self _requestWithType:LookinRequestTypeHierarchy data:param] flattenMap:^RACSignal *(id value) {
        NSError *error = nil;
        LookinHierarchyInfo *info = [value isKindOfClass:NSData.class] ? [LookinHierarchyInfo hierarchyFromCompactJSONData:value error:&error] : value;
        if (![info isKindOfClass:LookinHierarchyInfo.class]) return [RACSignal error:error ?: LookinErr_Inner];
        if (!info.snapshotID.length) info.snapshotID = snapshotID;
        return [RACSignal return:info];
    }];
}

- (RACSignal *)submitInbuiltModification:(LookinAttributeModification *)modification {
    return [self _requestWithType:LookinRequestTypeInbuiltAttrModification data:modification];
}

- (RACSignal *)submitCustomModification:(LookinCustomAttrModification *)modification {
    return [self _requestWithType:LookinRequestTypeCustomAttrModification data:modification];
}

- (RACSignal *)fetchHierarchyDetailWithTaskPackages:(NSArray<LookinStaticAsyncUpdateTasksPackage *> *)packages {
    return [self _requestWithType:LookinRequestTypeHierarchyDetails data:packages];
}

- (RACSignal *)fetchMetadataWithTaskPackages:(NSArray<LookinStaticAsyncUpdateTasksPackage *> *)packages {
    return [self _requestWithType:LookinRequestTypeMetadata data:packages];
}

- (void)cancelHierarchyDetailFetching {
    [self _cancelRequestWithType:LookinRequestTypeHierarchyDetails];
    [self _cancelRequestWithType:LookinRequestTypeMetadata];
    [self _pushWithType:LookinPush_CanceHierarchyDetails data:nil];
}

- (RACSignal *)fetchModificationPatchWithTasks:(NSArray<LookinStaticAsyncUpdateTask *> *)tasks {
    return [self _requestWithType:LookinRequestTypeAttrModificationPatch data:tasks];
}

- (RACSignal *)fetchObjectWithOid:(unsigned long)oid {
    if (!oid) {
        return [RACSignal error:LookinErr_Inner];
    }
    return [self _requestWithType:LookinRequestTypeFetchObject data:@(oid)];
}

- (RACSignal *)fetchSelectorNamesWithClass:(NSString *)className hasArg:(BOOL)hasArg {
    return [self _requestWithType:LookinRequestTypeAllSelectorNames data:@{@"className":className, @"hasArg":@(hasArg)}];
}

- (RACSignal *)invokeMethodWithOid:(unsigned long)oid text:(NSString *)text {
    if (oid == 0 || !text.length) {
        return [RACSignal error:LookinErr_Inner];
    }
    NSDictionary *param = @{@"oid":@(oid), @"text":text};
    return [[self _requestWithType:LookinRequestTypeInvokeMethod data:param] map:^id _Nullable(NSDictionary * _Nullable value) {
        if ([value[@"description"] isEqualToString:LookinStringFlag_VoidReturn]) {
            // 方法没有返回值时，替换成本地说明
            NSMutableDictionary *newValue = [value mutableCopy];
            newValue[@"description"] = NSLocalizedString(@"The method was invoked successfully and no value was returned.", nil);
            return newValue;
        } else {
            return value;
        }
    }];
}

- (RACSignal *)fetchAttrGroupListWithOid:(unsigned long)oid {
    if (!oid) {
        return [RACSignal error:LookinErr_Inner];
    }
    return [self _requestWithType:LookinRequestTypeAllAttrGroups data:@(oid)];
}

- (RACSignal *)fetchImageWithImageViewOid:(unsigned long)oid {
    if (!oid) {
        return [RACSignal error:LookinErr_Inner];
    }
    return [self _requestWithType:LookinRequestTypeFetchImageViewImage data:@(oid)];
}

- (RACSignal *)modifyGestureRecognizer:(unsigned long)oid toBeEnabled:(BOOL)shouldBeEnabled {
    if (!oid) {
        return [RACSignal error:LookinErr_Inner];
    }
    return [self _requestWithType:LookinRequestTypeModifyRecognizerEnable data:@{@"oid":@(oid), @"enable":@(shouldBeEnabled)}];
}

#pragma mark - Push From iOS


#pragma mark - Private

- (void)_pushWithType:(uint32_t)pushType data:(id)data {
    if (!self.channel) {
        return;
    }
    [[LKConnectionManager sharedInstance] pushWithType:pushType data:data channel:self.channel];
}

- (RACSignal *)_requestWithType:(uint32_t)requestType data:(id)data {
    if (!self.channel) {
        return [RACSignal error:LookinErr_NoConnect];
    }
    return [[[LKConnectionManager sharedInstance] requestWithType:requestType data:data channel:self.channel] flattenMap:^__kindof RACSignal * _Nullable(RACTuple *tuple) {
        LookinConnectionResponseAttachment *attachment = tuple.first;
        if (attachment.error) {
            // 翻译成本地文字
            if (attachment.error.code == LookinErrCode_ObjectNotFound) {
                attachment.error = LookinErr_ObjNotFound;
            } else if (attachment.error.code == LookinErrCode_Inner) {
                attachment.error = LookinErr_Inner;
            }
            return [RACSignal error:attachment.error];
        } else {
            return [RACSignal return:attachment.data];
        }
    }];
}

- (void)_cancelRequestWithType:(uint32_t)requestType {
    if (!self.channel) {
        return;
    }
    [[LKConnectionManager sharedInstance] cancelRequestWithType:requestType channel:self.channel];
}

@end
