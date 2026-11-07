// MARK: - 26Home: iOS 18/26 style home screen customisation (icon styles, Customize sheet, edit menu)
// Included by Tweak.m (same translation unit), SpringBoard only.

static BOOL gH26Enabled = YES, gH26Labels = NO, gH26Loaded = NO;
static int gH26Style = 0;          // 0 Default, 1 Dark, 2 Clear, 3 Tinted
static int gH26Ver = 0;            // icon generation: 0 iOS 26 (Solid Glass 2), 1 iOS 27 (Solid Glass 27); icons missing from a generation fall back to the iOS 26 pack
static int gH26Mode = 0;           // 0 Light, 1 Dark, 2 Auto
static int gH26BG = 0;             // tinted: 0 dark background, 1 light background
static int gH26Src = 0;            // tinted colour: 0 custom (sliders), 1 from the wallpaper
static double gH26Hue = 0.58, gH26Sat = 0.85, gH26Bri = 1.0, gH26Wall = 0.6;
static NSMutableDictionary *gH26Orig, *gH26Proc;
static NSString *gH26ProcKey;
static const void *kH26Lbl = &kH26Lbl;

static double H26D(NSString *k, double d) {
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)k, W12_DOMAIN));
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : d;
}
static void H26Load(void) {
    CFPreferencesAppSynchronize(W12_DOMAIN);
    gH26Style = (int)H26D(@"h26Style", 0); gH26Mode = (int)H26D(@"h26Mode", 0); gH26BG = (int)H26D(@"h26BG", 0); gH26Src = (int)H26D(@"h26Src", 1);
    gH26Hue = H26D(@"h26Hue", 0.58); gH26Sat = H26D(@"h26Sat", 0.85); gH26Bri = H26D(@"h26Bri", 1.0); gH26Labels = H26D(@"h26Labels", 0) > 0.5;
    gH26Wall = H26D(@"h26Wall", 0.6);
    gH26Ver = (int)H26D(@"h26Ver", 0); if (gH26Ver < 0 || gH26Ver > 1) gH26Ver = 0;
    gH26Loaded = YES;
}
static void H26Save(void) {
    void (^set)(NSString *, double) = ^(NSString *k, double v) { CFPreferencesSetAppValue((__bridge CFStringRef)k, (__bridge CFTypeRef)@(v), W12_DOMAIN); };
    set(@"h26Style", gH26Style); set(@"h26Mode", gH26Mode); set(@"h26BG", gH26BG); set(@"h26Src", gH26Src);
    set(@"h26Hue", gH26Hue); set(@"h26Sat", gH26Sat); set(@"h26Bri", gH26Bri); set(@"h26Labels", gH26Labels ? 1 : 0); set(@"h26Wall", gH26Wall);
    CFPreferencesAppSynchronize(W12_DOMAIN);
}

static BOOL H26Night(void) {
    if (gH26Mode == 1) return YES;
    if (gH26Mode == 2) { NSInteger h = [[NSCalendar currentCalendar] component:NSCalendarUnitHour fromDate:[NSDate date]]; return h >= 18 || h < 6; }
    return NO;
}
static int H26Eff(void) {
    if (gH26Style == 1 && gH26Mode == 2 && !H26Night()) return 0;      // Dark / Auto: dark only at night
    return gH26Style;
}
static double H26HueNow(void) { return gH26Src == 1 ? gH26Wall : gH26Hue; }
static BOOL H26SnowActive(void);
static BOOL H26HueFromImage(CGImageRef img, double *outHue) {
    uint8_t px[24 * 40 * 4]; memset(px, 0, sizeof(px));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(px, 24, 40, 8, 24 * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (c) { CGContextSetInterpolationQuality(c, kCGInterpolationMedium); CGContextDrawImage(c, CGRectMake(0, 0, 24, 40), img); CGContextRelease(c); }
    CGColorSpaceRelease(cs);
    double sx = 0, sy = 0, ws = 0;      // saturation-weighted vector mean of the hue: a colourful wallpaper wins over grey areas
    for (int i = 0; i < 24 * 40; i++) {
        CGFloat h, s, b, a; [[UIColor colorWithRed:px[i * 4] / 255.0 green:px[i * 4 + 1] / 255.0 blue:px[i * 4 + 2] / 255.0 alpha:1] getHue:&h saturation:&s brightness:&b alpha:&a];
        double wgt = s * s * b; sx += cos(h * 2 * M_PI) * wgt; sy += sin(h * 2 * M_PI) * wgt; ws += wgt;
    }
    if (ws < 0.01) return NO;
    double h = atan2(sy, sx) / (2 * M_PI); if (h < 0) h += 1; *outHue = h; return YES;
}
// The icon colour follows the home wallpaper by itself (re-read whenever the wallpaper file changes). Returns YES when the hue changed.
static BOOL H26WallUpdate(BOOL force) {
    static double lastM = -1;
    NSString *p = @"/var/mobile/Library/SpringBoard/HomeBackgroundThumbnail.jpg";
    NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
    if (!at) return NO;
    double m = [at.fileModificationDate timeIntervalSince1970];
    if (!force && m == lastM) return NO;
    lastM = m;
    UIImage *im = [UIImage imageWithContentsOfFile:p]; if (!im.CGImage) return NO;
    double h; if (!H26HueFromImage(im.CGImage, &h)) return NO;
    BOOL ch = fabs(h - gH26Wall) > 0.004; gH26Wall = h;
    if (ch) W12_LOG(@"26home: wallpaper hue %.3f", h);
    return ch;
}
static NSString *H26ParamKey(void) {
    return [NSString stringWithFormat:@"%d|%.3f|%.3f|%.2f|%d|%d|%d|v%d", H26Eff(), H26HueNow(), gH26Sat, gH26Bri, H26Night(), gH26BG, H26SnowActive(), gH26Ver];
}

// ---- pixel processing ----
static inline double H26Sm(double a, double b, double x) { double t = (x - a) / (b - a); t = t < 0 ? 0 : (t > 1 ? 1 : t); return t * t * (3 - 2 * t); }
static void H26HSB(double h, double s, double v, double *r, double *g, double *b) {
    h = h - floor(h); s = MAX(0, MIN(1, s)); v = MAX(0, MIN(1, v));
    double i = floor(h * 6), f = h * 6 - i, p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s);
    switch ((int)i % 6) {
        case 0: *r = v; *g = t; *b = p; break; case 1: *r = q; *g = v; *b = p; break; case 2: *r = p; *g = v; *b = t; break;
        case 3: *r = p; *g = q; *b = v; break; case 4: *r = t; *g = p; *b = v; break; default: *r = v; *g = p; *b = q;
    }
}
static void H26Box(float *a, float *t, size_t w, size_t h, int r) {              // separable box blur, clamped edges
    int n = 2 * r + 1;
    for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) { float s = 0; for (int k = -r; k <= r; k++) { long xx = (long)x + k; xx = xx < 0 ? 0 : (xx >= (long)w ? (long)w - 1 : xx); s += a[y * w + xx]; } t[y * w + x] = s / n; }
    for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) { float s = 0; for (int k = -r; k <= r; k++) { long yy = (long)y + k; yy = yy < 0 ? 0 : (yy >= (long)h ? (long)h - 1 : yy); s += t[(size_t)yy * w + x]; } a[y * w + x] = s / n; }
}
static void H26Med(uint8_t *buf, size_t w, size_t h, double yf, double *o) {      // per-channel median of five samples along a row
    const double xs[5] = {0.2, 0.35, 0.5, 0.65, 0.8}; double v[3][5]; int n = 0;
    for (int i = 0; i < 5; i++) {
        uint8_t *p = buf + ((size_t)(yf * h) * w + (size_t)(xs[i] * w)) * 4; double a = p[3] / 255.0; if (a < 0.5) continue;
        for (int c = 0; c < 3; c++) v[c][n] = MIN(1, p[c] / 255.0 / a); n++;
    }
    if (!n) { o[0] = o[1] = o[2] = 0.5; return; }
    for (int c = 0; c < 3; c++) { for (int i = 1; i < n; i++) { double x = v[c][i]; int j = i - 1; while (j >= 0 && v[c][j] > x) { v[c][j + 1] = v[c][j]; j--; } v[c][j + 1] = x; } o[c] = v[c][n / 2]; }
}
static void H26Warp(const float *src, float *dst, size_t w, size_t h, double sc, double bx, double by) {   // dst(p) = src((p - centre) / sc + (bx, by)), bilinear, zero outside
    double cx = w / 2.0, cy = h / 2.0;
    for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) {
        double sx = (x - cx) / sc + bx, sy = (y - cy) / sc + by, v = 0;
        if (sx >= 0 && sy >= 0 && sx <= w - 1 && sy <= h - 1) {
            size_t x0 = (size_t)sx, y0 = (size_t)sy, x1 = MIN(w - 1, x0 + 1), y1 = MIN(h - 1, y0 + 1); double fx = sx - x0, fy = sy - y0;
            v = (src[y0 * w + x0] * (1 - fx) + src[y0 * w + x1] * fx) * (1 - fy) + (src[y1 * w + x0] * (1 - fx) + src[y1 * w + x1] * fx) * fy;
        }
        dst[y * w + x] = (float)v;
    }
}
static void H26Chamfer(const uint8_t *buf, float *dist, size_t w, size_t h) {      // distance of every pixel to the icon's edge (two-pass chamfer)
    for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) { size_t k = y * w + x; dist[k] = (buf[k * 4 + 3] < 128 || x == 0 || y == 0 || x == w - 1 || y == h - 1) ? 0 : 1e6f; }
    for (size_t y = 1; y < h; y++) for (size_t x = 1; x + 1 < w; x++) { size_t k = y * w + x; float m = dist[k]; m = fminf(m, dist[k - 1] + 1); m = fminf(m, dist[k - w] + 1); m = fminf(m, dist[k - w - 1] + 1.414f); m = fminf(m, dist[k - w + 1] + 1.414f); dist[k] = m; }
    for (size_t y = h - 1; y-- > 0;) for (size_t x = w - 1; x-- > 1;) { size_t k = y * w + x; float m = dist[k]; m = fminf(m, dist[k + 1] + 1); m = fminf(m, dist[k + w] + 1); m = fminf(m, dist[k + w - 1] + 1.414f); m = fminf(m, dist[k + w + 1] + 1.414f); dist[k] = m; }
}
// style: 0 original look (only brightness) / 1 Dark / 2 Clear / 3 Tinted / 4 default + glass gloss
static UIImage *H26Process(UIImage *src, int style, double hue, double sat, double bri, BOOL night, int bgMode, BOOL glassSrc) {
    CGImageRef cg = src.CGImage; if (!cg) return src;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w < 8 || h < 8 || w > 1024 || h > 1024) return src;
    size_t N = w * h;
    uint8_t *buf = calloc(N, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!c) { free(buf); CGColorSpaceRelease(cs); return src; }
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), cg);
    // background colour of the icon: median near the top and the bottom edge, blended by row (handles vertical gradients)
    double bt[3], bb2[3]; H26Med(buf, w, h, 0.13, bt); H26Med(buf, w, h, 0.87, bb2);
    double Lbg = 0.5 * (0.299 * (bt[0] + bb2[0]) + 0.587 * (bt[1] + bb2[1]) + 0.114 * (bt[2] + bb2[2])); BOOL lightBG = Lbg > 0.55;
    // distance of every pixel to the icon's edge (two-pass chamfer)
    float *dist = malloc(N * sizeof(float));
    H26Chamfer(buf, dist, w, h);
    double rimLo = w * 0.022, rimHi = w * 0.060;
    float *sig = NULL; double slabV = 0;
    if (glassSrc) {                                          // ready-made glass icon: its alpha is the signal (glyph = opaque, slab = faint); the shape is a rounded square
        sig = malloc(N * sizeof(float));
        uint8_t *cm = calloc(N, 1); CGColorSpaceRef gcs = CGColorSpaceCreateDeviceGray();
        CGContextRef mc = CGBitmapContextCreate(cm, w, h, 8, w, gcs, kCGImageAlphaNone);
        if (mc) { CGContextSetGrayFillColor(mc, 1, 1); CGContextAddPath(mc, W12SquirclePath(CGRectMake(0, 0, w, h), w * 0.256).CGPath); CGContextFillPath(mc); CGContextRelease(mc); }
        CGColorSpaceRelease(gcs);
        for (size_t k = 0; k < N; k++) {
            sig[k] = (float)((0.299 * buf[k * 4] + 0.587 * buf[k * 4 + 1] + 0.114 * buf[k * 4 + 2]) / 255.0);   // premultiplied brightness: faint slab -> low, bright glyph -> high, dark opaque slab -> low
            buf[k * 4] = buf[k * 4 + 1] = buf[k * 4 + 2] = buf[k * 4 + 3] = cm[k];                                 // the shape is the exact icon squircle
        }
        free(cm); H26Chamfer(buf, dist, w, h);
        int rh[64] = {0}; long rn = 0;                       // the slab's own level: median of the border band
        for (size_t k = 0; k < N; k++) if (dist[k] >= w * 0.06 && dist[k] < w * 0.14) { rh[MAX(0, MIN(63, (int)(sig[k] * 64)))]++; rn++; }
        if (rn > 0) { long acc = 0; for (int i = 0; i < 64; i++) { acc += rh[i]; if (acc >= rn / 2) { slabV = (i + 1) / 64.0; break; } } }
    }
    // per-pixel pass 1: luminance histogram (contrast stretch), "far from background" share (picture icons)
    int hist[64] = {0}; long cnt = 0, inner = 0, far = 0, ringN = 0, ringFar = 0; double ringHi = w * 0.14;
    for (size_t i = 0; i < N; i++) {
        uint8_t *p = buf + i * 4; double a = p[3] / 255.0; if (a < 0.5) continue;
        double r = MIN(1, p[0] / 255.0 / a), g = MIN(1, p[1] / 255.0 / a), b = MIN(1, p[2] / 255.0 / a);
        double L = 0.299 * r + 0.587 * g + 0.114 * b; hist[MIN(63, (int)(L * 64))]++; cnt++;
        if (dist[i] < rimHi) continue;
        double t = (double)(i / w) / (double)h, br = bt[0] + (bb2[0] - bt[0]) * t, bg = bt[1] + (bb2[1] - bt[1]) * t, bb = bt[2] + (bb2[2] - bt[2]) * t;
        double dd = MAX(fabs(r - br), MAX(fabs(g - bg), fabs(b - bb)));
        inner++; if (dd > 0.2) far++;
        if (dist[i] < ringHi) { ringN++; if (dd > 0.2) ringFar++; }          // the border band: a flat colour = a normal icon, anything else = a picture / gradient icon
    }
    double Llo = 0, Lhi = 1; { long a5 = 0; for (int i = 0; i < 64; i++) { a5 += hist[i]; if (a5 >= cnt * 0.05) { Llo = i / 64.0; break; } } a5 = 0; for (int i = 63; i >= 0; i--) { a5 += hist[i]; if (a5 >= cnt * 0.05) { Lhi = (i + 1) / 64.0; break; } } if (Lhi - Llo < 0.2) Lhi = Llo + 0.2; }
    BOOL pic = !glassSrc && ringN > 0 && (double)ringFar / ringN > 0.30;
    BOOL art = (style == 2 || style == 3) && pic;
    BOOL artD = style == 1 && pic;
    float *m = NULL, *tm = NULL, *shd = NULL, *Lnb = NULL, *GC = NULL;
    if (style >= 1 && style <= 3) {
        m = malloc(N * sizeof(float)); tm = malloc(N * sizeof(float)); Lnb = malloc(N * sizeof(float));
        if (style == 1) GC = calloc(N * 3, sizeof(float));
        for (size_t i = 0; i < N; i++) {
            uint8_t *p = buf + i * 4; double a = p[3] / 255.0;
            if (a < 0.004) { m[i] = 0; Lnb[i] = 0; continue; }
            double r = MIN(1, p[0] / 255.0 / a), g = MIN(1, p[1] / 255.0 / a), b = MIN(1, p[2] / 255.0 / a);
            double L = 0.299 * r + 0.587 * g + 0.114 * b, ln = MAX(0, MIN(1, (L - Llo) / (Lhi - Llo))); Lnb[i] = ln;
            double t = (double)(i / w) / (double)h, br = bt[0] + (bb2[0] - bt[0]) * t, bg = bt[1] + (bb2[1] - bt[1]) * t, bb = bt[2] + (bb2[2] - bt[2]) * t;
            double d = MAX(fabs(r - br), MAX(fabs(g - bg), fabs(b - bb)));
            double v = art ? (0.10 + 0.90 * H26Sm(0.50, 0.88, L)) : (glassSrc ? H26Sm(slabV + 0.12, slabV + 0.38, sig[i]) : H26Sm(0.10, 0.34, d));
            m[i] = (float)(v * H26Sm(rimLo, rimHi, dist[i]));
            if (GC) {                                        // Dark: the glyph's own colour, fringe removed, dark-on-light turned light
                double tc = MAX(0.35, H26Sm(0.10, 0.36, d));
                double gr = MAX(0, MIN(1, br + (r - br) / tc)), gg = MAX(0, MIN(1, bg + (g - bg) / tc)), gb = MAX(0, MIN(1, bb + (b - bb) / tc));
                if (lightBG && L < 0.35 && MAX(r, MAX(g, b)) - MIN(r, MIN(g, b)) < 0.3) { double vv = 0.93 - L * 0.5; gr = gg = gb = vv; }
                GC[i * 3] = (float)gr; GC[i * 3 + 1] = (float)gg; GC[i * 3 + 2] = (float)gb;
            }
        }
        H26Box(m, tm, w, h, 1);
        if (glassSrc) { for (size_t i = 0; i < N; i++) Lnb[i] = (float)MAX(0, MIN(1, (sig[i] - slabV - 0.12) / 0.5)); }
        else if (!art) {                                          // contrast of the glyph measured on the glyph itself (so a flat glyph stays bright and a shaded one keeps its shading)
            int gh[64] = {0}; long gc = 0;
            for (size_t i = 0; i < N; i++) if (m[i] > 0.5f) { uint8_t *p = buf + i * 4; double a = p[3] / 255.0; if (a < 0.5) continue; double L = (0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]) / 255.0 / a; gh[MAX(0, MIN(63, (int)(L * 64)))]++; gc++; }
            double glo = 0, ghi = 1; if (gc > 20) { long a5 = 0; for (int i = 0; i < 64; i++) { a5 += gh[i]; if (a5 >= gc * 0.04) { glo = i / 64.0; break; } } a5 = 0; for (int i = 63; i >= 0; i--) { a5 += gh[i]; if (a5 >= gc * 0.04) { ghi = (i + 1) / 64.0; break; } } }
            BOOL flat = ghi - glo < 0.18;
            for (size_t i = 0; i < N; i++) { uint8_t *p = buf + i * 4; double a = p[3] / 255.0; if (a < 0.004) { Lnb[i] = 0; continue; } double L = (0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]) / 255.0 / a; Lnb[i] = flat ? 0.85f : (float)MAX(0, MIN(1, (L - glo) / (ghi - glo))); }
        }
        if (!art && !artD && !glassSrc) {                    // iOS keeps the glyph well inside the tile: shrink glyphs that touch the edge (Facebook "f", Zalo bubble...) and centre them
            long x0 = w, x1 = -1, y0 = h, y1 = -1;
            for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) if (m[y * w + x] > 0.35f) { if ((long)x < x0) x0 = x; if ((long)x > x1) x1 = x; if ((long)y < y0) y0 = y; if ((long)y > y1) y1 = y; }
            if (x1 > x0 && y1 > y0) {
                double bw = (x1 - x0 + 1.0) / w, bh = (y1 - y0 + 1.0) / h, sc = MIN(1.0, 0.74 / MAX(bw, bh));
                double bx = (x0 + x1) / 2.0, by = (y0 + y1) / 2.0;
                if (sc < 0.98 || fabs(bx - w / 2.0) > w * 0.03 || fabs(by - h / 2.0) > h * 0.03) {
                    float *t2 = malloc(N * sizeof(float)), *t3 = malloc(N * sizeof(float));
                    H26Warp(Lnb, t2, w, h, sc, bx, by); memcpy(Lnb, t2, N * sizeof(float));
                    if (GC) for (int ch = 0; ch < 3; ch++) {
                        for (size_t i = 0; i < N; i++) t3[i] = GC[i * 3 + ch] * m[i];
                        H26Warp(t3, t2, w, h, sc, bx, by); for (size_t i = 0; i < N; i++) GC[i * 3 + ch] = t2[i];   // premultiplied, divided below
                    }
                    H26Warp(m, t3, w, h, sc, bx, by);
                    if (GC) for (size_t i = 0; i < N; i++) for (int ch = 0; ch < 3; ch++) GC[i * 3 + ch] = t3[i] > 0.002f ? fminf(1, GC[i * 3 + ch] / t3[i]) : 0;
                    memcpy(m, t3, N * sizeof(float)); free(t2); free(t3);
                }
            }
        }
        if (style >= 2) {                                // drop shadow of the glyph: the mask moved down and blurred
            shd = calloc(N, sizeof(float)); long sy = lround(h * 0.014);
            for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) { long yy = (long)y - sy; shd[y * w + x] = yy >= 0 ? m[(size_t)yy * w + x] : 0; }
            H26Box(shd, tm, w, h, 2); H26Box(shd, tm, w, h, 2);
        }
    }
    for (size_t i = 0; i < N; i++) {
        double rowF = (double)(i / w) / (double)h;       // 0 top .. 1 bottom
        uint8_t *p = buf + i * 4; double a = p[3] / 255.0;
        if (a < 0.004) { p[0] = p[1] = p[2] = p[3] = 0; continue; }
        double r = MIN(1, p[0] / 255.0 / a), g = MIN(1, p[1] / 255.0 / a), b = MIN(1, p[2] / 255.0 / a);
        double L = 0.299 * r + 0.587 * g + 0.114 * b;
        double br = bt[0] + (bb2[0] - bt[0]) * rowF, bg = bt[1] + (bb2[1] - bt[1]) * rowF, bb = bt[2] + (bb2[2] - bt[2]) * rowF;
        double d = MAX(fabs(r - br), MAX(fabs(g - bg), fabs(b - bb)));
        double or_ = r, og = g, ob = b, oa = a;
        if (style == 4) {                                   // default: keep the icon, add a glass gloss on top and a little depth below
            double gl = 0.26 * pow(MAX(0, 1 - rowF / 0.6), 1.4) * (0.6 + 0.4 * H26Sm(0, 0.5, MIN(dist[i], (float)w) / w));
            double sh = 0.10 * H26Sm(0.55, 1.0, rowF);
            or_ = r * (1 - sh) * (1 - gl) + gl; og = g * (1 - sh) * (1 - gl) + gl; ob = b * (1 - sh) * (1 - gl) + gl;
        } else if (style == 1) {                            // Dark
            double mm = artD ? 0 : m[i];
            double mx = MAX(br, MAX(bg, bb)), mn = MIN(br, MIN(bg, bb)), sb = mx > 0.001 ? (mx - mn) / mx : 0;
            double nr, ng, nb;
            if (artD) { nr = r * 0.62; ng = g * 0.62; nb = b * 0.62; }
            else if (lightBG) { nr = 0.12 * (1 - sb) + br * 0.34 * sb; ng = 0.12 * (1 - sb) + bg * 0.34 * sb; nb = 0.12 * (1 - sb) + bb * 0.34 * sb; }
            else { nr = br * 0.38; ng = bg * 0.38; nb = bb * 0.38; }
            double gr = GC[i * 3], gg = GC[i * 3 + 1], gb = GC[i * 3 + 2];
            if (artD) { gr = r; gg = g; gb = b; }
            or_ = nr + (gr - nr) * mm; og = ng + (gg - ng) * mm; ob = nb + (gb - nb) * mm;
            double gl = 0.10 * MAX(0, 1 - rowF / 0.5);
            or_ = or_ * (1 - gl) + gl; og = og * (1 - gl) + gl; ob = ob * (1 - gl) + gl;
        } else if (style == 2 || style == 3) {              // Clear / Tinted: glass slab + specular band + lit glyph with a soft shadow
            double mi = m[i], ln = Lnb[i];
            double sheen = 1.25 - 0.55 * rowF, fr, fg, fb, gr, gg, gb, fa;
            if (style == 2) { fr = fg = fb = night ? 0 : 1; fa = night ? 0.50 * (1 - rowF) + 0.38 * rowF : 0.25 * (1 - rowF) + 0.03 * rowF; gr = gg = gb = night ? 0.94 : 1; }   // iOS 26 clear: a faint white glass, top to bottom
            else if (bgMode == 0) { H26HSB(hue, sat, night ? 0.55 : 0.80, &fr, &fg, &fb); fa = (night ? 0.42 : 0.32) * sheen; H26HSB(hue, sat * 0.16, 1.0, &gr, &gg, &gb); }
            else { H26HSB(hue, sat * 0.55, 1.0, &fr, &fg, &fb); fa = (night ? 0.40 : 0.50) * sheen; H26HSB(hue, sat * 0.9, 0.40, &gr, &gg, &gb); }
            double spec = style == 2 ? 0 : 0.30 * exp(-rowF / 0.11) * H26Sm(0, rimLo * 2.5, dist[i]) * (night ? 0.5 : 1.0);
            double sa = MIN(1, fa + spec * (1 - fa));
            double sr = (fr * fa + spec * (1 - fa)) / MAX(sa, 1e-3), sg = (fg * fa + spec * (1 - fa)) / MAX(sa, 1e-3), sbb = (fb * fa + spec * (1 - fa)) / MAX(sa, 1e-3);
            double lit = 1.0 - 0.16 * rowF, gcr, gcg, gcb;
            if (art) {                                      // picture icon: keep the picture, seen through the glass
                if (style == 2) { double k = (1.0 - 0.12 * rowF) * (night ? 0.90 : 1.0), v = (0.62 + 0.38 * ln) * k; gcr = MIN(1, v * 0.97); gcg = MIN(1, v * 0.985); gcb = MIN(1, v); }   // colourless: the picture is kept only as light and shade
                else {
                    double t0r, t0g, t0b, t1r, t1g, t1b;
                    H26HSB(hue, sat, bgMode == 0 ? 0.30 : 0.28, &t0r, &t0g, &t0b); H26HSB(hue, sat * 0.40, bgMode == 0 ? 1.0 : 0.80, &t1r, &t1g, &t1b);
                    gcr = t0r * (1 - ln) + t1r * ln; gcg = t0g * (1 - ln) + t1g * ln; gcb = t0b * (1 - ln) + t1b * ln;
                }
            } else {
                double detail = (style == 2 ? 0.60 + 0.40 * ln : 0.75 + 0.25 * ln), k = lit * detail;
                gcr = MIN(1, gr * k); gcg = MIN(1, gg * k); gcb = MIN(1, gb * k);
            }
            double sh = shd[i] * ((style == 2 && !night) ? 0.40 : 0.34);
            double c1r = sr * sa, c1g = sg * sa, c1b = sbb * sa, a1 = sa;
            c1r *= (1 - sh); c1g *= (1 - sh); c1b *= (1 - sh); a1 = a1 + sh * (1 - a1);
            double ga = 0.97 * mi;
            c1r = c1r * (1 - ga) + gcr * ga; c1g = c1g * (1 - ga) + gcg * ga; c1b = c1b * (1 - ga) + gcb * ga; a1 = a1 + ga * (1 - a1);
            or_ = MIN(1, c1r / MAX(a1, 1e-3)); og = MIN(1, c1g / MAX(a1, 1e-3)); ob = MIN(1, c1b / MAX(a1, 1e-3)); oa = a * a1;
        }
        or_ = MIN(1, or_ * bri); og = MIN(1, og * bri); ob = MIN(1, ob * bri);
        p[0] = (uint8_t)(or_ * oa * 255.0 + 0.5); p[1] = (uint8_t)(og * oa * 255.0 + 0.5); p[2] = (uint8_t)(ob * oa * 255.0 + 0.5); p[3] = (uint8_t)(oa * 255.0 + 0.5);
    }
    free(dist); free(m); free(tm); free(shd); free(Lnb); free(GC); free(sig);
    CGImageRef out = CGBitmapContextCreateImage(c);
    CGContextRelease(c); CGColorSpaceRelease(cs); free(buf);
    UIImage *ui = out ? [UIImage imageWithCGImage:out scale:src.scale orientation:UIImageOrientationUp] : src;
    if (out) CGImageRelease(out);
    return ui;
}

// ---- applying to the real icons ----
static UIView *H26ImgView(UIView *iv) {
    id v = nil;
    @try { v = [iv valueForKey:@"_iconImageView"]; } @catch (NSException *e) {}
    if ([v isKindOfClass:[UIView class]]) return v;
    for (UIView *s in iv.subviews) if ([NSStringFromClass([s class]) containsString:@"IconImageView"]) return s;
    return nil;
}
static UIImage *H26Render(UIView *img) {
    CGSize s = img.bounds.size; if (s.width < 20 || s.height < 20) return nil;
    UIGraphicsBeginImageContextWithOptions(s, NO, [UIScreen mainScreen].scale);
    [img.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *o = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return o;
}
static void H26Labels(UIView *iv) {
    for (UIView *s in iv.subviews) {
        NSString *cn = NSStringFromClass([s class]);
        if (![cn containsString:@"Label"] || [cn containsString:@"Badge"]) continue;
        if (gH26Labels && gH26Enabled) { s.alpha = 0; objc_setAssociatedObject(s, kH26Lbl, @1, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        else if (objc_getAssociatedObject(s, kH26Lbl)) { s.alpha = 1; objc_setAssociatedObject(s, kH26Lbl, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    }
}
static BOOL H26Editing(void) {
    id ctrl = W12Call(NSClassFromString(@"SBIconController"), @selector(sharedInstance));
    return ctrl && [ctrl respondsToSelector:@selector(isEditing)] && ((BOOL (*)(id, SEL))objc_msgSend)(ctrl, @selector(isEditing));
}
// Edit mode: the iOS 12 "x" becomes the grey "-" of newer iOS (best effort, the class layout differs between versions).
static void H26CloseBox(UIView *iv) {
    id cb = nil;
    for (NSString *k in @[@"_closeBox", @"closeBox", @"_closeBoxView"]) { @try { cb = [iv valueForKey:k]; } @catch (NSException *e) { cb = nil; } if (cb) break; }
    if (![cb isKindOfClass:[UIView class]]) return;
    UIView *c = cb;
    BOOL on = gH26Enabled && W12Bool(@"home26Edit", YES);
    CAShapeLayer *old = nil; for (CALayer *l in c.layer.sublayers) if ([l.name isEqualToString:@"w12.minus"]) old = (CAShapeLayer *)l;
    if (!on) { [old removeFromSuperlayer]; return; }
    if (old) return;
    if ([c isKindOfClass:[UIButton class]]) { UIButton *b = (UIButton *)c; [b setImage:nil forState:UIControlStateNormal]; [b setImage:nil forState:UIControlStateHighlighted]; [b setBackgroundImage:nil forState:UIControlStateNormal]; }
    for (UIView *s in c.subviews) s.hidden = YES;
    CGFloat d = MIN(24, MIN(c.bounds.size.width, c.bounds.size.height) - 2); if (d < 12) d = 22;
    CAShapeLayer *circle = [CAShapeLayer layer]; circle.name = @"w12.minus";
    CGRect r = CGRectMake((c.bounds.size.width - d) / 2, (c.bounds.size.height - d) / 2, d, d);
    circle.path = [UIBezierPath bezierPathWithOvalInRect:r].CGPath;
    circle.fillColor = [UIColor colorWithWhite:0.30 alpha:0.96].CGColor; circle.strokeColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor; circle.lineWidth = 0.8;
    CAShapeLayer *bar = [CAShapeLayer layer];
    UIBezierPath *bp = [UIBezierPath bezierPath]; [bp moveToPoint:CGPointMake(CGRectGetMidX(r) - d * 0.22, CGRectGetMidY(r))]; [bp addLineToPoint:CGPointMake(CGRectGetMidX(r) + d * 0.22, CGRectGetMidY(r))];
    bar.path = bp.CGPath; bar.strokeColor = [UIColor whiteColor].CGColor; bar.lineWidth = 2.4; bar.lineCap = kCALineCapRound; bar.fillColor = nil;
    [circle addSublayer:bar];
    [c.layer addSublayer:circle];
}

// ---- Snowboard scan + the iOS 26 icon pack (/Library/Application Support/Wave12/Icons/<style>/<bundle id lowercased>.png) ----
static BOOL H26SnowActive(void) {
    static BOOL cached = NO, logged = NO; static CFTimeInterval stamp = -100;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - stamp < 4) return cached;
    stamp = now;
    if (!W12Bool(@"h26Snow", YES)) { cached = NO; return NO; }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL dylib = NO;
    for (NSString *f in [fm contentsOfDirectoryAtPath:@"/Library/MobileSubstrate/DynamicLibraries" error:nil]) if ([f.lowercaseString containsString:@"snowboard"] && [f.pathExtension isEqualToString:@"dylib"]) { dylib = YES; break; }
    BOOL plist = NO, themes = NO;
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.spark.snowboard.plist"];
    if (d) {
        plist = YES;
        for (id k in d) { id v = d[k]; if (([v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSDictionary class]]) && [v count] && [[k description].lowercaseString containsString:@"theme"]) themes = YES; }
    }
    cached = dylib && (themes || !plist);
    if (!logged || cached != YES) { if (!logged) W12_LOG(@"26home: snowboard scan dylib=%d plist=%d themes=%d -> %@", dylib, plist, themes, cached ? @"ACTIVE (26Home uses the icon pack only)" : @"not active"); logged = YES; }
    return cached;
}
static UIImage *H26Pack(NSString *bid, int style) {      // style 0 default, 1 dark, 2 clear dark, 3 clear light
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    static const char *dirs[4] = {"default", "dark", "cleardark", "clearlight"};
    NSString *key = [NSString stringWithFormat:@"%d|%d|%@", gH26Ver, style, bid.lowercaseString];
    id c = cache[key]; if (c) return c == (id)[NSNull null] ? nil : c;
    UIImage *im = nil;
    if (gH26Ver == 1) im = [UIImage imageWithContentsOfFile:[NSString stringWithFormat:@"/Library/Application Support/Wave12/Icons27/%s/%@.png", dirs[style], bid.lowercaseString]];
    if (!im) im = [UIImage imageWithContentsOfFile:[NSString stringWithFormat:@"/Library/Application Support/Wave12/Icons/%s/%@.png", dirs[style], bid.lowercaseString]];
    if (im) im = [UIImage imageWithCGImage:im.CGImage scale:3 orientation:UIImageOrientationUp];
    cache[key] = im ?: (id)[NSNull null];
    return im;
}
static BOOL H26PackHeavy(UIImage *im, NSString *bid) {      // a clear icon whose slab is far more solid than the others (Tips, Compass...) or that is known to look milky (Find My)
    static NSMutableDictionary *cache; if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *k = bid.lowercaseString; NSNumber *c = cache[k]; if (c) return c.boolValue;
    BOOL heavy = [k isEqualToString:@"com.apple.findmy"] || [k isEqualToString:@"com.apple.mobileme.fmip1"];
    CGImageRef cg = im.CGImage;
    if (!heavy && cg) {
        const int S = 64; uint8_t buf[S * S * 4]; memset(buf, 0, sizeof(buf));
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(buf, S, S, 8, S * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        if (ctx) { CGContextDrawImage(ctx, CGRectMake(0, 0, S, S), cg); CGContextRelease(ctx);
            int hist[16] = {0}, n = 0; double rr = S * 0.256, hx = S / 2.0 - rr;
            for (int y = 0; y < S; y++) for (int x = 0; x < S; x++) {
                double qx = fabs(x + 0.5 - S / 2.0) - hx, qy = fabs(y + 0.5 - S / 2.0) - hx;
                double d = -(sqrt(MAX(qx, 0) * MAX(qx, 0) + MAX(qy, 0) * MAX(qy, 0)) + MIN(MAX(qx, qy), 0) - rr);
                if (d >= S * 0.06 && d < S * 0.14) { hist[MIN(15, buf[(y * S + x) * 4 + 3] / 16)]++; n++; }
            }
            int acc = 0; double med = 0; for (int i = 0; i < 16; i++) { acc += hist[i]; if (acc >= n / 2) { med = (i + 1) / 16.0; break; } }
            heavy = med > 0.30;
        }
        CGColorSpaceRelease(cs);
    }
    cache[k] = @(heavy); return heavy;
}
static UIImage *H26ClearPack(NSString *bid) { return H26Pack(bid, H26Night() ? 2 : 3); }     // ready-made clear glass icon for the current Light / Dark choice

// The original icon must never show through the (translucent) overlay: alpha AND hidden are forced, also against SpringBoard resetting them.
static const void *kH26Hid = &kH26Hid;
static void H26HideOrig(UIView *img, BOOL hide) {
    BOOL was = objc_getAssociatedObject(img, kH26Hid) != nil;
    if (!hide && !was) return;                                   // never touched: leave SpringBoard's own state alone
    objc_setAssociatedObject(img, kH26Hid, hide ? @1 : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (hide) { img.alpha = 0; img.hidden = YES; img.layer.opacity = 0; }
    else { img.alpha = 1; img.hidden = NO; img.layer.opacity = 1; }
}
static void H26HookHide(void) {
    for (NSString *cn in @[@"SBIconImageView", @"SBFolderIconImageView"]) {
        Class c = NSClassFromString(cn); if (!c) continue;
        Method m = class_getInstanceMethod(c, @selector(setAlpha:));
        if (m) { IMP o = method_getImplementation(m); class_replaceMethod(c, @selector(setAlpha:), imp_implementationWithBlock(^(UIView *self, CGFloat a) { ((void (*)(id, SEL, CGFloat))o)(self, @selector(setAlpha:), objc_getAssociatedObject(self, kH26Hid) ? 0 : a); }), method_getTypeEncoding(m)); }
        Method h = class_getInstanceMethod(c, @selector(setHidden:));
        if (h) { IMP o = method_getImplementation(h); class_replaceMethod(c, @selector(setHidden:), imp_implementationWithBlock(^(UIView *self, BOOL v) { ((void (*)(id, SEL, BOOL))o)(self, @selector(setHidden:), objc_getAssociatedObject(self, kH26Hid) ? YES : v); }), method_getTypeEncoding(h)); }
    }
}

// Folder: keep SpringBoard's own folder picture (the mini icons live inside it) and put a glass plate behind it.
static void H26FolderGlass(UIView *img, BOOL on, int eff) {
    CALayer *fl = nil; for (CALayer *l in img.layer.sublayers) if ([l.name isEqualToString:@"w12.h26f"]) { fl = l; break; }
    if (!on) { [fl removeFromSuperlayer]; return; }
    if (!fl) {
        fl = [CALayer layer]; fl.name = @"w12.h26f";
        fl.actions = @{@"backgroundColor": [NSNull null], @"bounds": [NSNull null], @"position": [NSNull null], @"cornerRadius": [NSNull null]};
        [img.layer insertSublayer:fl atIndex:0];
    }
    CGFloat w = img.bounds.size.width;
    fl.frame = img.bounds; fl.cornerRadius = w * 0.256;
    UIColor *c;
    if (eff == 1) c = [UIColor colorWithWhite:0.06 alpha:0.78];
    else if (eff == 2) c = H26Night() ? [UIColor colorWithWhite:0.1 alpha:0.36] : [UIColor colorWithWhite:0.95 alpha:0.20];
    else { double r, g, b; H26HSB(H26HueNow(), gH26BG == 0 ? gH26Sat : gH26Sat * 0.55, gH26BG == 0 ? (H26Night() ? 0.55 : 0.8) : 1.0, &r, &g, &b); c = [UIColor colorWithRed:r green:g blue:b alpha:gH26BG == 0 ? 0.40 : 0.48]; }
    fl.backgroundColor = c.CGColor;
    CALayer *rim = nil; for (CALayer *l in img.layer.sublayers) if ([l.name isEqualToString:@"w12.h26frim"]) { rim = l; break; }
    if (!rim) { rim = W12RimLayer(@"w12.h26frim"); [img.layer addSublayer:rim]; }
    W12RimSet(rim, img.bounds, w * 0.256, YES);
}
static void H26Rim(CALayer *host, CALayer *ov, BOOL on) {
    CALayer *rim = nil; for (CALayer *l in host.sublayers) if ([l.name isEqualToString:@"w12.h26rim"]) { rim = l; break; }
    if (!on) { [rim removeFromSuperlayer]; return; }
    if (!rim) { rim = W12RimLayer(@"w12.h26rim"); [host insertSublayer:rim above:ov]; }
    W12RimSet(rim, ov.frame, ov.frame.size.width * 0.256, YES);
}

// ---- the real icon: the image SpringBoard itself builds for each app is replaced (no layer on top) ----
static NSObject *gH26Lock;
static NSMutableDictionary *gH26Gen; static NSString *gH26GenKey;
static NSMutableSet *gH26Styled;                       // bundle ids whose icon image went through H26StyleImage with the current parameters
static UIImage *H26Finish(UIImage *img, CGSize size, CGFloat scale, CGFloat rimA, CGFloat smoke) {
    UIGraphicsBeginImageContextWithOptions(size, NO, scale);
    [W12SquirclePath(CGRectMake(0, 0, size.width, size.height), size.width * 0.256) addClip];     // art that bleeds past the corner (Contacts tabs...) is cut to the icon shape
    if (smoke > 0.01) {                                      // Clear Dark: a smoky dark glass under the ready-made icon
        CGContextRef gc = UIGraphicsGetCurrentContext(); CGContextSaveGState(gc);
        CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB(); CGFloat cc[8] = {0, 0, 0, smoke, 0, 0, 0, smoke * 0.78};
        CGGradientRef gr2 = CGGradientCreateWithColorComponents(cs2, cc, NULL, 2);
        CGContextDrawLinearGradient(gc, gr2, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
        CGGradientRelease(gr2); CGColorSpaceRelease(cs2); CGContextRestoreGState(gc);
    }
    [img drawInRect:CGRectMake(0, 0, size.width, size.height)];
    if (rimA <= 0.01) { UIImage *o0 = UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext(); return o0; }
    CGFloat r = size.width * 0.256; UIImage *ri = W12RimImageL(r, size.width / 2, NO, NO); CGFloat S = ri.size.width;
    UIImage *rz = [ri resizableImageWithCapInsets:UIEdgeInsetsMake(S / 2 - 0.5, S / 2 - 0.5, S / 2 - 0.5, S / 2 - 0.5) resizingMode:UIImageResizingModeStretch];
    [rz drawInRect:CGRectMake(0, 0, size.width, size.height) blendMode:kCGBlendModeNormal alpha:rimA];   // faint glass rim baked into the icon (the pack icons already have their own edge)
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out;
}
static UIImage *H26StyleImage(NSString *bid, UIImage *orig) {
    if (!gH26Loaded || !gH26Enabled || !bid.length || !orig.CGImage) return nil;
    if (W12Excluded(bid) || [bid isEqualToString:@"com.apple.mobilecal"] || [bid isEqualToString:@"com.apple.mobiletimer"]) return nil;
    CGFloat wpt = orig.size.width; if (wpt < 20 || wpt > 140) return nil;
    int eff = H26Eff();
    UIImage *pack = nil, *packSrc = nil;
    BOOL glass = NO;
    if (eff == 1) pack = H26Pack(bid, 1);
    else if (eff == 0) pack = H26Pack(bid, 0);
    else if (eff == 2) { pack = H26ClearPack(bid); if (pack && H26PackHeavy(pack, bid)) { packSrc = pack; glass = YES; pack = nil; } }   // Clear: the ready-made glass icon is final, unless its slab is too solid: then it is redrawn as normal glass
    if (eff == 3) { packSrc = H26ClearPack(bid); glass = packSrc != nil; if (!packSrc) packSrc = H26Pack(bid, 0); }   // Tinted: recolour the glass icon
    if (eff == 2 && !pack && !packSrc) packSrc = H26Pack(bid, 0);                 // no glass icon: generate one from the normal icon
    if (eff == 1 && !pack) packSrc = H26Pack(bid, 0);
    @synchronized (gH26Lock) {
        NSString *pk = H26ParamKey();
        if (!gH26Gen || ![pk isEqualToString:gH26GenKey]) { gH26GenKey = pk; gH26Gen = [NSMutableDictionary dictionary]; gH26Styled = [NSMutableSet set]; }
        if (!gH26Styled) gH26Styled = [NSMutableSet set];
        [gH26Styled addObject:bid];
        NSString *ck = [NSString stringWithFormat:@"%@|%.0f|%.1f", bid, wpt, orig.scale];
        UIImage *c = gH26Gen[ck]; if (c) return c;
        UIImage *base;
        if (pack) base = (fabs(gH26Bri - 1) < 0.01) ? pack : H26Process(pack, 0, 0, 0, gH26Bri, NO, 0, NO);
        else base = H26Process(packSrc ?: orig, eff == 0 ? 4 : eff, H26HueNow(), gH26Sat, gH26Bri, H26Night(), gH26BG, glass);
        UIImage *fin = H26Finish(base, orig.size, orig.scale, pack ? 0 : (eff >= 2 ? 0.95 : 0.5), (eff == 2 && pack && H26Night()) ? 0.50 : 0);
        if (fin) gH26Gen[ck] = fin;
        W12_LOG(@"26home: styled %@ eff=%d pack=%d src=%d size=%.0f", bid, eff, pack != nil, packSrc != nil, wpt);
        return fin;
    }
}
static void H26HookGenerate(void) {
    if (!gH26Lock) gH26Lock = [NSObject new];
    SEL sel = NSSelectorFromString(@"generateIconImage:");
    int hooked = 0;
    for (NSString *cn in @[@"SBIcon", @"SBLeafIcon", @"SBApplicationIcon"]) {
        Class c = NSClassFromString(cn); if (!c) continue;
        unsigned n = 0; Method *ms = class_copyMethodList(c, &n); Method m = NULL;
        for (unsigned i = 0; i < n; i++) if (method_getName(ms[i]) == sel) m = ms[i];
        free(ms);
        if (!m) continue;                                   // inherited: the parent's hook already covers it
        IMP o = method_getImplementation(m);
        class_replaceMethod(c, sel, imp_implementationWithBlock(^id(id self, int fmt) {
            UIImage *im = ((id (*)(id, SEL, int))o)(self, sel, fmt);
            @try {
                if (![im isKindOfClass:[UIImage class]]) return im;
                id b = W12Call(self, NSSelectorFromString(@"applicationBundleID"));
                if (![b isKindOfClass:[NSString class]]) return im;
                UIImage *st = H26StyleImage(b, im);
                return st ?: im;
            } @catch (NSException *e) { return im; }
        }), method_getTypeEncoding(m));
        hooked++; W12_LOG(@"26home: hooked %@ generateIconImage:", cn);
    }
    if (!hooked) W12_LOG(@"26home: NO generateIconImage: found, icons cannot be replaced");
}
static void H26Collect(UIView *v, Class c, NSMutableArray *out, int d);
static void H26ReloadIcons(void) {
    NSMutableSet *icons = [NSMutableSet set];
    Class c = NSClassFromString(@"SBIconView");
    NSMutableArray *views = [NSMutableArray array];
    if (c) for (UIWindow *w in [UIApplication sharedApplication].windows) { NSString *cn = NSStringFromClass([w class]); if ([cn containsString:@"Island"] || [cn hasPrefix:@"H26"]) continue; H26Collect(w, c, views, 0); }
    for (UIView *v in views) { id ic = W12Call(v, @selector(icon)); if (ic) [icons addObject:ic]; }
    id ctrl = W12Call(NSClassFromString(@"SBIconController"), @selector(sharedInstance));
    id model = W12Call(ctrl, @selector(model));
    id leaf = W12Call(model, NSSelectorFromString(@"leafIcons"));
    if ([leaf isKindOfClass:[NSSet class]]) [icons unionSet:leaf]; else if ([leaf isKindOfClass:[NSArray class]]) [icons addObjectsFromArray:leaf];
    SEL rs = NSSelectorFromString(@"reloadIconImagePurgingImageCache:");
    int n = 0;
    for (id ic in icons) { if ([ic respondsToSelector:rs]) { ((void (*)(id, SEL, BOOL))objc_msgSend)(ic, rs, YES); n++; } }
    W12_LOG(@"26home: reload %d of %lu icons", n, (unsigned long)icons.count);
}
static BOOL gH26RelPending; static NSString *gH26RelKey;
static NSString *H26RelKeyNow(void) { return [H26ParamKey() stringByAppendingFormat:@"|%d", gH26Enabled]; }
static void H26ScheduleReload(void) {
    if ([H26RelKeyNow() isEqualToString:gH26RelKey] || gH26RelPending) return;
    gH26RelPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gH26RelPending = NO; gH26RelKey = H26RelKeyNow(); H26ReloadIcons();
    });
}

// ---- Clock: the system's own icon is kept (live hands, seconds) and only its dial picture (ClockIconBackgroundSquare) is replaced ----
static UIImage *H26ClockFace(void) {
    if (!gH26Loaded || !gH26Enabled) return nil;
    static NSString *kBid = @"ClockIconBackgroundSquare";
    int eff = H26Eff();
    UIImage *base = H26Pack(kBid, 0); if (!base) return nil;
    UIImage *face = nil;
    if (eff == 1) face = H26Pack(kBid, 1);
    else if (eff == 2) face = H26ClearPack(kBid);
    else if (eff == 3) face = H26StyleImage(kBid, base);
    else face = base;
    if (eff == 0 && fabs(gH26Bri - 1) > 0.01) face = H26StyleImage(kBid, base) ?: base;
    return face ?: base;
}
static BOOL H26IsFace(CGImageRef cg, CGSize ptSize) {
    if (!cg) return NO;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    return w >= 100 && w == h && ptSize.width >= 50 && ptSize.width <= 80;
}
static void H26ClockSwapIn(UIView *v, UIImage *face, int d, int *n) {
    if (d > 4) return;
    if ([v isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)v;
        if (iv.image && H26IsFace(iv.image.CGImage, iv.bounds.size) && iv.image.CGImage != face.CGImage) { iv.image = face; (*n)++; }
    }
    NSMutableArray *ls = [NSMutableArray arrayWithObject:v.layer];
    for (int i = 0; i < (int)ls.count && i < 40; i++) {
        CALayer *l = ls[i]; [ls addObjectsFromArray:l.sublayers ?: @[]];
        id c = l.contents;
        if (c && CFGetTypeID((__bridge CFTypeRef)c) == CGImageGetTypeID() && H26IsFace((__bridge CGImageRef)c, l.bounds.size) && (__bridge CGImageRef)c != face.CGImage && ![l.name hasPrefix:@"w12"]) { l.contents = (__bridge id)face.CGImage; (*n)++; }
    }
    for (UIView *s in v.subviews) H26ClockSwapIn(s, face, d + 1, n);
}
static void H26ClockApply(UIView *img) {
    UIImage *face = H26ClockFace(); if (!face.CGImage) return;
    int n = 0; H26ClockSwapIn(img, face, 0, &n);
    static int logged; if (n && logged++ < 3) W12_LOG(@"26home: clock dial replaced (%d layers) in %@", n, NSStringFromClass([img class]));
    else if (!n && logged < 3) { static BOOL dumped; if (!dumped) { dumped = YES; NSMutableString *d = [NSMutableString string]; for (CALayer *l in img.layer.sublayers) [d appendFormat:@"%@(%@ %.0fx%.0f) ", NSStringFromClass([l class]), l.contents ? @"img" : @"-", l.bounds.size.width, l.bounds.size.height]; W12_LOG(@"26home: clock icon %@ layers: %@", NSStringFromClass([img class]), d); } }
}
static UIImage *(*o_imgNamedBundle)(id, SEL, NSString *, NSBundle *, id);
static UIImage *n_imgNamedBundle(id self, SEL _cmd, NSString *name, NSBundle *b, id tc) {
    if ([name hasPrefix:@"ClockIconBackgroundSquare"]) { UIImage *f = H26ClockFace(); if (f) return f; }
    return o_imgNamedBundle(self, _cmd, name, b, tc);
}
static UIImage *(*o_imgNamed)(id, SEL, NSString *);
static UIImage *n_imgNamed(id self, SEL _cmd, NSString *name) {
    if ([name hasPrefix:@"ClockIconBackgroundSquare"]) { UIImage *f = H26ClockFace(); if (f) return f; }
    return o_imgNamed(self, _cmd, name);
}
static void H26HookClock(void) {
    Class mc = object_getClass([UIImage class]);
    Method m1 = class_getInstanceMethod(mc, @selector(imageNamed:inBundle:compatibleWithTraitCollection:));
    if (m1) { o_imgNamedBundle = (void *)method_getImplementation(m1); class_replaceMethod(mc, @selector(imageNamed:inBundle:compatibleWithTraitCollection:), (IMP)n_imgNamedBundle, method_getTypeEncoding(m1)); }
    Method m2 = class_getInstanceMethod(mc, @selector(imageNamed:));
    if (m2) { o_imgNamed = (void *)method_getImplementation(m2); class_replaceMethod(mc, @selector(imageNamed:), (IMP)n_imgNamed, method_getTypeEncoding(m2)); }
    Class cc = NSClassFromString(@"SBClockApplicationIconImageView");
    if (cc) {
        for (NSString *sn in @[@"layoutSubviews", @"didMoveToWindow"]) {
            SEL sel = NSSelectorFromString(sn); Method m = class_getInstanceMethod(cc, sel); if (!m) continue;
            IMP orig = method_getImplementation(m);
            class_replaceMethod(cc, sel, imp_implementationWithBlock(^(UIView *self) { ((void (*)(id, SEL))orig)(self, sel); @try { H26ClockApply(self); } @catch (NSException *e) {} }), method_getTypeEncoding(m));
        }
    }
    W12_LOG(@"26home: clock hooks bundle=%d named=%d class=%d", m1 != NULL, m2 != NULL, cc != nil);
}

static void H26Apply(UIView *iv) {
    if (!gH26Loaded || !iv.superview) return;
    if (!gH26Orig) { gH26Orig = [NSMutableDictionary dictionary]; gH26Proc = [NSMutableDictionary dictionary]; }
    UIView *img = H26ImgView(iv); if (!img) return;
    H26Labels(iv);
    if (H26Editing()) H26CloseBox(iv); else if (gH26Enabled) { /* keep the layer; hidden by SpringBoard with the box */ }
    id icon = W12Call(iv, @selector(icon));
    id b = W12Call(icon, NSSelectorFromString(@"applicationBundleID"));
    NSString *bid = [b isKindOfClass:[NSString class]] ? b : nil;
    BOOL folder = !bid.length && icon && [NSStringFromClass([icon class]) containsString:@"Folder"];
    NSString *key = bid.length ? bid : (folder ? [NSString stringWithFormat:@"folder:%p", icon] : nil);
    BOOL dyn = folder || [bid isEqualToString:@"com.apple.mobilecal"];   // content changes: re-read every few seconds
    CALayer *host = img.layer.superlayer ?: iv.layer;
    CALayer *ov = nil; for (CALayer *l in host.sublayers) if ([l.name isEqualToString:@"w12.h26"]) { ov = l; break; }
    if ([bid isEqualToString:@"com.apple.mobiletimer"]) {          // Clock: no overlay, the system icon itself gets the new dial
        if (ov) { H26Rim(host, ov, NO); [ov removeFromSuperlayer]; }
        H26HideOrig(img, NO);
        if (gH26Enabled) H26ClockApply(img);
        return;
    }
    int eff = H26Eff();
    if (folder) {
        BOOL on = gH26Enabled && (eff != 0);
        H26FolderGlass(img, on, eff);
        if (ov) { [ov removeFromSuperlayer]; H26Rim(host, ov, NO); }
        H26HideOrig(img, NO);
        return;
    }
    if (!dyn) {                                                   // normal apps: their own icon image was replaced (see H26StyleImage); drop any leftover layer
        if (gH26Enabled && bid.length && !W12Excluded(bid)) {        // an icon built before the hook (or by a path it missed) is asked to rebuild itself, at most every 4 s
            BOOL done; @synchronized (gH26Lock) { done = [gH26Styled containsObject:bid]; }
            static NSMutableDictionary *tries; if (!tries) tries = [NSMutableDictionary dictionary];
            double now = CACurrentMediaTime(); SEL rs = NSSelectorFromString(@"reloadIconImagePurgingImageCache:");
            if (!done && now - [tries[bid] doubleValue] > 4.0 && [icon respondsToSelector:rs]) { tries[bid] = @(now); ((void (*)(id, SEL, BOOL))objc_msgSend)(icon, rs, YES); }
        }
        if (ov) { H26Rim(host, ov, NO); [ov removeFromSuperlayer]; H26HideOrig(img, NO); }
        return;
    }
    BOOL snow = H26SnowActive();
    UIImage *pack = nil; int packStyle = 0;                       // finished icon from the pack
    UIImage *packSrc = nil;                                       // pack icon used as the source for Tinted
    if (bid.length) {
        if (eff == 1) pack = H26Pack(bid, 1);
        else if (eff == 0) pack = H26Pack(bid, 0);                       // Solid Glass icons are the default look
        if (eff == 2 || eff == 3) packSrc = H26Pack(bid, 0);
        if (eff == 1 && !pack) packSrc = H26Pack(bid, 0);                 // no dark icon for this app: darken the light one
        (void)packStyle;
    }
    if (dyn) { packSrc = nil; pack = nil; }          // live icons (calendar, clock, folders): style what is on screen right now
    BOOL pass = !gH26Enabled || !key.length || (bid.length && W12Excluded(bid))
                || (eff == 0 && !pack && fabs(gH26Bri - 1) < 0.01);
    if (pass) { if (ov) { H26Rim(host, ov, NO); [ov removeFromSuperlayer]; } H26HideOrig(img, NO); return; }
    NSString *pk = H26ParamKey();
    if (![pk isEqualToString:gH26ProcKey]) { gH26ProcKey = pk; [gH26Proc removeAllObjects]; }
    if (dyn) {
        static NSMutableDictionary *dynT; if (!dynT) dynT = [NSMutableDictionary dictionary];
        double now = CACurrentMediaTime();
        if (now - [dynT[key] doubleValue] > 3.5) { dynT[key] = @(now); [gH26Orig removeObjectForKey:key]; [gH26Proc removeObjectForKey:key]; }
    }
    UIImage *orig = packSrc ?: pack ?: gH26Orig[key];
    if (!orig) {
        BOOL hid = ov.hidden; H26HideOrig(img, NO); ov.hidden = YES;
        orig = H26Render(img);
        ov.hidden = hid;
        if (orig) gH26Orig[key] = orig;
    }
    if (!orig) return;
    UIImage *pr = gH26Proc[key];
    if (!pr) {
        if (pack) pr = (fabs(gH26Bri - 1) < 0.01) ? pack : H26Process(pack, 0, 0, 0, gH26Bri, NO, 0, NO);      // the pack icon is final; only brightness applies
        else pr = H26Process(orig, eff, H26HueNow(), gH26Sat, gH26Bri, H26Night(), gH26BG, NO);
        gH26Proc[key] = pr;
    }
    if (!ov) {
        ov = [CALayer layer]; ov.name = @"w12.h26"; ov.contentsScale = [UIScreen mainScreen].scale;
        ov.actions = @{@"contents": [NSNull null], @"bounds": [NSNull null], @"position": [NSNull null], @"cornerRadius": [NSNull null], @"borderWidth": [NSNull null], @"hidden": [NSNull null]};
        [host insertSublayer:ov above:img.layer];
    }
    ov.frame = img.frame;
    if (ov.contents != (id)pr.CGImage) ov.contents = (id)pr.CGImage;
    ov.cornerRadius = img.frame.size.width * 0.256;
    ov.borderWidth = 0;
    H26Rim(host, ov, YES);                                          // glass edge (specular rim) like the iOS 26/27 icons
    H26HideOrig(img, YES);
}

static void H26Collect(UIView *v, Class c, NSMutableArray *out, int d) {
    if (d > 18) return;
    for (UIView *s in v.subviews) { if ([s isKindOfClass:c]) { [out addObject:s]; continue; } H26Collect(s, c, out, d + 1); }
}
static void H26RefreshAll(void) {
    Class c = NSClassFromString(@"SBIconView"); if (!c) return;
    NSMutableArray *a = [NSMutableArray array];
    for (UIWindow *w in [UIApplication sharedApplication].windows) { NSString *cn = NSStringFromClass([w class]); if ([cn containsString:@"Island"] || [cn hasPrefix:@"H26"]) continue; H26Collect(w, c, a, 0); }
    for (UIView *v in a) H26Apply(v);
    H26ScheduleReload();
}
static void H26HookIcons(void) {
    Class c = NSClassFromString(@"SBIconView"); if (!c) { W12_LOG(@"26home: no SBIconView"); return; }
    Method m = class_getInstanceMethod(c, @selector(layoutSubviews)); if (!m) return;
    IMP orig = method_getImplementation(m);
    class_replaceMethod(c, @selector(layoutSubviews), imp_implementationWithBlock(^(UIView *self) {
        ((void (*)(id, SEL))orig)(self, @selector(layoutSubviews));
        @try { H26Apply(self); } @catch (NSException *e) {}
    }), method_getTypeEncoding(m));
    W12_LOG(@"26home: hooked SBIconView layoutSubviews");
}

// ---- UI pieces ----
@interface H26Glass : UIVisualEffectView
@property (nonatomic) CGFloat radius;
@end
@implementation H26Glass
- (void)layoutSubviews {
    [super layoutSubviews];
    CALayer *rim = nil; for (CALayer *l in self.layer.sublayers) if ([l.name isEqualToString:@"w12.rim"]) rim = l;
    if (!rim) { rim = W12RimLayer(@"w12.rim"); [self.layer addSublayer:rim]; }
    self.layer.cornerRadius = self.radius; W12RimSet(rim, self.bounds, self.radius, NO);
}
@end
static H26Glass *H26MakeGlass(CGRect f, CGFloat r, UIBlurEffectStyle st) {
    H26Glass *v = [[H26Glass alloc] initWithEffect:[UIBlurEffect effectWithStyle:st]];
    v.frame = f; v.radius = r; v.clipsToBounds = YES; v.layer.cornerRadius = r;
    return v;
}

@interface H26Slider : UIView
@property (nonatomic) double value;
@property (nonatomic, copy) void (^onChange)(double v, BOOL end);
@property (nonatomic, strong) CAGradientLayer *track;
@property (nonatomic, strong) UIView *thumb, *thumbFill;
- (void)setTrackColors:(NSArray *)cols;
@end
@implementation H26Slider
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        _track = [CAGradientLayer layer]; _track.startPoint = CGPointMake(0, 0.5); _track.endPoint = CGPointMake(1, 0.5); [self.layer addSublayer:_track];
        _thumb = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 38, 38)]; _thumb.layer.cornerRadius = 19; _thumb.backgroundColor = [UIColor whiteColor];
        _thumb.layer.shadowColor = [UIColor blackColor].CGColor; _thumb.layer.shadowOpacity = 0.3; _thumb.layer.shadowRadius = 3; _thumb.layer.shadowOffset = CGSizeMake(0, 1);
        _thumbFill = [[UIView alloc] initWithFrame:CGRectInset(_thumb.bounds, 4, 4)]; _thumbFill.layer.cornerRadius = 15; [_thumb addSubview:_thumbFill];
        [self addSubview:_thumb];
    }
    return self;
}
- (void)setTrackColors:(NSArray *)cols { [CATransaction begin]; [CATransaction setDisableActions:YES]; _track.colors = cols; [CATransaction commit]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    CGFloat h = self.bounds.size.height - 6; _track.frame = CGRectMake(0, 3, self.bounds.size.width, h); _track.cornerRadius = h / 2;
    [CATransaction commit];
    [self place];
}
- (void)place { CGFloat w = self.bounds.size.width - 38; _thumb.center = CGPointMake(19 + w * _value, self.bounds.size.height / 2); }
- (void)setValue:(double)v { _value = MAX(0, MIN(1, v)); [self place]; }
- (void)move:(UITouch *)t end:(BOOL)end {
    CGFloat w = self.bounds.size.width - 38; CGFloat x = [t locationInView:self].x - 19;
    _value = MAX(0, MIN(1, w > 0 ? x / w : 0)); [self place];
    if (self.onChange) self.onChange(_value, end);
}
- (void)touchesBegan:(NSSet *)ts withEvent:(UIEvent *)e { [self move:ts.anyObject end:NO]; }
- (void)touchesMoved:(NSSet *)ts withEvent:(UIEvent *)e { [self move:ts.anyObject end:NO]; }
- (void)touchesEnded:(NSSet *)ts withEvent:(UIEvent *)e { [self move:ts.anyObject end:YES]; }
- (void)touchesCancelled:(NSSet *)ts withEvent:(UIEvent *)e { [self move:ts.anyObject end:YES]; }
@end

@interface H26Window : UIWindow
@property (nonatomic, weak) UIView *bar;
@property (nonatomic) BOOL modal;
@end
@implementation H26Window
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e {
    if (self.modal) return YES;
    UIView *b = self.bar;
    if (b && !b.hidden && b.alpha > 0.05) { CGPoint q = [self convertPoint:p toView:b]; for (UIView *s in b.subviews) if (CGRectContainsPoint(CGRectInset(s.frame, -8, -8), q)) return YES; }
    return NO;
}
@end

static UIImage *H26SunGlyph(UIColor *c, CGFloat s) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(s, s), NO, 0);
    CGContextRef g = UIGraphicsGetCurrentContext(); CGContextSetStrokeColorWithColor(g, c.CGColor); CGContextSetFillColorWithColor(g, c.CGColor);
    CGPoint m = CGPointMake(s / 2, s / 2);
    CGContextFillEllipseInRect(g, CGRectMake(m.x - s * 0.17, m.y - s * 0.17, s * 0.34, s * 0.34));
    CGContextSetLineWidth(g, 1.8); CGContextSetLineCap(g, kCGLineCapRound);
    for (int i = 0; i < 8; i++) { double a = i * M_PI / 4; CGContextMoveToPoint(g, m.x + cos(a) * s * 0.30, m.y + sin(a) * s * 0.30); CGContextAddLineToPoint(g, m.x + cos(a) * s * 0.45, m.y + sin(a) * s * 0.45); }
    CGContextStrokePath(g);
    UIImage *o = UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext(); return o;
}

@interface H26UI : NSObject
@property (nonatomic, strong) H26Window *win;
@property (nonatomic, strong) UIView *bar, *catcher, *menu;
@property (nonatomic, strong) H26Glass *panel;
@property (nonatomic) BOOL editShown, panelUp, menuUp, lastEnabled;
@property (nonatomic, strong) NSMutableArray *tileImgs, *tileLabels, *tileBgs, *modeLabels, *colBtns;
@property (nonatomic, strong) UIView *sunBtn, *togBtn, *modeSel, *modeRow, *colRow;
@property (nonatomic, strong) H26Slider *hueS, *satS;
@property (nonatomic, strong) UIImage *weather;
@property (nonatomic, strong) W12FixedLabel *toast;
- (void)start;
@end

@implementation H26UI
- (CGFloat)SW { return [UIScreen mainScreen].bounds.size.width; }
- (CGFloat)SH { return [UIScreen mainScreen].bounds.size.height; }

- (void)ensureWindow {
    if (self.win) return;
    CGRect b = [UIScreen mainScreen].bounds;
    H26Window *w = [[H26Window alloc] initWithFrame:b]; w.windowLevel = 99990; w.backgroundColor = [UIColor clearColor];
    UIViewController *vc = [UIViewController new]; vc.view.backgroundColor = [UIColor clearColor]; w.rootViewController = vc;
    UIView *cat = [[UIView alloc] initWithFrame:b]; cat.backgroundColor = [UIColor clearColor]; cat.hidden = YES;
    [cat addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(catchTap)]];
    [vc.view addSubview:cat]; self.catcher = cat;
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, 50)]; bar.alpha = 0; bar.hidden = YES;
    [vc.view addSubview:bar]; self.bar = bar; w.bar = bar;
    NSArray *names = @[@"Edit", @"Done"];
    for (int i = 0; i < 2; i++) {
        CGFloat bw = i == 0 ? 64 : 70, x = i == 0 ? 10 : b.size.width - 10 - bw;
        H26Glass *g = H26MakeGlass(CGRectMake(x, 8, bw, 34), 17, UIBlurEffectStyleDark); [bar addSubview:g];
        W12FixedLabel *l = [[W12FixedLabel alloc] initWithFrame:g.bounds]; [l lockFont:[UIFont systemFontOfSize:16 weight:i == 1 ? UIFontWeightSemibold : UIFontWeightMedium]]; l.textColor = [UIColor whiteColor]; l.textAlignment = NSTextAlignmentCenter; l.text = names[i];
        [g.contentView addSubview:l];
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom]; btn.frame = g.frame; [btn addTarget:self action:(i == 0 ? @selector(editTap) : @selector(doneTap)) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:btn];
    }
    self.win = w; w.hidden = NO;
}

- (void)start {
    H26Load(); gH26Enabled = W12Bool(@"home26", YES); self.lastEnabled = gH26Enabled;
    H26HookGenerate(); H26HookIcons(); H26HookHide(); H26HookClock();
    for (NSNumber *dly in @[@1.0, @3.0, @8.0]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([dly doubleValue] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ gH26RelKey = nil; H26ScheduleReload(); });   // icons built before the hook existed are rebuilt
    if (gH26Src == 1) H26WallUpdate(YES);
    NSTimer *t = [NSTimer timerWithTimeInterval:0.3 target:self selector:@selector(poll) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    H26RefreshAll();
    W12_LOG(@"26home: started (style %d)", gH26Style);
}

- (void)poll {
    BOOL en = W12Bool(@"home26", YES);
    if (en != gH26Enabled) { gH26Enabled = en; H26RefreshAll(); }
    CGSize ss = [UIScreen mainScreen].bounds.size;
    BOOL ed = en && W12Bool(@"home26Edit", YES) && H26Editing() && !W12FrontApp() && ss.width < ss.height;
    if (ed && !self.editShown) {
        [self ensureWindow]; self.editShown = YES; self.bar.hidden = NO; self.win.hidden = NO;
        [UIView animateWithDuration:0.25 animations:^{ self.bar.alpha = 1; }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ H26RefreshAll(); });
    } else if (!ed && self.editShown) {
        self.editShown = NO; [self closeMenu];
        [UIView animateWithDuration:0.2 animations:^{ self.bar.alpha = 0; } completion:^(BOOL f) { if (!self.editShown) self.bar.hidden = YES; }];
        H26RefreshAll();
    }
    if (self.panelUp && (W12FrontApp() || ss.width > ss.height)) [self closePanel];
    { static int tick = 0; if (en && gH26Src == 1 && (tick++ % 8) == 0 && H26WallUpdate(NO)) { H26Save(); if (self.panel) [self refreshTint]; [self refreshPreviews]; H26RefreshAll(); } }
    { static CFTimeInterval lastLive = 0; CFTimeInterval now = CACurrentMediaTime();
      if (en && now - lastLive > 3.6 && ss.width < ss.height && !W12FrontApp() && (H26Eff() != 0 || fabs(gH26Bri - 1) > 0.01)) { lastLive = now; H26RefreshAll(); } }
}

- (void)exitEditing {
    id ctrl = W12Call(NSClassFromString(@"SBIconController"), @selector(sharedInstance));
    SEL s = NSSelectorFromString(@"setIsEditing:");
    if (ctrl && [ctrl respondsToSelector:s]) { ((void (*)(id, SEL, BOOL))objc_msgSend)(ctrl, s, NO); return; }
    id ui = W12Call(NSClassFromString(@"SBUIController"), @selector(sharedInstance));
    SEL m = NSSelectorFromString(@"clickedMenuButton");
    if ([ui respondsToSelector:m]) ((void (*)(id, SEL))objc_msgSend)(ui, m);
}
- (void)doneTap { [self closeMenu]; [self exitEditing]; }
- (void)catchTap { if (self.panelUp) [self closePanel]; else [self closeMenu]; }
- (void)updateModal { self.win.modal = self.panelUp || self.menuUp; self.catcher.hidden = !(self.panelUp || self.menuUp); }

- (void)showToast:(NSString *)msg {
    [self ensureWindow]; self.win.hidden = NO;
    [self.toast removeFromSuperview];
    CGFloat w = MIN(300, [self SW] - 40);
    H26Glass *g = H26MakeGlass(CGRectMake(([self SW] - w) / 2, 60, w, 40), 20, UIBlurEffectStyleDark);
    W12FixedLabel *l = [[W12FixedLabel alloc] initWithFrame:g.bounds]; [l lockFont:[UIFont systemFontOfSize:14 weight:UIFontWeightMedium]]; l.textColor = [UIColor whiteColor]; l.textAlignment = NSTextAlignmentCenter; l.text = msg;
    [g.contentView addSubview:l]; g.alpha = 0; [self.win.rootViewController.view addSubview:g];
    [UIView animateWithDuration:0.2 animations:^{ g.alpha = 1; } completion:^(BOOL f) {
        [UIView animateWithDuration:0.3 delay:1.8 options:0 animations:^{ g.alpha = 0; } completion:^(BOOL f2) { [g removeFromSuperview]; }];
    }];
}

// ---- the menu under "Edit" ----
- (void)editTap { if (self.menuUp) [self closeMenu]; else [self openMenu]; }
- (void)closeMenu {
    if (!self.menuUp) return;
    self.menuUp = NO; UIView *m = self.menu; self.menu = nil;
    [UIView animateWithDuration:0.18 animations:^{ m.alpha = 0; m.transform = CGAffineTransformMakeScale(0.7, 0.7); } completion:^(BOOL f) { [m removeFromSuperview]; }];
    [self updateModal];
}
- (void)openMenu {
    [self ensureWindow];
    self.menuUp = YES; [self updateModal];
    NSArray *items = @[@"Add Widget", @"Customize", @"Edit Wallpaper", @"Edit Pages"];
    CGFloat rowH = 48, W = 214, H = rowH * items.count;
    H26Glass *m = H26MakeGlass(CGRectMake(10, 50, W, H), 22, UIBlurEffectStyleDark);
    for (int i = 0; i < (int)items.count; i++) {
        CGFloat y = i * rowH;
        W12FixedLabel *l = [[W12FixedLabel alloc] initWithFrame:CGRectMake(18, y, W - 70, rowH)]; [l lockFont:[UIFont systemFontOfSize:17]]; l.textColor = [UIColor whiteColor]; l.text = items[i];
        [m.contentView addSubview:l];
        // small glyph on the right
        CAShapeLayer *g = [CAShapeLayer layer]; g.fillColor = nil; g.strokeColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor; g.lineWidth = 1.7; g.lineCap = kCALineCapRound;
        CGRect gr = CGRectMake(W - 18 - 22, y + (rowH - 22) / 2, 22, 22); UIBezierPath *p = [UIBezierPath bezierPath];
        if (i == 0) { [p appendPath:[UIBezierPath bezierPathWithRoundedRect:gr cornerRadius:5]]; [p moveToPoint:CGPointMake(CGRectGetMidX(gr), gr.origin.y + 6)]; [p addLineToPoint:CGPointMake(CGRectGetMidX(gr), CGRectGetMaxY(gr) - 6)]; [p moveToPoint:CGPointMake(gr.origin.x + 6, CGRectGetMidY(gr))]; [p addLineToPoint:CGPointMake(CGRectGetMaxX(gr) - 6, CGRectGetMidY(gr))]; }
        else if (i == 1) { [p appendPath:[UIBezierPath bezierPathWithOvalInRect:gr]]; [p moveToPoint:CGPointMake(CGRectGetMidX(gr), gr.origin.y)]; [p addLineToPoint:CGPointMake(CGRectGetMidX(gr), CGRectGetMaxY(gr))]; }
        else if (i == 2) { [p appendPath:[UIBezierPath bezierPathWithRoundedRect:gr cornerRadius:5]]; [p moveToPoint:CGPointMake(gr.origin.x + 2, CGRectGetMaxY(gr) - 5)]; [p addLineToPoint:CGPointMake(gr.origin.x + 8, CGRectGetMidY(gr) + 1)]; [p addLineToPoint:CGPointMake(gr.origin.x + 13, CGRectGetMaxY(gr) - 7)]; [p addLineToPoint:CGPointMake(gr.origin.x + 16, CGRectGetMidY(gr) + 3)]; [p addLineToPoint:CGPointMake(CGRectGetMaxX(gr) - 2, CGRectGetMaxY(gr) - 5)]; }
        else { [p appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(gr.origin.x, gr.origin.y, 15, 15) cornerRadius:4]]; [p appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(gr.origin.x + 7, gr.origin.y + 7, 15, 15) cornerRadius:4]]; }
        g.path = p.CGPath; [m.contentView.layer addSublayer:g];
        if (i > 0) { CALayer *sep = [CALayer layer]; sep.frame = CGRectMake(16, y, W - 32, 0.5); sep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor; [m.contentView.layer addSublayer:sep]; }
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom]; b.frame = CGRectMake(0, y, W, rowH); b.tag = 100 + i;
        [b addTarget:self action:@selector(menuPick:) forControlEvents:UIControlEventTouchUpInside];
        [b addTarget:self action:@selector(menuDown:) forControlEvents:UIControlEventTouchDown];
        [b addTarget:self action:@selector(menuUpTap:) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchUpInside];
        [m.contentView addSubview:b];
    }
    m.layer.anchorPoint = CGPointMake(0.1, 0); m.frame = CGRectMake(10, 50, W, H);
    m.alpha = 0; m.transform = CGAffineTransformMakeScale(0.6, 0.6);
    [self.win.rootViewController.view addSubview:m]; self.menu = m;
    [UIView animateWithDuration:0.42 delay:0 usingSpringWithDamping:0.72 initialSpringVelocity:0.6 options:0 animations:^{ m.alpha = 1; m.transform = CGAffineTransformIdentity; } completion:nil];
}
- (void)menuDown:(UIButton *)b { b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14]; }
- (void)menuUpTap:(UIButton *)b { b.backgroundColor = [UIColor clearColor]; }
- (void)menuPick:(UIButton *)b {
    int i = (int)b.tag - 100;
    [self closeMenu];
    if (i == 0) [self showToast:W12Tr(@"Widget chưa hỗ trợ trên iOS 12")];
    else if (i == 1) { [self exitEditing]; dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self openPanel]; }); }
    else if (i == 2) { [self exitEditing]; UIApplication *app = [UIApplication sharedApplication]; SEL sel = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:"); if ([app respondsToSelector:sel]) ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(app, sel, @"com.apple.Preferences", NO); }
    else [self showToast:W12Tr(@"Chỉnh sửa trang chưa hỗ trợ")];
}

// ---- the Customize sheet ----
static const char *kStyleNames[4] = {"Default", "Dark", "Clear", "Tinted"};

- (void)sampleWallpaper {
    if (H26WallUpdate(YES)) return;
    { NSString *wp = @"/var/mobile/Library/SpringBoard/HomeBackgroundThumbnail.jpg"; if ([[NSFileManager defaultManager] fileExistsAtPath:wp]) return; }
    typedef CGImageRef (*Fn)(void); Fn fn = (Fn)dlsym(RTLD_DEFAULT, "UIGetScreenImage"); if (!fn) return;
    CGImageRef img = fn(); if (!img) return;
    uint8_t px[24 * 40 * 4]; memset(px, 0, sizeof(px));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(px, 24, 40, 8, 24 * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (c) { CGContextSetInterpolationQuality(c, kCGInterpolationMedium); CGContextDrawImage(c, CGRectMake(0, 0, 24, 40), img); CGContextRelease(c); }
    CGColorSpaceRelease(cs); CGImageRelease(img);
    // saturation-weighted mean hue (vector average), so a colourful wallpaper wins over grey icons
    double sx = 0, sy = 0, ws = 0;
    for (int i = 0; i < 24 * 40; i++) {
        CGFloat h, s, b, a; [[UIColor colorWithRed:px[i * 4] / 255.0 green:px[i * 4 + 1] / 255.0 blue:px[i * 4 + 2] / 255.0 alpha:1] getHue:&h saturation:&s brightness:&b alpha:&a];
        double wgt = s * s * b; sx += cos(h * 2 * M_PI) * wgt; sy += sin(h * 2 * M_PI) * wgt; ws += wgt;
    }
    if (ws > 0.01) { double h = atan2(sy, sx) / (2 * M_PI); if (h < 0) h += 1; gH26Wall = h; }
}

- (UIImage *)previewFor:(int)style {
    UIImage *pk = H26Pack(@"com.apple.weather", style == 1 ? 1 : 0);
    if (pk) return (style >= 2) ? H26Process(pk, style, H26HueNow(), gH26Sat, gH26Bri, H26Night(), gH26BG, NO) : ((fabs(gH26Bri - 1) < 0.01) ? pk : H26Process(pk, 0, 0, 0, gH26Bri, NO, 0, NO));
    if (!self.weather) {
        UIImage *w = W12AppIcon(@"com.apple.weather") ?: W12AppIcon(@"com.apple.Preferences");
        self.weather = w;
    }
    if (!self.weather) return nil;
    BOOL night = H26Night();
    return H26Process(self.weather, style, H26HueNow(), gH26Sat, gH26Bri, night, gH26BG, NO);
}

- (void)openPanel {
    if (self.panelUp) return;
    [self ensureWindow];
    if (gH26Style == 3 && gH26Src == 1) {}
    [self sampleWallpaper];
    self.weather = nil;
    self.panelUp = YES; [self updateModal]; self.win.hidden = NO;
    [self buildPanel];
    CGFloat W = [self SW] - 12, H = self.panel.bounds.size.height;
    CGRect fin = CGRectMake(6, [self SH] - 6 - H, W, H);
    self.panel.frame = CGRectOffset(fin, 0, H + 20);
    [self.win.rootViewController.view addSubview:self.panel];
    [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.4 options:0 animations:^{ self.panel.frame = fin; } completion:nil];
}
- (void)closePanel {
    if (!self.panelUp) return;
    self.panelUp = NO; UIView *p = self.panel; self.panel = nil;
    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{ p.frame = CGRectOffset(p.frame, 0, p.frame.size.height + 24); } completion:^(BOOL f) { [p removeFromSuperview]; }];
    [self updateModal];
    H26Save();
    if (!self.editShown) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (!self.panelUp && !self.editShown && !self.menuUp) { /* keep window: it is cheap and click-through */ } });
}

- (CGFloat)panelHeight { return gH26Style == 3 ? 376 : 224; }

- (void)buildPanel {
    CGFloat W = [self SW] - 12, H = [self panelHeight];
    H26Glass *p = H26MakeGlass(CGRectMake(0, 0, W, H), 40, UIBlurEffectStyleDark);
    self.panel = p; UIView *cv = p.contentView;
    // header: sun (brightness), title, two squares (labels)
    UIView *sun = [[UIView alloc] initWithFrame:CGRectMake(16, 12, 38, 38)]; sun.layer.cornerRadius = 19; sun.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    UIImageView *si = [[UIImageView alloc] initWithImage:H26SunGlyph([UIColor colorWithWhite:1 alpha:0.9], 22)]; si.center = CGPointMake(19, 19); [sun addSubview:si];
    UIButton *sb = [UIButton buttonWithType:UIButtonTypeCustom]; sb.frame = sun.bounds; [sb addTarget:self action:@selector(sunTap) forControlEvents:UIControlEventTouchUpInside]; [sun addSubview:sb];
    [cv addSubview:sun]; self.sunBtn = sun;
    W12FixedLabel *title = [[W12FixedLabel alloc] initWithFrame:CGRectMake(70, 12, W - 140, 38)]; [title lockFont:[UIFont systemFontOfSize:19 weight:UIFontWeightSemibold]]; title.textColor = [UIColor whiteColor]; title.textAlignment = NSTextAlignmentCenter; title.text = @"Customize"; [cv addSubview:title];
    UIView *tg = [[UIView alloc] initWithFrame:CGRectMake(W - 16 - 52, 15, 52, 32)]; tg.layer.cornerRadius = 16; tg.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    UIView *sq1 = [[UIView alloc] initWithFrame:CGRectMake(9, 10, 12, 12)]; sq1.layer.cornerRadius = 3; sq1.backgroundColor = [UIColor whiteColor];
    UIView *sq2 = [[UIView alloc] initWithFrame:CGRectMake(28, 7, 17, 17)]; sq2.layer.cornerRadius = 4.5; sq2.layer.borderWidth = 1.6; sq2.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.85].CGColor;
    [tg addSubview:sq2]; [tg addSubview:sq1];
    UIButton *tb = [UIButton buttonWithType:UIButtonTypeCustom]; tb.frame = tg.bounds; [tb addTarget:self action:@selector(togTap) forControlEvents:UIControlEventTouchUpInside]; [tg addSubview:tb];
    [cv addSubview:tg]; self.togBtn = tg; [self refreshToggle];
    // style tiles
    self.tileImgs = [NSMutableArray array]; self.tileLabels = [NSMutableArray array]; self.tileBgs = [NSMutableArray array];
    for (int i = 0; i < 4; i++) {
        CGFloat cx = W / 2 + (i - 1.5) * 84;
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(cx - 31, 64, 62, 62)]; iv.contentMode = UIViewContentModeScaleAspectFit; iv.image = [self previewFor:i];
        if (!iv.image) { iv.backgroundColor = [UIColor colorWithWhite:0.4 alpha:1]; iv.layer.cornerRadius = 14; }
        [cv addSubview:iv]; [self.tileImgs addObject:iv];
        UIView *bg = [[UIView alloc] initWithFrame:CGRectMake(cx - 38, 134, 76, 26)]; bg.layer.cornerRadius = 13; [cv addSubview:bg]; [self.tileBgs addObject:bg];
        W12FixedLabel *l = [[W12FixedLabel alloc] initWithFrame:bg.frame]; [l lockFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]]; l.textAlignment = NSTextAlignmentCenter; l.text = [NSString stringWithUTF8String:kStyleNames[i]];
        [cv addSubview:l]; [self.tileLabels addObject:l];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom]; b.frame = CGRectMake(cx - 42, 58, 84, 106); b.tag = i; [b addTarget:self action:@selector(tileTap:) forControlEvents:UIControlEventTouchUpInside]; [cv addSubview:b];
    }
    // tinted controls
    self.hueS = [[H26Slider alloc] initWithFrame:CGRectMake(18, 176, W - 36, 40)];
    NSMutableArray *rb = [NSMutableArray array]; for (int i = 0; i <= 12; i++) { double r, g, b; H26HSB(i / 12.0, 1, 1, &r, &g, &b); [rb addObject:(id)[UIColor colorWithRed:r green:g blue:b alpha:1].CGColor]; }
    [self.hueS setTrackColors:rb]; self.hueS.value = H26HueNow();
    __weak H26UI *wk = self;
    self.hueS.onChange = ^(double v, BOOL end) { gH26Hue = v; gH26Src = 0; [wk changed:end]; };
    [cv addSubview:self.hueS];
    self.satS = [[H26Slider alloc] initWithFrame:CGRectMake(18, 222, W - 36, 40)]; self.satS.value = gH26Sat;
    self.satS.onChange = ^(double v, BOOL end) { gH26Sat = v; [wk changed:end]; };
    [cv addSubview:self.satS];
    // colour row: dark bg, light bg, wallpaper, custom
    self.colRow = [[UIView alloc] initWithFrame:CGRectMake(0, 272, W, 48)]; [cv addSubview:self.colRow];
    self.colBtns = [NSMutableArray array];
    for (int i = 0; i < 4; i++) {
        CGFloat cx = W / 2 + (i - 1.5) * 76;
        UIView *c = [[UIView alloc] initWithFrame:CGRectMake(cx - 23, 2, 46, 46)]; c.layer.cornerRadius = 23; c.userInteractionEnabled = NO;
        CAShapeLayer *gl = [CAShapeLayer layer]; gl.name = @"glyph"; gl.fillColor = nil; gl.strokeColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor; gl.lineWidth = 1.6;
        UIBezierPath *gp = [UIBezierPath bezierPath]; CGPoint m = CGPointMake(23, 23);
        if (i == 0 || i == 1) { [gp appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(m.x - 7, m.y - 12, 14, 24) cornerRadius:3.5]]; gl.fillColor = (i == 0) ? [UIColor colorWithWhite:1 alpha:0.9].CGColor : nil; }
        else if (i == 2) { for (int k = 0; k < 6; k++) { double a = k * M_PI / 3; [gp appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(m.x + cos(a) * 6 - 4.5, m.y + sin(a) * 6 - 4.5, 9, 9)]]; } }
        if (i < 3) { gl.path = gp.CGPath; [c.layer addSublayer:gl]; }
        [self.colRow addSubview:c]; [self.colBtns addObject:c];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom]; b.frame = CGRectMake(cx - 30, 0, 60, 50); b.tag = i; [b addTarget:self action:@selector(colTap:) forControlEvents:UIControlEventTouchUpInside]; [self.colRow addSubview:b];
    }
    // appearance row
    self.modeRow = [[UIView alloc] initWithFrame:CGRectMake(16, 0, W - 32, 44)]; self.modeRow.layer.cornerRadius = 16; self.modeRow.backgroundColor = [UIColor colorWithWhite:0 alpha:0.22]; [cv addSubview:self.modeRow];
    self.modeSel = [UIView new]; self.modeSel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.24]; self.modeSel.layer.cornerRadius = 15; [self.modeRow addSubview:self.modeSel];
    self.modeLabels = [NSMutableArray array];
    for (int i = 0; i < 3; i++) {
        W12FixedLabel *l = [W12FixedLabel new]; [l lockFont:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]]; l.textAlignment = NSTextAlignmentCenter; [self.modeRow addSubview:l]; [self.modeLabels addObject:l];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom]; b.tag = i; [b addTarget:self action:@selector(modeTap:) forControlEvents:UIControlEventTouchUpInside]; [self.modeRow addSubview:b];
    }
    [self layoutPanel:NO];
}

- (void)refreshToggle { self.togBtn.alpha = gH26Labels ? 1.0 : 0.6; }

- (void)layoutPanel:(BOOL)animated {
    if (!self.panel) return;
    BOOL tinted = gH26Style == 3;
    CGFloat W = self.panel.bounds.size.width;
    // tiles' selection look
    for (int i = 0; i < 4; i++) {
        BOOL sel = (i == gH26Style);
        UIView *bg = self.tileBgs[i]; W12FixedLabel *l = self.tileLabels[i];
        bg.backgroundColor = sel ? [UIColor colorWithWhite:1 alpha:0.26] : [UIColor clearColor];
        l.textColor = sel ? [UIColor whiteColor] : [UIColor colorWithWhite:1 alpha:0.62];
    }
    // appearance labels
    NSArray *names = (gH26Style == 1) ? @[@"Always", @"Auto"] : @[@"Light", @"Dark", @"Auto"];
    int count = (int)names.count;
    CGFloat mw = (W - 32) / count; int selIdx = (gH26Style == 1) ? (gH26Mode == 2 ? 1 : 0) : gH26Mode;
    for (int i = 0; i < 3; i++) {
        W12FixedLabel *l = self.modeLabels[i]; UIButton *b = nil; for (UIView *s in self.modeRow.subviews) if ([s isKindOfClass:[UIButton class]] && s.tag == i) b = (UIButton *)s;
        l.hidden = i >= count; b.hidden = i >= count;
        if (i < count) { l.text = names[i]; l.frame = CGRectMake(i * mw, 0, mw, 44); b.frame = l.frame; l.textColor = (i == selIdx) ? [UIColor whiteColor] : [UIColor colorWithWhite:1 alpha:0.6]; }
    }
    CGFloat H = [self panelHeight];
    CGFloat modeY = tinted ? 322 : 172;
    void (^apply)(void) = ^{
        CGRect f = self.panel.frame; f.size.height = H; f.origin.y = [self SH] - 6 - H; self.panel.frame = f;
        self.modeRow.frame = CGRectMake(16, modeY, W - 32, 44);
        self.modeSel.frame = CGRectMake(selIdx * mw + 3, 3, mw - 6, 38);
        self.hueS.alpha = tinted ? 1 : 0; self.satS.alpha = tinted ? 1 : 0; self.colRow.alpha = tinted ? 1 : 0;
    };
    if (animated) [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.3 options:UIViewAnimationOptionBeginFromCurrentState animations:apply completion:nil]; else apply();
    self.hueS.userInteractionEnabled = tinted; self.satS.userInteractionEnabled = tinted; self.colRow.userInteractionEnabled = tinted;
    [self refreshTint];
}

- (void)refreshTint {
    double r, g, b; double hue = H26HueNow();
    H26HSB(hue, 1, 1, &r, &g, &b);
    UIColor *pure = [UIColor colorWithRed:r green:g blue:b alpha:1];
    self.hueS.value = hue; self.hueS.thumbFill.backgroundColor = pure;
    [self.satS setTrackColors:@[(id)[UIColor colorWithWhite:1 alpha:1].CGColor, (id)pure.CGColor]];
    self.satS.value = gH26Sat; self.satS.thumbFill.backgroundColor = [UIColor colorWithRed:1 - (1 - r) * gH26Sat green:1 - (1 - g) * gH26Sat blue:1 - (1 - b) * gH26Sat alpha:1];
    for (int i = 0; i < 4; i++) {
        UIView *c = self.colBtns[i];
        BOOL sel = (i < 2) ? (gH26BG == i) : (i == 2 ? gH26Src == 1 : gH26Src == 0);
        c.backgroundColor = sel ? [UIColor colorWithWhite:1 alpha:0.22] : [UIColor colorWithWhite:1 alpha:0.10];
        c.layer.borderWidth = sel ? 1.5 : 0; c.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.7].CGColor;
        if (i == 3) { c.backgroundColor = pure; c.layer.borderWidth = sel ? 3 : 0; c.layer.borderColor = [UIColor whiteColor].CGColor; }
    }
}

- (void)refreshPreviews {
    for (int i = 0; i < 4; i++) { UIImage *im = [self previewFor:i]; if (im) { ((UIImageView *)self.tileImgs[i]).image = im; ((UIImageView *)self.tileImgs[i]).backgroundColor = [UIColor clearColor]; } }
}

- (void)changed:(BOOL)end {
    [self refreshTint]; [self refreshPreviews];
    H26RefreshAll();
    if (end) H26Save();
}
- (void)tileTap:(UIButton *)b {
    if (gH26Style == b.tag) return;
    gH26Style = (int)b.tag;
    if (gH26Style == 1 && gH26Mode == 0) gH26Mode = 1;       // Dark: "Always" by default
    [self layoutPanel:YES]; [self refreshPreviews]; H26RefreshAll(); H26Save();
}
- (void)colTap:(UIButton *)b {
    int i = (int)b.tag;
    if (i < 2) gH26BG = i; else if (i == 2) { gH26Src = 1; } else { gH26Src = 0; }
    [self changed:YES];
}
- (void)modeTap:(UIButton *)b {
    int i = (int)b.tag;
    if (gH26Style == 1) gH26Mode = (i == 0) ? 1 : 2; else gH26Mode = i;
    [self layoutPanel:YES]; [self refreshPreviews]; H26RefreshAll(); H26Save();
}
- (void)sunTap {
    static const double lv[4] = {1.0, 0.85, 0.7, 1.15};
    int idx = 0; for (int i = 0; i < 4; i++) if (fabs(gH26Bri - lv[i]) < 0.02) idx = i;
    gH26Bri = lv[(idx + 1) % 4];
    self.sunBtn.alpha = 0.55 + 0.45 * MIN(1, gH26Bri);
    [self changed:YES];
}
- (void)togTap { gH26Labels = !gH26Labels; [self refreshToggle]; H26RefreshAll(); H26Save(); }
@end

static H26UI *gH26UI;
static void W12Home26Start(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try { gH26UI = [H26UI new]; [gH26UI start]; } @catch (NSException *e) { W12_LOG(@"26home start failed: %@", e.reason); }
    });
}
