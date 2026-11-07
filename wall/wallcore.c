#include "wallcore.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>
static float clampf(float v, float a, float b) { return v < a ? a : (v > b ? b : v); }
static float sample(const uint8_t *px, int W, int H, float fx, float fy, int ch) {
    int x0 = (int)floorf(fx), y0 = (int)floorf(fy); float ax = fx - x0, ay = fy - y0;
    int x1 = x0 + 1, y1 = y0 + 1; if (x0 < 0) x0 = 0; if (y0 < 0) y0 = 0; if (x1 >= W) x1 = W - 1; if (y1 >= H) y1 = H - 1; if (x0 >= W) x0 = W - 1; if (y0 >= H) y0 = H - 1;
    float a = px[((size_t)y0 * W + x0) * 4 + ch], b = px[((size_t)y0 * W + x1) * 4 + ch], c = px[((size_t)y1 * W + x0) * 4 + ch], d = px[((size_t)y1 * W + x1) * 4 + ch];
    return (a * (1 - ax) + b * ax) * (1 - ay) + (c * (1 - ax) + d * ax) * ay;
}
void wall_prepare(const uint8_t *rgba, int W, int H, int S, float *out) {
    // area-ish downsample: average a block of source pixels per target pixel
    float mx = 1e-6f; size_t plane = (size_t)S * S;
    for (int y = 0; y < S; y++) for (int x = 0; x < S; x++) {
        int sx0 = x * W / S, sx1 = (x + 1) * W / S; if (sx1 <= sx0) sx1 = sx0 + 1;
        int sy0 = y * H / S, sy1 = (y + 1) * H / S; if (sy1 <= sy0) sy1 = sy0 + 1;
        float acc[3] = {0, 0, 0}; int n = 0;
        for (int yy = sy0; yy < sy1 && yy < H; yy++) for (int xx = sx0; xx < sx1 && xx < W; xx++) { const uint8_t *p = rgba + ((size_t)yy * W + xx) * 4; acc[0] += p[0]; acc[1] += p[1]; acc[2] += p[2]; n++; }
        if (!n) n = 1;
        for (int c = 0; c < 3; c++) { float v = acc[c] / n / 255.f; out[c * plane + (size_t)y * S + x] = v; if (v > mx) mx = v; }
    }
    static const float mean[3] = {0.485f, 0.456f, 0.406f}, sd[3] = {0.229f, 0.224f, 0.225f};
    for (int c = 0; c < 3; c++) for (size_t i = 0; i < plane; i++) out[c * plane + i] = (out[c * plane + i] / mx - mean[c]) / sd[c];
}
// box filter (mean) with radius r, edge-clamped by window shrinking
static void boxf(const float *in, float *out, int W, int H, int r) {
    float *tmp = (float *)malloc(sizeof(float) * (size_t)W * H);
    for (int y = 0; y < H; y++) {            // horizontal
        const float *s = in + (size_t)y * W; float *d = tmp + (size_t)y * W; double acc = 0; int lo = 0, hi = -1;
        for (int x = 0; x < W; x++) {
            int nl = x - r < 0 ? 0 : x - r, nh = x + r >= W ? W - 1 : x + r;
            while (hi < nh) acc += s[++hi]; while (lo < nl) acc -= s[lo++];
            d[x] = (float)(acc / (nh - nl + 1));
        }
    }
    for (int x = 0; x < W; x++) {            // vertical
        double acc = 0; int lo = 0, hi = -1;
        for (int y = 0; y < H; y++) {
            int nl = y - r < 0 ? 0 : y - r, nh = y + r >= H ? H - 1 : y + r;
            while (hi < nh) { hi++; acc += tmp[(size_t)hi * W + x]; } while (lo < nl) { acc -= tmp[(size_t)lo * W + x]; lo++; }
            out[(size_t)y * W + x] = (float)(acc / (nh - nl + 1));
        }
    }
    free(tmp);
}
static float net_at(const float *net, int S, float mn, float rng, float fx, float fy) {
    fx = clampf(fx, 0, S - 1); fy = clampf(fy, 0, S - 1);
    int x0 = (int)fx, y0 = (int)fy, x1 = x0 + 1 < S ? x0 + 1 : x0, y1 = y0 + 1 < S ? y0 + 1 : y0; float ax = fx - x0, ay = fy - y0;
    float v = (net[y0 * S + x0] * (1 - ax) + net[y0 * S + x1] * ax) * (1 - ay) + (net[y1 * S + x0] * (1 - ax) + net[y1 * S + x1] * ax) * ay;
    return (v - mn) / rng;
}
static void net_range(const float *net, int S, float *mn, float *rng) {
    float lo = 1e9f, hi = -1e9f; for (int i = 0; i < S * S; i++) { if (net[i] < lo) lo = net[i]; if (net[i] > hi) hi = net[i]; }
    *mn = lo; *rng = hi - lo < 1e-4f ? 1e-4f : hi - lo;
    if (hi < 0.5f) { *mn = 1.f; *rng = 1e9f; }      // the network sees nothing salient here: treat as "no subject" instead of stretching noise
}
// net1 = whole image; net2 (optional) = the top `band` fraction of the image (the clock zone), blended in with a soft vertical fade.
float wall_mask2(const uint8_t *rgba, int W, int H, const float *net1, const float *net2, float band, int S, uint8_t *alphaOut) {
    size_t N = (size_t)W * H;
    float mn1, r1, mn2 = 0, r2 = 1; net_range(net1, S, &mn1, &r1); if (net2) net_range(net2, S, &mn2, &r2);
    int bandH = (int)(H * band); if (bandH < 2) bandH = 2; float fadeStart = bandH * 0.78f;
    float *p = (float *)malloc(N * sizeof(float)), *I = (float *)malloc(N * sizeof(float));
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        float v = net_at(net1, S, mn1, r1, (x + 0.5f) * S / W - 0.5f, (y + 0.5f) * S / H - 0.5f);
        if (net2 && y < bandH) {
            float v2 = net_at(net2, S, mn2, r2, (x + 0.5f) * S / W - 0.5f, (y + 0.5f) * S / bandH - 0.5f);
            float w = y <= fadeStart ? 1.f : 1.f - (y - fadeStart) / (bandH - fadeStart); w = w * w * (3 - 2 * w);
            v = v * (1 - w) + v2 * w;
        }
        p[(size_t)y * W + x] = v;
        const uint8_t *q = rgba + ((size_t)y * W + x) * 4; I[(size_t)y * W + x] = (0.299f * q[0] + 0.587f * q[1] + 0.114f * q[2]) / 255.f;
    }
    // guided filter (He et al.), radius scales with image size
    int r = (int)(fminf(W, H) / 90.f); if (r < 3) r = 3; float eps = 4e-3f;
    float *mI = (float *)malloc(N * 4), *mp = (float *)malloc(N * 4), *t1 = (float *)malloc(N * 4), *t2 = (float *)malloc(N * 4);
    boxf(I, mI, W, H, r); boxf(p, mp, W, H, r);
    for (size_t i = 0; i < N; i++) t1[i] = I[i] * I[i]; boxf(t1, t2, W, H, r);       // t2 = corr_I
    float *cIp = t1; for (size_t i = 0; i < N; i++) cIp[i] = I[i] * p[i];
    float *mIp = (float *)malloc(N * 4); boxf(cIp, mIp, W, H, r);
    float *a = (float *)malloc(N * 4), *b = (float *)malloc(N * 4);
    for (size_t i = 0; i < N; i++) { float var = t2[i] - mI[i] * mI[i], cov = mIp[i] - mI[i] * mp[i]; a[i] = cov / (var + eps); b[i] = mp[i] - a[i] * mI[i]; }
    boxf(a, t1, W, H, r); boxf(b, t2, W, H, r);
    size_t cnt = 0;
    for (size_t i = 0; i < N; i++) {
        float q = t1[i] * I[i] + t2[i];
        float s = clampf((q - 0.5f) * 3.2f + 0.5f, 0, 1); s = s * s * (3 - 2 * s);   // firm but soft edge
        alphaOut[i] = (uint8_t)(s * 255.f + 0.5f); if (s > 0.5f) cnt++;
    }
    free(p); free(I); free(mI); free(mp); free(t1); free(t2); free(mIp); free(a); free(b);
    return (float)cnt / (float)N;
}
float wall_mask(const uint8_t *rgba, int W, int H, const float *net, int S, uint8_t *alphaOut) { return wall_mask2(rgba, W, H, net, NULL, 0.f, S, alphaOut); }
void wall_cutout(const uint8_t *rgba, int W, int H, const uint8_t *alpha, uint8_t *out) {
    size_t N = (size_t)W * H;
    for (size_t i = 0; i < N; i++) { unsigned a = alpha[i]; out[i*4] = (uint8_t)((rgba[i*4] * a + 127) / 255); out[i*4+1] = (uint8_t)((rgba[i*4+1] * a + 127) / 255); out[i*4+2] = (uint8_t)((rgba[i*4+2] * a + 127) / 255); out[i*4+3] = (uint8_t)a; }
}
