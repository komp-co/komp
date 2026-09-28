#ifndef KF_NATIVE_UNITY
#include "kf_runtime.h"
/* For the `String` layout, which alloc declares; its header includes core's. */
#include "alloc.h"
#endif

#include <stdlib.h>
#include <unistd.h>

String kf_current_dir(void) {
    char* path = getcwd(NULL, 0);
    if (!path) return __kf_v2_str_from_cstr("");
    String out = __kf_v2_str_from_cstr(path);
    free(path);
    return out;
}

String kf_self_dir(void) {
    char path[4096];
    ssize_t len = readlink("/proc/self/exe", path, sizeof(path) - 1);
    if (len <= 0) return __kf_v2_str_from_cstr("");
    path[len] = '\0';
    for (ssize_t i = len - 1; i >= 0; i--) {
        if (path[i] == '/') {
            path[i] = '\0';
            break;
        }
    }
    return __kf_v2_str_from_cstr(path);
}

void kf_env_set(const char* name, const char* value) {
    setenv(name, value, 1);
}
