/*
 * host.m — 单窗口嵌入验证宿主。
 * QEMU 作为动态库在本进程内运行，画面渲染进本窗口的 contentView。
 * 用法: ./host <实例目录>
 */
#import <Cocoa/Cocoa.h>

int andropod_qemu_start(int argc, char **argv);
void andropod_qemu_set_host_view(void *view);

#define MAX_ARGS 256

static NSView *gScreen;

static int load_argv(const char *dir, char *storage[], int max)
{
    char path[1024], buf[8192];
    snprintf(path, sizeof(path), "%s/qemu.cmd", dir);
    FILE *fp = fopen(path, "r");
    if (!fp) { perror(path); exit(2); }

    int n = 0;
    while (fgets(buf, sizeof(buf), fp) && n < max - 8) {
        size_t len = strlen(buf);
        while (len && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) buf[--len] = 0;
        if (!len) continue;
        storage[n++] = strdup(buf);
    }
    fclose(fp);
    return n;
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    NSLog(@"[host] didFinishLaunching, main thread=%d", (int)[NSThread isMainThread]);

    NSRect frame = NSMakeRect(0, 0, 460, 820);
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    [win setTitle:@"AndroPod 单窗口嵌入"];
    [win center];

    gScreen = [[NSView alloc] initWithFrame:frame];
    [gScreen setWantsLayer:YES];
    [[gScreen layer] setBackgroundColor:[[NSColor blackColor] CGColor]];
    [win setContentView:gScreen];
    [win makeKeyAndOrderFront:nil];

    const char *dir = [[[NSProcessInfo processInfo] arguments] count] > 1
        ? [[[[NSProcessInfo processInfo] arguments] objectAtIndex:1] UTF8String] : NULL;
    if (!dir) { NSLog(@"usage: host <instance-dir>"); [NSApp terminate:nil]; return; }

    static char *args[MAX_ARGS];
    int n = load_argv(dir, args, MAX_ARGS);

    char *out[MAX_ARGS];
    int m = 0;
    out[m++] = "qemu-system-aarch64";
    const char *bios = getenv("ANDROPOD_BIOS");
    if (bios) { out[m++] = "-L"; out[m++] = (char *)bios; }
    int force2d = getenv("ANDROPOD_2D") != NULL;
    for (int i = 1; i < n; i++) {
        if (!strcmp(args[i], "-qmp")) { i++; continue; }   /* 控制 socket 不必开 */
        if (force2d && !strcmp(args[i], "-display")) {
            i++;
            out[m++] = "-display";
            out[m++] = "cocoa";
            continue;
        }
        if (force2d && !strcmp(args[i], "-device") && i + 1 < n &&
            !strncmp(args[i + 1], "virtio-gpu-gl-pci", 17)) {
            out[m++] = "-device";
            out[m++] = "virtio-gpu-pci";
            i++;
            continue;
        }
        out[m++] = args[i];
    }

    andropod_qemu_set_host_view((__bridge void *)gScreen);

    NSLog(@"[host] calling andropod_qemu_start, argv=%d", m);
    @try {
        if (andropod_qemu_start(m, out) != 0) {
            NSLog(@"[host] qemu start failed");
            [NSApp terminate:nil];
            return;
        }
    } @catch (NSException *e) {
        NSLog(@"[host] EXCEPTION %@: %@", e.name, e.reason);
        NSLog(@"[host] stack: %@", [e.callStackSymbols componentsJoinedByString:@"\n"]);
    }

    NSLog(@"[host] andropod_qemu_start returned");

    /* 把键盘焦点交给 QEMU 的视图，否则按键进不去客机 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSView *target = gScreen.subviews.count ? gScreen.subviews.firstObject : gScreen;
        [win makeFirstResponder:target];
        NSLog(@"[host] first responder -> %@", target);
    });
}
@end

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
