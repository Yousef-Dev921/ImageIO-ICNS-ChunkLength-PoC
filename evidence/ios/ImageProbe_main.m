// ImageProbe v2 — adds VM measurement (task_info) so we can prove
// or disprove the iOS memory commit.
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <mach/mach.h>

static void writeResult(NSString *line) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *docs = [[fm URLsForDirectory:NSDocumentDirectory
                              inDomains:NSUserDomainMask] firstObject];
    NSURL *out = [docs URLByAppendingPathComponent:@"result.txt"];
    NSString *prev = [NSString stringWithContentsOfURL:out
                              encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSString *now = [NSString stringWithFormat:@"%@%@\n", prev, line];
    [now writeToURL:out atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[ImageProbe] %@", line);
}

static void readVM(uint64_t *virt, uint64_t *resid, uint64_t *phys) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    *virt = info.virtual_size;
    *resid = info.resident_size;
    *phys = info.phys_footprint;
}

static NSString *bytesStr(uint64_t b) {
    if (b >= (1ULL<<30)) return [NSString stringWithFormat:@"%.2f GiB", b/(double)(1<<30)];
    if (b >= (1<<20)) return [NSString stringWithFormat:@"%.2f MiB", b/(double)(1<<20)];
    if (b >= (1<<10)) return [NSString stringWithFormat:@"%.2f KiB", b/(double)(1<<10)];
    return [NSString stringWithFormat:@"%llu B", b];
}

static void probeImage(NSData *data) {
    uint64_t v0, r0, p0; readVM(&v0, &r0, &p0);
    writeResult([NSString stringWithFormat:@"[VM before] virt=%@ resid=%@ phys=%@",
                bytesStr(v0), bytesStr(r0), bytesStr(p0)]);
    writeResult([NSString stringWithFormat:@"probe image bytes=%lu", (unsigned long)data.length]);

    NSDictionary *opts = @{
        (id)kCGImageSourceShouldCache: @YES,
        (id)kCGImageSourceShouldAllowFloat: @YES,
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @256,
        (id)kCGImageSourceShouldCacheImmediately: @YES,
    };
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data,
                                                       (__bridge CFDictionaryRef)opts);
    if (!src) {
        writeResult(@"  source=NULL");
    } else {
        uint64_t v1, r1, p1; readVM(&v1, &r1, &p1);
        writeResult([NSString stringWithFormat:@"  [after CreateWithData] resid=%@ (Δ=+%@)",
                    bytesStr(r1), bytesStr(r1>r0?r1-r0:0)]);

        CFDictionaryRef pp = CGImageSourceCopyProperties(src, NULL);
        uint64_t v2, r2, p2; readVM(&v2, &r2, &p2);
        writeResult([NSString stringWithFormat:@"  [after CopyProperties] resid=%@ (Δ=+%@) props=%p",
                    bytesStr(r2), bytesStr(r2>r0?r2-r0:0), pp]);
        if (pp) CFRelease(pp);

        size_t count = CGImageSourceGetCount(src);
        writeResult([NSString stringWithFormat:@"  count=%zu", count]);
        if (count > 4) count = 4;
        for (size_t i = 0; i < count; i++) {
            CGImageRef img = CGImageSourceCreateImageAtIndex(src, i, (__bridge CFDictionaryRef)opts);
            uint64_t v3, r3, p3; readVM(&v3, &r3, &p3);
            writeResult([NSString stringWithFormat:@"  [after CreateImage[%zu]] resid=%@ (Δ=+%@) img=%p",
                        i, bytesStr(r3), bytesStr(r3>r0?r3-r0:0), img]);
            if (img) CGImageRelease(img);

            CGImageRef th = CGImageSourceCreateThumbnailAtIndex(src, i, (__bridge CFDictionaryRef)opts);
            uint64_t v4, r4, p4; readVM(&v4, &r4, &p4);
            writeResult([NSString stringWithFormat:@"  [after CreateThumb[%zu]] resid=%@ (Δ=+%@) thumb=%p",
                        i, bytesStr(r4), bytesStr(r4>r0?r4-r0:0), th]);
            if (th) CGImageRelease(th);
        }
        CFRelease(src);
    }
    uint64_t vF, rF, pF; readVM(&vF, &rF, &pF);
    writeResult([NSString stringWithFormat:@"[VM after] virt=%@ resid=%@ phys=%@ (Δresid=+%@)",
                bytesStr(vF), bytesStr(rF), bytesStr(pF), bytesStr(rF>r0?rF-r0:0)]);
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)application
  didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSURL *docs = [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                              inDomains:NSUserDomainMask] firstObject];
    [[NSFileManager defaultManager] removeItemAtURL:
       [docs URLByAppendingPathComponent:@"result.txt"] error:nil];
    writeResult([NSString stringWithFormat:@"=== ImageProbe v2 boot %@ ===", NSDate.date]);

    NSString *p = [NSBundle.mainBundle pathForResource:@"payload-image" ofType:@"bin"];
    if (p) {
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (d) probeImage(d);
    }
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = UIColor.systemGreenColor;
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class])); }
}
