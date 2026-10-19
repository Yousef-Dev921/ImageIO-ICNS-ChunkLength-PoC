// nsimage_steps.m — isolate where the memory commit actually happens
#import <Cocoa/Cocoa.h>
#import <mach/mach.h>
static uint64_t rd(void) {
    task_vm_info_data_t i; mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
    task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&i, &c);
    return i.resident_size;
}
static void step(const char *label, uint64_t r0) {
    uint64_t r = rd();
    fprintf(stderr, "  %-40s  resident=%.2f MiB  Δ=+%lld bytes\n",
        label, r/(double)(1<<20), (long long)(r - r0));
}
int main(int argc, char *argv[]) {
    if (argc < 2) return 2;
    uint64_t r0 = rd();
    fprintf(stderr, "[start]   resident=%.2f MiB\n\n", r0/(double)(1<<20));

    @autoreleasepool {
        // Step 1: read file
        NSData *d = [NSData dataWithContentsOfFile:@(argv[1])];
        step("after NSData", r0);

        // Step 2: ONLY NSImage initWithData (no rep access yet)
        NSImage *img = [[NSImage alloc] initWithData:d];
        step("after NSImage initWithData:", r0);

        // Step 3: ask NSImage for its size (lazy)
        if (img) { NSSize sz = [img size]; (void)sz; }
        step("after [img size]", r0);

        // Step 4: ask for representations array (lazy)
        NSArray *reps = img ? [img representations] : nil;
        step("after [img representations]", r0);

        // Step 5: actually inspect rep dimensions
        if (reps.count > 0) {
            NSImageRep *rep = reps[0];
            (void)[rep pixelsWide];
            (void)[rep pixelsHigh];
        }
        step("after rep pixel access", r0);

        // Step 6: separately try NSBitmapImageRep initWithData
        NSBitmapImageRep *bm = [[NSBitmapImageRep alloc] initWithData:d];
        step("after NSBitmapImageRep initWithData:", r0);

        if (bm) {
            (void)[bm pixelsWide];
            (void)[bm pixelsHigh];
        }
        step("after NSBitmapImageRep pixel access", r0);
    }
    step("after @autoreleasepool drained", r0);
    return 0;
}
