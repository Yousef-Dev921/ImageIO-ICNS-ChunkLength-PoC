// vm_probe.m — measure actual VM commit during ImageIO / AVAsset parsing.
//
// Samples task_info(TASK_VM_INFO) before and after invoking the parser
// to detect whether the framework actually requests/commits memory or
// gracefully fails the allocation upstream.
//
// Output: before/after virtual_size, resident_size, peak_resident, and
// the high-water virtual_size during a multi-thread sampler loop.
//
// Usage: vm_probe FILE [image|font|media]

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <AVFoundation/AVFoundation.h>
#import <mach/mach.h>
#import <mach/task_info.h>
#import <pthread.h>
#import <stdatomic.h>

static atomic_uint_least64_t g_peak_virt = 0;
static atomic_uint_least64_t g_peak_resid = 0;
static atomic_bool g_sample_run = true;

static void read_vm_info(uint64_t *virt, uint64_t *resid,
                         uint64_t *phys_footprint, uint64_t *peak_resid) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO,
                                 (task_info_t)&info, &count);
    if (kr == KERN_SUCCESS) {
        *virt = info.virtual_size;
        *resid = info.resident_size;
        *phys_footprint = info.phys_footprint;
        *peak_resid = info.resident_size_peak;
    } else {
        *virt = *resid = *phys_footprint = *peak_resid = 0;
    }
}

static void *sampler_thread(void *_) {
    while (atomic_load(&g_sample_run)) {
        uint64_t v, r, p, pr;
        read_vm_info(&v, &r, &p, &pr);
        uint64_t old_v = atomic_load(&g_peak_virt);
        while (v > old_v && !atomic_compare_exchange_weak(&g_peak_virt, &old_v, v)) {}
        uint64_t old_r = atomic_load(&g_peak_resid);
        while (r > old_r && !atomic_compare_exchange_weak(&g_peak_resid, &old_r, r)) {}
        usleep(500);  // 500us — high-frequency sampling
    }
    return NULL;
}

static void format_bytes(uint64_t b, char *out) {
    if (b >= (1ULL << 30)) sprintf(out, "%.2f GiB", (double)b / (1<<30));
    else if (b >= (1<<20)) sprintf(out, "%.2f MiB", (double)b / (1<<20));
    else if (b >= (1<<10)) sprintf(out, "%.2f KiB", (double)b / (1<<10));
    else sprintf(out, "%llu B", b);
}

static void probe_image(NSData *d) {
    NSDictionary *opts = @{
        (id)kCGImageSourceShouldCache: @YES,
        (id)kCGImageSourceShouldAllowFloat: @YES,
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @256,
        (id)kCGImageSourceShouldCacheImmediately: @YES,
    };
    CGImageSourceRef src = CGImageSourceCreateWithData(
        (__bridge CFDataRef)d, (__bridge CFDictionaryRef)opts);
    if (!src) { fprintf(stderr, "  CGImageSourceCreateWithData -> NULL\n"); return; }

    CFDictionaryRef p0 = CGImageSourceCopyProperties(src, NULL);
    fprintf(stderr, "  CGImageSourceCopyProperties -> %p\n", p0);
    if (p0) CFRelease(p0);

    size_t count = CGImageSourceGetCount(src);
    fprintf(stderr, "  count=%zu\n", count);
    if (count > 8) count = 8;

    for (size_t i = 0; i < count; i++) {
        CFDictionaryRef p = CGImageSourceCopyPropertiesAtIndex(src, i, NULL);
        if (p) CFRelease(p);
        CGImageRef img = CGImageSourceCreateImageAtIndex(src, i,
            (__bridge CFDictionaryRef)opts);
        fprintf(stderr, "  [%zu] image=%p\n", i, img);
        if (img) CGImageRelease(img);
        CGImageRef thumb = CGImageSourceCreateThumbnailAtIndex(src, i,
            (__bridge CFDictionaryRef)opts);
        fprintf(stderr, "  [%zu] thumb=%p\n", i, thumb);
        if (thumb) CGImageRelease(thumb);
    }
    CFRelease(src);
}

static void probe_font(NSData *d) {
    CTFontDescriptorRef desc = CTFontManagerCreateFontDescriptorFromData(
        (__bridge CFDataRef)d);
    fprintf(stderr, "  desc=%p\n", desc);
    if (!desc) return;
    CTFontRef font = CTFontCreateWithFontDescriptor(desc, 24.0, NULL);
    fprintf(stderr, "  font=%p\n", font);
    if (font) CFRelease(font);
    CFRelease(desc);
}

static void probe_media(NSString *path) {
    NSURL *url = [NSURL fileURLWithPath:path];
    AVURLAsset *a = [[AVURLAsset alloc] initWithURL:url options:nil];
    NSArray *tracks = [a tracks];
    fprintf(stderr, "  tracks=%lu\n", (unsigned long)[tracks count]);
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <file> [image|font|media]\n", argv[0]);
        return 2;
    }
    const char *kind = argc >= 3 ? argv[2] : "image";

    NSString *path = @(argv[1]);
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) { fprintf(stderr, "cannot read %s\n", argv[1]); return 3; }

    uint64_t v0, r0, p0, pr0;
    read_vm_info(&v0, &r0, &p0, &pr0);
    char b1[32], b2[32], b3[32], b4[32];
    format_bytes(v0, b1); format_bytes(r0, b2);
    format_bytes(p0, b3); format_bytes(pr0, b4);
    fprintf(stderr, "[before] virtual=%s resident=%s phys_footprint=%s peak_resid=%s\n",
            b1, b2, b3, b4);

    // Start sampler thread
    pthread_t sampler;
    pthread_create(&sampler, NULL, sampler_thread, NULL);

    fprintf(stderr, "[probe] kind=%s file=%s bytes=%lu\n",
            kind, argv[1], (unsigned long)d.length);

    if (strcmp(kind, "image") == 0) probe_image(d);
    else if (strcmp(kind, "font") == 0) probe_font(d);
    else if (strcmp(kind, "media") == 0) probe_media(path);

    // Stop sampler
    atomic_store(&g_sample_run, false);
    pthread_join(sampler, NULL);

    uint64_t v1, r1, p1, pr1;
    read_vm_info(&v1, &r1, &p1, &pr1);
    format_bytes(v1, b1); format_bytes(r1, b2);
    format_bytes(p1, b3); format_bytes(pr1, b4);
    fprintf(stderr, "[after]  virtual=%s resident=%s phys_footprint=%s peak_resid=%s\n",
            b1, b2, b3, b4);

    uint64_t pv = atomic_load(&g_peak_virt);
    uint64_t pr = atomic_load(&g_peak_resid);
    format_bytes(pv, b1); format_bytes(pr, b2);
    fprintf(stderr, "[peak]   virtual_high_water=%s resident_high_water=%s\n", b1, b2);

    fprintf(stderr, "[delta]  virtual=+%lld resident=+%lld\n",
            (long long)(v1 - v0), (long long)(r1 - r0));
    fprintf(stderr, "[peak delta] virtual_peak=+%lld resident_peak=+%lld\n",
            (long long)(pv - v0), (long long)(pr - r0));
    return 0;
}
