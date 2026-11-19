#include "pixel_rows.h"

#include <stdlib.h>
#include <string.h>

// In C rather than Swift: a debug build compiles Swift's per-byte loops
// without optimisation, which took seconds an image a few thousand pixels
// on a side, where unoptimised C takes a fraction of one.
long pixel_rows_unfilter(const uint8_t *raw, uint8_t *out, size_t stride, size_t height, size_t channels) {
    size_t lead = channels < stride ? channels : stride;
    for (size_t y = 0; y < height; y++) {
        uint8_t filter = raw[y * (stride + 1)];
        const uint8_t *in = raw + y * (stride + 1) + 1;
        uint8_t *row = out + y * stride;
        // Zeros stand in for the row above the first, as the format says.
        const uint8_t *above = y > 0 ? row - stride : NULL;
        size_t x;
        switch (filter) {
        case 0:
            memcpy(row, in, stride);
            break;
        case 1:
            for (x = 0; x < lead; x++) row[x] = in[x];
            for (; x < stride; x++) row[x] = (uint8_t)(in[x] + row[x - channels]);
            break;
        case 2:
            if (above) {
                for (x = 0; x < stride; x++) row[x] = (uint8_t)(in[x] + above[x]);
            } else {
                memcpy(row, in, stride);
            }
            break;
        case 3:
            for (x = 0; x < lead; x++) row[x] = (uint8_t)(in[x] + (above ? above[x] >> 1 : 0));
            for (; x < stride; x++) {
                unsigned up = above ? above[x] : 0;
                row[x] = (uint8_t)(in[x] + ((row[x - channels] + up) >> 1));
            }
            break;
        case 4:
            // Paeth; with no left neighbour it picks the byte above.
            for (x = 0; x < lead; x++) row[x] = (uint8_t)(in[x] + (above ? above[x] : 0));
            for (; x < stride; x++) {
                int a = row[x - channels], b = above ? above[x] : 0, c = above ? above[x - channels] : 0;
                int pa = abs(b - c), pb = abs(a - c), pc = abs(a + b - 2 * c);
                row[x] = (uint8_t)(in[x] + (pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)));
            }
            break;
        default:
            return (long)y;
        }
    }
    return -1;
}

static inline uint8_t times(uint8_t colour, unsigned alpha) {
    return (uint8_t)((colour * alpha + 127) / 255);
}

void pixel_rows_premultiply(uint8_t *pixels, size_t bytes) {
    for (size_t at = 0; at + 3 < bytes; at += 4) {
        unsigned alpha = pixels[at + 3];
        if (alpha < 255) {
            pixels[at] = times(pixels[at], alpha);
            pixels[at + 1] = times(pixels[at + 1], alpha);
            pixels[at + 2] = times(pixels[at + 2], alpha);
        }
    }
}

void pixel_rows_premultiply_flipped(const uint8_t *in, uint8_t *out, size_t width, size_t height) {
    size_t stride = width * 4;
    for (size_t row = 0; row < height; row++) {
        const uint8_t *from = in + row * stride;
        uint8_t *to = out + (height - 1 - row) * stride;
        for (size_t at = 0; at < stride; at += 4) {
            unsigned alpha = from[at + 3];
            if (alpha == 255) {
                to[at] = from[at];
                to[at + 1] = from[at + 1];
                to[at + 2] = from[at + 2];
            } else {
                to[at] = times(from[at], alpha);
                to[at + 1] = times(from[at + 1], alpha);
                to[at + 2] = times(from[at + 2], alpha);
            }
            to[at + 3] = (uint8_t)alpha;
        }
    }
}
