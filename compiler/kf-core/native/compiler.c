#ifndef KF_NATIVE_UNITY
#include "kf_runtime.h"
#endif

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define KF_SYM_INITIAL_CAP 65536u

static const char** kf_sym_table;
static uint32_t kf_sym_count = 1;
static uint32_t kf_sym_capacity;
static int32_t* kf_sym_hash_table;

static uint32_t kf_sym_hash_string(const char* value) {
    uint32_t hash = 2166136261u;
    for (; *value; value++) {
        hash ^= (uint8_t)*value;
        hash *= 16777619u;
    }
    return hash;
}

static void kf_sym_allocation_failed(void) {
    static const char message[] = "komp: failed to grow symbol interner\n";
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(1);
}

static void kf_sym_grow(void) {
    uint32_t old_capacity = kf_sym_capacity;
    uint32_t new_capacity = old_capacity == 0
        ? KF_SYM_INITIAL_CAP
        : old_capacity * 2;
    if (new_capacity <= old_capacity) kf_sym_allocation_failed();

    const char** new_symbols = (const char**)realloc(
        kf_sym_table, sizeof(const char*) * new_capacity);
    if (new_symbols == NULL) kf_sym_allocation_failed();
    memset(new_symbols + old_capacity, 0,
           sizeof(const char*) * (new_capacity - old_capacity));

    int32_t* new_hash_table = (int32_t*)calloc(new_capacity, sizeof(int32_t));
    if (new_hash_table == NULL) kf_sym_allocation_failed();

    uint32_t mask = new_capacity - 1;
    for (uint32_t id = 1; id < kf_sym_count; id++) {
        uint32_t index = kf_sym_hash_string(new_symbols[id]) & mask;
        while (new_hash_table[index] != 0) index = (index + 1) & mask;
        new_hash_table[index] = (int32_t)(id + 1);
    }

    free(kf_sym_hash_table);
    kf_sym_table = new_symbols;
    kf_sym_hash_table = new_hash_table;
    kf_sym_capacity = new_capacity;
}

uint32_t kf_sym_intern(const char* value) {
    for (;;) {
        if (kf_sym_capacity == 0) kf_sym_grow();
        uint32_t mask = kf_sym_capacity - 1;
        uint32_t index = kf_sym_hash_string(value) & mask;
        while (kf_sym_hash_table[index] != 0) {
            uint32_t id = (uint32_t)(kf_sym_hash_table[index] - 1);
            if (strcmp(kf_sym_table[id], value) == 0) return id;
            index = (index + 1) & mask;
        }

        uint64_t next_load = (uint64_t)kf_sym_count * 10;
        uint64_t load_limit = (uint64_t)kf_sym_capacity * 7;
        if (kf_sym_count >= kf_sym_capacity || next_load >= load_limit) {
            kf_sym_grow();
            continue;
        }

        char* copy = (char*)malloc(strlen(value) + 1);
        if (copy == NULL) kf_sym_allocation_failed();
        strcpy(copy, value);
        uint32_t id = kf_sym_count++;
        kf_sym_table[id] = copy;
        kf_sym_hash_table[index] = (int32_t)(id + 1);
        return id;
    }
}

const char* kf_sym_resolve(uint32_t id) {
    return kf_sym_table[id];
}

/* Warning output, muted for the duration of a `komp test` run.
 *
 * A test run recompiles the crate, so every auto-clone and borrow hint the
 * crate's own source carries is reprinted ahead of the results — hundreds of
 * lines that say nothing about the tests and push the failures off screen.
 * `komp check` and `komp build` still report them, which is where someone
 * looking for them would go.
 *
 * A process-wide flag rather than a parameter because the print sites are
 * spread across the pipeline, and threading a display preference through
 * compilation to reach them would put it in a lot of signatures that have no
 * other reason to know.
 */
static int kf_warnings_muted = 0;

void kf_mute_warnings(int32_t on) { kf_warnings_muted = on ? 1 : 0; }
int32_t kf_warnings_are_muted(void) { return kf_warnings_muted ? 1 : 0; }

/* Which crate is being built, as a source-directory prefix.
 *
 * A warning is advice to whoever can act on it. Building anything that
 * depends on core/alloc/std used to print the dependency's borrow-ergonomics
 * advisories alongside the author's own — a consumer of `core` cannot edit
 * `core`, and under separate compilation the advice does not even name a file
 * they have (it names `core.kfi`). Errors are unaffected: a dependency that
 * fails to compile is always the consumer's problem.
 *
 * Process-wide for the same reason the mute flag is: the print sites are
 * spread across the pipeline, and threading "which project am I" through
 * compilation to reach them would put it in a lot of signatures that have no
 * other reason to know.
 *
 * A dependency built in its own child process sets its OWN root, so building
 * `core` directly still reports `core`'s warnings.
 */
static char kf_local_root_buf[4096];
static int  kf_local_root_set = 0;

void kf_set_local_root(const char* path) {
    if (!path || !*path) { kf_local_root_set = 0; kf_local_root_buf[0] = 0; return; }
    size_t n = strlen(path);
    if (n >= sizeof kf_local_root_buf) n = sizeof kf_local_root_buf - 1;
    memcpy(kf_local_root_buf, path, n);
    kf_local_root_buf[n] = 0;
    kf_local_root_set = 1;
}

const char* kf_local_root(void) {
    return kf_local_root_set ? kf_local_root_buf : "";
}

/* Running one crate's compilation in a child process.
 *
 * komp frees nothing it allocates while compiling, so a build that walks a
 * dependency chain in one process pays for the WHOLE chain rather than for
 * its largest crate: 4.5 GB for `komp test compiler/kf-driver`, against
 * 1.2 GB for the same crate with its dependencies already built (#326).
 *
 * A crate's output is entirely on disk — `.kfi`, `.h`, `.c`, `.o`, `.a` and
 * the artifact manifest — so a child that compiles one crate and exits hands
 * back everything a consumer needs, and the OS reclaims the rest. That makes
 * the fork a memory decision and not an architectural one: the parent reads
 * what the child wrote, exactly as it would read a previous run's artifacts.
 *
 * Flushing before the fork matters. Anything still buffered would be
 * duplicated into the child's copy of the stream and printed twice.
 */
int32_t kf_fork_child(void) {
    fflush(NULL);
    return (int32_t)fork();
}

/* Wait for one child. Returns its exit status, or 128+signal if it was
 * killed — which is how an out-of-memory child reports itself. */
int32_t kf_wait_child_pid(int32_t pid) {
    int status = 0;
    if (waitpid((pid_t)pid, &status, 0) < 0) return -1;
    if (WIFEXITED(status)) return (int32_t)WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return (int32_t)(128 + WTERMSIG(status));
    return -1;
}

/* Leave a child. `_exit` rather than `exit` so the parent's atexit handlers
 * do not run a second time in the child, but flush first so the diagnostics
 * the child printed are not lost with its buffers. */
void kf_exit_child(int32_t code) {
    fflush(NULL);
    _exit((int)code);
}

/* The `TypeNodes` a typing is putting its type children in (0 for none).
 *
 * Process-wide for the same reason the flags above are: types are built all
 * over the checker, and threading the storage through every signature that
 * makes one would put it in hundreds of functions. A typing sets it around
 * its own work and restores the previous one after. */
static uint64_t kf_type_nodes_current = 0;

uint64_t kf_type_nodes_swap(uint64_t next) {
    uint64_t previous = kf_type_nodes_current;
    kf_type_nodes_current = next;
    return previous;
}
