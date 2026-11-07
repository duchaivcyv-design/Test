// Wave12 TabBar: iOS 26 style floating glass tab bar for every UIKit app (not SpringBoard).
// - the stock bar background is removed and a glass capsule floats `tabLift` pt above the bottom edge
//   (above the HomeGesture swipe zone, so sliding a finger along the bar never leaves the app)
// - touching the bar shows a glass lens that magnifies the icons under it and follows the finger;
//   releasing snaps to the nearest item with a spring and selects it.
#import <UIKit/UIKit.h>
#import "W12Rim.h"
#import <objc/runtime.h>

#define TB_DOMAIN CFSTR("com.wave12.unlockwave")

static void TLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ tab: %@\n", [NSDate date], m];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:@"/var/mobile/Library/Logs/Wave12.log"];
    if (h) { [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile]; }
}
static id TPref(NSString *k) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)k, TB_DOMAIN);
    return v ? CFBridgingRelease(v) : nil;
}
static BOOL TBool(NSString *k, BOOL d) {
    id e = TPref(@"en_tab"); if (e && ![e boolValue]) return NO;
    id v = TPref(k); return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : d;
}
static double TNum(NSString *k, double d, double lo, double hi) {
    id v = TPref(k); double x = [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : d;
    return MAX(lo, MIN(hi, x));
}

static const void *kHost = &kHost;
static const void *kBack = &kBack, *kCap = &kCap, *kLens = &kLens, *kGR = &kGR, *kIdx = &kIdx, *kConf = &kConf, *kDark = &kDark, *kAuto = &kAuto, *kAutoCnt = &kAutoCnt, *kAutoTimer = &kAutoTimer;
static const void *kSelCol = &kSelCol, *kUnselCol = &kUnselCol;
static void CollectContent(UIView *v, int d, NSMutableArray *a);
static BOOL Colourful(UIColor *c) {
    CGFloat h, s, b, al;
    return c && [c getHue:&h saturation:&s brightness:&b alpha:&al] && s > 0.25 && b > 0.3 && al > 0.3;
}
static BOOL LooksWhite(UIColor *c) {
    CGFloat h, s, b, al;
    return !c || ([c getHue:&h saturation:&s brightness:&b alpha:&al] && s < 0.12 && b > 0.93);
}
static UIColor *BtnLabelColor(UIView *btn) {
    NSMutableArray *a = [NSMutableArray array]; CollectContent(btn, 0, a);
    for (UIView *v in a) if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (l.attributedText.length) { id c = [l.attributedText attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL]; if ([c isKindOfClass:[UIColor class]]) return c; }
        return l.textColor;
    }
    return nil;
}
// Work out the app's real selected / unselected colours once per touch (before we recolour anything).
static void ResolveColors(UITabBar *tb, NSArray *btns) {
    if (objc_getAssociatedObject(tb, kSelCol)) return;
    NSUInteger si = tb.selectedItem ? [tb.items indexOfObject:tb.selectedItem] : NSNotFound;
    UIColor *sel = nil, *uns = nil;
    if (si != NSNotFound && si < btns.count) { UIColor *c = BtnLabelColor(btns[si]); if (Colourful(c)) sel = c; }
    if (!sel) sel = Colourful(tb.tintColor) ? tb.tintColor : (tb.tintColor ?: [UIColor colorWithRed:0 green:0.48 blue:1 alpha:1]);
    if (@available(iOS 10.0, *)) uns = tb.unselectedItemTintColor;
    for (NSUInteger i = 0; !uns && i < btns.count; i++) {
        if (i == si) continue;
        UIColor *c = BtnLabelColor(btns[i]);
        if (c && !Colourful(c) && !LooksWhite(c)) uns = c;
    }
    if (!uns) uns = [UIColor colorWithWhite:0.56 alpha:1];
    objc_setAssociatedObject(tb, kSelCol, sel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tb, kUnselCol, uns, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    TLog(@"tab colours: selected %@ unselected %@ (tint %@)", sel, uns, tb.tintColor);
}
// While the glass is held the real selected item must look unselected. We do NOT touch the bar's tint (that drifted after many touches):
// the selected button's icon/label are hidden and replaced by grey copies; everything is put back in ReleaseGhost().
static const void *kGhostBox = &kGhostBox, *kHidden = &kHidden;
static const void *kSwellKey = &kSwellKey;
static void ApplyLift(UITabBar *tb, CGRect pill);
// The whole glass bar swells a little while it is pressed (like iOS 26) and relaxes with a spring when released.
static NSArray<UIView *> *Buttons(UITabBar *tb);
static CGRect PillRect(UITabBar *tb, NSArray<UIView *> *btns);
static const void *kTy = &kTy, *kSeen = &kSeen, *kVisStart = &kVisStart;
static const void *kSwellPill = &kSwellPill;
// The swell lives on the bar layer's sublayerTransform: completely separate from tb.transform (lift / app transform),
// so layout passes, Select(), the lift logic and the app can never move or resize the bar while it swells.
// It only scales horizontally about the pill centre, so the dock height never changes.
static void SetSwell(UITabBar *tb, CGFloat f, CGRect pill) {
    CALayer *L = tb.layer;
    if (f > 1.0 || !objc_getAssociatedObject(tb, kSwellPill))   // remember the pill the swell was started from
        objc_setAssociatedObject(tb, kSwellPill, [NSValue valueWithCGRect:pill], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGRect pr = [objc_getAssociatedObject(tb, kSwellPill) CGRectValue];
    CATransform3D target = CATransform3DIdentity;
    if (f > 1.0 && tb.window) {
        CGFloat sw = MIN(f, (tb.window.bounds.size.width - 6) / MAX(1, pr.size.width));
        CGFloat dx = CGRectGetMidX(pr) - tb.bounds.size.width / 2;           // sublayerTransform is anchored at the layer centre
        target = CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(dx, 0, 0), sw, 1, 1), -dx, 0, 0);
    }
    CATransform3D from = L.presentationLayer ? L.presentationLayer.sublayerTransform : L.sublayerTransform;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    L.sublayerTransform = target;
    [CATransaction commit];
    CASpringAnimation *a = [CASpringAnimation animationWithKeyPath:@"sublayerTransform"];   // springy both ways: swells with a bounce, settles back with a bounce
    a.mass = 1; a.initialVelocity = 0;
    if (f > 1.0) { a.stiffness = 320; a.damping = 13; } else { a.stiffness = 240; a.damping = 11; }
    a.duration = a.settlingDuration;
    a.fromValue = [NSValue valueWithCATransform3D:from]; a.toValue = [NSValue valueWithCATransform3D:target];
    [L addAnimation:a forKey:@"w12.swell"];
    if (f <= 1.0) objc_setAssociatedObject(tb, kSwellPill, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static NSArray<UIView *> *Buttons(UITabBar *tb);
static void ReleaseGhost(UITabBar *tb) {
    for (UIView *v in objc_getAssociatedObject(tb, kHidden) ?: @[]) v.alpha = 1;
    objc_setAssociatedObject(tb, kHidden, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *g = objc_getAssociatedObject(tb, kGhostBox); [g removeFromSuperview];
    objc_setAssociatedObject(tb, kGhostBox, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tb, kSelCol, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tb, kUnselCol, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
// While the glass is held, nothing outside the lens may show the "selected" colour: if the system re-creates or re-tints the selected item's
// icon / label (it does that on layout and on selection changes), the ghost is rebuilt at once.
static void EnforceGhost(UITabBar *tb);
static void RebuildGhost(UITabBar *tb) {
    UIColor *grey = objc_getAssociatedObject(tb, kUnselCol) ?: [UIColor colorWithWhite:0.56 alpha:1];
    for (UIView *v in objc_getAssociatedObject(tb, kHidden) ?: @[]) v.alpha = 1;
    [(UIView *)objc_getAssociatedObject(tb, kGhostBox) removeFromSuperview];
    NSArray *btns = Buttons(tb);
    NSUInteger si = tb.selectedItem ? [tb.items indexOfObject:tb.selectedItem] : NSNotFound;
    NSMutableArray *hidden = [NSMutableArray array];
    UIView *gc = [[UIView alloc] initWithFrame:tb.bounds]; gc.userInteractionEnabled = NO;
    if (si != NSNotFound && si < btns.count) {
        NSMutableArray *content = [NSMutableArray array]; CollectContent(btns[si], 0, content);
        for (UIView *sv in content) {
            CGRect fr = [tb convertRect:sv.bounds fromView:sv];
            UIView *c = nil;
            if ([sv isKindOfClass:[UIImageView class]]) {
                UIImageView *iv = [[UIImageView alloc] initWithImage:[((UIImageView *)sv).image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
                iv.contentMode = sv.contentMode; iv.tintColor = grey; c = iv;
            } else {
                UILabel *src = (UILabel *)sv, *l = [[UILabel alloc] init];
                l.text = src.text; l.font = src.font; l.textAlignment = src.textAlignment; l.textColor = grey; l.backgroundColor = [UIColor clearColor]; c = l;
            }
            c.frame = fr; [gc addSubview:c];
            sv.alpha = 0; [hidden addObject:sv];
        }
    }
    UIView *lens = objc_getAssociatedObject(tb, kLens);
    if (lens.superview == tb) [tb insertSubview:gc belowSubview:lens]; else [tb addSubview:gc];
    objc_setAssociatedObject(tb, kGhostBox, gc, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tb, kHidden, hidden, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
#define kInflate ((CGFloat)TNum(@"tabInflate", 1.45, 1.0, 1.8))   // the held lens swells like a drop of glass


#pragma mark - Views

@interface W12TabBack : UIView                       // shadow + border container
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic) CGSize lastSize;
@property (nonatomic, strong) CALayer *rim;
@property (nonatomic) BOOL lightRim, rimStale, darkMode;
- (void)applyTint;
@end
@implementation W12TabBack
// Keep the real blur at full strength and replace the style's own (strong, milky) tint overlay by a light one of our own,
// like the translucent bar of the system: blurred colours of the content show through.
- (void)applyTint {
    if (fabs(_blur.alpha - 1) > 0.01) _blur.alpha = 1;
    CGFloat k = (CGFloat)TNum(@"tabAlpha", 0.6, 0.2, 1.0);
    UIColor *tint = _darkMode ? [UIColor colorWithWhite:0.0 alpha:0.5 * k] : [UIColor colorWithWhite:1.0 alpha:0.5 * k];
    static BOOL logged = NO;
    for (UIView *s in _blur.subviews) {
        NSString *cn = NSStringFromClass([s class]);
        if (!logged) NSLog(@"[Wave12] tab blur subview: %@", cn);
        if ([cn containsString:@"Backdrop"] || [cn isEqualToString:@"UIVisualEffectContentView"] || s == _blur.contentView) continue;
        if (![s.backgroundColor isEqual:tint]) s.backgroundColor = tint;
        s.alpha = 1;
    }
    logged = YES;
}
- (instancetype)init {
    self = [super init];
    if (self) {
        self.userInteractionEnabled = NO;
        _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleLight]];
        _blur.clipsToBounds = YES;
        [self addSubview:_blur];
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.18; self.layer.shadowRadius = 14; self.layer.shadowOffset = CGSizeMake(0, 4);
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize sz = self.bounds.size;
    if (CGSizeEqualToSize(sz, _lastSize) && !_rimStale) return;      // nothing changed: skip path rebuilds on every layout pass
    _lastSize = sz; _rimStale = NO;
    if (!_rim) { _rim = W12RimLayer(@"w12.tabrim"); [self.layer addSublayer:_rim]; }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    W12RimSetL(_rim, self.bounds, sz.height / 2, NO, _lightRim);
    [CATransaction commit];
    _blur.frame = self.bounds;
    _blur.layer.cornerRadius = sz.height / 2;
    [self applyTint];
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:sz.height / 2].CGPath;
}
@end

// Fake "liquid glass" lens: opaque glass body, three stacked magnified copies of the bar content (centre / middle / edge,
// each stronger than the one inside = barrel distortion at the rim), a tinted rim and a soft specular highlight.
@interface W12TabLens : UIView
@property (nonatomic, strong) UIView *clip;
@property (nonatomic, strong) UIView *tint;
@property (nonatomic, strong) NSArray<UIView *> *rings;     // masked containers, outermost first
@property (nonatomic, strong) NSArray<UIView *> *boxes;     // content copies (one per ring)
@property (nonatomic, strong) CAShapeLayer *rimTint, *rimWhite;
@property (nonatomic, strong) CAGradientLayer *gloss, *spec;
@property (nonatomic, strong) CALayer *rimGlass;
@property (nonatomic) BOOL lightRim;
@property (nonatomic, strong) UIVisualEffectView *blur;      // real blur inside the glass, same look as the bar around it
@property (nonatomic) CGRect barRect;                        // the bar's capsule in the tab bar's coordinates: frosted fill only exists inside it
@property (nonatomic) BOOL hasBarRect;
- (void)setDark:(BOOL)dark;
- (void)updateFill;
@end
@implementation W12TabLens
- (void)setDark:(BOOL)dark {
    _blur.effect = [UIBlurEffect effectWithStyle:dark ? UIBlurEffectStyleDark : UIBlurEffectStyleLight];
    CGFloat k = (CGFloat)TNum(@"tabAlpha", 0.6, 0.2, 1.0);
    UIColor *tint = dark ? [UIColor colorWithWhite:0.0 alpha:0.18 * k] : [UIColor colorWithWhite:1.0 alpha:0.22 * k];
    __weak UIVisualEffectView *wb = _blur;
    void (^paint)(void) = ^{
        UIVisualEffectView *bv = wb; if (!bv) return;
        for (UIView *s in bv.subviews) {
            NSString *cn = NSStringFromClass([s class]);
            if ([cn containsString:@"Backdrop"] || s == bv.contentView) continue;
            s.backgroundColor = tint; s.alpha = 1;
        }
    };
    paint();
    dispatch_async(dispatch_get_main_queue(), paint);       // the effect view may rebuild its subviews after the effect change
}
- (instancetype)init {
    self = [super init];
    if (self) {
        self.userInteractionEnabled = NO;
        _clip = [[UIView alloc] init]; _clip.clipsToBounds = YES; _clip.userInteractionEnabled = NO;
        [self addSubview:_clip];
        _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleLight]];
        _blur.userInteractionEnabled = NO; [_clip addSubview:_blur];
        _tint = [[UIView alloc] init]; [_clip addSubview:_tint];
        _gloss = [CAGradientLayer layer];
        _gloss.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.30].CGColor, (id)[UIColor colorWithWhite:1 alpha:0.0].CGColor];
        _gloss.startPoint = CGPointMake(0.5, 0); _gloss.endPoint = CGPointMake(0.5, 1);
        _rimTint = [CAShapeLayer layer]; _rimTint.fillColor = nil; _rimTint.lineWidth = 1.1;      // thin grey rim
        _rimWhite = [CAShapeLayer layer]; _rimWhite.fillColor = nil; _rimWhite.lineWidth = 1.8; _rimWhite.strokeColor = [UIColor whiteColor].CGColor;
        // specular edge: bright crescents top-left / bottom-right (light bending at the glass rim), masked by the inner ring stroke
        _spec = [CAGradientLayer layer];
        _spec.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.95].CGColor, (id)[UIColor colorWithWhite:1 alpha:0.0].CGColor,
                         (id)[UIColor colorWithWhite:1 alpha:0.0].CGColor, (id)[UIColor colorWithWhite:1 alpha:0.7].CGColor];
        _spec.locations = @[@0, @0.38, @0.62, @1];
        _spec.startPoint = CGPointMake(0.1, 0); _spec.endPoint = CGPointMake(0.9, 1);
        _spec.mask = _rimWhite;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0; self.layer.shadowRadius = 10; self.layer.shadowOffset = CGSizeMake(0, 4);
    }
    return self;
}
- (void)installRings:(NSArray<UIView *> *)boxes {
    for (UIView *r in _rings) [r removeFromSuperview];
    NSMutableArray *rs = [NSMutableArray array];
    for (UIView *bx in boxes) {
        UIView *ring = [[UIView alloc] init]; ring.userInteractionEnabled = NO;
        ring.layer.mask = [CAShapeLayer layer];
        [ring addSubview:bx];
        [_clip insertSubview:ring belowSubview:_tint]; [rs addObject:ring];
    }
    // draw order: blur, tint, then rings outermost -> innermost
    [_clip insertSubview:_tint atIndex:0];
    [_clip insertSubview:_blur atIndex:0];
    for (UIView *r in rs) [_clip addSubview:r];
    _gloss.hidden = YES; _spec.hidden = YES;   // no light-reflection effects
    [self.layer addSublayer:_rimTint];
    _rimTint.hidden = YES;      // the flat grey ring is replaced by the glass rim (bright top-left / bottom-right)
    if (!_rimGlass) _rimGlass = W12RimLayer(@"w12.lensrim");
    [self.layer addSublayer:_rimGlass];
    _rings = rs; _boxes = boxes;
    [self setNeedsLayout];
}
// The frosted fill (blur + tint) is only drawn where the lens overlaps the BAR. The part of the glass that pokes out of the bar is clear,
// so nothing outside the bar's border takes the bar's colour. Uses the presentation values: the lens is usually mid-animation.
- (void)updateFill {
    CGRect b = self.bounds;
    CGRect f = b; CGFloat r = b.size.height / 2;
    if (_hasBarRect && b.size.width > 1) {
        CALayer *pl = self.layer.presentationLayer ?: self.layer;
        CGAffineTransform t = pl.affineTransform;
        CGFloat sx = MAX(0.3, fabs(t.a)), sy = MAX(0.3, fabs(t.d));
        CGPoint c = pl.position;
        f = CGRectMake((_barRect.origin.x - c.x) / sx + b.size.width / 2, (_barRect.origin.y - c.y) / sy + b.size.height / 2,
                       _barRect.size.width / sx, _barRect.size.height / sy);
        r = MAX(2, MIN(_barRect.size.height / 2 / ((sx + sy) / 2), f.size.height / 2));
    }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (UIView *v in @[_blur, _tint]) {
        v.frame = f; v.layer.cornerRadius = r; v.clipsToBounds = YES;
    }
    [CATransaction commit];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds; CGFloat h = b.size.height;
    _clip.frame = b; _clip.layer.cornerRadius = h / 2;
    [self updateFill];
    CGFloat insets[3] = {0, 0, 0};
    for (NSUInteger i = 0; i < _rings.count && i < 3; i++) {
        UIView *r = _rings[i]; r.frame = b;
        CGRect ir = CGRectInset(b, insets[i] * 1.6, insets[i]);
        ((CAShapeLayer *)r.layer.mask).path = [UIBezierPath bezierPathWithRoundedRect:ir cornerRadius:ir.size.height / 2].CGPath;
        ((CAShapeLayer *)r.layer.mask).frame = b;
    }
    _gloss.frame = CGRectMake(0, 0, b.size.width, h * 0.5);
    _gloss.cornerRadius = h / 2;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    UIBezierPath *outer = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, 0.9, 0.9) cornerRadius:h / 2 - 0.9];
    _rimTint.path = outer.CGPath;
    W12RimSetL(_rimGlass, b, h / 2, YES, _lightRim);
    _spec.frame = b; _rimWhite.frame = b;
    _rimWhite.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, 2.4, 2.4) cornerRadius:h / 2 - 2.4].CGPath;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:b cornerRadius:h / 2].CGPath;
    [CATransaction commit];
}
@end

#pragma mark - Geometry

static BOOL SelfExcluded(void) {
    static NSString *bid; static NSArray *cache; static CFTimeInterval at;
    if (!bid) bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    CFTimeInterval now = CACurrentMediaTime();
    if (!cache || now - at > 1.5) {
        id a = TPref(@"exclude"); cache = [a isKindOfClass:[NSArray class]] ? a : @[]; at = now;
    }
    return [cache containsObject:bid];
}

static BOOL ButtonsOK(UITabBar *tb);
static BOOL Eligible(UITabBar *tb) {
    if (!TBool(@"tabOn", YES) || SelfExcluded()) return NO;
    if ([UIDevice currentDevice].userInterfaceIdiom != UIUserInterfaceIdiomPhone) return NO;
    if (tb.hidden || tb.alpha < 0.05 || tb.items.count < 2 || !tb.window) return NO;
    CGSize ws = tb.window.bounds.size;
    if (ws.width > ws.height) return NO;                                   // portrait only
    if (tb.bounds.size.width < ws.width * 0.85 || tb.bounds.size.height < 40 || tb.bounds.size.height > 110) return NO;
    if (!ButtonsOK(tb)) return NO;
    if (!TBool(@"tabCustom", NO)) {      // safe default: only the standard UITabBarController bar (apps like Zalo drive their own bar)
        id d = tb.delegate;
        if (!([d isKindOfClass:[UITabBarController class]] && ((UITabBarController *)d).tabBar == tb)) {
            static NSMutableSet *seen; if (!seen) seen = [NSMutableSet set];
            NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"?";
            if (![seen containsObject:bid]) { [seen addObject:bid]; TLog(@"custom tab bar in %@ (delegate %@) left untouched", bid, NSStringFromClass([d class])); }
            return NO;
        }
    }
    return YES;
}

static void CollectBtns(UIView *v, int d, NSMutableArray *a) {
    for (UIView *s in v.subviews) {
        if ([NSStringFromClass([s class]) containsString:@"TabBarButton"]) [a addObject:s];
        else if (d < 2) CollectBtns(s, d + 1, a);
    }
}

static NSArray<UIView *> *Buttons(UITabBar *tb) {
    NSMutableArray *a = [NSMutableArray array];
    CollectBtns(tb, 0, a);
    [a sortUsingComparator:^NSComparisonResult(UIView *x, UIView *y) {
        CGFloat xa = [tb convertPoint:CGPointZero fromView:x].x, ya = [tb convertPoint:CGPointZero fromView:y].x;
        return xa < ya ? NSOrderedAscending : NSOrderedDescending; }];
    return a;
}

static BOOL ButtonsOK(UITabBar *tb) {
    NSArray *b = Buttons(tb);
    BOOL ok = b.count == tb.items.count && b.count > 0;
    for (UIView *v in b) if (v.superview != tb) ok = NO;
    if (!ok) {
        static NSMutableSet *seen; if (!seen) seen = [NSMutableSet set];
        NSString *k = [NSString stringWithFormat:@"%@%lu", [NSBundle mainBundle].bundleIdentifier, (unsigned long)b.count];
        if (![seen containsObject:k]) {
            [seen addObject:k];
            NSMutableString *d = [NSMutableString string];
            for (UIView *sv in tb.subviews) [d appendFormat:@"%@ ", NSStringFromClass([sv class])];
            TLog(@"skip tab bar in %@: %lu buttons for %lu items; class %@; subviews: %@", [NSBundle mainBundle].bundleIdentifier, (unsigned long)b.count, (unsigned long)tb.items.count, NSStringFromClass([tb class]), d);
        }
    }
    return ok;
}

static CGRect PillRect(UITabBar *tb, NSArray<UIView *> *btns) {
    // wrap the real content (icons + labels of every button) with generous padding so nothing sticks out
    CGFloat top = CGFLOAT_MAX, bot = -CGFLOAT_MAX;
    for (UIView *b in btns) {
        CGRect u = CGRectNull;
        for (UIView *s in b.subviews) {
            // the ghost trick hides the selected icon/label (alpha 0) while the glass is held; they must still count, otherwise the
            // pill's height/position changes on every press and release => the dock "jumps" vertically
            BOOL ghost = NO;
            for (UIView *hv in objc_getAssociatedObject(tb, kHidden) ?: @[]) if (hv == s || [hv isDescendantOfView:s]) { ghost = YES; break; }
            if (!s.hidden && (s.alpha > 0.01 || ghost)) u = CGRectUnion(u, s.frame);
        }
        if (CGRectIsNull(u)) u = b.bounds;
        top = MIN(top, b.frame.origin.y + u.origin.y);
        bot = MAX(bot, b.frame.origin.y + CGRectGetMaxY(u));
    }
    if (top > bot) { top = 2; bot = 47; }
    CGFloat pad = (CGFloat)TNum(@"tabPad", 10, 4, 30), h = MAX(60, (bot - top) + 2 * pad);
    CGFloat mid = (top + bot) / 2;
    CGFloat full = tb.bounds.size.width - 20;
    CGFloat w = MIN(full, btns.count * 82.0 + 16.0);                  // few tabs -> a compact pill, like iOS 26
    return CGRectMake((tb.bounds.size.width - w) / 2, mid - h / 2, w, h);
}

// Mean luminance (0..1) of what is drawn behind the pill, rendered from the window's layer tree into a tiny bitmap with the bar itself
// hidden. Returns -1 when the area cannot be read (video / web / Metal content renders as nothing).
static CGFloat BackLuma(UITabBar *tb, CGRect pill) {
    UIWindow *w = tb.window; if (!w) return -1;
    CGRect r = [tb convertRect:pill toView:w];
    r = CGRectIntersection(r, w.bounds);
    if (r.size.width < 20 || r.size.height < 10) return -1;
    const int pw = 24, ph = 8;
    uint8_t *buf = calloc(pw * ph * 4, 1);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, pw, ph, 8, pw * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    CGFloat res = -1;
    if (ctx) {
        CGContextTranslateCTM(ctx, 0, ph);
        CGContextScaleCTM(ctx, pw / r.size.width, -ph / r.size.height);
        CGContextTranslateCTM(ctx, -r.origin.x, -r.origin.y);
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        BOOL was = tb.layer.hidden; tb.layer.hidden = YES;
        [w.layer renderInContext:ctx];
        tb.layer.hidden = was;
        [CATransaction commit];
        double sum = 0; int n = 0;
        for (int i = 0; i < pw * ph; i++) {
            uint8_t *q = buf + i * 4;
            if (q[3] < 200) continue;                                   // unread / transparent pixel
            sum += (0.299 * q[0] + 0.587 * q[1] + 0.114 * q[2]) / 255.0; n++;
        }
        if (n >= pw * ph * 0.35) res = sum / n;
        CGContextRelease(ctx);
    }
    free(buf);
    return res;
}

static void StyleTabBar(UITabBar *tb);
static BOOL IsDark(UITabBar *tb);
// Dark pill over dark content, white pill over light content (with hysteresis + two agreeing readings, so it never flickers).
static void AutoDarkTick(UITabBar *tb) {
    if (!tb.window || tb.hidden || tb.alpha < 0.05 || !objc_getAssociatedObject(tb, kConf)) return;
    if ([(UIView *)objc_getAssociatedObject(tb, kLens) superview]) return;          // never while the glass is held
    W12TabBack *back = objc_getAssociatedObject(tb, kBack);
    if (!back || back.hidden) return;
    static CFTimeInterval lastCost = 0; static unsigned skip = 0;
    if (lastCost > 0.012 && (skip++ & 1)) return;                                   // sampling is slow on this device: every other tick only
    CFTimeInterval t0 = CACurrentMediaTime();
    CGFloat lum = BackLuma(tb, back.frame);
    lastCost = CACurrentMediaTime() - t0;
    if (lum < 0) return;
    NSNumber *cur = objc_getAssociatedObject(tb, kAuto);
    BOOL dark = cur ? cur.boolValue : IsDark(tb);
    BOOL want = dark ? (lum < 0.50) : (lum < 0.34);                                 // enter dark below 0.34, leave it above 0.50
    if (want == dark) { objc_setAssociatedObject(tb, kAutoCnt, @0, OBJC_ASSOCIATION_RETAIN_NONATOMIC); return; }
    BOOL clear = dark ? (lum > 0.62) : (lum < 0.22);                                // far past the threshold: switch at once, no second look
    int cnt = [objc_getAssociatedObject(tb, kAutoCnt) intValue] + 1;
    objc_setAssociatedObject(tb, kAutoCnt, @(cnt), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (cnt < 2 && !clear) return;
    objc_setAssociatedObject(tb, kAutoCnt, @0, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tb, kAuto, @(want), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    TLog(@"tab bar background luma %.2f -> %@ pill", lum, want ? @"dark" : @"light");
    StyleTabBar(tb);
}

static BOOL IsDark(UITabBar *tb) {
    if (tb.barStyle == UIBarStyleBlack) return YES;
    UIColor *c = tb.barTintColor;
    CGFloat r, g, b, a;
    if (c && [c getRed:&r green:&g blue:&b alpha:&a] && a > 0.5) return (0.299 * r + 0.587 * g + 0.114 * b) < 0.35;
    UIView *bgv = tb.superview;
    UIColor *bc = bgv.backgroundColor;
    if (bc && [bc getRed:&r green:&g blue:&b alpha:&a] && a > 0.5) return (0.299 * r + 0.587 * g + 0.114 * b) < 0.35;
    return NO;
}

#pragma mark - Controller (gesture target)

@interface W12TabCtl : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handle:(UILongPressGestureRecognizer *)g;
@end

static NSArray<UIView *> *Buttons(UITabBar *tb);
static void Select(UITabBar *tb, NSUInteger idx) {
    if (idx >= tb.items.count) return;
    UITabBarItem *want = tb.items[idx];
    if (tb.selectedItem == want) return;
    // Preferred: "tap" the real tab button, so the owner (UITabBarController, Zalo's own controller, ...) reacts exactly like to a finger.
    NSArray *btns = Buttons(tb);
    if (idx < btns.count && [btns[idx] isKindOfClass:[UIControl class]]) {
        UIControl *c = btns[idx];
        [c sendActionsForControlEvents:UIControlEventTouchDown];
        [c sendActionsForControlEvents:UIControlEventTouchUpInside];
        if (tb.selectedItem == want) return;
    }
    id d = tb.delegate;
    if ([d isKindOfClass:[UITabBarController class]]) {
        UITabBarController *c = d;
        if (c.viewControllers.count == tb.items.count) { if (c.selectedIndex != idx) c.selectedIndex = idx; return; }
    }
    tb.selectedItem = want;
    if ([d respondsToSelector:@selector(tabBar:didSelectItem:)]) [d tabBar:tb didSelectItem:want];
}

static NSInteger NearestIndex(NSArray<UIView *> *btns, CGFloat x) {
    NSInteger best = -1; CGFloat bd = 1e9;
    for (NSUInteger i = 0; i < btns.count; i++) {
        CGFloat d = fabs(CGRectGetMidX(btns[i].frame) - x);
        if (d < bd) { bd = d; best = (NSInteger)i; }
    }
    return best;
}

static void PlaceSnapshot(W12TabLens *lens, UITabBar *tb, CGPoint c, CGFloat scale) {
    CGSize S = tb.bounds.size;
    static const CGFloat mul[3] = {1.0, 1.0, 1.0};          // edge ring magnifies more -> lens-like warp
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < lens.boxes.count && i < 3; i++) {
        UIView *sn = lens.boxes[i];
        sn.transform = CGAffineTransformIdentity;
        sn.bounds = CGRectMake(0, 0, S.width, S.height);
        sn.layer.anchorPoint = CGPointMake(c.x / S.width, c.y / S.height);
        sn.layer.position = CGPointMake(lens.bounds.size.width / 2, lens.bounds.size.height / 2);
        CGAffineTransform lt = ((CALayer *)(lens.layer.presentationLayer ?: lens.layer)).affineTransform;
        CGFloat lsx = MAX(0.5, fabs(lt.a)), lsy = MAX(0.5, fabs(lt.d));   // the lens is scaled (inflated, stretched): cancel each axis for the content
        CGFloat k = (i == 0) ? 1.0 : scale * mul[i];      // ring 0 = bar edge, never magnified
        sn.transform = CGAffineTransformMakeScale(k / lsx, k / lsy);   // uniform on screen -> text keeps its proportions
    }
    [CATransaction commit];
}

// Coloured copies of every icon/label: they fade in as the lens passes over an item (selected colour preview).
static void TintClones(W12TabLens *lens, CGFloat cx, CGFloat iw) {
    for (UIView *box in lens.boxes) {
        for (NSDictionary *d in objc_getAssociatedObject(box, "clones")) {
            CGFloat x = [d[@"x"] doubleValue];
            CGFloat k = MAX(0, 1.0 - fabs(x - cx) / (iw * 0.85));
            ((UIView *)d[@"v"]).alpha = k * k * (3 - 2 * k);
        }
    }
}

static void CollectContent(UIView *v, int d, NSMutableArray *a) {
    for (UIView *s in v.subviews) {
        if (s.hidden || s.alpha < 0.01) continue;
        if (([s isKindOfClass:[UIImageView class]] && ((UIImageView *)s).image) || ([s isKindOfClass:[UILabel class]] && ((UILabel *)s).text.length)) [a addObject:s];
        else if (d < 3) CollectContent(s, d + 1, a);
    }
}

// The lens picture is rebuilt from copies of every icon/label (no screenshot, so it can never come out blank):
// a base copy as drawn now plus a coloured copy that fades in while the lens is over that item.
// The bar's own shape (fill + edge). Not magnified, so its border stays visible at its true place through the glass.
static UIView *BuildLensEdge(UITabBar *tb, NSArray *btns) {
    UIView *box = [[UIView alloc] initWithFrame:tb.bounds];
    box.userInteractionEnabled = NO;
    {   // the bar itself (pill + its edge + the selected capsule) is part of what the lens magnifies, so its border is visible through the glass
        BOOL dk = [objc_getAssociatedObject(tb, kDark) boolValue];
        CGRect pr = PillRect(tb, btns);
        UIView *pv = [[UIView alloc] initWithFrame:pr];
        pv.backgroundColor = [UIColor clearColor];      // the glass interior is the lens' own blur, not a solid fill
        pv.layer.cornerRadius = pr.size.height / 2;
        pv.layer.borderWidth = 0.8;
        pv.layer.borderColor = (dk ? [UIColor colorWithWhite:1 alpha:0.5] : [UIColor colorWithWhite:0 alpha:0.28]).CGColor;   // clearly visible edge inside the glass
        [box addSubview:pv];
    }
    return box;
}

static UIView *BuildLensContent(UITabBar *tb, NSArray *btns) {
    UIView *box = [[UIView alloc] initWithFrame:tb.bounds];
    box.userInteractionEnabled = NO;
    ResolveColors(tb, btns);
    UIColor *tint = objc_getAssociatedObject(tb, kSelCol);      // selected colour (inside the glass)
    UIColor *grey = objc_getAssociatedObject(tb, kUnselCol);    // unselected colour (everything else)
    NSMutableArray *clones = [NSMutableArray array];
    for (UIView *b in btns) {
        CGFloat mx = [tb convertPoint:CGPointMake(CGRectGetMidX(b.bounds), 0) fromView:b].x;
        NSMutableArray *content = [NSMutableArray array];
        CollectContent(b, 0, content);
        for (UIView *sv in content) {
            CGRect fr = [tb convertRect:sv.bounds fromView:sv];
            UIView *base = nil, *over = nil;
            if ([sv isKindOfClass:[UIImageView class]]) {
                UIImage *im = ((UIImageView *)sv).image;
                UIImageView *b1 = [[UIImageView alloc] initWithImage:[im imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]]; b1.contentMode = sv.contentMode; b1.tintColor = grey; base = b1;
                UIImageView *b2 = [[UIImageView alloc] initWithImage:[im imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
                b2.contentMode = sv.contentMode; b2.tintColor = tint; over = b2;
            } else {
                UILabel *src = (UILabel *)sv;
                UILabel *l1 = [[UILabel alloc] init]; l1.text = src.text; l1.font = src.font; l1.textAlignment = src.textAlignment; l1.textColor = grey; l1.backgroundColor = [UIColor clearColor]; base = l1;
                UILabel *l2 = [[UILabel alloc] init]; l2.text = src.text; l2.font = src.font; l2.textAlignment = src.textAlignment; l2.textColor = tint; l2.backgroundColor = [UIColor clearColor]; over = l2;
            }
            base.frame = fr; over.frame = fr; over.alpha = 0;
            [box addSubview:base]; [box addSubview:over];
            [clones addObject:@{@"v": over, @"x": @(mx)}];
        }
    }
    objc_setAssociatedObject(box, "clones", clones, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return box;
}

static void EnforceGhost(UITabBar *tb) {
    NSArray *hid = objc_getAssociatedObject(tb, kHidden);
    if (!hid || !tb.selectedItem) return;
    NSArray *btns = Buttons(tb);
    NSUInteger si = [tb.items indexOfObject:tb.selectedItem];
    if (si == NSNotFound || si >= btns.count) return;
    NSMutableArray *content = [NSMutableArray array]; CollectContent(btns[si], 0, content);
    BOOL stale = NO;
    for (UIView *v in content) if (![hid containsObject:v] || v.alpha != 0) { stale = YES; break; }
    if (stale) RebuildGhost(tb);
}

@implementation W12TabCtl {
    UISelectionFeedbackGenerator *_fb;
    NSInteger _lastNear;
    CADisplayLink *_link;
    __weak UITabBar *_tb;
    CGFloat _target, _cur, _cy, _minX, _maxX, _vel, _sx, _sy;
    NSUInteger _tok;      // bumps with every new touch: stale delayed animations from a previous touch must do nothing
    CFTimeInterval _lastT;
}
+ (instancetype)shared { static W12TabCtl *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [W12TabCtl new]; }); return s; }

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o { return YES; }

- (void)stopLink { [_link invalidate]; _link = nil; }

// Lens follows the finger with a soft spring-like lag and stretches a little with speed (feels like a drop of glass).
- (void)step:(CADisplayLink *)dl {
    UITabBar *tb = _tb;
    W12TabLens *lens = tb ? objc_getAssociatedObject(tb, kLens) : nil;
    if (!lens || !lens.superview) { [self stopLink]; return; }
    CFTimeInterval now = CACurrentMediaTime();
    CGFloat dt = MIN(0.05, MAX(0.001, now - _lastT)); _lastT = now;
    CGFloat k = 1.0 - powf(0.0006f, (float)dt);                 // frame-rate independent smoothing
    CGFloat prev = _cur;
    _cur += (_target - _cur) * k;
    _vel = (_cur - prev) / dt;
    CGFloat stretch = 1.0 + MIN(0.07, fabs(_vel) / 9000.0);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    lens.center = CGPointMake(_cur, _cy);
    lens.transform = CGAffineTransformMakeScale(_sx * stretch, _sy / (1.0 + (stretch - 1.0) * 0.5));
    [CATransaction commit];
    PlaceSnapshot(lens, tb, CGPointMake(_cur, _cy), TNum(@"tabMag", 1.30, 1.0, 1.9));
    [lens updateFill];
    NSArray *bb = Buttons(tb); if (bb.count) TintClones(lens, _cur, ((UIView *)bb[0]).frame.size.width);
    static unsigned fr = 0; if ((++fr & 3) == 0) EnforceGhost(tb);
}

- (void)handle:(UILongPressGestureRecognizer *)g {
    @try {
        UITabBar *tb = (UITabBar *)g.view;
        if (![tb isKindOfClass:[UITabBar class]] || !Eligible(tb)) return;
        NSArray *btns = Buttons(tb);
        if (btns.count != tb.items.count) return;
        CGRect pill = PillRect(tb, btns);
        W12TabLens *lens = objc_getAssociatedObject(tb, kLens);
        UIView *cap = objc_getAssociatedObject(tb, kCap);
        CGPoint p = [g locationInView:tb];
        CGFloat itemW = ((UIView *)btns[0]).frame.size.width;
        CGFloat lw = MIN(itemW + 6, 96), lh = pill.size.height - 12;      // same size as the resting capsule; it inflates while held
        CGFloat cy = CGRectGetMidY(pill);
        CGFloat sx = 1.0 + (kInflate - 1.0) * 0.7, sy = MIN(kInflate, (pill.size.height + 16) / lh);   // narrower than tall: sticks out only a little sideways     // stay inside the pill vertically
        CGFloat over = 12;                                               // like iOS 26: the glass may poke out of the bar at both ends
        CGFloat minX = pill.origin.x + lw * sx * 1.04 / 2 - over, maxX = CGRectGetMaxX(pill) - lw * sx * 1.04 / 2 + over;
        CGFloat cx = MAX(minX, MIN(maxX, p.x));
        BOOL dark = [objc_getAssociatedObject(tb, kDark) boolValue];

        if (g.state == UIGestureRecognizerStateBegan) {
            if (!TBool(@"tabLens", YES)) return;
            _tok++;
            ReleaseGhost(tb);      // a quick spam of taps leaves the previous ghost alive: its hidden (alpha 0) icon would be cloned as nothing => empty lens
            [lens.layer removeAllAnimations]; [lens removeFromSuperview];
            if (cap) { [cap.layer removeAllAnimations]; cap.alpha = 0; }     // the selected (grey) capsule disappears at once while the glass is held
            lens = [[W12TabLens alloc] init];
            objc_setAssociatedObject(tb, kLens, lens, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            lens.lightRim = !dark;
            [lens setDark:dark];
            lens.layer.shadowOpacity = dark ? 0.0 : 0.22;       // light bar: a soft shadow lifts the white glass off the bar
            lens.bounds = CGRectMake(0, 0, lw, lh);
            // the glass starts on the tab that is selected now and flies to the finger / the tapped tab
            CGFloat startX = cx;
            if (tb.selectedItem) {
                NSUInteger si = [tb.items indexOfObject:tb.selectedItem];
                if (si != NSNotFound && si < btns.count) startX = MAX(pill.origin.x + lw / 2, MIN(CGRectGetMaxX(pill) - lw / 2, CGRectGetMidX(((UIView *)btns[si]).frame)));
            }
            lens.center = CGPointMake(startX, cy);
            UIColor *rim __unused = tb.tintColor ?: [UIColor colorWithRed:0 green:0.48 blue:1 alpha:1];
            lens.tint.backgroundColor = [UIColor clearColor];   // glass: the bar edge comes from the magnified clone
            lens.rimTint.hidden = YES; lens.rimGlass.hidden = NO; lens.rimTint.strokeColor = (dark ? [UIColor colorWithWhite:0.7 alpha:0.6] : [UIColor colorWithWhite:0.5 alpha:0.55]).CGColor;
            
            {
                NSMutableArray *bx = [NSMutableArray array];
                [bx addObject:BuildLensEdge(tb, btns)]; [bx addObject:BuildLensContent(tb, btns)];   // edge (true size) + magnified content
                [lens installRings:bx];
                [lens layoutIfNeeded];
                PlaceSnapshot(lens, tb, CGPointMake(startX, cy), TNum(@"tabMag", 1.30, 1.0, 1.9));
                TintClones(lens, startX, itemW);
            }
            lens.barRect = pill; lens.hasBarRect = YES; [lens updateFill];
            [tb addSubview:lens];
            RebuildGhost(tb);
            SetSwell(tb, 1.05, pill);
            lens.alpha = 0; lens.transform = CGAffineTransformMakeScale(0.7, 0.7);
            [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.72 initialSpringVelocity:0.5 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
                lens.alpha = 1; lens.transform = CGAffineTransformMakeScale(sx, sy);
            } completion:nil];
            for (int i = 1; i <= 8; i++) {      // the pop-in animates the lens transform: keep the frosted fill glued to the bar until the main loop starts
                W12TabLens *lr = lens;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.016 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (lr.superview) [lr updateFill]; });
            }
            _fb = [UISelectionFeedbackGenerator new]; [_fb prepare];
            _lastNear = NearestIndex(btns, p.x);
            _sx = sx; _sy = sy; _tb = tb; _cur = startX; _target = cx; _cy = cy; _minX = minX; _maxX = maxX; _vel = 0; _lastT = CACurrentMediaTime();
            [self stopLink];
            _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
            // start after the pop-in so the transform animation is not fought with
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self->_link) [self->_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            });
            return;
        }
        if (!lens) return;
        if (g.state == UIGestureRecognizerStateChanged) {
            _target = cx; _cy = cy; _minX = minX; _maxX = maxX;
            NSInteger n = NearestIndex(btns, cx);
            if (n != _lastNear && n >= 0) { _lastNear = n; [_fb selectionChanged]; [_fb prepare]; }   // only a tick, the tab stays put
            return;
        }
        if (g.state == UIGestureRecognizerStateEnded) {
            [self stopLink];
            SetSwell(tb, 1.0, pill);                                 // the bar relaxes back with a spring
            NSInteger idx = NearestIndex(btns, _target);               // the slot nearest to where the finger was released
            if (idx < 0) idx = 0;
            Select(tb, (NSUInteger)idx);
            [tb layoutIfNeeded];
            btns = Buttons(tb);
            RebuildGhost(tb);                                      // the newly selected item also stays grey until the glass lands on it
            CGFloat tx = MAX(pill.origin.x + lw / 2, MIN(CGRectGetMaxX(pill) - lw / 2, CGRectGetMidX(((UIView *)btns[idx]).frame)));   // exactly where the resting capsule sits (no inflate margin)
            CGFloat dist = tx - _cur;
            CGFloat v0 = fabs(dist) > 3 ? MAX(-3.0, MIN(3.0, _vel / dist)) : 0;      // carry the finger's momentum into the spring
            [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:v0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
                lens.center = CGPointMake(tx, cy);
            } completion:nil];
            [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.62 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
                lens.transform = CGAffineTransformIdentity;          // the stretched drop relaxes with a tiny wobble
            } completion:nil];
            NSUInteger tok = _tok;
            CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:self selector:@selector(follow:)];
            objc_setAssociatedObject(dl, "tb", tb, OBJC_ASSOCIATION_ASSIGN);
            objc_setAssociatedObject(dl, "tok", @(tok), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(dl, "t0", @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            W12TabLens *lensRef = lens; UIView *capRef = cap;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.34 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (tok != self->_tok) return;                       // a new touch started: that touch owns lens and capsule now
                ReleaseGhost(tb);                                    // the chosen item gets its colour back as the glass melts into it
                [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
                    lensRef.alpha = 0; lensRef.transform = CGAffineTransformMakeScale(0.96, 0.96); capRef.alpha = 1;
                } completion:^(BOOL f) {
                    if (tok != self->_tok) return;
                    [lensRef removeFromSuperview]; capRef.alpha = 1;
                }];
            });
            return;
        }
        // cancelled / failed
        [self stopLink];
        SetSwell(tb, 1.0, pill);
        {
            NSUInteger tok = _tok; W12TabLens *lensRef = lens; UIView *capRef = cap;
            ReleaseGhost(tb);
            [UIView animateWithDuration:0.2 animations:^{ lensRef.alpha = 0; capRef.alpha = 1; } completion:^(BOOL f) {
                if (tok != self->_tok) return;
                [lensRef removeFromSuperview]; capRef.alpha = 1;
            }];
        }
    } @catch (NSException *e) { TLog(@"gesture: %@", e.reason); }
}

- (void)follow:(CADisplayLink *)dl {
    UITabBar *tb = objc_getAssociatedObject(dl, "tb");
    CFTimeInterval t0 = [objc_getAssociatedObject(dl, "t0") doubleValue];
    W12TabLens *lens = tb ? objc_getAssociatedObject(tb, kLens) : nil;
    if (!lens || !lens.superview || CACurrentMediaTime() - t0 > 0.85 || [objc_getAssociatedObject(dl, "tok") unsignedIntegerValue] != _tok) { [dl invalidate]; return; }
    CALayer *pl = lens.layer.presentationLayer;
    if (!pl) return;
    CGFloat u = MIN(1.0, (CACurrentMediaTime() - t0) / 0.5); u = u * u * (3 - 2 * u);
    CGFloat mag = 1.0 + (TNum(@"tabMag", 1.30, 1.0, 1.9) - 1.0) * (1.0 - 0.55 * u);   // magnification eases off while it settles
    PlaceSnapshot(lens, tb, pl.position, mag);
    [lens updateFill];
    NSArray *bb = Buttons(tb); if (bb.count) TintClones(lens, pl.position.x, ((UIView *)bb[0]).frame.size.width);
}
@end

#pragma mark - Styling

static const void *kUT = &kUT, *kOwnT = &kOwnT, *kSwell = &kSwell;
// Lift the bar so the glass floats above the bottom edge; the app's own transform (if any) is kept underneath ours.
static void ApplyLift(UITabBar *tb, CGRect pill) {
    BOOL std = [tb.delegate isKindOfClass:[UITabBarController class]] && ((UITabBarController *)tb.delegate).tabBar == tb;
    double lift = MAX(6.0, std ? TNum(@"tabLiftStd", 14, 0, 60) : TNum(@"tabLift", 40, 0, 60));
    CGFloat gap = tb.bounds.size.height - CGRectGetMaxY(pill);
    CGFloat ty = -(lift - gap);
    NSValue *uv = objc_getAssociatedObject(tb, kUT);
    CGAffineTransform ut = uv ? [uv CGAffineTransformValue] : CGAffineTransformIdentity;
    if (tb.superview && tb.window) {   // the glass must never leave the screen (Sileo & co. move/resize their bar themselves)
        CGPoint o = [tb.superview convertPoint:CGPointMake(tb.center.x - tb.bounds.size.width / 2, tb.center.y - tb.bounds.size.height / 2) toView:tb.window];
        CGFloat H = MIN(tb.window.bounds.size.height, [UIScreen mainScreen].bounds.size.height);
        CGFloat bottom = o.y + CGRectGetMaxY(pill) + ut.ty;
        CGFloat maxTy = H - lift - bottom;
        if (ty > maxTy) ty = maxTy;
    }
    objc_setAssociatedObject(tb, kTy, @(ty), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGAffineTransform t = CGAffineTransformConcat(ut, CGAffineTransformMakeTranslation(0, ty));
    if (!CGAffineTransformEqualToTransform(tb.transform, t)) {
        objc_setAssociatedObject(tb, kOwnT, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tb.transform = t;
        objc_setAssociatedObject(tb, kOwnT, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}


// Item colours that stay readable on the translucent glass: dark grey / white for the unselected items (the app's light grey vanishes on a
// see-through bar), the app's own selected colour pushed to a clearly visible brightness. The app's originals are kept and restored.
static const void *kOrigTint = &kOrigTint, *kOrigUns = &kOrigUns, *kColSig = &kColSig;
static void ApplyItemColors(UITabBar *tb, BOOL dark) {
    if (objc_getAssociatedObject(tb, kHidden)) return;                   // never while the glass is held (ghost copies read the colours)
    NSNumber *sig = @(dark);
    if ([objc_getAssociatedObject(tb, kColSig) isEqual:sig]) return;
    if (!objc_getAssociatedObject(tb, kOrigTint)) {
        objc_setAssociatedObject(tb, kOrigTint, tb.tintColor ?: (id)[NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIColor *u = nil; if (@available(iOS 10.0, *)) u = tb.unselectedItemTintColor;
        objc_setAssociatedObject(tb, kOrigUns, u ?: (id)[NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    id ot = objc_getAssociatedObject(tb, kOrigTint);
    UIColor *base = [ot isKindOfClass:[UIColor class]] ? ot : [UIColor colorWithRed:0 green:0.48 blue:1 alpha:1];
    if (@available(iOS 10.0, *)) tb.unselectedItemTintColor = dark ? [UIColor colorWithWhite:1 alpha:0.74] : [UIColor colorWithWhite:0.16 alpha:0.78];
    CGFloat h, s, b, a;
    if (Colourful(base) && [base getHue:&h saturation:&s brightness:&b alpha:&a]) {
        UIColor *sel = dark ? [UIColor colorWithHue:h saturation:MIN(s, 0.85) brightness:MAX(b, 1.0) alpha:1]
                            : [UIColor colorWithHue:h saturation:MAX(s, 0.8) brightness:MIN(b, 0.80) alpha:1];
        tb.tintColor = sel;
    }
    objc_setAssociatedObject(tb, kColSig, sig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void RestoreItemColors(UITabBar *tb) {
    if (!objc_getAssociatedObject(tb, kColSig)) return;
    id ot = objc_getAssociatedObject(tb, kOrigTint), ou = objc_getAssociatedObject(tb, kOrigUns);
    tb.tintColor = [ot isKindOfClass:[UIColor class]] ? ot : nil;
    if (@available(iOS 10.0, *)) tb.unselectedItemTintColor = [ou isKindOfClass:[UIColor class]] ? ou : nil;
    objc_setAssociatedObject(tb, kColSig, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tb, kOrigTint, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tb, kOrigUns, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void StyleTabBar(UITabBar *tb) {
    if (!Eligible(tb)) {
        RestoreItemColors(tb);
        W12TabBack *old = objc_getAssociatedObject(tb, kBack);
        if (old && old.superview) { old.hidden = YES; }
        if (objc_getAssociatedObject(tb, kConf)) {          // rotated / hidden / switched off: give the stock look back
            tb.backgroundImage = nil; tb.shadowImage = nil;
            if (!CGAffineTransformIsIdentity(tb.transform)) tb.transform = CGAffineTransformIdentity;
            UIView *c = objc_getAssociatedObject(tb, kCap); c.hidden = YES;
            objc_setAssociatedObject(tb, kConf, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    NSArray *btns = Buttons(tb);
    if (!btns.count) return;
    for (UIView *hv in objc_getAssociatedObject(tb, kHidden) ?: @[]) if (hv.alpha != 0) hv.alpha = 0;

    if (!objc_getAssociatedObject(tb, kConf)) {
        objc_setAssociatedObject(tb, kConf, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tb.backgroundImage = [UIImage new];
        tb.shadowImage = [UIImage new];
        tb.backgroundColor = [UIColor clearColor];
        tb.clipsToBounds = NO;
        if (!objc_getAssociatedObject(tb, kGR)) {
        UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:[W12TabCtl shared] action:@selector(handle:)];
        g.minimumPressDuration = 0; g.allowableMovement = CGFLOAT_MAX;
        g.cancelsTouchesInView = NO; g.delaysTouchesBegan = NO; g.delaysTouchesEnded = NO;
        g.delegate = [W12TabCtl shared];
        [tb addGestureRecognizer:g];
        objc_setAssociatedObject(tb, kGR, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        TLog(@"styled tab bar in %@ (%lu items)", [NSBundle mainBundle].bundleIdentifier, (unsigned long)tb.items.count);
    }

    for (UIView *sv in tb.subviews) {                       // stock bar background / hairline (some apps keep a grey fill)
        NSString *cn = NSStringFromClass([sv class]);
        if ([cn containsString:@"BarBackground"] || [cn containsString:@"Backdrop"] || [cn containsString:@"_UIBarBackground"] || [cn containsString:@"HairlineView"]) {
            if (!sv.hidden) sv.hidden = YES;
        }
    }
    {   // any other full-width fill inside the bar (custom backgrounds, e.g. Messenger) would travel with the lift as a stray strip
        for (UIView *sv in tb.subviews) {
            if ([btns containsObject:sv] || [sv isKindOfClass:[W12TabBack class]] || [sv isKindOfClass:[W12TabLens class]] || sv == objc_getAssociatedObject(tb, kCap)) continue;
            BOOL wide = sv.bounds.size.width >= tb.bounds.size.width * 0.9 && sv.bounds.size.height >= 20;
            BOOL plain = [sv isKindOfClass:[UIVisualEffectView class]] || [sv isKindOfClass:[UIImageView class]] || sv.subviews.count == 0 || [NSStringFromClass([sv class]) containsString:@"Background"];
            if (wide && plain && sv.alpha > 0) sv.alpha = 0;
        }
        tb.barTintColor = nil; tb.layer.backgroundColor = nil;
    }
    NSNumber *autoD = objc_getAssociatedObject(tb, kAuto);
    BOOL dark = autoD ? autoD.boolValue : IsDark(tb);      // the sampled background wins once it has been measured
    BOOL darkChanged = objc_getAssociatedObject(tb, kDark) && [objc_getAssociatedObject(tb, kDark) boolValue] != dark;
    objc_setAssociatedObject(tb, kDark, @(dark), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApplyItemColors(tb, dark);
    if (!objc_getAssociatedObject(tb, kAutoTimer)) {      // watch the content behind the bar every 0.6 s (first look after 0.2 s)
        __weak UITabBar *wtb = tb;
        NSTimer *tm = [NSTimer timerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *t) {
            UITabBar *s = wtb; if (!s) { [t invalidate]; return; }
            AutoDarkTick(s);
        }];
        tm.tolerance = 0.03;
        [[NSRunLoop mainRunLoop] addTimer:tm forMode:NSRunLoopCommonModes];
        objc_setAssociatedObject(tb, kAutoTimer, tm, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ UITabBar *s = wtb; if (s) AutoDarkTick(s); });
    }
    CGRect pill = PillRect(tb, btns);

    W12TabBack *back = objc_getAssociatedObject(tb, kBack);
    if (!back) {
        back = [[W12TabBack alloc] init];
        objc_setAssociatedObject(tb, kBack, back, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    back.hidden = NO;
    if (back.superview != tb) [tb insertSubview:back atIndex:0];
    else if ([tb.subviews indexOfObject:back] != 0) [tb sendSubviewToBack:back];
    back.frame = pill;
    UIBlurEffectStyle st = dark ? UIBlurEffectStyleDark : UIBlurEffectStyleLight;    // Light is clearly more see-through than ExtraLight
    if (darkChanged) [UIView animateWithDuration:0.18 animations:^{ back.blur.effect = [UIBlurEffect effectWithStyle:st]; }];
    else if (!back.blur.effect || ![objc_getAssociatedObject(back, kDark) isEqual:@(dark)]) back.blur.effect = [UIBlurEffect effectWithStyle:st];
    objc_setAssociatedObject(back, kDark, @(dark), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    back.darkMode = dark; [back applyTint];
    { __weak W12TabBack *wb = back; dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [wb applyTint]; }); }
    if (back.lightRim != !dark) { back.lightRim = !dark; back.rimStale = YES; [back setNeedsLayout]; }
    back.blur.layer.borderWidth = 0;
    back.layer.shadowOpacity = dark ? 0.35 : 0.16;

    // spread the buttons evenly INSIDE the pill so every item (also the first and last) has room around it
    if (btns.count == tb.items.count) {
        CGFloat padIn = 8, iw = (pill.size.width - 2 * padIn) / btns.count;
        for (NSUInteger i = 0; i < btns.count; i++) {
            UIView *b = btns[i]; CGRect f = b.frame;
            CGRect nf = CGRectMake(pill.origin.x + padIn + i * iw, f.origin.y, iw, f.size.height);
            if (!CGRectEqualToRect(f, nf)) b.frame = nf;
        }
    }

    // selected capsule
    UIView *cap = objc_getAssociatedObject(tb, kCap);
    if (!cap) {
        cap = [[UIView alloc] init]; cap.userInteractionEnabled = NO;
        objc_setAssociatedObject(tb, kCap, cap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (cap.superview != tb) [tb insertSubview:cap aboveSubview:back];
    cap.backgroundColor = dark ? [UIColor colorWithWhite:1 alpha:0.16] : [UIColor colorWithWhite:0 alpha:0.07];
    NSUInteger sel = tb.selectedItem ? [tb.items indexOfObject:tb.selectedItem] : NSNotFound;
    if (btns.count == tb.items.count && sel != NSNotFound && sel < btns.count) {
        CGRect bf = [(UIView *)btns[sel] frame];
        CGFloat w = MIN(bf.size.width + 6, 96), ch = pill.size.height - 12;      // flat capsule
        CGRect cr = CGRectMake(CGRectGetMidX(bf) - w / 2, CGRectGetMidY(pill) - ch / 2, w, ch);
        NSNumber *last = objc_getAssociatedObject(tb, kIdx);
        cap.hidden = NO; cap.layer.cornerRadius = cr.size.height / 2;
        BOOL lensOn = [(UIView *)objc_getAssociatedObject(tb, kLens) superview] != nil;
        if (lensOn) { cap.frame = cr; }
        else if (last && last.unsignedIntegerValue != sel) {
            [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{ cap.frame = cr; } completion:nil];
        } else if (![cap.layer animationForKey:@"position"] && !(last && cap.layer.animationKeys.count)) {
            cap.frame = cr;
        }
        objc_setAssociatedObject(tb, kIdx, @(sel), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else cap.hidden = YES;

    ApplyLift(tb, pill);
    {   // the lifted bar may now stick out of its container: let the containers accept touches there
        __weak UITabBar *wtb = tb;
        id getter = [^UITabBar *{ return wtb; } copy];
        UIView *v = tb.superview;
        for (int i = 0; i < 4 && v && v != (UIView *)tb.window; i++, v = v.superview) objc_setAssociatedObject(v, kHost, getter, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (tb.superview) { UIView *l = objc_getAssociatedObject(tb, kLens); if (l && l.superview == tb) [tb bringSubviewToFront:l]; }
}

void W12TabBarInit(void);
void W12TabBarInit(void) {
    @try {
        {   // containers of a lifted tab bar also own the touches that land on the bar
            Class vc = [UIView class]; SEL ps = @selector(pointInside:withEvent:);
            Method pm = class_getInstanceMethod(vc, ps);
            if (pm) {
                IMP po = method_getImplementation(pm);
                class_replaceMethod(vc, ps, imp_implementationWithBlock(^BOOL(UIView *self, CGPoint p, UIEvent *e) {
                    if (((BOOL (*)(id, SEL, CGPoint, id))po)(self, ps, p, e)) return YES;
                    id g = objc_getAssociatedObject(self, kHost);
                    if (!g) return NO;
                    UITabBar *tb = ((UITabBar *(^)(void))g)();
                    if (!tb || tb.hidden || tb.window != self.window || !objc_getAssociatedObject(tb, kConf)) return NO;
                    CGRect r = [self convertRect:tb.bounds fromView:tb];
                    return CGRectContainsPoint(CGRectInset(r, 0, -16), p);
                }), method_getTypeEncoding(pm));
            }
        }
        {   // let the floating pill (which pokes out of the stock bar frame) take touches too
            Class tc = [UITabBar class]; SEL ps = @selector(pointInside:withEvent:);
            Method pm = class_getInstanceMethod(tc, ps);
            if (pm) {
                IMP po = method_getImplementation(pm);
                class_replaceMethod(tc, ps, imp_implementationWithBlock(^BOOL(UITabBar *self, CGPoint p, UIEvent *e) {
                    if (((BOOL (*)(id, SEL, CGPoint, id))po)(self, ps, p, e)) return YES;
                    if (!objc_getAssociatedObject(self, kConf) || self.hidden) return NO;
                    return CGRectContainsPoint(CGRectInset(self.bounds, 0, -16), p);
                }), method_getTypeEncoding(pm));
            }
        }
        {   // the app (Sileo, ...) may set the bar's transform / position itself: keep our lift on top of it
            Class tc = [UITabBar class]; SEL ts = @selector(setTransform:);
            Method tm = class_getInstanceMethod(tc, ts);
            if (tm) {
                IMP to = method_getImplementation(tm);
                class_replaceMethod(tc, ts, imp_implementationWithBlock(^(UITabBar *self, CGAffineTransform t) {
                    if (objc_getAssociatedObject(self, kConf) && !objc_getAssociatedObject(self, kOwnT)) {
                        objc_setAssociatedObject(self, kUT, [NSValue valueWithCGAffineTransform:t], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        t = CGAffineTransformConcat(t, CGAffineTransformMakeTranslation(0, [objc_getAssociatedObject(self, kTy) doubleValue]));   // keep our lift under it
                    }
                    ((void (*)(id, SEL, CGAffineTransform))to)(self, ts, t);
                }), method_getTypeEncoding(tm));
            }
            {
                SEL ss = @selector(setCenter:); Method sm = class_getInstanceMethod(tc, ss);
                if (sm) { IMP so = method_getImplementation(sm);
                    class_replaceMethod(tc, ss, imp_implementationWithBlock(^(UITabBar *self, CGPoint p) {
                        ((void (*)(id, SEL, CGPoint))so)(self, ss, p);
                        if (objc_getAssociatedObject(self, kConf) && self.window) { NSArray *b = Buttons(self); if (b.count) ApplyLift(self, PillRect(self, b)); }
                    }), method_getTypeEncoding(sm)); }
                SEL fs = @selector(setFrame:); Method fm = class_getInstanceMethod(tc, fs);
                if (fm) { IMP fo = method_getImplementation(fm);
                    class_replaceMethod(tc, fs, imp_implementationWithBlock(^(UITabBar *self, CGRect r) {
                        ((void (*)(id, SEL, CGRect))fo)(self, fs, r);
                        if (objc_getAssociatedObject(self, kConf) && self.window) { NSArray *b = Buttons(self); if (b.count) ApplyLift(self, PillRect(self, b)); }
                    }), method_getTypeEncoding(fm)); }
            }
        }
        Class c = [UITabBar class];
        SEL s = @selector(layoutSubviews);
        Method m = class_getInstanceMethod(c, s);
        if (!m) return;
        IMP orig = method_getImplementation(m);
        IMP imp = imp_implementationWithBlock(^(UITabBar *self) {
            ((void (*)(id, SEL))orig)(self, s);
            @try { StyleTabBar(self); } @catch (NSException *e) { TLog(@"style: %@", e.reason); }
        });
        class_replaceMethod(c, s, imp, method_getTypeEncoding(m));
        TLog(@"tab bar hook ready in %@", [NSBundle mainBundle].bundleIdentifier);
    } @catch (NSException *e) { TLog(@"init failed: %@", e.reason); }
}
