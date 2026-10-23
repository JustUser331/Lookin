#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const LKSimulatorAutoConnectDidChangeNotification;
extern NSString *const LKSimulatorAutoConnectDefaultsKey;

@interface LKSimulatorCommandResult : NSObject
@property(nonatomic) int status;
@property(nonatomic, copy) NSString *output;
@property(nonatomic, copy) NSString *error;
@end

typedef LKSimulatorCommandResult * _Nonnull (^LKSimulatorCommandRunner)(NSArray<NSString *> *arguments);

@interface LKSimulatorAutoConnect : NSObject
@property(atomic, copy, readonly) NSDictionary<NSString *, NSString *> *rememberedApps;
@property(atomic, copy, readonly) NSArray<NSDictionary *> *availableApps;
@property(atomic, copy, readonly) NSString *statusText;
@property(atomic) BOOL catalogVisible;

+ (instancetype)sharedInstance;
- (void)start;
- (void)refresh;
- (void)setBundleID:(NSString *)bundleID name:(NSString *)name enabled:(BOOL)enabled;
- (void)stopWithCompletion:(void (^)(void))completion;

// Изолированные зависимости позволяют проверять жизненный цикл без пользовательских Simulator.
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults directory:(NSString *)directory
                    loaderSource:(NSString *)loaderSource serverPath:(NSString *)serverPath
                          runner:(LKSimulatorCommandRunner)runner;
+ (NSString *)environment:(NSString *)environment addingLoader:(NSString *)loader;
+ (NSString *)environment:(NSString *)environment removingLoader:(NSString *)loader;
+ (BOOL)isValidBundleID:(NSString *)bundleID;
@end

NS_ASSUME_NONNULL_END
