#import "LKAgentController.h"
@import LookinAgentBridge;
#import "LKAppsManager.h"
#import "LKInspectableApp.h"
#import "LKStaticHierarchyDataSource.h"
#import "LKStaticAsyncUpdateManager.h"
#import "LKNavigationManager.h"
#import "LookinDisplayItem+LookinClient.h"
#import "LookinHierarchyInfo.h"
#import "LookinAttributesSection.h"
#import "LookinAttribute.h"
#import "LookinAutoLayoutConstraint.h"
#import "LookinEventHandler.h"
#import "LookinTuple.h"
#import "Lookin_PTChannel.h"
#include <math.h>

typedef void (^LKAgentReply)(NSData *);

@interface LKAgentOperation : NSObject
@property(nonatomic, copy) LKAgentReply reply;
@property(nonatomic, copy) dispatch_block_t cancel;
@end
@implementation LKAgentOperation @end

static NSString *AgentText(NSString *text, NSUInteger limit) {
    if (!text) return @"";
    return text.length <= limit ? text : [[text substringToIndex:limit] stringByAppendingString:@"… [truncated]"];
}
static NSDictionary *AgentRect(CGRect r) {
    return @{@"x": @(isfinite(r.origin.x) ? r.origin.x : 0), @"y": @(isfinite(r.origin.y) ? r.origin.y : 0),
             @"width": @(isfinite(r.size.width) ? r.size.width : 0), @"height": @(isfinite(r.size.height) ? r.size.height : 0)};
}
static NSDictionary *AgentTool(NSString *name, NSString *description, NSDictionary *properties, NSArray *required) {
    return @{@"name": name, @"description": description,
             @"inputSchema": @{@"type": @"object", @"properties": properties, @"required": required, @"additionalProperties": @NO},
             @"annotations": @{@"readOnlyHint": @YES, @"destructiveHint": @NO, @"openWorldHint": @NO}};
}

@interface LKAgentController () <LKAgentDataProvider>
@property(nonatomic, strong) NSMutableDictionary<NSString *, LKAgentOperation *> *operations;
@property(nonatomic, strong) NSMutableDictionary<NSString *, LKInspectableApp *> *apps;
@property(nonatomic, copy) NSString *captureOwner;
@property(nonatomic, strong) LookinHierarchyInfo *hierarchy;
@property(nonatomic, copy) NSArray<LookinDisplayItem *> *items;
@property(nonatomic, weak) LKInspectableApp *snapshotApp;
@property(nonatomic, copy) NSString *snapshot;
@property(nonatomic, strong) NSDate *receivedAt;
@property(nonatomic, strong) NSMutableDictionary<NSString *, LookinDisplayItem *> *nodes;
@property(nonatomic, strong) NSMapTable<LookinDisplayItem *, NSString *> *refs;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *objectRefs;
@end

@implementation LKAgentController

+ (instancetype)sharedInstance {
    static LKAgentController *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [self new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _operations = [NSMutableDictionary new];
        _apps = [NSMutableDictionary new];
    }
    return self;
}

- (void)start { [LKAgentService.shared startWithProvider:self]; }
- (void)stop {
    for (NSString *identifier in self.operations.allKeys) [self cancelRequest:identifier];
    [LKAgentService.shared stop];
}
- (void)showStatus {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"MCP for agents";
    alert.informativeText = [NSString stringWithFormat:@"%@\n\nSix tools inspect apps, hierarchy, properties and PNG. Node references belong to one snapshot.\n\nAdd this HTTP endpoint to your MCP client:\n%@", LKAgentService.shared.status, LKAgentService.shared.endpoint];
    [alert addButtonWithTitle:@"Copy URL"];
    [alert addButtonWithTitle:@"Close"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:LKAgentService.shared.endpoint forType:NSPasteboardTypeString];
    }
}

- (NSArray<NSDictionary *> *)toolDefinitions {
    NSDictionary *string = @{@"type": @"string", @"minLength": @1, @"maxLength": @2048};
    NSDictionary *limit = @{@"type": @"integer", @"minimum": @1, @"maximum": @300, @"default": @100};
    NSDictionary *offset = @{@"type": @"integer", @"minimum": @0, @"maximum": @1000000, @"default": @0};
    return @[
        AgentTool(@"list_apps", @"Discover inspectable running apps. Returns opaque appRef, exact Simulator/device identity and the current selection. If missing, run the app with Xcode Integration and resume its debugger.", @{}, @[]),
        AgentTool(@"connect_app", @"Select an appRef from list_apps and capture its hierarchy in Lookin. Changes Lookin's selection; does not restart or modify the inspected app. Returns a new snapshotId.", @{@"appRef": string}, @[@"appRef"]),
        AgentTool(@"get_snapshot", @"Read a bounded flat tree with parentRef/childRefs, readiness and pagination. Default depth=4, limit=100. Pass snapshotId with nextOffset to avoid mixing snapshots. Optional root scopes the subtree. refresh=true captures a new tree and invalidates previous refs. Tree/PNG are not an atomic capture.",
                  @{@"snapshotId": string, @"root": string, @"depth": @{@"type": @"integer", @"minimum": @0, @"maximum": @64, @"default": @4},
                    @"offset": offset, @"limit": limit, @"refresh": @{@"type": @"boolean", @"default": @NO}}, @[]),
        AgentTool(@"find_nodes", @"Search the current full tree by class or text. Text covers summary and already-loaded string attributes; it does not force metadata for every node. Returns bounded matches with snapshot-bound refs and nextOffset.",
                  @{@"query": string, @"field": @{@"type": @"string", @"enum": @[@"any", @"class", @"text"]}, @"snapshotId": string, @"offset": offset, @"limit": limit}, @[@"query"]),
        AgentTool(@"get_node", @"Inspect one snapshot-bound ref. details=attributes loads its properties, constraints and event handlers on demand; basic returns geometry and class only. A stale_ref requires getting a new snapshot and finding the node again.",
                  @{@"ref": string, @"details": @{@"type": @"string", @"enum": @[@"basic", @"attributes"], @"default": @"attributes"}}, @[@"ref"]),
        AgentTool(@"get_image", @"Get native MCP PNG for one snapshot-bound ref. includeChildren=true captures the subtree; false requests the isolated layer. Preserves alpha. Returns image_unavailable for excluded, oversized or unrenderable layers.",
                  @{@"ref": string, @"includeChildren": @{@"type": @"boolean", @"default": @YES}}, @[@"ref"])
    ];
}
- (NSData *)toolsJSON { return [NSJSONSerialization dataWithJSONObject:self.toolDefinitions options:0 error:nil]; }

- (void)finish:(NSString *)identifier result:(NSDictionary *)result image:(NSData *)image {
    LKAgentOperation *operation = self.operations[identifier];
    if (!operation) return;
    [self.operations removeObjectForKey:identifier];
    if ([self.captureOwner isEqual:identifier]) self.captureOwner = nil;
    if (operation.cancel) operation.cancel();
    NSData *text = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
    if (!text || text.length > 512 * 1024) {
        result = @{@"error": @{@"code": @"response_too_large", @"message": @"Request fewer nodes, a smaller subtree, or basic details."}};
        text = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        image = nil;
    }
    NSMutableArray *content = [NSMutableArray arrayWithObject:@{@"type": @"text", @"text": [[NSString alloc] initWithData:text encoding:NSUTF8StringEncoding]}];
    if (image) [content addObject:@{@"type": @"image", @"mimeType": @"image/png", @"data": [image base64EncodedStringWithOptions:0]}];
    NSDictionary *response = @{@"content": content, @"structuredContent": result, @"isError": result[@"error"] ? @YES : @NO};
    operation.reply([NSJSONSerialization dataWithJSONObject:response options:0 error:nil]);
}
- (void)fail:(NSString *)identifier code:(NSString *)code message:(NSString *)message {
    [self finish:identifier result:@{@"error": @{@"code": code, @"message": AgentText(message, 2000)}} image:nil];
}
- (void)cancelRequest:(NSString *)requestID { [self fail:requestID code:@"cancelled" message:@"The MCP request was cancelled. Retry if needed."]; }

- (NSString *)validationError:(NSDictionary *)arguments tool:(NSDictionary *)tool {
    if (!arguments || !tool) return @"Expected a known tool with object arguments.";
    NSDictionary *schema = tool[@"inputSchema"], *properties = schema[@"properties"];
    for (NSString *key in schema[@"required"]) if (!arguments[key]) return [@"Missing argument: " stringByAppendingString:key];
    for (NSString *key in arguments) {
        NSDictionary *rule = properties[key]; id value = arguments[key];
        if (!rule) return [@"Unknown argument: " stringByAppendingString:key];
        NSString *type = rule[@"type"];
        if ([type isEqual:@"string"] && (![value isKindOfClass:NSString.class] || [value length] < [rule[@"minLength"] unsignedIntegerValue] || [value length] > (rule[@"maxLength"] ? [rule[@"maxLength"] unsignedIntegerValue] : 2048))) return [@"Invalid string: " stringByAppendingString:key];
        if ([type isEqual:@"boolean"] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) return [@"Invalid boolean: " stringByAppendingString:key];
        if ([type isEqual:@"integer"] && (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() || !isfinite([value doubleValue]) || floor([value doubleValue]) != [value doubleValue] || [value doubleValue] < [rule[@"minimum"] doubleValue] || [value doubleValue] > [rule[@"maximum"] doubleValue])) return [@"Invalid integer: " stringByAppendingString:key];
        if (rule[@"enum"] && ![rule[@"enum"] containsObject:value]) return [@"Unsupported value: " stringByAppendingString:key];
    }
    return nil;
}

- (void)performTool:(NSString *)name arguments:(NSData *)data requestID:(NSString *)identifier completion:(LKAgentReply)completion {
    LKAgentOperation *operation = [LKAgentOperation new]; operation.reply = completion; self.operations[identifier] = operation;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *arguments = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
    NSDictionary *tool;
    for (NSDictionary *definition in self.toolDefinitions) if ([definition[@"name"] isEqual:name]) tool = definition;
    NSString *invalid = [self validationError:arguments tool:tool];
    if (invalid) { [self fail:identifier code:@"invalid_arguments" message:invalid]; return; }
    if (self.operations.count > 16) { [self fail:identifier code:@"busy" message:@"Too many concurrent requests. Wait for current requests to finish."]; return; }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 35 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [weakSelf fail:identifier code:@"timeout" message:@"Keep the app in the foreground and resume Xcode if paused, then retry."]; });
    if ([name isEqual:@"list_apps"]) { [self listApps:identifier]; return; }
    if ([name isEqual:@"connect_app"]) {
        LKInspectableApp *app = self.apps[arguments[@"appRef"]];
        if (!app.channel.isConnected) { [self fail:identifier code:@"stale_app" message:@"This connection is no longer available. Call list_apps again."]; return; }
        [self capture:app request:identifier completion:^{ [self finish:identifier result:[self snapshotStatus] image:nil]; }];
        return;
    }
    if (!LKAppsManager.sharedInstance.inspectingApp.channel.isConnected) { [self fail:identifier code:@"not_connected" message:@"Call list_apps and connect_app. Run the app with Xcode Integration and keep it active."]; return; }
    if ([name isEqual:@"get_snapshot"] && [arguments[@"refresh"] boolValue]) {
        if ([arguments[@"offset"] unsignedIntegerValue] || arguments[@"root"] || arguments[@"snapshotId"]) { [self fail:identifier code:@"invalid_arguments" message:@"refresh starts a new snapshot; omit root, snapshotId and offset."]; return; }
        [self capture:LKAppsManager.sharedInstance.inspectingApp request:identifier completion:^{ [self snapshotPage:arguments request:identifier]; }];
        return;
    }
    [self synchronizeSnapshot];
    if (!self.snapshot || LKStaticAsyncUpdateManager.sharedInstance.isPreparingSnapshot) { [self fail:identifier code:@"not_ready" message:@"The hierarchy is loading. Retry get_snapshot shortly."]; return; }
    if (arguments[@"snapshotId"] && ![arguments[@"snapshotId"] isEqual:self.snapshot]) { [self fail:identifier code:@"stale_snapshot" message:@"The hierarchy changed. Start a new get_snapshot request without an offset."]; return; }
    if ([name isEqual:@"get_snapshot"]) [self snapshotPage:arguments request:identifier];
    else if ([name isEqual:@"find_nodes"]) [self findNodes:arguments request:identifier];
    else [self inspectNode:arguments image:[name isEqual:@"get_image"] request:identifier];
}

- (NSString *)appRef:(LKInspectableApp *)app {
    NSString *existing;
    for (NSString *key in self.apps) if (self.apps[key].channel == app.channel) { existing = key; break; }
    if (existing) { self.apps[existing] = app; return existing; }
    NSString *key = NSUUID.UUID.UUIDString; self.apps[key] = app; return key;
}
- (NSDictionary *)appRow:(LKInspectableApp *)app {
    if (!app) return @{};
    LookinAppInfo *info = app.appInfo;
    return @{@"appRef": [self appRef:app], @"name": info.appName ?: @"", @"bundleId": info.appBundleIdentifier ?: @"",
             @"device": info.deviceDescription ?: @"", @"os": info.osDescription ?: @"", @"simulatorId": info.simulatorUDID ?: NSNull.null,
             @"selected": LKAppsManager.sharedInstance.inspectingApp.channel == app.channel ? @YES : @NO};
}
- (void)listApps:(NSString *)identifier {
    RACDisposable *subscription = [[[[LKAppsManager.sharedInstance fetchAppInfosWithImage:NO localInfos:nil] take:1]
                                    timeout:8 onScheduler:RACScheduler.mainThreadScheduler] subscribeNext:^(NSArray<LKInspectableApp *> *apps) {
        if (!self.operations[identifier]) return;
        NSMutableArray *rows = [NSMutableArray new]; NSMutableDictionary *live = [NSMutableDictionary new];
        for (LKInspectableApp *app in apps) {
            if (!app.appInfo || !app.channel.isConnected) continue;
            NSDictionary *row = [self appRow:app]; [rows addObject:row]; live[row[@"appRef"]] = app;
            if (rows.count == 64) break;
        }
        self.apps = live;
        [self finish:identifier result:@{@"apps": rows, @"hint": @"For Xcode Run, enable Xcode Integration, Debug executable and breakpoints. Resume a paused app."} image:nil];
    } error:^(NSError *error) { [self fail:identifier code:@"discovery_failed" message:error.localizedDescription]; }];
    self.operations[identifier].cancel = ^{ [subscription dispose]; };
}
- (void)capture:(LKInspectableApp *)app request:(NSString *)identifier completion:(dispatch_block_t)completion {
    if (self.captureOwner) { [self fail:identifier code:@"busy" message:@"Another hierarchy capture is in progress. Retry shortly."]; return; }
    self.captureOwner = identifier;
    RACDisposable *subscription = [[[[app fetchHierarchyData] take:1] timeout:15 onScheduler:RACScheduler.mainThreadScheduler] subscribeNext:^(LookinHierarchyInfo *info) {
        if (!self.operations[identifier]) return;
        if (!info) { [self fail:identifier code:@"empty_hierarchy" message:@"The app returned no hierarchy. Keep it in the foreground and retry."]; return; }
        LKAppsManager.sharedInstance.inspectingApp = app;
        [LKStaticHierarchyDataSource.sharedInstance reloadWithHierarchyInfo:info keepState:NO];
        [LKNavigationManager.sharedInstance showStaticWorkspace];
        [LKNavigationManager.sharedInstance closeLaunch];
        [self synchronizeSnapshot];
        completion();
    } error:^(NSError *error) { [self fail:identifier code:@"capture_failed" message:error.localizedDescription]; }];
    self.operations[identifier].cancel = ^{ [subscription dispose]; };
}

- (void)synchronizeSnapshot {
    LKStaticHierarchyDataSource *source = LKStaticHierarchyDataSource.sharedInstance;
    LKInspectableApp *app = LKAppsManager.sharedInstance.inspectingApp;
    if (self.hierarchy == source.rawHierarchyInfo && self.items == source.rawFlatItems && self.snapshotApp == app) return;
    self.hierarchy = source.rawHierarchyInfo; self.items = source.rawFlatItems; self.snapshotApp = app;
    self.snapshot = self.hierarchy && self.items.count && app ? NSUUID.UUID.UUIDString : nil;
    self.receivedAt = NSDate.date; self.nodes = [NSMutableDictionary new]; self.objectRefs = [NSMutableDictionary new];
    self.refs = [NSMapTable strongToStrongObjectsMapTable];
    [self.items enumerateObjectsUsingBlock:^(LookinDisplayItem *item, NSUInteger index, BOOL *stop) {
        NSString *ref = [NSString stringWithFormat:@"%@:n%lu", self.snapshot, (unsigned long)index];
        self.nodes[ref] = item; [self.refs setObject:ref forKey:item];
        if (item.viewObject.oid) self.objectRefs[@(item.viewObject.oid)] = ref;
        if (item.layerObject.oid) self.objectRefs[@(item.layerObject.oid)] = ref;
    }];
}
- (NSDictionary *)snapshotStatus {
    [self synchronizeSnapshot];
    LKStaticAsyncUpdateManager *loading = LKStaticAsyncUpdateManager.sharedInstance;
    return @{@"snapshotId": self.snapshot ?: NSNull.null, @"receivedAt": @([self.receivedAt timeIntervalSince1970]),
             @"app": [self appRow:LKAppsManager.sharedInstance.inspectingApp], @"totalNodes": @(self.items.count),
             @"loading": @{@"state": loading.loadingState ?: @"idle", @"mode": loading.loadingMode ?: @"",
                           @"previewReady": @(loading.previewReady), @"metadataComplete": @(loading.metadataComplete),
                           @"imagesComplete": @(loading.imagesComplete), @"pending": @(loading.pendingResourceCount), @"failed": @(loading.failedResourceCount)},
             @"captureNote": @"Hierarchy, properties and PNG can be captured at different times. Refresh invalidates node refs."};
}
- (LookinDisplayItem *)resolve:(NSString *)ref request:(NSString *)identifier {
    LookinDisplayItem *item = self.nodes[ref];
    if (!item) [self fail:identifier code:@"stale_ref" message:@"This ref is absent from the current snapshot. Call get_snapshot or find_nodes and use a new ref."];
    return item;
}
- (NSDictionary *)nodeRow:(LookinDisplayItem *)item {
    NSMutableArray *children = [NSMutableArray new];
    for (LookinDisplayItem *child in item.subitems) { if (children.count == 200) break; NSString *ref = [self.refs objectForKey:child]; if (ref) [children addObject:ref]; }
    NSString *parent = item.superItem ? [self.refs objectForKey:item.superItem] : nil;
    return @{@"ref": [self.refs objectForKey:item] ?: @"", @"parentRef": parent ?: NSNull.null,
             @"childRefs": children, @"childCount": @(item.subitems.count), @"childrenTruncated": item.subitems.count > children.count ? @YES : @NO,
             @"class": AgentText(item.displayingObject.rawClassName ?: item.title, 512),
             @"text": AgentText(item.summaryText.length ? item.summaryText : item.subtitle, 512),
             @"frame": AgentRect(item.frame), @"hidden": @(item.isHidden), @"alpha": @(item.alpha)};
}
- (NSInteger)distance:(LookinDisplayItem *)item root:(LookinDisplayItem *)root {
    NSInteger depth = 0;
    while (item && item != root && depth < 256) { item = item.superItem; depth++; }
    return item == root ? depth : -1;
}
- (void)page:(NSArray<LookinDisplayItem *> *)items arguments:(NSDictionary *)arguments request:(NSString *)identifier note:(NSString *)note {
    NSUInteger offset = [arguments[@"offset"] unsignedIntegerValue], limit = arguments[@"limit"] ? [arguments[@"limit"] unsignedIntegerValue] : 100;
    if (offset > items.count) { [self fail:identifier code:@"invalid_arguments" message:@"offset exceeds the number of matching nodes."]; return; }
    NSMutableArray *rows = [NSMutableArray new]; NSUInteger end = MIN(items.count, offset + limit);
    for (NSUInteger index = offset; index < end; index++) [rows addObject:[self nodeRow:items[index]]];
    NSMutableDictionary *result = self.snapshotStatus.mutableCopy;
    [result addEntriesFromDictionary:@{@"nodes": rows, @"matched": @(items.count), @"nextOffset": end < items.count ? @(end) : NSNull.null, @"note": note}];
    [self finish:identifier result:result image:nil];
}
- (void)snapshotPage:(NSDictionary *)arguments request:(NSString *)identifier {
    [self synchronizeSnapshot];
    LookinDisplayItem *root = arguments[@"root"] ? [self resolve:arguments[@"root"] request:identifier] : nil;
    if (arguments[@"root"] && !root) return;
    NSInteger maximum = arguments[@"depth"] ? [arguments[@"depth"] integerValue] : 4;
    NSMutableArray *matches = [NSMutableArray new];
    for (LookinDisplayItem *item in self.items) { NSInteger depth = [self distance:item root:root]; if (depth >= 0 && depth <= maximum + (root ? 0 : 1)) [matches addObject:item]; }
    [self page:matches arguments:arguments request:identifier note:@"Use nextOffset with this snapshotId and the same root/depth. childRefs may point beyond this page."];
}
- (void)findNodes:(NSDictionary *)arguments request:(NSString *)identifier {
    NSString *query = arguments[@"query"], *field = arguments[@"field"] ?: @"any";
    NSMutableArray *matches = [NSMutableArray new];
    for (LookinDisplayItem *item in self.items) {
        BOOL match = ![field isEqual:@"text"] && [(item.displayingObject.rawClassName ?: @"") rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (![field isEqual:@"class"]) {
            NSString *text = [NSString stringWithFormat:@"%@ %@", item.summaryText ?: @"", item.subtitle ?: @""];
            match |= [text rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
            for (LookinAttributesGroup *group in item.queryAllAttrGroupList) for (LookinAttributesSection *section in group.attrSections) for (LookinAttribute *attribute in section.attributes) {
                if ([attribute.value isKindOfClass:NSString.class]) match |= [attribute.value rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
            }
        }
        if (match) [matches addObject:item];
    }
    [self page:matches arguments:arguments request:identifier note:@"Text search covers summaries and loaded attributes; unloaded metadata is not exhaustively searched."];
}

- (id)jsonValue:(id)value depth:(NSUInteger)depth {
    if (!value || value == NSNull.null) return NSNull.null;
    if (depth > 6) return @{@"truncated": @YES};
    if ([value isKindOfClass:NSString.class]) return AgentText(value, 4096);
    if ([value isKindOfClass:NSNumber.class]) return isfinite([value doubleValue]) ? value : NSNull.null;
    if ([value isKindOfClass:NSArray.class]) { NSMutableArray *out = [NSMutableArray new]; for (id entry in value) { if (out.count == 128) { [out addObject:@{@"truncated": @YES}]; break; } [out addObject:[self jsonValue:entry depth:depth + 1]]; } return out; }
    if ([value isKindOfClass:NSDictionary.class]) { NSMutableDictionary *out = [NSMutableDictionary new]; for (id key in value) { if (out.count == 128) { out[@"_truncated"] = @YES; break; } if ([key isKindOfClass:NSString.class]) out[AgentText(key, 256)] = [self jsonValue:value[key] depth:depth + 1]; } return out; }
    if ([value isKindOfClass:LookinObject.class]) { LookinObject *object = value; return @{@"class": object.rawClassName ?: @"", @"address": object.memoryAddress ?: @"", @"ref": self.objectRefs[@(object.oid)] ?: NSNull.null}; }
    if ([value isKindOfClass:LookinAutoLayoutConstraint.class]) {
        LookinAutoLayoutConstraint *c = value;
        return @{@"first": [self jsonValue:c.firstItem depth:depth + 1], @"second": [self jsonValue:c.secondItem depth:depth + 1],
                 @"firstAttribute": @(c.firstAttribute), @"secondAttribute": @(c.secondAttribute), @"relation": @(c.relation),
                 @"constant": @(c.constant), @"multiplier": @(c.multiplier), @"priority": @(c.priority), @"active": @(c.active), @"effective": @(c.effective), @"identifier": c.identifier ?: @""};
    }
    if ([value isKindOfClass:NSColor.class]) { NSColor *color = [value colorUsingColorSpace:NSColorSpace.sRGBColorSpace]; if (color) return @{@"r": @(color.redComponent), @"g": @(color.greenComponent), @"b": @(color.blueComponent), @"a": @(color.alphaComponent)}; }
    if ([value isKindOfClass:NSValue.class] && strcmp([value objCType], @encode(CGRect)) == 0) return AgentRect([value rectValue]);
    return @{@"type": NSStringFromClass([value class]), @"description": AgentText([value description], 2048)};
}
- (NSArray *)attributes:(LookinDisplayItem *)item {
    NSMutableArray *groups = [NSMutableArray new];
    for (LookinAttributesGroup *group in item.queryAllAttrGroupList) {
        if (groups.count == 64) { [groups addObject:@{@"truncated": @YES}]; break; }
        NSMutableArray *values = [NSMutableArray new];
        NSUInteger total = 0; for (LookinAttributesSection *section in group.attrSections) total += section.attributes.count;
        for (LookinAttributesSection *section in group.attrSections) for (LookinAttribute *attribute in section.attributes) {
            if (values.count == 256) break;
            [values addObject:@{@"id": attribute.identifier ?: @"", @"name": attribute.displayTitle ?: attribute.identifier ?: @"", @"type": @(attribute.attrType), @"value": [self jsonValue:attribute.value depth:0]}];
        }
        [groups addObject:@{@"id": group.identifier ?: @"", @"name": group.userCustomTitle ?: group.identifier ?: @"", @"values": values, @"truncated": total > values.count ? @YES : @NO}];
    }
    return groups;
}
- (void)inspectNode:(NSDictionary *)arguments image:(BOOL)image request:(NSString *)identifier {
    LookinDisplayItem *item = [self resolve:arguments[@"ref"] request:identifier]; if (!item) return;
    NSString *snapshot = self.snapshot;
    BOOL groupImage = arguments[@"includeChildren"] ? [arguments[@"includeChildren"] boolValue] : YES;
    BOOL useGroupImage = groupImage || !item.hasPhysicalSublayers;
    BOOL details = ![arguments[@"details"] isEqual:@"basic"];
    NSArray *kinds = image ? @[useGroupImage ? @"group" : @"solo"] : (details ? @[@"attributes", @"metadata"] : @[]);
    void (^ready)(NSError *) = ^(NSError *error) {
        if (!self.operations[identifier]) return;
        [self synchronizeSnapshot];
        if (![snapshot isEqual:self.snapshot]) { [self fail:identifier code:@"stale_ref" message:@"The hierarchy changed while loading resources. Find the node again in the new snapshot."]; return; }
        if (error) { [self fail:identifier code:@"resource_unavailable" message:error.localizedDescription]; return; }
        NSMutableDictionary *result = [self nodeRow:item].mutableCopy; result[@"snapshotId"] = snapshot;
        result[@"resourceRevision"] = @(item.resourceRevision);
        if (image) {
            NSData *png = useGroupImage ? item.groupScreenshotData : item.soloScreenshotData;
            if (!png) { NSImage *native = useGroupImage ? item.groupScreenshot : item.soloScreenshot; NSBitmapImageRep *rep = native ? [NSBitmapImageRep imageRepWithData:native.TIFFRepresentation] : nil; png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]; }
            if (!png.length || png.length > 16 * 1024 * 1024) { [self fail:identifier code:@"image_unavailable" message:@"This layer has no renderable PNG, is excluded, or exceeds 16 MiB. Try a smaller visible subtree."]; return; }
            result[@"includeChildren"] = @(groupImage); result[@"bytes"] = @(png.length);
            [self finish:identifier result:result image:png];
        } else {
            result[@"bounds"] = AgentRect(item.bounds); result[@"object"] = [self jsonValue:item.displayingObject depth:0];
            result[@"classChain"] = item.displayingObject.classChainList ?: @[];
            if (details) {
                result[@"attributes"] = [self attributes:item];
                NSMutableArray *events = [NSMutableArray new];
                for (LookinEventHandler *handler in item.eventHandlers) {
                    if (events.count == 128) break;
                    NSMutableArray *actions = [NSMutableArray new]; for (LookinStringTwoTuple *action in handler.targetActions) { if (actions.count == 128) break; [actions addObject:@{@"target": AgentText(action.first, 512), @"selector": AgentText(action.second, 512)}]; }
                    [events addObject:@{@"event": handler.eventName ?: @"", @"type": @(handler.handlerType), @"actions": actions, @"enabled": @(handler.gestureRecognizerIsEnabled)}];
                }
                result[@"events"] = events;
            }
            [self finish:identifier result:result image:nil];
        }
    };
    NSString *waiter = [LKStaticAsyncUpdateManager.sharedInstance ensureResourcesForItem:item kinds:kinds completion:ready];
    self.operations[identifier].cancel = ^{ [LKStaticAsyncUpdateManager.sharedInstance cancelWaiterWithID:waiter]; };
}
@end
