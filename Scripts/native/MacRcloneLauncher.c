/* MIT License, Rclone Browser Next contributors.
 * NSTask normalizes argv using fileSystemRepresentation. ASCII base64 crosses
 * that boundary unchanged; execv then forwards the original UTF-8 bytes.
 * No shell, extra child, temporary file or signal-forwarding loop is involved.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int digit(unsigned char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static char *decode(const char *encoded) {
    size_t size = strlen(encoded), count = 0;
    if (size % 4 || size > 4 * 1024 * 1024) return NULL;
    char *decoded = malloc(size / 4 * 3 + 1);
    if (!decoded) return NULL;
    for (size_t i = 0; i < size; i += 4) {
        int a = digit(encoded[i]), b = digit(encoded[i + 1]);
        int c = encoded[i + 2] == '=' ? 0 : digit(encoded[i + 2]);
        int d = encoded[i + 3] == '=' ? 0 : digit(encoded[i + 3]);
        if (a < 0 || b < 0 || c < 0 || d < 0 ||
            (encoded[i + 2] == '=' && encoded[i + 3] != '=') ||
            ((encoded[i + 2] == '=' || encoded[i + 3] == '=') && i + 4 != size)) {
            free(decoded); return NULL;
        }
        decoded[count++] = (char)((a << 2) | (b >> 4));
        if (encoded[i + 2] != '=') decoded[count++] = (char)((b << 4) | (c >> 2));
        if (encoded[i + 3] != '=') decoded[count++] = (char)((c << 6) | d);
    }
    if (memchr(decoded, 0, count)) { free(decoded); return NULL; }
    decoded[count] = 0;
    return decoded;
}

int main(int argc, char **argv) {
    if (argc < 2) return 125;
    char **original = calloc((size_t)argc, sizeof(char *));
    if (!original) return 125;
    for (int i = 1; i < argc; ++i) {
        original[i - 1] = decode(argv[i]);
        if (!original[i - 1]) {
            fputs("Rclone Browser Next: invalid process arguments.\n", stderr);
            return 125;
        }
    }
    if (original[0][0] != '/') return 125;
    execv(original[0], original);
    int error = errno;
    fprintf(stderr, "Rclone Browser Next: process launch failed: %s.\n", strerror(error));
    return error == ENOENT ? 127 : 126;
}
