#include "u2seg.h"
#include "wallcore.h"
#include <stdio.h>
#include <stdlib.h>
static uint8_t *rd(const char *p, size_t *n) { FILE *f = fopen(p, "rb"); fseek(f, 0, SEEK_END); *n = ftell(f); rewind(f); uint8_t *b = malloc(*n); fread(b, 1, *n, f); fclose(f); return b; }
int main(int c, char **v) {   // walltest model.u2p in.rgba W H out.rgba
    size_t nm, ni; uint8_t *m = rd(v[1], &nm); uint8_t *img = rd(v[2], &ni); int W = atoi(v[3]), H = atoi(v[4]);
    float *in = malloc(3 * 256 * 256 * 4), *net = malloc(256 * 256 * 4); wall_prepare(img, W, H, 256, in);
    int S; int r = u2seg_run(m, nm, in, net, &S); uint8_t *al = malloc((size_t)W * H), *o = malloc((size_t)W * H * 4);
    float cov = wall_mask(img, W, H, net, 256, al); wall_cutout(img, W, H, al, o);
    FILE *f = fopen(v[5], "wb"); fwrite(o, 1, (size_t)W * H * 4, f); fclose(f); printf("rc=%d coverage=%.3f\n", r, cov); return 0;
}
