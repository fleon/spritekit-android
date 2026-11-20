#ifndef PIXEL_ROWS_H
#define PIXEL_ROWS_H

#include <stddef.h>
#include <stdint.h>

/// Undoes PNG's per-row filters: `raw` holds each row's filter byte and then
/// its `stride` bytes; `out` (`stride` x `height` bytes) gets the rows.
/// `channels` is the bytes a pixel, the distance to the left neighbour.
/// Returns the first row with a filter PNG doesn't define, or -1.
long pixel_rows_unfilter(const uint8_t *raw, uint8_t *out, size_t stride, size_t height, size_t channels);

/// Straight RGBA8 premultiplied in place, `bytes` long (a whole number of
/// pixels): each colour times its alpha, rounded to nearest.
void pixel_rows_premultiply(uint8_t *pixels, size_t bytes);

/// Premultiplied as `pixel_rows_premultiply`, from `in` into `out` with the
/// rows in the opposite order (PNG's top-first into GL's bottom-first).
void pixel_rows_premultiply_flipped(const uint8_t *in, uint8_t *out, size_t width, size_t height);

#endif
