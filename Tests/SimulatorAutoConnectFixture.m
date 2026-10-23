#import <UIKit/UIKit.h>
#import <sys/sysctl.h>

@interface ResearchDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) NSTimer *timer;
@end

@implementation ResearchDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(25, 180, 340, 100)];
    label.text = @"Lookin without Xcode\nIndependent test application";
    label.numberOfLines = 2;
    label.accessibilityIdentifier = @"researchLabel";
    [controller.view addSubview:label];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(writeState) userInfo:nil repeats:YES];
    [self writeState];
    return YES;
}
- (void)writeState {
    struct kinfo_proc info = {0};
    size_t size = sizeof(info);
    int query[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    int result = sysctl(query, 4, &info, &size, NULL, 0);
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    NSDictionary *state = @{
        @"pid": @(getpid()),
        @"bundle": NSBundle.mainBundle.bundleIdentifier,
        @"lookinLoaded": @(NSClassFromString(@"Lookin") != Nil),
        @"swiftTraceLoaded": @(NSClassFromString(@"LookinServer.LKS_SwiftTraceManager") != Nil),
        @"traced": @((info.kp_proc.p_flag & P_TRACED) != 0),
        @"sysctlResult": @(result),
        @"applicationState": @(UIApplication.sharedApplication.applicationState),
        @"dyldInsert": environment[@"DYLD_INSERT_LIBRARIES"] ?: @"",
        @"globalMarker": environment[@"LOOKIN_RESEARCH_MARKER"] ?: @"",
        @"timestamp": @(NSDate.date.timeIntervalSince1970)
    };
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/state.json"];
    [[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil] writeToFile:path atomically:YES];
}
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary *)options {
    [self writeState];
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(ResearchDelegate.class));
    }
}
