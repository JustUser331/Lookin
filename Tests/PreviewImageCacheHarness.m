#import <AppKit/AppKit.h>
#import "LookinPreviewSupport-Swift.h"

// Выполняется участок настоящего _renderImageAndColor, а не его копия в тесте.
#define LookinImage NSImage
@interface HCPreference : NSObject
@property BOOL currentBOOLValue;
@end
@implementation HCPreference
@end
@interface HCPreferences : NSObject
@property(strong) HCPreference *showHiddenItems;
@end
@implementation HCPreferences
@end
@interface HCItem : NSObject
@property BOOL displayingInHierarchy, inHiddenHierarchy;
@property(copy) NSString *appropriateScreenshotResourceKind;
@property(strong) NSData *groupScreenshotData, *soloScreenshotData;
@property(strong) NSImage *groupScreenshot, *soloScreenshot;
@end
@implementation HCItem
@end
@interface HCNode : NSObject
@property(strong) HCItem *displayItem;
@property(strong) HCPreferences *preferenceManager;
@property(strong) LKPreviewImageCache *imageCache;
@property(strong) NSData *renderedPNG;
@property(strong) NSImage *renderedImage;
@property NSInteger progressiveTextureMode;
- (NSImage *)renderImage;
@end
@implementation HCNode
- (NSImage *)renderImage {
#include "ImageSelection.inc"
    return appropriateScreenshot;
}
@end

static NSUInteger checks;
#define CHECK(value, message) do { checks++; if (!(value)) { fprintf(stderr,"FAIL: %s\n",message); exit(1); } } while(0)
static NSData *png(unsigned char red) {
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:4 pixelsHigh:2 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:NSBitmapFormatAlphaNonpremultiplied bytesPerRow:16 bitsPerPixel:32];
    for (NSUInteger index=0;index<8;index++) {
        bitmap.bitmapData[index*4]=red;bitmap.bitmapData[index*4+1]=30;
        bitmap.bitmapData[index*4+2]=40;bitmap.bitmapData[index*4+3]=100;
    }
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
int main(void) { @autoreleasepool {
    HCNode *node=[HCNode new];node.imageCache=[LKPreviewImageCache new];node.displayItem=[HCItem new];
    node.preferenceManager=[HCPreferences new];node.preferenceManager.showHiddenItems=[HCPreference new];
    node.displayItem.displayingInHierarchy=YES;node.displayItem.appropriateScreenshotResourceKind=@"group";
    NSData *group=png(10), *solo=png(20);node.displayItem.groupScreenshotData=group;node.displayItem.soloScreenshotData=solo;
    NSImage *first=[node renderImage];CHECK(first!=nil,"group image is available");
    [node.imageCache removeAllImages];
    CHECK([node renderImage]==first,"visible plane retains texture after shared cache eviction");
    node.displayItem.groupScreenshotData=png(30);
    CHECK([node renderImage]!=first,"new PNG cannot return the previous image");
    node.displayItem.appropriateScreenshotResourceKind=@"solo";
    NSImage *separate=[node renderImage];CHECK(node.renderedPNG==solo,"expanded container uses solo resource");
    node.progressiveTextureMode=1;
    CHECK([node renderImage]!=separate && node.renderedPNG==node.displayItem.groupScreenshotData,"overview uses group while expanded");
    node.progressiveTextureMode=2;
    CHECK([node renderImage]==nil && node.renderedImage==nil && node.renderedPNG==nil,"suppressed plane releases its local texture");
    node.progressiveTextureMode=0;node.displayItem.inHiddenHierarchy=YES;
    CHECK([node renderImage]==nil,"hidden layer does not retain a decoded image");
    node.preferenceManager.showHiddenItems.currentBOOLValue=YES;
    CHECK([node renderImage]!=nil,"show hidden restores native image");
    node.displayItem.soloScreenshotData=nil;node.displayItem.soloScreenshot=first;
    CHECK([node renderImage]==first,"legacy NSImage resource keeps its original render path");
    node.displayItem.soloScreenshot=nil;
    CHECK([node renderImage]==nil && node.renderedImage==nil,"invalidated image cannot retain stale cache contents");
    node.displayItem.groupScreenshotData=group;node.displayItem.appropriateScreenshotResourceKind=@"group";
    CHECK([node renderImage]!=nil,"group restores after invalidation");
    node.displayItem.displayingInHierarchy=NO;
    CHECK([node renderImage]==nil && node.renderedImage==nil,"collapsed descendant releases local image");
    fprintf(stdout,"PASS: %lu production preview image assertions\n",checks);
} return 0; }
