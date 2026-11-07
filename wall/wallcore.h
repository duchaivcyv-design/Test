#ifndef WALLCORE_H
#define WALLCORE_H
#include <stdint.h>
// Prepare network input (3*S*S floats, CHW) from an RGBA8 image (any size) - nearest/area resample done by caller is not required.
void wall_prepare(const uint8_t *rgba, int W, int H, int S, float *outCHW);
// Turn raw network output (S*S, 0..1) into a full-size alpha mask refined along image edges. Returns subject coverage 0..1 (area with alpha>0.5).
float wall_mask(const uint8_t *rgba, int W, int H, const float *net, int S, uint8_t *alphaOut);
float wall_mask2(const uint8_t *rgba, int W, int H, const float *net1, const float *net2, float band, int S, uint8_t *alphaOut);
// Premultiplied RGBA cutout from rgba + alpha.
void wall_cutout(const uint8_t *rgba, int W, int H, const uint8_t *alpha, uint8_t *outPremul);
#endif
