// Wave12 LockStyle: iOS 26 look for the lock screen (glass clock, glass notifications) and the passcode keypad
// (round glass keys). Every part has its own switch and is wrapped in @try so one failure never breaks the rest.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define LS_DOMAIN CFSTR("com.wave12.unlockwave")

static void LLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ ls: %@\n", [NSDate date], m];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:@"/var/mobile/Library/Logs/Wave12.log"];
    if (h) { [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile]; }
}
static id LPref(NSString *k) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)k, LS_DOMAIN);
    return v ? CFBridgingRelease(v) : nil;
}
static BOOL LBool(NSString *k, BOOL d) {
    if (!(LPref(@"enabled") ? [LPref(@"enabled") boolValue] : YES)) return NO;
    id v = LPref(k); return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : d;
}
static double LNum(NSString *k, double d, double lo, double hi) {
    id v = LPref(k); double x = [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : d;
    return MAX(lo, MIN(hi, x));
}

// ---- generic "run after the original" hook
static NSMutableSet *gHooked;
static BOOL HookAfter(NSString *cls, NSString *sel, void (^post)(id self)) {
    if (!gHooked) gHooked = [NSMutableSet set];
    NSString *key = [cls stringByAppendingString:sel];
    if ([gHooked containsObject:key]) return YES;
    Class c = NSClassFromString(cls);
    SEL s = NSSelectorFromString(sel);
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    if (!m || method_getNumberOfArguments(m) != 2) { LLog(@"skip %@ %@", cls, sel); return NO; }
    IMP orig = method_getImplementation(m);
    char *rt = method_copyReturnType(m); BOOL isVoid = rt && rt[0] == 'v'; free(rt);
    if (!isVoid) return NO;
    IMP imp = imp_implementationWithBlock(^(id self) {
        ((void (*)(id, SEL))orig)(self, s);
        @try { post(self); } @catch (NSException *e) { LLog(@"%@ %@: %@", cls, sel, e.reason); }
    });
    class_replaceMethod(c, s, imp, method_getTypeEncoding(m));
    [gHooked addObject:key];
    LLog(@"hooked %@ %@", cls, sel);
    return YES;
}

static id SafeKey(id obj, NSString *key) {
    @try { return [obj valueForKey:key]; } @catch (NSException *e) { return nil; }
}

// ======================= Clock =======================

static BOOL LooksLikeTime(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length < 3 || s.length > 8) return NO;
    NSRange r = [s rangeOfString:@":"];
    return r.location != NSNotFound && r.location > 0 && r.location < s.length - 1;
}

static void StyleTimeView(UIView *v, double alpha, double scale) {
    v.alpha = alpha;
    CGAffineTransform t = CGAffineTransformMakeScale(scale, scale);
    if (!CGAffineTransformEqualToTransform(v.transform, t)) v.transform = t;
    v.layer.shadowColor = [UIColor blackColor].CGColor;
    v.layer.shadowOpacity = 0.22; v.layer.shadowRadius = 10; v.layer.shadowOffset = CGSizeMake(0, 2);
    v.layer.shouldRasterize = NO;
}

static void FindTime(UIView *root, int depth, UIView **out) {
    if (!root || depth > 4 || *out) return;
    for (UIView *s in root.subviews) {
        NSString *txt = nil;
        if ([s isKindOfClass:[UILabel class]]) txt = ((UILabel *)s).text;
        else if ([s respondsToSelector:NSSelectorFromString(@"string")]) txt = ((id (*)(id, SEL))objc_msgSend)(s, NSSelectorFromString(@"string"));
        if (LooksLikeTime(txt)) { *out = s; return; }
        FindTime(s, depth + 1, out);
        if (*out) return;
    }
}

static void StyleClock(UIView *dateView) {
    if (!LBool(@"lsClock", YES)) return;
    UIView *time = SafeKey(dateView, @"_timeLabel");
    if (![time isKindOfClass:[UIView class]]) { time = nil; FindTime(dateView, 0, &time); }
    if (!time) return;
    double a = LNum(@"lsClockAlpha", 0.72, 0.35, 1.0), sc = LNum(@"lsClockScale", 1.08, 0.9, 1.35);
    StyleTimeView(time, a, sc);
    UIFont *f = nil;
    if ([time isKindOfClass:[UILabel class]]) f = ((UILabel *)time).font;
    else if ([time respondsToSelector:NSSelectorFromString(@"font")]) f = ((id (*)(id, SEL))objc_msgSend)(time, NSSelectorFromString(@"font"));
    if ([f isKindOfClass:[UIFont class]]) {
        UIFont *bold = [UIFont systemFontOfSize:f.pointSize weight:UIFontWeightHeavy];
        if (![bold.fontName isEqualToString:f.fontName]) {
            if ([time isKindOfClass:[UILabel class]]) ((UILabel *)time).font = bold;
            else if ([time respondsToSelector:NSSelectorFromString(@"setFont:")]) ((void (*)(id, SEL, id))objc_msgSend)(time, NSSelectorFromString(@"setFont:"), bold);
        }
    }
}

// ======================= Notifications =======================

static void StyleNotif(UIView *platter) {
    if (!LBool(@"lsNotif", YES)) return;
    double R = LNum(@"lsNotifRadius", 26, 10, 40);
    CALayer *L = platter.layer;
    if (L.cornerRadius != R) L.cornerRadius = R;
    L.masksToBounds = YES;
    UIView *bg = SafeKey(platter, @"backgroundView");
    if (![bg isKindOfClass:[UIView class]]) bg = SafeKey(platter, @"_backgroundView");
    if ([bg isKindOfClass:[UIView class]]) { bg.layer.cornerRadius = R; bg.layer.masksToBounds = YES; }
    if (L.borderWidth < 0.5) { L.borderWidth = 0.7; L.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor; }
}

// ======================= Keypad =======================

static const void *kGlassKey = &kGlassKey;

@interface W12Glass : UIVisualEffectView
@property (nonatomic, strong) CAShapeLayer *ring;
@property (nonatomic, strong) CAGradientLayer *shine;
@end
@implementation W12Glass
- (instancetype)init {
    self = [super initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleLight]];
    if (self) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        self.contentView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
        _shine = [CAGradientLayer layer];
        _shine.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.30].CGColor, (id)[UIColor colorWithWhite:1 alpha:0.0].CGColor, (id)[UIColor colorWithWhite:1 alpha:0.10].CGColor];
        _shine.startPoint = CGPointMake(0.15, 0); _shine.endPoint = CGPointMake(0.85, 1);
        [self.contentView.layer addSublayer:_shine];
        _ring = [CAShapeLayer layer];
        _ring.fillColor = nil; _ring.strokeColor = [UIColor colorWithWhite:1 alpha:0.70].CGColor; _ring.lineWidth = 1.2;
        [self.layer addSublayer:_ring];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    self.layer.cornerRadius = MIN(b.size.width, b.size.height) / 2;
    _shine.frame = b;
    _ring.frame = b;
    _ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(b, 0.6, 0.6)].CGPath;
}
@end

static void StyleKey(UIView *btn) {
    if (!LBool(@"lsPad", YES)) return;
    CGRect b = btn.bounds;
    CGFloat d = MIN(b.size.width, b.size.height);
    if (d < 40) return;
    W12Glass *g = objc_getAssociatedObject(btn, kGlassKey);
    if (!g) {
        g = [[W12Glass alloc] init];
        objc_setAssociatedObject(btn, kGlassKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [btn insertSubview:g atIndex:0];
    }
    g.frame = CGRectMake((b.size.width - d) / 2, (b.size.height - d) / 2, d, d);
    if (g.superview != btn) [btn insertSubview:g atIndex:0];
    // hide the stock round background (image / plain view about the size of the key); labels are left alone
    for (UIView *s in btn.subviews) {
        if (s == g || [s isKindOfClass:[UILabel class]]) continue;
        if ([s isKindOfClass:[UIImageView class]] || (s.bounds.size.width >= d * 0.8 && s.subviews.count == 0)) s.alpha = 0;
    }
    for (NSString *k in @[@"_circleView", @"_highlightedCircleView", @"_circleLayer"]) {
        id o = SafeKey(btn, k);
        if ([o isKindOfClass:[UIView class]]) ((UIView *)o).alpha = 0;
        else if ([o isKindOfClass:[CALayer class]]) ((CALayer *)o).opacity = 0;
    }
    for (UIView *s in btn.subviews) {                 // numbers a bit lighter, like iOS 26
        if ([s isKindOfClass:[UILabel class]]) {
            UILabel *l = (UILabel *)s;
            if (l.font.pointSize > 24 && l.font.pointSize < 60 && ![l.font.fontName containsString:@"Light"]) l.font = [UIFont systemFontOfSize:l.font.pointSize weight:UIFontWeightRegular];
            l.textColor = [UIColor whiteColor];
        }
    }
}

// ======================= Setup =======================

static void InstallAll(void) {
    for (NSString *c in @[@"SBFLockScreenDateView", @"SBLockScreenDateView", @"CSTimeView"])
        HookAfter(c, @"layoutSubviews", ^(id self) { StyleClock(self); });
    for (NSString *c in @[@"PLPlatterView", @"NCNotificationShortLookView"])
        HookAfter(c, @"layoutSubviews", ^(id self) { StyleNotif(self); });
    for (NSString *c in @[@"TPNumberPadButton", @"SBUIPasscodeNumberPadButton"])
        HookAfter(c, @"layoutSubviews", ^(id self) { StyleKey(self); });
}

void W12LockStyleInit(void);
void W12LockStyleInit(void) {
    @try {
        InstallAll();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ @try { InstallAll(); } @catch (NSException *e) {} });
        LLog(@"lock style ready");
    } @catch (NSException *e) { LLog(@"init failed: %@", e.reason); }
}
