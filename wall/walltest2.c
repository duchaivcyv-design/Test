#include "u2seg.h"
#include "wallcore.h"
#include <stdio.h>
#include <stdlib.h>
static uint8_t *rd(const char *p, size_t *n) { FILE *f = fopen(p, "rb"); fseek(f, 0, SEEK_END); *n = ftell(f); rewind(f); uint8_t *b = malloc(*n); fread(b, 1, *n, f); fclose(f); return b; }
int main(int c, char **v) {   // model rgba W H out clock(0/1)
    size_t nm, ni; uint8_t *m = rd(v[1], &nm); uint8_t *img = rd(v[2], &ni); int W = atoi(v[3]), H = atoi(v[4]); int clk = atoi(v[6]); float band = 0.42f;
    float *in = malloc(3*256*256*4), *n1 = malloc(256*256*4), *n2 = NULL; int S;
    wall_prepare(img, W, H, 256, in); u2seg_run(m, nm, in, n1, &S);
    if (clk) { n2 = malloc(256*256*4); wall_prepare(img, W, (int)(H*band), 256, in); u2seg_run(m, nm, in, n2, &S); }
    uint8_t *al = malloc((size_t)W*H), *o = malloc((size_t)W*H*4);
    float cov = wall_mask2(img, W, H, n1, n2, clk ? band : 0, 256, al); wall_cutout(img, W, H, al, o);
    FILE *f = fopen(v[5], "wb"); fwrite(o, 1, (size_t)W*H*4, f); fclose(f); printf("coverage=%.3f\n", cov); return 0;
}
