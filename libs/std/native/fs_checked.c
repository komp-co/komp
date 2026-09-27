#ifndef KF_NATIVE_UNITY
#include "kf_runtime.h"
/* For the `String` layout, which alloc declares; its header includes core's. */
#include "alloc.h"
#endif

/* The filesystem calls std.fs answers with a Result. Each records the errno
 * of its failure, or 0, for kf_fs_last_error to read straight after it. */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int32_t kf_remove_dir_all(const char* path);

static int32_t kf_fs_last = 0;

int32_t kf_fs_last_error(void) { return kf_fs_last; }

String kf_fs_error_text(int32_t code) { return __kf_v2_str_from_cstr(strerror(code)); }

static int32_t kf_fs_record(int failed) {
    kf_fs_last = failed ? (errno ? errno : EIO) : 0;
    return failed ? -1 : 0;
}

String kf_fs_read(const char* path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        kf_fs_record(1);
        return __kf_v2_str_from_cstr("");
    }
    size_t cap = 4096;
    size_t len = 0;
    char* buffer = (char*)malloc(cap);
    int failed = buffer == NULL;
    while (!failed) {
        if (cap - len < 4096) {
            char* grown = (char*)realloc(buffer, cap * 2);
            if (!grown) { failed = 1; break; }
            buffer = grown;
            cap *= 2;
        }
        long count = read(fd, buffer + len, cap - len - 1);
        if (count < 0) { failed = 1; break; }
        if (count == 0) break;
        len += (size_t)count;
    }
    kf_fs_record(failed);
    close(fd);
    if (failed) {
        free(buffer);
        return __kf_v2_str_from_cstr("");
    }
    buffer[len] = '\0';
    String out = __kf_v2_str_from_cstr(buffer);
    free(buffer);
    return out;
}

int32_t kf_fs_write(const char* path, const char* content) {
    FILE* file = fopen(path, "w");
    if (!file) return kf_fs_record(1);
    size_t len = strlen(content);
    int failed = fwrite(content, 1, len, file) != len;
    int saved = errno;
    if (fclose(file) != 0 && !failed) { failed = 1; saved = errno; }
    errno = saved;
    return kf_fs_record(failed);
}

int32_t kf_fs_remove_file(const char* path) { return kf_fs_record(unlink(path) != 0); }

int32_t kf_fs_rename(const char* from, const char* to) { return kf_fs_record(rename(from, to) != 0); }

int32_t kf_fs_remove_dir_all(const char* path) {
    errno = 0;
    return kf_fs_record(kf_remove_dir_all(path) != 0);
}

bool kf_fs_exists(const char* path) { return access(path, F_OK) == 0; }

bool kf_fs_is_dir(const char* path) {
    struct stat status;
    return stat(path, &status) == 0 && S_ISDIR(status.st_mode);
}

bool kf_fs_is_file(const char* path) {
    struct stat status;
    return stat(path, &status) == 0 && S_ISREG(status.st_mode);
}

uint64_t kf_fs_dir_start(const char* path) {
    DIR* directory = opendir(path);
    kf_fs_record(directory == NULL);
    return (uint64_t)(uintptr_t)directory;
}

/* The next name in the directory, skipping `.` and `..`; "" at the end. */
String kf_fs_dir_entry(uint64_t handle) {
    DIR* directory = (DIR*)(uintptr_t)handle;
    for (;;) {
        struct dirent* entry = readdir(directory);
        if (!entry) return __kf_v2_str_from_cstr("");
        const char* name = entry->d_name;
        if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) continue;
        return __kf_v2_str_from_cstr(name);
    }
}

void kf_fs_dir_finish(uint64_t handle) { closedir((DIR*)(uintptr_t)handle); }
