#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <netinet/tcp.h>
#import <dlfcn.h>
#import <time.h>
#import <CommonCrypto/CommonDigest.h>

// Измерительный клиент использует штатные классы архива из установленного Lookin.
static double now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }
static void transfer(int fd, void *bytes, size_t n, BOOL writing) {
    while (n) {
        ssize_t got = writing ? write(fd, bytes, n) : read(fd, bytes, n);
        if (got <= 0) { perror(writing ? "write" : "read"); exit(2); }
        n -= got; bytes += got;
    }
}
static uint32_t sequence = 1;
static void sendRequest(int fd, uint32_t type, id object) {
    NSData *body = object ? [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:YES error:nil] : nil;
    uint32_t header[] = {htonl(1), htonl(type), htonl(sequence++), htonl((uint32_t)body.length)};
    NSMutableData *packet = [NSMutableData dataWithBytes:header length:16];
    if (body) [packet appendData:body];
    transfer(fd, (void *)packet.bytes, packet.length, YES);
}
static id receive(int fd, NSUInteger *bytes, double *decodeMs) {
    uint32_t header[4]; transfer(fd, header, 16, NO);
    NSUInteger length = ntohl(header[3]);
    if (length > 512 * 1024 * 1024) exit(3);
    NSMutableData *body = [NSMutableData dataWithLength:length];
    transfer(fd, body.mutableBytes, length, NO);
    *bytes += length;
    double t = now(); NSError *error = nil;
    id result = [NSKeyedUnarchiver unarchivedObjectOfClass:NSObject.class fromData:body error:&error];
    *decodeMs += now() - t;
    if (!result || error) { NSLog(@"decode failed: %@", error); exit(4); }
    if ([result valueForKey:@"error"]) { NSLog(@"server error: %@", [result valueForKey:@"error"]); exit(5); }
    return result;
}
static void flatten(id item, NSMutableArray *items) {
    NSArray *classes = [[item valueForKey:@"viewObject"] valueForKey:@"classChainList"];
    if ([classes containsObject:@"HYPSnapshotDebuggingWindow"]) return;
    [items addObject:item];
    for (id child in [item valueForKey:@"subitems"]) flatten(child, items);
}
static NSArray *rectValues(NSRect r) { return @[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)]; }
static void coreNodes(id item,NSNumber *parent,NSMutableArray *nodes) {
    id obj=[item valueForKey:@"viewObject"] ?: [item valueForKey:@"layerObject"];
    NSArray *classes=[obj valueForKey:@"classChainList"];
    if([classes containsObject:@"HYPSnapshotDebuggingWindow"])return;
    NSNumber *oid=[[item valueForKey:@"layerObject"] valueForKey:@"oid"] ?: @0;
    [nodes addObject:@{@"oid":oid,@"parentOid":parent ?: @0,@"class":classes.firstObject ?: @"",@"frame":rectValues([[item valueForKey:@"frame"] rectValue]),@"bounds":rectValues([[item valueForKey:@"bounds"] rectValue]),@"hidden":[item valueForKey:@"isHidden"],@"alpha":[item valueForKey:@"alpha"]}];
    for(id child in [item valueForKey:@"subitems"])coreNodes(child,oid,nodes);
}
static NSString *checksum(NSArray *nodes) {
    NSMutableDictionary *indexes=[NSMutableDictionary dictionary];
    for(NSUInteger i=0;i<nodes.count;i++)indexes[nodes[i][@"oid"]]=@(i);
    NSMutableArray *values=[NSMutableArray array];
    for(NSDictionary *n in nodes) [values addObject:@[n[@"class"],n[@"frame"],n[@"bounds"],n[@"hidden"],n[@"alpha"],indexes[n[@"parentOid"]] ?: @(-1)]];
    NSData *data=[NSJSONSerialization dataWithJSONObject:values options:NSJSONWritingSortedKeys error:nil]; unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *result=[NSMutableString string]; for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[result appendFormat:@"%02x",digest[i]]; return result;
}
static id task(id item, NSInteger kind, NSInteger attrs) {
    id result = [NSClassFromString(@"LookinStaticAsyncUpdateTask") new];
    [result setValue:[[item valueForKey:@"layerObject"] valueForKey:@"oid"] forKey:@"oid"];
    [result setValue:@(kind) forKey:@"taskType"];
    [result setValue:@(attrs) forKey:@"attrRequest"];
    [result setValue:@"1.0.7" forKey:@"clientReadableVersion"];
    return result;
}
static void emit(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String); fflush(stdout);
}
int main(int argc, const char *argv[]) { @autoreleasepool {
    if (argc < 4) { fprintf(stderr, "wire_client PORT ITERATIONS none|attrs|attrs-root|full|root|images [package-count]\n"); return 1; }
    if (!dlopen("/Applications/Lookin MCP.app/Contents/Frameworks/LookinShared.framework/LookinShared", RTLD_NOW|RTLD_GLOBAL)) { puts(dlerror()); return 1; }
    int fd = socket(AF_INET, SOCK_STREAM, 0), flag = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
    struct timeval timeout = {.tv_sec = 90}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = htons(atoi(argv[1])), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    double connectionStart = now();
    if (connect(fd, (void *)&address, sizeof(address))) { perror("connect"); return 1; }
    double connectionMs = now() - connectionStart;
    NSString *mode = @(argv[3]);
    NSInteger cap = argc > 4 ? atoi(argv[4]) : 100;
    for (int iteration = 0; iteration < atoi(argv[2]); iteration++) { @autoreleasepool {
        NSUInteger bytes = 0; double decode = 0, t = now();
        sendRequest(fd, 200, nil); id ping = receive(fd, &bytes, &decode);
        double pingMs = now()-t;
        bytes=0; decode=0; t=now();
        sendRequest(fd, 202, @{@"clientVersion":@"1.0.7"});
        id response = receive(fd, &bytes, &decode);
        double treeMs = now()-t;
        id info = [response valueForKey:@"data"];
        if ([info isKindOfClass:NSData.class]) {
            double jsonStart=now(); NSDictionary *core=[NSJSONSerialization JSONObjectWithData:info options:0 error:nil]; double jsonMs=now()-jsonStart;
            emit(@{@"iteration":@(iteration),@"pid":@(getpid()),@"connection_ms":@(connectionMs),@"ping_ms":@(pingMs),@"mode":mode,@"format":core[@"format"],@"nodes":@([core[@"nodes"] count]),@"raw_roots":core[@"raw_roots"],@"tree_ms":@(treeMs+jsonMs),@"tree_bytes":@(bytes),@"tree_decode_ms":@(decode+jsonMs),@"core_checksum":checksum(core[@"nodes"])});
            usleep(250000); continue;
        }
        NSMutableArray *items = [NSMutableArray array];
        NSArray *roots = [info valueForKey:@"displayItems"];
        for (id root in roots) flatten(root, items);
        NSMutableDictionary *row = [@{@"iteration":@(iteration), @"pid":@(getpid()), @"connection_ms":@(connectionMs), @"ping_ms":@(pingMs), @"background":[ping valueForKey:@"appIsInBackground"], @"mode":mode, @"tree_ms":@(treeMs), @"tree_bytes":@(bytes), @"tree_decode_ms":@(decode), @"nodes":@(items.count), @"raw_roots":@(roots.count)} mutableCopy];
        NSMutableArray *core=[NSMutableArray array]; for(id root in roots)coreNodes(root,nil,core); row[@"core_checksum"]=checksum(core);
        NSMutableArray *tasks = [NSMutableArray array], *areas = [NSMutableArray array];
        if (![mode isEqual:@"none"]) {
            double scale = [[[info valueForKey:@"appInfo"] valueForKey:@"screenScale"] doubleValue];
            for (id item in items) {
                if ([item valueForKey:@"customInfo"]) continue;
                NSRect frame = [[item valueForKey:@"frame"] rectValue];
                double area = MAX(0, frame.size.width * frame.size.height);
                BOOL allowed = [[item valueForKey:@"shouldCaptureImage"] boolValue] && MAX(frame.size.width, frame.size.height)*scale <= 16284;
                NSInteger kind = [mode isEqual:@"attrs"] || !allowed ? 0 : 2;
                if ([mode isEqual:@"attrs-root"] && tasks.count > 0) kind=0;
                [tasks addObject:task(item,kind,[mode isEqual:@"images"] ? 2 : 0)]; [areas addObject:@(area)];
                if ([mode isEqual:@"root"]) break;
                if (([mode isEqual:@"full"] || [mode isEqual:@"images"]) && allowed && [[item valueForKey:@"subitems"] count]) {
                    [tasks addObject:task(item,1,[mode isEqual:@"images"] ? 2 : 0)]; [areas addObject:@(area)];
                }
            }
        }
        if (tasks.count) {
            NSMutableArray *packages = [NSMutableArray array], *buffer = [NSMutableArray array]; double area=0;
            for (NSUInteger i=0;i<tasks.count;i++) {
                double current=[areas[i] doubleValue];
                if (buffer.count && (buffer.count >= cap || area+current > 2000000)) {
                    id package=[NSClassFromString(@"LookinStaticAsyncUpdateTasksPackage") new];
                    [package setValue:buffer.copy forKey:@"tasks"]; [packages addObject:package]; [buffer removeAllObjects]; area=0;
                }
                [buffer addObject:tasks[i]]; area+=current;
            }
            if (buffer.count) { id package=[NSClassFromString(@"LookinStaticAsyncUpdateTasksPackage") new]; [package setValue:buffer.copy forKey:@"tasks"]; [packages addObject:package]; }
            bytes=0; decode=0; t=now(); sendRequest(fd,203,packages);
            NSUInteger received=0, failures=0, attrNodes=0, images=0, frames=0; double first=0;
            while (received < tasks.count) {
                id part=receive(fd,&bytes,&decode); frames++; if (!first) first=now()-t;
                received += [[part valueForKey:@"currentDataCount"] unsignedIntegerValue];
                for (id detail in [part valueForKey:@"data"]) {
                    failures += [[detail valueForKey:@"failureCode"] integerValue] != 0;
                    attrNodes += [[detail valueForKey:@"attributesGroupList"] count] > 0;
                    images += [detail valueForKey:@"soloScreenshot"] != nil; images += [detail valueForKey:@"groupScreenshot"] != nil;
                }
            }
            [row addEntriesFromDictionary:@{@"details_ms":@(now()-t),@"details_first_ms":@(first),@"details_decode_ms":@(decode),@"details_bytes":@(bytes),@"tasks":@(tasks.count),@"packages":@(frames),@"failures":@(failures),@"attr_nodes":@(attrNodes),@"images":@(images)}];
        }
        emit(row); usleep(250000);
    }} close(fd); return 0;
}}
