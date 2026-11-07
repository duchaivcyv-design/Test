// Glass rim helper: the rim is a pre-rendered, stretchable bitmap (9-slice) instead of a gradient layer with a shape mask.
// A masked gradient forces an offscreen render pass per layer on every frame; a plain bitmap layer is just composited.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

// iOS "continuous" (squircle) rounded rectangle, built the way Figma documents it (60% smoothing): the curve starts
// 1.6 * r away from the corner instead of r, so it follows the real Control Center shapes instead of a plain circular arc.
// The path is a fine polyline: the 9-slice bitmap below is drawn once per radius, so the cost does not matter.
static inline UIBezierPath *W12SquirclePath(CGRect R, CGFloat r) {
    CGFloat W = R.size.width, H = R.size.height, half = MIN(W, H) / 2;
    r = MAX(0.5, MIN(r, half));
    CGFloat sm = 0.6, p = (1 + sm) * r;
    if (p > half) { sm = MAX(0, half / r - 1); p = MIN(p, half); }
    const CGFloat K = M_PI / 180;
    CGFloat arcMeasure = 90 * (1 - sm);
    CGFloat arcSec = sin(arcMeasure / 2 * K) * r * M_SQRT2;
    CGFloat alpha = (90 - arcMeasure) / 2;
    CGFloat p3p4 = r * tan(alpha / 2 * K);
    CGFloat beta = 45 * sm;
    CGFloat c = p3p4 * cos(beta * K), d = c * tan(beta * K);
    CGFloat b = (p - arcSec - c - d) / 3, a = 2 * b;
    // corner in local coordinates: the corner point is (0,0), the shape lies at x < 0, y > 0
    CGPoint S0 = CGPointMake(-p, 0), P1 = CGPointMake(-p + a + b + c, d), P2 = CGPointMake(P1.x + arcSec, P1.y + arcSec);
    NSMutableArray *loc = [NSMutableArray array];
    #define ADD(px, py) [loc addObject:[NSValue valueWithCGPoint:CGPointMake(px, py)]]
    const int N = 14;
    for (int i = 0; i <= N; i++) {                           // first Bezier: edge -> arc
        CGFloat u = (CGFloat)i / N, v = 1 - u;
        CGPoint c1 = CGPointMake(-p + a, 0), c2 = CGPointMake(-p + a + b, 0);
        ADD(v*v*v*S0.x + 3*v*v*u*c1.x + 3*v*u*u*c2.x + u*u*u*P1.x, v*v*v*S0.y + 3*v*v*u*c1.y + 3*v*u*u*c2.y + u*u*u*P1.y);
    }
    CGFloat chord = arcSec * M_SQRT2, h = sqrt(MAX(0, r * r - chord * chord / 4));
    CGPoint ctr = CGPointMake((P1.x + P2.x) / 2 - h / M_SQRT2, (P1.y + P2.y) / 2 + h / M_SQRT2);
    CGFloat sa = atan2(P1.y - ctr.y, P1.x - ctr.x), ea = atan2(P2.y - ctr.y, P2.x - ctr.x);
    for (int i = 1; i < 20; i++) { CGFloat ang = sa + (ea - sa) * i / 20.0; ADD(ctr.x + r * cos(ang), ctr.y + r * sin(ang)); }
    for (int i = 0; i <= N; i++) {                           // second Bezier: arc -> edge
        CGFloat u = (CGFloat)i / N, v = 1 - u;
        CGPoint c1 = CGPointMake(P2.x + d, P2.y + c), c2 = CGPointMake(P2.x + d, P2.y + b + c), E = CGPointMake(0, p);
        ADD(v*v*v*P2.x + 3*v*v*u*c1.x + 3*v*u*u*c2.x + u*u*u*E.x, v*v*v*P2.y + 3*v*v*u*c1.y + 3*v*u*u*c2.y + u*u*u*E.y);
    }
    #undef ADD
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGPoint corner[4] = { CGPointMake(R.origin.x + W, R.origin.y), CGPointMake(R.origin.x + W, R.origin.y + H),
                          CGPointMake(R.origin.x, R.origin.y + H), CGPointMake(R.origin.x, R.origin.y) };
    for (int k = 0; k < 4; k++) {
        CGFloat th = k * M_PI_2, cs = cos(th), sn = sin(th);
        for (NSValue *val in loc) {
            CGPoint q = val.CGPointValue;
            CGPoint pt = CGPointMake(corner[k].x + q.x * cs - q.y * sn, corner[k].y + q.x * sn + q.y * cs);
            if (path.isEmpty) [path moveToPoint:pt]; else [path addLineToPoint:pt];
        }
    }
    [path closePath];
    return path;
}

static inline UIImage *W12RimImageL(CGFloat r, CGFloat maxP, BOOL strong, BOOL light) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    r = MAX(2.0, round(r * 2.0) / 2.0);
    CGFloat pe = MAX(r, MIN(1.6 * r, round(maxP * 2.0) / 2.0));            // extent of the corner along each edge
    NSString *key = [NSString stringWithFormat:@"%.1f|%.1f|%d|%d", r, pe, strong, light];
    UIImage *img = cache[key];
    if (img) return img;
    BOOL circ = (pe <= r + 0.01);                                             // circle / capsule end: no smoothing, the cell is exactly the circle
    CGFloat lw = light ? (strong ? 1.35 : 1.1) : (strong ? 1.1 : 1.0), S = 2 * ceil(pe) + (circ ? 0 : 2);
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(S, S), NO, [UIScreen mainScreen].scale);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect rr = CGRectInset(CGRectMake(0, 0, S, S), lw / 2, lw / 2);
    UIBezierPath *p = W12SquirclePath(rr, circ ? rr.size.width / 2 : r - lw / 2);
    CGContextAddPath(c, p.CGPath); CGContextSetLineWidth(c, lw);
    CGContextReplacePathWithStrokedPath(c); CGContextClip(c);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat a0 = strong ? 0.85 : 0.62, a1 = strong ? 0.14 : 0.10, a2 = strong ? 0.60 : 0.40;
    CGFloat comps[16] = {1,1,1,a0,  1,1,1,a1,  1,1,1,a1,  1,1,1,a2};
    if (light) {   // light mode: the same glass (bright specular arcs top-left / bottom-right), with a faint cool body so the ring still reads on white
        CGFloat gd = strong ? 0.20 : 0.15;
        CGFloat lc[16] = {1,1,1,1.0,  0.50,0.58,0.68,gd,  0.50,0.58,0.68,gd,  1,1,1,0.96};
        memcpy(comps, lc, sizeof(lc));
    }
    CGFloat locs[4] = {0, 0.38, 0.62, 1};
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, locs, 4);
    CGContextDrawLinearGradient(c, g, CGPointMake(0, 0), CGPointMake(S, S), 0);
    CGGradientRelease(g); CGColorSpaceRelease(cs);
    img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (img) cache[key] = img;
    return img;
}

static inline UIImage *W12RimImage(CGFloat r, CGFloat maxP, BOOL strong) { return W12RimImageL(r, maxP, strong, NO); }

static inline CALayer *W12RimLayer(NSString *name) {
    CALayer *l = [CALayer layer];
    l.name = name; l.contentsScale = [UIScreen mainScreen].scale;
    l.actions = @{@"contents": [NSNull null], @"bounds": [NSNull null], @"position": [NSNull null], @"hidden": [NSNull null]};
    return l;
}

// Shows the rim around `b` (in the host layer's coordinates) with corner radius r.
static inline void W12RimSetL(CALayer *rim, CGRect b, CGFloat r, BOOL strong, BOOL light) {
    r = MAX(2.0, MIN(r, MIN(b.size.width, b.size.height) / 2));
    UIImage *img = W12RimImageL(r, MIN(b.size.width, b.size.height) / 2, strong, light);
    CGFloat S = img.size.width;
    if (rim.contents != (id)img.CGImage) {
        rim.contents = (id)img.CGImage;
        rim.contentsCenter = CGRectMake((S / 2 - 0.5) / S, (S / 2 - 0.5) / S, 1.0 / S, 1.0 / S);
    }
    if (!CGRectEqualToRect(rim.frame, b)) rim.frame = b;
}
static inline void W12RimSet(CALayer *rim, CGRect b, CGFloat r, BOOL strong) { W12RimSetL(rim, b, r, strong, NO); }
