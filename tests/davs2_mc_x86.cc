// Build against a patched 10-bit davs2 source tree; see README.md.
#include "common/common.h"
#include "common/primitives.h"
#include "common/cpu.h"
#include <stdio.h>
#include <string.h>

static pel_t source[80 * 80], expected[80 * 80], actual[80 * 80];
static const int8_t luma[3][8] = {
    {-1, 4, -10, 57, 19, -7, 3, -1},
    {-1, 4, -11, 40, 40, -11, 4, -1},
    {-1, 3, -7, 19, 57, -10, 4, -1},
};
static const int8_t chroma[7][4] = {
    {-4, 62, 6, 0}, {-6, 56, 15, -1}, {-5, 47, 25, -3},
    {-4, 36, 36, -4}, {-3, 25, 47, -5}, {-1, 15, 56, -6}, {0, 6, 62, -4},
};

int main()
{
    ao_funcs_t scalar = {}, fallback = {}, simd = {};
    davs2_mc_init(0, &scalar);
    davs2_mc_init(DAVS2_CPU_SSE2 | DAVS2_CPU_SSE4, &fallback);
    if (scalar.intpl_luma_ext[1] != fallback.intpl_luma_ext[1] ||
        scalar.intpl_chroma_ext[1] != fallback.intpl_chroma_ext[1])
        return 1;
    if (!(davs2_cpu_detect() & DAVS2_CPU_AVX2)) {
        fprintf(stderr, "SKIP: AVX2 execution requires a CPU/runtime with AVX2 support\n");
        return 77;
    }
    davs2_mc_init(DAVS2_CPU_AVX2, &simd);
    if (scalar.intpl_luma_ext[1] == simd.intpl_luma_ext[1] ||
        scalar.intpl_chroma_ext[1] == simd.intpl_chroma_ext[1])
        return 1;

    const int widths[] = {4, 8, 12, 16, 24, 32, 48, 64};
    const int heights[] = {4, 12, 64};
    unsigned random = 1;
    int checks = 0;
    for (int pattern = 0; pattern < 4; pattern++) {
        for (int i = 0; i < 80 * 80; i++) {
            random = random * 1664525u + 1013904223u;
            source[i] = pattern == 0 ? 0 : pattern == 1 ? 1023 :
                        pattern == 2 ? ((i + i / 80) & 1) * 1023 : random >> 22;
        }
        // Unaligned source/output, with padding for the interpolation window.
        pel_t *src = source + 5 * 80 + 5;
        for (int color = 0; color < 2; color++) {
            int phases = color ? 7 : 3;
            for (int width : widths) for (int height : heights) {
                int w = color ? width / 2 : width;
                int h = color ? height / 2 : height;
                for (int a = 0; a < phases; a++) for (int b = 0; b < phases; b++) {
                    const int8_t *ch = color ? chroma[a] : luma[a];
                    const int8_t *cv = color ? chroma[b] : luma[b];
                    for (int direction = 0; direction < 3; direction++) {
                        memset(expected, 0xa5, sizeof(expected));
                        memset(actual, 0xa5, sizeof(actual));
                        for (int impl = 0; impl < 2; impl++) {
                            ao_funcs_t &pf = impl ? simd : scalar;
                            pel_t *dst = (impl ? actual : expected) + 1;
                            if (direction == 2) {
                                auto fn = color ? pf.intpl_chroma_ext[1] : pf.intpl_luma_ext[1];
                                fn(dst, 80, src, 80, w, h, ch, cv);
                            } else {
                                auto fn = color ? (direction ? pf.intpl_chroma_ver[1] : pf.intpl_chroma_hor[1]) :
                                                  (direction ? pf.intpl_luma_ver[1][0] : pf.intpl_luma_hor[1][0]);
                                fn(dst, 80, src, 80, w, h, direction ? cv : ch);
                            }
                        }
                        if (memcmp(expected, actual, sizeof(actual))) {
                            fprintf(stderr, "Mismatch: pattern=%d chroma=%d size=%dx%d phases=%d,%d direction=%d\n",
                                    pattern, color, w, h, a, b, direction);
                            return 1;
                        }
                        checks++;
                    }
                }
            }
        }
    }
    printf("PASS: %d scalar/AVX2 comparisons, including output padding and SSE fallback\n", checks);
    return 0;
}
