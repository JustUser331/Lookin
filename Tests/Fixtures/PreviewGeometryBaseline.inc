// Reference algorithm before geometry caching (930f195).
- (void)updateZPosition {
    [self.flatDisplayItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [self _updateZIndexForItem:obj];
    }];

    [self _updateZPositionByZIndex];
}

- (void)_updateZIndexForItem:(LookinDisplayItem *)item {
    item.previewZIndex = -1;
    if (item.displayingInHierarchy) {
        LookinDisplayItem *referenceItem = [self _maxZIndexForOverlappedItemUnderItem:item];
        if (referenceItem) {
            // 如果 item 和另一个 itemA 重叠了，则 item.previewZIndex 应该比 itemA.previewZIndex 高一级
            item.previewZIndex = referenceItem.previewZIndex + 1;
        } else {
            item.previewZIndex = 0;
        }

    } else {
        if (item.superItem) {
            item.previewZIndex = item.superItem.previewZIndex;
        } else {
            NSAssert(NO, @"");
        }
    }

    if (item.previewZIndex < 0) {
        NSAssert(NO, @"");
        item.previewZIndex = 0;
    }
}

/**
 传入 itemA，返回另一个 itemB，itemB 满足以下条件：
 - itemB 在 preview 中可见
 - itemB 的层级比 itemA 要低（即 itemB 在 flatItems 里的 index 要比 itemA 小）
 - itemB 和 itemA 的 frameToRoot 有重叠，即视觉上它们是彼此遮挡的
 - itemB 是满足以上两个条件中的所有 items 里的 zIndex 值最高的

 @note 如果没有找到任何符合条件的 itemB，则返回 nil
 */
- (LookinDisplayItem *)_maxZIndexForOverlappedItemUnderItem:(LookinDisplayItem *)item {
    NSUInteger itemIndex = [self.flatDisplayItems indexOfObject:item];
    if (itemIndex == 0) {
        return nil;
    }
    if (itemIndex == NSNotFound) {
        NSAssert(NO, @"");
        return nil;
    }
    CGRect itemFrameToRoot = [item calculateFrameToRoot];
    NSIndexSet *indexesBelow = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, itemIndex)];
    __block LookinDisplayItem *targetItem = nil;
    [self.flatDisplayItems enumerateObjectsAtIndexes:indexesBelow options:NSEnumerationReverse usingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if (!obj.inHiddenHierarchy || self.showHiddenItems) {
            if (CGRectIntersectsRect(itemFrameToRoot, [obj calculateFrameToRoot])) {
                if (!targetItem) {
                    targetItem = obj;
                } else {
                    if (obj.previewZIndex > targetItem.previewZIndex) {
                        targetItem = obj;
                    }
                }
            }
        }
    }];
    return targetItem;
}
