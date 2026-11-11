/*
 * andropod_qemu.c — QEMU-in-process 入口层。
 *
 * 复刻 system/main.c 的启动顺序，但不接管 UI 主循环：
 *   qemu_init() 在调用线程（必须是主线程，cocoa 显示要建 AppKit 对象）
 *   之后把 BQL / replay 锁交出去，QEMU 主循环跑在后台线程，
 *   主线程留给 NSApplication —— 这正是 QEMU 在 Darwin 上的原生分工。
 */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

void qemu_init(int argc, char **argv);
int qemu_main_loop(void);
int qemu_cleanup(int status);
void bql_lock_impl(const char *file, int line);
void bql_unlock(void);
void replay_mutex_lock(void);
void replay_mutex_unlock(void);

/* system/main.c 里定义、被 ui/cocoa.m 引用的函数指针。我们不带那个目标文件
 * （它含 main()），所以在这里给出定义。ui 层只会在调用 qemu_main() 时用它，
 * 而嵌入模式下主线程由 NSApplication 占用，永远不会走到那条路。 */
int (*qemu_main)(void);

/* 由 ui/cocoa.m 提供：把 QEMU 的视频视图挂进宿主窗口 */
void qemu_cocoa_set_host_view(void *view);

void andropod_qemu_set_host_view(void *view)
{
    qemu_cocoa_set_host_view(view);
}

/* 阶段打点：QEMU 会把 stdio 接管掉一部分，写独立文件才可靠 */
static void stage(const char *s)
{
    if (!getenv("ANDROPOD_EMBED_DEBUG")) {
        return;
    }
    int fd = open("/tmp/andropod-stage.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        write(fd, s, strlen(s));
        write(fd, "\n", 1);
        close(fd);
    }
}

static void *andropod_loop(void *arg)
{
    int status;
    (void)arg;

    stage("loop: acquiring locks");
    replay_mutex_lock();
    bql_lock_impl(__FILE__, __LINE__);
    stage("loop: running qemu_main_loop");
    status = qemu_main_loop();
    qemu_cleanup(status);
    /* qemu_cleanup() closes block devices and monitors but deliberately does
     * NOT exit; upstream that job belongs to main() in system/main.c. We are
     * that main() here, so the process has to end itself — otherwise a QMP
     * `quit` leaves a live player with a dead QEMU and a frozen window.
     * _exit() rather than exit(): the atexit chain tears down AppKit/GL state
     * that the still-running main thread owns, which deadlocks. Blocks are
     * already flushed by bdrv_close_all() inside qemu_cleanup(). */
    fprintf(stderr, "[andropod] qemu main loop exited, status=%d\n", status);
    fflush(stderr);
    _exit(status);

    return NULL;
}

int andropod_qemu_start(int argc, char **argv)
{
    pthread_t thread;

    stage("init begin");
    qemu_init(argc, argv);
    stage("init done");

    /* qemu_init 返回时仍持有 BQL 与 replay 锁（见 system/main.c 注释），
     * 交给主循环线程重新获取。 */
    bql_unlock();
    stage("bql released");
    replay_mutex_unlock();

    int rc = pthread_create(&thread, NULL, andropod_loop, NULL);
    stage(rc == 0 ? "loop thread started" : "loop thread failed");
    if (rc != 0) {
        fprintf(stderr, "[andropod] failed to spawn qemu main loop thread\n");
        return -1;
    }
    pthread_detach(thread);
    return 0;
}
