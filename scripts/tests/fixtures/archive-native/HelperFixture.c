/* Test-only helper failures. Fixed-size buffers; no archive extraction. */
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    (void)argc;
    const char *name = strrchr(argv[0], '/');
    name = name ? name + 1 : argv[0];
    if (strcmp(name, "fake-fail") == 0) return 7;
    if (strcmp(name, "fake-crash") == 0) { raise(SIGKILL); return 8; }
    if (strcmp(name, "fake-invalid") == 0) { puts("{not valid JSON}"); return 0; }
    if (strcmp(name, "fake-oversized") == 0) {
        char buffer[65536]; memset(buffer, 'x', sizeof(buffer));
        for (int i = 0; i < 300; ++i) {
            if (fwrite(buffer, 1, sizeof(buffer), stdout) != sizeof(buffer)) return 0;
        }
        return 0;
    }
    if (strcmp(name, "fake-cancel") == 0) {
        char ready[4096];
        if (snprintf(ready, sizeof(ready), "%s.pid", argv[0]) >= (int)sizeof(ready)) return 9;
        FILE *file = fopen(ready, "w");
        if (!file) return 10;
        fprintf(file, "%d\n", getpid()); fclose(file);
        for (;;) pause();
    }
    return 11;
}
