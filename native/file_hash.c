/* A file's content hash (djb2), 0 when it cannot be opened. komp keys
 * fingerprints and the compiler's identity on it. */

#include <fcntl.h>
#include <stdint.h>
#include <unistd.h>

uint64_t kf_file_hash(const char* path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    uint64_t hash = 5381;
    unsigned char buffer[65536];
    for (;;) {
        long count = read(fd, buffer, sizeof(buffer));
        if (count <= 0) break;
        for (long i = 0; i < count; i++) hash = hash * 33 + (uint64_t)buffer[i];
    }
    close(fd);
    return hash;
}
