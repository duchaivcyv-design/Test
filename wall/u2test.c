#include "u2seg.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
static uint8_t *rd(const char *p, size_t *n) { FILE *f = fopen(p, "rb"); fseek(f, 0, SEEK_END); *n = ftell(f); rewind(f); uint8_t *b = malloc(*n); fread(b, 1, *n, f); fclose(f); return b; }
int main(int c, char **v) {
    size_t nm, ni, nr; uint8_t *m = rd(v[1], &nm); char p[512];
    snprintf(p, 512, "%s.in", v[1]); float *in = (float *)rd(p, &ni); snprintf(p, 512, "%s.ref", v[1]); float *ref = (float *)rd(p, &nr);
    float *out = malloc(nr); int S = 0; int r = u2seg_run(m, nm, in, out, &S); double md = 0; for (size_t i = 0; i < nr / 4; i++) { double d = fabs(out[i] - ref[i]); if (d > md) md = d; }
    printf("rc=%d S=%d maxdiff=%g\n", r, S, md); return 0;
}
