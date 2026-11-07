// 26wallseg <in.png> <model.u2p> <out.png>  -> cut-out (premultiplied RGBA PNG). exit: 0 ok, 3 no clear subject, other = error
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <sys/resource.h>
#include <stdio.h>
#include "u2seg.h"
#include "wallcore.h"
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 4) return 2;
        setpriority(PRIO_PROCESS, 0, 15);
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[1])], NULL);
        CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
        if (!img) { fprintf(stderr, "cannot read image\n"); return 4; }
        size_t iw = CGImageGetWidth(img), ih = CGImageGetHeight(img);
        float sc = 1.f; size_t mx = iw > ih ? iw : ih; if (mx > 1400) sc = 1400.f / mx;
        int W = (int)(iw * sc + 0.5f), H = (int)(ih * sc + 0.5f);
        uint8_t *rgba = (uint8_t *)calloc((size_t)W * H, 4);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef cx = CGBitmapContextCreate(rgba, W, H, 8, (size_t)W * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGContextSetInterpolationQuality(cx, kCGInterpolationHigh);
        CGContextDrawImage(cx, CGRectMake(0, 0, W, H), img); CGContextRelease(cx); CGImageRelease(img); CFRelease(src);
        NSData *model = [NSData dataWithContentsOfFile:@(argv[2]) options:NSDataReadingMappedIfSafe error:nil];
        if (!model.length) { fprintf(stderr, "no model\n"); return 5; }
        const int S = 256;
        float *in = (float *)malloc(sizeof(float) * 3 * S * S), *net = (float *)malloc(sizeof(float) * S * S);
        wall_prepare(rgba, W, H, S, in);
        int outS = 0; int rc = u2seg_run((const uint8_t *)model.bytes, model.length, in, net, &outS);
        if (rc != 0 || outS != S) { fprintf(stderr, "network failed rc=%d\n", rc); return 6; }
        // "clock first": second pass on the top part of the picture (where the lock screen clock sits)
        BOOL clockFirst = argc > 4 && atoi(argv[4]) != 0; float band = 0.42f; float *net2 = NULL;
        if (clockFirst) {
            int bh = (int)(H * band); net2 = (float *)malloc(sizeof(float) * S * S);
            wall_prepare(rgba, W, bh, S, in);
            int s2 = 0; if (u2seg_run((const uint8_t *)model.bytes, model.length, in, net2, &s2) != 0) { free(net2); net2 = NULL; }
        }
        free(in);
        uint8_t *alpha = (uint8_t *)malloc((size_t)W * H);
        float cov = wall_mask2(rgba, W, H, net, net2, net2 ? band : 0.f, S, alpha); free(net); free(net2);
        // An abstract wallpaper (colour bands/swirls) comes out as one shape that spans the whole width of the clock area: not a subject.
        int CH = (int)(H * (clockFirst ? band : 0.45f) + 0.5f); if (CH < 8) CH = H;
        int leftRows = 0, rightRows = 0, bw = W / 20 > 2 ? W / 20 : 2; size_t topCnt = 0;
        for (int y = 0; y < CH; y++) { int l = 0, r = 0; for (int x = 0; x < bw; x++) { if (alpha[(size_t)y * W + x] > 128) l = 1; if (alpha[(size_t)y * W + W - 1 - x] > 128) r = 1; }
            leftRows += l; rightRows += r; for (int x = 0; x < W; x++) if (alpha[(size_t)y * W + x] > 128) topCnt++; }
        float topCov = (float)topCnt / ((float)CH * W);
        int spans = leftRows > CH * 0.08f && rightRows > CH * 0.08f && topCov > 0.30f;
        fprintf(stdout, "coverage=%.3f topCoverage=%.3f spans=%d size=%dx%d\n", cov, topCov, spans, W, H);
        BOOL skipAbstract = argc > 5 && atoi(argv[5]) != 0;      // optional: ignore colour-band wallpapers
        if (cov < 0.02f || cov > 0.88f || (spans && skipAbstract)) return 3;
        uint8_t *outpx = (uint8_t *)malloc((size_t)W * H * 4);
        wall_cutout(rgba, W, H, alpha, outpx);
        CGContextRef oc = CGBitmapContextCreate(outpx, W, H, 8, (size_t)W * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGImageRef oi = CGBitmapContextCreateImage(oc);
        CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[3])], CFSTR("public.png"), 1, NULL);
        CGImageDestinationAddImage(dst, oi, NULL);
        if (!CGImageDestinationFinalize(dst)) { fprintf(stderr, "write failed\n"); return 7; }
        return 0;
    }
}
