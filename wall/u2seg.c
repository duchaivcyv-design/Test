#include "u2seg.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>
#ifdef __APPLE__
#include <Accelerate/Accelerate.h>
#define GEMM(M,N,K,A,B,C) cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, M, N, K, 1.0f, A, K, B, N, 0.0f, C, N)
#else
static void GEMM(int M, int N, int K, const float *A, const float *B, float *C) {
    memset(C, 0, sizeof(float) * (size_t)M * N);
    for (int i = 0; i < M; i++) for (int k = 0; k < K; k++) { float a = A[(size_t)i*K+k]; const float *b = B + (size_t)k*N; float *c = C + (size_t)i*N; for (int j = 0; j < N; j++) c[j] += a * b[j]; }
}
#endif
typedef struct { uint32_t t, in[6], out, a, b, p0, p1, c, h, w; } Op;
typedef struct { uint32_t nd, shape[4]; const float *data; size_t n; } Wt;
static const uint32_t NONE = 0xffffffffu;

static void conv(const float *x, int I, int H, int W, const Wt *w, const Wt *bias, int dil, int pad, float *y) {
    int O = (int)w->shape[0], k = (int)w->shape[2];
    int K = I * k * k;
    int rowsPer = 16384 / W; if (rowsPer < 1) rowsPer = 1; if (rowsPer > H) rowsPer = H;
    float *col = (float *)malloc(sizeof(float) * (size_t)K * rowsPer * W);
    float *tmp = (float *)malloc(sizeof(float) * (size_t)O * rowsPer * W);
    if (!col || !tmp) { free(col); free(tmp); return; }
    for (int y0 = 0; y0 < H; y0 += rowsPer) {
        int rows = H - y0 < rowsPer ? H - y0 : rowsPer; int N = rows * W;
        for (int c = 0; c < I; c++) for (int ky = 0; ky < k; ky++) for (int kx = 0; kx < k; kx++) {
            float *dst = col + ((size_t)(c * k + ky) * k + kx) * N;
            int dy = ky * dil - pad, dx = kx * dil - pad;
            for (int r = 0; r < rows; r++) {
                int sy = y0 + r + dy; float *d = dst + (size_t)r * W;
                if (sy < 0 || sy >= H) { memset(d, 0, sizeof(float) * W); continue; }
                const float *s = x + ((size_t)c * H + sy) * W;
                for (int xx = 0; xx < W; xx++) { int sx = xx + dx; d[xx] = (sx < 0 || sx >= W) ? 0.f : s[sx]; }
            }
        }
        GEMM(O, N, K, w->data, col, tmp);
        for (int o = 0; o < O; o++) { float b = bias->data[o]; const float *s = tmp + (size_t)o * N; float *d = y + ((size_t)o * H + y0) * W; for (int i = 0; i < N; i++) d[i] = s[i] + b; }
    }
    free(col); free(tmp);
}
static void resize_bl(const float *x, int C, int H, int W, int oh, int ow, float *y) {
    for (int c = 0; c < C; c++) for (int j = 0; j < oh; j++) {
        float sy = oh > 1 ? ((j + 0.5f) * H / oh - 0.5f) : 0.f; if (sy < 0) sy = 0; if (sy > H - 1) sy = (float)(H - 1);
        int y0 = (int)floorf(sy), y1 = y0 + 1 < H ? y0 + 1 : H - 1; float fy = sy - y0;
        const float *r0 = x + ((size_t)c * H + y0) * W, *r1 = x + ((size_t)c * H + y1) * W; float *d = y + ((size_t)c * oh + j) * ow;
        for (int i = 0; i < ow; i++) {
            float sx = ow > 1 ? ((i + 0.5f) * W / ow - 0.5f) : 0.f; if (sx < 0) sx = 0; if (sx > W - 1) sx = (float)(W - 1);
            int x0 = (int)floorf(sx), x1 = x0 + 1 < W ? x0 + 1 : W - 1; float fx = sx - x0;
            float t = r0[x0] * (1 - fx) + r0[x1] * fx, b = r1[x0] * (1 - fx) + r1[x1] * fx; d[i] = t * (1 - fy) + b * fy;
        }
    }
}
int u2seg_run(const uint8_t *m, size_t len, const float *input, float *out, int *outS) {
    if (len < 32 || memcmp(m, "U2P1", 4)) return 1;
    const uint32_t *h = (const uint32_t *)(m + 4); uint32_t S = h[0], nT = h[1], nOps = h[2], nW = h[3], inId = h[4], finalId = h[5];
    size_t off = 4 + 7 * 4; Wt *ws = (Wt *)calloc(nW, sizeof(Wt));
    for (uint32_t i = 0; i < nW; i++) {
        uint32_t nd; memcpy(&nd, m + off, 4); off += 4; ws[i].nd = nd; size_t n = 1;
        for (uint32_t d = 0; d < nd; d++) { memcpy(&ws[i].shape[d], m + off, 4); off += 4; n *= ws[i].shape[d]; }
        ws[i].data = (const float *)(m + off); ws[i].n = n; off += n * 4;
    }
    Op *ops = (Op *)malloc(sizeof(Op) * nOps); memcpy(ops, m + off, sizeof(Op) * nOps);
    float **buf = (float **)calloc(nT, sizeof(float *)); uint32_t *lastUse = (uint32_t *)calloc(nT, 4);
    int (*dim)[3] = calloc(nT, sizeof(int[3]));
    for (uint32_t i = 0; i < nOps; i++) for (int k = 0; k < 6; k++) if (ops[i].in[k] != NONE) lastUse[ops[i].in[k]] = i;
    lastUse[finalId] = nOps + 1;
    buf[inId] = (float *)input; dim[inId][0] = 3; dim[inId][1] = dim[inId][2] = (int)S;
    int ok = 1;
    for (uint32_t i = 0; i < nOps && ok; i++) {
        Op *o = &ops[i]; int C = (int)o->c, H = (int)o->h, W = (int)o->w; size_t n = (size_t)C * H * W;
        float *y = (float *)malloc(n * sizeof(float));
        if (!y) { ok = 0; break; }
        const float *x0 = buf[o->in[0]]; int *d0 = dim[o->in[0]];
        switch (o->t) {
            case 1: conv(x0, d0[0], H, W, &ws[o->a], &ws[o->b], (int)o->p0, (int)o->p1, y); break;
            case 2: for (size_t j = 0; j < n; j++) y[j] = x0[j] > 0 ? x0[j] : 0; break;
            case 3: {   // 2x2 stride 2, ceil mode (edge windows are clipped)
                int IH = d0[1], IW = d0[2];
                for (int c = 0; c < C; c++) for (int j = 0; j < H; j++) for (int k = 0; k < W; k++) {
                    float mx = -INFINITY;
                    for (int dy = 0; dy < 2; dy++) for (int dx = 0; dx < 2; dx++) { int yy = j * 2 + dy, xx = k * 2 + dx; if (yy < IH && xx < IW) { float v = x0[((size_t)c * IH + yy) * IW + xx]; if (v > mx) mx = v; } }
                    y[((size_t)c * H + j) * W + k] = mx;
                }
                break; }
            case 4: { size_t pos = 0; for (int k = 0; k < 6 && o->in[k] != NONE; k++) { size_t sz = (size_t)dim[o->in[k]][0] * dim[o->in[k]][1] * dim[o->in[k]][2]; memcpy(y + pos, buf[o->in[k]], sz * 4); pos += sz; } break; }
            case 5: { const float *b = buf[o->in[1]]; for (size_t j = 0; j < n; j++) y[j] = x0[j] + b[j]; break; }
            case 6: resize_bl(x0, d0[0], d0[1], d0[2], H, W, y); break;
            case 7: for (size_t j = 0; j < n; j++) y[j] = 1.f / (1.f + expf(-x0[j])); break;
            default: ok = 0; break;
        }
        buf[o->out] = y; dim[o->out][0] = C; dim[o->out][1] = H; dim[o->out][2] = W;
        for (int k = 0; k < 6; k++) { uint32_t t = o->in[k]; if (t == NONE) continue; if (lastUse[t] == i && t != inId && buf[t]) { free(buf[t]); buf[t] = NULL; } }
    }
    if (ok) { memcpy(out, buf[finalId], (size_t)S * S * sizeof(float)); if (outS) *outS = (int)S; }
    for (uint32_t t = 0; t < nT; t++) if (buf[t] && t != inId) free(buf[t]);
    free(buf); free(lastUse); free(dim); free(ops); free(ws);
    return ok ? 0 : 2;
}
