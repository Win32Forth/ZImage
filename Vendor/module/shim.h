#ifndef ZIMAGE_CODEC_SHIM_H_
#define ZIMAGE_CODEC_SHIM_H_

#include <stddef.h>
#include <stdint.h>

#include <webp/decode.h>
#include <webp/encode.h>
#include <jxl/decode.h>
#include <jxl/encode.h>

/// libjxl status checks. Swift calls these so a C enum import cannot drift the comparison.
static inline int ZImageEncoderSucceeded(JxlEncoderStatus status) {
    return status == JXL_ENC_SUCCESS;
}

static inline int ZImageEncoderNeedsOutput(JxlEncoderStatus status) {
    return status == JXL_ENC_NEED_MORE_OUTPUT;
}

static inline int ZImageDecoderSucceeded(JxlDecoderStatus status) {
    return status == JXL_DEC_SUCCESS;
}

static inline int ZImageDecoderFailed(JxlDecoderStatus status) {
    return status == JXL_DEC_ERROR;
}

static inline int ZImageDecoderNeedsImage(JxlDecoderStatus status) {
    return status == JXL_DEC_NEED_IMAGE_OUT_BUFFER;
}

static inline int ZImageDecoderHasBasicInfo(JxlDecoderStatus status) {
    return status == JXL_DEC_BASIC_INFO;
}

static inline int ZImageDecoderHasFullImage(JxlDecoderStatus status) {
    return status == JXL_DEC_FULL_IMAGE;
}

static inline int ZImageDecoderEvents(void) {
    return JXL_DEC_BASIC_INFO | JXL_DEC_FULL_IMAGE;
}

/// One `JxlEncoderProcessOutput` step. `*written` is the number of bytes produced into `buffer`.
/// Returns 0 on success, 1 when the encoder needs another buffer, and -1 on failure.
static inline int ZImageEncoderPump(JxlEncoder *encoder, uint8_t *buffer, size_t capacity, size_t *written) {
    uint8_t *next = buffer;
    size_t avail = capacity;
    JxlEncoderStatus status = JxlEncoderProcessOutput(encoder, &next, &avail);
    *written = capacity - avail;
    if (status == JXL_ENC_SUCCESS) {
        return 0;
    }
    if (status == JXL_ENC_NEED_MORE_OUTPUT) {
        return 1;
    }
    return -1;
}

#endif
