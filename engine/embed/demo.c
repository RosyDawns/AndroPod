/*
 * demo.c — 可行性验证：把 QEMU 作为动态库在自己进程里跑起来。
 * 用法: ./demo <实例目录>   （读取该目录下的 qemu.cmd 作为参数源）
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int andropod_qemu_start(int argc, char **argv);

#define MAX_ARGS 256

static int is_flag(const char *s) { return s[0] == '-'; }

int main(int argc, char **argv)
{
    char path[1024];
    const char *dir = argc > 1 ? argv[1] : NULL;
    if (!dir) {
        fprintf(stderr, "usage: %s <instance-dir>\n", argv[0]);
        return 2;
    }
    snprintf(path, sizeof(path), "%s/qemu.cmd", dir);

    FILE *fp = fopen(path, "r");
    if (!fp) {
        perror(path);
        return 2;
    }

    char *lines[MAX_ARGS];
    int n = 0;
    char buf[8192];
    while (fgets(buf, sizeof(buf), fp) && n < MAX_ARGS - 8) {
        size_t len = strlen(buf);
        while (len && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) {
            buf[--len] = 0;
        }
        if (!len) {
            continue;
        }
        lines[n++] = strdup(buf);
    }
    fclose(fp);

    /* 重写参数：去掉控制 socket 与图形后端，换 2D 显卡，因为 headless
     * 模式下 display_opengl 为假，virtio-gpu-gl 会拒绝初始化。 */
    char *out[MAX_ARGS];
    int m = 0;
    out[m++] = "qemu-system-aarch64";
    /* 进程内加载时 argv[0] 不再是 qemu-system-aarch64，QEMU 找不到自带固件，
     * 必须显式给 -L。真实集成时由 workspace 提供 runtime/qemu/share。 */
    const char *bios = getenv("ANDROPOD_BIOS");
    if (bios) {
        out[m++] = "-L";
        out[m++] = (char *)bios;
    }
    for (int i = 1; i < n; i++) {
        if (!strcmp(lines[i], "-qmp") || !strcmp(lines[i], "-display")) {
            i++;
            continue;
        }
        if (!strcmp(lines[i], "-device") && i + 1 < n &&
            !strncmp(lines[i + 1], "virtio-gpu-gl-pci", 17)) {
            out[m++] = "-device";
            out[m++] = "virtio-gpu-pci";
            i++;
            continue;
        }
        out[m++] = lines[i];
    }
    out[m++] = "-display";
    out[m++] = "none";

    printf("[demo] argv (%d):\n", m);
    for (int i = 0; i < m; i++) {
        printf("  [%02d] %s\n", i, out[i]);
    }
    fflush(stdout);

    if (andropod_qemu_start(m, out) != 0) {
        fprintf(stderr, "[demo] start failed\n");
        return 1;
    }
    printf("[demo] qemu_init returned, main loop on background thread\n");
    fflush(stdout);

    /* 主线程保持存活，模拟宿主 UI 线程 */
    for (;;) {
        sleep(2);
        printf("[demo] alive, host thread free\n");
        fflush(stdout);
    }
}
