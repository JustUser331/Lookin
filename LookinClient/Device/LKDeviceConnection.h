#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface LKDeviceConnection : NSObject
+ (instancetype)sharedInstance;
@property(nonatomic, readonly) BOOL busy;
- (void)connectXcodeApp:(void (^)(NSDictionary *result))completion;
- (void)xcodeIntegrationStatus:(void (^)(NSDictionary *result))completion;
- (void)setXcodeIntegrationEnabled:(BOOL)enabled completion:(void (^)(NSDictionary *result))completion;
- (void)listDevices:(void (^)(NSDictionary *result))completion;
- (void)connectDevice:(NSString *)identifier appPath:(NSString *)path mode:(NSString *)mode completion:(void (^)(NSDictionary *result))completion;
@end
NS_ASSUME_NONNULL_END
