// u2seg: tiny U^2-Net-P runtime (executes a program baked by export_model.py). No dependencies except libc (+Accelerate on iOS).
#ifndef U2SEG_H
#define U2SEG_H
#include <stddef.h>
#include <stdint.h>
// model: whole .u2p file. input: 3*S*S floats (CHW, normalised). out: S*S floats in 0..1. Returns 0 on success.
int u2seg_run(const uint8_t *model, size_t len, const float *input, float *out, int *outS);
#endif
