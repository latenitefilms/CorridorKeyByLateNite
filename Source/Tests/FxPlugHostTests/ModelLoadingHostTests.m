#import <FxPlug/FxPlugSDK.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <unistd.h>

/// The startup probe never supplies frames or a connection to Final Cut Pro.
@interface ModelLoadingTestHost : NSObject <PROAPIAccessing>
@end

@implementation ModelLoadingTestHost
- (id)apiForProtocol:(Protocol *)apiProtocol { return nil; }
@end

/// Avoids global GPU teardown racing a background warm-up in a failing build.
static _Noreturn void finishProbe(int status) {
    fflush(stdout);
    _Exit(status);
}

/// Physical footprint includes unified-memory allocations that RSS can miss.
static uint64_t physicalFootprint(void) {
    task_vm_info_data_t information = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(), TASK_VM_INFO,
                                    (task_info_t)&information, &count);
    if (result != KERN_SUCCESS) {
        fprintf(stdout, "FAIL: could not measure process footprint (%d).\n", result);
        finishProbe(1);
    }
    return information.phys_footprint;
}

/// Runs after production main.swift but replaces the blocking XPC host handoff.
/// The real production initializer and property callback execute unchanged.
static void inspectIdleRenderer(id principal, SEL selector, id delegate) {
    @autoreleasepool {
        Class pluginClass = NSClassFromString(@"CorridorKeyToolboxPlugIn");
        if (!pluginClass) {
            fprintf(stdout, "FAIL: production plug-in class is unavailable.\n");
            finishProbe(1);
        }
        ModelLoadingTestHost *host = [ModelLoadingTestHost new];
        NSMutableArray *instances = [NSMutableArray new];
        for (NSUInteger index = 0; index < 10; index++) {
            id<FxTileableEffect> plugin = [[pluginClass alloc] initWithAPIManager:host];
            NSDictionary *properties = nil;
            NSError *error = nil;
            if (!plugin || ![plugin properties:&properties error:&error]) {
                fprintf(stdout, "FAIL: plug-in construction or property discovery failed.\n");
                finishProbe(1);
            }
            [instances addObject:plugin];
        }

        // Allow an accidentally scheduled background import to become visible.
        // A model-free renderer should remain far below this generous budget;
        // the bundled v2 weights alone occupy several gigabytes when loaded.
        const uint64_t limit = 256ULL * 1024 * 1024;
        uint64_t peak = 0;
        for (NSUInteger sample = 0; sample <= 20; sample++) {
            peak = MAX(peak, physicalFootprint());
            if (sample == 20) { break; }
            sleep(1);
        }
        fprintf(stdout, "%s: idle renderer with %lu instances; peak physical footprint %.2f MiB (limit 256 MiB).\n",
                peak <= limit ? "PASS" : "FAIL", (unsigned long)instances.count,
                (double)peak / (1024 * 1024));
        finishProbe(peak <= limit ? 0 : 1);
    }
}

/// Test-only interposition. No production source or installed process is changed.
__attribute__((constructor))
static void installHeadlessPrincipal(void) {
    Method method = class_getClassMethod([FxPrincipal class], @selector(startServicePrincipalWithDelegate:));
    if (!method) {
        fprintf(stdout, "FAIL: FxPlug service entry point is unavailable.\n");
        finishProbe(1);
    }
    method_setImplementation(method, (IMP)inspectIdleRenderer);
}
