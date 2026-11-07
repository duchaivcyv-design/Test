// Wave12 — iOS 12 / iPhone 6 port (rewrite) of "26Unlock" by blu_tek.
// Icons fly in as a wave from the screen centre outwards. Critically damped
// springs (no bounce), only transform/position/opacity are animated, so it
// runs fully on the GPU (no offscreen rendering) and stays smooth on A8.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <dlfcn.h>
#include <strings.h>
#import "W12Rim.h"
#import "W12L.h"

#define W12_DOMAIN CFSTR("com.wave12.unlockwave")
#ifndef W12_ENKEY_S
#define W12_ENKEY_S enabled
#endif
#ifndef W12_MOD_S
#define W12_MOD_S all
#endif
#define W12_ST2(x) #x
#define W12_ST(x) W12_ST2(x)
#define W12_ENKEY @W12_ST(W12_ENKEY_S)
#define W12_MODNAME W12_ST(W12_MOD_S)
static void W12LogF(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    double ts = CACurrentMediaTime();
    static dispatch_queue_t q;                       // file I/O never runs on the main thread (it used to stall the animations)
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.wave12.log", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(q, ^{
        const char *path = "/var/mobile/Library/Logs/Wave12.log";
        FILE *f = fopen(path, "a");
        if (f) {
            if (ftell(f) > 200000) { fclose(f); f = fopen(path, "w"); }
            if (f) { fprintf(f, "%.2f %s\n", ts, m.UTF8String); fclose(f); }
        }
    });
}
#define W12_LOG(fmt, ...) W12LogF(@"" fmt, ##__VA_ARGS__)

typedef NS_ENUM(NSInteger, W12Source) { W12SourceUnlock = 0, W12SourceHome = 1 };

#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

// MARK: - Preferences

static id W12Pref(NSString *key) {
    // 0.4 s cache: the animations read many keys per frame-critical call; settings still apply almost instantly
    static NSMutableDictionary *cache; static CFTimeInterval stamp;
    @synchronized ([NSNull null]) {
        CFTimeInterval now = CACurrentMediaTime();
        if (!cache || now - stamp > 0.4) { cache = [NSMutableDictionary dictionary]; stamp = now; }
        if ([key isEqualToString:@"enabled"]) key = W12_ENKEY;      // each module has its own master switch
        id c = cache[key];
        if (c) return c == (id)[NSNull null] ? nil : c;
        CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, W12_DOMAIN);
        id o = CFBridgingRelease(v);
        cache[key] = o ?: [NSNull null];
        return o;
    }
}
static BOOL W12Bool(NSString *key, BOOL def) {
    id v = W12Pref(key);
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : def;
}
static double W12Double(NSString *key, double def, double lo, double hi) {
    id v = W12Pref(key);
    double d = [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : def;
    return MAX(lo, MIN(hi, d));
}

// MARK: - Helpers

static id W12Call(id obj, SEL sel) {
    if (obj && [obj respondsToSelector:sel]) return [obj performSelector:sel];
    return nil;
}

// Apps the user switched off in Wave12 -> Danh sách loại trừ (shared by every feature).
static NSArray *gExclCache; static CFTimeInterval gExclTime;
static BOOL W12Excluded(NSString *bid) {
    if (![bid isKindOfClass:[NSString class]] || !bid.length) return NO;
    CFTimeInterval now = CACurrentMediaTime();
    if (!gExclCache || now - gExclTime > 1.5) {
        CFPreferencesAppSynchronize(W12_DOMAIN);
        CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("exclude"), W12_DOMAIN);
        id a = v ? CFBridgingRelease(v) : nil;
        gExclCache = [a isKindOfClass:[NSArray class]] ? a : @[];
        gExclTime = now;
    }
    return [gExclCache containsObject:bid];
}
static BOOL W12SelfExcluded(void) { return W12Excluded([NSBundle mainBundle].bundleIdentifier); }

static void W12Collect(UIView *v, Class iconCls, NSMutableArray *out, int depth) {
    if (!v || depth > 7) return;
    for (UIView *s in v.subviews) {
        if ([s isKindOfClass:iconCls]) { [out addObject:s]; continue; }
        W12Collect(s, iconCls, out, depth + 1);
    }
}

static BOOL W12Visible(UIView *v) {
    return v.window && !v.hidden && v.alpha > 0.01 && v.bounds.size.width > 1 && v.bounds.size.height > 1;
}

// MARK: - Animation

static CFTimeInterval gLastRunBy[2] = {0, 0};
static double gHomeDelay = 0;   // extra delay for the home wave when the app card is shrinking

static void W12Run(W12Source source) {
    if (!W12Bool(@"enabled", YES)) return;
    if (source == W12SourceUnlock && !W12Bool(@"unlock", YES)) return;
    if (source == W12SourceHome && !W12Bool(@"home", YES)) return;
    if (UIAccessibilityIsReduceMotionEnabled()) return;

    CFTimeInterval now = CACurrentMediaTime();
    // several hooks fire for one unlock event, so unlock needs a longer guard; Home may be spammed
    if (now - gLastRunBy[source] < (source == W12SourceUnlock ? 0.6 : 0.1)) return;

    Class iconCls = NSClassFromString(@"SBIconView");
    Class ctrlCls = NSClassFromString(@"SBIconController");
    if (!iconCls || !ctrlCls) return;
    id ctrl = W12Call(ctrlCls, @selector(sharedInstance));
    if (!ctrl) return;

    if (source == W12SourceUnlock) {            // unlocking straight into an app: nothing to animate
        id app = W12Call([UIApplication sharedApplication], NSSelectorFromString(@"_accessibilityFrontMostApplication"));
        if (app) return;
    }

    NSMutableArray *icons = [NSMutableArray array];
    NSMutableSet *dockSet = [NSMutableSet set];
    UIView *list = W12Call(ctrl, @selector(currentRootIconList));
    UIView *dock = W12Call(ctrl, NSSelectorFromString(@"dockListView"));
    if ([list isKindOfClass:[UIView class]]) W12Collect(list, iconCls, icons, 0);
    if ([dock isKindOfClass:[UIView class]]) {
        NSMutableArray *di = [NSMutableArray array];
        W12Collect(dock, iconCls, di, 0);
        [icons addObjectsFromArray:di];
        [dockSet addObjectsFromArray:di];
    }
    if (icons.count == 0) {
        UIView *root = W12Call(ctrl, @selector(contentView)) ?: W12Call(ctrl, @selector(view));
        if ([root isKindOfClass:[UIView class]]) W12Collect(root, iconCls, icons, 0);
    }
    NSMutableArray *vis = [NSMutableArray arrayWithCapacity:icons.count];
    for (UIView *v in icons) {
        // returning to Home: the home layer may still be hidden under the app, so only require a window
        BOOL ok = (source == W12SourceHome) ? (v.window != nil && v.bounds.size.width > 1) : W12Visible(v);
        if (ok && v.superview) [vis addObject:v];
    }
    if (vis.count == 0 || vis.count > 80) return;

    gLastRunBy[source] = now;

    double speed   = W12Double(@"speed", 1.0, 0.6, 1.6);
    double zoom    = W12Double(@"zoom", 3.0, 1.1, 4.0);
    double stagger = W12Double(@"stagger", 0.14, 0.0, 0.4) / speed;
    double bounce  = W12Double(@"bounce", 0.7, 0.0, 1.0);
    double extra = 0;
    if (source == W12SourceHome && gHomeDelay < 0) { gHomeDelay = 0; return; }   // the card engine already animates the icon
    if (source == W12SourceHome) {            // like the reference video: icons only gently settle in
        zoom = 1.12; stagger = 0.05; bounce = 0.3;
        extra = gHomeDelay; gHomeDelay = 0;
    }

    if (source == W12SourceHome) {
        // Home settle: animate the two icon CONTAINERS (page + dock) instead of ~30 icons x 3 animations. Same look (the stagger on Home is
        // only 0.05 s), but one spring per container: far less main-thread work in the very frame the app card starts to shrink.
        NSMutableArray *targets = [NSMutableArray array];
        if ([list isKindOfClass:[UIView class]] && list.window && !list.hidden) [targets addObject:list];
        if ([dock isKindOfClass:[UIView class]] && dock.window && !dock.hidden) [targets addObject:dock];
        if (targets.count) {
            double zeta = 1.0 - 0.5 * bounce, stiffness = 170.0 * speed * speed, damping = 2.0 * zeta * sqrt(stiffness);
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            for (UIView *v in targets) {
                CALayer *L = v.layer;
                BOOL isDock = (v == dock);
                UIWindow *w = v.window;
                CGPoint c = [w convertPoint:CGPointMake(CGRectGetMidX(w.bounds), CGRectGetMidY(w.bounds)) toView:v.superview];
                CGPoint fp = L.position;
                double z = isDock ? 1.0 + (zoom - 1.0) * 0.45 : zoom;
                CGPoint sp = CGPointMake(fp.x + (c.x - fp.x) * (1 - z), fp.y + (c.y - fp.y) * (1 - z));   // scaling about the screen centre
                CFTimeInterval begin = [L convertTime:CACurrentMediaTime() fromLayer:nil] + 0.02 + extra + (isDock ? 0.0 : stagger * 0.6);
                CASpringAnimation *sc = [CASpringAnimation animationWithKeyPath:@"transform.scale"];
                sc.fromValue = @(z); sc.toValue = @1.0;
                CASpringAnimation *ps = [CASpringAnimation animationWithKeyPath:@"position"];
                ps.fromValue = [NSValue valueWithCGPoint:sp]; ps.toValue = [NSValue valueWithCGPoint:fp];
                for (CASpringAnimation *a in @[sc, ps]) {
                    a.mass = 1; a.stiffness = stiffness; a.damping = damping; a.initialVelocity = 0;
                    a.duration = MIN(a.settlingDuration, 0.6); a.beginTime = begin; a.fillMode = kCAFillModeBackwards;
                }
                CABasicAnimation *al = [CABasicAnimation animationWithKeyPath:@"opacity"];
                al.fromValue = @0.0; al.toValue = @1.0; al.duration = 0.14 / speed; al.beginTime = begin; al.fillMode = kCAFillModeBackwards;
                al.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
                if ([L animationForKey:@"w12.scale"]) {          // spam: continue from what is on screen
                    CALayer *pl = L.presentationLayer;
                    if (pl) { sc.fromValue = @(pl.transform.m11); ps.fromValue = [NSValue valueWithCGPoint:pl.position]; al.fromValue = @(pl.opacity); }
                }
                [L addAnimation:sc forKey:@"w12.scale"];
                [L addAnimation:ps forKey:@"w12.pos"];
                [L addAnimation:al forKey:@"w12.alpha"];
            }
            [CATransaction commit];
            return;
        }
    }

    // Pre-compute each icon's offset from the screen centre (in its own superview space).
    NSMutableArray<NSNumber *> *dist = [NSMutableArray arrayWithCapacity:vis.count];
    NSMutableArray<NSValue *> *cent = [NSMutableArray arrayWithCapacity:vis.count];
    double maxD = 1;
    for (UIView *v in vis) {
        UIWindow *w = v.window;
        CGPoint wc = CGPointMake(CGRectGetMidX(w.bounds), CGRectGetMidY(w.bounds));
        CGPoint c = [w convertPoint:wc toView:v.superview];
        double d = hypot(v.layer.position.x - c.x, v.layer.position.y - c.y);
        maxD = MAX(maxD, d);
        [dist addObject:@(d)];
        [cent addObject:[NSValue valueWithCGPoint:c]];
    }

    // Spring: bounce 0 = critically damped (no overshoot), 1 = lively (damping ratio 0.5).
    double zeta = 1.0 - 0.5 * bounce;
    double stiffness = 170.0 * speed * speed;
    double damping = 2.0 * zeta * sqrt(stiffness);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < vis.count; i++) {
        UIView *v = vis[i];
        CALayer *L = v.layer;
        CGPoint c = [cent[i] CGPointValue];
        CGPoint fp = L.position;
        BOOL isDock = [dockSet containsObject:v];
        double z = isDock ? 1.0 + (zoom - 1.0) * 0.45 : zoom;      // dock starts closer to its final size
        CGPoint sp = CGPointMake(c.x + (fp.x - c.x) * z, c.y + (fp.y - c.y) * z);
        double norm = isDock ? 0.35 : [dist[i] doubleValue] / maxD; // dock appears early, like the original
        CFTimeInterval delay = 0.02 + extra + norm * stagger;
        CFTimeInterval begin = [L convertTime:CACurrentMediaTime() fromLayer:nil] + delay;

        CASpringAnimation *sc = [CASpringAnimation animationWithKeyPath:@"transform.scale"];
        sc.fromValue = @(z); sc.toValue = @1.0;
        CASpringAnimation *ps = [CASpringAnimation animationWithKeyPath:@"position"];
        ps.fromValue = [NSValue valueWithCGPoint:sp]; ps.toValue = [NSValue valueWithCGPoint:fp];
        for (CASpringAnimation *a in @[sc, ps]) {
            a.mass = 1; a.stiffness = stiffness; a.damping = damping; a.initialVelocity = 0;
            a.duration = (source == W12SourceHome) ? MIN(a.settlingDuration, 0.6) : a.settlingDuration;   // gentle settle on Home: stop early, fewer frames of work while the card also animates
            a.beginTime = begin; a.fillMode = kCAFillModeBackwards;
        }
        CABasicAnimation *al = [CABasicAnimation animationWithKeyPath:@"opacity"];
        al.fromValue = @0.0; al.toValue = @1.0;
        al.duration = 0.14 / speed;
        al.beginTime = begin; al.fillMode = kCAFillModeBackwards;
        al.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];

        // spam-proof: when an older wave is still running, continue from what is on screen right now
        CALayer *pl = [L animationForKey:@"w12.scale"] ? L.presentationLayer : nil;
        if (pl) {
            sc.fromValue = @(pl.transform.m11);
            ps.fromValue = [NSValue valueWithCGPoint:pl.position];
            al.fromValue = @(pl.opacity);
        }
        [L addAnimation:sc forKey:@"w12.scale"];
        [L addAnimation:ps forKey:@"w12.pos"];
        [L addAnimation:al forKey:@"w12.alpha"];
    }
    [CATransaction commit];
}


// MARK: - iOS 26 style app open / close ("card" that grows from / shrinks to the icon)

static CGRect gLaunchRect; static BOOL gHasLaunchRect = NO; static CFTimeInterval gLaunchRectTime = 0;
static CFTimeInterval gLastOpenStart = 0, gLastClose = 0;

static CATransform3D W12T(CGFloat tx, CGFloat ty, CGFloat s, CGFloat rx, CGFloat ry) {
    CATransform3D t = CATransform3DIdentity;
    t.m34 = -1.0 / 900.0;
    t = CATransform3DTranslate(t, tx, ty, 0);
    t = CATransform3DScale(t, s, s, 1);
    if (rx != 0) t = CATransform3DRotate(t, rx, 1, 0, 0);
    if (ry != 0) t = CATransform3DRotate(t, ry, 0, 1, 0);
    return t;
}

static void W12Scan(UIView *v, int depth, CGSize sz, UIView **best, int *bestScore) {
    if (!v || depth > 9) return;
    for (UIView *s in v.subviews) {
        if (s.hidden || s.alpha < 0.05) continue;
        CGSize b = s.bounds.size;
        BOOL big = MAX(b.width, b.height) >= 0.85 * MAX(sz.width, sz.height) &&
                   MIN(b.width, b.height) >= 0.85 * MIN(sz.width, sz.height);
        NSString *cn = big ? NSStringFromClass([s class]) : nil;      // class-name strings only for full-screen views
        if (big && [cn containsString:@"Scene"]) {
            int score = [cn containsString:@"ApplicationSceneView"] ? 3 : ([cn containsString:@"SceneView"] ? 2 : 1);
            if (score > *bestScore) { *bestScore = score; *best = s; }
            if (score >= 2) continue;                       // found a scene view: never walk the app's own (huge) view tree
        }
        W12Scan(s, depth + 1, sz, best, bestScore);
    }
}

static void W12Dump(UIView *v, int depth, int maxDepth) {
    if (!v || depth > maxDepth) return;
    for (UIView *s in v.subviews) {
        CGRect f = s.frame;
        W12_LOG(@"%*s%@ (%.0f,%.0f %.0fx%.0f)%@", depth * 2, "", NSStringFromClass([s class]), f.origin.x, f.origin.y, f.size.width, f.size.height, s.hidden ? @" hidden" : @"");
        W12Dump(s, depth + 1, maxDepth);
    }
}

static __weak UIView *gSceneCache; static NSString *gSceneCacheBid;
// Fast path for rapid open/close: reuse the scene view found a moment ago while the same app is still frontmost.
static UIView *W12CachedScene(NSString *bid) {
    UIView *V = gSceneCache;
    if (V && bid && [bid isEqualToString:gSceneCacheBid] && V.window && V.superview && !V.hidden) return V;
    return nil;
}
static UIView *W12FindSceneView(void);
static UIView *W12SceneFor(NSString *bid) {
    UIView *V = W12CachedScene(bid);
    if (!V) { V = W12FindSceneView(); if (V && bid) { gSceneCache = V; gSceneCacheBid = [bid copy]; } }
    return V;
}
static UIView *W12FindSceneView(void) {
    CGSize sz = [UIScreen mainScreen].bounds.size;
    UIView *best = nil; int score = 0;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.hidden) continue;
        W12Scan(w, 0, sz, &best, &score);
    }
    return best;
}

static CFTimeInterval gLastDump = 0;
static void W12DumpAllWindows(const char *why) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gLastDump < 5) return;
    gLastDump = now;
    W12_LOG(@"--- hierarchy dump (%s) ---", why);
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        W12_LOG(@"WINDOW %@ level=%.0f hidden=%d", NSStringFromClass([w class]), w.windowLevel, w.hidden);
        W12Dump(w, 1, 6);
    }
}

static id W12FrontApp(void) {
    return W12Call([UIApplication sharedApplication], NSSelectorFromString(@"_accessibilityFrontMostApplication"));
}

static NSArray *W12HomeIconViews(void) {
    Class iconCls = NSClassFromString(@"SBIconView");
    id ctrl = W12Call(NSClassFromString(@"SBIconController"), @selector(sharedInstance));
    NSMutableArray *out = [NSMutableArray array];
    if (!iconCls || !ctrl) return out;
    UIView *list = W12Call(ctrl, @selector(currentRootIconList));
    UIView *dock = W12Call(ctrl, NSSelectorFromString(@"dockListView"));
    if ([list isKindOfClass:[UIView class]]) W12Collect(list, iconCls, out, 0);
    if ([dock isKindOfClass:[UIView class]]) W12Collect(dock, iconCls, out, 0);
    return out;
}

static NSMutableDictionary *gIconRectCache;     // bundle id -> @[rect, time]: the rect measured at launch makes the close start without walking the icon lists
static BOOL W12IconRectForBundle(NSString *bid, UIWindow *w, CGRect *out) {
    if (!bid || !w) return NO;
    NSArray *hit = gIconRectCache[bid];
    if (hit && CACurrentMediaTime() - [hit[1] doubleValue] < 90) { *out = [hit[0] CGRectValue]; return YES; }
    for (UIView *v in W12HomeIconViews()) {
        id icon = W12Call(v, @selector(icon));
        id b = W12Call(icon, NSSelectorFromString(@"applicationBundleID"));
        if ([b isKindOfClass:[NSString class]] && [b isEqualToString:bid]) {
            CGRect r = [v convertRect:v.bounds toView:w];
            CGFloat side = MIN(r.size.width, r.size.height);
            *out = CGRectMake(CGRectGetMidX(r) - side / 2, r.origin.y, side, side);
            if (!gIconRectCache) gIconRectCache = [NSMutableDictionary dictionary];
            gIconRectCache[bid] = @[[NSValue valueWithCGRect:*out], @(CACurrentMediaTime())];
            return YES;
        }
    }
    return NO;
}

@interface W12CardState : NSObject
@property (nonatomic) BOOL active, masks, group;
@property (nonatomic) CGFloat radius;
@property (nonatomic) NSUInteger gen;
@end
@implementation W12CardState
@end
static const void *kW12CardState = &kW12CardState;

static W12CardState *W12State(CALayer *L) {
    W12CardState *st = objc_getAssociatedObject(L, kW12CardState);
    if (!st) { st = [W12CardState new]; objc_setAssociatedObject(L, kW12CardState, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    return st;
}

// Remember the layer's ORIGINAL clipping/radius once, even if animations are restarted again and again.
static W12CardState *W12CardPrepare(CALayer *L) {
    W12CardState *st = W12State(L);
    if (!st.active) { st.masks = L.masksToBounds; st.radius = L.cornerRadius; st.group = L.allowsGroupOpacity; st.active = YES; }
    L.allowsGroupOpacity = NO;      // the scene is one remote layer: no offscreen pass needed for the fade
    st.gen++;
    L.masksToBounds = YES;
    return st;
}

// Clip off early (when the radius is already 0 the clip is invisible but costs an offscreen pass),
// then clean up; both steps are cancelled automatically if a newer animation started meanwhile.
static void W12CardFinishLater(CALayer *L, W12CardState *st, NSTimeInterval clipOffAfter, NSTimeInterval cleanupAfter) {
    NSUInteger g = st.gen;
    if (clipOffAfter > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(clipOffAfter * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (st.gen == g) L.masksToBounds = st.masks;
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(cleanupAfter * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (st.gen != g) return;
        [L removeAnimationForKey:@"w12.app.t"];
        [L removeAnimationForKey:@"w12.app.r"];
        [L removeAnimationForKey:@"w12.app.a"];
        L.masksToBounds = st.masks;
        L.cornerRadius = st.radius;
        L.allowsGroupOpacity = st.group;
        st.active = NO;
    });
}

static BOOL W12InFlight(CALayer *L) { return [L animationForKey:@"w12.app.t"] != nil && L.presentationLayer != nil; }
static NSTimer *gOpenTimer = nil;

// MARK: - Card engine (iOS 18-style open / close, modelled on the reference video)
//
// The app is one card. Going home it shrinks into the icon's square: the card is cropped (mask) to the icon's shape while it scales, the corners
// round off, the home screen sits behind a strong blur that clears while the card lands, and the icon pops (1.3x -> 1.0x). Opening is the
// same path backwards, with a perspective tilt (top edge leaning away) that relaxes as the card grows. Every value is pre-sampled from
// closed-form curves into dense keyframes, so the whole motion is ONE continuous movement that runs on the render server (no stop-and-go,
// and it keeps its pace even when the main thread is busy launching the app).

static CAKeyframeAnimation *W12Samp(NSString *kp, int n, double dur, id (^val)(double u)) {
    NSMutableArray *vals = [NSMutableArray arrayWithCapacity:n + 1], *times = [NSMutableArray arrayWithCapacity:n + 1];
    for (int i = 0; i <= n; i++) { double u = (double)i / n; [vals addObject:val(u)]; [times addObject:@(u)]; }
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:kp];
    a.values = vals; a.keyTimes = times; a.calculationMode = kCAAnimationLinear; a.duration = dur;
    return a;
}
static double W12Clamp01(double x) { return x < 0 ? 0 : (x > 1 ? 1 : x); }
static double W12Smooth(double a, double b, double x) { double t = W12Clamp01((x - a) / (b - a)); return t * t * (3 - 2 * t); }

static UIView *W12IconViewForBundle(NSString *bid) {
    if (!bid) return nil;
    for (UIView *v in W12HomeIconViews()) {
        id icon = W12Call(v, @selector(icon));
        id b = W12Call(icon, NSSelectorFromString(@"applicationBundleID"));
        if ([b isKindOfClass:[NSString class]] && [b isEqualToString:bid]) return v;
    }
    return nil;
}

// Home blur: a real blur (no tint) between the home screen and the card.
static UIVisualEffectView *W12MakeBlur(UIView *V) {
    UIView *sv = V.superview; if (!sv) return nil;
    UIVisualEffectView *bv = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleLight]];
    bv.userInteractionEnabled = NO;
    CGSize s = V.bounds.size;
    bv.frame = CGRectMake(V.center.x - s.width / 2, V.center.y - s.height / 2, s.width, s.height);
    for (UIView *t in bv.subviews) {                       // drop the style's milky overlay, keep the blur itself
        NSString *cn = NSStringFromClass([t class]);
        if ([cn containsString:@"Backdrop"] || t == bv.contentView) continue;
        t.backgroundColor = [UIColor clearColor];
    }
    bv.layer.opacity = 0;
    [sv insertSubview:bv belowSubview:V];
    return bv;
}

static void W12CardRun(UIView *V, BOOL opening, BOOL has, CGRect ir, NSString *bid, double speed) {
    CALayer *L = V.layer; UIView *sv = V.superview; if (!sv || !V.window) return;
    CGSize S0 = V.bounds.size; double W = S0.width, H = S0.height;
    CGPoint P = L.position;
    CGPoint C = P; double Sicon = 0.34, cropEnd = H, iconRad = 0.225;
    if (has) {
        C = [V.window convertPoint:CGPointMake(CGRectGetMidX(ir), CGRectGetMidY(ir)) toView:sv];
        Sicon = MAX(0.08, ir.size.width / W * 1.04);
        cropEnd = W;                                                    // the icon is square: the card is cropped to a square of full width
        iconRad = 0.225;
    }
    double Rfull = W12Double(@"appCorner", 40, 8, 90);
    double tilt = W12Double(@"appTilt", 1.0, 0.0, 5.0);
    double offX = MAX(-1.0, MIN(1.0, (C.x - P.x) / (W * 0.5)));       // -1 = icon at the far left, +1 = far right
    double offY = MAX(-1.0, MIN(1.0, (C.y - P.y) / (H * 0.5)));
    double dirY = (fabs(offX) < 0.12) ? 0.0 : offX;                  // icon on the right -> the card swings out of / into the right side

    // where the card is right now (interrupting an animation in flight)
    BOOL live = W12InFlight(L);
    double q0 = opening ? 1.0 : 0.0, q1 = opening ? 0.0 : 1.0, a0 = opening ? 0.0 : 1.0;
    if (live) {
        CALayer *pl = L.presentationLayer;
        double sNow = pl ? pl.transform.m11 : 1.0;
        double qNow = W12Clamp01((1.0 - sNow) / MAX(0.05, 1.0 - Sicon));
        q0 = qNow; a0 = pl ? pl.opacity : a0;
    }
    double dist = fabs(q1 - q0);
    double dur = (opening ? 0.44 : 0.34) / speed * MAX(0.45, dist);
    int N = MAX(14, (int)ceil(dur * 60));

    CGFloat orad = 0;
    W12CardState *st = W12State(L); st.gen++; NSUInteger gen = st.gen;
    if (!st.active) { st.masks = L.masksToBounds; st.radius = L.cornerRadius; st.group = L.allowsGroupOpacity; st.active = YES; }
    orad = st.radius;
    L.allowsGroupOpacity = NO;

    // q: 0 = full screen card, 1 = icon. Curves per direction.
    double (^qAt)(double) = ^double(double u) {
        double e = opening ? (1 - pow(1 - u, 3.6)) : (1 - pow(1 - u, 1.30));
        return q0 + (q1 - q0) * e;
    };
    double (^scaleAt)(double) = ^double(double q) { return 1 + (Sicon - 1) * q; };
    double (^cropAt)(double) = ^double(double q) { return H + (cropEnd - H) * W12Smooth(0.30, 1.0, q); };
    double tiltK = (opening ? 1.0 : 0.45) * tilt;

    CAKeyframeAnimation *tr = W12Samp(@"transform", N, dur, ^id(double u) {
        double q = qAt(u), S = scaleAt(q), crop = cropAt(q);
        double qx = opening ? q : q;                                  // same path both ways
        double vx = P.x + (C.x - P.x) * qx, vy = P.y + (C.y - P.y) * q;           // where the middle of the visible (cropped) card should be
        double tx = vx - P.x, ty = vy - P.y - (crop / 2 - H / 2) * S;
        double k = pow(q, 1.15) * tiltK;
        CATransform3D t = CATransform3DIdentity; t.m34 = -1.0 / 900.0;
        t = CATransform3DTranslate(t, tx, ty, 0);
        t = CATransform3DScale(t, S, S, 1);
        t = CATransform3DRotate(t, (0.18 + 0.06 * offY) * k, 1, 0, 0);                            // top edge leans away: narrower top, wider bottom
        t = CATransform3DRotate(t, -0.26 * k * dirY, 0, 1, 0);
        t = CATransform3DRotate(t, 0.07 * k * dirY, 0, 0, 1);
        return [NSValue valueWithCATransform3D:t];
    });
    CAKeyframeAnimation *al = W12Samp(@"opacity", N, dur, ^id(double u) {
        double q = qAt(u), a;
        if (opening) a = a0 + (1 - a0) * W12Smooth(0.0, 0.16, u);
        else a = (q < 0.80) ? 1.0 : 1.0 - W12Smooth(0.80, 1.0, q);
        return @(a);
    });
    // crop mask (local coordinates, top aligned) + corner radius that keeps its visible size while the card scales
    CALayer *mk = [CALayer layer]; mk.backgroundColor = [UIColor blackColor].CGColor; mk.anchorPoint = CGPointZero; mk.position = CGPointZero;
    double qEnd = opening ? 0.0 : 1.0;
    mk.bounds = CGRectMake(0, 0, W, cropAt(qEnd));
    double (^radAt)(double) = ^double(double q) {
        double S = scaleAt(q), crop = cropAt(q);
        double vis = Rfull * W12Smooth(0.0, 0.10, q) * (1 - W12Smooth(0.35, 1.0, q)) + iconRad * (has ? ir.size.width : 60) * W12Smooth(0.35, 1.0, q);
        if (q < 0.0001) vis = (opening ? orad : orad);
        if (q > 0.0001 && q < 0.10) vis = MAX(vis, orad);
        return MIN(vis / S, MIN(W, crop) / 2);
    };
    mk.cornerRadius = (qEnd < 0.001) ? orad : radAt(qEnd);
    CAKeyframeAnimation *mb = W12Samp(@"bounds", N, dur, ^id(double u) { return [NSValue valueWithCGRect:CGRectMake(0, 0, W, cropAt(qAt(u)))]; });
    CAKeyframeAnimation *mr = W12Samp(@"cornerRadius", N, dur, ^id(double u) { return @(radAt(qAt(u))); });
    for (CAAnimation *a in @[tr, al]) { a.fillMode = opening ? kCAFillModeBackwards : kCAFillModeForwards; a.removedOnCompletion = NO; }
    for (CAAnimation *a in @[mb, mr]) { a.fillMode = kCAFillModeBoth; a.removedOnCompletion = NO; }
    L.mask = mk;
    [mk addAnimation:mb forKey:@"w12.mask.b"]; [mk addAnimation:mr forKey:@"w12.mask.r"];
    [L addAnimation:tr forKey:@"w12.app.t"];
    [L addAnimation:al forKey:@"w12.app.a"];

    // blurred home screen behind the card
    UIVisualEffectView *bv = nil;
    if (W12Bool(@"appExp", NO) && W12Bool(@"appBlur", YES)) {
        bv = W12MakeBlur(V);
        if (bv) {
            CAKeyframeAnimation *ba = W12Samp(@"opacity", N, dur, ^id(double u) {
                double q = qAt(u), b;
                if (opening) b = W12Smooth(0.0, 0.22, u) * (1 - W12Smooth(0.62, 1.0, u));
                else b = 1 - W12Smooth(0.42, 0.97, q);
                return @(b);
            });
            ba.fillMode = kCAFillModeBoth; ba.removedOnCompletion = NO;
            bv.layer.opacity = 0;
            [bv.layer addAnimation:ba forKey:@"w12.blur"];
        }
    }
    // the icon pops (bigger -> normal) as the card lands in it / starts from it
    UIView *iv = (has && bid) ? W12IconViewForBundle(bid) : nil;
    if (iv) {
        CALayer *IL = iv.layer;
        CAKeyframeAnimation *pop;
        if (opening) {
            pop = W12Samp(@"transform.scale", 24, 0.42 / speed, ^id(double u) { return @(1.0 + 0.24 * sin(M_PI * pow(u, 0.5)) * (1 - u)); });
            pop.beginTime = [IL convertTime:CACurrentMediaTime() fromLayer:nil];
        } else {
            pop = W12Samp(@"transform.scale", 28, 0.34 / speed, ^id(double u) { double e = exp(-5.2 * u) * cos(7.5 * u); return @(1.0 + 0.30 * e); });   // 1.3 -> 1.0 with a soft settle
            pop.beginTime = [IL convertTime:CACurrentMediaTime() fromLayer:nil] + dur * 0.80;
            pop.fillMode = kCAFillModeBackwards;
        }
        [IL addAnimation:pop forKey:@"w12.pop"];
    }
    __weak UIVisualEffectView *wbv = bv;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((dur + 0.05) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIVisualEffectView *b2 = wbv; [b2 removeFromSuperview];
        W12CardState *s2 = W12State(L);
        if (s2.gen != gen) return;                                  // a newer animation took over
        [L removeAnimationForKey:@"w12.app.t"];
        [L removeAnimationForKey:@"w12.app.a"];
        L.mask = nil;
        L.allowsGroupOpacity = s2.group;
        s2.active = NO;
    });
}

// Target (card) geometry in V.superview space for a given icon rect.
static void W12CardTarget(UIView *V, BOOL has, CGRect r, CGFloat *tx, CGFloat *ty, CGFloat *sc) {
    UIView *sv = V.superview;
    if (has) {
        CGPoint c = [V.window convertPoint:CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)) toView:sv];
        *tx = c.x - V.layer.position.x; *ty = c.y - V.layer.position.y;
        *sc = MAX(0.08, r.size.width / V.bounds.size.width * 1.1);
    } else {                                   // notification / Spotlight: grow from the middle
        *tx = 0; *ty = 0; *sc = 0.55;
    }
}

// Direction factor from the icon offset: -1..1, soft in the middle, full strength towards the edges.
static double W12DirK(double off, double span) {
    double v = off / (span * 0.34);
    double a = fabs(v); if (a > 1.0) a = 1.0;
    double k = pow(a, 0.85) * 1.25; if (k > 1.25) k = 1.25;
    return v < 0 ? -k : k;
}

static BOOL W12IslandFlyInfo(NSString *bid, CGRect *out);
static void W12IslandArrive(void);
static void W12FaceTick(void);
static BOOL gFidBusy;
static UIView *gFidCard, *gFidCV, *gFidBV, *gFidLock;
static void W12FacePlay(BOOL test);
static double W12FaceUnlockWait(void);

// Leaving an app that has a live activity on the island (swipe up / home): the card narrows, flattens into the capsule and the island bumps.
static void W12FlyRun(UIView *V, CGRect ir, double speed) {
    CALayer *L = V.layer; UIView *sv = V.superview; if (!sv || !V.window) return;
    double W = V.bounds.size.width, H = V.bounds.size.height;
    CGPoint P = L.position;
    CGPoint C = [V.window convertPoint:CGPointMake(CGRectGetMidX(ir), CGRectGetMidY(ir)) toView:sv];
    double sx = ir.size.width / W, sy = ir.size.height / H;
    double dur = 0.46 / speed; int N = MAX(18, (int)ceil(dur * 60));
    W12CardState *st = W12CardPrepare(L); CGFloat orad = st.radius;
    double (^q)(double) = ^double(double u) { return 1 - pow(1 - u, 2.2); };
    CAKeyframeAnimation *tr = W12Samp(@"transform", N, dur, ^id(double u) {
        double e = q(u), ey = pow(e, 1.35);
        CATransform3D t = CATransform3DMakeTranslation((C.x - P.x) * e, (C.y - P.y) * e, 0);
        t = CATransform3DScale(t, 1 + (sx - 1) * e, 1 + (sy - 1) * ey, 1);
        return [NSValue valueWithCATransform3D:t];
    });
    CAKeyframeAnimation *rad = W12Samp(@"cornerRadius", N, dur, ^id(double u) {
        double e = q(u);
        return @(orad + (MIN(W, H) / 2 - orad) * W12Smooth(0.0, 0.9, e));
    });
    CAKeyframeAnimation *al = W12Samp(@"opacity", N, dur, ^id(double u) { return @(1.0 - W12Smooth(0.74, 1.0, q(u))); });
    for (CAAnimation *a in @[tr, rad, al]) { a.fillMode = kCAFillModeForwards; a.removedOnCompletion = NO; }
    [L addAnimation:tr forKey:@"w12.app.t"];
    [L addAnimation:rad forKey:@"w12.app.r"];
    [L addAnimation:al forKey:@"w12.app.a"];
    W12CardFinishLater(L, st, 0, dur + 0.03);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dur * 0.86 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ W12IslandArrive(); });
}

static NSString *gLastFrontBid; static CFTimeInterval gLastFrontTime;
static UIView *W12FindCoverSheetView(void);
// Lock screen / cover sheet on screen: the app-close card animation must never run then (it would drag the cover sheet away).
static BOOL W12UILocked(void) {
    id m = W12Call(NSClassFromString(@"SBLockScreenManager"), @selector(sharedInstance));
    if (!m) return NO;
    for (NSString *sn in @[@"isUILocked", @"isLockScreenVisible", @"isLockScreenActive"]) {
        SEL sel = NSSelectorFromString(sn);
        if ([m respondsToSelector:sel] && ((BOOL (*)(id, SEL))objc_msgSend)(m, sel)) return YES;
    }
    return NO;
}
static BOOL W12ViewIsCover(UIView *V) {
    UIView *cs = W12FindCoverSheetView();
    return cs && V && (V == cs || [V isDescendantOfView:cs] || [cs isDescendantOfView:V]);
}
static void W12AppClose(void) {
    if (!W12Bool(@"enabled", YES) || !W12Bool(@"appanim", YES) || !W12Bool(@"appClose", YES)) { W12_LOG(@"close: disabled in prefs"); return; }
    if (UIAccessibilityIsReduceMotionEnabled()) { W12_LOG(@"close: reduce motion on"); return; }
    CFTimeInterval now = CACurrentMediaTime();
    gHomeDelay = 0;
    if (W12UILocked()) { W12_LOG(@"close: device locked, skipped"); return; }
    if (now - gLastClose < 0.12) return;      // several triggers can fire for one gesture: only the first starts the animation (short, so fast open/close spam still works)
    [gOpenTimer invalidate]; gOpenTimer = nil;           // closing right after opening: stop waiting for the old open
    id app = W12FrontApp();
    NSString *bid = app ? W12Call(app, @selector(bundleIdentifier)) : nil;
    if (!bid && gLastFrontBid && now - gLastFrontTime < 2.5) bid = gLastFrontBid;   // gesture tweaks drop the front app at swipe start
    if (!bid) { W12_LOG(@"close: no frontmost app"); return; }
    UIView *V = W12SceneFor(bid);
    if (V && W12ViewIsCover(V)) { W12_LOG(@"close: scene view is the cover sheet, skipped"); gSceneCache = nil; return; }
    if (!V || !V.superview || !V.window) { W12_LOG(@"close: no scene view for %@", bid); W12DumpAllWindows("close"); return; }
    gLastClose = now;

    double speed = W12Double(@"speed", 1.0, 0.6, 1.6);
    if (W12Excluded(bid)) { W12_LOG(@"close: %@ is excluded", bid); gLastClose = 0; return; }
    CGRect r = CGRectZero; BOOL has = W12IconRectForBundle(bid, V.window, &r);
    { CGRect fir; if (W12IslandFlyInfo(bid, &fir)) {
        W12_LOG(@"close: %@ flies into the island", bid);
        W12FlyRun(V, fir, speed);
        gHomeDelay = 0.46 / speed * 0.45;
        return;
    } }
    if (W12Bool(@"appExp", NO)) {
        W12CardRun(V, NO, has, r, bid, speed);
        gHomeDelay = -1;   // experimental engine pops the icon itself, skip the old settle
    } else {
    CGFloat tx, ty, sc; W12CardTarget(V, has, r, &tx, &ty, &sc);
    double dur = 0.46 / speed;
    double R = W12Double(@"appCorner", 40, 8, 90);
    double tilt = W12Double(@"appTilt", 1.0, 0.0, 5.0);
    int axis = (int)W12Double(@"appTiltAxis", 2, 0, 2);          // 0 = side to side, 1 = top to bottom, 2 = both
    double ax = (axis == 0) ? 0.0 : (axis == 1 ? 1.4 : 1.0);     // rotation around the horizontal axis (top/bottom)
    double ay = (axis == 1) ? 0.0 : (axis == 0 ? 1.3 : 1.0);     // rotation around the vertical axis (left/right)
    double dirX = W12DirK(ty, V.bounds.size.height);               // continuous: icon high up -> tilt top/bottom, mid-height -> almost none
    double dirY = W12DirK(tx, V.bounds.size.width);                // icon far left/right -> strong side-to-side lean, centre -> none
    CALayer *L = V.layer;
    BOOL live = W12InFlight(L);                                   // spam: start from what is on screen right now
    CATransform3D t0 = live ? L.presentationLayer.transform : W12T(0, 0, 1, 0, 0);
    CGFloat a0 = live ? L.presentationLayer.opacity : 1.0;
    CATransform3D t1 = W12T(0, -10, 0.92, 0.07 * tilt * ax * dirX, -0.09 * tilt * ay * dirY);
    CATransform3D t2 = W12T(tx, ty, sc, 0.0, 0.0);
    CGFloat r0 = live ? L.presentationLayer.cornerRadius : L.cornerRadius;

    W12CardState *st = W12CardPrepare(L);
    CGFloat orad = st.radius;
    if (!live) r0 = orad;

    CAKeyframeAnimation *tr = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
    tr.values = @[[NSValue valueWithCATransform3D:t0], [NSValue valueWithCATransform3D:t1], [NSValue valueWithCATransform3D:t2]];
    tr.keyTimes = @[@0, @0.30, @1];
    tr.timingFunctions = @[[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut],
                           [CAMediaTimingFunction functionWithControlPoints:0.5 :0.0 :0.2 :1.0]];
    CAKeyframeAnimation *rad = [CAKeyframeAnimation animationWithKeyPath:@"cornerRadius"];
    rad.values = @[@(r0), @(R), @(MIN(R * 1.5, 16.0 / sc))];
    rad.keyTimes = @[@0, @0.30, @1];
    CAKeyframeAnimation *al = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    al.values = @[@(a0), @1, @0]; al.keyTimes = @[@0, @0.5, @1];
    for (CAAnimation *a in @[tr, rad, al]) {
        a.duration = dur; a.fillMode = kCAFillModeForwards; a.removedOnCompletion = NO;
    }
    [L addAnimation:tr forKey:@"w12.app.t"];
    [L addAnimation:rad forKey:@"w12.app.r"];
    [L addAnimation:al forKey:@"w12.app.a"];
    W12CardFinishLater(L, st, 0, dur + 0.03);
    gHomeDelay = dur * 0.45;                 // home icons start settling while the card is shrinking
    }
}

static NSString *gPendingBundle = nil; static CFTimeInterval gPendingBundleTime = 0;

static void W12AppOpenNow(UIView *V, BOOL has, CGRect r) {
    { id fa = W12FrontApp(); id fb = W12Call(fa, @selector(bundleIdentifier));
      if ([fb isKindOfClass:[NSString class]] && W12Excluded(fb)) { W12_LOG(@"open: %@ is excluded", fb); return; } }
    double speed = W12Double(@"speed", 1.0, 0.6, 1.6);
    if (!has) {   // opened from Spotlight / notification / hook miss: find the app's own icon on Home
        NSString *bid = (gPendingBundle && CACurrentMediaTime() - gPendingBundleTime < 2.0) ? gPendingBundle : nil;
        if (!bid) { id app = W12FrontApp(); id b = W12Call(app, @selector(bundleIdentifier)); if ([b isKindOfClass:[NSString class]]) bid = b; }
        has = W12IconRectForBundle(bid, V.window, &r);
        W12_LOG(@"open: icon rect via bundle %@ found=%d", bid, has);
    }
    if (has) {      // remember where the icon is: the close animation starts without scanning the home screen
        id fa2 = W12FrontApp(); id fb2 = W12Call(fa2, @selector(bundleIdentifier));
        if ([fb2 isKindOfClass:[NSString class]]) {
            if (!gIconRectCache) gIconRectCache = [NSMutableDictionary dictionary];
            gIconRectCache[fb2] = @[[NSValue valueWithCGRect:r], @(CACurrentMediaTime())];
        }
    }
    if (W12Bool(@"appExp", NO)) {
    NSString *obid = nil; { id fa3 = W12FrontApp(); id b3 = W12Call(fa3, @selector(bundleIdentifier)); if ([b3 isKindOfClass:[NSString class]]) obid = b3; }
    if (!obid && gPendingBundle && CACurrentMediaTime() - gPendingBundleTime < 2.0) obid = gPendingBundle;
    W12CardRun(V, YES, has, r, obid, speed);
    } else {
    CGFloat tx, ty, sc; W12CardTarget(V, has, r, &tx, &ty, &sc);
    // icon -> slightly smaller tilted card -> full screen. Ease-out only, so it never bounces.
    double R = W12Double(@"appCorner", 40, 8, 90);
    double tilt = W12Double(@"appTilt", 1.0, 0.0, 5.0);
    int axis = (int)W12Double(@"appTiltAxis", 2, 0, 2);
    double ax = (axis == 0) ? 0.0 : (axis == 1 ? 1.4 : 1.0);
    double ay = (axis == 1) ? 0.0 : (axis == 0 ? 1.3 : 1.0);
    double dirX = W12DirK(ty, V.bounds.size.height);               // continuous: icon high up -> tilt top/bottom, mid-height -> almost none
    double dirY = W12DirK(tx, V.bounds.size.width);                // icon far left/right -> strong side-to-side lean, centre -> none
    CALayer *L = V.layer;
    BOOL live = W12InFlight(L);
    CATransform3D t0 = live ? L.presentationLayer.transform : W12T(tx, ty, sc, 0.12 * tilt * ax * dirX, -0.10 * tilt * ay * dirY);
    CGFloat a0 = live ? L.presentationLayer.opacity : 0.0;
    CGFloat r0 = live ? L.presentationLayer.cornerRadius : MIN(R * 1.5, 20.0 / sc);
    CATransform3D t1 = W12T(0, -6, 0.94, 0.06 * tilt * ax * dirX, -0.05 * tilt * ay * dirY);
    CATransform3D t2 = W12T(0, 0, 1, 0, 0);

    W12CardState *st = W12CardPrepare(L);
    CGFloat orad = st.radius;
    double dur = 0.5 / speed;

    CAKeyframeAnimation *tr = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
    tr.values = @[[NSValue valueWithCATransform3D:t0], [NSValue valueWithCATransform3D:t1], [NSValue valueWithCATransform3D:t2]];
    tr.keyTimes = @[@0, @0.55, @1];
    tr.timingFunctions = @[[CAMediaTimingFunction functionWithControlPoints:0.15 :0.85 :0.25 :1.0],
                           [CAMediaTimingFunction functionWithControlPoints:0.2 :0.8 :0.3 :1.0]];
    // the corner radius reaches its final value at 80% of the time, so the (costly) clip can be dropped early
    CAKeyframeAnimation *rad = [CAKeyframeAnimation animationWithKeyPath:@"cornerRadius"];
    rad.values = @[@(r0), @(R), @(orad), @(orad)];
    rad.keyTimes = @[@0, @0.4, @0.8, @1];
    CAKeyframeAnimation *al = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    al.values = @[@(a0), @1, @1]; al.keyTimes = @[@0, @0.2, @1];

    for (CAAnimation *a in @[tr, rad, al]) { a.duration = dur; a.fillMode = kCAFillModeBackwards; }
    [L addAnimation:tr forKey:@"w12.app.t"];
    [L addAnimation:rad forKey:@"w12.app.r"];
    [L addAnimation:al forKey:@"w12.app.a"];
    W12CardFinishLater(L, st, dur * 0.82, dur + 0.03);
    }
}

// The scene view only exists a few frames after the tap, so poll (max 1.2 s) until it appears.
static void W12AppOpenStart(void) {
    if (!W12Bool(@"enabled", YES) || !W12Bool(@"appanim", YES) || UIAccessibilityIsReduceMotionEnabled()) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gLastOpenStart < 0.1) return;
    gLastOpenStart = now;
    BOOL has = gHasLaunchRect && (now - gLaunchRectTime) < 1.0;
    CGRect r = gLaunchRect;
    gHasLaunchRect = NO;
    [gOpenTimer invalidate];                              // a newer tap replaces the old wait
    __weak NSTimer *weakTimer = nil;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.012 repeats:YES block:^(NSTimer *t) {
        if (CACurrentMediaTime() - now > 1.2) { [t invalidate]; W12_LOG(@"open: timeout, scene not found (frontApp=%d)", W12FrontApp() != nil); W12DumpAllWindows("open"); return; }
        if (!W12FrontApp()) return;                       // cheap check first; the view scan is the expensive part
        static CFTimeInterval lastScan = 0; CFTimeInterval tn = CACurrentMediaTime();
        if (tn - lastScan < 0.03) return;                 // at most ~30 scans per second: the scan must never steal frames from the launch itself
        lastScan = tn;
        UIView *V = W12FindSceneView();
        if (V && V.superview && V.window) {
            { id fa = W12FrontApp(); id fb = W12Call(fa, @selector(bundleIdentifier)); if ([fb isKindOfClass:[NSString class]]) { gSceneCache = V; gSceneCacheBid = [fb copy]; } }
            [t invalidate];
            W12_LOG(@"open: animating %@ hasRect=%d", NSStringFromClass([V class]), has);
            W12AppOpenNow(V, has, r);
        }
    }];
    (void)weakTimer;
    gOpenTimer = timer;
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}


// MARK: - Lock screen: bottom corners curve while the sheet slides up (iOS 26 look)

static UIView *W12FindCoverSheetView(void) {
    CGSize sz = [UIScreen mainScreen].bounds.size;
    UIView *best = nil; int bestScore = 0;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        NSString *wn = NSStringFromClass([w class]);
        if (w.hidden || !([wn containsString:@"CoverSheet"] || [wn containsString:@"DashBoard"] || [wn containsString:@"LockScreen"])) continue;
        NSMutableArray *queue = [NSMutableArray arrayWithObject:w];
        int depth = 0;
        while (queue.count && depth < 5) {
            NSMutableArray *next = [NSMutableArray array];
            for (UIView *v in queue) {
                NSString *cn = NSStringFromClass([v class]);
                CGSize b = v.bounds.size;
                BOOL big = MAX(b.width, b.height) >= 0.85 * MAX(sz.width, sz.height) &&
                           MIN(b.width, b.height) >= 0.85 * MIN(sz.width, sz.height);
                if (big && v != (UIView *)w) {
                    int sc = [cn containsString:@"SlidingView"] ? 4 : ([cn containsString:@"DashBoardView"] || [cn containsString:@"CoverSheetView"]) ? 3 : 1;
                    if (sc > bestScore) { bestScore = sc; best = v; }
                }
                [next addObjectsFromArray:v.subviews];
            }
            queue = next; depth++;
        }
        if (!best) best = w.rootViewController.view;
    }
    return best;
}


// ---- Pan-synchronous glass/corner effect: follows the cover sheet frame by frame while you drag it up.

static CFTimeInterval gWatcherFrame = 0;     // last time the watcher drove the effect

@interface W12Ticker : NSObject
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, weak) UIView *view;
@property (nonatomic) BOOL modified;
@property (nonatomic) CGFloat oRadius;
@property (nonatomic) BOOL oMasks;
@property (nonatomic) CACornerMask oMask;
@property (nonatomic) float oOpacity;
@end

@implementation W12Ticker
- (void)start {
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    self.link.paused = YES;
    [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    NSTimer *t = [NSTimer timerWithTimeInterval:0.5 target:self selector:@selector(poll) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}
- (double)progress {
    UIView *V = self.view;
    if (!V || !V.window) return -1;
    CALayer *pl = V.layer.presentationLayer ?: V.layer;
    CGRect r = [pl convertRect:pl.bounds toLayer:V.window.layer];
    CGFloat h = [UIScreen mainScreen].bounds.size.height;
    return MAX(0, MIN(1.2, -r.origin.y / h));
}
- (void)poll {
    BOOL on = NO;   // lock-screen glass removed
    UIView *v = on ? W12FindCoverSheetView() : nil;
    if (v != self.view) { [self restore]; self.view = v; if (v) W12_LOG(@"watcher: tracking %@", NSStringFromClass([v class])); }
    double p = [self progress];
    BOOL run = on && v && p >= 0 && p < 0.98;       // idle (sheet fully gone) => no per-frame work
    self.link.paused = !run;
    if (!run) [self restore];
}
- (void)restore {
    UIView *V = self.view;
    if (V && self.modified) {
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        V.layer.cornerRadius = self.oRadius; V.layer.masksToBounds = self.oMasks;
        V.layer.maskedCorners = self.oMask; V.layer.opacity = self.oOpacity;
        [CATransaction commit];
    }
    self.modified = NO;
}
- (void)tick:(CADisplayLink *)l {
    UIView *V = self.view;
    double p = [self progress];
    if (!V || p < 0) return;
    if (p < 0.004) { [self restore]; return; }
    CALayer *L = V.layer;
    if (!self.modified) {
        self.oRadius = L.cornerRadius; self.oMasks = L.masksToBounds; self.oMask = L.maskedCorners; self.oOpacity = L.opacity;
        self.modified = YES;
    }
    double R = W12Double(@"cornerRadius", 46, 10, 70);
    double glass = W12Double(@"coverAlpha", 0.6, 0.25, 1.0);
    double kc = MIN(1.0, p / 0.05);              // corners reach full radius after 5% of the travel
    double ka = MIN(1.0, p / 0.12);              // glass look after 12%
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    L.maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    L.masksToBounds = YES;
    L.cornerRadius = R * kc;
    L.opacity = 1.0 - (1.0 - glass) * ka;
    [CATransaction commit];
    gWatcherFrame = CACurrentMediaTime();
}
@end

static W12Ticker *gTicker;

// ---- Leave-app watcher: catches closing paths we have no hook for (HomeGesture, other gesture tweaks, ...).
// While an app is frontmost it compares the app scene's on-screen frame with the full screen. When the system starts
// moving/scaling it (someone is leaving the app), the card close animation is started once.

@interface W12CloseWatch : NSObject
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, weak) UIView *view;
@property (nonatomic) BOOL armed;
@property (nonatomic) int calm;
@property (nonatomic) BOOL following;       // the system is moving the scene (home gesture): we only follow with the corners, never add a second motion
@property (nonatomic) CGFloat fRadius;
@property (nonatomic) BOOL fMasks;
@property (nonatomic, weak) CALayer *fLayer;
@end

@implementation W12CloseWatch
- (void)start {
    self.armed = YES;
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    self.link.preferredFramesPerSecond = 30;     // detection only: half the per-frame work of the leave-watcher
    self.link.paused = YES;
    [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    NSTimer *t = [NSTimer timerWithTimeInterval:0.2 target:self selector:@selector(poll) userInfo:nil repeats:YES];
    t.tolerance = 0.05;
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}
- (void)poll {
    BOOL on = W12Bool(@"enabled", YES) && W12Bool(@"appanim", YES) && W12Bool(@"appClose", YES);
    id app = on ? W12FrontApp() : nil;
    static BOOL hadApp = NO;
    if (!!app != hadApp) { hadApp = !!app; W12_LOG(@"leave-watch: front app %@ (locked=%d, last=%@, armed=%d)", app ? @"appeared" : @"LOST", W12UILocked(), gLastFrontBid, self.armed); }
    if (app) { gLastFrontBid = [W12Call(app, @selector(bundleIdentifier)) copy]; gLastFrontTime = CACurrentMediaTime(); }
    BOOL grace = on && !W12UILocked() && gLastFrontBid && CACurrentMediaTime() - gLastFrontTime < 1.5;   // keep watching a moment after the app lost focus
    if (gLastFrontBid && W12Excluded(gLastFrontBid)) { app = nil; grace = NO; }
    if (!app && !grace) { self.view = nil; self.armed = YES; self.link.paused = YES; return; }
    UIView *V = self.view;
    if (!V || !V.window || V.hidden) { V = W12FindSceneView(); self.view = V; if (V) W12_LOG(@"leave-watch: tracking %@", NSStringFromClass([V class])); }
    self.link.paused = (V == nil);
}
- (void)followEnd {
    if (!self.following) return;
    self.following = NO;
    CALayer *L = self.fLayer;
    if (L) { [CATransaction begin]; [CATransaction setDisableActions:YES]; L.cornerRadius = self.fRadius; L.masksToBounds = self.fMasks; [CATransaction commit]; }
    self.fLayer = nil;
    self.link.preferredFramesPerSecond = 30;
}
- (void)tick:(CADisplayLink *)l {
    UIView *V = self.view;
    if (!V || !V.window) { [self followEnd]; return; }
    if (W12UILocked() || W12ViewIsCover(V)) { [self followEnd]; self.view = nil; return; }
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gLastClose < 0.5 || [V.layer animationForKey:@"w12.app.t"]) { self.calm = 0; [self followEnd]; return; }   // our own timed close (home button) is running
    BOOL animating = NO;    // presentationLayer copies the layer tree: only pay for it when something up the chain really animates
    for (CALayer *a = V.layer; a; a = a.superlayer) if (a.animationKeys.count) { animating = YES; break; }
    CALayer *pl = animating ? (V.layer.presentationLayer ?: V.layer) : V.layer;
    CGRect r = [pl convertRect:pl.bounds toLayer:V.window.layer];
    CGSize sz = [UIScreen mainScreen].bounds.size;
    BOOL moved = fabs(r.origin.x) > 3 || fabs(r.origin.y) > 3 || fabs(r.size.width - sz.width) > 4 || fabs(r.size.height - sz.height) > 4;
    if (!moved) { [self followEnd]; if (++self.calm > 20) self.armed = YES; return; }
    self.calm = 0;
    if (!self.following) {
        if (!self.armed || now - gLastOpenStart < 1.2) return;     // not while the app is still opening
        self.armed = NO;
        W12CardState *st = W12State(V.layer);
        if (st.active) return;                                      // an old card animation is still being cleaned up
        self.following = YES; self.fLayer = V.layer; self.fRadius = V.layer.cornerRadius; self.fMasks = V.layer.masksToBounds;
        self.link.preferredFramesPerSecond = 60;
        W12_LOG(@"leave-watch: scene moved (%.0f,%.0f %.0fx%.0f) -> following the system motion", r.origin.x, r.origin.y, r.size.width, r.size.height);
    }
    // corners follow how far the card has shrunk: sharp when full screen, fully rounded after ~10% shrink
    double R = W12Double(@"appCorner", 40, 8, 90);
    CGFloat scale = MIN(r.size.width / sz.width, r.size.height / sz.height);
    double p = MAX(0.0, MIN(1.0, (1.0 - scale) / 0.10));
    p = MAX(p, MIN(1.0, fabs(r.origin.y) / (0.08 * sz.height)));
    CALayer *L = V.layer;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    L.masksToBounds = YES; L.cornerRadius = MAX(self.fRadius, R * p);
    [CATransaction commit];
}
@end

static W12CloseWatch *gCloseWatch;

static void W12CoverCorners(void) {
    return;   // lock-screen glass removed
    if (!W12Bool(@"enabled", YES)) return;
    if (UIAccessibilityIsReduceMotionEnabled()) return;
    if (CACurrentMediaTime() - gWatcherFrame < 1.5) return;   // the pan-synchronous watcher is already driving it
    UIView *V = W12FindCoverSheetView();
    if (!V) { W12_LOG(@"corners: cover sheet view not found"); W12DumpAllWindows("corners"); return; }
    W12_LOG(@"corners: using %@", NSStringFromClass([V class]));
    CALayer *L = V.layer;
    BOOL om = L.masksToBounds; CGFloat orad = L.cornerRadius; CACornerMask omask = L.maskedCorners;
    L.maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    L.masksToBounds = YES;
    double speed = W12Double(@"speed", 1.0, 0.6, 1.6);
    double R = W12Double(@"cornerRadius", 46, 10, 70);
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"cornerRadius"];
    a.fromValue = @(orad); a.toValue = @(R);
    a.duration = 0.18 / speed; a.fillMode = kCAFillModeForwards; a.removedOnCompletion = NO;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [L addAnimation:a forKey:@"w12.cover.r"];

    // Glass look: the sheet turns translucent while it lifts, so Home shows through.
    double glass = W12Double(@"coverAlpha", 0.6, 0.25, 1.0);
    if (glass < 0.99) {
        CABasicAnimation *g = [CABasicAnimation animationWithKeyPath:@"opacity"];
        g.fromValue = @(L.opacity); g.toValue = @(glass);
        g.duration = 0.22 / speed; g.fillMode = kCAFillModeForwards; g.removedOnCompletion = NO;
        g.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [L addAnimation:g forKey:@"w12.cover.a"];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [L removeAnimationForKey:@"w12.cover.r"];
        [L removeAnimationForKey:@"w12.cover.a"];
        L.cornerRadius = orad; L.masksToBounds = om; L.maskedCorners = omask;
    });
}


// MARK: - Fake Dynamic Island: a static black pill, with a thin grey outline when the background behind it is black

@interface W12IslandWindow : UIWindow
@property (nonatomic, weak) UIView *pillRef, *pill2Ref;
@property (nonatomic) BOOL fullHit;                  // expanded card open: a tap anywhere closes it
@end
static CGFloat W12IslandBorderW(void) { return (CGFloat)W12Double(@"islandBorderW", 0.75, 0.25, 3.0); }
@implementation W12IslandWindow
// Never steals touches, except on the pill itself while it shows a live activity (tap = open that app).
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.fullHit) return YES;
    for (UIView *p in @[self.pillRef ?: [NSNull null], self.pill2Ref ?: [NSNull null]]) {
        if (![p isKindOfClass:[UIView class]]) continue;
        if (!p.userInteractionEnabled || p.hidden || p.alpha < 0.05 || !p.superview || p.window != self) continue;
        CGPoint q = [self convertPoint:point toView:p.superview];
        if (CGRectContainsPoint(CGRectInset(p.frame, -6, -6), q)) return YES;
    }
    return NO;
}
@end

#define W12_ORANGE [UIColor colorWithRed:1.0 green:0.62 blue:0.04 alpha:1]
#define W12_RED    [UIColor colorWithRed:1.0 green:0.23 blue:0.19 alpha:1]
#define W12_GREEN  [UIColor colorWithRed:0.19 green:0.82 blue:0.35 alpha:1]

// The island pill: black capsule with an icon on the left and a time / waveform on the right.
// A text view other tweaks cannot restyle: a plain UIView (not a UILabel) that draws its own text with the font it was locked to.
@interface W12FixedLabel : UIView
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) UIColor *textColor;
@property (nonatomic) NSTextAlignment textAlignment;
@property (nonatomic, strong) UIFont *font;
@property (nonatomic) NSInteger numberOfLines;
@property (nonatomic) NSLineBreakMode lineBreakMode;
@property (nonatomic) BOOL adjustsFontSizeToFitWidth;
@property (nonatomic) CGFloat minimumScaleFactor;
- (void)lockFont:(UIFont *)f;
@end
@implementation W12FixedLabel
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) { self.opaque = NO; self.backgroundColor = [UIColor clearColor]; self.contentMode = UIViewContentModeRedraw; self.userInteractionEnabled = NO; self.clipsToBounds = YES; _textColor = [UIColor whiteColor]; }
    return self;
}
- (void)setText:(NSString *)t { if ((t ?: @"") == (_text ?: @"") || [t isEqualToString:_text]) return; _text = [t copy]; [self setNeedsDisplay]; }
- (void)setTextColor:(UIColor *)c { _textColor = c; [self setNeedsDisplay]; }
- (void)setTextAlignment:(NSTextAlignment)a { _textAlignment = a; [self setNeedsDisplay]; }
- (void)lockFont:(UIFont *)f { _font = f; [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)r {
    if (!_text.length) return;
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = _textAlignment; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    UIFont *f = _font ?: [UIFont systemFontOfSize:17];
    NSDictionary *at = @{NSFontAttributeName: f, NSForegroundColorAttributeName: _textColor ?: [UIColor whiteColor], NSParagraphStyleAttributeName: ps};
    CGFloat h = ceil(f.lineHeight), W = self.bounds.size.width, H = self.bounds.size.height;
    [_text drawInRect:CGRectMake(0, (H - h) / 2, W, h) withAttributes:at];
}
@end

static UIImage *gW12Art; static UIColor *gW12Tint;     // now-playing artwork and its dominant colour
static UIImage *W12AppIcon(NSString *bid) {
    SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (bid.length && [UIImage respondsToSelector:sel]) return ((UIImage *(*)(id, SEL, id, int, CGFloat))objc_msgSend)([UIImage class], sel, bid, 2, [UIScreen mainScreen].scale);
    return nil;
}
@interface W12PillView : UIView
@property (nonatomic, strong) UIView *iconHost, *barsHost;
@property (nonatomic, strong) W12FixedLabel *label;
@property (nonatomic, strong) NSArray<CALayer *> *bars;
@property (nonatomic) BOOL centerIcon;                  // small bubble: the glyph sits in the middle
@property (nonatomic, strong) UIView *volHost;           // speaker icon + level bar (volume activity)
@property (nonatomic, strong) CAShapeLayer *volSpk, *volTrk, *volFill;
@property (nonatomic, strong) NSArray<CAShapeLayer *> *volWaves;
@property (nonatomic) float volumeLevel;
- (void)setVolume:(float)v;
- (void)showVolume:(BOOL)on;
- (void)setIconKind:(int)kind bid:(NSString *)bid;      // 1 clock, 2 stopwatch, 3 alarm, 4 media, 5 call
- (void)setBarsColor:(UIColor *)c;
- (void)showContent:(BOOL)on label:(BOOL)hasLabel bars:(BOOL)hasBars;
- (void)startBars;
@end
@implementation W12PillView
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        _iconHost = [UIView new]; _iconHost.alpha = 0; _iconHost.userInteractionEnabled = NO; [self addSubview:_iconHost];
        _barsHost = [UIView new]; _barsHost.alpha = 0; _barsHost.userInteractionEnabled = NO; [self addSubview:_barsHost];
        _label = [W12FixedLabel new]; _label.alpha = 0; _label.textAlignment = NSTextAlignmentRight; _label.textColor = W12_ORANGE;
        [_label lockFont:([UIFont respondsToSelector:@selector(monospacedDigitSystemFontOfSize:weight:)] ? [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightSemibold] : [UIFont boldSystemFontOfSize:17])];
        _label.adjustsFontSizeToFitWidth = YES; _label.minimumScaleFactor = 0.7;
        [self addSubview:_label];
        NSMutableArray *bs = [NSMutableArray array];
        for (int i = 0; i < 4; i++) {
            CALayer *b = [CALayer layer]; b.cornerRadius = 1.5; b.backgroundColor = [UIColor whiteColor].CGColor;
            [_barsHost.layer addSublayer:b]; [bs addObject:b];
        }
        _bars = bs;
        _volHost = [UIView new]; _volHost.alpha = 0; _volHost.userInteractionEnabled = NO; [self addSubview:_volHost];
        UIColor *wc = [UIColor whiteColor];
        _volSpk = [CAShapeLayer layer]; _volSpk.fillColor = wc.CGColor; _volSpk.frame = CGRectMake(0, 0, 22, 22);
        UIBezierPath *sp = [UIBezierPath bezierPath];
        [sp moveToPoint:CGPointMake(2, 8)]; [sp addLineToPoint:CGPointMake(6.5, 8)]; [sp addLineToPoint:CGPointMake(11.5, 3.6)]; [sp addLineToPoint:CGPointMake(11.5, 18.4)];
        [sp addLineToPoint:CGPointMake(6.5, 14)]; [sp addLineToPoint:CGPointMake(2, 14)]; [sp closePath]; _volSpk.path = sp.CGPath;
        [_volHost.layer addSublayer:_volSpk];
        NSMutableArray *wv = [NSMutableArray array];
        for (int i = 0; i < 3; i++) {
            CAShapeLayer *a = [CAShapeLayer layer]; a.fillColor = nil; a.strokeColor = wc.CGColor; a.lineWidth = 1.9; a.lineCap = kCALineCapRound; a.frame = CGRectMake(0, 0, 22, 22);
            a.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(11.5, 11) radius:4.2 + i * 3.4 startAngle:-0.82 endAngle:0.82 clockwise:YES].CGPath;
            [_volHost.layer addSublayer:a]; [wv addObject:a];
        }
        _volWaves = wv;
        _volTrk = [CAShapeLayer layer]; _volTrk.fillColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor; [_volHost.layer addSublayer:_volTrk];
        _volFill = [CAShapeLayer layer]; _volFill.fillColor = wc.CGColor; [_volHost.layer addSublayer:_volFill];
    }
    return self;
}
- (void)showVolume:(BOOL)on {
    [UIView animateWithDuration:on ? 0.25 : 0.1 delay:on ? 0.14 : 0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{ self.volHost.alpha = on ? 1 : 0; } completion:nil];
}
- (void)setVolume:(float)v {
    _volumeLevel = MAX(0, MIN(1, v));
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height, pad = (h - 22) / 2 + 5;
    _volHost.frame = self.bounds;
    CGFloat tx = pad + 22 + 12, tw = MAX(10, w - tx - pad - 2), th = 6, ty = (h - th) / 2;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _volSpk.frame = CGRectMake(pad, (h - 22) / 2, 22, 22);
    for (int i = 0; i < 3; i++) { CAShapeLayer *a = _volWaves[i]; a.frame = CGRectMake(pad, (h - 22) / 2, 22, 22); a.hidden = !(_volumeLevel > 0.001 && _volumeLevel > i * 0.34 - 0.001); }
    _volTrk.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(tx, ty, tw, th) cornerRadius:3].CGPath;
    _volFill.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(tx, ty, MAX(th, tw * _volumeLevel), th) cornerRadius:3].CGPath;
    [CATransaction commit];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat s = MIN(22, h - 12), pad = (h - s) / 2 + 3;
    _iconHost.frame = CGRectMake(pad, (h - s) / 2, s, s);
    _barsHost.frame = CGRectMake(w - pad - 20, (h - 18) / 2, 20, 18);
    if (_centerIcon) { _iconHost.frame = CGRectMake((w - s) / 2, (h - s) / 2, s, s); _barsHost.frame = CGRectMake((w - 20) / 2, (h - 18) / 2, 20, 18); }
    _label.frame = CGRectMake(w * 0.38, 0, w * 0.62 - pad, h);
    if (_volHost.alpha > 0 || _volumeLevel > 0) [self setVolume:_volumeLevel];
    for (int i = 0; i < 4; i++) {
        CALayer *b = _bars[i];
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        b.bounds = CGRectMake(0, 0, 3, 18); b.position = CGPointMake(1.5 + i * 5.8, 9);
        [CATransaction commit];
    }
}
- (void)setBarsColor:(UIColor *)c { for (CALayer *b in _bars) b.backgroundColor = c.CGColor; }
- (void)startBars {
    static const double dur[4] = {0.52, 0.38, 0.61, 0.44}, lo[4] = {0.30, 0.45, 0.22, 0.40};
    if ([_bars.firstObject animationForKey:@"w12.bar"]) return;
    for (int i = 0; i < 4; i++) {
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
        a.fromValue = @(lo[i]); a.toValue = @1.0; a.duration = dur[i]; a.autoreverses = YES; a.repeatCount = HUGE_VALF;
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        a.beginTime = CACurrentMediaTime() - i * 0.11;
        [_bars[i] addAnimation:a forKey:@"w12.bar"];
    }
}
- (void)stopBars { for (CALayer *b in _bars) [b removeAnimationForKey:@"w12.bar"]; }
- (void)setIconKind:(int)kind bid:(NSString *)bid {
    for (UIView *v in [_iconHost.subviews copy]) [v removeFromSuperview];
    for (CALayer *l in [_iconHost.layer.sublayers copy]) [l removeFromSuperlayer];
    if (kind == 1 || kind == 2 || kind == 3) {            // orange stopwatch glyph
        CAShapeLayer *ring = [CAShapeLayer layer]; ring.fillColor = nil; ring.strokeColor = W12_ORANGE.CGColor; ring.lineWidth = 2.2; ring.lineCap = kCALineCapRound;
        ring.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(11, 12.4) radius:8.4 startAngle:0 endAngle:2 * M_PI clockwise:YES].CGPath;
        [_iconHost.layer addSublayer:ring];
        CAShapeLayer *cap = [CAShapeLayer layer]; cap.fillColor = W12_ORANGE.CGColor;
        cap.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(8.6, 0, 4.8, 2.4) cornerRadius:1.2].CGPath;
        [_iconHost.layer addSublayer:cap];
        CAShapeLayer *hand = [CAShapeLayer layer]; hand.fillColor = nil; hand.strokeColor = W12_ORANGE.CGColor; hand.lineWidth = 2.0; hand.lineCap = kCALineCapRound;
        UIBezierPath *hp = [UIBezierPath bezierPath];
        if (kind == 3) { [hp moveToPoint:CGPointMake(11, 7.6)]; [hp addLineToPoint:CGPointMake(11, 12.4)]; [hp addLineToPoint:CGPointMake(14.2, 14.2)]; }   // alarm: clock hands
        else { [hp moveToPoint:CGPointMake(11, 12.4)]; [hp addLineToPoint:CGPointMake(14.6, 8.6)]; }                                         // timer / stopwatch: one hand
        hand.path = hp.CGPath; [_iconHost.layer addSublayer:hand];
    } else if (kind == 7 || kind == 8 || kind == 9) {      // battery (7 charging: green + bolt, 8 low: red, 9 plain white)
        UIColor *c = (kind == 7) ? W12_GREEN : (kind == 8 ? W12_RED : [UIColor colorWithWhite:0.95 alpha:1]);
        CAShapeLayer *body = [CAShapeLayer layer]; body.fillColor = nil; body.strokeColor = c.CGColor; body.lineWidth = 1.6;
        body.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.8, 5.3, 18, 11.4) cornerRadius:3.4].CGPath;
        [_iconHost.layer addSublayer:body];
        CAShapeLayer *cap = [CAShapeLayer layer]; cap.fillColor = c.CGColor;
        cap.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(19.6, 8.6, 2.2, 4.8) cornerRadius:1.1].CGPath;
        [_iconHost.layer addSublayer:cap];
        float lvl = [UIDevice currentDevice].batteryLevel; if (lvl < 0) lvl = 0.5; if (kind == 8) lvl = MIN(lvl, 0.2f);
        CAShapeLayer *fill = [CAShapeLayer layer]; fill.fillColor = c.CGColor;
        fill.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(2.8, 7.3, MAX(2.0, 14 * lvl), 7.4) cornerRadius:1.8].CGPath;
        [_iconHost.layer addSublayer:fill];
        if (kind == 7) {
            CAShapeLayer *bolt = [CAShapeLayer layer]; bolt.fillColor = [UIColor blackColor].CGColor;
            UIBezierPath *bp = [UIBezierPath bezierPath];
            [bp moveToPoint:CGPointMake(10.8, 6.2)]; [bp addLineToPoint:CGPointMake(7.0, 11.4)]; [bp addLineToPoint:CGPointMake(9.6, 11.4)];
            [bp addLineToPoint:CGPointMake(8.6, 15.8)]; [bp addLineToPoint:CGPointMake(12.6, 10.4)]; [bp addLineToPoint:CGPointMake(10.0, 10.4)]; [bp closePath];
            bolt.path = bp.CGPath; bolt.strokeColor = [UIColor blackColor].CGColor; bolt.lineWidth = 0.6;
            [_iconHost.layer addSublayer:bolt];
        }
    } else if (kind == 10 || kind == 11) {                // ringer: bell (11 = silent: red bell with a slash)
        UIColor *c = kind == 11 ? W12_RED : [UIColor whiteColor];
        CAShapeLayer *bell = [CAShapeLayer layer]; bell.fillColor = c.CGColor; bell.name = @"bell";
        UIBezierPath *bp = [UIBezierPath bezierPath];
        [bp addArcWithCenter:CGPointMake(11, 10) radius:6.2 startAngle:M_PI endAngle:2 * M_PI clockwise:YES];
        [bp addLineToPoint:CGPointMake(18.8, 15.4)]; [bp addLineToPoint:CGPointMake(3.2, 15.4)]; [bp closePath];
        [bp appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(9.3, 16.4, 3.4, 3.4)]];
        [bp appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(9.8, 1.6, 2.4, 2.4)]];
        bell.path = bp.CGPath; [_iconHost.layer addSublayer:bell];
        if (kind == 11) {
            CAShapeLayer *sl = [CAShapeLayer layer]; sl.fillColor = nil; sl.strokeColor = W12_RED.CGColor; sl.lineWidth = 2.0; sl.lineCap = kCALineCapRound;
            UIBezierPath *lp = [UIBezierPath bezierPath]; [lp moveToPoint:CGPointMake(3.5, 3.5)]; [lp addLineToPoint:CGPointMake(18.5, 18.5)];
            sl.path = lp.CGPath; [_iconHost.layer addSublayer:sl];
        } else {
            CAKeyframeAnimation *rot = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
            rot.values = @[@0, @0.42, @-0.38, @0.3, @-0.22, @0.12, @0]; rot.duration = 0.75; rot.beginTime = CACurrentMediaTime() + 0.2; rot.fillMode = kCAFillModeBackwards;
            bell.anchorPoint = CGPointMake(0.5, 0.15); bell.frame = CGRectMake(0, 0, 22, 22);
            [bell addAnimation:rot forKey:@"w12.shake"];
        }
    } else if (kind == 13) {                               // flashlight
        UIColor *c = [UIColor colorWithRed:0.86 green:0.84 blue:1 alpha:1];
        CAShapeLayer *tl = [CAShapeLayer layer]; tl.fillColor = c.CGColor;
        UIBezierPath *tp = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(7.5, 9, 7, 11) cornerRadius:2];
        [tp appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(5.5, 4.2, 11, 5.2) cornerRadius:1.8]];
        tl.path = tp.CGPath; [_iconHost.layer addSublayer:tl];
        CAShapeLayer *rays = [CAShapeLayer layer]; rays.fillColor = nil; rays.strokeColor = c.CGColor; rays.lineWidth = 1.5; rays.lineCap = kCALineCapRound;
        UIBezierPath *rp = [UIBezierPath bezierPath];
        [rp moveToPoint:CGPointMake(11, 0.4)]; [rp addLineToPoint:CGPointMake(11, 1.9)];
        [rp moveToPoint:CGPointMake(4.4, 2.2)]; [rp addLineToPoint:CGPointMake(5.4, 3.2)];
        [rp moveToPoint:CGPointMake(17.6, 2.2)]; [rp addLineToPoint:CGPointMake(16.6, 3.2)];
        rays.path = rp.CGPath; [_iconHost.layer addSublayer:rays];
    } else if (kind == 6) {                                // screen recording: one pulsing red dot
        CAShapeLayer *dot = [CAShapeLayer layer]; dot.fillColor = W12_RED.CGColor;
        dot.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(11, 11) radius:7.6 startAngle:0 endAngle:2 * M_PI clockwise:YES].CGPath;
        [_iconHost.layer addSublayer:dot];
        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
        pulse.fromValue = @1.0; pulse.toValue = @0.35; pulse.duration = 0.9; pulse.autoreverses = YES; pulse.repeatCount = HUGE_VALF;
        pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [dot addAnimation:pulse forKey:@"w12.pulse"];
    } else if (kind == 5) {                                // green handset
        CAShapeLayer *arc = [CAShapeLayer layer]; arc.fillColor = nil; arc.strokeColor = W12_GREEN.CGColor; arc.lineWidth = 3.2; arc.lineCap = kCALineCapRound;
        arc.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(15.2, 6.4) radius:11 startAngle:M_PI_2 endAngle:M_PI clockwise:YES].CGPath;
        [_iconHost.layer addSublayer:arc];
        for (NSValue *v in @[[NSValue valueWithCGPoint:CGPointMake(15.2, 17.4)], [NSValue valueWithCGPoint:CGPointMake(4.2, 6.4)]]) {
            CAShapeLayer *e = [CAShapeLayer layer]; e.fillColor = W12_GREEN.CGColor; CGPoint p = v.CGPointValue;
            e.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(p.x - 2.6, p.y - 2.6, 5.2, 5.2)].CGPath;
            [_iconHost.layer addSublayer:e];
        }
    } else if (kind == 4) {                                // the playing app's icon
        UIImage *img = nil;
        SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
        if (bid.length && [UIImage respondsToSelector:sel])
            img = ((UIImage *(*)(id, SEL, id, int, CGFloat))objc_msgSend)([UIImage class], sel, bid, 0, [UIScreen mainScreen].scale);
        if (gW12Art) img = gW12Art;
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 22, 22)];
        iv.image = img; iv.layer.cornerRadius = 5.5; iv.clipsToBounds = YES; iv.contentMode = UIViewContentModeScaleAspectFill;
        if (!img) { iv.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1]; }
        [_iconHost addSubview:iv];
    }
}
- (void)showContent:(BOOL)on label:(BOOL)hasLabel bars:(BOOL)hasBars {
    CGFloat d = on ? 0.18 : 0.0;
    [UIView animateWithDuration:on ? 0.28 : 0.12 delay:d options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.iconHost.alpha = on ? 1 : 0;
        self.label.alpha = (on && hasLabel) ? 1 : 0;
        self.barsHost.alpha = (on && hasBars) ? 1 : 0;
    } completion:nil];
    if (on && hasBars) [self startBars]; else [self stopBars];
}
@end

typedef CGImageRef (*W12ScreenImageFn)(void);

@interface W12IslandVC : UIViewController
@property (nonatomic, copy) void (^onLayout)(void);
@end
@implementation W12IslandVC
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; if (self.onLayout) self.onLayout(); }
- (BOOL)shouldAutorotate { return YES; }
@end


// ---- glyphs and buttons of the expanded card ----
static UIBezierPath *W12PlayPath(CGRect r) {
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(r.origin.x + r.size.width * 0.12, r.origin.y)];
    [p addLineToPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMidY(r))];
    [p addLineToPoint:CGPointMake(r.origin.x + r.size.width * 0.12, CGRectGetMaxY(r))];
    [p closePath]; return p;
}
static UIBezierPath *W12PausePath(CGRect r) {
    UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(r.origin.x + r.size.width * 0.08, r.origin.y, r.size.width * 0.3, r.size.height) cornerRadius:2];
    [p appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(r.origin.x + r.size.width * 0.62, r.origin.y, r.size.width * 0.3, r.size.height) cornerRadius:2]];
    return p;
}
static UIBezierPath *W12SkipPath(CGRect r, BOOL prev) {
    UIBezierPath *p = [UIBezierPath bezierPath];
    CGFloat w = r.size.width, h = r.size.height, x = r.origin.x, y = r.origin.y;
    [p moveToPoint:CGPointMake(x, y)]; [p addLineToPoint:CGPointMake(x + w * 0.5, y + h / 2)]; [p addLineToPoint:CGPointMake(x, y + h)]; [p closePath];
    [p moveToPoint:CGPointMake(x + w * 0.46, y)]; [p addLineToPoint:CGPointMake(x + w * 0.92, y + h / 2)]; [p addLineToPoint:CGPointMake(x + w * 0.46, y + h)]; [p closePath];
    [p appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x + w * 0.9, y, w * 0.12, h) cornerRadius:1]];
    if (prev) { CGAffineTransform t = CGAffineTransformMake(-1, 0, 0, 1, 2 * x + w * 1.02, 0); [p applyTransform:t]; }
    return p;
}
static UIBezierPath *W12HandsetPath(CGRect r) {       // the call glyph, rotated by the caller
    UIBezierPath *p = [UIBezierPath bezierPathWithArcCenter:CGPointMake(CGRectGetMaxX(r) - r.size.width * 0.15, r.origin.y + r.size.height * 0.2) radius:r.size.width * 0.5 startAngle:M_PI_2 endAngle:M_PI clockwise:YES];
    return p;
}

@interface W12IslandBtn : UIButton
@property (nonatomic, copy) void (^act)(void);
@property (nonatomic, strong) CAShapeLayer *glyph;
@property (nonatomic) CGFloat maxGlyph;
- (void)setGlyphPath:(UIBezierPath *)path color:(UIColor *)c filled:(BOOL)filled;
@end
@implementation W12IslandBtn
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        [self addTarget:self action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
        [self addTarget:self action:@selector(down) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
        [self addTarget:self action:@selector(up) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
        _glyph = [CAShapeLayer layer]; [self.layer addSublayer:_glyph];
    }
    return self;
}
- (void)setGlyphPath:(UIBezierPath *)path color:(UIColor *)c filled:(BOOL)filled {
    CGRect b = path.bounds;
    CGFloat mg = _maxGlyph > 0 ? _maxGlyph : 22.0;
    CGFloat sc = MIN(1.0, mg / MAX(b.size.width, b.size.height));
    CGAffineTransform t = CGAffineTransformMakeTranslation(-CGRectGetMidX(b), -CGRectGetMidY(b));
    UIBezierPath *q = [path copy]; [q applyTransform:t]; [q applyTransform:CGAffineTransformMakeScale(sc, sc)];
    [q applyTransform:CGAffineTransformMakeTranslation(self.bounds.size.width / 2, self.bounds.size.height / 2)];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _glyph.path = q.CGPath; _glyph.fillColor = filled ? c.CGColor : nil; _glyph.strokeColor = filled ? nil : c.CGColor;
    _glyph.lineWidth = 3.4; _glyph.lineCap = kCALineCapRound; _glyph.fillRule = kCAFillRuleNonZero;
    [CATransaction commit];
}
- (void)fire { if (self.act) self.act(); }
- (void)down { [UIView animateWithDuration:0.08 animations:^{ self.alpha = 0.55; self.transform = CGAffineTransformMakeScale(0.92, 0.92); }]; }
- (void)up { [UIView animateWithDuration:0.18 animations:^{ self.alpha = 1; self.transform = CGAffineTransformIdentity; }]; }
@end

typedef Boolean (*W12MRSendFn)(uint32_t, id);
static void W12MediaCmd(uint32_t cmd) {
    static void *h; static W12MRSendFn fn;
    if (!h) { h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY); if (h) fn = (W12MRSendFn)dlsym(h, "MRMediaRemoteSendCommand"); }
    if (fn) fn(cmd, nil); else W12_LOG(@"island: MediaRemote unavailable");
}

static BOOL W12IsLandscape(void) {
    UIApplication *app = [UIApplication sharedApplication];
    long o = 0;
    for (NSString *n in @[@"activeInterfaceOrientation", @"_frontMostAppOrientation"]) {
        SEL sl = NSSelectorFromString(n);
        if (!o && [app respondsToSelector:sl]) o = ((long (*)(id, SEL))objc_msgSend)(app, sl);
    }
    CGSize ss = [UIScreen mainScreen].bounds.size;
    if (ss.width > ss.height || o == 3 || o == 4) return YES;
    if (W12FrontApp()) { UIDeviceOrientation d = [UIDevice currentDevice].orientation; if (d == UIDeviceOrientationLandscapeLeft || d == UIDeviceOrientationLandscapeRight) return YES; }
    return NO;
}
static unsigned long long W12TorchLevel(void) {
    Class c = NSClassFromString(@"SBUIFlashlightController");
    id fc = c ? W12Call(c, @selector(sharedInstance)) : nil;
    SEL s = NSSelectorFromString(@"level");
    return (fc && [fc respondsToSelector:s]) ? ((unsigned long long (*)(id, SEL))objc_msgSend)(fc, s) : 0;
}
static void W12SetTorchLevel(unsigned long long l) {
    Class c = NSClassFromString(@"SBUIFlashlightController");
    id fc = c ? W12Call(c, @selector(sharedInstance)) : nil;
    SEL s = NSSelectorFromString(@"setLevel:");
    if (fc && [fc respondsToSelector:s]) ((void (*)(id, SEL, unsigned long long))objc_msgSend)(fc, s, l);
}
static BOOL gHudHide;                       // iOS 12 volume / ringer HUD is kept hidden while the island shows them
static CGFloat gFlFrac; static BOOL gFlDrag;

@interface W12Island : NSObject
@property (nonatomic) CGRect lastFrame;
@property (nonatomic, strong) W12IslandWindow *win;
@property (nonatomic, strong) UIView *pill;
@property (nonatomic) CGRect lastRect;
@property (nonatomic) double borderAlpha;
@property (nonatomic) int blankToken;
@property (nonatomic) BOOL sampling;
@property (nonatomic) W12ScreenImageFn screenImage;
@property (nonatomic) BOOL warnedNoImage;
// live activity
@property (nonatomic) int actKind;                 // 0 none, 1 timer, 2 stopwatch, 3 alarm, 4 media, 5 call
@property (nonatomic, copy) NSString *actBid, *actText;
@property (nonatomic) BOOL expanded;
@property (nonatomic, copy) NSString *battText;
@property (nonatomic) int expKind;
@property (nonatomic, strong) UIView *expView;
@property (nonatomic, strong) W12FixedLabel *expTitle, *expSub, *expBig;
@property (nonatomic, strong) W12IslandBtn *expPlay;
@property (nonatomic) CFTimeInterval expDeadline;
@property (nonatomic) int transientKind;
@property (nonatomic) CFTimeInterval transientUntil;
@property (nonatomic) int lastChg;
@property (nonatomic) BOOL warned20, warned10, batInit;
@property (nonatomic) int shownKind;
@property (nonatomic) CFTimeInterval expandAfter;
@property (nonatomic, copy) NSString *lastBid;
@property (nonatomic) BOOL animateNext;
@property (nonatomic, strong) NSDate *timerFire, *alarmFire;       // filled by the background reader
@property (nonatomic, strong) dispatch_queue_t mtQ;
@property (nonatomic, strong) id timerMgr, alarmMgr;
@property (nonatomic) BOOL mtDumped;
@property (nonatomic, strong) NSArray<NSDictionary *> *acts, *vis;     // all running activities / the ones the island shows (front app filtered)
@property (nonatomic) int shownKind2, expSlot;
@property (nonatomic, copy) NSString *shownBid, *shownBid2, *lastBid2;
@property (nonatomic, strong) W12PillView *pill2;                        // the small bubble of a second activity
@property (nonatomic, strong) UIView *progFill, *progTrack;
@property (nonatomic, strong) UIImageView *expArt;
@property (nonatomic, strong) W12FixedLabel *tLeft, *tRight;
@property (nonatomic, copy) NSString *npTitle, *npArtist;
@property (nonatomic) double npElapsed, npDur, npRate; @property (nonatomic, strong) NSDate *npStamp;
@property (nonatomic) CFTimeInterval npFetch; @property (nonatomic) BOOL npBusy;
@property (nonatomic) BOOL artDirty; @property (nonatomic) NSUInteger npArtLen;
- (NSDictionary *)actWithKind:(int)k;
- (void)fetchNowPlaying;
@property (nonatomic) int clkToken;
@property (nonatomic) BOOL volInit, lastLand; @property (nonatomic) float volLevel;
@property (nonatomic) int ringToken, ringState;
@property (nonatomic, copy) NSString *transientText;
@property (nonatomic, strong) NSDictionary *flL;
- (CGFloat)expandedWidth;
- (void)volPoll;
- (void)torchPan:(UIPanGestureRecognizer *)g;
@property (nonatomic) BOOL lowBatCard, lowBatPending, lbLast, lbOn;      // low-battery card (auto expands at 20 % / 10 %)
@property (nonatomic) int lowBatPct;
@property (nonatomic, strong) UIView *lbCap;
@property (nonatomic, strong) CAShapeLayer *lbBody, *lbNub, *lbFill, *lbRing;
- (void)openLowBat;
- (void)testKind:(int)k;
- (void)toggleLowPower;
@property (nonatomic) BOOL clkReg;
- (CGRect)targetRect;
- (CGRect)collapsedRect;
- (CGFloat)activityExtra;
- (void)collapse;
- (CGFloat)expandedHeight;
- (void)held:(UILongPressGestureRecognizer *)g;
- (CGRect)baseRect;
- (void)bump;
- (void)tickActivity;
- (void)showBubble:(int)k bid:(NSString *)bid;
@end

@implementation W12Island
- (void)start {
    notify_register_check("com.apple.springboard.hasBlankedScreen", &_blankToken);
    self.mtQ = dispatch_queue_create("com.wave12.island.mt", DISPATCH_QUEUE_SERIAL);
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    NSTimer *t3 = [NSTimer timerWithTimeInterval:0.25 target:self selector:@selector(tickActivity) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:t3 forMode:NSRunLoopCommonModes];
    self.screenImage = (W12ScreenImageFn)dlsym(RTLD_DEFAULT, "UIGetScreenImage");
    NSTimer *t1 = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:t1 forMode:NSRunLoopCommonModes];
    NSTimer *t2 = [NSTimer timerWithTimeInterval:0.5 target:self selector:@selector(sample) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:t2 forMode:NSRunLoopCommonModes];
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [self refresh];
}

- (void)ensureWindow {
    if (self.win) return;
    CGRect b = [UIScreen mainScreen].bounds;
    W12IslandWindow *w = [[W12IslandWindow alloc] initWithFrame:b];
    w.windowLevel = 100000;
    w.backgroundColor = [UIColor clearColor];
    w.userInteractionEnabled = YES;
    W12IslandVC *vc = [W12IslandVC new];
    __weak W12Island *wk = self;
    vc.onLayout = ^{ [wk refresh]; };
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.userInteractionEnabled = YES;
    w.rootViewController = vc;
    W12PillView *pill = [[W12PillView alloc] initWithFrame:CGRectZero];
    pill.backgroundColor = [UIColor blackColor];
    pill.userInteractionEnabled = YES;       // long press works on an idle island too
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)];
    [pill addGestureRecognizer:tap];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(held:)];
    lp.minimumPressDuration = 0.38; [pill addGestureRecognizer:lp];
    UITapGestureRecognizer *outside = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(outsideTap:)];
    outside.cancelsTouchesInView = NO; [vc.view addGestureRecognizer:outside];
    w.pillRef = pill;
    W12PillView *p2 = [[W12PillView alloc] initWithFrame:CGRectZero];
    p2.centerIcon = YES; p2.backgroundColor = [UIColor blackColor]; p2.userInteractionEnabled = YES; p2.hidden = YES; p2.alpha = 0;
    p2.layer.borderWidth = W12IslandBorderW(); p2.layer.borderColor = [UIColor colorWithWhite:0.55 alpha:0].CGColor;
    [p2 addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped2)]];
    UILongPressGestureRecognizer *lp2 = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(held:)];
    lp2.minimumPressDuration = 0.38; [p2 addGestureRecognizer:lp2];
    [vc.view addSubview:p2]; w.pill2Ref = p2; self.pill2 = p2;
    pill.layer.borderWidth = W12IslandBorderW();
    pill.layer.borderColor = [UIColor colorWithWhite:0.55 alpha:0].CGColor;
    [vc.view addSubview:pill];
    self.win = w; self.pill = pill;
    w.hidden = NO;
}

// iOS 12 does not draw extra windows above the Lock Screen (the log shows ours at level 100000 over SBCoverSheetWindow at 1050 and it still
// stays invisible), so while the device is locked the pills live inside the cover sheet window itself and move back after unlocking.
- (void)syncHost { [self syncHost:NO]; }
- (void)syncHost:(BOOL)force {
    if (!self.win || !self.pill) return;
    static CFTimeInterval lockedAt = 0;
    CFTimeInterval now = CACurrentMediaTime();
    BOOL lk = W12UILocked();
    if (lk) lockedAt = now;
    UIWindow *cw = nil;
    if (lk || (!force && now - lockedAt < 0.9)) {
        for (UIWindow *w in [UIApplication sharedApplication].windows)
            if (!w.hidden && w != self.win && [NSStringFromClass([w class]) containsString:@"CoverSheetWindow"]) { cw = w; break; }
    }
    UIView *own = self.win.rootViewController.view;
    UIView *target = cw ?: own;
    if (!target) return;
    if (self.pill.superview != target) {
        if (!cw && gFidBusy) return;                              // the Face ID animation is running in the cover sheet: let it finish first
        [target addSubview:self.pill2]; [target addSubview:self.pill];
        self.lastRect = CGRectZero; self.lastFrame = CGRectZero;
        W12_LOG(@"island: host -> %@ (%@)", cw ? @"cover sheet window" : @"island window", cw ? NSStringFromClass([cw class]) : @"");
    } else if (cw) {
        // keep the pills on top of the Lock Screen's own views, but never fight with the padlock / Face ID views that sit above them
        UIView *top = cw.subviews.lastObject;
        if (top != self.pill && top != gFidLock && top != gFidCard && top != gFidBV && top != gFidCV) { [cw bringSubviewToFront:self.pill2]; [cw bringSubviewToFront:self.pill]; }
    }
}

- (void)refresh {
    BOOL on = W12Bool(@"island", NO);
    if (on && W12Bool(@"islandHideLand", YES) && W12IsLandscape()) on = NO;
    if (!on) { if (self.expanded) [self collapse]; self.win.hidden = YES; return; }
    [self ensureWindow];
    self.win.hidden = NO;
    [self syncHost];
    {   BOOL lk = W12UILocked();
        static int lastLk = -1; if (lk != lastLk) { lastLk = lk; W12_LOG(@"island: lock state -> %d, windows:", lk); for (UIWindow *dw in [UIApplication sharedApplication].windows) W12_LOG(@"  %@ level=%g hidden=%d alpha=%.2f%@", NSStringFromClass([dw class]), dw.windowLevel, dw.hidden, dw.alpha, dw == self.win ? @" (island)" : @""); }
        CGFloat top = 100000, anyMax = 0;
        for (UIWindow *ow in [UIApplication sharedApplication].windows) if (ow != self.win && !ow.hidden) {
            anyMax = MAX(anyMax, ow.windowLevel);
            if (ow.windowLevel < 1e8) top = MAX(top, ow.windowLevel + 1);
        }
        // Lock Screen: its window may sit at a huge level, the island has to be above every visible window then.
        if (lk && anyMax >= top && !isinf(anyMax)) top = anyMax * 1.0001 + 2;
        if (self.win.windowLevel != top) { self.win.windowLevel = top; W12_LOG(@"island: window level -> %g (locked=%d, highest other=%g)", top, lk, anyMax); } }
    double W = W12Double(@"islandW", 126, 70, 220);
    double H = W12Double(@"islandH", 37, 20, 60);
    double Y = W12Double(@"islandY", 11, 0, 40);
    CGFloat radius = 0;
    UIScreen *sc = [UIScreen mainScreen];
    CGRect b = sc.fixedCoordinateSpace.bounds;
    CGRect rf = [self collapsedRect];                              // idle / activity width, centred with the second bubble when there is one
    if (self.expanded) { W = [self expandedWidth]; H = [self expandedHeight]; radius = self.expKind == 13 ? 27 : MIN(36, H / 2); rf = CGRectMake(round((b.size.width - W) / 2.0), Y, W, H); }
    // The pill is placed in the screen's FIXED (portrait, physical) coordinate space and converted into the window's
    // current space, so it stays on the same physical spot whatever the orientation (landscape: a vertical pill on the same edge).
    CGFloat bw = W12IslandBorderW();
    if (self.pill.layer.borderWidth != bw) { self.pill.layer.borderWidth = bw; self.pill2.layer.borderWidth = bw; }
    UIView *host = self.pill.superview;
    CGRect rc = host ? [sc.fixedCoordinateSpace convertRect:rf toCoordinateSpace:host] : rf;
    rc = CGRectMake(round(rc.origin.x), round(rc.origin.y), round(rc.size.width), round(rc.size.height));
    if (!CGRectEqualToRect(rf, self.lastRect) || !CGRectEqualToRect(rc, self.lastFrame)) {
        self.lastRect = rf; self.lastFrame = rc;
        CGRect rf2 = CGRectMake(rf.origin.x + rf.size.width + 8, rf.origin.y, H, H);
        CGRect rc2 = host ? [sc.fixedCoordinateSpace convertRect:rf2 toCoordinateSpace:host] : rf2;
        rc2 = CGRectMake(round(rc2.origin.x), round(rc2.origin.y), round(rc2.size.width), round(rc2.size.height));
        // The bubble of a second activity appears BEHIND the main pill (no sliding in from its old place), then springs out with it.
        BOOL p2Static = self.pill2.hidden || self.pill2.alpha < 0.05;
        void (^applyMain)(void) = ^{ self.pill.frame = rc; [self.pill layoutIfNeeded]; };
        void (^applyP2)(void) = ^{
            CGAffineTransform t2 = self.pill2.transform; self.pill2.transform = CGAffineTransformIdentity;
            self.pill2.frame = rc2; self.pill2.transform = t2;
            [self.pill2 layoutIfNeeded];
        };
        self.pill2.layer.cornerRadius = MIN(rc2.size.width, rc2.size.height) / 2.0;
        CGFloat newR = radius > 0 ? radius : MIN(rc.size.width, rc.size.height) / 2.0;
        CALayer *pres = self.pill.layer.presentationLayer;
        CGFloat oldR = pres ? pres.cornerRadius : self.pill.layer.cornerRadius;          // interrupted animations continue from where they are (spam)
        self.pill.layer.cornerRadius = newR;
        if (self.animateNext && fabs(oldR - newR) > 0.5) {
            CABasicAnimation *ca = [CABasicAnimation animationWithKeyPath:@"cornerRadius"];
            ca.fromValue = @(oldR); ca.toValue = @(newR); ca.duration = 0.45; ca.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.2 :0.9 :0.25 :1];
            [self.pill.layer addAnimation:ca forKey:@"w12.cr"];
        }
        if (self.animateNext) {
            self.animateNext = NO;
            [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.6 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:applyMain completion:nil];
            if (p2Static) [UIView performWithoutAnimation:applyP2];
            else [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.6 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:applyP2 completion:nil];
        } else {
            [UIView performWithoutAnimation:^{ applyMain(); applyP2(); }];
        }
    }
}

// ---- live activity ----
- (CGFloat)activityExtra {
    int k = self.shownKind; if (!k) return 0;
    CGFloat e = (k == 6) ? 60 : ((k == 4 || k == 5) ? 66 : 84);        // dot only / icon + bars / icon + text
    if (self.shownKind2) e = MIN(e, 54);                              // two activities: both must fit beside the status bar items
    return e;
}
- (CGRect)collapsedRect {
    double W = W12Double(@"islandW", 126, 70, 220), H = W12Double(@"islandH", 37, 20, 60), Y = W12Double(@"islandY", 11, 0, 40);
    CGRect b = [UIScreen mainScreen].fixedCoordinateSpace.bounds;
    if (self.shownKind && W12Bool(@"islandLive", YES)) W = MAX(W, MIN(W + [self activityExtra], 224));
    CGFloat gap = (self.shownKind2 && W12Bool(@"islandLive", YES) && !self.expanded) ? H + 8 : 0;
    CGFloat maxW = b.size.width - 24 - gap; if (W > maxW) W = MAX(70, maxW);
    return CGRectMake(round((b.size.width - W - gap) / 2.0), Y, W, H);
}
- (CGRect)targetRect {
    return [self collapsedRect];                               // the card flies into the pill as it is right now (plain black inside the app)
}

- (CGRect)baseRect {
    double W = W12Double(@"islandW", 126, 70, 220), H = W12Double(@"islandH", 37, 20, 60), Y = W12Double(@"islandY", 11, 0, 40);
    CGRect b = [UIScreen mainScreen].fixedCoordinateSpace.bounds;
    return CGRectMake(round((b.size.width - W) / 2.0), Y, W, H);
}

- (void)bump {
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    a.values = @[@1.0, @1.16, @0.96, @1.03, @1.0]; a.keyTimes = @[@0, @0.25, @0.55, @0.8, @1];
    a.duration = 0.5; a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [self.pill.layer addAnimation:a forKey:@"w12.bump"];
    UIColor *gc = self.shownKind == 5 ? W12_GREEN : (self.shownKind == 4 ? [UIColor whiteColor] : W12_ORANGE);
    CALayer *pl = self.pill.layer;
    pl.shadowColor = gc.CGColor; pl.shadowRadius = 13; pl.shadowOffset = CGSizeZero;
    pl.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.pill.bounds cornerRadius:self.pill.bounds.size.height / 2].CGPath;
    CAKeyframeAnimation *g = [CAKeyframeAnimation animationWithKeyPath:@"shadowOpacity"];
    g.values = @[@0, @0.95, @0.5, @0]; g.keyTimes = @[@0, @0.2, @0.55, @1]; g.duration = 0.8;
    [pl addAnimation:g forKey:@"w12.glow"];
}

- (void)tapped {
    if (self.expanded && self.expKind == 8) { [self toggleLowPower]; return; }
    if (self.expanded || self.shownKind == 0 || self.shownKind >= 6) return;       // an idle island does nothing, like the real one
    NSString *bid = self.shownBid;
    if (!bid.length) return;
    UIApplication *app = [UIApplication sharedApplication];
    SEL sel = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    if ([app respondsToSelector:sel]) ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(app, sel, bid, NO);
    W12_LOG(@"island: tap -> open %@", bid);
}
- (void)tapped2 {
    if (self.expanded || self.shownKind2 == 0 || self.shownKind2 >= 6) return;
    NSString *bid = self.shownBid2; if (!bid.length) return;
    UIApplication *app = [UIApplication sharedApplication];
    SEL sel = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    if ([app respondsToSelector:sel]) ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(app, sel, bid, NO);
}
- (NSDictionary *)actWithKind:(int)k { for (NSDictionary *d in self.acts) if ([d[@"k"] intValue] == k) return d; return nil; }

// Now-playing details (title, artist, artwork, progress) straight from MediaRemote.
- (void)fetchNowPlaying {
    CFTimeInterval now = CACurrentMediaTime();
    if (self.npBusy || now - self.npFetch < (self.expanded ? 0.8 : 1.5)) return;
    static void (*fn)(dispatch_queue_t, void (^)(CFDictionaryRef)); static BOOL tried;
    if (!tried) { tried = YES; void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY); if (h) fn = dlsym(h, "MRMediaRemoteGetNowPlayingInfo"); }
    if (!fn) return;
    self.npBusy = YES; self.npFetch = now;
    __weak W12Island *wk = self;
    fn(dispatch_get_main_queue(), ^(CFDictionaryRef ref) {
        W12Island *me = wk; if (!me) return;
        me.npBusy = NO;
        NSDictionary *d = (__bridge NSDictionary *)ref;
        if (![d isKindOfClass:[NSDictionary class]]) return;
        NSString *t = d[@"kMRMediaRemoteNowPlayingInfoTitle"], *a = d[@"kMRMediaRemoteNowPlayingInfoArtist"];
        me.npTitle = [t isKindOfClass:[NSString class]] ? t : nil; me.npArtist = [a isKindOfClass:[NSString class]] ? a : nil;
        id el = d[@"kMRMediaRemoteNowPlayingInfoElapsedTime"], du = d[@"kMRMediaRemoteNowPlayingInfoDuration"], rt = d[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"], ts = d[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        me.npElapsed = [el respondsToSelector:@selector(doubleValue)] ? [el doubleValue] : 0;
        me.npDur = [du respondsToSelector:@selector(doubleValue)] ? [du doubleValue] : 0;
        me.npRate = [rt respondsToSelector:@selector(doubleValue)] ? [rt doubleValue] : 1;
        me.npStamp = [ts isKindOfClass:[NSDate class]] ? ts : [NSDate date];
        NSData *ad = d[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if ([ad isKindOfClass:[NSData class]] && ad.length) {
            if (!gW12Art || ad.length != me.npArtLen) {
                UIImage *im = [UIImage imageWithData:ad];
                if (im) {
                    gW12Art = im; me.npArtLen = ad.length;
                    uint8_t px[4] = {0}; CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                    CGContextRef c = CGBitmapContextCreate(px, 1, 1, 8, 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
                    if (c) { CGContextSetInterpolationQuality(c, kCGInterpolationMedium); CGContextDrawImage(c, CGRectMake(0, 0, 1, 1), im.CGImage); CGContextRelease(c);
                        CGFloat h, sa, b, al; [[UIColor colorWithRed:px[0] / 255.0 green:px[1] / 255.0 blue:px[2] / 255.0 alpha:1] getHue:&h saturation:&sa brightness:&b alpha:&al];
                        gW12Tint = [UIColor colorWithHue:h saturation:MIN(1, MAX(sa, 0.25) * 0.9) brightness:MAX(b, 0.82) alpha:1]; }
                    CGColorSpaceRelease(cs);
                    me.artDirty = YES;
                }
            }
        } else if (gW12Art && !ad) { gW12Art = nil; gW12Tint = nil; me.npArtLen = 0; me.artDirty = YES; }
    });
}

// Dump the method names of a private class once: the log then tells what this iOS version offers.
static void W12DumpClass(NSString *cn) {
    Class c = NSClassFromString(cn);
    if (!c) { W12_LOG(@"island: class %@ not found", cn); return; }
    NSMutableString *o = [NSMutableString stringWithFormat:@"island: %@ instance methods:", cn];
    unsigned n = 0; Method *ms = class_copyMethodList(c, &n);
    for (unsigned i = 0; i < n && i < 90; i++) [o appendFormat:@" %@", NSStringFromSelector(method_getName(ms[i]))];
    free(ms);
    [o appendString:@" | class methods:"];
    ms = class_copyMethodList(object_getClass(c), &n);
    for (unsigned i = 0; i < n && i < 30; i++) [o appendFormat:@" %@", NSStringFromSelector(method_getName(ms[i]))];
    free(ms);
    W12_LOG(@"%@", o);
}

static id W12Obj(id o, NSArray *names) {
    for (NSString *n in names) {
        SEL s = NSSelectorFromString(n);
        if (o && [o respondsToSelector:s]) { id r = ((id (*)(id, SEL))objc_msgSend)(o, s); if (r) return r; }
    }
    return nil;
}
static NSDate *W12DateOf(id o, NSArray *names) { id r = W12Obj(o, names); return [r isKindOfClass:[NSDate class]] ? r : nil; }

// Background read of the Clock's timer / next alarm (MobileTimer is private and may block while it talks to its daemon).
- (void)readClock {
    dispatch_async(self.mtQ, ^{
        @try {
            static BOOL loaded;
            if (!loaded) { loaded = YES; dlopen("/System/Library/PrivateFrameworks/MobileTimer.framework/MobileTimer", RTLD_LAZY); }
            if (!self.timerMgr) { Class c = NSClassFromString(@"MTTimerManager"); if (c) self.timerMgr = [[c alloc] init]; }
            if (!self.alarmMgr) { Class c = NSClassFromString(@"MTAlarmManager"); if (c) self.alarmMgr = [[c alloc] init]; }
            if (!self.mtDumped) {
                self.mtDumped = YES;
                W12DumpClass(@"MTTimerManager"); W12DumpClass(@"MTTimer"); W12DumpClass(@"MTAlarmManager"); W12DumpClass(@"MTAlarm");
            }
            // timer
            NSDate *tf = nil;
            id t = W12Obj(self.timerMgr, @[@"currentTimerSync", @"currentTimer", @"timersSync", @"timers"]);
            if ([t isKindOfClass:[NSArray class]]) { id best = nil; for (id x in (NSArray *)t) { if (!best) best = x; } t = best; }
            if ([t isKindOfClass:[NSSet class]]) t = [(NSSet *)t anyObject];
            if (t) {
                tf = W12DateOf(t, @[@"fireDate", @"firedDate", @"dateIfRunning"]);
                if (!tf && [t respondsToSelector:NSSelectorFromString(@"remainingTime")]) {
                    double rem = ((double (*)(id, SEL))objc_msgSend)(t, NSSelectorFromString(@"remainingTime"));
                    BOOL running = YES;
                    SEL st = NSSelectorFromString(@"state");
                    if ([t respondsToSelector:st]) { NSInteger sv = ((NSInteger (*)(id, SEL))objc_msgSend)(t, st); running = (sv == 3 || sv == 2); }
                    if (running && rem > 0.5 && rem < 360000) tf = [NSDate dateWithTimeIntervalSinceNow:rem];
                }
            }
            self.timerFire = tf;
            // alarm
            id a = W12Obj(self.alarmMgr, @[@"nextAlarmSync", @"nextAlarm"]);
            self.alarmFire = a ? W12DateOf(a, @[@"nextFireDate", @"fireDate"]) : nil;
        } @catch (NSException *e) { W12_LOG(@"island: clock read failed: %@", e.reason); }
    });
}

- (void)pollActivity {
    NSMutableArray *list = [NSMutableArray array];
    void (^add)(int, NSString *, NSString *) = ^(int k, NSString *b, NSString *t) {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject:@(k) forKey:@"k"];
        if (b) d[@"bid"] = b; if (t) d[@"text"] = t;
        [list addObject:d];
    };
    NSString *(^fmt)(long) = ^NSString *(long s) { return s >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", s / 3600, (s / 60) % 60, s % 60] : [NSString stringWithFormat:@"%ld:%02ld", s / 60, s % 60]; };
    @try {
        // phone call
        Class tcc = NSClassFromString(@"TUCallCenter");
        id cc = tcc ? W12Call(tcc, @selector(sharedInstance)) : nil;
        NSArray *calls = cc ? W12Call(cc, @selector(currentCalls)) : nil;
        if ([calls isKindOfClass:[NSArray class]]) for (id c in calls) {
            SEL ss = NSSelectorFromString(@"callStatus");
            if (![c respondsToSelector:ss]) continue;
            NSInteger st = ((NSInteger (*)(id, SEL))objc_msgSend)(c, ss);
            if (st == 1 || st == 2 || st == 3) { add(5, @"com.apple.mobilephone", nil); break; }
        }
        // screen recording (also true while mirroring)
        if ([[UIScreen mainScreen] respondsToSelector:@selector(isCaptured)] && [UIScreen mainScreen].isCaptured) add(6, nil, nil);
        // clock state published by the Clock app itself (stopwatch / timer)
        int ckKind = 0; BOOL ckRun = NO; double ckMs = 0;
        {
            if (!self.clkReg) { self.clkReg = YES; notify_register_check("com.wave12.clockstate", &_clkToken); }
            uint64_t v = 0; notify_get_state(self.clkToken, &v);
            ckKind = (int)((v >> 44) & 7); ckRun = ((v >> 43) & 1) != 0; ckMs = (double)(v & ((1ULL << 41) - 1));
        }
        double nowMs = [[NSDate date] timeIntervalSince1970] * 1000.0;
        // timer (MobileTimer, else the Clock app's own)
        BOOL haveTimer = NO;
        NSDate *tf = self.timerFire; double rem = tf ? [tf timeIntervalSinceNow] : 0;
        if (rem > 0.3) { add(1, @"com.apple.mobiletimer", fmt((long)ceil(rem))); haveTimer = YES; }
        if (!haveTimer && ckKind == 2 && ckRun) {
            double r2 = (ckMs - nowMs) / 1000.0;
            if (r2 > 0.3 && r2 < 360000) { add(1, @"com.apple.mobiletimer", fmt((long)ceil(r2))); haveTimer = YES; }
        }
        // stopwatch
        if (ckKind == 1 && ckRun) {
            double el = (nowMs - ckMs) / 1000.0;
            if (el >= 0 && el < 360000) add(2, @"com.apple.mobiletimer", fmt((long)el));
        }
        // alarm about to ring
        NSDate *af = self.alarmFire; double ar = af ? [af timeIntervalSinceNow] : 0;
        if (ar > 0.3 && ar <= 600) add(3, @"com.apple.mobiletimer", fmt((long)ceil(ar)));
        if (W12Bool(@"islandTorch", YES) && W12TorchLevel() > 0) add(13, nil, nil);
        // media
        id mc = W12Call(NSClassFromString(@"SBMediaController"), @selector(sharedInstance));
        if (mc && [mc respondsToSelector:@selector(isPlaying)] && ((BOOL (*)(id, SEL))objc_msgSend)(mc, @selector(isPlaying))) {
            id app = W12Call(mc, @selector(nowPlayingApplication));
            id b = W12Call(app, @selector(bundleIdentifier));
            if ([b isKindOfClass:[NSString class]]) add(4, b, nil);
        }
    } @catch (NSException *e) { W12_LOG(@"island: poll failed: %@", e.reason); }
    self.acts = list;
    NSDictionary *f = list.firstObject;
    self.actKind = [f[@"k"] intValue]; self.actBid = f[@"bid"]; self.actText = f[@"text"];
}

// ---- low power mode (iOS 12: CoreDuet's battery saver) ----
static BOOL W12LPM(void) {
    NSProcessInfo *pi = [NSProcessInfo processInfo];
    return [pi respondsToSelector:@selector(isLowPowerModeEnabled)] && pi.isLowPowerModeEnabled;
}
static void W12SetLPM(BOOL on) {
    Class c = NSClassFromString(@"_CDBatterySaver");
    id bs = c ? W12Call(c, NSSelectorFromString(@"batterySaver")) : nil;
    if (!bs) { W12_LOG(@"lpm: _CDBatterySaver not available"); return; }
    static BOOL dumped; if (!dumped) { dumped = YES; W12DumpClass(@"_CDBatterySaver"); }
    SEL a = NSSelectorFromString(@"setPowerMode:error:"), b = NSSelectorFromString(@"setMode:"), c3 = NSSelectorFromString(@"setPowerMode:fromSource:withCompletion:");
    if ([bs respondsToSelector:a]) { ((BOOL (*)(id, SEL, long long, id *))objc_msgSend)(bs, a, on ? 1 : 0, NULL); W12_LOG(@"lpm: setPowerMode:error: %d", on); }
    else if ([bs respondsToSelector:b]) { ((void (*)(id, SEL, long long))objc_msgSend)(bs, b, on ? 1 : 0); W12_LOG(@"lpm: setMode: %d", on); }
    else if ([bs respondsToSelector:c3]) { ((void (*)(id, SEL, long long, id, id))objc_msgSend)(bs, c3, on ? 1 : 0, @"com.wave12", nil); W12_LOG(@"lpm: fromSource %d", on); }
    else W12_LOG(@"lpm: no known setter, see the _CDBatterySaver dump");
}

- (void)toggleLowPower {
    if (W12LPM()) { [self collapse]; return; }
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]; [fb impactOccurred];
    W12SetLPM(YES);
    self.expDeadline = CACurrentMediaTime() + 3;
    __weak W12Island *wk = self;
    for (NSNumber *dl in @[@0.25, @0.7, @1.4]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([dl doubleValue] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        W12Island *me = wk; if (!me || !me.expanded || me.expKind != 8) return;
        [me updateExpanded];
        if (W12LPM()) me.expDeadline = MIN(me.expDeadline, CACurrentMediaTime() + 2.0);
    });
}

- (void)testKind:(int)k {
    if (!W12Bool(@"island", NO)) return;
    if (k == 14) { W12FacePlay(YES); return; }
    CFTimeInterval now = CACurrentMediaTime();
    if (self.expanded) [self collapse];
    if (k == 8) { self.lowBatPct = 10; [self openLowBat]; return; }
    if (k == 13) { W12SetTorchLevel(2); dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ W12SetTorchLevel(0); }); return; }
    NSString *bt = self.battText ?: @"80%";
    self.transientKind = k;
    if (k == 7 || k == 9) { self.transientText = bt; self.transientUntil = now + 3.0; }
    else if (k == 10) { self.transientText = W12Tr(@"Chuông"); self.transientUntil = now + 2.4; }
    else if (k == 11) { self.transientText = W12Tr(@"Im lặng"); self.transientUntil = now + 2.4; }
    else if (k == 12) { self.transientText = @""; self.volLevel = 0.6f; self.transientUntil = now + 2.2; }
    if (self.shownKind == k) [self bump];                          // same activity again: restart its pop (spam like iOS 16)
    dispatch_async(dispatch_get_main_queue(), ^{ [self tickActivity]; });   // show it now, not at the next 0.25 s tick
    W12_LOG(@"island: test %d", k);
}

- (void)openLowBat {
    CGSize ss = [UIScreen mainScreen].bounds.size;
    if (self.expanded || ss.width > ss.height || !W12Bool(@"island", NO)) return;
    self.lowBatCard = YES; self.expSlot = 0;
    UINotificationFeedbackGenerator *nf = [UINotificationFeedbackGenerator new]; [nf notificationOccurred:UINotificationFeedbackTypeWarning];
    [self buildExpand];
    self.expanded = YES; self.win.fullHit = YES;
    self.expDeadline = CACurrentMediaTime() + 6.5;
    W12PillView *pv = (W12PillView *)self.pill;
    pv.clipsToBounds = YES;
    [pv showContent:NO label:NO bars:NO];
    [pv addSubview:self.expView];
    [UIView animateWithDuration:0.2 animations:^{ self.pill2.alpha = 0; }];
    self.animateNext = YES; self.lastRect = CGRectZero;
    [self refresh];
    UIView *ev = self.expView;
    [UIView animateWithDuration:0.3 delay:0.14 options:0 animations:^{ ev.alpha = 1; } completion:nil];
    W12_LOG(@"island: low battery card (%d%%)", self.lowBatPct);
}

// ---- expanded card (long press) ----
- (CGFloat)expandedHeight {
    switch (self.expKind) { case 4: return 196; case 1: case 5: return 150; case 6: return 92; case 8: return 84; case 13: return 172; default: return 112; }
}
- (CGFloat)expandedWidth { return self.expKind == 13 ? 128 : MIN([UIScreen mainScreen].fixedCoordinateSpace.bounds.size.width - 16, 360); }
- (void)openBid:(NSString *)bid {
    if (!bid.length) return;
    UIApplication *app = [UIApplication sharedApplication];
    SEL sel = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    if ([app respondsToSelector:sel]) ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(app, sel, bid, NO);
}

- (void)cancelTimer {
    dispatch_async(self.mtQ, ^{
        @try {
            BOOL done = NO;
            for (NSString *n in @[@"cancelCurrentTimer", @"removeCurrentTimer", @"pauseCurrentTimer", @"stopCurrentTimer", @"cancelCurrentTimerSync"]) {
                SEL sel = NSSelectorFromString(n);
                if ([self.timerMgr respondsToSelector:sel]) { ((id (*)(id, SEL))objc_msgSend)(self.timerMgr, sel); done = YES; W12_LOG(@"island: timer stop via %@", n); break; }
            }
            if (!done) W12_LOG(@"island: no timer-stop selector on this iOS (see the MTTimerManager dump above)");
            self.timerFire = nil;
        } @catch (NSException *e) { W12_LOG(@"island: timer stop failed %@", e.reason); }
    });
}

- (void)endCall {
    @try {
        id cc = W12Call(NSClassFromString(@"TUCallCenter"), @selector(sharedInstance));
        NSArray *calls = W12Call(cc, @selector(currentCalls));
        SEL one = NSSelectorFromString(@"disconnectCall:");
        if ([calls isKindOfClass:[NSArray class]] && calls.count && [cc respondsToSelector:one]) {
            for (id c in calls) ((void (*)(id, SEL, id))objc_msgSend)(cc, one, c);
            return;
        }
        for (NSString *n in @[@"disconnectCurrentCallAndActivateHeld", @"disconnectAllCalls"]) {
            SEL sel = NSSelectorFromString(n);
            if ([cc respondsToSelector:sel]) { ((void (*)(id, SEL))objc_msgSend)(cc, sel); return; }
        }
        W12_LOG(@"island: cannot end call on this iOS");
    } @catch (NSException *e) { W12_LOG(@"island: end call failed %@", e.reason); }
}

- (W12IslandBtn *)circleBtn:(UIBezierPath *)gp fill:(BOOL)fill glyphColor:(UIColor *)gc bg:(UIColor *)bg act:(void (^)(void))act {
    W12IslandBtn *b = [[W12IslandBtn alloc] initWithFrame:CGRectMake(0, 0, 46, 46)];
    b.backgroundColor = bg; b.layer.cornerRadius = 23;
    [b setGlyphPath:gp color:gc filled:fill];
    b.act = act; return b;
}
- (W12IslandBtn *)textBtn:(NSString *)t act:(void (^)(void))act {
    W12IslandBtn *b = [[W12IslandBtn alloc] initWithFrame:CGRectMake(0, 0, 96, 42)];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18]; b.layer.cornerRadius = 21;
    W12FixedLabel *tl = [[W12FixedLabel alloc] initWithFrame:b.bounds]; tl.backgroundColor = [UIColor clearColor]; tl.userInteractionEnabled = NO;
    [tl lockFont:[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]]; tl.textColor = [UIColor whiteColor]; tl.textAlignment = NSTextAlignmentCenter; tl.text = t;
    tl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; [b addSubview:tl];
    b.act = act; return b;
}

- (UIView *)airplayGlyph {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 34, 34)]; v.userInteractionEnabled = NO;
    UIColor *c = [UIColor colorWithWhite:1 alpha:0.9];
    for (int i = 0; i < 2; i++) {
        CAShapeLayer *a = [CAShapeLayer layer]; a.fillColor = nil; a.strokeColor = c.CGColor; a.lineWidth = 2.4; a.lineCap = kCALineCapRound;
        CGFloat r = 9 + i * 6.5;
        a.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(17, 16.5) radius:r startAngle:M_PI * 0.8 endAngle:M_PI * 2.2 clockwise:YES].CGPath;
        [v.layer addSublayer:a];
    }
    CAShapeLayer *tri = [CAShapeLayer layer]; tri.fillColor = c.CGColor;
    UIBezierPath *tp = [UIBezierPath bezierPath]; [tp moveToPoint:CGPointMake(17, 17.5)]; [tp addLineToPoint:CGPointMake(24, 28.5)]; [tp addLineToPoint:CGPointMake(10, 28.5)]; [tp closePath];
    tri.path = tp.CGPath; [v.layer addSublayer:tri];
    return v;
}

- (void)buildExpand {
    [self.expView removeFromSuperview];
    // which activity: slot 0 = the main pill, slot 1 = the bubble
    NSDictionary *act = nil; int slot = self.expSlot;
    int kvs = slot < (int)self.vis.count ? [self.vis[slot][@"k"] intValue] : 0, kv0 = self.vis.count ? [self.vis[0][@"k"] intValue] : 0;
    if (slot < (int)self.vis.count && (kvs < 7 || kvs == 13)) act = self.vis[slot];
    else if (slot == 0 && self.acts.count && !(self.vis.count && (kv0 < 7 || kv0 == 13))) act = self.acts.firstObject;
    int k = [act[@"k"] intValue]; if (self.lowBatCard) k = 8; self.expKind = k;
    NSString *bid = act[@"bid"];
    CGFloat W = [self expandedWidth], H = [self expandedHeight];
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, H)]; v.alpha = 0; v.backgroundColor = [UIColor clearColor]; v.clipsToBounds = YES;
    __weak W12Island *wk = self;
    BOOL chg = [UIDevice currentDevice].batteryState == UIDeviceBatteryStateCharging || [UIDevice currentDevice].batteryState == UIDeviceBatteryStateFull;
    float lv = [UIDevice currentDevice].batteryLevel;
    int iconKind = k ? k : (chg ? 7 : (lv >= 0 && lv <= 0.2 ? 8 : 9));
    UIColor *tint = (k == 4 && gW12Tint) ? gW12Tint : [UIColor colorWithWhite:1 alpha:0.92];
    if (k == 5) tint = W12_GREEN;
    W12FixedLabel *(^mk)(CGRect, UIFont *, UIColor *) = ^W12FixedLabel *(CGRect f, UIFont *ft, UIColor *c) {
        W12FixedLabel *l = [[W12FixedLabel alloc] initWithFrame:f]; [l lockFont:ft]; l.textColor = c; [v addSubview:l]; return l;
    };
    UIFont *mono = [UIFont respondsToSelector:@selector(monospacedDigitSystemFontOfSize:weight:)] ? [UIFont monospacedDigitSystemFontOfSize:34 weight:UIFontWeightSemibold] : [UIFont boldSystemFontOfSize:34];
    self.expArt = nil; self.progFill = nil; self.progTrack = nil; self.tLeft = nil; self.tRight = nil;
    NSMutableArray<UIView *> *row = [NSMutableArray array];
    void (^touch)(void) = ^{ wk.expDeadline = CACurrentMediaTime() + 9; };

    if (k == 13) {                                   // ---- flashlight card: tall, beam of light, dotted arc, drag to set the brightness ----
        CGPoint ctr = CGPointMake(W / 2, 92);
        // beam
        CAGradientLayer *beam = [CAGradientLayer layer]; beam.frame = CGRectMake(0, 0, W, H); beam.type = kCAGradientLayerRadial;
        beam.colors = @[(id)[UIColor colorWithRed:0.82 green:0.88 blue:1 alpha:0.95].CGColor, (id)[UIColor colorWithRed:0.82 green:0.88 blue:1 alpha:0].CGColor];
        beam.startPoint = CGPointMake(0.5, 0.86); beam.endPoint = CGPointMake(1.0, 0.0);
        CAShapeLayer *cone = [CAShapeLayer layer]; UIBezierPath *cp = [UIBezierPath bezierPath];
        [cp moveToPoint:CGPointMake(W / 2 - 8, H - 44)]; [cp addLineToPoint:CGPointMake(W / 2 + 8, H - 44)];
        [cp addLineToPoint:CGPointMake(W / 2 + 58, 26)]; [cp addLineToPoint:CGPointMake(W / 2 - 58, 26)]; [cp closePath];
        cone.path = cp.CGPath; beam.mask = cone; beam.opacity = 0.4; [v.layer addSublayer:beam];
        // dotted track
        CAShapeLayer *dots = [CAShapeLayer layer];
        UIBezierPath *dp = [UIBezierPath bezierPath];
        for (int i = 0; i < 45; i++) {
            CGFloat a = (215 + 110.0 * i / 44.0) * M_PI / 180.0;
            [dp appendPath:[UIBezierPath bezierPathWithArcCenter:CGPointMake(ctr.x + 50 * cos(a), ctr.y + 50 * sin(a)) radius:1.35 startAngle:0 endAngle:2 * M_PI clockwise:YES]];
        }
        dots.path = dp.CGPath; dots.fillColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor; [v.layer addSublayer:dots];
        CAShapeLayer *arc = [CAShapeLayer layer]; arc.fillColor = nil; arc.strokeColor = [UIColor whiteColor].CGColor; arc.lineWidth = 3.4; arc.lineCap = kCALineCapRound; [v.layer addSublayer:arc];
        CAShapeLayer *sun = [CAShapeLayer layer]; sun.fillColor = [UIColor whiteColor].CGColor; sun.strokeColor = [UIColor whiteColor].CGColor; sun.lineWidth = 1.5; sun.lineCap = kCALineCapRound; [v.layer addSublayer:sun];
        // torch
        CAShapeLayer *torch = [CAShapeLayer layer]; torch.fillColor = [UIColor colorWithRed:0.86 green:0.84 blue:1 alpha:1].CGColor;
        UIBezierPath *tp = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(W / 2 - 11, H - 40, 22, 30) cornerRadius:6];
        [tp appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(W / 2 - 15, H - 48, 30, 12) cornerRadius:4]];
        torch.path = tp.CGPath; [v.layer addSublayer:torch];
        self.flL = @{@"arc": arc, @"sun": sun, @"beam": beam, @"c": [NSValue valueWithCGPoint:ctr]};
        UIPanGestureRecognizer *pg = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(torchPan:)]; [v addGestureRecognizer:pg];
        gFlDrag = NO; gFlFrac = (CGFloat)W12TorchLevel();
        self.expView = v; [self updateExpanded]; return;
    }
    if (k == 8) {                                    // ---- low battery card (like the iOS 26 one) ----
        UIColor *gray = [UIColor colorWithWhite:0.6 alpha:1];
        self.expTitle = mk(CGRectMake(26, 15, W - 26 - 100, 24), [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold], [UIColor whiteColor]);
        self.expSub = mk(CGRectMake(26, 41, W - 26 - 92, 20), [UIFont systemFontOfSize:15], gray);
        self.expBig = mk(CGRectZero, mono, [UIColor whiteColor]); self.expBig.hidden = YES;
        UIView *cap = [[UIView alloc] initWithFrame:CGRectMake(W - 22 - 68, (H - 46) / 2, 68, 46)];
        cap.layer.cornerRadius = 23; cap.userInteractionEnabled = NO; cap.backgroundColor = [UIColor colorWithRed:0.29 green:0.05 blue:0.07 alpha:1];
        CAShapeLayer *ring = [CAShapeLayer layer]; ring.frame = CGRectMake(14.5, 11.5, 36, 23); ring.fillColor = nil; ring.lineWidth = 1.6;
        ring.strokeColor = W12_RED.CGColor; ring.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 36, 23) cornerRadius:9].CGPath; ring.opacity = 0;
        [cap.layer addSublayer:ring];
        CAShapeLayer *body = [CAShapeLayer layer]; body.fillColor = nil; body.lineWidth = 2.3; body.strokeColor = W12_RED.CGColor;
        body.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(19.5, 15.5, 28, 15) cornerRadius:5.5].CGPath; [cap.layer addSublayer:body];
        CAShapeLayer *nub = [CAShapeLayer layer]; nub.fillColor = W12_RED.CGColor;
        nub.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(49.2, 20, 2.4, 6) cornerRadius:1.2].CGPath; [cap.layer addSublayer:nub];
        CAShapeLayer *fill = [CAShapeLayer layer]; fill.fillColor = W12_RED.CGColor;
        fill.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(22.5, 18.5, 8, 9) cornerRadius:3 ].CGPath; [cap.layer addSublayer:fill];
        [v addSubview:cap];
        self.lbCap = cap; self.lbRing = ring; self.lbBody = body; self.lbNub = nub; self.lbFill = fill; self.lbLast = NO;
        CABasicAnimation *sc = [CABasicAnimation animationWithKeyPath:@"transform.scale"]; sc.fromValue = @1.0; sc.toValue = @1.55;
        CABasicAnimation *op = [CABasicAnimation animationWithKeyPath:@"opacity"]; op.fromValue = @0.9; op.toValue = @0.0;
        CAAnimationGroup *grp = [CAAnimationGroup animation]; grp.animations = @[sc, op]; grp.duration = 1.5; grp.repeatCount = HUGE_VALF;
        grp.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        grp.beginTime = CACurrentMediaTime() + 0.5; grp.fillMode = kCAFillModeBackwards;
        [ring addAnimation:grp forKey:@"w12.lbpulse"];
        self.expView = v; [self updateExpanded]; return;
    }
    if (k == 4) {                                    // ---- music card, laid out like the iOS 16 one ----
        UIImageView *art = [[UIImageView alloc] initWithFrame:CGRectMake(24, 22, 64, 64)];
        art.layer.cornerRadius = 15; art.clipsToBounds = YES; art.contentMode = UIViewContentModeScaleAspectFill; art.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1];
        art.image = gW12Art ?: W12AppIcon(bid); [v addSubview:art]; self.expArt = art;
        self.expTitle = mk(CGRectMake(102, 30, W - 102 - 56, 22), [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold], [UIColor whiteColor]);
        self.expSub = mk(CGRectMake(102, 52, W - 102 - 56, 22), [UIFont systemFontOfSize:17], [UIColor colorWithWhite:0.55 alpha:1]);
        self.expBig = mk(CGRectZero, mono, [UIColor whiteColor]); self.expBig.hidden = YES;
        W12PillView *tmp = [[W12PillView alloc] initWithFrame:CGRectMake(0, 0, 200, 37)];
        [tmp setBarsColor:tint]; [tmp layoutIfNeeded]; [tmp startBars];
        UIView *bh = tmp.barsHost; [bh removeFromSuperview]; bh.alpha = 1; bh.transform = CGAffineTransformMakeScale(1.15, 1.3); bh.frame = CGRectMake(W - 24 - 25, 38, 25, 26); [v addSubview:bh];
        self.tLeft = mk(CGRectMake(24, 98, 44, 18), [UIFont systemFontOfSize:13 weight:UIFontWeightMedium], [UIColor colorWithWhite:0.55 alpha:1]);
        self.tRight = mk(CGRectMake(W - 24 - 44, 98, 44, 18), [UIFont systemFontOfSize:13 weight:UIFontWeightMedium], [UIColor colorWithWhite:0.55 alpha:1]); self.tRight.textAlignment = NSTextAlignmentRight;
        UIView *tr = [[UIView alloc] initWithFrame:CGRectMake(70, 105, W - 70 - 70, 5)]; tr.backgroundColor = [UIColor colorWithWhite:0.32 alpha:1]; tr.layer.cornerRadius = 2.5; tr.clipsToBounds = YES; [v addSubview:tr];
        UIView *fl = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 5)]; fl.backgroundColor = [UIColor whiteColor]; [tr addSubview:fl];
        self.progTrack = tr; self.progFill = fl;
        UIColor *w = [UIColor whiteColor], *bg = [UIColor clearColor];
        CGFloat cy = 150;
        W12IslandBtn *pv_ = [self circleBtn:W12SkipPath(CGRectMake(0, 0, 36, 28), YES) fill:YES glyphColor:w bg:bg act:^{ touch(); W12MediaCmd(5); }];
        W12IslandBtn *pp = [self circleBtn:W12PausePath(CGRectMake(0, 0, 26, 32)) fill:YES glyphColor:w bg:bg act:^{ touch(); W12MediaCmd(2); dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [wk updateExpanded]; }); }];
        W12IslandBtn *nx = [self circleBtn:W12SkipPath(CGRectMake(0, 0, 36, 28), NO) fill:YES glyphColor:w bg:bg act:^{ touch(); W12MediaCmd(4); }];
        for (W12IslandBtn *b in @[pv_, pp, nx]) { b.maxGlyph = 36; b.bounds = CGRectMake(0, 0, 60, 56); b.layer.cornerRadius = 0; [b setGlyphPath:b == pp ? W12PausePath(CGRectMake(0, 0, 26, 32)) : W12SkipPath(CGRectMake(0, 0, 36, 28), b == pv_) color:w filled:YES]; }
        pv_.center = CGPointMake(W * 0.295, cy); pp.center = CGPointMake(W * 0.5, cy); nx.center = CGPointMake(W * 0.705, cy);
        [v addSubview:pv_]; [v addSubview:pp]; [v addSubview:nx]; self.expPlay = pp;
        UIView *ap = [self airplayGlyph]; ap.center = CGPointMake(W * 0.885, cy); [v addSubview:ap];
        self.expView = v; [self updateExpanded]; return;
    }

    // ---- the other cards ----
    W12PillView *tmp = [[W12PillView alloc] initWithFrame:CGRectMake(0, 0, 200, 37)];
    [tmp setIconKind:iconKind bid:bid];
    [tmp setBarsColor:tint]; [tmp layoutIfNeeded];
    UIView *ic = tmp.iconHost; [ic removeFromSuperview]; ic.alpha = 1; ic.bounds = CGRectMake(0, 0, 22, 22); ic.center = CGPointMake(40, 36);
    ic.transform = CGAffineTransformMakeScale(1.9, 1.9); [v addSubview:ic];
    if (k == 5) { [tmp startBars]; UIView *bh = tmp.barsHost; [bh removeFromSuperview]; bh.alpha = 1; bh.frame = CGRectMake(W - 22 - 22, 26, 20, 18); [v addSubview:bh]; }
    self.expTitle = mk(CGRectMake(74, 14, W - 74 - 60, 22), [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold], [UIColor whiteColor]);
    self.expSub = mk(CGRectMake(74, 36, W - 74 - 60, 18), [UIFont systemFontOfSize:14], [UIColor colorWithWhite:0.62 alpha:1]);
    self.expBig = mk(CGRectMake(74, 34, W - 74 - 20, 44), mono, (k == 0) ? [UIColor whiteColor] : W12_ORANGE);
    self.expPlay = nil;
    if (k == 1) {
        [row addObject:[self textBtn:W12Tr(@"Mở") act:^{ [wk openBid:bid]; [wk collapse]; }]];
        [row addObject:[self circleBtn:[UIBezierPath bezierPathWithRect:CGRectMake(0, 0, 16, 16)] fill:YES glyphColor:[UIColor whiteColor] bg:[UIColor colorWithRed:1 green:0.23 blue:0.19 alpha:1] act:^{ [wk cancelTimer]; [wk collapse]; }]];
    } else if (k == 5) {
        [row addObject:[self textBtn:W12Tr(@"Mở") act:^{ [wk openBid:bid]; [wk collapse]; }]];
        UIBezierPath *hp = W12HandsetPath(CGRectMake(0, 0, 22, 22)); [hp applyTransform:CGAffineTransformMakeRotation(M_PI * 0.75)];
        W12IslandBtn *end = [self circleBtn:hp fill:NO glyphColor:[UIColor whiteColor] bg:[UIColor colorWithRed:1 green:0.23 blue:0.19 alpha:1] act:^{ [wk endCall]; [wk collapse]; }];
        [row addObject:end];
    } else if (k == 2 || k == 3) {
        [row addObject:[self textBtn:W12Tr(@"Mở") act:^{ [wk openBid:bid]; [wk collapse]; }]];
    }
    CGFloat total = 0; for (UIView *b in row) total += b.bounds.size.width; total += 18 * MAX(0, (int)row.count - 1);
    CGFloat x = (W - total) / 2, y = H - 46 - 14;
    for (UIView *b in row) { b.frame = CGRectMake(x, y, b.bounds.size.width, b.bounds.size.height); [v addSubview:b]; x += b.bounds.size.width + 18; }
    if ((k == 2 || k == 3) && row.count == 1) { UIView *b = row[0]; b.frame = CGRectMake(W - b.bounds.size.width - 22, (H - b.bounds.size.height) / 2 + 12, b.bounds.size.width, b.bounds.size.height); }   // time on the left, button on the right: no overlap
    self.expView = v;
    [self updateExpanded];
}

static NSString *W12MS(double t) { if (t < 0) t = 0; long s = (long)t; return [NSString stringWithFormat:@"%ld:%02ld", s / 60, s % 60]; }

- (void)updateExpanded {
    if (!self.expanded || !self.expView) return;
    int k = self.expKind;
    UIDevice *d = [UIDevice currentDevice];
    BOOL chg = d.batteryState == UIDeviceBatteryStateCharging || d.batteryState == UIDeviceBatteryStateFull;
    CGFloat W = self.expView.bounds.size.width;
    NSString *txt = [self actWithKind:k][@"text"];
    if (k == 0) {
        self.expTitle.text = chg ? W12Tr(@"Đang sạc") : @"Pin";
        self.expBig.text = self.battText ?: @"--%";
        self.expSub.hidden = YES; self.expBig.frame = CGRectMake(74, 36, W - 74 - 20, 44);
        self.expBig.textAlignment = NSTextAlignmentLeft;
    } else if (k == 4) {
        id mc = W12Call(NSClassFromString(@"SBMediaController"), @selector(sharedInstance));
        NSString *title = self.npTitle.length ? self.npTitle : W12Call(mc, NSSelectorFromString(@"nowPlayingTitle"));
        NSString *artist = self.npArtist.length ? self.npArtist : W12Call(mc, NSSelectorFromString(@"nowPlayingArtist"));
        self.expTitle.text = [title isKindOfClass:[NSString class]] && title.length ? title : W12Tr(@"Đang phát");
        self.expSub.text = [artist isKindOfClass:[NSString class]] ? artist : @"";
        BOOL playing = mc && [mc respondsToSelector:@selector(isPlaying)] && ((BOOL (*)(id, SEL))objc_msgSend)(mc, @selector(isPlaying));
        [self.expPlay setGlyphPath:(playing ? W12PausePath(CGRectMake(0, 0, 26, 32)) : W12PlayPath(CGRectMake(0, 0, 26, 32))) color:[UIColor whiteColor] filled:YES];
        if (gW12Art && self.expArt.image != gW12Art) self.expArt.image = gW12Art;
        double el = self.npElapsed; if (self.npStamp && self.npRate > 0 && playing) el += [[NSDate date] timeIntervalSinceDate:self.npStamp] * self.npRate;
        if (self.npDur > 1) {
            el = MIN(el, self.npDur);
            self.tLeft.text = W12MS(el); self.tRight.text = [@"-" stringByAppendingString:W12MS(self.npDur - el)];
            self.progFill.frame = CGRectMake(0, 0, self.progTrack.bounds.size.width * (el / self.npDur), 5);
        } else { self.tLeft.text = @"--:--"; self.tRight.text = @""; self.progFill.frame = CGRectMake(0, 0, 0, 5); }
    } else if (k == 1 || k == 2 || k == 3) {
        self.expTitle.text = k == 1 ? W12Tr(@"Hẹn giờ") : (k == 2 ? W12Tr(@"Bấm giờ") : W12Tr(@"Báo thức"));
        self.expSub.hidden = YES; self.expBig.text = txt ?: @"";
        self.expTitle.frame = CGRectMake(74, 10, W - 134, 22);
        self.expBig.frame = CGRectMake(74, 30, (k == 1) ? W - 74 - 20 : W - 74 - 130, 44);
    } else if (k == 5) {
        self.expTitle.text = W12Tr(@"Cuộc gọi"); self.expSub.text = W12Tr(@"Đang kết nối"); self.expBig.hidden = YES;
    } else if (k == 13) {
        CGFloat f = gFlDrag ? gFlFrac : (CGFloat)W12TorchLevel(), pr = MAX(0.06, MIN(1, f / 4.0));
        CAShapeLayer *arc = self.flL[@"arc"], *sun = self.flL[@"sun"]; CALayer *beam = self.flL[@"beam"]; CGPoint c = [self.flL[@"c"] CGPointValue];
        CGFloat R = 31 + 8 * pr, a0 = 215 * M_PI / 180.0, a1 = a0 + 110 * M_PI / 180.0 * pr;
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        arc.path = [UIBezierPath bezierPathWithArcCenter:c radius:R startAngle:a0 endAngle:a1 clockwise:YES].CGPath;
        CGPoint sp = CGPointMake(c.x + (R + 10) * cos(a1), c.y + (R + 10) * sin(a1));
        UIBezierPath *sb = [UIBezierPath bezierPathWithArcCenter:sp radius:2.6 startAngle:0 endAngle:2 * M_PI clockwise:YES];
        for (int i = 0; i < 8; i++) { CGFloat ra = i * M_PI / 4; [sb moveToPoint:CGPointMake(sp.x + 4.4 * cos(ra), sp.y + 4.4 * sin(ra))]; [sb addLineToPoint:CGPointMake(sp.x + 6.2 * cos(ra), sp.y + 6.2 * sin(ra))]; }
        sun.path = sb.CGPath; beam.opacity = 0.34 + 0.165 * f;
        [CATransaction commit];
    } else if (k == 8) {
        BOOL lpm = W12LPM();
        float lf = d.batteryLevel; int pct = lf >= 0 ? (int)roundf(lf * 100) : self.lowBatPct;
        self.expTitle.text = [NSString stringWithFormat:W12Tr(@"%d%% Pin yếu"), pct];
        UIColor *yel = [UIColor colorWithRed:1 green:0.80 blue:0.04 alpha:1];
        if (lpm != self.lbLast || !self.lbOn) {
            self.lbLast = lpm; self.lbOn = YES;
            self.expSub.text = lpm ? W12Tr(@"Đã bật Chế độ nguồn điện thấp") : W12Tr(@"Chạm để bật Chế độ nguồn điện thấp");
            self.expSub.textColor = lpm ? yel : [UIColor colorWithWhite:0.6 alpha:1];
            [UIView animateWithDuration:0.3 animations:^{ self.lbCap.backgroundColor = lpm ? yel : [UIColor colorWithRed:0.29 green:0.05 blue:0.07 alpha:1]; }];
            UIColor *gc = lpm ? [UIColor colorWithWhite:0.08 alpha:1] : W12_RED;
            [CATransaction begin]; [CATransaction setAnimationDuration:0.3];
            self.lbBody.strokeColor = gc.CGColor; self.lbNub.fillColor = gc.CGColor; self.lbFill.fillColor = gc.CGColor;
            self.lbRing.hidden = lpm;
            [CATransaction commit];
        }
    } else if (k == 6) {
        self.expTitle.text = W12Tr(@"Đang quay màn hình"); self.expSub.text = @""; self.expBig.hidden = YES;
        self.expTitle.frame = CGRectMake(74, 30, W - 134, 24);
    }
}

- (void)held:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan || self.expanded) return;
    CGSize ss = [UIScreen mainScreen].bounds.size;
    if (ss.width > ss.height || !W12Bool(@"island", NO)) return;
    self.expSlot = (g.view == self.pill2) ? 1 : 0;
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]; [fb impactOccurred];
    [self buildExpand];
    self.expanded = YES; self.win.fullHit = YES;
    self.expDeadline = CACurrentMediaTime() + 9;
    W12PillView *pv = (W12PillView *)self.pill;
    pv.clipsToBounds = YES;
    [pv showContent:NO label:NO bars:NO];
    [pv addSubview:self.expView];
    [UIView animateWithDuration:0.2 animations:^{ self.pill2.alpha = 0; }];
    self.animateNext = YES; self.lastRect = CGRectZero;
    [self refresh];
    UIView *ev = self.expView;
    [UIView animateWithDuration:0.3 delay:0.14 options:0 animations:^{ ev.alpha = 1; } completion:nil];
    W12_LOG(@"island: expanded (kind %d slot %d)", self.expKind, self.expSlot);
    { NSMutableString *o = [NSMutableString stringWithFormat:@"island: expand frames pill=%@ ev=%@:", NSStringFromCGRect(self.pill.frame), NSStringFromCGRect(self.expView.frame)]; for (UIView *c in self.expView.subviews) [o appendFormat:@" [%@ %@]", NSStringFromClass([c class]), NSStringFromCGRect(c.frame)]; W12_LOG(@"%@", o); }
}

- (void)collapse {
    if (!self.expanded) return;
    self.expanded = NO; self.win.fullHit = NO; self.lowBatCard = NO; self.lbCap = nil;
    UIView *ev = self.expView; self.expView = nil;
    [UIView animateWithDuration:0.14 animations:^{ ev.alpha = 0; } completion:^(BOOL f) { [ev removeFromSuperview]; }];
    W12PillView *pv = (W12PillView *)self.pill;
    int k = self.shownKind;
    [pv showContent:(k != 0 && k != 12) label:(k == 1 || k == 2 || k == 3 || k == 7 || k == 8 || k == 9 || k == 10 || k == 11) bars:(k == 4 || k == 5)];
    [pv showVolume:(k == 12)];
    if (self.shownKind2) { [UIView animateWithDuration:0.3 delay:0.25 options:0 animations:^{ self.pill2.alpha = 1; } completion:nil]; }
    self.animateNext = YES; self.lastRect = CGRectZero;
    [self refresh];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (!self.expanded) pv.clipsToBounds = NO; });
}

- (void)outsideTap:(UITapGestureRecognizer *)g {
    if (!self.expanded) return;
    CGPoint p = [g locationInView:g.view];
    if (!CGRectContainsPoint(self.pill.frame, p)) [self collapse];
}

// Battery events shown on the island for a few seconds: plugging in, 20 % and 10 %.
- (void)batteryTick {
    UIDevice *d = [UIDevice currentDevice];
    float lvl = d.batteryLevel; UIDeviceBatteryState st = d.batteryState;
    BOOL chg = (st == UIDeviceBatteryStateCharging || st == UIDeviceBatteryStateFull);
    if (lvl >= 0) self.battText = [NSString stringWithFormat:@"%d%%", (int)roundf(lvl * 100)];
    CFTimeInterval now = CACurrentMediaTime();
    if (!self.batInit) {
        self.batInit = YES; self.lastChg = chg ? 1 : 0;
        self.warned20 = (lvl >= 0 && lvl <= 0.20); self.warned10 = (lvl >= 0 && lvl <= 0.10);
        return;
    }
    if (chg && !self.lastChg) { self.transientKind = 7; self.transientUntil = now + 3.6; W12_LOG(@"island: charger plugged in (%@)", self.battText); }
    if (!chg && self.lastChg) { self.transientKind = 9; self.transientText = self.battText; self.transientUntil = now + 2.8; W12_LOG(@"island: charger unplugged (%@)", self.battText); }
    if (chg && !self.lastChg) self.transientText = self.battText;
    self.lastChg = chg ? 1 : 0;
    if (lvl < 0) return;
    if (chg || lvl > 0.22) self.warned20 = NO;
    if (chg || lvl > 0.12) self.warned10 = NO;
    if (!chg && lvl <= 0.10 && !self.warned10) { self.warned10 = YES; self.warned20 = YES; self.lowBatPending = YES; self.lowBatPct = (int)roundf(lvl * 100); W12_LOG(@"island: battery 10%%"); }
    else if (!chg && lvl <= 0.20 && !self.warned20) { self.warned20 = YES; self.lowBatPending = YES; self.lowBatPct = (int)roundf(lvl * 100); W12_LOG(@"island: battery 20%%"); }
}

- (void)torchPan:(UIPanGestureRecognizer *)g {
    static CGFloat start; static long lastLv;
    if (g.state == UIGestureRecognizerStateBegan) { start = (CGFloat)W12TorchLevel(); gFlFrac = start; gFlDrag = YES; lastLv = (long)start; }
    CGFloat dy = [g translationInView:g.view].y;
    gFlFrac = MAX(0, MIN(4, start - dy / 26.0));
    self.expDeadline = CACurrentMediaTime() + 9;
    long lv = lround(gFlFrac);
    if (lv != lastLv) { lastLv = lv; W12SetTorchLevel((unsigned long long)lv); UISelectionFeedbackGenerator *sf = [UISelectionFeedbackGenerator new]; [sf selectionChanged]; }
    [self updateExpanded];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled || g.state == UIGestureRecognizerStateFailed) {
        gFlDrag = NO;
        if (lround(gFlFrac) <= 0) { W12SetTorchLevel(0); [self collapse]; }
    }
}

// Volume and ringer switch: shown on the island, the iOS 12 HUD stays hidden meanwhile.
- (void)volPoll {
    CFTimeInterval now = CACurrentMediaTime();
    if (!W12Bool(@"islandVol", YES)) { gHudHide = NO; return; }
    gHudHide = YES;
    static id avs; static BOOL tried;
    if (!tried) { tried = YES; Class c = NSClassFromString(@"AVSystemController"); avs = c ? W12Call(c, NSSelectorFromString(@"sharedAVSystemController")) : nil; if (!avs) W12_LOG(@"island: no AVSystemController, volume island off"); }
    if (avs) {
        float v = -1; SEL gs = NSSelectorFromString(@"getVolume:forCategory:");
        if ([avs respondsToSelector:gs]) ((BOOL (*)(id, SEL, float *, id))objc_msgSend)(avs, gs, &v, @"Audio/Video");
        if (v >= 0) {
            if (!self.volInit) { self.volInit = YES; self.volLevel = v; }
            else if (fabsf(v - self.volLevel) > 0.004f) {
                self.volLevel = v;
                if (self.transientKind != 12 || now >= self.transientUntil || self.shownKind != 12) { self.transientKind = 12; }
                self.transientKind = 12; self.transientText = @""; self.transientUntil = now + 1.9;
            }
        }
    }
    if (!self.ringToken) { notify_register_check("com.apple.springboard.ringerstate", &_ringToken); self.ringState = -1; }
    uint64_t rs = 0; notify_get_state(self.ringToken, &rs);
    int cur = rs ? 1 : 0;
    if (self.ringState == -1) { self.ringState = cur; W12_LOG(@"island: ringer state %d", cur); }
    else if (cur != self.ringState) {
        self.ringState = cur; W12_LOG(@"island: ringer state -> %d", cur);
        self.transientKind = cur ? 10 : 11; self.transientText = cur ? W12Tr(@"Chuông") : W12Tr(@"Im lặng"); self.transientUntil = now + 2.2;
    }
}

- (void)showBubble:(int)k bid:(NSString *)bid {
    W12PillView *p2 = self.pill2;
    if (k) {
        [p2 setIconKind:k bid:bid];
        [p2 setBarsColor:(k == 5 ? W12_GREEN : (k == 4 ? (gW12Tint ?: [UIColor colorWithWhite:1 alpha:0.92]) : W12_ORANGE))];
        BOOL wasHidden = p2.hidden || p2.alpha < 0.05;
        p2.hidden = NO; p2.userInteractionEnabled = YES; [p2 setNeedsLayout];
        CALayer *pl = p2.layer;
        [CATransaction begin]; [CATransaction setAnimationDuration:0.3];
        pl.borderWidth = W12IslandBorderW(); pl.borderColor = [UIColor colorWithWhite:0.55 alpha:MAX(0, _borderAlpha)].CGColor;
        [CATransaction commit];
        if (wasHidden) {                                          // starts hidden behind the main pill, springs out to its place
            CGFloat dx = -(self.pill.bounds.size.width / 2 + 8 + p2.bounds.size.width / 2);
            p2.transform = CGAffineTransformScale(CGAffineTransformMakeTranslation(dx, 0), 0.5, 0.5); p2.alpha = 1;
        }
        [p2 showContent:YES label:NO bars:(k == 5)];
        [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.72 initialSpringVelocity:0.7 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
            p2.transform = CGAffineTransformIdentity; p2.alpha = self.expanded ? 0 : 1;
        } completion:nil];
    } else {
        [p2 showContent:NO label:NO bars:NO];
        p2.userInteractionEnabled = NO;
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            CGFloat dx = -(self.pill.bounds.size.width / 2 + 8 + p2.bounds.size.width / 2);
            p2.transform = CGAffineTransformScale(CGAffineTransformMakeTranslation(dx, 0), 0.5, 0.5); p2.alpha = 0;
        } completion:^(BOOL f) { if (!self.shownKind2) p2.hidden = YES; }];
    }
}

- (void)tickActivity {
    [self syncHost];
    W12FaceTick();
    BOOL on = W12Bool(@"island", NO) && W12Bool(@"islandLive", YES) && self.win && !self.win.hidden;
    if (!on) {
        if (self.shownKind || self.shownKind2) {
            self.acts = nil; self.vis = nil; self.actKind = 0; self.shownKind = 0; self.shownKind2 = 0; self.pill.userInteractionEnabled = NO;
            [(W12PillView *)self.pill showContent:NO label:NO bars:NO]; [self showBubble:0 bid:nil]; self.lastRect = CGRectZero; [self refresh];
        }
        return;
    }
    static unsigned n = 0; if ((n++ % 4) == 0) [self readClock];       // clock data: once a second
    { BOOL ls = W12IsLandscape(); if (ls != self.lastLand) { self.lastLand = ls; [self refresh]; if (self.win.hidden) return; } }
    [self volPoll];
    [self pollActivity];
    if ([self actWithKind:4]) [self fetchNowPlaying]; else if (gW12Art) { gW12Art = nil; gW12Tint = nil; self.npArtLen = 0; self.artDirty = YES; self.npTitle = nil; }
    W12PillView *pv = (W12PillView *)self.pill;
    // What the island SHOWS: nothing (plain black) while the app that owns an activity is open, and nothing before the card has landed in it.
    NSMutableArray *vis = [NSMutableArray array];
    { id fa = W12FrontApp(); id fb = W12Call(fa, @selector(bundleIdentifier)); NSString *front = [fb isKindOfClass:[NSString class]] ? fb : nil;
      for (NSDictionary *a in self.acts) { if (front && [a[@"bid"] isEqualToString:front]) continue; [vis addObject:a]; } }
    if (CACurrentMediaTime() < self.expandAfter) [vis removeAllObjects];
    [self batteryTick];
    if (self.lowBatPending && !self.expanded && CACurrentMediaTime() >= self.expandAfter) { self.lowBatPending = NO; if (!W12LPM()) [self openLowBat]; }
    if (CACurrentMediaTime() < self.transientUntil) [vis insertObject:@{@"k": @(self.transientKind), @"text": ((self.transientKind == 7 || self.transientKind == 9 || self.transientKind == 8) ? (self.transientText.length ? self.transientText : self.battText) : self.transientText) ?: @""} atIndex:0];
    self.vis = vis;
    int uiKind = vis.count ? [vis[0][@"k"] intValue] : 0, uiKind2 = vis.count > 1 ? [vis[1][@"k"] intValue] : 0;
    NSString *uiBid = vis.count ? vis[0][@"bid"] : nil, *uiBid2 = vis.count > 1 ? vis[1][@"bid"] : nil;
    if (self.expanded) {
        BOOL gone = (self.expKind == 8) ? NO : (self.expKind ? ([self actWithKind:self.expKind] == nil) : (self.acts.count > 0));
        if (CACurrentMediaTime() > self.expDeadline || gone || !W12Bool(@"island", NO)) [self collapse];
        else [self updateExpanded];
    }
    BOOL artChanged = NO;
    if (self.artDirty) { self.artDirty = NO; artChanged = YES; }
    if (uiKind != self.shownKind || (uiKind == 4 && ![uiBid isEqualToString:self.lastBid]) || (uiKind == 4 && artChanged)) {
        int k = uiKind; int oldK = self.shownKind;
        self.shownKind = k; self.lastBid = uiBid; self.shownBid = uiBid;
        self.animateNext = YES;
        pv.userInteractionEnabled = YES;
        if (k) {
            [pv setIconKind:k bid:uiBid];
            [pv setBarsColor:(k == 5 ? W12_GREEN : (k == 4 ? (gW12Tint ?: [UIColor colorWithWhite:1 alpha:0.92]) : W12_ORANGE))];
            pv.label.textColor = (k == 7) ? W12_GREEN : (k == 8 ? W12_RED : ((k == 9 || k == 10) ? [UIColor whiteColor] : (k == 11 ? W12_RED : W12_ORANGE)));
            if (k == 12) [pv setVolume:self.volLevel];
            NSString *tx = vis[0][@"text"];
            if (tx) pv.label.text = tx;
        }
        [self refresh];
        [pv setNeedsLayout];
        [pv showContent:(k != 0 && k != 12 && !self.expanded) label:(k == 1 || k == 2 || k == 3 || k == 7 || k == 8 || k == 9 || k == 10 || k == 11) bars:(k == 4 || k == 5)];
        [pv showVolume:(k == 12 && !self.expanded)];
        W12_LOG(@"island: showing %d (%@)", k, uiBid);
    } else if (uiKind == 4 && gW12Tint) { [pv setBarsColor:gW12Tint]; }
    if (uiKind2 != self.shownKind2 || (uiKind2 == 4 && ![uiBid2 isEqualToString:self.lastBid2]) || (uiKind2 == 4 && artChanged)) {
        BOOL pairChanged = (uiKind2 != 0) != (self.shownKind2 != 0);
        self.shownKind2 = uiKind2; self.lastBid2 = uiBid2; self.shownBid2 = uiBid2;
        if (pairChanged) { self.animateNext = YES; self.lastRect = CGRectZero; [self refresh]; [pv setNeedsLayout]; }   // the pair is centred and the main pill narrows
        [self showBubble:uiKind2 bid:uiBid2];
        W12_LOG(@"island: bubble %d (%@)", uiKind2, uiBid2);
    }
    if (self.shownKind == 12) [pv setVolume:self.volLevel];
    if (self.shownKind && vis.count) { NSString *tx = vis[0][@"text"]; if (tx && ![pv.label.text isEqualToString:tx]) pv.label.text = tx; }
}

- (void)setBorderAlpha:(double)a {
    if (fabs(a - _borderAlpha) < 0.03) return;
    _borderAlpha = a;
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.25];
    self.pill.layer.borderColor = [UIColor colorWithWhite:0.55 alpha:a].CGColor;
    self.pill2.layer.borderColor = [UIColor colorWithWhite:0.55 alpha:a].CGColor;
    [CATransaction commit];
}

// Mean luminance (0..1) of the ring of pixels just around the pill, taken from a screen capture.
- (void)sample {
    if (!W12Bool(@"island", NO) || self.win.hidden || self.sampling) return;
    if (!W12Bool(@"islandBorder", YES)) { [self setBorderAlpha:0]; return; }
    uint64_t blank = 0; notify_get_state(self.blankToken, &blank);
    if (blank) return;                                   // screen is off
    if (!self.screenImage) {
        if (!self.warnedNoImage) { self.warnedNoImage = YES; W12_LOG(@"island: UIGetScreenImage missing, using a constant faint outline"); }
        [self setBorderAlpha:0.35];
        return;
    }
    CGRect pr = self.lastRect;
    self.sampling = YES;
    W12ScreenImageFn fn = self.screenImage;
    __weak W12Island *weak = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        double luma = -1;
        CGImageRef img = fn();
        if (img) {
            double sc = (double)CGImageGetWidth(img) / [UIScreen mainScreen].bounds.size.width;
            CGRect reg = CGRectMake(MAX(0, pr.origin.x - 16), MAX(0, pr.origin.y - 6), pr.size.width + 32, pr.size.height + 20);
            int px = (int)(reg.origin.x * sc), py = (int)(reg.origin.y * sc), pw = (int)(reg.size.width * sc), ph = (int)(reg.size.height * sc);
            if (pw > 0 && ph > 0 && pw < 1200 && ph < 400) {
                uint8_t *buf = calloc((size_t)pw * ph, 4);
                CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                CGContextRef ctx = CGBitmapContextCreate(buf, pw, ph, 8, pw * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
                if (ctx) {
                    double imgH = (double)CGImageGetHeight(img), imgW = (double)CGImageGetWidth(img);
                    CGContextDrawImage(ctx, CGRectMake(-px, -(imgH - py - ph), imgW, imgH), img);
                    CGRect hole = CGRectMake((pr.origin.x - 2) * sc - px, (pr.origin.y - 2) * sc - py,
                                             (pr.size.width + 4) * sc, (pr.size.height + 4) * sc);
                    double sum = 0; long n = 0;
                    for (int y = 0; y < ph; y += 2) for (int x = 0; x < pw; x += 2) {
                        if (CGRectContainsPoint(hole, CGPointMake(x, y))) continue;
                        uint8_t *q = buf + ((size_t)y * pw + x) * 4;
                        sum += (0.299 * q[0] + 0.587 * q[1] + 0.114 * q[2]) / 255.0; n++;
                    }
                    if (n > 0) luma = sum / n;
                    CGContextRelease(ctx);
                }
                CGColorSpaceRelease(cs);
                free(buf);
            }
            CGImageRelease(img);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            W12Island *s = weak; if (!s) return;
            s.sampling = NO;
            if (luma < 0) return;
            // black-ish surroundings (<= 0.06) => full outline; fades out by 0.20
            double a = 0.85 * MAX(0.0, MIN(1.0, (0.20 - luma) / 0.14));
            [s setBorderAlpha:a];
        });
    });
}
@end

static W12Island *gIsland;

// MARK: - Face ID unlock animation (card growing out of the island) + padlock in the island on the Lock Screen

static UIView *gFidCard, *gFidCV, *gFidBV, *gFidLock;
static CAShapeLayer *gFidShackle;
static BOOL gFidBusy, gFidLockShown, gFidShown, gFidReleasing, gFidPending; static CFTimeInterval gFidLast, gFidUnlockAt; static int gFidToken; static CGFloat gFidP2A;
#define W12_FIDGREEN [UIColor colorWithRed:0.42 green:0.93 blue:0.46 alpha:1]

// Gaussian blur filter of Core Animation (private CAFilter; nil when this iOS does not have it).
static id W12FidBlur(CGFloat r) {
    Class c = NSClassFromString(@"CAFilter"); if (!c) return nil;
    @try {
        id f = ((id (*)(id, SEL, id))objc_msgSend)(c, NSSelectorFromString(@"filterWithType:"), @"gaussianBlur");
        if (!f) return nil;
        [f setValue:@"fidblur" forKey:@"name"]; [f setValue:@(r) forKey:@"inputRadius"];
        return f;
    } @catch (NSException *e) { return nil; }
}
static void W12FidBlurTo(CALayer *l, CGFloat from, CGFloat to, CFTimeInterval dur, CFTimeInterval delay) {
    if (!l.filters.count) return;
    @try {
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"filters.fidblur.inputRadius"];
        a.fromValue = @(from); a.toValue = @(to); a.duration = dur; a.beginTime = CACurrentMediaTime() + delay; a.fillMode = kCAFillModeBoth;
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [l addAnimation:a forKey:@"w12.fidblur"];
        [l setValue:@(to) forKeyPath:@"filters.fidblur.inputRadius"];
    } @catch (NSException *e) {}
}

// The Face ID glyph: four corners, two eyes, nose and smile (60 x 60).
static CAShapeLayer *W12FidGlyph(void) {
    CGFloat L = 16, R = 9, W = 60;
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(0, L)]; [p addLineToPoint:CGPointMake(0, R)]; [p addArcWithCenter:CGPointMake(R, R) radius:R startAngle:M_PI endAngle:1.5 * M_PI clockwise:YES]; [p addLineToPoint:CGPointMake(L, 0)];
    [p moveToPoint:CGPointMake(W - L, 0)]; [p addLineToPoint:CGPointMake(W - R, 0)]; [p addArcWithCenter:CGPointMake(W - R, R) radius:R startAngle:1.5 * M_PI endAngle:2 * M_PI clockwise:YES]; [p addLineToPoint:CGPointMake(W, L)];
    [p moveToPoint:CGPointMake(W, W - L)]; [p addLineToPoint:CGPointMake(W, W - R)]; [p addArcWithCenter:CGPointMake(W - R, W - R) radius:R startAngle:0 endAngle:0.5 * M_PI clockwise:YES]; [p addLineToPoint:CGPointMake(W - L, W)];
    [p moveToPoint:CGPointMake(L, W)]; [p addLineToPoint:CGPointMake(R, W)]; [p addArcWithCenter:CGPointMake(R, W - R) radius:R startAngle:0.5 * M_PI endAngle:M_PI clockwise:YES]; [p addLineToPoint:CGPointMake(0, W - L)];
    [p moveToPoint:CGPointMake(21, 21)]; [p addLineToPoint:CGPointMake(21, 26)];
    [p moveToPoint:CGPointMake(39, 21)]; [p addLineToPoint:CGPointMake(39, 26)];
    [p moveToPoint:CGPointMake(30, 22)]; [p addLineToPoint:CGPointMake(30, 33)]; [p addLineToPoint:CGPointMake(27.6, 33)];
    [p moveToPoint:CGPointMake(20, 40)]; [p addQuadCurveToPoint:CGPointMake(40, 40) controlPoint:CGPointMake(30, 50)];
    CAShapeLayer *s = [CAShapeLayer layer]; s.bounds = CGRectMake(0, 0, W, W); s.path = p.CGPath; s.fillColor = nil;
    s.strokeColor = W12_FIDGREEN.CGColor; s.lineWidth = 3.2; s.lineCap = kCALineCapRound; s.lineJoin = kCALineJoinRound;
    return s;
}

// The scanning orb: three rings tumbling in 3D around each other.
static CALayer *W12FidOrb(CGFloat lw, CGFloat alpha, CGFloat blur) {
    CALayer *orb = [CALayer layer]; orb.bounds = CGRectMake(0, 0, 90, 90);
    CATransform3D t = CATransform3DIdentity; t.m34 = -1.0 / 230;
    double zs[3] = {0, M_PI / 3, 2 * M_PI / 3}, dur[3] = {0.74, 0.92, 1.12}, ph[3] = {0, 0.31, 0.57};
    for (int i = 0; i < 3; i++) {
        CALayer *w = [CALayer layer]; w.bounds = orb.bounds; w.position = CGPointMake(45, 45);
        w.transform = CATransform3DMakeRotation(zs[i], 0, 0, 1); w.sublayerTransform = t;
        CAShapeLayer *r = [CAShapeLayer layer]; r.bounds = CGRectMake(0, 0, 60, 60); r.position = CGPointMake(45, 45);
        r.path = [UIBezierPath bezierPathWithOvalInRect:r.bounds].CGPath; r.fillColor = nil;
        r.strokeColor = [W12_FIDGREEN colorWithAlphaComponent:alpha].CGColor; r.lineWidth = lw;
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.rotation.y"];
        a.fromValue = @0; a.toValue = @(2 * M_PI); a.duration = dur[i]; a.repeatCount = HUGE_VALF; a.timeOffset = ph[i];
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [r addAnimation:a forKey:@"w12.spin"];
        [w addSublayer:r]; [orb addSublayer:w];
    }
    CABasicAnimation *z = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    z.fromValue = @0; z.toValue = @(2 * M_PI); z.duration = 2.4; z.repeatCount = HUGE_VALF; [orb addAnimation:z forKey:@"w12.spinz"];
    id f = W12FidBlur(blur);
    if (f) orb.filters = @[f];
    else { orb.shadowColor = W12_FIDGREEN.CGColor; orb.shadowRadius = blur; orb.shadowOpacity = 0.9; orb.shadowOffset = CGSizeZero; }
    return orb;
}

static void W12FidSpring(CALayer *l, NSString *kp, double from, double to, double dur, double delay) {
    CASpringAnimation *a = [CASpringAnimation animationWithKeyPath:kp];
    a.mass = 1; a.stiffness = 260; a.damping = 17; a.initialVelocity = 0;
    a.fromValue = @(from); a.toValue = @(to); a.duration = dur; a.beginTime = CACurrentMediaTime() + delay; a.fillMode = kCAFillModeBackwards;
    [l addAnimation:a forKey:[@"w12.sp." stringByAppendingString:kp]];
}
static void W12FidFade(CALayer *l, double from, double to, double dur, double delay) {
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
    a.fromValue = @(from); a.toValue = @(to); a.duration = dur; a.beginTime = CACurrentMediaTime() + delay; a.fillMode = kCAFillModeBackwards;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [l addAnimation:a forKey:[NSString stringWithFormat:@"w12.fade.%p", a]];
    l.opacity = (float)to;
}

static void W12FaceFinish(int token) {
    if (token != gFidToken) return;
    // the real island (and the second bubble) come back exactly where the effect shrank to
    gIsland.pill.layer.mask = nil; gIsland.pill2.layer.mask = nil;
    if (gIsland.pill) gIsland.pill.alpha = 1;
    if (gIsland.pill2 && gIsland.pill2.alpha < 0.01 && gFidP2A > 0.01) gIsland.pill2.alpha = gFidP2A;
    [gFidCard removeFromSuperview]; [gFidCV removeFromSuperview]; [gFidBV removeFromSuperview]; gFidCard = nil; gFidCV = nil; gFidBV = nil; gFidBusy = NO;
}

// Face ID effect, two styles (pref faceStyle): 0 = the island itself stretches into a scan bar (glyph left, tick drawn right),
//                                              1 = the island grows into the big square with blurred tumbling rings, then the tick.
// Both are ONE black shape that morphs (position, size and corner radius share one timing curve, so it never gets distorted),
// the real island steps aside while it runs. The real unlock is released when the tick is complete (gFidUnlockAt).

// Morph the card (frame + corner radius) with one common curve. spring = grow with a soft overshoot, otherwise a plain ease (shrink).
static void W12FidMorph(UIView *card, CGRect to, CGFloat toR, double delay, BOOL spring, double dur) {
    CALayer *l = card.layer; CALayer *pl = l.presentationLayer ?: l;
    CGRect fb = pl.bounds; CGPoint fp = pl.position; CGFloat fr = pl.cornerRadius;
    for (NSString *k in @[@"bounds", @"position", @"cornerRadius"]) [l removeAnimationForKey:[@"w12.m." stringByAppendingString:k]];
    [UIView performWithoutAnimation:^{ card.frame = to; }];
    l.cornerRadius = toR;
    NSArray *keys = @[@"bounds", @"position", @"cornerRadius"];
    NSArray *from = @[[NSValue valueWithCGRect:fb], [NSValue valueWithCGPoint:fp], @(fr)];
    NSArray *tov = @[[NSValue valueWithCGRect:l.bounds], [NSValue valueWithCGPoint:l.position], @(toR)];
    for (int i = 0; i < 3; i++) {
        CABasicAnimation *a;
        if (spring) { CASpringAnimation *sa = [CASpringAnimation animationWithKeyPath:keys[i]]; sa.mass = 1; sa.stiffness = 260; sa.damping = 23; sa.initialVelocity = 0; sa.duration = sa.settlingDuration; a = sa; }
        else { a = [CABasicAnimation animationWithKeyPath:keys[i]]; a.duration = dur; a.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.4 :0 :0.2 :1]; }
        a.fromValue = from[i]; a.toValue = tov[i]; a.fillMode = kCAFillModeBackwards;
        if (delay > 0) a.beginTime = CACurrentMediaTime() + delay;
        [l addAnimation:a forKey:[@"w12.m." stringByAppendingString:keys[i]]];
    }
}

// Thin ring + tick badge (the ringed tick at the right end of the bar): sublayer 0 = ring, 1 = tick.
static CALayer *W12FidBadge(void) {
    CALayer *b = [CALayer layer]; b.bounds = CGRectMake(0, 0, 64, 64);
    CAShapeLayer *r = [CAShapeLayer layer]; r.bounds = b.bounds; r.position = CGPointMake(32, 32); r.fillColor = nil;
    r.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(2, 2, 60, 60)].CGPath; r.strokeColor = W12_FIDGREEN.CGColor; r.lineWidth = 3.6;
    CAShapeLayer *k = [CAShapeLayer layer]; k.bounds = b.bounds; k.position = CGPointMake(32, 32); k.fillColor = nil; k.strokeColor = W12_FIDGREEN.CGColor; k.lineWidth = 3.8; k.lineCap = kCALineCapRound; k.lineJoin = kCALineJoinRound;
    UIBezierPath *cp = [UIBezierPath bezierPath]; [cp moveToPoint:CGPointMake(18.5, 33)]; [cp addLineToPoint:CGPointMake(28, 42.5)]; [cp addLineToPoint:CGPointMake(46, 21.5)]; k.path = cp.CGPath; k.strokeEnd = 0;
    [b addSublayer:r]; [b addSublayer:k];
    return b;
}

static void W12FacePlay(BOOL test) {
    if (!gIsland || !gIsland.win || gIsland.win.hidden || !W12Bool(@"island", NO)) { W12_LOG(@"faceid: skipped (island missing/hidden/off)"); return; }
    if (!test && (!W12Bool(@"faceID", YES) || !W12Bool(@"enabled", YES) || UIAccessibilityIsReduceMotionEnabled())) { W12_LOG(@"faceid: skipped (switch off or reduce motion)"); return; }
    CGSize ss = [UIScreen mainScreen].bounds.size; if (ss.width > ss.height || W12IsLandscape()) { W12_LOG(@"faceid: skipped (landscape)"); return; }
    CFTimeInterval now = CACurrentMediaTime();
    if (gFidBusy && !test) return;
    if (!test && now - gFidLast < 3.0) { W12_LOG(@"faceid: skipped (played %.1fs ago)", now - gFidLast); return; }
    gFidLast = now;
    if (!W12UILocked()) [gIsland syncHost:YES];              // unlocked already: the effect must play in the island window, not in the leaving cover sheet
    if (gFidBusy) { gFidToken++; [gFidCard removeFromSuperview]; [gFidCV removeFromSuperview]; [gFidBV removeFromSuperview]; gFidCard = nil; gFidCV = nil; gFidBV = nil; }
    if (gIsland.expanded) [gIsland collapse];
    int style = (int)W12Double(@"faceStyle", 1, 0, 1);
    double T0 = test ? 0.0 : 0.06;
    double D = T0 + (style == 1 ? 1.4 : 1.2);                 // when the tick is complete = when the real unlock is released
    gFidBusy = YES; int token = ++gFidToken;
    if (!test) { gFidShown = YES; gFidUnlockAt = now + D; }
    UIView *host = gIsland.pill.superview; if (!host) { gFidBusy = NO; return; }
    CGRect pr = gIsland.pill.frame; CGFloat S = 148, R0 = pr.size.height / 2;
    double idleW = W12Double(@"islandW", 126, 70, 220), idleH = W12Double(@"islandH", 37, 20, 60), idleY = W12Double(@"islandY", 11, 0, 40);
    CGFloat cx = round(ss.width / 2);                                       // always the screen centre (the resting spot of the island)
    CGFloat Hb = idleH + 4, Wb = MIN(MAX(idleW * 1.55, 176), 204);          // stays clear of the clock and the battery in the status bar
    CGRect bar = CGRectMake(cx - Wb / 2, idleY - 2, Wb, Hb);
    CGRect big = CGRectMake(cx - S / 2, idleY, S, S);
    W12_LOG(@"faceid: play test=%d style=%d pill=%@ level=%.0f locked=%d", test, style, NSStringFromCGRect(pr), gIsland.win.windowLevel, W12UILocked());

    UIView *card = [[UIView alloc] initWithFrame:pr]; card.backgroundColor = [UIColor blackColor]; card.userInteractionEnabled = NO;
    card.layer.cornerRadius = R0; card.layer.borderWidth = 1; card.layer.borderColor = [W12_FIDGREEN colorWithAlphaComponent:0].CGColor;
    [host addSubview:card]; gFidCard = card;
    // The black card IS the island while the effect runs: the real pill and its activity dot (screen recording, timer ...) step aside.
    if (gIsland.pill2 && gIsland.pill2.alpha > 0.01) gFidP2A = gIsland.pill2.alpha;
    [UIView performWithoutAnimation:^{ gIsland.pill.alpha = 0; gIsland.pill2.alpha = 0; }];
    for (UIView *pv in @[gIsland.pill, gIsland.pill2]) { CALayer *m = [CALayer layer]; m.frame = pv.bounds; pv.layer.mask = m; }   // a transparent mask hides them whatever else happens to their alpha
    UIView *bv = [[UIView alloc] initWithFrame:bar]; bv.userInteractionEnabled = NO; bv.backgroundColor = [UIColor clearColor]; [host addSubview:bv]; gFidBV = bv;
    UIView *cv = [[UIView alloc] initWithFrame:big]; cv.userInteractionEnabled = NO; cv.backgroundColor = [UIColor clearColor]; [host addSubview:cv]; gFidCV = cv;
    CGPoint C = CGPointMake(S / 2, S / 2);

    // padlock opens, then fades
    if (gFidLock && gFidLockShown) {
        gFidLockShown = NO;
        CATransform3D open = CATransform3DConcat(CATransform3DMakeRotation(0.62, 0, 0, 1), CATransform3DMakeTranslation(0, -2.6, 0));
        CABasicAnimation *oa = [CABasicAnimation animationWithKeyPath:@"transform"]; oa.fromValue = [NSValue valueWithCATransform3D:CATransform3DIdentity]; oa.toValue = [NSValue valueWithCATransform3D:open];
        oa.duration = 0.2; oa.fillMode = kCAFillModeForwards; oa.removedOnCompletion = NO; oa.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [gFidShackle addAnimation:oa forKey:@"w12.open"];
        UIView *lk = gFidLock;
        [UIView animateWithDuration:0.16 delay:0.18 options:0 animations:^{ lk.alpha = 0; } completion:^(BOOL f) { [gFidShackle removeAnimationForKey:@"w12.open"]; }];
    }

    // the green outline fades in with the morph
    CABasicAnimation *bd = [CABasicAnimation animationWithKeyPath:@"borderColor"]; bd.fromValue = (id)[W12_FIDGREEN colorWithAlphaComponent:0].CGColor; bd.toValue = (id)[W12_FIDGREEN colorWithAlphaComponent:0.30].CGColor; bd.duration = 0.4; bd.beginTime = CACurrentMediaTime() + T0; bd.fillMode = kCAFillModeBackwards;
    card.layer.borderColor = [W12_FIDGREEN colorWithAlphaComponent:0.30].CGColor; [card.layer addAnimation:bd forKey:@"w12.bd"];

    CAShapeLayer *ring = nil, *chk = nil; CALayer *gl = nil, *bg = nil;
    if (style == 0) {
        // ---- scan bar: the island stretches, glyph (left) sharpens, then the ringed tick (right) appears and its tick is drawn
        W12FidMorph(card, bar, Hb / 2, T0, YES, 0);
        CGFloat gs = 0.36, bs = 0.30;
        CALayer *gcont = [CALayer layer]; gcont.bounds = CGRectMake(0, 0, 60, 60); gcont.position = CGPointMake(25, Hb / 2); gcont.transform = CATransform3DMakeScale(gs, gs, 1);
        CAShapeLayer *g = W12FidGlyph(); g.position = CGPointMake(30, 30); g.opacity = 0; [gcont addSublayer:g]; [bv.layer addSublayer:gcont]; gl = g;
        CALayer *bcont = [CALayer layer]; bcont.bounds = CGRectMake(0, 0, 64, 64); bcont.position = CGPointMake(Wb - 25, Hb / 2); bcont.transform = CATransform3DMakeScale(bs, bs, 1);
        CALayer *b = W12FidBadge(); b.position = CGPointMake(32, 32); b.opacity = 0; [bcont addSublayer:b]; [bv.layer addSublayer:bcont]; bg = b;
        id f1 = W12FidBlur(11), f2 = W12FidBlur(11); if (f1) gl.filters = @[f1]; if (f2) bg.filters = @[f2];
        W12FidFade(gl, 0, 1, 0.26, T0 + 0.1); W12FidBlurTo(gl, 11, 0, 0.34, T0 + 0.1); W12FidSpring(gl, @"transform.scale", 0.82, 1, 0.5, T0 + 0.1);
        W12FidFade(bg, 0, 1, 0.26, T0 + 0.42); W12FidBlurTo(bg, 11, 0, 0.34, T0 + 0.42); W12FidSpring(bg, @"transform.scale", 0.82, 1, 0.5, T0 + 0.42);
        CAShapeLayer *tk = (CAShapeLayer *)bg.sublayers[1];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((T0 + 0.6) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (token != gFidToken) return;
            CABasicAnimation *sa = [CABasicAnimation animationWithKeyPath:@"strokeEnd"]; sa.fromValue = @0.001; sa.toValue = @1; sa.duration = 0.34;
            sa.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.3 :0.7 :0.3 :1]; tk.strokeEnd = 1; [tk addAnimation:sa forKey:@"w12.chk"];
            UINotificationFeedbackGenerator *nf = [UINotificationFeedbackGenerator new]; [nf notificationOccurred:UINotificationFeedbackTypeSuccess];
        });
    } else {
        // ---- square: the island grows into the big square; blurred tumbling rings -> one circle -> tick drawn from a dot
        W12FidMorph(card, big, 46, T0, YES, 0);
        double T1 = T0 + 0.18;
        CALayer *halo = W12FidOrb(6.5, 0.55, 14), *core = W12FidOrb(3.4, 1.0, 10);
        halo.position = C; core.position = C; halo.opacity = 0; core.opacity = 0; [cv.layer addSublayer:halo]; [cv.layer addSublayer:core];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(T1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (token != gFidToken) return;
            W12FidFade(halo, 0, 1, 0.22, 0); W12FidFade(core, 0, 1, 0.22, 0);
            W12FidSpring(halo, @"transform.scale", 0.55, 1, 0.55, 0); W12FidSpring(core, @"transform.scale", 0.55, 1, 0.55, 0);
            W12FidBlurTo(core, 10, 1.3, 0.5, 0); W12FidBlurTo(halo, 14, 8, 0.5, 0);
        });
        ring = [CAShapeLayer layer]; ring.bounds = CGRectMake(0, 0, 64, 64); ring.position = C; ring.fillColor = nil; ring.opacity = 0;
        ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(1.7, 1.7, 60.6, 60.6)].CGPath; ring.strokeColor = W12_FIDGREEN.CGColor; ring.lineWidth = 3.4; ring.lineCap = kCALineCapRound;
        [cv.layer addSublayer:ring];
        chk = [CAShapeLayer layer]; chk.bounds = CGRectMake(0, 0, 64, 64); chk.position = C; chk.fillColor = nil; chk.strokeEnd = 0; chk.strokeColor = W12_FIDGREEN.CGColor; chk.lineWidth = 3.6; chk.lineCap = kCALineCapRound; chk.lineJoin = kCALineJoinRound;
        { UIBezierPath *cp = [UIBezierPath bezierPath]; [cp moveToPoint:CGPointMake(19, 33.5)]; [cp addLineToPoint:CGPointMake(28.5, 43)]; [cp addLineToPoint:CGPointMake(46, 22.5)]; chk.path = cp.CGPath; }
        [cv.layer addSublayer:chk];
        CAShapeLayer *ringL = ring, *chkL = chk;
        double T2 = T1 + 0.54, T3 = T2 + 0.18;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(T2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (token != gFidToken) return;
            W12FidFade(halo, 1, 0, 0.22, 0); W12FidFade(core, 1, 0, 0.22, 0);
            id rb = W12FidBlur(5); if (rb) ringL.filters = @[rb];
            id cb = W12FidBlur(0); if (cb) chkL.filters = @[cb];
            W12FidFade(ringL, 0, 1, 0.16, 0); W12FidSpring(ringL, @"transform.scale", 0.9, 1, 0.5, 0); W12FidBlurTo(ringL, 5, 0, 0.3, 0);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(T3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (token != gFidToken) return;
            CABasicAnimation *sa = [CABasicAnimation animationWithKeyPath:@"strokeEnd"]; sa.fromValue = @0.001; sa.toValue = @1; sa.duration = 0.42;
            sa.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.3 :0.7 :0.3 :1]; chkL.strokeEnd = 1; [chkL addAnimation:sa forKey:@"w12.chk"];
            UINotificationFeedbackGenerator *nf = [UINotificationFeedbackGenerator new]; [nf notificationOccurred:UINotificationFeedbackTypeSuccess];
        });
    }

    // ---- the tick is complete: content blurs out, the same black shape eases back into the island (no overshoot -> no distortion)
    CAShapeLayer *ringS = ring, *chkS = chk; CALayer *glS = gl, *bgS = bg;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((D + 0.04) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token != gFidToken) return;
        for (CALayer *l in @[ringS ?: (id)[NSNull null], chkS ?: (id)[NSNull null], glS ?: (id)[NSNull null], bgS ?: (id)[NSNull null]]) {
            if (![l isKindOfClass:[CALayer class]]) continue;
            W12FidBlurTo(l, 0, 9, 0.26, 0); W12FidFade(l, 1, 0, 0.26, 0);
        }
        CGRect back = gIsland.pill.frame;
        W12FidMorph(card, back, back.size.height / 2, 0, NO, 0.42);
        card.layer.borderColor = [W12_FIDGREEN colorWithAlphaComponent:0].CGColor;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.46 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ W12FaceFinish(token); });
    });
}

// Has the passcode / finger been accepted already? (MobileKeyBag: 0 = device unlocked). Only then is an unlock request a real unlock;
// before that, Home / swipe-up only brings up the passcode pad and must not trigger (or delay) anything.
static BOOL W12DeviceAuthed(void) {
    static int (*fn)(void *); static BOOL done; static int lastSt = -99;
    if (!done) { done = YES; fn = (int (*)(void *))dlsym(RTLD_DEFAULT, "MKBGetDeviceLockState"); W12_LOG(@"faceid: MKBGetDeviceLockState %s", fn ? "found" : "MISSING"); }
    if (!fn) return NO;
    int st = fn(NULL);
    if (st != lastSt) { lastSt = st; W12_LOG(@"faceid: device lock state -> %d", st); }
    return st == 0;
}

// How long the real unlock has to wait so the animation can show its tick first (0 = unlock right now).
static double W12FaceUnlockWait(void) {
    if (!gFidBusy && !W12DeviceAuthed()) return 0;           // still waiting for the passcode: nothing to celebrate yet
    if (!W12Bool(@"faceDelay", YES)) { W12FacePlay(NO); return 0; }
    CFTimeInterval now = CACurrentMediaTime();
    if (gFidBusy) return MAX(0, gFidUnlockAt - now);
    if (gFidShown && now - gFidLast < 30) return 0;          // already played for this unlock
    W12FacePlay(NO);
    return gFidBusy ? MAX(0, gFidUnlockAt - now) : 0;
}

// Padlock in the island while the Lock Screen is up and the island is idle (called from the island's 0.25 s tick).
static void W12FaceTick(void) {
    if (!gIsland) return;
    BOOL lkd = W12UILocked(), land = W12IsLandscape();
    BOOL raw = gIsland.win && !gIsland.win.hidden && W12Bool(@"island", NO) && W12Bool(@"faceLock", YES) && !gFidBusy && !gIsland.expanded
        && gIsland.shownKind == 0 && gIsland.shownKind2 == 0 && lkd && !land;
    // debounce: the padlock shows only after the conditions held for 0.4 s and goes only after they were gone for 0.7 s (no blinking)
    static CFTimeInterval onAt = 0, offAt = 0; static int lastRaw = -1;
    CFTimeInterval tnow = CACurrentMediaTime();
    if (raw) { if (!onAt) onAt = tnow; offAt = 0; } else { if (!offAt) offAt = tnow; onAt = 0; }
    if (raw != lastRaw) { lastRaw = raw; W12_LOG(@"island: padlock cond %d (locked=%d kind=%d/%d expanded=%d busy=%d landscape=%d)", raw, lkd, gIsland.shownKind, gIsland.shownKind2, gIsland.expanded, gFidBusy, land); }
    BOOL want = gFidLockShown ? !(offAt && tnow - offAt > 0.7) : (onAt && tnow - onAt > 0.4);
    if (gFidBusy) want = NO;
    UIView *host = gIsland.pill.superview; if (!host) return;
    if (!gFidLock) {
        UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 16, 20)]; v.userInteractionEnabled = NO; v.alpha = 0;
        CAShapeLayer *body = [CAShapeLayer layer]; body.fillColor = [UIColor colorWithWhite:0.93 alpha:1].CGColor;
        body.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1.5, 8.6, 13, 10.4) cornerRadius:2.6].CGPath; [v.layer addSublayer:body];
        CAShapeLayer *sh = [CAShapeLayer layer]; sh.frame = v.bounds; sh.fillColor = nil; sh.strokeColor = [UIColor colorWithWhite:0.93 alpha:1].CGColor; sh.lineWidth = 1.9; sh.lineCap = kCALineCapRound;
        UIBezierPath *sp = [UIBezierPath bezierPath]; [sp moveToPoint:CGPointMake(4, 9)]; [sp addLineToPoint:CGPointMake(4, 6.4)]; [sp addArcWithCenter:CGPointMake(8, 6.4) radius:4 startAngle:M_PI endAngle:2 * M_PI clockwise:YES]; [sp addLineToPoint:CGPointMake(12, 9)];
        sh.path = sp.CGPath; sh.anchorPoint = CGPointMake(12.0 / 16, 9.0 / 20); sh.position = CGPointMake(12, 9);
        [v.layer addSublayer:sh]; gFidShackle = sh; gFidLock = v;
    }
    if (gFidLock.superview != host) [host addSubview:gFidLock];
    else if (gFidCard.superview == host) [host insertSubview:gFidLock belowSubview:gFidCard];
    CGRect pr = gIsland.pill.frame;
    CGPoint lc = CGPointMake(round(pr.origin.x + 14 + 8), round(CGRectGetMidY(pr)));          // leading icon, like the other island activities
    if (!CGPointEqualToPoint(gFidLock.center, lc)) gFidLock.center = lc;
    if (!gFidBusy && host.subviews.lastObject != gFidLock) [host bringSubviewToFront:gFidLock];
    if (want != gFidLockShown) {
        gFidLockShown = want;
        W12_LOG(@"island: padlock %d (island level %.0f hidden=%d)", want, gIsland.win.windowLevel, gIsland.win.hidden);
        if (want) [gFidShackle removeAllAnimations];
        [UIView animateWithDuration:0.22 animations:^{ gFidLock.alpha = want ? 1 : 0; }];
    }
}

static BOOL W12IslandFlyInfoLocal(NSString *bid, CGRect *out) {
    if (!gIsland || !bid.length) return NO;
    if (!W12Bool(@"island", NO) || !W12Bool(@"islandLive", YES) || !W12Bool(@"islandFly", YES)) return NO;
    BOOL has = NO; for (NSDictionary *d in gIsland.acts) if ([d[@"bid"] isEqualToString:bid]) { has = YES; break; }
    if (!has) return NO;
    CGSize ss = [UIScreen mainScreen].bounds.size;
    if (ss.width > ss.height) return NO;
    *out = gIsland.shownKind ? [gIsland targetRect] : [gIsland baseRect];       // plain black island (inside the app): the card lands in that pill, then it opens
    gIsland.expandAfter = CACurrentMediaTime() + 0.46 / W12Double(@"speed", 1.0, 0.6, 1.6) * 0.84;      // the island opens up when the card has landed
    return YES;
}
static void W12IslandArriveLocal(void) { [gIsland tickActivity]; [gIsland bump]; }
#ifdef W12_M_DYNA
__attribute__((visibility("default"))) BOOL W12XIslandFlyInfo(NSString *bid, CGRect *out) { return W12IslandFlyInfoLocal(bid, out); }
__attribute__((visibility("default"))) void W12XIslandArrive(void) { W12IslandArriveLocal(); }
__attribute__((visibility("default"))) double W12XFidWait(void) { return gFidBusy ? MAX(0, gFidUnlockAt - CACurrentMediaTime()) : 0; }
static BOOL W12IslandFlyInfo(NSString *bid, CGRect *out) { return W12IslandFlyInfoLocal(bid, out); }
static void W12IslandArrive(void) { W12IslandArriveLocal(); }
#else
static BOOL W12IslandFlyInfo(NSString *bid, CGRect *out) {     // dynaFake (if installed) owns the island: ask it
    static BOOL (*f)(NSString *, CGRect *); static dispatch_once_t o;
    dispatch_once(&o, ^{ f = (BOOL (*)(NSString *, CGRect *))dlsym(RTLD_DEFAULT, "W12XIslandFlyInfo"); });
    return f ? f(bid, out) : NO;
}
static void W12IslandArrive(void) {
    static void (*f)(void); static dispatch_once_t o;
    dispatch_once(&o, ^{ f = (void (*)(void))dlsym(RTLD_DEFAULT, "W12XIslandArrive"); });
    if (f) f();
}
#endif

static void (*o_hudHidden)(id, SEL, BOOL);
static void n_hudHidden(id self, SEL _cmd, BOOL h) {
    if (!h && gHudHide && gIsland && gIsland.win && !gIsland.win.hidden && W12Bool(@"island", NO) && W12Bool(@"islandVol", YES)) h = YES;     // volume / ringer HUD: the island shows it instead
    o_hudHidden(self, _cmd, h);
}

#include "Home26.inc"

// MARK: - Hooking (plain ObjC runtime, no Substrate dependency)

static BOOL W12ArgIs(Method m, unsigned idx, char t) {
    char *a = method_copyArgumentType(m, idx);
    BOOL ok = a && a[0] == t;
    free(a);
    return ok;
}

static void (*o_setPresented)(id, SEL, BOOL, BOOL, id);
static void n_setPresented(id self, SEL _cmd, BOOL presented, BOOL animated, id completion) {
#ifdef W12_M_DYNA
    if (!presented && animated && !gFidReleasing && W12UILocked()) {        // Face ID effect: hold the dismissal until the tick has been shown
        double w = gFidPending ? MAX(0, gFidUnlockAt - CACurrentMediaTime()) : W12FaceUnlockWait();
        if (w > 0.02) {
            id c = completion ? [completion copy] : nil;
            W12_LOG(@"faceid: cover sheet dismissal held %.2fs", w);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(w * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                BOOL r = gFidReleasing; gFidReleasing = YES; n_setPresented(self, _cmd, presented, animated, c); gFidReleasing = r; });
            return;
        }
    }
#endif
#ifdef W12_M_WAVE
    if (!presented && animated) { W12CoverCorners(); W12Run(W12SourceUnlock); }
#endif
    o_setPresented(self, _cmd, presented, animated, completion);
}

static void (*o_unlockUI)(id, SEL, int, id);
static void n_unlockUI(id self, SEL _cmd, int source, id options) {
#ifdef W12_M_DYNA
    W12_LOG(@"faceid: unlockUI source=%d releasing=%d pending=%d locked=%d", source, gFidReleasing, gFidPending, W12UILocked());
    if (!gFidReleasing) {
        if (gFidPending) return;                                     // an unlock is already waiting for the Face ID effect
        double w = W12UILocked() ? W12FaceUnlockWait() : 0;
        if (w > 0.02) {
            gFidPending = YES; id opt = options;
            W12_LOG(@"faceid: unlock held %.2fs", w);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(w * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                gFidPending = NO; gFidReleasing = YES; n_unlockUI(self, _cmd, source, opt); gFidReleasing = NO; });
            return;
        }
    }
#endif
#ifdef W12_M_WAVE
    CFTimeInterval t = CACurrentMediaTime();
    static CFTimeInterval lastCorner = 0;
    if (t - lastCorner > 1.0) { lastCorner = t; W12CoverCorners(); }
    W12Run(W12SourceUnlock);
#endif
    o_unlockUI(self, _cmd, source, options);
}

static void (*o_restore1)(id, SEL, BOOL);
static void n_restore1(id self, SEL _cmd, BOOL animated) {
    W12_LOG(@"hook restore1 animated=%d", animated);
    
#ifdef W12_M_MORPH
    W12AppClose();
#endif
#ifdef W12_M_WAVE
    if (animated) W12Run(W12SourceHome);
#endif

    o_restore1(self, _cmd, animated);
}
static void (*o_restore2)(id, SEL, BOOL, id);
static void n_restore2(id self, SEL _cmd, BOOL animated, id completion) {
    W12_LOG(@"hook restore2 animated=%d", animated);
    
#ifdef W12_M_MORPH
    W12AppClose();
#endif
#ifdef W12_M_WAVE
    if (animated) W12Run(W12SourceHome);
#endif

    o_restore2(self, _cmd, animated, completion);
}

static BOOL (*o_flyIn)(id, SEL);
static BOOL n_flyIn(id self, SEL _cmd) { return W12Bool(@"enabled", YES) ? NO : o_flyIn(self, _cmd); }

static BOOL W12Hook(NSString *cls, SEL sel, IMP imp, void *orig, unsigned nargs, const char *types) {
    Class c = NSClassFromString(cls);
    Method m = c ? class_getInstanceMethod(c, sel) : NULL;
    if (!m || method_getNumberOfArguments(m) != nargs) { W12_LOG(@"skip %@ %@", cls, NSStringFromSelector(sel)); return NO; }
    for (unsigned i = 0; types && types[i]; i++) if (types[i] != '*' && !W12ArgIs(m, 2 + i, types[i])) { W12_LOG(@"sig mismatch %@ %@", cls, NSStringFromSelector(sel)); return NO; }
    *(IMP *)orig = method_getImplementation(m);
    class_replaceMethod(c, sel, imp, method_getTypeEncoding(m));
    W12_LOG(@"hooked %@ %@", cls, NSStringFromSelector(sel));
    return YES;
}


// Hook for methods whose arguments are all pointer/integer sized (<= 6 of them).
typedef uintptr_t (*W12GenFn)(id, SEL, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t);
static BOOL W12HookGeneric(NSString *cls, SEL sel, void (^pre)(id self, uintptr_t a0)) {
    Class c = NSClassFromString(cls);
    Method m = c ? class_getInstanceMethod(c, sel) : NULL;
    if (!m) { W12_LOG(@"skip %@ %@", cls, NSStringFromSelector(sel)); return NO; }
    unsigned n = method_getNumberOfArguments(m);
    if (n > 8) return NO;
    for (unsigned i = 2; i < n; i++) {
        char *t = method_copyArgumentType(m, i); char ch = t ? t[0] : 0; free(t);
        if (ch == 'f' || ch == 'd' || ch == 'D' || ch == '{' || ch == '(') return NO;
    }
    char *rt = method_copyReturnType(m); char rc = rt ? rt[0] : 0; free(rt);
    if (!strchr("vB@qQiIcClLsS#:", rc)) return NO;
    IMP orig = method_getImplementation(m);
    SEL s = sel;
    IMP imp = imp_implementationWithBlock(^uintptr_t(id self, uintptr_t a, uintptr_t b, uintptr_t c2, uintptr_t d, uintptr_t e, uintptr_t f) {
        pre(self, a);
        return ((W12GenFn)orig)(self, s, a, b, c2, d, e, f);
    });
    class_replaceMethod(c, sel, imp, method_getTypeEncoding(m));
    W12_LOG(@"hooked %@ %@", cls, NSStringFromSelector(sel));
    return YES;
}


// MARK: - iPhone 14 Pro style status bar: clock in the left "ear", icons grouped on the right, gap for the island

static void W12CollectItems(UIView *v, int depth, NSMutableArray *out) {
    if (!v || depth > 10) return;
    for (UIView *s in v.subviews) {
        NSString *cn = NSStringFromClass([s class]);
        if ([cn hasPrefix:@"UIStatusBar"] && [cn hasSuffix:@"ItemView"]) { [out addObject:s]; continue; }
        W12CollectItems(s, depth + 1, out);
    }
}

// Move a view horizontally so its centre sits at x (given in window coordinates).
static void W12SetCenterWinX(UIView *v, CGFloat x) {
    UIView *sv = v.superview; if (!sv) return;
    CGPoint p = [sv convertPoint:CGPointMake(x, 0) fromView:nil];
    v.center = CGPointMake(p.x, v.center.y);
}

static void W12LayoutGroup(NSArray<UIView *> *items) {
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    double islandW   = W12Double(@"islandW", 126, 70, 220);
    double timeScale = W12Double(@"sbTimeScale", 1.15, 0.8, 1.6);
    double timeDX    = W12Double(@"sbTimeX", 0, -40, 40);
    double rightDX   = W12Double(@"sbRightX", 0, -40, 40);
    BOOL hideCarrier = W12Bool(@"sbHideCarrier", YES), hidePct = W12Bool(@"sbHidePercent", YES);

    UIView *timeV = nil, *batt = nil, *pct = nil;
    NSMutableArray<UIView *> *right = [NSMutableArray array];
    for (UIView *v in items) {
        NSString *cn = NSStringFromClass([v class]);
        if ([cn containsString:@"TimeItemView"]) timeV = v;
        else if ([cn containsString:@"BatteryPercent"]) { pct = v; v.hidden = hidePct; }
        else if ([cn containsString:@"BatteryItemView"]) batt = v;
        else if ([cn containsString:@"ServiceItemView"]) v.hidden = hideCarrier;
        else if (v.bounds.size.width > 0 && !v.hidden) [right addObject:v];
    }
    [right sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat xa = [a convertPoint:CGPointZero toView:nil].x, xb = [b convertPoint:CGPointZero toView:nil].x;
        return xa < xb ? NSOrderedAscending : NSOrderedDescending;
    }];
    if (timeV && timeV.bounds.size.width > 0) {
        W12SetCenterWinX(timeV, (sw - islandW) / 4.0 + timeDX);
        timeV.layer.transform = CATransform3DMakeScale(timeScale, timeScale, 1);
    }
    NSMutableArray *ordered = [NSMutableArray arrayWithArray:right];
    if (pct && !hidePct) [ordered addObject:pct];
    if (batt) [ordered addObject:batt];
    CGFloat x = sw - 14 + rightDX;
    for (UIView *v in [ordered reverseObjectEnumerator]) {
        if (v.hidden || v.bounds.size.width <= 0) continue;
        CGFloat w = v.bounds.size.width;
        W12SetCenterWinX(v, x - w / 2.0);
        x -= w + 4;
    }
}

static BOOL gSBDumped = NO;
static void W12AdjustStatusBar(UIView *root) {
    if (![root isKindOfClass:[UIView class]] || YES /* iPhone 14 status bar removed */ || W12SelfExcluded()) return;
    if ([UIScreen mainScreen].bounds.size.width > [UIScreen mainScreen].bounds.size.height) return;
    NSMutableArray *items = [NSMutableArray array];
    W12CollectItems(root, 0, items);
    if (!items.count) return;
    // group items by their container, so each status bar is laid out on its own
    NSMutableArray *parents = [NSMutableArray array];
    NSMutableArray *groups = [NSMutableArray array];
    for (UIView *v in items) {
        NSUInteger i = [parents indexOfObjectIdenticalTo:v.superview];
        if (i == NSNotFound) { [parents addObject:v.superview]; [groups addObject:[NSMutableArray arrayWithObject:v]]; }
        else [groups[i] addObject:v];
    }
    for (NSArray *g in groups) W12LayoutGroup(g);
    if (!gSBDumped) {
        gSBDumped = YES;
        NSMutableString *names = [NSMutableString string];
        for (UIView *v in items) [names appendFormat:@"%@ ", NSStringFromClass([v class])];
        W12_LOG(@"statusbar: %lu items in %lu groups: %@", (unsigned long)items.count, (unsigned long)groups.count, names);
    }
}

static void W12StatusBarTick(void) {
    if (YES /* removed */) return;
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;
    static BOOL diag = NO;
    BOOL found = NO;
    for (UIWindow *w in app.windows) {
        NSMutableArray *probe = [NSMutableArray array];
        W12CollectItems(w, 0, probe);
        if (probe.count) { found = YES; W12AdjustStatusBar(w); }
    }
    id sbw = W12Call(app, NSSelectorFromString(@"statusBarWindow"));
    if ([sbw isKindOfClass:[UIView class]]) { NSMutableArray *probe = [NSMutableArray array]; W12CollectItems(sbw, 0, probe); if (probe.count) { found = YES; W12AdjustStatusBar(sbw); } }
    if (!found && !diag) {
        diag = YES;
        W12_LOG(@"statusbar: no item views found. windows:");
        for (UIWindow *w in app.windows) W12_LOG(@"  window %@ hidden=%d", NSStringFromClass([w class]), w.hidden);
        if (sbw) { W12_LOG(@"  statusBarWindow %@", NSStringFromClass([sbw class])); W12Dump(sbw, 1, 6); }
        W12DumpAllWindows("statusbar");
    }
}

static void (*o_sbLayout)(id, SEL);
static void n_sbLayout(id self, SEL _cmd) {
    o_sbLayout(self, _cmd);
    W12AdjustStatusBar(self);
}


// MARK: - Control Center: thin glass rim around every module (iOS 26 look)

static void (*o_mtLayout)(id, SEL);
static void W12CCRound(UIView *c);
static void W12CCPrefs(void);
static const void *kCCIn = &kCCIn;
static BOOL W12InControlCenterRaw(UIView *v) {
    int d = 0;
    for (UIView *p = v; p && d < 10; p = p.superview, d++) {
        const char *cn = object_getClassName(p);                 // C string: no allocation (this runs for every layout pass of every material view)
        if (!strncmp(cn, "CCUI", 4) || strstr(cn, "ControlCenter")) return YES;
    }
    return NO;
}
static void W12CCForget(UIView *v) { objc_setAssociatedObject(v, kCCIn, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
static BOOL W12InControlCenter(UIView *v) {
    NSNumber *c = objc_getAssociatedObject(v, kCCIn);
    if (c) return c.boolValue;
    if (!v.window) return W12InControlCenterRaw(v);              // not attached yet: do not cache
    BOOL r = W12InControlCenterRaw(v);
    objc_setAssociatedObject(v, kCCIn, @(r), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return r;
}
// Numeric signatures (no string formatting) to detect "nothing changed since the last time".
typedef struct { float w, h, a; int flags; } W12CCSig;
static BOOL W12CCSigSame(id o, const void *key, W12CCSig s) {
    NSData *d = objc_getAssociatedObject(o, key);
    return d.length == sizeof(s) && memcmp(d.bytes, &s, sizeof(s)) == 0;
}
static void W12CCSigSet(id o, const void *key, W12CCSig s) { objc_setAssociatedObject(o, key, [NSData dataWithBytes:&s length:sizeof(s)], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
// Corner radius of the visible shape: the material view itself is often not what is clipped, so look at the views around it
// and fall back to the shape language of Control Center (circles, capsules, rounded squares).
// One radius rule for both the module's own clipping (W12CCRound) and the rim drawn on it: they used to disagree for the 2x2
// modules (Connectivity, Music), so the rim did not follow the corners.
static CGFloat W12CCRoundRadius(CGFloat m) { return m < 105 ? m / 2 : MIN(m / 2, MAX(30.0, m * 0.28)); }
static BOOL gCCRoundOn;
static CGFloat W12ShapeRadius(UIView *v) {
    CGSize s = v.bounds.size; CGFloat m = MIN(s.width, s.height), r = 0;
    if (gCCRoundOn && m >= 30 && m < 190 && MAX(s.width, s.height) <= 360) return W12CCRoundRadius(m);
    int d = 0;
    for (UIView *p = v; p && d < 5; p = p.superview, d++) {
        CGSize ps = p.bounds.size;
        if (fabs(ps.width - s.width) > 14 || fabs(ps.height - s.height) > 14) break;
        r = MAX(r, p.layer.cornerRadius);
        for (NSString *sn in @[@"continuousCornerRadius", @"cornerRadius", @"_continuousCornerRadius"]) {   // CCUI containers keep the stock radius in a property
            SEL sel = NSSelectorFromString(sn);
            if (![p isKindOfClass:[UIView class]] || ![p respondsToSelector:sel]) continue;
            Method mm = class_getInstanceMethod([p class], sel); char *rt = mm ? method_copyReturnType(mm) : NULL;
            BOOL isF = rt && (rt[0] == 'd' || rt[0] == 'f'); BOOL isD = rt && rt[0] == 'd'; if (rt) free(rt);
            if (isF) { CGFloat v = isD ? ((double (*)(id, SEL))objc_msgSend)(p, sel) : ((float (*)(id, SEL))objc_msgSend)(p, sel); if (v > 1 && v < 80) r = MAX(r, v); }
        }
        if ([p.layer.mask isKindOfClass:[CAShapeLayer class]]) {
            CGPathRef path = ((CAShapeLayer *)p.layer.mask).path;
            if (path) { CGRect pb = CGPathGetBoundingBox(path); if (fabs(pb.size.width - pb.size.height) < 2 && fabs(pb.size.width - s.width) < 3) r = MAX(r, m / 2); }
        }
    }
    CGFloat ratio = MAX(s.width, s.height) / MAX(1, m);
    if (ratio > 1.45 && m < 105) return m / 2;      // small sliders, wide buttons: capsule
    if (m >= 105 && MAX(s.width, s.height) >= 150 && (ratio > 1.45 || m >= 150)) return (r > 1 && r <= 40) ? r : 30.0;   // expanded panels (brightness, volume, calculator...): rounded rectangle, never a capsule
    if (r < 1) r = (m < 105) ? m / 2 : (m < 190 ? m * 0.23 : 27.0);   // small square: round button; module: ~0.23; expanded panel: close to the stock iOS 12 radius
    if (m < 105 && ratio <= 1.45) return m / 2;      // every small round-ish control is a circle (the pressed highlight view reports a smaller squircle radius)
    return MIN(r, m / 2);
}

// Preferences are read at most once per second here: these hooks run for every layout pass while Control Center is dragged.
static CGFloat W12IslandBorderW(void);
static BOOL gCCOn = YES; static CGFloat gCCAlpha = 0.55; static CFTimeInterval gCCPrefT = -10;
static void W12CCPrefs(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gCCPrefT < 1.0) return;
    gCCPrefT = now;
    gCCOn = W12Bool(@"enabled", YES) && W12Bool(@"ccGlass", YES);
    gCCAlpha = (CGFloat)W12Double(@"ccAlpha", 0.55, 0.2, 1.0);
    gCCRoundOn = W12Bool(@"enabled", YES) && W12Bool(@"ccRound", YES);
}
static const void *kCCSig = &kCCSig, *kCCWant = &kCCWant, *kCCRoundSig = &kCCRoundSig;

static void W12ApplyCCRim(UIView *self) {
    static NSString *kName = @"w12.ccrim";
    W12CCPrefs();
    CGRect b = self.bounds;
    // cheap exit: same size and same prefs as the last time => nothing to do (layout passes repeat constantly during the drag)
    W12CCSig sig = { (float)b.size.width, (float)b.size.height, (float)gCCAlpha, (gCCOn ? 1 : 0) | (self.window ? 2 : 0) };
    if (W12CCSigSame(self, kCCSig, sig)) {
        NSNumber *w = objc_getAssociatedObject(self, kCCWant);       // the system resets layer opacities now and then: keep re-applying (cheap)
        if (w) { CGFloat wv = w.doubleValue; for (CALayer *l in self.layer.sublayers) if (![l.name isEqualToString:kName] && l.opacity != wv) l.opacity = wv; }
        return;
    }
    CALayer *rim = nil;
    for (CALayer *l in self.layer.sublayers) if ([l.name isEqualToString:kName]) { rim = l; break; }
    BOOL on = gCCOn && b.size.width > 30 && b.size.height > 30 && b.size.width <= 340 && b.size.height <= 470 && self.window && W12InControlCenter(self);   // full-screen backings never get a rim
    // transparent dark background: fade the material's own layers (not the rim) in every Control Center module
    CGFloat want = on ? gCCAlpha : 1.0;
    objc_setAssociatedObject(self, kCCWant, @(want), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (CALayer *l in self.layer.sublayers) if (l != rim && l.opacity != want) l.opacity = want;
    if (!on) { if (rim) rim.hidden = YES; W12CCSigSet(self, kCCSig, sig); return; }
    {   // a material of the same size inside another material (expanded panels): outline only the outer one
        int d = 0; Class mc = NSClassFromString(@"MTMaterialView");
        for (UIView *p = self.superview; p && d < 4; p = p.superview, d++)
            if ([p isKindOfClass:mc] && fabs(p.bounds.size.width - b.size.width) < 12 && fabs(p.bounds.size.height - b.size.height) < 12) { if (rim) rim.hidden = YES; W12CCSigSet(self, kCCSig, sig); return; }
    }
    {   // pressing a control adds a second background view of the same size: only one rim per spot
        for (UIView *sib in self.superview.subviews) {
            if (sib == self || sib.hidden) continue;
            CGRect sb = sib.frame, mb = self.frame;
            if (fabs(sb.origin.x - mb.origin.x) > 3 || fabs(sb.origin.y - mb.origin.y) > 3 || fabs(sb.size.width - mb.size.width) > 3 || fabs(sb.size.height - mb.size.height) > 3) continue;
            for (CALayer *l in sib.layer.sublayers) if ([l.name isEqualToString:kName] && !l.hidden) { if (rim) rim.hidden = YES; W12CCSigSet(self, kCCSig, sig); return; }
        }
    }
    CGFloat r = W12ShapeRadius(self);
    if (!rim) { rim = W12RimLayer(kName); [self.layer addSublayer:rim]; }
    rim.hidden = NO;
    if (self.layer.sublayers.lastObject != rim) [self.layer addSublayer:rim];   // stay on top
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    W12RimSet(rim, b, r, NO);
    [CATransaction commit];
    W12CCSigSet(self, kCCSig, sig);
}

static void n_mtLayout(UIView *self, SEL _cmd) {
    o_mtLayout(self, _cmd);
    if (!W12InControlCenter(self)) { if (self.window) W12ApplyCCRim(self); return; }   // every other material view of SpringBoard: leave as fast as possible
    if (gCCRoundOn) { static Class cc; if (!cc) cc = NSClassFromString(@"CCUIContentModuleContainerView"); for (UIView *p = self.superview; p; p = p.superview) if (cc && [p isKindOfClass:cc]) { W12CCRound(p); break; } }
    W12ApplyCCRim(self);
}
static void (*o_mtWin)(id, SEL);
static void n_mtWin(UIView *self, SEL _cmd) {
    o_mtWin(self, _cmd);
    W12CCForget(self);
    if (!self.window) return;
    W12ApplyCCRim(self);                                   // first appearance: no layout pass may follow until the user touches the module
    __weak UIView *w = self;
    dispatch_async(dispatch_get_main_queue(), ^{ UIView *s = w; if (s.window) W12ApplyCCRim(s); });   // superviews are fully attached by then
}


// Passcode keypad: the same glass rim around every round key.
static void W12GlassRimOn(UIView *v) {
    static NSString *kName = @"w12.ccrim";
    W12CCPrefs();
    CGRect b = v.bounds;
    W12CCSig sig = { (float)b.size.width, (float)b.size.height, 0, (gCCOn ? 1 : 0) | (v.window ? 2 : 0) | 4 };
    if (W12CCSigSame(v, kCCSig, sig)) return;
    CALayer *rim = nil;
    for (CALayer *l in v.layer.sublayers) if ([l.name isEqualToString:kName]) { rim = l; break; }
    if (!gCCOn || b.size.width < 30 || b.size.width > 130 || fabs(b.size.width - b.size.height) > 6 || !v.window) { if (rim) rim.hidden = YES; W12CCSigSet(v, kCCSig, sig); return; }
    if (!rim) { rim = W12RimLayer(kName); [v.layer addSublayer:rim]; }
    rim.hidden = NO;
    if (v.layer.sublayers.lastObject != rim) [v.layer addSublayer:rim];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    W12RimSet(rim, b, b.size.width / 2, NO);
    [CATransaction commit];
    W12CCSigSet(v, kCCSig, sig);
}
static void (*o_npLayout)(id, SEL);
static void n_npLayout(UIView *self, SEL _cmd) { o_npLayout(self, _cmd); W12GlassRimOn(self); }
static void (*o_npLayout2)(id, SEL);
static void n_npLayout2(UIView *self, SEL _cmd) { o_npLayout2(self, _cmd); W12GlassRimOn(self); }


// Round Control Center modules (replaces the separate "Rounded Modules" tweak): 1x1 modules and sliders become circles / capsules,
// bigger modules get a larger radius. The radius is written on the container, on its background views and through the
// private corner-radius setters (they differ between iOS builds, so every one that exists with a float/double argument is used).
static void W12CallRadiusSetter(id obj, NSString *name, CGFloat r) {
    SEL sel = NSSelectorFromString(name);
    if (![obj respondsToSelector:sel]) return;
    Method m = class_getInstanceMethod([obj class], sel); if (!m || method_getNumberOfArguments(m) != 3) return;
    char *at = method_copyArgumentType(m, 2); char t = at ? at[0] : 0; if (at) free(at);
    if (t == 'd') ((void (*)(id, SEL, double))objc_msgSend)(obj, sel, (double)r);
    else if (t == 'f') ((void (*)(id, SEL, float))objc_msgSend)(obj, sel, (float)r);
}
static void W12CCRound(UIView *c) {
    W12CCPrefs();
    if (!gCCRoundOn || !c.window) return;
    CGSize s = c.bounds.size;
    W12CCSig rsig = { (float)s.width, (float)s.height, 0, 1 };
    if (W12CCSigSame(c, kCCRoundSig, rsig)) return;                    // same size as last time: radii are already written (this walks the whole subtree)
    W12CCSigSet(c, kCCRoundSig, rsig); CGFloat m = MIN(s.width, s.height), M = MAX(s.width, s.height);
    if (m < 30 || m >= 190 || M > 360) return;                       // expanded panels and full-width backings keep their stock shape
    static NSMutableSet *logged; if (!logged) logged = [NSMutableSet set];
    NSString *cn = NSStringFromClass([c class]);
    if (![logged containsObject:cn]) {
        [logged addObject:cn]; NSMutableArray *names = [NSMutableArray array]; unsigned n = 0;
        Method *ms = class_copyMethodList([c class], &n);
        for (unsigned i = 0; i < n; i++) { NSString *nm = NSStringFromSelector(method_getName(ms[i])); if ([nm localizedCaseInsensitiveContainsString:@"corner"] || [nm localizedCaseInsensitiveContainsString:@"radius"]) [names addObject:nm]; }
        free(ms); W12_LOG(@"cc round: %@ corner selectors: %@", cn, [names componentsJoinedByString:@" "]);
    }
    CGFloat ratio = M / MAX(1, m), r = W12CCRoundRadius(m);
    for (NSString *sn in @[@"setCompactContinuousCornerRadius:", @"setContinuousCornerRadius:", @"_setContinuousCornerRadius:", @"setCornerRadius:"]) W12CallRadiusSetter(c, sn, r);
    (void)ratio;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:c];
    for (int depth = 0; depth < 4 && stack.count; depth++) {
        NSMutableArray *next = [NSMutableArray array];
        for (UIView *p in stack) {
            CGSize ps = p.bounds.size;
            if (fabs(ps.width - s.width) <= 6 && fabs(ps.height - s.height) <= 6) {
                if (p.layer.cornerRadius != r) p.layer.cornerRadius = r;
                // masksToBounds on a view that has children (blur, labels, artwork) makes Core Animation render it offscreen on every frame:
                // that was the lag when pulling Control Center down. Only plain backgrounds (materials / leaves) are clipped this way.
                // ... but skipping it left the fill with the stock corners (rim round, fill squarish), so every module-sized view is clipped again.
                if (!p.layer.masksToBounds) p.layer.masksToBounds = YES;
                if (p != c) for (NSString *sn in @[@"setContinuousCornerRadius:", @"_setContinuousCornerRadius:", @"setCornerRadius:"]) W12CallRadiusSetter(p, sn, r);
            }
            for (UIView *sv in p.subviews) [next addObject:sv];
        }
        stack = next;
    }
}

// Control Center module container: every module background should be equally clear. The Music module uses other classes than
// the plain MTMaterialView, so look at the container's big background-like subviews and log what is in there (diagnosis).
static void (*o_ccLayout)(id, SEL);
static void n_ccLayout(UIView *self, SEL _cmd) {
    o_ccLayout(self, _cmd);
    W12CCRound(self);
    W12CCPrefs();
    if (!gCCOn || !self.window) return;
    CGFloat want = gCCAlpha;
    CGSize cs = self.bounds.size;
    W12CCSig csig = { (float)cs.width, (float)cs.height, (float)want, 8 | ((int)(CACurrentMediaTime() * 2) << 4) };   // re-checked twice a second at most
    if (W12CCSigSame(self, kCCSig, csig)) return;                                  // same size/prefs: the backgrounds are already faded
    W12CCSigSet(self, kCCSig, csig);
    static NSMutableSet *logged; if (!logged) logged = [NSMutableSet set];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:self];
    for (int depth = 0; depth < 3 && stack.count; depth++) {
        NSMutableArray *next = [NSMutableArray array];
        for (UIView *p in stack) for (UIView *s in p.subviews) {
            NSString *cn = NSStringFromClass([s class]);
            BOOL big = s.bounds.size.width * s.bounds.size.height >= 0.85 * cs.width * cs.height;
            if (big && ![logged containsObject:cn]) { [logged addObject:cn]; W12_LOG(@"cc module bg candidate: %@ in %@ (%.0fx%.0f)", cn, NSStringFromClass([self class]), cs.width, cs.height); }
            BOOL bgLike = [cn containsString:@"Material"] || [cn containsString:@"Backdrop"] || [cn containsString:@"VisualEffect"] || [cn containsString:@"Background"] || [cn containsString:@"Blur"];
            if (big && bgLike) for (CALayer *l in s.layer.sublayers) if (![l.name isEqualToString:@"w12.ccrim"] && l.opacity != want) l.opacity = want;
            [next addObject:s];
        }
        stack = next;
    }
}


// MARK: - Alerts (UIAlertController, also the system ones in SpringBoard): iOS 26 glass card with a rim and clear pill buttons

static const void *kAlertSig = &kAlertSig;
static const void *kAlertExtraKey = &kAlertExtraKey;   // extra glass drawn under the card (the layout of the card itself is left alone)
static const void *kRowDyKey = &kRowDyKey;
static NSString *const kAlertRim = @"w12.alertrim", *const kAlertFill = @"w12.alertfill", *const kAlertBtnRim = @"w12.alertbtnrim";

static void W12AlertHideLines(UIView *v, int depth) {
    if (depth > 4) return;
    for (UIView *s in v.subviews) {
        NSString *cn = NSStringFromClass([s class]);
        if ([cn containsString:@"Separator"] || [cn containsString:@"Hairline"]) { if (!s.hidden) s.hidden = YES; continue; }
        W12AlertHideLines(s, depth + 1);
    }
}
static void W12AlertFade(UIView *v, int depth, CGFloat a) {
    if (depth > 3) return;
    for (UIView *s in v.subviews) {
        NSString *cn = NSStringFromClass([s class]);
        if ([s isKindOfClass:[UIVisualEffectView class]] || [cn containsString:@"Backdrop"] || [cn containsString:@"Background"] || [cn containsString:@"Knockout"]) {
            if (s.bounds.size.width > 60 && s.bounds.size.height > 40 && s.alpha != a) s.alpha = a;
            continue;
        }
        W12AlertFade(s, depth + 1, a);
    }
}

// Header / button text of the card: left-aligned bold title, grey message, white button labels (iOS 26 alert).
static BOOL W12InActionView(UIView *v, UIView *card) {
    for (UIView *p = v.superview; p && p != card; p = p.superview) {
        NSString *cn = NSStringFromClass([p class]);
        if ([cn containsString:@"Representation"] || [cn containsString:@"ActionView"]) return YES;
    }
    return NO;
}
static void W12AlertCollectLabels(UIView *v, int depth, NSMutableArray *out) {
    if (depth > 14) return;
    for (UIView *s in v.subviews) {
        if ([s isKindOfClass:[UILabel class]]) [out addObject:s];
        else W12AlertCollectLabels(s, depth + 1, out);
    }
}
static void W12AlertStyleText(UIView *card) {
    NSMutableArray *labels = [NSMutableArray array];
    W12AlertCollectLabels(card, 0, labels);
    NSMutableArray *head = [NSMutableArray array];
    for (UILabel *l in labels) {
        if (l.text.length == 0) continue;
        if (W12InActionView(l, card)) {
            CGFloat r = 0, g = 0, b = 0, a = 0; [l.textColor getRed:&r green:&g blue:&b alpha:&a];
            BOOL red = r > 0.65 && g < 0.45 && b < 0.45;                        // destructive actions keep their red
            l.textColor = red ? [UIColor colorWithRed:1 green:0.35 blue:0.31 alpha:1] : [UIColor whiteColor];
            l.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        } else [head addObject:l];
    }
    [head sortUsingComparator:^NSComparisonResult(UILabel *x, UILabel *y) {
        CGFloat xy = [x convertPoint:CGPointZero toView:card].y, yy = [y convertPoint:CGPointZero toView:card].y;
        return xy < yy ? NSOrderedAscending : NSOrderedDescending; }];
    for (NSUInteger i = 0; i < head.count; i++) {
        UILabel *l = head[i];
        l.textAlignment = NSTextAlignmentLeft;
        if (i == 0) { l.textColor = [UIColor whiteColor]; l.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold]; }
        else { l.textColor = [UIColor colorWithWhite:1 alpha:0.62]; l.font = [UIFont systemFontOfSize:15]; }
    }
    static int logged = 0;
    if (logged < 3) { logged++; for (UILabel *l in labels) W12_LOG(@"alert label %@ \"%@\" inAction=%d", NSStringFromClass([l class]), l.text, W12InActionView(l, card)); }
}

static const void *kAlertWide = &kAlertWide;
// iOS 12 alerts are 270pt wide: make the card bigger (iOS 26 style) by raising its width constraint
static void W12AlertWiden(UIView *card) {
    if (objc_getAssociatedObject(card, kAlertWide)) return;
    objc_setAssociatedObject(card, kAlertWide, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat target = MIN(338.0, [UIScreen mainScreen].bounds.size.width - 34);
    int hit = 0; UIView *v = card;
    for (int d = 0; d < 5 && v; d++, v = v.superview) {
        for (NSLayoutConstraint *c in v.constraints) {
            if (c.firstAttribute != NSLayoutAttributeWidth || c.secondItem || c.constant < 240 || c.constant > 300) continue;
            if (![c.firstItem isKindOfClass:[UIView class]] || ![card isDescendantOfView:c.firstItem]) continue;
            W12_LOG(@"alert width constraint %@ %.0f -> %.0f (rel %ld prio %.0f)", NSStringFromClass([c.firstItem class]), c.constant, target, (long)c.relation, c.priority);
            c.constant = target; hit++;
        }
    }
    if (!hit) W12_LOG(@"alert width constraint not found (card %@ %.0f)", NSStringFromClass([card class]), card.bounds.size.width);
    [card.superview setNeedsLayout]; [card setNeedsLayout];
}
// the whole alert card
static void W12ApplyAlertCardImpl(UIView *v);
static void W12ApplyAlertCard(UIView *v) {
    static int cardDepth = 0; if (cardDepth > 0) return; cardDepth++;
    @try { W12ApplyAlertCardImpl(v); } @finally { cardDepth--; }
}
static void W12ApplyAlertCardImpl(UIView *v) {
    W12CCPrefs();
    CGRect b = v.bounds;
    if (b.size.width < 150 || b.size.height < 60 || !v.window) return;
    for (UIResponder *r = v.nextResponder; r; r = r.nextResponder)       // action sheets (Settings reset menu, share menus...) keep the stock look
        if ([r isKindOfClass:[UIAlertController class]]) { if (((UIAlertController *)r).preferredStyle == UIAlertControllerStyleActionSheet) return; break; }
    if (gCCOn && W12Bool(@"alertGlass", YES)) W12AlertWiden(v);
    CGFloat extra = [objc_getAssociatedObject(v, kAlertExtraKey) doubleValue];
    CGRect b2 = b; b2.size.height += extra;                           // glass + rim cover the card and a little more below it: room for the margin under the last pill
    NSString *sig = [NSString stringWithFormat:@"c%.1f,%.1f,%.1f,%d", b.size.width, b.size.height, extra, gCCOn];
    UIVisualEffectView *glass = nil;
    for (UIView *s in v.subviews) if ([s.layer.name isEqualToString:@"w12.alertblur"]) { glass = (UIVisualEffectView *)s; break; }
    if ([objc_getAssociatedObject(v, kAlertSig) isEqualToString:sig]) { if (glass && (glass.frame.size.width != b2.size.width || glass.frame.size.height != b2.size.height)) glass.frame = b2; return; }
    objc_setAssociatedObject(v, kAlertSig, sig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gCCOn || !W12Bool(@"alertGlass", YES)) return;
    CGFloat R = MIN(38.0, b2.size.height / 2);
    v.layer.cornerRadius = R; v.layer.masksToBounds = NO;
    @try { [v.layer setValue:@YES forKey:@"continuousCorners"]; } @catch (__unused id e) {}
    if (!glass) {                                                    // own dark glass behind everything; the stock (light) backdrop is switched off
        glass = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
        glass.layer.name = @"w12.alertblur"; glass.userInteractionEnabled = NO;
        [v insertSubview:glass atIndex:0];
    }
    glass.frame = b2; glass.alpha = 0.92;
    glass.layer.cornerRadius = R; glass.clipsToBounds = YES;
    @try { [glass.layer setValue:@YES forKey:@"continuousCorners"]; } @catch (__unused id e) {}
    for (UIView *s in v.subviews) if (s != glass) {
        NSString *cn = NSStringFromClass([s class]);
        if ([s isKindOfClass:[UIVisualEffectView class]] || [cn containsString:@"Backdrop"] || [cn containsString:@"Background"] || [cn containsString:@"Knockout"]) { if (s.alpha != 0) s.alpha = 0; }
        else W12AlertFade(s, 0, 0);
    }
    W12AlertHideLines(v, 0);
    CALayer *rim = nil;
    for (CALayer *l in v.layer.sublayers) if ([l.name isEqualToString:kAlertRim]) { rim = l; break; }
    if (!rim) { rim = W12RimLayer(kAlertRim); [v.layer addSublayer:rim]; }
    if (v.layer.sublayers.lastObject != rim) [v.layer addSublayer:rim];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    W12RimSetL(rim, b2, R, YES, NO);
    [CATransaction commit];
}

// one button row: clear rounded pill with its own rim
static void W12ApplyAlertButton(UIView *v) {
    W12CCPrefs();
    CGRect b = v.bounds;
    if (b.size.width < 80 || b.size.height < 30 || b.size.height > 90 || !v.window) return;
    NSString *sig = [NSString stringWithFormat:@"b%.1f,%.1f,%d,%d", b.size.width, b.size.height, gCCOn, (int)(CACurrentMediaTime() * 3)];   // re-applied ~3x/s: the stock style resets colours on highlight / layout
    if ([objc_getAssociatedObject(v, kAlertSig) isEqualToString:sig]) return;
    objc_setAssociatedObject(v, kAlertSig, sig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CALayer *fill = nil, *rim = nil;
    for (CALayer *l in v.layer.sublayers) { if ([l.name isEqualToString:kAlertFill]) fill = l; else if ([l.name isEqualToString:kAlertBtnRim]) rim = l; }
    BOOL on = gCCOn && W12Bool(@"alertGlass", YES);
    if (!on) { fill.hidden = YES; rim.hidden = YES; return; }
    v.backgroundColor = [UIColor clearColor];
    {   // vibrancy / blur views inside the row paint the light fill: switch them off (labels keep working), and re-colour the labels
        NSMutableArray *stack = [NSMutableArray arrayWithObject:v];
        for (int d = 0; d < 4 && stack.count; d++) {
            NSMutableArray *next = [NSMutableArray array];
            for (UIView *p in stack) for (UIView *s in p.subviews) {
                if ([s isKindOfClass:[UIVisualEffectView class]]) { UIVisualEffectView *ev = (UIVisualEffectView *)s; if (ev.effect) ev.effect = nil; }
                else if ([s isKindOfClass:[UILabel class]] && ((UILabel *)s).text.length) {
                    UILabel *l = (UILabel *)s;
                    CGFloat r = 0, g = 0, bb = 0, a = 0; [l.textColor getRed:&r green:&g blue:&bb alpha:&a];
                    BOOL red = r > 0.65 && g < 0.45 && bb < 0.45;
                    UIColor *want = red ? [UIColor colorWithRed:1 green:0.35 blue:0.31 alpha:1] : [UIColor whiteColor];
                    if (![l.textColor isEqual:want]) l.textColor = want;
                    l.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
                }
                [next addObject:s];
            }
            stack = next;
        }
    }
    for (UIView *s in v.subviews) {          // the stock (light) highlight / backdrop of the row would tint the clear pill
        NSString *cn = NSStringFromClass([s class]);
        if ([cn containsString:@"Highlight"] || [cn containsString:@"Background"] || [cn containsString:@"Backdrop"] || [cn containsString:@"VisualEffect"] || [cn containsString:@"Knockout"] || [cn containsString:@"Material"]) {
            NSMutableArray *ls = [NSMutableArray array]; W12AlertCollectLabels(s, 0, ls);
            if (!ls.count && s.alpha != 0) s.alpha = 0;
        }
    }
    CGRect pb = CGRectInset(b, 14, 6);
    CGFloat r = pb.size.height / 2;
    if (!fill) { fill = [CALayer layer]; fill.name = kAlertFill; fill.actions = @{@"bounds": [NSNull null], @"position": [NSNull null], @"cornerRadius": [NSNull null]}; [v.layer insertSublayer:fill atIndex:0]; }
    if (!rim) { rim = W12RimLayer(kAlertBtnRim); [v.layer insertSublayer:rim above:fill]; }
    fill.hidden = NO; rim.hidden = NO;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    fill.frame = pb; fill.cornerRadius = r;
    fill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.17].CGColor;      // clear grey like the Control Center modules
    W12RimSetL(rim, pb, r, NO, NO);
    [CATransaction commit];
}

static void W12AlertDiag(UIView *v) {
    static int n = 0; if (n >= 4 || !v.window) return; n++;
    W12_LOG(@"alert hierarchy (%@):", NSStringFromClass([v class]));
    W12Dump(v, 1, 5);
}

// ---- Buttons. The row views of UIAlertController are private and differ between iOS builds, so they are found from the controller:
// every label whose text is an action title belongs to a row = its highest ancestor that is still button-sized.
static NSString *W12Trim(NSString *s) {
    return [[s ?: @"" stringByReplacingOccurrencesOfString:@"\u2002" withString:@""] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
static const void *kAlertInkKey = &kAlertInkKey;
// horizontal middle of the pixels a label really draws (label coordinates), NAN when it draws nothing
static CGFloat W12InkMidX(UILabel *l) {
    int w = (int)ceil(l.bounds.size.width), h = (int)ceil(l.bounds.size.height);
    if (w < 2 || h < 2 || w > 1200 || h > 200) return NAN;
    uint8_t *buf = calloc((size_t)w * h, 1);
    if (!buf) return NAN;
    CGContextRef cx = CGBitmapContextCreate(buf, w, h, 8, w, NULL, kCGImageAlphaOnly);
    if (!cx) { free(buf); return NAN; }
    CGContextTranslateCTM(cx, 0, h); CGContextScaleCTM(cx, 1, -1);
    [l.layer renderInContext:cx];
    int minX = w, maxX = -1;
    for (int y = 0; y < h; y++) { uint8_t *p = buf + (size_t)y * w; for (int x = 0; x < w; x++) if (p[x] > 40) { if (x < minX) minX = x; if (x > maxX) maxX = x; } }
    CGContextRelease(cx); free(buf);
    if (maxX < 0 || (minX <= 0 && maxX >= w - 1)) return NAN;   // nothing drawn, or an opaque background: cannot tell
    return (minX + maxX + 1) / 2.0;
}
static const void *kAlertTallKey = &kAlertTallKey;
// iOS 12 action rows are 44pt: iOS 26 buttons are taller. Raise the stock height constraints of the row (found on the row or just inside it).
static void W12AlertTallRow(UIView *row) {
    if (objc_getAssociatedObject(row, kAlertTallKey)) return;
    objc_setAssociatedObject(row, kAlertTallKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    int hit = 0;
    NSMutableArray *views = [NSMutableArray arrayWithObject:row];
    for (int d = 0; d < 3; d++) { NSArray *cur = [views copy]; for (UIView *v in cur) for (UIView *s in v.subviews) if (![views containsObject:s]) [views addObject:s]; }
    for (UIView *up = row.superview; up && hit == 0 && up.bounds.size.height < 400; up = nil) [views addObject:up];
    for (UIView *v in views) for (NSLayoutConstraint *c in v.constraints) {
        if (c.firstAttribute != NSLayoutAttributeHeight || c.secondItem || c.firstItem != v || c.constant < 40 || c.constant > 48) continue;
        W12_LOG(@"alert row height constraint %@ %.0f -> 54 (rel %ld prio %.0f)", NSStringFromClass([v class]), c.constant, (long)c.relation, c.priority);
        c.constant = 54; hit++;
    }
    if (!hit) W12_LOG(@"alert row height: no constraint found (%@ %.0f)", NSStringFromClass([row class]), row.bounds.size.height);
    else { [row.superview setNeedsLayout]; }
}
// Keeps an action label in the middle of its pill. Works from the label's untransformed centre, so it is correct whatever the stock layout did
// (a pressed row relayouts / re-aligns its label). The padding spaces that force the stacked layout are compensated: the leading ones count,
// the trailing ones hang outside the line, so the text would sit half a padding too far to the right.
static void W12AlertLabelAdjust(UILabel *l, UIView *row, CGFloat ty) {
    if (l.textAlignment != NSTextAlignmentCenter) l.textAlignment = NSTextAlignmentCenter;
    NSString *tx = l.text ?: @"";
    NSUInteger lead = 0; while (lead < tx.length && [tx characterAtIndex:lead] == 0x2002) lead++;
    CGFloat padAdj = lead ? -(lead * [@"\u2002" sizeWithAttributes:@{NSFontAttributeName: l.font}].width) / 2.0 : 0;
    UIView *sv = l.superview; if (!sv) return;
    CGPoint c = [sv convertPoint:l.center toView:row];
    CGFloat need = CGRectGetMidX(row.bounds) + padAdj - c.x;
    CGAffineTransform cur = l.transform;
    if (fabs(cur.tx - need) > 0.25 || fabs(cur.ty - ty) > 0.25 || fabs(cur.a - 1) > 0.001 || fabs(cur.d - 1) > 0.001)
        l.transform = CGAffineTransformMakeTranslation(need, ty);
}
static void W12StyleAlertRow(UIView *row, NSArray<UILabel *> *rowLabels) {
    CGRect b = row.bounds;
    if (b.size.width < 80 || b.size.height < 30) return;
    // The stock rows touch the bottom rim of the card: lift the pill so the margin under the last pill, the gap between pills and the side margins are about the same.
    CGRect pb = CGRectMake(15, 0.5, b.size.width - 30, MAX(30.0, b.size.height - 1));
    CGFloat pdy = CGRectGetMidY(pb) - CGRectGetMidY(b);                  // the label follows the pill
    NSNumber *last = objc_getAssociatedObject(row, kAlertSig);
    CFTimeInterval now = CACurrentMediaTime();
    if (last && now - last.doubleValue < 0.08) return;
    objc_setAssociatedObject(row, kAlertSig, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    row.backgroundColor = [UIColor clearColor];
    row.layer.backgroundColor = nil;
    CGAffineTransform up = CGAffineTransformMakeTranslation(0, [objc_getAssociatedObject(row, kRowDyKey) doubleValue]);   // rows are spread apart (gap between pills)
    if (!CGAffineTransformEqualToTransform(row.transform, up)) row.transform = up;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:row];
    for (int d = 0; d < 5 && stack.count; d++) {            // everything stock that paints a fill behind the label goes: effects, highlight, backdrop
        NSMutableArray *next = [NSMutableArray array];
        for (UIView *p in stack) for (UIView *s in p.subviews) {
            if ([s isKindOfClass:[UIVisualEffectView class]]) { UIVisualEffectView *ev = (UIVisualEffectView *)s; if (ev.effect) ev.effect = nil; }
            NSMutableArray *ls = [NSMutableArray array]; W12AlertCollectLabels(s, 0, ls);
            BOOL hasLabel = [s isKindOfClass:[UILabel class]] || ls.count;
            if (!hasLabel) { if (s.alpha != 0) s.alpha = 0; }
            else { if (![s isKindOfClass:[UILabel class]] && s.backgroundColor) s.backgroundColor = [UIColor clearColor]; [next addObject:s]; }
        }
        stack = next;
    }
    for (UILabel *l in rowLabels) {
        CGFloat r = 0, g = 0, bb = 0, a = 0; [l.textColor getRed:&r green:&g blue:&bb alpha:&a];
        BOOL red = r > 0.65 && g < 0.45 && bb < 0.45;
        UIColor *want = red ? [UIColor colorWithRed:1 green:0.42 blue:0.38 alpha:1] : [UIColor whiteColor];
        if (![l.textColor isEqual:want]) l.textColor = want;
        l.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
        l.alpha = 1;
        l.textAlignment = NSTextAlignmentCenter;
        W12AlertLabelAdjust(l, row, pdy);
    }
    CALayer *fill = nil, *rim = nil;
    for (CALayer *l in row.layer.sublayers) { if ([l.name isEqualToString:kAlertFill]) fill = l; else if ([l.name isEqualToString:kAlertBtnRim]) rim = l; }
    CGFloat rad = pb.size.height / 2;
    if (!fill) { fill = [CALayer layer]; fill.name = kAlertFill; fill.actions = @{@"bounds": [NSNull null], @"position": [NSNull null], @"cornerRadius": [NSNull null], @"backgroundColor": [NSNull null]}; [row.layer insertSublayer:fill atIndex:0]; }
    if (!rim) { rim = W12RimLayer(kAlertBtnRim); [row.layer insertSublayer:rim above:fill]; }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    fill.hidden = NO; rim.hidden = NO;
    fill.frame = pb; fill.cornerRadius = rad;
    fill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.17].CGColor;       // clear grey, like the Control Center modules
    W12RimSetL(rim, pb, rad, NO, NO);
    [CATransaction commit];
}
static const void *kAlertRowsKey = &kAlertRowsKey;
// While a finger is on the alert (tap / slide up and down) UIKit repaints the stock highlight of the touched row on every frame, so the pills
// flickered between light and dark. The throttled restyle is too slow for that: this cheap pass runs on every frame while the alert is on screen.
static void W12AlertEnforceRow(UIView *row) {
    if (row.backgroundColor && ![row.backgroundColor isEqual:[UIColor clearColor]]) row.backgroundColor = [UIColor clearColor];
    if (row.layer.backgroundColor) row.layer.backgroundColor = nil;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:row];
    for (int d = 0; d < 5 && stack.count; d++) {
        NSMutableArray *next = [NSMutableArray array];
        for (UIView *p in stack) for (UIView *s in p.subviews) {
            if ([s isKindOfClass:[UIVisualEffectView class]]) { UIVisualEffectView *ev = (UIVisualEffectView *)s; if (ev.effect) ev.effect = nil; }
            NSMutableArray *ls = [NSMutableArray array]; W12AlertCollectLabels(s, 0, ls);
            BOOL hasLabel = [s isKindOfClass:[UILabel class]] || ls.count;
            if (!hasLabel) { if (s.alpha != 0) s.alpha = 0; if (s.layer.opacity != 0) s.layer.opacity = 0; }
            else if (![s isKindOfClass:[UILabel class]]) { if (s.backgroundColor && ![s.backgroundColor isEqual:[UIColor clearColor]]) s.backgroundColor = [UIColor clearColor]; [next addObject:s]; }
        }
        stack = next;
    }
    {   // holding a finger on a row makes UIKit re-align / move its label: put it back on every frame
        NSMutableArray *ls = [NSMutableArray array]; W12AlertCollectLabels(row, 0, ls);
        for (UILabel *l in ls) {
            if (!W12Trim(l.text).length) continue;
            CGFloat r = 0, g = 0, bb = 0, a = 0; [l.textColor getRed:&r green:&g blue:&bb alpha:&a];
            BOOL red = r > 0.65 && g < 0.45 && bb < 0.45;
            UIColor *want = red ? [UIColor colorWithRed:1 green:0.42 blue:0.38 alpha:1] : [UIColor whiteColor];
            if (![l.textColor isEqual:want]) l.textColor = want;
            if (fabs(l.font.pointSize - 18) > 0.1) l.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
            if (l.alpha != 1) l.alpha = 1;
            W12AlertLabelAdjust(l, row, 0);
        }
    }
    for (CALayer *l in row.layer.sublayers) {
        if ([l.name isEqualToString:kAlertFill]) { if (l.hidden || l.opacity != 1) { [CATransaction begin]; [CATransaction setDisableActions:YES]; l.hidden = NO; l.opacity = 1; [CATransaction commit]; } }
        else if ([l.name isEqualToString:kAlertBtnRim]) { if (l.hidden || l.opacity != 1) { [CATransaction begin]; [CATransaction setDisableActions:YES]; l.hidden = NO; l.opacity = 1; [CATransaction commit]; } }
    }
}
@interface W12AlertTicker : NSObject
@property (nonatomic, weak) UIAlertController *ac;
@property (nonatomic, strong) CADisplayLink *link;
@end
@implementation W12AlertTicker
- (void)tick:(CADisplayLink *)l {
    UIAlertController *ac = self.ac;
    if (!ac || !ac.view.window) { [l invalidate]; self.link = nil; return; }
    NSPointerArray *pa = objc_getAssociatedObject(ac, kAlertRowsKey);
    for (NSUInteger i = 0; i < pa.count; i++) { UIView *r = (__bridge UIView *)[pa pointerAtIndex:i]; if (r.window) W12AlertEnforceRow(r); }
}
@end
static void W12AlertStartTicker(UIAlertController *ac) {
    if (objc_getAssociatedObject(ac, kAlertSig)) return;
    W12AlertTicker *tk = [W12AlertTicker new]; tk.ac = ac;
    tk.link = [CADisplayLink displayLinkWithTarget:tk selector:@selector(tick:)];
    [tk.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(ac, kAlertSig, tk, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static const void *kHdrKey = &kHdrKey;
// title / message: left aligned, with an inner margin (paragraph indents) so the text sits a little further from the glass rim.
// Guarded by a key: applying an attributed string asks for a layout pass, so it must never be repeated with the same content.
static void W12StyleHeaderLabel(UILabel *l, UIFont *f, UIColor *c, CGFloat indent, CGFloat dy) {
    NSString *key = [NSString stringWithFormat:@"%@|%.1f|%.1f", l.text, f.pointSize, indent];
    NSParagraphStyle *cur = l.attributedText.length ? [l.attributedText attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:NULL] : nil;
    if (![objc_getAssociatedObject(l, kHdrKey) isEqualToString:key] || !cur || cur.headIndent != indent) {
        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
        ps.alignment = NSTextAlignmentLeft; ps.headIndent = indent; ps.firstLineHeadIndent = indent; ps.tailIndent = -indent;
        ps.lineBreakMode = NSLineBreakByWordWrapping; ps.lineSpacing = 1.5;
        l.attributedText = [[NSAttributedString alloc] initWithString:l.text ?: @"" attributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: c, NSParagraphStyleAttributeName: ps}];
        objc_setAssociatedObject(l, kHdrKey, key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGAffineTransform tr = dy ? CGAffineTransformMakeTranslation(0, dy) : CGAffineTransformIdentity;
    if (!CGAffineTransformEqualToTransform(l.transform, tr)) l.transform = tr;
}
static int gAlertDepth = 0;
// Gap between the pills, margin under the last pill and side margins like iOS 26: the rows are spread with a visual offset (touches follow it),
// every clip between the rows and the card is switched off, and the glass of the card is extended below by exactly what is missing.
static void W12AlertGeometry(UIAlertController *ac, NSArray<UIView *> *rowsIn) {
    if (!rowsIn.count) return;
    UIView *root = ac.view;
    NSArray<UIView *> *rows = [rowsIn sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ya = [a convertPoint:CGPointZero toView:root].y - a.transform.ty, yb = [b convertPoint:CGPointZero toView:root].y - b.transform.ty;
        return ya < yb ? NSOrderedAscending : (ya > yb ? NSOrderedDescending : NSOrderedSame);
    }];
    NSMutableArray<UIView *> *cards = [NSMutableArray array];               // every ancestor that carries our glass rim (normally just one)
    for (UIView *p = rows[0].superview; p && p != root; p = p.superview)
        for (CALayer *l in p.layer.sublayers) if ([l.name isEqualToString:kAlertRim]) { [cards addObject:p]; break; }
    if (!cards.count) return;
    for (UIView *r in rows) {
        r.clipsToBounds = NO;
        for (UIView *p = r.superview; p && p != root; p = p.superview) if (p.clipsToBounds) p.clipsToBounds = NO;
    }
    const CGFloat gap = 7;
    for (NSUInteger i = 0; i < rows.count; i++) {
        UIView *r = rows[i];
        CGFloat dy = i * gap;
        objc_setAssociatedObject(r, kRowDyKey, @(dy), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGAffineTransform tr = CGAffineTransformMakeTranslation(0, dy);
        if (!CGAffineTransformEqualToTransform(r.transform, tr)) r.transform = tr;
    }
    for (UIView *card in cards) {
        CGFloat bottom = 0;
        for (UIView *r in rows) bottom = MAX(bottom, CGRectGetMaxY([r convertRect:r.bounds toView:card]));
        CGFloat extra = MAX(0, MIN(80, bottom - 0.5 + 15 - card.bounds.size.height));
        CGFloat old = [objc_getAssociatedObject(card, kAlertExtraKey) doubleValue];
        if (fabs(extra - old) > 0.5) {
            objc_setAssociatedObject(card, kAlertExtraKey, @(extra), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(card, kAlertSig, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            W12ApplyAlertCard(card);
            static int n = 0; if (n < 4) { n++; W12_LOG(@"alert geometry: rows=%lu card=%@ %.0fx%.0f extra=%.1f", (unsigned long)rows.count, NSStringFromClass([card class]), card.bounds.size.width, card.bounds.size.height, extra); }
        }
    }
}
static void W12StyleAlertRowsImpl(UIAlertController *ac);
static void W12StyleAlertRows(UIAlertController *ac) {
    if (gAlertDepth > 0) return;                    // styling a label can ask for another layout pass: never recurse into ourselves
    gAlertDepth++; W12StyleAlertRowsImpl(ac); gAlertDepth--;
}
static void W12StyleAlertRowsImpl(UIAlertController *ac) {
    W12CCPrefs();
    if (!gCCOn || !W12Bool(@"alertGlass", YES) || ac.preferredStyle != UIAlertControllerStyleAlert) return;   // action sheets keep the stock look
    UIView *root = ac.view;
    if (!root.window) return;
    if (![root.tintColor isEqual:[UIColor whiteColor]]) root.tintColor = [UIColor whiteColor];   // default actions take the tint: white instead of blue
    NSMutableSet *titles = [NSMutableSet set];
    for (UIAlertAction *a in ac.actions) if (a.title.length) [titles addObject:W12Trim(a.title)];
    NSString *head = W12Trim(ac.title);
    NSMutableArray *labels = [NSMutableArray array];
    W12AlertCollectLabels(root, 0, labels);
    NSMutableDictionary<NSValue *, NSMutableArray *> *rows = [NSMutableDictionary dictionary];
    NSMutableArray *rowOrder = [NSMutableArray array];
    for (UILabel *l in labels) {
        NSString *tx = W12Trim(l.text);
        if (!tx.length || ![titles containsObject:tx] || [tx isEqualToString:head]) continue;
        UIView *row = l, *p = l.superview;
        while (p && p != root && p.bounds.size.height <= 70 && p.bounds.size.height >= l.bounds.size.height) {
            BOOL other = NO;                                           // never climb into a view that holds another action's label
            for (UILabel *o in labels) if (o != l && [titles containsObject:W12Trim(o.text)] && ![W12Trim(o.text) isEqualToString:head] && [o isDescendantOfView:p]) { other = YES; break; }
            if (other) break;
            row = p; p = p.superview;
        }
        if (row == l) continue;
        NSValue *k = [NSValue valueWithNonretainedObject:row];
        if (!rows[k]) { rows[k] = [NSMutableArray array]; [rowOrder addObject:row]; }
        [rows[k] addObject:l];
    }
    static int logged = 0;
    if (logged < 3 && rowOrder.count) { logged++; for (UIView *r in rowOrder) W12_LOG(@"alert row %@ (%.0fx%.0f) labels=%lu", NSStringFromClass([r class]), r.bounds.size.width, r.bounds.size.height, (unsigned long)[rows[[NSValue valueWithNonretainedObject:r]] count]); }
    W12AlertGeometry(ac, rowOrder);
    for (UIView *r in rowOrder) W12StyleAlertRow(r, rows[[NSValue valueWithNonretainedObject:r]]);
    { NSPointerArray *pa = [NSPointerArray weakObjectsPointerArray]; for (UIView *r in rowOrder) [pa addPointer:(__bridge void *)r]; objc_setAssociatedObject(ac, kAlertRowsKey, pa, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    // title + message: left aligned, bold / grey (matched by text, so button labels are never touched)
    NSString *msg = W12Trim(ac.message);
    UILabel *titleL = nil, *msgL = nil;
    for (UILabel *l in labels) {
        NSString *tx = W12Trim(l.text);
        if (!tx.length) continue;
        if ([titles containsObject:tx] && ![tx isEqualToString:head]) continue;          // action label
        BOOL inRow = NO; for (UIView *r in rowOrder) if ([l isDescendantOfView:r]) { inRow = YES; break; }
        if (inRow) continue;
        if (head.length && [tx isEqualToString:head]) {
            W12StyleHeaderLabel(l, [UIFont systemFontOfSize:20 weight:UIFontWeightBold], [UIColor whiteColor], 14, 4); titleL = l;
        } else if (msg.length && [tx isEqualToString:msg]) {
            W12StyleHeaderLabel(l, [UIFont systemFontOfSize:14 weight:UIFontWeightRegular], [UIColor colorWithWhite:1 alpha:0.66], 14, 0); msgL = l;
        } else {                                                                          // any other text of the card (third-party alerts, custom content): stock black would vanish on the dark glass
            CGFloat w = 0, a = 0; [l.textColor getWhite:&w alpha:&a];
            if (w < 0.6 || l.attributedText) l.textColor = [UIColor colorWithWhite:1 alpha:0.78];
        }
    }
    // the title is bigger than the stock one, so its label is too short and the message used to run into it: the message is placed under the
    // title's real (measured) height with an even gap, whatever the stock layout decided.
    if (titleL && msgL && titleL.superview && titleL.superview == msgL.superview && titleL.bounds.size.width > 20) {
        CGFloat need = ceil([titleL sizeThatFits:CGSizeMake(titleL.bounds.size.width, CGFLOAT_MAX)].height);
        CGFloat tTop = titleL.center.y - titleL.bounds.size.height / 2, mTop = msgL.center.y - msgL.bounds.size.height / 2;
        CGFloat dy = MAX(-4, MIN(26, tTop + 4 + need + 6 - mTop));
        CGAffineTransform tr = CGAffineTransformMakeTranslation(0, dy);
        if (!CGAffineTransformEqualToTransform(msgL.transform, tr)) msgL.transform = tr;
    }
}

static const void *kAlertMsgPad = &kAlertMsgPad;
// more air between the text and the buttons (taller card): one extra, nearly empty line under the message. The layout system does the rest.
static void W12AlertPadMessage(UIAlertController *ac) {
    W12CCPrefs(); if (!gCCOn) return;
    if (ac.preferredStyle != UIAlertControllerStyleAlert || objc_getAssociatedObject(ac, kAlertMsgPad)) return;
    objc_setAssociatedObject(ac, kAlertMsgPad, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!ac.message.length || ac.textFields.count) return;
    @try { ac.message = [ac.message stringByAppendingString:@"\n\u2002"]; } @catch (__unused id e) {}
}
// iOS 12 puts two short actions side by side; iOS 26 stacks them. The stock layout stacks them as soon as a title does not fit
// in half the card, so the widest title is padded with invisible spaces (centred, so nothing moves) when everything would fit.
static const void *kAlertPadded = &kAlertPadded;
static void W12AlertForceStack(UIAlertController *ac) {
    W12CCPrefs();
    if (!gCCOn || !W12Bool(@"alertGlass", YES)) return;
    if (ac.preferredStyle != UIAlertControllerStyleAlert || ac.textFields.count) return;
    NSArray<UIAlertAction *> *acts = ac.actions;
    if (acts.count < 2 || acts.count > 3 || objc_getAssociatedObject(ac, kAlertPadded)) return;
    objc_setAssociatedObject(ac, kAlertPadded, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIFont *f = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    CGFloat maxW = 0; UIAlertAction *widest = nil;
    for (UIAlertAction *a in acts) {
        if (!a.title.length) return;
        CGFloat w = [a.title sizeWithAttributes:@{NSFontAttributeName: f}].width;
        if (w > maxW) { maxW = w; widest = a; }
    }
    if (maxW >= 175 || !widest) return;                                   // already too wide for one row: stock stacks them
    CGFloat sp = MAX(4.0, [@"\u2002" sizeWithAttributes:@{NSFontAttributeName: f}].width);
    int n = MIN(14, (int)ceil((195.0 - maxW) / (2 * sp)));
    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < n; i++) [pad appendString:@"\u2002"];
    @try { [widest setValue:[NSString stringWithFormat:@"%@%@%@", pad, widest.title, pad] forKey:@"title"]; W12_LOG(@"alert: stacked actions (%lu), padded \"%@\" by %d", (unsigned long)acts.count, widest.title, n); }
    @catch (__unused id e) { W12_LOG(@"alert: cannot pad title"); }
}

static void W12HookAlerts(void) {
    static BOOL acHooked = NO;
    if (!acHooked) {
        Class ac = objc_getClass("UIAlertController");
        Method m = ac ? class_getInstanceMethod(ac, @selector(viewWillAppear:)) : NULL;
        if (m) {
            acHooked = YES;
            IMP orig = method_getImplementation(m);
            class_replaceMethod(ac, @selector(viewWillAppear:), imp_implementationWithBlock(^(UIAlertController *self, BOOL animated) {
                if (W12Bool(@"alertGlass", YES)) W12AlertPadMessage(self);
                W12AlertForceStack(self);
                if (W12Bool(@"alertGlass", YES) && self.preferredStyle == UIAlertControllerStyleAlert) self.view.tintColor = [UIColor whiteColor];
                ((void (*)(id, SEL, BOOL))orig)(self, @selector(viewWillAppear:), animated);
            }), method_getTypeEncoding(m));
            W12_LOG(@"hooked UIAlertController viewWillAppear:");
        }
        Method ml = ac ? class_getInstanceMethod(ac, @selector(viewDidLayoutSubviews)) : NULL;
        if (ml) {
            IMP ol = method_getImplementation(ml);
            class_replaceMethod(ac, @selector(viewDidLayoutSubviews), imp_implementationWithBlock(^(UIAlertController *self) {
                ((void (*)(id, SEL))ol)(self, @selector(viewDidLayoutSubviews));
                W12StyleAlertRows(self);
            }), method_getTypeEncoding(ml));
        }
        Method ma = ac ? class_getInstanceMethod(ac, @selector(viewDidAppear:)) : NULL;
        if (ma) {
            IMP oa = method_getImplementation(ma);
            class_replaceMethod(ac, @selector(viewDidAppear:), imp_implementationWithBlock(^(UIAlertController *self, BOOL animated) {
                ((void (*)(id, SEL, BOOL))oa)(self, @selector(viewDidAppear:), animated);
                if (W12Bool(@"alertGlass", YES) && self.preferredStyle == UIAlertControllerStyleAlert) W12AlertStartTicker(self);
                __weak UIAlertController *w = self;                  // the stock style may reset colours after the first layout: look again for a moment
                for (NSNumber *d in @[@0.02, @0.1, @0.25, @0.5, @1.0]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ UIAlertController *s = w; if (s.view.window) W12StyleAlertRows(s); });
            }), method_getTypeEncoding(ma));
        }
    }
    static NSMutableSet *done; if (!done) done = [NSMutableSet set];
    struct { const char *cls; int kind; } list[] = {
        {"_UIInterfaceActionGroupView", 0}, {"_UIAlertControllerInterfaceActionGroupView", 0},
    };
    for (unsigned i = 0; i < sizeof(list) / sizeof(list[0]); i++) {
        NSString *cn = @(list[i].cls); int kind = list[i].kind;
        if ([done containsObject:cn]) continue;
        Class c = objc_getClass(list[i].cls);
        if (!c) continue;
        SEL sel = @selector(layoutSubviews);
        Method m = class_getInstanceMethod(c, sel);
        if (!m) continue;
        [done addObject:cn];
        IMP orig = method_getImplementation(m);
        IMP imp = imp_implementationWithBlock(^(UIView *self) {
            ((void (*)(id, SEL))orig)(self, sel);
            if (kind == 0) { W12AlertDiag(self); W12ApplyAlertCard(self); } else W12ApplyAlertButton(self);
        });
        class_replaceMethod(c, sel, imp, method_getTypeEncoding(m));
        W12_LOG(@"hooked alert view %@ (%@)", cn, kind == 0 ? @"card" : @"button");
    }
}

// Passcode keypad keys: the class name differs between iOS builds (TPNumberPadButton, SBUIPasscodeNumberPadButton, ...), so find them by name.
// Passcode keypad: the keys pop in as a bouncy wave from the middle of the pad (like the iOS 26 passcode screen).
// ---- Passcode keypad: exact port of the original 26Passcode wave (decoded from its machine code) ----
// Every key flies from near the screen centre (15% of its distance, 15% size) to its real place on a spring
// (stiffness 200 / damping 15 / mass 1; the 0 key 150 / 12), in 4 waves delayed 0 / 0.0575 / 0.11 / 0.18 s.
// It starts when the keypad view is at least 95% visible. Native animations on the keys are stripped for ~1.5 s.
static const NSInteger kPCWave[4][4] = { {3, 2, 3, 0}, {2, 1, 2, 0}, {3, 2, 3, 0}, {0, 4, 0, 0} };
static const double kPCDelay[5] = { 0, 0, 0.0575, 0.11, 0.18 };
static NSString *const kPCPos = @"passcode.pos", *const kPCScale = @"passcode.scale";
static __weak UIView *gPCContainer;
static CADisplayLink *gPCLink;

static BOOL W12IsPCButton(UIView *v) {
    NSString *cn = NSStringFromClass([v class]);      // iOS 15 (original): SBPasscodeNumberPadButton; iOS 12 uses other names, so match by name part
    return [cn containsString:@"NumberPadButton"] && ![cn containsString:@"Emergency"];
}
static void W12PCCollect(UIView *v, NSMutableArray<UIView *> *out, int d) {
    if (d > 20) return;
    for (UIView *s in v.subviews) {
        if (W12IsPCButton(s)) { if (!s.hidden && s.bounds.size.width > 20) [out addObject:s]; }
        else W12PCCollect(s, out, d + 1);
    }
}
static void W12PCStrip(UIView *v) {
    CALayer *L = v.layer;
    for (NSString *k in [L.animationKeys copy]) if (![k isEqualToString:kPCPos] && ![k isEqualToString:kPCScale]) [L removeAnimationForKey:k];
}
static void W12PCFire(UIView *box) {
    if (!W12Bool(@"enabled", YES) || !W12Bool(@"passAnim", YES) || UIAccessibilityIsReduceMotionEnabled()) { W12_LOG(@"passcode wave: off (pref/reduce motion)"); return; }
    UIWindow *win = box.window; if (!win) { W12_LOG(@"passcode wave: container has no window"); return; }
    [box layoutIfNeeded];                                   // final key positions before reading them
    NSMutableArray<UIView *> *keys = [NSMutableArray array];
    W12PCCollect(win, keys, 0);
    if (keys.count < 3) { W12_LOG(@"passcode wave: only %lu keys", (unsigned long)keys.count); return; }
    // grid: 3 columns x 4 rows from the key centres
    CGFloat minX = CGFLOAT_MAX, maxX = -CGFLOAT_MAX, minY = CGFLOAT_MAX, maxY = -CGFLOAT_MAX;
    NSMutableArray<NSValue *> *pts = [NSMutableArray array];
    for (UIView *v in keys) {
        CGPoint p = [v.superview convertPoint:v.center toView:win]; [pts addObject:[NSValue valueWithCGPoint:p]];
        minX = MIN(minX, p.x); maxX = MAX(maxX, p.x); minY = MIN(minY, p.y); maxY = MAX(maxY, p.y);
    }
    for (UIView *v in keys) [v.layer removeAllAnimations];
    CFTimeInterval now = [keys[0].layer convertTime:CACurrentMediaTime() fromLayer:nil];
    for (NSUInteger i = 0; i < keys.count; i++) {
        UIView *v = keys[i]; CALayer *L = v.layer; CGPoint p = pts[i].CGPointValue;
        NSInteger col = maxX > minX ? (NSInteger)lround((p.x - minX) / (maxX - minX) * 2.0) : 1;
        NSInteger row = maxY > minY ? (NSInteger)lround((p.y - minY) / (maxY - minY) * 3.0) : 0;
        NSInteger w = kPCWave[row][col]; if (w < 1) continue;
        L.zPosition = 100.0 - w * 10.0;
        CGPoint pos = L.position; CATransform3D tr = L.transform;
        CGRect wr = [win convertRect:win.bounds toView:v.superview];
        CGPoint c = CGPointMake(CGRectGetMidX(wr), CGRectGetMidY(wr));
        CGPoint from = CGPointMake(c.x + (pos.x - c.x) * 0.15, c.y + (pos.y - c.y) * 0.15);
        BOOL zero = (col == 1 && row == 3);
        double stiff = zero ? 150.0 : 200.0, damp = zero ? 12.0 : 15.0;
        CFTimeInterval begin = now + kPCDelay[w];
        CASpringAnimation *sp = [CASpringAnimation animationWithKeyPath:@"position"];
        sp.fromValue = [NSValue valueWithCGPoint:from]; sp.toValue = [NSValue valueWithCGPoint:pos];
        sp.damping = damp; sp.stiffness = stiff; sp.mass = 1.0; sp.duration = sp.settlingDuration;
        sp.beginTime = begin; sp.fillMode = kCAFillModeBackwards; sp.removedOnCompletion = YES;
        [L addAnimation:sp forKey:kPCPos];
        CASpringAnimation *sc = [CASpringAnimation animationWithKeyPath:@"transform"];
        sc.fromValue = [NSValue valueWithCATransform3D:CATransform3DScale(tr, 0.15, 0.15, 1.0)];
        sc.toValue = [NSValue valueWithCATransform3D:tr];
        sc.damping = damp; sc.stiffness = stiff; sc.mass = 1.0; sc.duration = sp.duration;
        sc.beginTime = begin; sc.fillMode = kCAFillModeBackwards; sc.removedOnCompletion = YES;
        [L addAnimation:sc forKey:kPCScale];
    }
    // strip native animations right away and again for ~1.5 s (90 ticks)
    for (UIView *v in keys) W12PCStrip(v);
    __block int ticks = 0;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC), 16 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{
        if (++ticks >= 90) { dispatch_source_cancel(t); return; }
        for (UIView *v in keys) if (v.window) W12PCStrip(v);
    });
    dispatch_resume(t);
    W12_LOG(@"passcode wave: %lu keys fired, pref on, first key anims=%@", (unsigned long)keys.count, [keys[0].layer animationKeys]);
    __weak UIView *k0 = keys[0], *k4 = keys.count > 4 ? keys[4] : keys[0];
    for (NSNumber *dl in @[@0.03, @0.12, @0.3]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dl.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *a = k0, *b = k4; if (!a) return;
        CALayer *pa = a.layer.presentationLayer, *pb = b.layer.presentationLayer;
        W12_LOG(@"passcode wave +%.2fs: key0 model %.0f,%.0f pres %.0f,%.0f anims=%@ | key4 model %.0f,%.0f pres %.0f,%.0f", dl.doubleValue,
                a.layer.position.x, a.layer.position.y, pa.position.x, pa.position.y, [a.layer animationKeys],
                b.layer.position.x, b.layer.position.y, pb.position.x, pb.position.y);
    });
}
@interface W12PCTramp : NSObject
- (void)tick:(CADisplayLink *)l;
@end
static CFTimeInterval gPCStart; static int gPCTicks;
@implementation W12PCTramp
- (void)tick:(CADisplayLink *)l {
    UIView *box = gPCContainer;
    if (!gPCLink) return;
    if (!box || !box.window) { W12_LOG(@"passcode wave: container gone, stop"); [gPCLink invalidate]; gPCLink = nil; gPCContainer = nil; return; }
    CFTimeInterval age = CACurrentMediaTime() - gPCStart;
    CGFloat eff = 1; for (UIView *a = box; a; a = a.superview) { eff *= a.alpha; if (a.hidden) eff = 0; }
    if ((gPCTicks++ % 20) == 0) W12_LOG(@"passcode wave: waiting alpha=%.2f effective=%.2f age=%.2f", box.alpha, eff, age);
    BOOL ready = box.alpha >= 0.95 && !box.hidden;
    if (!ready && age > 1.5 && eff > 0.5) ready = YES;     // safety net: never stay silent
    if (!ready) return;
    [gPCLink invalidate]; gPCLink = nil; gPCContainer = nil;
    W12PCFire(box);
}
@end
static void W12PCButtonMoved(UIView *btn) {
    if (btn.window) {
        UIView *a = btn.superview, *found = nil;
        while (a) { if ([NSStringFromClass([a class]) isEqualToString:@"SBUIPasscodeLockViewSimpleFixedDigitKeypad"]) { found = a; break; } a = a.superview; }
        if (!found) { a = btn.superview; while (a) { if ([NSStringFromClass([a class]) containsString:@"Keypad"]) { found = a; break; } a = a.superview; } }
        if (!found) found = btn.superview;
        gPCContainer = found;
        W12_LOG(@"passcode keys: button %@ container %@", NSStringFromClass([btn class]), NSStringFromClass([found class]));
        if (!gPCLink) {
            gPCStart = CACurrentMediaTime(); gPCTicks = 0;
            static W12PCTramp *tramp; if (!tramp) tramp = [W12PCTramp new];
            gPCLink = [CADisplayLink displayLinkWithTarget:tramp selector:@selector(tick:)];
            [gPCLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        }
    } else if (gPCContainer && !gPCContainer.window) {          // only when the keypad itself is gone (other keys can leave while it stays)
        [gPCLink invalidate]; gPCLink = nil; gPCContainer = nil;
    }
}

static void W12HookNumPads(void) {
    // Only fixed class names, looked up with objc_getClass (nothing is enumerated or messaged): safe at any time.
    static NSMutableSet *done;
    if (!done) done = [NSMutableSet set];
    for (NSString *cn in @[@"TPNumberPadButton", @"TPNumberPadLightStyleButton", @"TPNumberPadDarkStyleButton",
                           @"SBUIPasscodeNumberPadButton", @"SBPasscodeNumberPadButton", @"SBLightPasscodeNumberPadButton", @"SBUIPasscodeButton"]) {
        if ([done containsObject:cn]) continue;
        Class c = objc_getClass(cn.UTF8String);
        if (!c) continue;
        [done addObject:cn];
        for (NSString *sn in @[@"layoutSubviews", @"didMoveToWindow"]) {
            SEL sel = NSSelectorFromString(sn);
            Method m = class_getInstanceMethod(c, sel);
            if (!m) continue;
            IMP orig = method_getImplementation(m);
            IMP imp = imp_implementationWithBlock(^(UIView *self) {
                ((void (*)(id, SEL))orig)(self, sel);
                W12GlassRimOn(self);
                if (sel == @selector(didMoveToWindow) && W12IsPCButton(self) + 0) W12PCButtonMoved(self);
            });
            class_replaceMethod(c, sel, imp, method_getTypeEncoding(m));
            W12_LOG(@"hooked passcode key %@ %@", cn, sn);
        }
    }
}

static void W12InstallStatusBarHooks(void) {
    if (!NSClassFromString(@"UIStatusBarForegroundView")) return;
    W12Hook(@"UIStatusBarForegroundView", @selector(layoutSubviews), (IMP)n_sbLayout, &o_sbLayout, 2, NULL);
    // The layout manager also moves items without a layout pass; re-apply right after each data update.
    for (NSString *sn in @[@"setStatusBarData:actions:", @"_setStatusBarData:actions:"]) {
        W12HookGeneric(@"UIStatusBarForegroundView", NSSelectorFromString(sn), ^(id self, uintptr_t a0) {
            __weak id w = self;
            dispatch_async(dispatch_get_main_queue(), ^{ W12AdjustStatusBar(w); });
        });
    }
}

extern void W12LockStyleInit(void);
extern void W12TabBarInit(void);

// Crash / hang guard (SpringBoard): a marker file lives for the first 25 s of every SpringBoard run. If it is still there at the next start, the previous run
// died or hung early (watchdog reboot, crash loop): the newest risky features (alert / switch skins) are switched off so the phone can boot, and the log says so.
static void W12BootGuard(void) {
    NSString *mk = @"/var/mobile/Library/Caches/com.wave12.boot";
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:mk]) {
        CFPreferencesSetAppValue(CFSTR("alertGlass"), kCFBooleanFalse, W12_DOMAIN);
        CFPreferencesAppSynchronize(W12_DOMAIN);
        W12_LOG(@"BOOT GUARD: previous SpringBoard run ended within 25 s -> alertGlass switched off (re-enable in Settings > 2712)");
    }
    [@"1" writeToFile:mk atomically:YES encoding:NSUTF8StringEncoding error:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [[NSFileManager defaultManager] removeItemAtPath:mk error:nil]; });
}



// MARK: - Clock app side: the stopwatch / timer live in the Clock app itself, so a tiny scanner inside that process reads what its labels show
// and hands the result to SpringBoard through a Darwin notification state (kind << 44 | running << 43 | milliseconds in the low 41 bits).
#define W12_CLK_NOTE "com.wave12.clockstate"
static int gClkToken = 0;
static void W12ClkPublish(int kind, BOOL running, double msValue) {
    if (!gClkToken) notify_register_check(W12_CLK_NOTE, &gClkToken);
    uint64_t v = ((uint64_t)kind << 44) | ((uint64_t)(running ? 1 : 0) << 43) | ((uint64_t)MAX(0.0, msValue) & ((1ULL << 41) - 1));
    notify_set_state(gClkToken, v);
    notify_post(W12_CLK_NOTE);
}
static void W12ClkLabels(UIView *v, NSMutableArray *out, int d) {
    if (v.hidden || v.alpha < 0.05 || d > 12) return;
    if ([v isKindOfClass:[UILabel class]] && ((UILabel *)v).text.length && v.window) [out addObject:v];
    for (UIView *s in v.subviews) W12ClkLabels(s, out, d + 1);
}
// seconds in "H:MM:SS", "MM:SS" or "MM:SS,cc"; hasFrac says whether the label has hundredths
static double W12ParseClock(NSString *t, BOOL *hasFrac) {
    static NSRegularExpression *re;
    if (!re) re = [NSRegularExpression regularExpressionWithPattern:@"^\\s*(?:(\\d+):)?(\\d{1,2}):(\\d{2})(?:[.,](\\d{1,2}))?\\s*$" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
    if (!m) return -1;
    double h = [m rangeAtIndex:1].location != NSNotFound ? [[t substringWithRange:[m rangeAtIndex:1]] doubleValue] : 0;
    double mi = [[t substringWithRange:[m rangeAtIndex:2]] doubleValue], se = [[t substringWithRange:[m rangeAtIndex:3]] doubleValue];
    double fr = 0; BOOL has = [m rangeAtIndex:4].location != NSNotFound;
    if (has) { NSString *f = [t substringWithRange:[m rangeAtIndex:4]]; fr = [f doubleValue] / (f.length == 1 ? 10.0 : 100.0); }
    if (hasFrac) *hasFrac = has;
    return h * 3600 + mi * 60 + se + fr;
}
static void W12ClockScanStart(void) {
    static double swLast = -1, swLastChange = 0, tmLast = -1, tmLastChange = 0; static int sent = -1;
    NSTimer *t = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *tt) {
        @try {
            if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
            NSMutableArray *labels = [NSMutableArray array];
            for (UIWindow *w in [UIApplication sharedApplication].windows) W12ClkLabels(w, labels, 0);
            UILabel *bigSw = nil, *bigTm = nil;
            for (UILabel *l in labels) {
                BOOL frac = NO; double sec = W12ParseClock(l.text, &frac);
                if (sec < 0) continue;
                if (frac) { if (!bigSw || l.font.pointSize > bigSw.font.pointSize) bigSw = l; }
                else      { if (!bigTm || l.font.pointSize > bigTm.font.pointSize) bigTm = l; }
            }
            double now = CACurrentMediaTime(), epochMs = [[NSDate date] timeIntervalSince1970] * 1000.0;
            if (bigSw) {                                           // stopwatch page
                BOOL f; double e = W12ParseClock(bigSw.text, &f);
                if (e != swLast) { if (swLast >= 0 && e > swLast) swLastChange = now; swLast = e; if (e < 0.05) swLastChange = 0; }
                BOOL running = (now - swLastChange) < 0.9 && swLastChange > 0 && e > 0.05;
                if (running) { if (sent != 2) W12_LOG(@"clock: stopwatch running (%@)", bigSw.text); W12ClkPublish(1, YES, epochMs - e * 1000.0); sent = 2; }
                else if (sent == 2) { W12ClkPublish(1, NO, e * 1000.0); sent = 0; if (e < 0.05) W12ClkPublish(0, NO, 0); }
            }
            if (bigTm && !bigSw) {                                 // timer page: the countdown only ever goes down
                BOOL f; double v = W12ParseClock(bigTm.text, &f);
                if (tmLast >= 0 && v < tmLast && tmLast - v < 3.5) { tmLastChange = now; }
                tmLast = v;
                BOOL running = (now - tmLastChange) < 1.8 && tmLastChange > 0 && v > 0.5;
                if (running) { if (sent != 3) W12_LOG(@"clock: timer running (%@)", bigTm.text); W12ClkPublish(2, YES, epochMs + v * 1000.0); sent = 3; }
                else if (sent == 3) { W12ClkPublish(2, NO, v * 1000.0); sent = 0; }
            }
        } @catch (NSException *e) { }
    }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    W12_LOG(@"clock scanner started");
}

#ifdef W12_M_WALL
#include "Wall.inc"
#endif

__attribute__((constructor)) static void W12Init(void) {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
#ifdef W12_M_DYNA
            W12InstallStatusBarHooks();            // regular apps: only the status bar layout is touched
            if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.mobiletimer"])
                dispatch_async(dispatch_get_main_queue(), ^{ W12ClockScanStart(); });
#endif
#ifdef W12_M_TAB
            W12TabBarInit();
#endif
#ifdef W12_M_BOX
            W12HookAlerts();
#endif
            return;
        }
#ifdef W12_M_BOX
        W12BootGuard();
        W12HookAlerts();
#endif
#ifdef W12_M_DYNA
        W12InstallStatusBarHooks();
        W12Hook(@"SBHUDWindow", @selector(setHidden:), (IMP)n_hudHidden, &o_hudHidden, 3, "B");
#endif
#ifdef W12_M_CC
        W12Hook(@"MTMaterialView", @selector(layoutSubviews), (IMP)n_mtLayout, &o_mtLayout, 2, NULL);   // Control Center glass rim
        W12Hook(@"MTMaterialView", @selector(didMoveToWindow), (IMP)n_mtWin, &o_mtWin, 2, NULL);
        W12Hook(@"CCUIContentModuleContainerView", @selector(layoutSubviews), (IMP)n_ccLayout, &o_ccLayout, 2, NULL);
#endif
#ifdef W12_M_CODE
        W12HookNumPads();
        for (NSNumber *dly in @[@6, @20]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dly.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ W12HookNumPads(); });   // frameworks may load later
#endif
#if defined(W12_M_WAVE) || defined(W12_M_DYNA)
        // Main trigger: cover sheet (lock screen) is dismissed with animation.
        W12Hook(@"SBCoverSheetPresentationManager", @selector(setCoverSheetPresented:animated:withCompletion:),
                (IMP)n_setPresented, &o_setPresented, 5, "BB@");
        // Fallback trigger: unlock requested (touch id / passcode).
        W12Hook(@"SBLockScreenManager", @selector(unlockUIFromSource:withOptions:),
                (IMP)n_unlockUI, &o_unlockUI, 4, "i@");
#endif
#if defined(W12_M_WAVE) || defined(W12_M_MORPH)
        // App -> Home.
        W12Hook(@"SBUIController", @selector(restoreContentAndUnscatterIconsAnimated:),
                (IMP)n_restore1, &o_restore1, 3, "B");
        W12Hook(@"SBUIController", @selector(restoreContentAndUnscatterIconsAnimated:withCompletion:),
                (IMP)n_restore2, &o_restore2, 4, "B@");
#endif
#ifdef W12_M_WAVE
        // Silence the system's own icon fly-in where it exists (our animation replaces it).
        for (NSString *cn in @[@"SBIconController", @"SBRootFolderController", @"SBRootFolderView"]) {
            if (W12Hook(cn, NSSelectorFromString(@"iconsFlyIn"), (IMP)n_flyIn, &o_flyIn, 2, NULL)) break;
        }
#endif
#ifdef W12_M_MORPH

        // App open: remember which icon was tapped, then wait for the app scene to appear.
        W12HookGeneric(@"SBIconController", NSSelectorFromString(@"iconTapped:"), ^(id self, uintptr_t a0) {
            UIView *iv = (__bridge UIView *)(void *)a0;
            if ([iv isKindOfClass:[UIView class]] && iv.window && !W12FrontApp()) {
                CGRect r = [iv convertRect:iv.bounds toView:iv.window];
                CGFloat side = MIN(r.size.width, r.size.height);
                gLaunchRect = CGRectMake(CGRectGetMidX(r) - side / 2, r.origin.y, side, side);
                gHasLaunchRect = YES; gLaunchRectTime = CACurrentMediaTime();
                W12AppOpenStart();
            }
        });
        // Other ways to open an app (notification, Spotlight, URL, ...).
        for (NSString *sn in @[@"activateApplication:",
                               @"activateApplication:fromIcon:location:",
                               @"activateApplication:fromIcon:location:activationSettings:actions:"]) {
            W12HookGeneric(@"SBUIController", NSSelectorFromString(sn), ^(id self, uintptr_t a0) {
                id obj = (__bridge id)(void *)a0;
                if ([obj respondsToSelector:@selector(bundleIdentifier)]) {
                    id b = [obj performSelector:@selector(bundleIdentifier)];
                    if ([b isKindOfClass:[NSString class]]) { gPendingBundle = [b copy]; gPendingBundleTime = CACurrentMediaTime(); }
                }
                if (!W12FrontApp()) W12AppOpenStart();
            });
        }

        // More ways to detect "leave the app" (home button / switcher), only when an app is frontmost.
        NSArray *closeHooks = @[
            @[@"SBUIController", @"clickedMenuButton"],
            @[@"SBUIController", @"handleMenuButtonTap"],
            @[@"SBUIController", @"_handleHomeButtonSinglePress"],
            @[@"SBHomeHardwareButtonActions", @"performSinglePressUpActions"],
            @[@"SBHomeHardwareButtonActions", @"performSinglePressDownActions"],
            @[@"SBMainSwitcherViewController", @"_dismissSwitcherNoninteractivelyToAppWithBundleIdentifier:"],
            @[@"SBDeckSwitcherViewController", @"_dismissSwitcherNoninteractively"],
        ];
        for (NSArray *h in closeHooks) {
            W12HookGeneric(h[0], NSSelectorFromString(h[1]), ^(id self, uintptr_t a0) {
                W12_LOG(@"close trigger: %@", h[1]);
                if (W12FrontApp()) { W12AppClose(); }
            });
        }
        {   // Gesture tweaks (HomeGesture & co.) leave the app through methods we cannot know in advance: scan the likely classes at
            // runtime, log everything that looks related (for diagnosis) and hook the void "go home / return home" style ones.
            NSMutableSet *seen = [NSMutableSet set];
            unsigned nc = 0; Class *all = objc_copyClassList(&nc);
            NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"^_?(return|go|activate|dismiss|exit|leave|handle|perform)[A-Za-z]*(Home|ToHome)[A-Za-z:]*$" options:0 error:nil];
            for (unsigned i = 0; i < nc; i++) {
                NSString *cn = NSStringFromClass(all[i]);
                if (!([cn hasPrefix:@"SBFluid"] || [cn hasPrefix:@"SBHomeGesture"] || [cn hasPrefix:@"SBMainSwitcher"] || [cn hasPrefix:@"SBMainWorkspace"] ||
                      [cn hasPrefix:@"SBDeckSwitcher"] || [cn hasPrefix:@"SBUIController"] || [cn hasPrefix:@"SBGestureHome"] || [cn hasPrefix:@"SBHomeHardware"] ||
                      [cn hasPrefix:@"HG"] || [cn hasPrefix:@"HomeGesture"])) continue;
                unsigned nm = 0; Method *ml = class_copyMethodList(all[i], &nm);
                for (unsigned k = 0; k < nm; k++) {
                    NSString *mn = NSStringFromSelector(method_getName(ml[k]));
                    if ([mn rangeOfString:@"Home" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
                    W12_LOG(@"candidate: -[%@ %@]", cn, mn);
                    if ([rx numberOfMatchesInString:mn options:0 range:NSMakeRange(0, mn.length)] == 0) continue;
                    if ([mn containsString:@"ToApp"] || [mn containsString:@"Animated:"] == NO) { if ([mn containsString:@"ToApp"]) continue; }
                    NSString *key = [cn stringByAppendingString:mn]; if ([seen containsObject:key]) continue; [seen addObject:key];
                    char *rt = method_copyReturnType(ml[k]); BOOL isVoid = rt && rt[0] == 'v'; free(rt);
                    if (!isVoid) continue;
                    NSString *label = [NSString stringWithFormat:@"%@ %@", cn, mn];
                    W12HookGeneric(cn, method_getName(ml[k]), ^(id self, uintptr_t a0) {
                        W12_LOG(@"close trigger (auto): %@", label);
                        if (W12FrontApp()) { W12AppClose(); }
                    });
                }
                free(ml);
            }
            free(all);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ gCloseWatch = [W12CloseWatch new]; [gCloseWatch start]; });
#endif
#ifdef W12_M_DYNA
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            gIsland = [W12Island new]; [gIsland start];
            static int testTokens[8]; int kinds[8] = {7, 8, 9, 10, 11, 12, 13, 14};
            for (int i = 0; i < 8; i++) {
                int kk = kinds[i]; char nm[40]; snprintf(nm, sizeof nm, "com.wave12.test.%d", kk);
                notify_register_dispatch(nm, &testTokens[i], dispatch_get_main_queue(), ^(int t) { [gIsland testKind:kk]; });
            }
        });
#endif
#ifdef W12_M_HOME
        W12Home26Start();
#endif
#ifdef W12_M_WALL
        W12WallStart();
#endif
        {   // "Respring" button of the settings page
            static int respringToken;
            notify_register_dispatch("com.wave12.respring", &respringToken, dispatch_get_main_queue(), ^(int t) {
                W12_LOG(@"respring requested from settings");
                UIApplication *app = [UIApplication sharedApplication];
                SEL rel = NSSelectorFromString(@"_relaunchSpringBoardNow");
                if ([app respondsToSelector:rel]) [app performSelector:rel];
                else exit(0);
            });
        }
#if defined(W12_M_WAVE) || defined(W12_M_MORPH) || defined(W12_M_TAB)
        {   // installed-app list for the exclusion page (the Settings app cannot always enumerate apps itself)
            void (^dump)(void) = ^{
                @try {
                    id ic = W12Call(NSClassFromString(@"SBIconController"), @selector(sharedInstance));
                    id model = W12Call(ic, @selector(model));
                    NSSet *leaf = W12Call(model, NSSelectorFromString(@"leafIcons"));
                    NSMutableDictionary *seen = [NSMutableDictionary dictionary];
                    for (id icon in leaf) {
                        id b = W12Call(icon, NSSelectorFromString(@"applicationBundleID"));
                        id n = W12Call(icon, NSSelectorFromString(@"displayName"));
                        if ([b isKindOfClass:[NSString class]] && [n isKindOfClass:[NSString class]] && ((NSString *)b).length) seen[b] = n;
                    }
                    NSMutableArray *out = [NSMutableArray array];
                    for (NSString *k in seen) [out addObject:@{@"bid": k, @"name": seen[k]}];
                    if (out.count) {
                        [out writeToFile:@"/var/mobile/Library/Preferences/com.wave12.apps.plist" atomically:YES];
                        W12_LOG(@"app list written: %lu apps", (unsigned long)out.count);
                    } else W12_LOG(@"app list: no icons found");
                } @catch (NSException *e) { W12_LOG(@"app list failed: %@", e.reason); }
            };
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), dump);
            static int refreshToken;
            notify_register_dispatch("com.wave12.refreshapps", &refreshToken, dispatch_get_main_queue(), ^(int t) { dump(); });
        }
#endif
        W12_LOG(@"init done (%s) on iOS %@", W12_MODNAME, [UIDevice currentDevice].systemVersion);
#if defined(W12_M_WAVE) || defined(W12_M_DYNA)

        // Last-resort fallback: lock state notification (0 = unlocked).
        static int token; static uint64_t lastState = 1;
        notify_register_dispatch("com.apple.springboard.lockstate", &token, dispatch_get_main_queue(), ^(int t) {
            uint64_t s = 0; notify_get_state(t, &s);
#ifdef W12_M_DYNA
            if (s != 0 && !gFidBusy) gFidShown = NO;                   // locked again: the next unlock gets its Face ID effect
#endif
            if (lastState != 0 && s == 0) {
#ifdef W12_M_WAVE
                static double (*fidWait)(void); static dispatch_once_t wo;
                dispatch_once(&wo, ^{ fidWait = (double (*)(void))dlsym(RTLD_DEFAULT, "W12XFidWait"); });      // dynaFake (if installed) may still be playing its effect
                double w = fidWait ? fidWait() : 0;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((w + 0.02) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ W12Run(W12SourceUnlock); });
#endif
#ifdef W12_M_DYNA
                // Safety net: the unlock went through without any of our hooks seeing it -> play the effect now, over the home screen.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (!gFidBusy && !gFidShown && !W12UILocked()) { W12_LOG(@"faceid: safety-net play (unlock seen only by lock state)"); W12FacePlay(NO); } });
#endif
            }
            lastState = s;
        });
#endif
        W12_LOG(@"loaded (%s)", W12_MODNAME);
    }
}
