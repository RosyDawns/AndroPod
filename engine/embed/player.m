/*
 * player.m — AndroPod 播放器。
 *
 * 一台实例一个进程：QEMU 以动态库形式跑在本进程内，客机画面直接挂进本进程
 * 的 NSView。管理器只负责列表与开关机，进程间通过实例目录里的
 * qemu.cmd / plan.json / qemu.pid / QMP socket 沟通。
 *
 * 用法:
 *   andropod-player --instance <实例目录> [--snapshot <tag>] [--bios <pc-bios>]
 */
#import <Cocoa/Cocoa.h>

#import <errno.h>
#import <stdlib.h>
#import <fcntl.h>
#import <signal.h>
#import <string.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

int andropod_qemu_start(int argc, char **argv);
void andropod_qemu_set_host_view(void *view);
void qemu_cocoa_relayout(void);

#define MAX_ARGS 512

/* MuMu 式产品壳：画面顶满整个窗口，工具条悬浮在右上角。 */

static NSString *gInstanceDir;
static NSDictionary *gPlan;
static NSWindow *gWindow;
static NSWindow *gEngineWindow;
static NSView *gScreen;          /* QEMU 的宿主视图容器 = 窗口的画面区 */
static NSView *gScreenArea;      /* 画面区视图（gScreen 的父级，黑底） */
static NSView *gToolbar;         /* 右上角悬浮工具条（必须始终在 QEMU 视图之上） */
static BOOL gQuitting;
static BOOL gCloseConfirmed;     /* 关闭确认弹窗里点了「关闭」 */

static NSString *gAdbSerial;

#pragma mark - QMP

/* Minimal QMP client. The player needs exactly three things from QEMU —
 * capabilities, loadvm, cont — and one thing on the way out (quit). Pulling in
 * a full JSON-RPC stack for that would be more code than the protocol. */
@interface QMPClient : NSObject {
    int _fd;
    NSMutableData *_buffer;
}
- (BOOL)connectPath:(NSString *)path timeout:(NSTimeInterval)timeout;
- (NSDictionary *)execute:(NSString *)command
                arguments:(NSDictionary *)arguments
                    error:(NSString **)error
                  timeout:(NSTimeInterval)timeout;
- (void)close;
@end

@implementation QMPClient

- (instancetype)init
{
    if ((self = [super init])) {
        _fd = -1;
        _buffer = [NSMutableData data];
    }
    return self;
}

- (BOOL)connectPath:(NSString *)path timeout:(NSTimeInterval)timeout
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path.fileSystemRepresentation, sizeof(addr.sun_path) - 1);

    while (1) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return NO;
        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
            _fd = fd;
            break;
        }
        int err = errno;
        close(fd);
        if (err != ENOENT && err != ECONNREFUSED) return NO;
        if ([deadline timeIntervalSinceNow] <= 0) return NO;
        usleep(80 * 1000);
    }

    /* The server speaks first: a single greeting line. */
    NSData *greeting = [self readLineWithTimeout:3.0];
    return greeting.length > 0;
}

- (NSData *)readLineWithTimeout:(NSTimeInterval)timeout
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSData *newline = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];

    while (1) {
        NSRange range = [_buffer rangeOfData:newline options:0
                                       range:NSMakeRange(0, _buffer.length)];
        if (range.location != NSNotFound) {
            NSData *line = [_buffer subdataWithRange:NSMakeRange(0, range.location)];
            [_buffer replaceBytesInRange:NSMakeRange(0, range.location + 1)
                               withBytes:NULL length:0];
            return line;
        }

        NSTimeInterval remain = [deadline timeIntervalSinceNow];
        if (remain <= 0 || _fd < 0) return nil;

        struct timeval tv;
        tv.tv_sec = (time_t)remain;
        tv.tv_usec = (suseconds_t)((remain - tv.tv_sec) * 1e6);
        fd_set set;
        FD_ZERO(&set);
        FD_SET(_fd, &set);
        int ready = select(_fd + 1, &set, NULL, NULL, &tv);
        if (ready <= 0) continue;

        uint8_t chunk[8192];
        ssize_t n = recv(_fd, chunk, sizeof(chunk), 0);
        if (n <= 0) return nil;
        [_buffer appendBytes:chunk length:(NSUInteger)n];
    }
}

- (NSDictionary *)execute:(NSString *)command
                arguments:(NSDictionary *)arguments
                    error:(NSString **)error
                  timeout:(NSTimeInterval)timeout
{
    if (_fd < 0) {
        if (error) *error = @"QMP 未连接";
        return nil;
    }

    NSMutableDictionary *request = [NSMutableDictionary dictionary];
    request[@"execute"] = command;
    request[@"id"] = @"andropod";
    if (arguments) request[@"arguments"] = arguments;

    NSData *json = [NSJSONSerialization dataWithJSONObject:request options:0 error:NULL];
    NSMutableData *payload = [json mutableCopy];
    [payload appendBytes:"\n" length:1];
    if (send(_fd, payload.bytes, payload.length, 0) < 0) {
        if (error) *error = @"QMP 写入失败";
        return nil;
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (1) {
        NSTimeInterval remain = [deadline timeIntervalSinceNow];
        if (remain <= 0) break;
        NSData *line = [self readLineWithTimeout:remain];
        if (!line) break;

        NSDictionary *message =
            [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
        if (![message isKindOfClass:[NSDictionary class]]) continue;
        if (message[@"event"]) continue;          /* async event, not our reply */
        if (message[@"error"]) {
            if (error) {
                id desc = message[@"error"][@"desc"];
                *error = [desc isKindOfClass:[NSString class]] ? desc : @"QMP 返回错误";
            }
            return nil;
        }
        return message;
    }

    if (error) *error = @"QMP 等待回复超时";
    return nil;
}

- (void)close
{
    if (_fd >= 0) {
        close(_fd);
        _fd = -1;
    }
}

@end

#pragma mark - helpers

static NSString *read_text(NSString *path)
{
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    return text;
}

static id read_json(NSString *path)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
}

static void write_json(id object, NSString *path)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:NULL];
    [data writeToFile:path atomically:NO];
}

static NSString *frame_path(NSString *dir)
{
    return [dir stringByAppendingPathComponent:@"window.json"];
}

static void save_frame(void)
{
    if (!gWindow || !gInstanceDir) return;
    NSRect frame = gWindow.frame;
    write_json(@{
        @"x": @(frame.origin.x),
        @"y": @(frame.origin.y),
        @"w": @(frame.size.width),
        @"h": @(frame.size.height),
    }, frame_path(gInstanceDir));
}

static BOOL frame_is_usable(NSRect frame)
{
    if (frame.size.width < 200 || frame.size.height < 200) return NO;
    for (NSScreen *screen in [NSScreen screens]) {
        NSRect visible = screen.visibleFrame;
        NSRect overlap = NSIntersectionRect(frame, visible);
        /* Keep the titlebar reachable: a frame fully outside every display is
         * what you get after unplugging the monitor it was saved on. */
        if (overlap.size.width > 120 && overlap.size.height > 80) return YES;
    }
    return NO;
}

static NSRect restored_frame(NSRect fallback)
{
    NSDictionary *saved = read_json(frame_path(gInstanceDir));
    if (![saved isKindOfClass:[NSDictionary class]]) return fallback;

    NSRect frame = NSMakeRect([saved[@"x"] doubleValue], [saved[@"y"] doubleValue],
                              [saved[@"w"] doubleValue], [saved[@"h"] doubleValue]);
    return frame_is_usable(frame) ? frame : fallback;
}

/* Reads qemu.cmd and rewrites the display/console bits that only make sense for
 * a standalone QEMU. Everything else — devices, disks, QMP sockets, kernel and
 * cmdline — is passed through untouched, because that is exactly what the CLI
 * already validated. */
static int build_argv(NSString *dir, NSString *bios, char *storage[], int max)
{
    NSString *cmd = read_text([dir stringByAppendingPathComponent:@"qemu.cmd"]);
    if (!cmd) {
        fprintf(stderr, "[player] qemu.cmd missing in %s\n", dir.fileSystemRepresentation);
        return -1;
    }

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *line in [cmd componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length) [lines addObject:trimmed];
    }

    BOOL gl = NO;
    for (NSString *line in lines) {
        if ([line containsString:@"virtio-gpu-gl"]) { gl = YES; break; }
    }

    int n = 0;
    storage[n++] = strdup("qemu-system-aarch64");
    if (bios.length) {
        storage[n++] = strdup("-L");
        storage[n++] = strdup(bios.fileSystemRepresentation);
    }

    /* lines[0] is the host qemu binary; the embedded engine ignores it. */
    for (NSUInteger i = 1; i < lines.count && n < max - 4; i++) {
        NSString *line = lines[i];

        if ([line isEqualToString:@"-display"]) {
            /* The player *is* the display. cocoa with gl=es is what gives
             * virtio-gpu-gl a host GL context (ANGLE → Metal) — and in embed
             * mode cocoa attaches its view to ours instead of opening a window. */
            storage[n++] = strdup("-display");
            storage[n++] = strdup(gl ? "cocoa,gl=es,zoom-interpolation=on" : "cocoa,zoom-interpolation=on");
            i++;                       /* drop the old backend value */
            continue;
        }
        if ([line isEqualToString:@"-vnc"]) {
            i++;                       /* frames go to our own window, not RFB */
            continue;
        }

        storage[n++] = strdup(line.fileSystemRepresentation);
    }
    storage[n] = NULL;
    return n;
}

static NSString *locate_bios(NSString *override)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if (override.length) [candidates addObject:override];

    NSString *bundle = [[NSBundle mainBundle] bundlePath];
    if (bundle.length) {
        [candidates addObject:[bundle stringByAppendingPathComponent:@"Contents/Resources/pc-bios"]];
    }
    [candidates addObject:[NSHomeDirectory()
        stringByAppendingPathComponent:@"AndroPod/third_party/qemu-10.1.2/pc-bios"]];

    for (NSString *path in candidates) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:path isDirectory:&isDir] && isDir) return path;
    }
    return nil;
}

@interface PlayerDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

@implementation PlayerDelegate

#pragma mark - guest controls (MuMu 式工具栏的后端)

/* guest 分辨率（工具栏 fit 布局用）。 */
static void guest_resolution(double *xres, double *yres)
{
    double x = [gPlan[@"xres"] doubleValue];
    double y = [gPlan[@"yres"] doubleValue];
    if (x < 200 || y < 200) { x = 1280; y = 800; }
    *xres = x;
    *yres = y;
}

/* 从 qemu.cmd 的 hostfwd 规则解出 adb serial（guest 5555 对应的宿主端口）。 */
static NSString *adb_serial(void)
{
    if (gAdbSerial) return gAdbSerial;
    NSString *cmd = read_text([gInstanceDir stringByAppendingPathComponent:@"qemu.cmd"]);
    if (!cmd) return nil;
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"hostfwd=tcp:127\\.0\\.0\\.1:(\\d+)-:5555"
                             options:0 error:NULL];
    NSTextCheckingResult *m = [re firstMatchInString:cmd options:0
                                               range:NSMakeRange(0, cmd.length)];
    if (m.numberOfRanges > 1) {
        gAdbSerial = [NSString stringWithFormat:@"127.0.0.1:%@",
                      [cmd substringWithRange:[m rangeAtIndex:1]]];
    }
    return gAdbSerial;
}

static NSString *adb_binary(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in @[@"/opt/homebrew/bin/adb", @"/usr/local/bin/adb", @"/usr/bin/adb"]) {
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

/* 后台跑一条 adb。onDone 在主线程回调（output 为 stdout+stderr）。 */
static void adb_run(NSArray<NSString *> *arguments,
                    void (^onDone)(NSString *output, BOOL ok))
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *serial = adb_serial();
        NSString *adb = adb_binary();
        if (!serial || !adb) {
            if (onDone) onDone(@"找不到 adb 或实例端口", NO);
            return;
        }

        NSMutableArray *argv = [NSMutableArray arrayWithObjects:@"-s", serial, nil];
        [argv addObjectsFromArray:arguments];

        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:adb];
        task.arguments = argv;
        NSPipe *outPipe = [NSPipe pipe];
        NSPipe *errPipe = [NSPipe pipe];
        task.standardOutput = outPipe;
        task.standardError = errPipe;

        NSError *err = nil;
        if (![task launchAndReturnError:&err]) {
            if (onDone) onDone(err.localizedDescription ?: @"adb 启动失败", NO);
            return;
        }
        NSData *out = [outPipe.fileHandleForReading readDataToEndOfFile];
        NSData *errData = [errPipe.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];

        NSMutableString *text = [NSMutableString string];
        if (out.length) [text appendString:[[[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        if (errData.length) [text appendString:[[[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        BOOL ok = task.terminationStatus == 0;
        if (onDone) dispatch_async(dispatch_get_main_queue(), ^{
            onDone(text, ok);
        });
    });
}

- (void)guestKeycode:(int)code
{
    adb_run(@[@"shell", [NSString stringWithFormat:@"input keyevent %d", code]], nil);
}

- (void)takeScreenshot
{
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd-HHmmss";
    NSString *stamp = [fmt stringFromDate:[NSDate date]];
    NSString *dst = [NSString stringWithFormat:@"%@/Desktop/AndroPod-%@.png", NSHomeDirectory(), stamp];
    adb_run(@[@"shell", @"screencap", @"-p", @"/sdcard/andropod-shot.png"], ^(NSString *out, BOOL ok) {
        if (!ok) {
            NSAlert *a = [NSAlert new];
            a.messageText = @"截图失败";
            a.informativeText = out ?: @"adb 不可用";
            [a runModal];
            return;
        }
        adb_run(@[@"pull", @"/sdcard/andropod-shot.png", dst], ^(NSString *out2, BOOL ok2) {
            NSAlert *a = [NSAlert new];
            a.messageText = ok2 ? @"截图已保存" : @"截图失败";
            a.informativeText = ok2 ? dst : out2;
            [a runModal];
        });
    });
}

- (void)installApk
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes = @[ @"apk" ];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.message = @"选择要安装的 APK";
    [panel beginSheetModalForWindow:gWindow completionHandler:^(NSModalResponse rc) {
        if (rc != NSModalResponseOK) return;
        NSString *apk = panel.URLs.firstObject.path;
        if (!apk.length) return;

        /* 安装可能要几十秒：先给一个模态提示，完成后弹结果。 */
        NSAlert *wait = [NSAlert new];
        wait.messageText = @"正在安装 APK…";
        wait.informativeText = apk.lastPathComponent;
        [wait addButtonWithTitle:@"后台继续"];
        [wait beginSheetModalForWindow:gWindow completionHandler:^(NSModalResponse) { }];

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString *serial = adb_serial();
            NSString *adb = adb_binary();
            if (!serial || !adb) return;
            NSTask *task = [NSTask new];
            task.executableURL = [NSURL fileURLWithPath:adb];
            task.arguments = @[ @"-s", serial, @"install", @"-r", apk ];
            NSPipe *outPipe = [NSPipe pipe];
            task.standardOutput = outPipe;
            task.standardError = outPipe;
            NSError *err = nil;
            if (![task launchAndReturnError:&err]) return;
            NSData *out = [outPipe.fileHandleForReading readDataToEndOfFile];
            [task waitUntilExit];
            NSString *text = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] ?: @"";
            BOOL ok = task.terminationStatus == 0 && [text containsString:@"Success"];
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSApp endSheet:wait.window];
                NSAlert *a = [NSAlert new];
                a.messageText = ok ? @"安装成功" : @"安装失败";
                a.informativeText = ok ? apk.lastPathComponent : text;
                [a runModal];
            });
        });
    }];
}

- (NSButton *)toolButton:(NSString *)symbol tip:(NSString *)tip action:(SEL)sel
{
    NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 32, 28)];
    b.bezelStyle = NSBezelStyleTexturedRounded;
    b.bordered = NO;
    NSImage *img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip];
    if (img) {
        NSImageSymbolConfiguration *cfg =
            [NSImageSymbolConfiguration configurationWithPointSize:13 weight:5];
        b.image = [img imageWithSymbolConfiguration:cfg];
    }
    b.toolTip = tip;
    b.target = self;
    b.action = sel;
    b.contentTintColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.92];
    return b;
}

- (NSView *)toolSeparator
{
    NSView *line = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1, 18)];
    line.wantsLayer = YES;
    line.layer.backgroundColor =
        [NSColor colorWithCalibratedWhite:1.0 alpha:0.25].CGColor;
    return line;
}

/* MuMu 的工具条：右上角悬浮的半透明深色胶囊，横排。 */
- (NSView *)buildToolbar
{
    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.spacing = 8;
    stack.alignment = NSLayoutAttributeCenterY;

    NSArray *items = @[
        @[@"chevron.backward",    @"返回",   NSStringFromSelector(@selector(goBack:))],
        @[@"square.stack.3d.up",  @"最近任务", NSStringFromSelector(@selector(goRecents:))],
        @[@"house",               @"主页",   NSStringFromSelector(@selector(goHome:))],
        @"sep",
        @[@"speaker.wave.2",      @"音量+",  NSStringFromSelector(@selector(volumeUp:))],
        @[@"speaker.wave.1",      @"音量−",  NSStringFromSelector(@selector(volumeDown:))],
        @"sep",
        @[@"camera.viewfinder",   @"截图（保存到桌面）", NSStringFromSelector(@selector(takeScreenshot))],
        @[@"square.and.arrow.down", @"安装 APK", NSStringFromSelector(@selector(installApk))],
        @"sep",
        @[@"arrow.up.left.and.arrow.down.right", @"全屏",
          NSStringFromSelector(@selector(toggleFull:))],
    ];

    for (id item in items) {
        if ([item isKindOfClass:[NSString class]]) {
            [stack addArrangedSubview:[self toolSeparator]];
        } else {
            [stack addArrangedSubview:[self toolButton:item[0] tip:item[1]
                                                action:NSSelectorFromString(item[2])]];
        }
    }

    NSView *pill = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 10, 36)];
    pill.wantsLayer = YES;
    pill.layer.backgroundColor =
        [NSColor colorWithCalibratedWhite:0.0 alpha:0.42].CGColor;
    pill.layer.cornerRadius = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [pill addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:pill.topAnchor constant:4],
        [stack.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-4],
        [stack.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-12],
    ]];
    gToolbar = pill;
    return pill;
}

- (void)goBack:(id)sender       { [self guestKeycode:4]; }
- (void)goHome:(id)sender       { [self guestKeycode:3]; }
- (void)goRecents:(id)sender    { [self guestKeycode:187]; }
- (void)volumeUp:(id)sender     { [self guestKeycode:24]; }
- (void)volumeDown:(id)sender   { [self guestKeycode:25]; }
- (void)toggleFull:(id)sender   { [gWindow toggleFullScreen:sender]; }

/* 把 QEMU 的视图按客机比例 fit 居中放进画面区。2D 渲染是 CGImage 直接按视图
 * 坐标绘制，任意尺寸都成立；virgl 的 EGL surface 由 relayout 回调跟随。 */
/* 把 QEMU 的视图铺满画面区（2D 渲染按视图坐标绘制，任意尺寸成立；MuMu 的
 * 画面同样顶满窗口）。比例失真交给窗口比例——初始窗口就是客机比例。
 * 只匹配 QEMU 自己的视图类：工具条也是 gScreen 的子视图，不能被拉伸。 */
- (void)fitGuestView
{
    for (NSView *view in gScreen.subviews) {
        if ([NSStringFromClass([view class]) containsString:@"QemuCocoaView"]) {
            [view setFrame:gScreen.bounds];
            return;
        }
    }
}

#pragma mark - delegate

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    NSArray<NSString *> *arguments = [[NSProcessInfo processInfo] arguments];
    NSString *biosOverride = nil;
    for (NSUInteger i = 1; i < arguments.count; i++) {
        if ([arguments[i] isEqualToString:@"--instance"] && i + 1 < arguments.count) {
            gInstanceDir = [arguments[++i] stringByExpandingTildeInPath];
        } else if ([arguments[i] isEqualToString:@"--bios"] && i + 1 < arguments.count) {
            biosOverride = [arguments[++i] stringByExpandingTildeInPath];
        }
    }
    if (!gInstanceDir) {
        fprintf(stderr, "[player] usage: andropod-player --instance <dir>\n");
        [NSApp terminate:nil];
        return;
    }

    gPlan = read_json([gInstanceDir stringByAppendingPathComponent:@"plan.json"]);
    if (![gPlan isKindOfClass:[NSDictionary class]]) gPlan = @{};

    NSString *title = gPlan[@"name"] ?: gInstanceDir.lastPathComponent;
    double xres = [gPlan[@"xres"] doubleValue];
    double yres = [gPlan[@"yres"] doubleValue];
    if (xres < 200 || yres < 200) { xres = 1280; yres = 800; }

    /* Match the geometry QEMU gives its own window: one guest pixel per screen
     * pixel, expressed in points. The GL surface is then 1:1 and nothing has
     * to rescale the framebuffer. */
    NSScreen *screen = [NSScreen mainScreen];
    CGFloat backing = screen ? screen.backingScaleFactor : 1.0;
    NSRect visible = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);

    /* MuMu 式窗口：画面顶满整个窗口，工具条悬浮在右上角。 */
    NSRect frame = NSMakeRect(0, 0, xres / backing, yres / backing);
    /* Only the position is remembered: the size follows the guest resolution. */
    NSRect saved = restored_frame(NSZeroRect);
    BOOL placed = saved.size.width > 0;
    if (placed) frame.origin = saved.origin;

    gWindow = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered
        defer:NO];
    [gWindow setTitle:title];
    [gWindow setDelegate:self];
    [gWindow setAcceptsMouseMovedEvents:YES];

    gScreen = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    gScreen.wantsLayer = YES;
    gScreen.layer.backgroundColor = [[NSColor blackColor] CGColor];
    gScreen.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    gScreenArea = gScreen;
    [gWindow setContentView:gScreen];

    NSView *toolbar = [self buildToolbar];
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [gScreen addSubview:toolbar];
    [NSLayoutConstraint activateConstraints:@[
        [toolbar.topAnchor constraintEqualToAnchor:gScreen.topAnchor constant:10],
        [toolbar.trailingAnchor constraintEqualToAnchor:gScreen.trailingAnchor constant:-12],
    ]];

    [gWindow makeKeyAndOrderFront:nil];
    if (!placed) [gWindow center];

    [self installMenu];
    [NSApp activateIgnoringOtherApps:YES];

    NSString *bios = locate_bios(biosOverride);
    if (!bios) {
        [self fail:@"找不到 QEMU 固件目录（pc-bios）。请重新安装应用。" exit:YES];
        return;
    }

    static char *storage[MAX_ARGS];
    int argc = build_argv(gInstanceDir, bios, storage, MAX_ARGS);
    if (argc <= 0) {
        [self fail:@"实例缺少 qemu.cmd，请先在管理器里重新设置该实例。" exit:NO];
    }

    /* The manager's liveness check reads this file; inside the player the QEMU
     * pid *is* our pid, so write it before the engine starts. */
    NSString *pidPath = gPlan[@"pid_file"] ?:
        [gInstanceDir stringByAppendingPathComponent:@"qemu.pid"];
    [[@(getpid()) stringValue] writeToFile:pidPath
                                     atomically:NO
                                       encoding:NSUTF8StringEncoding
                                          error:NULL];

    /* Hand QEMU our view *before* qemu_init: with a host view it skips creating
     * its own window and attaches the guest console to this one. */
    andropod_qemu_set_host_view((__bridge void *)gScreen);

    if (andropod_qemu_start(argc, storage) != 0) {
        [self fail:@"QEMU 启动失败，详情见 player.log。" exit:NO];
    }

    /* The console mode arrives a moment later; re-fit the guest view (both the
     * initial frame and the GL surface) once it has its final size. */
    for (double delay = 0.2; delay <= 2.0; delay += 0.2) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self relayoutEngine];
        });
    }

    NSString *snapshot = gPlan[@"snapshot"];
    if ([snapshot isKindOfClass:[NSString class]] && snapshot.length) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self restoreSnapshot:snapshot];
        });
    }
}

- (void)installMenu
{
    NSMenu *mainMenu = [[NSMenu alloc] init];

    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"关于 AndroPod"
                      action:@selector(orderFrontStandardAboutPanel:)
               keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"关闭模拟器…"
                                                 action:@selector(requestClose:)
                                          keyEquivalent:@"q"];
    [quit setTarget:self];
    [appMenu addItem:quit];
    [appItem setSubmenu:appMenu];

    NSMenuItem *viewItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:viewItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"显示"];
    NSMenuItem *full = [[NSMenuItem alloc] initWithTitle:@"全屏"
                                                  action:@selector(toggleFullScreen:)
                                           keyEquivalent:@"f"];
    [full setKeyEquivalentModifierMask:NSEventModifierFlagControl | NSEventModifierFlagCommand];
    [viewMenu addItem:full];
    [viewItem setSubmenu:viewMenu];

    [NSApp setMainMenu:mainMenu];
}

/* Snapshot restore is the difference between "a few seconds" and "25 seconds"
 * of boot, but the saved state only matches the hardware it was taken on.
 *
 * Failure is not fatal: QEMU was started with -S, so the guest is still sitting
 * at the reset vector. Loading the state is an optimisation — if it does not
 * apply, `cont` simply boots normally. The marker file tells `plan` to skip the
 * attempt next time so the user does not pay for it on every power-on. */
- (void)restoreSnapshot:(NSString *)tag
{
    NSString *path = gPlan[@"qmp"] ?:
        [gInstanceDir stringByAppendingPathComponent:@"qmp.sock"];
    QMPClient *client = [[QMPClient alloc] init];
    if (![client connectPath:path timeout:20.0]) {
        NSLog(@"[player] QMP unavailable, cold booting");
        return;
    }

    NSString *error = nil;
    if (![client execute:@"qmp_capabilities" arguments:nil error:&error timeout:5.0]) {
        NSLog(@"[player] qmp_capabilities failed: %@", error);
        [client close];
        return;
    }

    NSLog(@"[player] restoring snapshot %@", tag);
    NSDate *started = [NSDate date];
    NSDictionary *reply = [client execute:@"human-monitor-command"
                              arguments:@{@"command-line":
                                  [NSString stringWithFormat:@"loadvm %@", tag]}
                                  error:&error
                                timeout:180.0];

    /* HMP reports failures inside the return string, not as a QMP error. */
    id result = reply[@"return"];
    BOOL bad = (reply == nil) || ([result isKindOfClass:[NSString class]] &&
        [result rangeOfString:@"error" options:NSCaseInsensitiveSearch].location != NSNotFound);

    if (bad) {
        NSString *note = [NSString stringWithFormat:@"loadvm %@: %@ / %@", tag,
                          error ?: @"", [result isKindOfClass:[NSString class]] ? result : @""];
        [note writeToFile:[gInstanceDir stringByAppendingPathComponent:@"snapshot-invalid"]
               atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        NSLog(@"[player] snapshot not restorable (%@), cold booting", note);
        [client execute:@"cont" arguments:nil error:NULL timeout:5.0];
        [client close];
        return;
    }

    [client execute:@"cont" arguments:nil error:NULL timeout:5.0];
    NSLog(@"[player] snapshot restored in %.2fs",
          -[started timeIntervalSinceNow]);

    /* Release the control socket: QEMU's QMP server accepts exactly one client,
     * and the manager needs it for status, input and shutdown. */
    [client close];
}

- (void)fail:(NSString *)message exit:(BOOL)exitAfter
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"AndroPod 无法启动这台设备";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"关闭"];
    [alert runModal];
    if (exitAfter) {
        gQuitting = YES;       /* nothing left to tear down cleanly */
        [NSApp terminate:nil];
    }
}

#pragma mark window lifecycle

/* 用户入口（窗口关闭按钮 / Cmd+Q 菜单）：先确认，再关机。
 * 确认 = shutdown；取消 = 什么都不发生。 */
- (void)requestClose:(id)sender
{
    if (gQuitting || gCloseConfirmed) {
        [self shutdown:nil];
        return;
    }
    NSWindow *win = gWindow ?: ([sender isKindOfClass:[NSWindow class]] ? sender : nil);
    if (!win) {
        [self shutdown:nil];
        return;
    }

    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"要关闭「%@」吗？", win.title];
    alert.informativeText = @"客机将正常关机，正在运行的应用会被结束。";
    [alert addButtonWithTitle:@"关闭"];
    [alert addButtonWithTitle:@"取消"];
    [alert beginSheetModalForWindow:win completionHandler:^(NSModalResponse rc) {
        if (rc == NSAlertFirstButtonReturn) {
            gCloseConfirmed = YES;
            [self shutdown:nil];
        }
        /* 取消：什么都不做。 */
    }];
}

- (BOOL)windowShouldClose:(NSWindow *)sender
{
    if (gQuitting) return YES;   /* AppKit 终止流程中放行（否则退出被取消） */

    /* 第一次点关闭：弹确认。取消 = 什么都不发生；确认 = 才真正开始关机。 */
    if (!gCloseConfirmed) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = [NSString stringWithFormat:@"要关闭「%@」吗？", sender.title];
        alert.informativeText = @"客机将正常关机，正在运行的应用会被结束。";
        [alert addButtonWithTitle:@"关闭"];
        [alert addButtonWithTitle:@"取消"];
        [alert beginSheetModalForWindow:sender completionHandler:^(NSModalResponse rc) {
            if (rc == NSAlertFirstButtonReturn) {
                gCloseConfirmed = YES;
                [sender performClose:nil];
            }
            /* 取消：什么都不做，窗口照常保留。 */
        }];
        return NO;
    }

    [self shutdown:nil];
    return NO;                 /* QMP teardown is in flight; the process exits */
}

- (void)windowDidMove:(NSNotification *)note
{
    [self scheduleFrameSave];
}

- (void)windowDidResize:(NSNotification *)note
{
    [self scheduleFrameSave];

    /* Rebuild once the drag settles: recreating the EGL surface on every
     * intermediate size would thrash, and the guest view has not been laid out
     * for the new bounds yet at notification time. */
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(relayoutEngine)
                                               object:nil];
    [self performSelector:@selector(relayoutEngine) withObject:nil afterDelay:0.12];
}

- (void)relayoutEngine
{
    [self fitGuestView];
    /* QEMU 在 qemu_init 里才把视图挂进 gScreen，晚于工具条；把它压回最底层，
     * 工具条永远浮在画面之上。 */
    if (gToolbar.superview == gScreen) {
        [gScreen addSubview:gToolbar positioned:NSWindowAbove relativeTo:nil];
    }
    qemu_cocoa_relayout();
}

- (void)scheduleFrameSave
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(saveFrameNow)
                                               object:nil];
    [self performSelector:@selector(saveFrameNow) withObject:nil afterDelay:0.4];
}

- (void)saveFrameNow { save_frame(); }

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    if (gQuitting) return NSTerminateNow;   /* second pass: QEMU is already down */
    [self shutdown:nil];
    return NSTerminateCancel;   /* shutdown: calls terminate again once QEMU is down */
}

- (void)shutdown:(id)sender
{
    if (gQuitting) return;
    gQuitting = YES;
    save_frame();

    /* 关机在后台进行（1–6 s），先把窗口从屏幕移除——让用户立刻看到
     * 「已经关了」，而不是盯着一个还开着但已不响应的窗口。 */
    [gWindow orderOut:nil];

    NSString *path = gPlan[@"qmp"] ?:
        [gInstanceDir stringByAppendingPathComponent:@"qmp.sock"];

    /* 正常关机走双通道，谁先完成都行：
     * 1) QMP quit —— 优雅退出，bdrv 刷盘；
     * 2) adb reboot -p —— Android 自己走 sync→umount→powerdown（E18 验证的
     *    最可靠关机路径），QEMU 随 guest 断电退出。
     * QMP 通道可能被管理器的状态轮询占用（单客户端），所以 adb 不是备胎，
     * 是并列的关机通道。 */
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        QMPClient *client = [[QMPClient alloc] init];
        if ([client connectPath:path timeout:3.0]) {
            /* QMP 规范：连接后必须先握手（qmp_capabilities），否则任何命令
             * 都被拒绝——漏了这一步 quit 就是空发，客机永远不退。 */
            [client execute:@"qmp_capabilities" arguments:nil error:NULL timeout:3.0];
            [client execute:@"quit" arguments:nil error:NULL timeout:3.0];
        }
        [client close];
    });
    adb_run(@[@"shell", @"sync; reboot", @"-p"], nil);

    /* 都失灵时的最后保险：_exit 而非 exit（atexit 死锁，见 E15）。走到这里
     * 前两条路至少有一条已对文件系统做过 sync/umount。 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        _exit(0);
    });
}

@end

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        /* ANGLE is dlopen'd by the GL layer, not linked, so a bare executable
         * has no way to find it. The manager also passes this, but setting it
         * here keeps the player runnable by hand. */
        if (!getenv("DYLD_FALLBACK_LIBRARY_PATH")) {
            setenv("DYLD_FALLBACK_LIBRARY_PATH",
                   "/opt/homebrew/opt/libangle/lib:/opt/homebrew/opt/libepoxy-angle/lib", 1);
        }

        NSApplication *app = [NSApplication sharedApplication];
        PlayerDelegate *delegate = [[PlayerDelegate alloc] init];
        [app setDelegate:delegate];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
