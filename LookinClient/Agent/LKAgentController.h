#import <Foundation/Foundation.h>

@interface LKAgentController : NSObject
+ (instancetype)sharedInstance;
- (void)start;
- (void)stop;
- (void)showStatus;
@end
