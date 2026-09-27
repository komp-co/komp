#ifndef KF_NATIVE_UNITY
#include "kf_runtime.h"
/* For the `String` layout, which alloc declares; its header includes core's. */
#include "alloc.h"
#endif

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

typedef struct {
    String* data;
    uint64_t len;
    uint64_t cap;
} KfStringArgs;

/* Death by a signal reads as 128. */
static int32_t kf_process_exit_code(int status) {
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128;
}

/* argv for execvp: the program, then each argument, then NULL. */
static char** kf_process_argv(const char* program, KfStringArgs* args) {
    char** values = (char**)malloc((args->len + 2) * sizeof(char*));
    if (!values) return NULL;
    values[0] = (char*)program;
    for (uint64_t i = 0; i < args->len; i++) values[i + 1] = (char*)args->data[i].data;
    values[args->len + 1] = NULL;
    return values;
}

/* In the child, before exec: its environment and directory. False on a
 * failure, with errno set. */
static int kf_process_prepare(const char* cwd, KfStringArgs* environment) {
    for (uint64_t i = 0; i < environment->len; i++) {
        char* entry = strdup((char*)environment->data[i].data);
        if (!entry || putenv(entry) != 0) return 0;
    }
    return !cwd[0] || chdir(cwd) == 0;
}

int32_t kf_process_status(const char* program, void* raw_args, const char* cwd, void* raw_environment, const char* stdout_path) {
    KfStringArgs* args = (KfStringArgs*)raw_args;
    KfStringArgs* environment = (KfStringArgs*)raw_environment;
    char** values = kf_process_argv(program, args);
    if (!values) return -1;
    pid_t child = fork();
    if (child == 0) {
        if (!kf_process_prepare(cwd, environment)) _exit(126);
        if (stdout_path[0]) {
            int fd = open(stdout_path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
            if (fd < 0 || dup2(fd, STDOUT_FILENO) < 0) _exit(126);
            close(fd);
        }
        execvp(program, values);
        _exit(127);
    }
    free(values);
    int status = 0;
    if (child < 0 || waitpid(child, &status, 0) < 0) return -1;
    return kf_process_exit_code(status);
}

/* The last spawn's outcome: the parent's ends of the child's stdin and
 * stdout, or the errno of the failure. */
static int32_t kf_spawned_stdin = -1;
static int32_t kf_spawned_stdout = -1;
static int32_t kf_spawn_error = 0;

int32_t kf_process_spawned_stdin(void) { return kf_spawned_stdin; }
int32_t kf_process_spawned_stdout(void) { return kf_spawned_stdout; }
int32_t kf_process_spawn_error(void) { return kf_spawn_error; }

/* A pipe whose ends a later exec does not inherit. */
static int kf_cloexec_pipe(int ends[2]) {
    ends[0] = -1;
    ends[1] = -1;
    if (pipe(ends) != 0) return 0;
    fcntl(ends[0], F_SETFD, FD_CLOEXEC);
    fcntl(ends[1], F_SETFD, FD_CLOEXEC);
    return 1;
}

/* Starts `program` with its stdin and stdout piped to this process and its
 * stderr shared, and answers its pid; -1 when it could not be started, exec
 * failures included, which the child reports through a pipe that exec
 * closes. */
int32_t kf_process_spawn(const char* program, void* raw_args, const char* cwd, void* raw_environment) {
    KfStringArgs* args = (KfStringArgs*)raw_args;
    KfStringArgs* environment = (KfStringArgs*)raw_environment;
    kf_spawned_stdin = -1;
    kf_spawned_stdout = -1;
    kf_spawn_error = 0;
    signal(SIGPIPE, SIG_IGN);
    int input[2], output[2], report[2];
    char** values = kf_process_argv(program, args);
    if (!values || !kf_cloexec_pipe(input) || !kf_cloexec_pipe(output) || !kf_cloexec_pipe(report)) {
        kf_spawn_error = errno ? errno : ENOMEM;
        free(values);
        return -1;
    }
    pid_t child = fork();
    if (child == 0) {
        if (dup2(input[0], STDIN_FILENO) >= 0 && dup2(output[1], STDOUT_FILENO) >= 0 &&
            kf_process_prepare(cwd, environment)) {
            signal(SIGPIPE, SIG_DFL);
            execvp(program, values);
        }
        int code = errno;
        ssize_t ignored = write(report[1], &code, sizeof(code));
        (void)ignored;
        _exit(127);
    }
    int saved = errno;
    free(values);
    close(input[0]);
    close(output[1]);
    close(report[1]);
    if (child < 0) {
        kf_spawn_error = saved;
        close(input[1]);
        close(output[0]);
        close(report[0]);
        return -1;
    }
    int code = 0;
    ssize_t got;
    do { got = read(report[0], &code, sizeof(code)); } while (got < 0 && errno == EINTR);
    close(report[0]);
    if (got == (ssize_t)sizeof(code)) {
        int status = 0;
        waitpid(child, &status, 0);
        close(input[1]);
        close(output[0]);
        kf_spawn_error = code;
        return -1;
    }
    kf_spawned_stdin = input[1];
    kf_spawned_stdout = output[0];
    return (int32_t)child;
}

/* The exit code once `pid` has exited, blocking until it does. */
int32_t kf_process_wait(int32_t pid) {
    int status = 0;
    pid_t done;
    do { done = waitpid((pid_t)pid, &status, 0); } while (done < 0 && errno == EINTR);
    if (done < 0) return -1;
    return kf_process_exit_code(status);
}

/* The exit code if `pid` has exited, or -2 while it runs. */
int32_t kf_process_try_wait(int32_t pid) {
    int status = 0;
    pid_t done = waitpid((pid_t)pid, &status, WNOHANG);
    if (done == 0) return -2;
    if (done < 0) return -1;
    return kf_process_exit_code(status);
}

void kf_process_kill(int32_t pid) {
    kill((pid_t)pid, SIGKILL);
}

String kf_process_error_text(int32_t code) { return __kf_v2_str_from_cstr(strerror(code)); }
