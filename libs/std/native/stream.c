#ifndef KF_NATIVE_UNITY
#include "kf_runtime.h"
/* For the `String` and `List` layouts, which alloc declares. */
#include "alloc.h"
#endif

/* Streams as file descriptors. A read never blocks: it asks poll whether
 * the descriptor is ready first, so descriptors stay in blocking mode and a
 * terminal or pipe shared with another process is left as it was found.
 * Each call records its outcome for kf_stream_last / kf_stream_errno to read
 * straight after it. */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { KF_STREAM_DATA = 0, KF_STREAM_NOTHING = 1, KF_STREAM_END = 2, KF_STREAM_FAILED = 3 };

static int32_t kf_stream_outcome = KF_STREAM_DATA;
static int32_t kf_stream_error = 0;

int32_t kf_stream_last(void) { return kf_stream_outcome; }
int32_t kf_stream_errno(void) { return kf_stream_error; }

static void kf_stream_record(int32_t outcome) {
    kf_stream_outcome = outcome;
    kf_stream_error = outcome == KF_STREAM_FAILED ? (errno ? errno : EIO) : 0;
}

/* A writer whose reader has gone gets EPIPE from write, rather than a
 * SIGPIPE that ends the whole process. */
static void kf_stream_ignore_sigpipe(void) {
    static int done = 0;
    if (!done) {
        signal(SIGPIPE, SIG_IGN);
        done = 1;
    }
}

static String kf_stream_empty(void) { return __kf_v2_str_from_cstr(""); }

/* Up to `max` bytes, kept whole even when they hold a NUL. */
String kf_stream_read(int32_t fd, uint64_t max) {
    struct pollfd ready = { .fd = fd, .events = POLLIN, .revents = 0 };
    int polled;
    do { polled = poll(&ready, 1, 0); } while (polled < 0 && errno == EINTR);
    if (polled < 0) {
        kf_stream_record(KF_STREAM_FAILED);
        return kf_stream_empty();
    }
    if (polled == 0) {
        kf_stream_record(KF_STREAM_NOTHING);
        return kf_stream_empty();
    }
    if (max == 0) max = 1;
    uint8_t* buffer = (uint8_t*)kf_alloc((size_t)max + 1);
    ssize_t count;
    do { count = read(fd, buffer, (size_t)max); } while (count < 0 && errno == EINTR);
    if (count <= 0) {
        kf_free(buffer);
        kf_stream_record(count == 0 ? KF_STREAM_END : KF_STREAM_FAILED);
        return kf_stream_empty();
    }
    buffer[count] = 0;
    kf_stream_record(KF_STREAM_DATA);
    return (String){ .data = buffer, .len = (uint64_t)count, .cap = (uint64_t)max + 1 };
}

/* All `len` bytes, blocking until the reader has taken them. */
int32_t kf_stream_write(int32_t fd, const char* data, uint64_t len) {
    kf_stream_ignore_sigpipe();
    uint64_t written = 0;
    while (written < len) {
        ssize_t count = write(fd, data + written, (size_t)(len - written));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            kf_stream_record(KF_STREAM_FAILED);
            return -1;
        }
        written += (uint64_t)count;
    }
    kf_stream_record(KF_STREAM_DATA);
    return 0;
}

void kf_stream_close(int32_t fd) {
    if (fd >= 0) close(fd);
}

/* The read end in the high 32 bits and the write end in the low; -1 on
 * failure. Neither end is inherited by a spawned child. */
int64_t kf_stream_pipe(void) {
    int ends[2];
    if (pipe(ends) != 0) {
        kf_stream_record(KF_STREAM_FAILED);
        return -1;
    }
    fcntl(ends[0], F_SETFD, FD_CLOEXEC);
    fcntl(ends[1], F_SETFD, FD_CLOEXEC);
    kf_stream_record(KF_STREAM_DATA);
    return ((int64_t)ends[0] << 32) | (int64_t)(uint32_t)ends[1];
}

/* The set the next kf_stream_poll waits on, built one descriptor at a time
 * so that nothing but scalars crosses into C. */
static struct pollfd* kf_poll_set = NULL;
static uint64_t kf_poll_count = 0;
static uint64_t kf_poll_capacity = 0;

void kf_stream_poll_clear(void) { kf_poll_count = 0; }

int32_t kf_stream_poll_add(int32_t fd) {
    if (kf_poll_count == kf_poll_capacity) {
        uint64_t grown = kf_poll_capacity ? kf_poll_capacity * 2 : 8;
        struct pollfd* larger = (struct pollfd*)realloc(kf_poll_set, grown * sizeof(struct pollfd));
        if (!larger) return -1;
        kf_poll_set = larger;
        kf_poll_capacity = grown;
    }
    kf_poll_set[kf_poll_count].fd = fd;
    kf_poll_set[kf_poll_count].events = POLLIN;
    kf_poll_set[kf_poll_count].revents = 0;
    kf_poll_count++;
    return 0;
}

/* How many of the set have input or a hang-up waiting; 0 when `timeout_ms`
 * passed first, -1 on failure. A negative timeout waits as long as it
 * takes. */
int32_t kf_stream_poll(int64_t timeout_ms) {
    int timeout = timeout_ms < 0 ? -1 : (timeout_ms > 2147483647 ? 2147483647 : (int)timeout_ms);
    int count;
    do { count = poll(kf_poll_set, (nfds_t)kf_poll_count, timeout); } while (count < 0 && errno == EINTR);
    kf_stream_record(count < 0 ? KF_STREAM_FAILED : KF_STREAM_DATA);
    return count;
}

/* Whether the set's `i`th descriptor was ready at the last kf_stream_poll. */
bool kf_stream_poll_ready(uint64_t i) {
    if (i >= kf_poll_count) return false;
    return (kf_poll_set[i].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) != 0;
}

String kf_stream_error_text(int32_t code) { return __kf_v2_str_from_cstr(strerror(code)); }
