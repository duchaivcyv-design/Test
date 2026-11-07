// ===================== 26Wall: iOS 16 style depth effect for the lock screen (subject in front of the clock) =====================
// Flow: lock wallpaper (LockBackground.cpbitmap) -> PNG -> /usr/libexec/26wallseg (U^2-Net-P, runs in its own process) -> cut-out PNG
//       -> an image view placed right above the clock inside the cover sheet, kept glued to the live wallpaper view.
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <ImageIO/ImageIO.h>
extern char **environ;

#define W12WALL_DIR @"/var/mobile/Library/26Wall"
#define W12WALL_MODEL @"/Library/Application Support/26Wall/u2netp_256.u2p"
#define W12WALL_HELPER "/usr/libexec/26wallseg"
#define W12WALL_LOCKBG @"/var/mobile/Library/SpringBoard/LockBackground.cpbitmap"

static UIImageView *gWallView;            // the cut-out
static UIImage *gWallCut;
static NSString *gWallCutStamp;           // wallpaper stamp the cut-out belongs to
static BOOL gWallBusy;
static __weak UIView *gWallDate;          // SBFLockScreenDateView
static CADisplayLink *gWallLink;
static __weak UIView *gWallLive;          // live lock wallpaper image view (geometry source)
static CFTimeInterval gWallLastLog;
static __weak UIView *gWallAbove;         // the view the cut-out sits right above: its opacity drives ours

static NSString *W12WallFileStamp(void);
static NSString *W12WallStamp(void) {
    return W12WallFileStamp() ? [W12WallFileStamp() stringByAppendingFormat:@"-%@", [NSString stringWithFormat:@"%@4%@", W12Bool(@"wallClockFirst", YES) ? @"clock" : @"whole", W12Bool(@"wallSkipAbstract", NO) ? @"s" : @""]] : nil;
}
static NSString *W12WallFileStamp(void) {
    struct stat st; if (stat([W12WALL_LOCKBG fileSystemRepresentation], &st) != 0) return nil;
    return [NSString stringWithFormat:@"%ld-%lld", (long)st.st_mtime, (long long)st.st_size];
}
static NSString *W12WallMetaPath(void) { return [W12WALL_DIR stringByAppendingPathComponent:@"meta.plist"]; }
static NSDictionary *W12WallMeta(void) { return [NSDictionary dictionaryWithContentsOfFile:W12WallMetaPath()]; }

static CGImageRef W12WallSourceImage(void) {
    NSData *d = [NSData dataWithContentsOfFile:W12WALL_LOCKBG];
    if (d.length) {
        static void *h; static dispatch_once_t o;
        dispatch_once(&o, ^{ h = dlopen("/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport", RTLD_LAZY); });
        CFArrayRef (*fn)(CFDataRef, void *, int, void *) = h ? (CFArrayRef (*)(CFDataRef, void *, int, void *))dlsym(h, "CPBitmapCreateImagesFromData") : NULL;
        if (fn) {
            CFArrayRef arr = fn((__bridge CFDataRef)d, NULL, 1, NULL);
            if (arr && CFArrayGetCount(arr) > 0) { CGImageRef im = (CGImageRef)CFArrayGetValueAtIndex(arr, 0); CGImageRetain(im); CFRelease(arr); return im; }
            if (arr) CFRelease(arr);
        }
        W12_LOG(@"wall: CPBitmapCreateImagesFromData unavailable/failed");
    }
    return NULL;
}
static BOOL W12WallWritePNG(CGImageRef im, NSString *path) {
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    if (!dst) return NO;
    CGImageDestinationAddImage(dst, im, NULL);
    BOOL ok = CGImageDestinationFinalize(dst); CFRelease(dst); return ok;
}

// ---- live wallpaper view (for geometry) ----
static UIView *W12WallFindLive(void) {
    UIView *v = gWallLive; if (v && v.window) return v;
    UIView *best = nil; CGFloat bestA = 0;
    CGSize sz = [UIScreen mainScreen].bounds.size;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        NSString *wn = NSStringFromClass([w class]);
        if (![wn containsString:@"Wallpaper"]) continue;
        NSMutableArray *q = [NSMutableArray arrayWithObject:w];
        while (q.count) {
            UIView *c = q.firstObject; [q removeObjectAtIndex:0];
            [q addObjectsFromArray:c.subviews];
            if (![c isKindOfClass:[UIImageView class]] && c.layer.contents == nil) continue;
            CGRect r = [c convertRect:c.bounds toView:nil]; CGFloat a = r.size.width * r.size.height;
            if (a >= sz.width * sz.height * 0.9 && a > bestA && !c.hidden) { bestA = a; best = c; }
        }
    }
    gWallLive = best;
    if (best) W12_LOG(@"wall: live wallpaper view %@ frame=%@", NSStringFromClass([best class]), NSStringFromCGRect([best convertRect:best.bounds toView:nil]));
    return best;
}

// ---- generation ----
static void W12WallApplyImage(void);
static void W12WallGenerate(BOOL force) {
    if (!W12Bool(@"wallOn", YES) || gWallBusy) return;
    NSString *stamp = W12WallFileStamp();
    if (!stamp) { W12_LOG(@"wall: no lock wallpaper file"); return; }
    NSDictionary *meta = W12WallMeta();
    BOOL clockFirst = W12Bool(@"wallClockFirst", YES);
    NSString *mode = [NSString stringWithFormat:@"%@4%@", clockFirst ? @"clock" : @"whole", W12Bool(@"wallSkipAbstract", NO) ? @"s" : @""];
    stamp = [stamp stringByAppendingFormat:@"-%@", mode];
    if (gWallCutStamp && ![gWallCutStamp isEqual:stamp]) gWallCut = nil;
    NSString *cutPath = [W12WALL_DIR stringByAppendingPathComponent:@"cutout.png"];
    if (!force && [meta[@"stamp"] isEqual:stamp]) {
        if ([meta[@"status"] isEqual:@"ok"] && !gWallCut && [[NSFileManager defaultManager] fileExistsAtPath:cutPath]) {
            gWallCut = [UIImage imageWithContentsOfFile:cutPath]; gWallCutStamp = stamp; W12_LOG(@"wall: loaded cached cut-out"); W12WallApplyImage();
        }
        return;
    }
    if (!force && !W12Bool(@"wallAuto", YES)) return;
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:@W12WALL_HELPER] || ![[NSFileManager defaultManager] fileExistsAtPath:W12WALL_MODEL]) { W12_LOG(@"wall: helper or model missing"); return; }
    gWallBusy = YES;
    [[NSFileManager defaultManager] createDirectoryAtPath:W12WALL_DIR withIntermediateDirectories:YES attributes:nil error:nil];
    CGImageRef src = W12WallSourceImage();
    if (!src) { gWallBusy = NO; W12_LOG(@"wall: cannot decode the lock wallpaper"); return; }
    NSString *srcPath = [W12WALL_DIR stringByAppendingPathComponent:@"src.png"];
    BOOL wrote = W12WallWritePNG(src, srcPath); CGImageRelease(src);
    if (!wrote) { gWallBusy = NO; W12_LOG(@"wall: cannot write source png"); return; }
    W12_LOG(@"wall: segmenting (stamp %@, force=%d)", stamp, force);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CFTimeInterval t0 = CACurrentMediaTime();
        [[NSFileManager defaultManager] removeItemAtPath:cutPath error:nil];
        pid_t pid = 0; const char *args[] = { W12WALL_HELPER, srcPath.fileSystemRepresentation, W12WALL_MODEL.fileSystemRepresentation, cutPath.fileSystemRepresentation, clockFirst ? "1" : "0", W12Bool(@"wallSkipAbstract", NO) ? "1" : "0", NULL };
        int rc = posix_spawn(&pid, W12WALL_HELPER, NULL, NULL, (char *const *)args, environ);
        int status = -1;
        if (rc == 0) { waitpid(pid, &status, 0); } else status = -2;
        NSString *res = @"fail";
        if (rc == 0 && WIFEXITED(status)) { int e = WEXITSTATUS(status); res = e == 0 ? @"ok" : (e == 3 ? @"none" : @"fail"); W12_LOG(@"wall: helper exit %d in %.1fs", e, CACurrentMediaTime() - t0); }
        else if (rc == 0 && WIFSIGNALED(status)) W12_LOG(@"wall: helper killed by signal %d (probably out of memory)", WTERMSIG(status));
        else W12_LOG(@"wall: spawn failed rc=%d", rc);
        dispatch_async(dispatch_get_main_queue(), ^{
            gWallBusy = NO;
            [@{@"stamp": stamp, @"status": res} writeToFile:W12WallMetaPath() atomically:YES];
            if ([res isEqual:@"ok"]) { gWallCut = [UIImage imageWithContentsOfFile:cutPath]; gWallCutStamp = stamp; }
            else { gWallCut = nil; gWallCutStamp = nil; }
            W12_LOG(@"wall: result %@", res);
            W12WallApplyImage();
        });
    });
}

// ---- display ----
static UIView *W12WallHostAbove(UIView *date, UIView **aboveOut) {
    // host = the nearest full-screen container above the clock; the cut-out goes right above the branch that holds the clock
    CGSize sz = [UIScreen mainScreen].bounds.size;
    for (UIView *a = date; a.superview; a = a.superview) {
        UIView *p = a.superview; CGSize b = p.bounds.size;
        if (![p isKindOfClass:[UIWindow class]] && b.width >= sz.width * 0.9 && b.height >= sz.height * 0.9) { *aboveOut = a; return p; }
    }
    UIView *a = date;
    while (a.superview && a.superview.subviews.count == 1 && ![a.superview isKindOfClass:[UIWindow class]]) a = a.superview;
    *aboveOut = a; return a.superview;
}
static void W12WallTick(void);
static void W12WallStartLink(void);
static BOOL W12WallLooksLikeTime(NSString *t) {
    static NSRegularExpression *re; static dispatch_once_t o;
    dispatch_once(&o, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"^\\s*\\d{1,2}[:.]\\d{2}(\\s*[AaPpSsCc][MmAaHh])?\\s*$" options:0 error:nil]; });
    return t.length && t.length < 12 && [re numberOfMatchesInString:t options:0 range:NSMakeRange(0, t.length)] > 0;
}
// The lock screen clock can be drawn by another tweak (different views): find it by its text instead of by class.
static UIView *W12WallClockAnchor(void) {
    UIView *d = gWallDate;
    if (d.window) return d;
    UIView *best = nil; CGFloat bestA = 0; int visited = 0;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        NSString *wn = NSStringFromClass([w class]);
        if (w.hidden || !([wn containsString:@"CoverSheet"] || [wn containsString:@"DashBoard"] || [wn containsString:@"LockScreen"])) continue;
        NSMutableArray *q = [NSMutableArray arrayWithObject:w];
        while (q.count && visited < 6000) {
            UIView *v = q.firstObject; [q removeObjectAtIndex:0]; visited++;
            [q addObjectsFromArray:v.subviews];
            if (v.hidden || v.alpha < 0.05 || v == gWallView) continue;
            NSString *t = nil;
            if ([v isKindOfClass:[UILabel class]]) t = ((UILabel *)v).text ?: ((UILabel *)v).attributedText.string;
            else if ([v respondsToSelector:@selector(string)]) { id r = ((id (*)(id, SEL))objc_msgSend)(v, @selector(string)); if ([r isKindOfClass:[NSString class]]) t = r; }
            if (!W12WallLooksLikeTime(t)) continue;
            CGFloat area = v.bounds.size.width * v.bounds.size.height;
            if (area > bestA) { bestA = area; best = v; }
        }
    }
    static CFTimeInterval lastLog;
    if (CACurrentMediaTime() - lastLog > 5) {
        lastLog = CACurrentMediaTime();
        W12_LOG(@"wall: clock anchor -> %@ (date view %@ window=%d)", best ? NSStringFromClass([best class]) : @"none", d ? NSStringFromClass([d class]) : @"nil", d.window != nil);
        if (!best) { static int dumped; if (dumped++ < 2) W12DumpAllWindows("wall: no clock found"); }
    }
    return best;
}
static void W12WallApplyImage(void) {
    UIView *date = W12WallClockAnchor();
    if (!W12Bool(@"wallOn", YES) || !gWallCut || !date.window || ![W12WallStamp() isEqual:gWallCutStamp]) { gWallView.hidden = YES; return; }
    UIView *above = nil; UIView *host = W12WallHostAbove(date, &above);
    if (!host) return;
    if (!gWallView) { gWallView = [[UIImageView alloc] init]; gWallView.userInteractionEnabled = NO; gWallView.contentMode = UIViewContentModeScaleToFill; }
    gWallView.image = gWallCut;
    if (gWallView.superview != host || [host.subviews indexOfObject:gWallView] != [host.subviews indexOfObject:above] + 1) {
        [gWallView removeFromSuperview];
        [host insertSubview:gWallView aboveSubview:above];
        if (CACurrentMediaTime() - gWallLastLog > 3) {
            NSMutableString *chain = [NSMutableString string]; for (UIView *p = date; p && chain.length < 400; p = p.superview) [chain appendFormat:@"%@(%lu) < ", NSStringFromClass([p class]), (unsigned long)p.subviews.count];
            W12_LOG(@"wall: date chain %@", chain); gWallLastLog = CACurrentMediaTime(); W12_LOG(@"wall: cut-out inserted in %@ above %@ (host subviews=%lu)", NSStringFromClass([host class]), NSStringFromClass([above class]), (unsigned long)host.subviews.count); }
    }
    gWallAbove = above;
    gWallView.hidden = NO;
    W12WallTick();
    W12WallStartLink();
}
static void W12WallTick(void) {
    UIImageView *cv = gWallView; if (!cv || cv.hidden || !cv.superview) return;
    UIView *live = W12WallFindLive(); UIView *host = cv.superview;
    // Fixed geometry: the wallpaper view's own position is moved by the parallax motion effect (that was the tremble), so only
    // its size is used and it is centred on the screen.
    CGSize sc = [UIScreen mainScreen].bounds.size, lb = live ? live.layer.bounds.size : CGSizeZero;
    CGRect inWin;
    if (lb.width > 100 && lb.height > 100 && lb.width < sc.width * 1.6 && lb.height < sc.height * 1.6) inWin = CGRectMake((sc.width - lb.width) / 2, (sc.height - lb.height) / 2, lb.width, lb.height);
    else { CGSize i = gWallCut.size; CGFloat k = MAX(sc.width / i.width, sc.height / i.height); inWin = CGRectMake((sc.width - i.width * k) / 2, (sc.height - i.height * k) / 2, i.width * k, i.height * k); }
    inWin = CGRectMake(round(inWin.origin.x * 2) / 2, round(inWin.origin.y * 2) / 2, round(inWin.size.width * 2) / 2, round(inWin.size.height * 2) / 2);
    CGRect r = [host convertRect:inWin fromView:nil];
    BOOL tr = !CGAffineTransformIsIdentity(cv.transform);
    if (tr) cv.transform = CGAffineTransformIdentity;
    if (tr || !CGRectEqualToRect(cv.frame, r)) cv.frame = r;
    // fade with the clock branch (passcode pad, sleep), but never move: the frame above is fixed to the wallpaper in window
    // coordinates, and any animated shift of the containers (slide, bounce, page swipe) is cancelled with a counter-offset.
    UIView *ab = gWallAbove; CGFloat al = 1;
    if (ab && ab.superview == host) { CALayer *pl = ab.layer.presentationLayer ?: ab.layer; al = ab.hidden ? 0 : pl.opacity; }
    UIView *dv = gWallDate;
    if (dv.window) { CGFloat a2 = dv.hidden ? 0 : dv.alpha; CALayer *dl = dv.layer.presentationLayer; if (dl) a2 = dv.hidden ? 0 : dl.opacity; al = MIN(al, a2); }
    cv.alpha = al < 0.02 ? 0 : al;
    CGFloat dx = 0, dy = 0; int n = 0;
    for (UIView *p = host; p && n < 12; p = p.superview, n++) {
        CALayer *l = p.layer, *q = l.presentationLayer; if (!q || !l.animationKeys.count) continue;
        dx += (q.position.x - l.position.x) - (q.bounds.origin.x - l.bounds.origin.x);
        dy += (q.position.y - l.position.y) - (q.bounds.origin.y - l.bounds.origin.y);
    }
    if (fabs(dx) < 0.01) dx = 0; if (fabs(dy) < 0.01) dy = 0;
    CGAffineTransform want = (dx || dy) ? CGAffineTransformMakeTranslation(-dx, -dy) : CGAffineTransformIdentity;
    if (!CGAffineTransformEqualToTransform(cv.transform, want)) cv.transform = want;
}
@interface W12WallLinker : NSObject
+ (void)tick:(CADisplayLink *)l;
@end
@implementation W12WallLinker
+ (void)tick:(CADisplayLink *)l {
    if (!gWallView || gWallView.hidden || !gWallView.window) { [l invalidate]; if (gWallLink == l) gWallLink = nil; return; }
    W12WallTick();
}
@end
static void W12WallStartLink(void) {
    if (gWallLink) return;
    gWallLink = [CADisplayLink displayLinkWithTarget:[W12WallLinker class] selector:@selector(tick:)];
    gWallLink.frameInterval = 1; [gWallLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

// ---- clock look ----
static UIColor *W12WallClockColor(void) {
    switch ((int)W12Double(@"wallClockColor", 0, 0, 5)) {
        case 1: return [UIColor whiteColor];
        case 2: return [UIColor colorWithRed:1.0 green:0.84 blue:0.35 alpha:1];
        case 3: return [UIColor colorWithRed:1.0 green:0.62 blue:0.72 alpha:1];
        case 4: return [UIColor colorWithRed:0.55 green:0.85 blue:1.0 alpha:1];
        case 5: return [UIColor colorWithRed:0.62 green:1.0 blue:0.7 alpha:1];
        default: return nil;
    }
}
static void (*o_wallDateLayout)(id, SEL);
static void W12WallStyleClock(UIView *dv) {
    BOOL big = W12Bool(@"wallBigClock", YES); UIColor *col = W12WallClockColor();
    if (!big && !col) return;
    id label = nil;
    for (NSString *k in @[@"timeLabel", @"_timeLabel"]) { @try { label = [dv valueForKey:k]; } @catch (id e) {} if (label) break; }
    if (!label) { static BOOL once; if (!once) { once = YES; W12_LOG(@"wall: no time label found on %@", NSStringFromClass([dv class])); } return; }
    if (big && [label respondsToSelector:@selector(setFont:)] && [label respondsToSelector:@selector(font)]) {
        CGFloat size = W12Double(@"wallClockSize", 92, 60, 130);
        UIFont *f = [UIFont systemFontOfSize:size weight:UIFontWeightHeavy];
        UIFont *cur = ((UIFont *(*)(id, SEL))objc_msgSend)(label, @selector(font));
        if (!cur || fabs(cur.pointSize - size) > 0.5 || ![cur.fontName isEqualToString:f.fontName]) {
            CGPoint c = ((UIView *)label).center;
            ((void (*)(id, SEL, id))objc_msgSend)(label, @selector(setFont:), f);
            [(UIView *)label sizeToFit];
            ((UIView *)label).center = CGPointMake(dv.bounds.size.width / 2, c.y);
        }
    }
    if (col && [label respondsToSelector:@selector(setTextColor:)]) ((void (*)(id, SEL, id))objc_msgSend)(label, @selector(setTextColor:), col);
}
static void n_wallDateLayout(id self, SEL _cmd) {
    o_wallDateLayout(self, _cmd);
    gWallDate = self;
    @try { W12WallStyleClock(self); } @catch (id e) {}
    dispatch_async(dispatch_get_main_queue(), ^{ W12WallApplyImage(); });
}
static void W12WallStart(void) {
    static BOOL hooked;
    void (^tryHook)(void) = ^{
        if (hooked) return;
        for (NSString *cn in @[@"SBFLockScreenDateView", @"SBLockScreenDateView"]) if (W12Hook(cn, @selector(layoutSubviews), (IMP)n_wallDateLayout, &o_wallDateLayout, 2, NULL)) { hooked = YES; break; }
    };
    tryHook();
    for (NSNumber *d in @[@5, @15, @40]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), tryHook);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ W12WallGenerate(NO); });
    int t1; notify_register_dispatch("com.wave12.wall.regen", &t1, dispatch_get_main_queue(), ^(int t) {
        gWallCut = nil; W12WallApplyImage(); W12WallGenerate(YES); });
    int t2; notify_register_dispatch("com.wave12.wall.apply", &t2, dispatch_get_main_queue(), ^(int t) { UIView *d = gWallDate; if (d) [d setNeedsLayout]; W12WallApplyImage(); });
    int t3; notify_register_dispatch("com.apple.springboard.lockstate", &t3, dispatch_get_main_queue(), ^(int t) {
        uint64_t s = 0; notify_get_state(t, &s);
        if (s != 0) {
            W12WallGenerate(NO);
            for (NSNumber *d in @[@0.05, @0.4, @1.2, @3.0]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                W12WallApplyImage(); });
        }
    });
}
