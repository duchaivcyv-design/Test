// iOS 26 style UISwitch for iOS 12: a wide white glass thumb on a pill track. The stock switch keeps doing all the work
// (touch handling, value, accessibility); this only paints an opaque skin on top of it and animates it like the tab bar lens
// (the thumb swells and turns glassy while pressed, then springs back / across).
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "W12Rim.h"

static void SLog(NSString *m) {
    FILE *f = fopen("/var/mobile/Library/Logs/Wave12.log", "a");
    if (f) { fprintf(f, "%.2f [switch] %s\n", CACurrentMediaTime(), m.UTF8String); fclose(f); }
}
static id SPref(NSString *k) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)k, CFSTR("com.wave12.unlockwave"));
    return CFBridgingRelease(v);
}
static BOOL SwitchSkinOn(void) {
    static CFTimeInterval at = -10; static BOOL on = YES; static NSArray *ex;
    CFTimeInterval n = CACurrentMediaTime();
    if (n - at > 1.5) {
        at = n;
        id e = SPref(@"enabled"), g = SPref(@"switchGlass");
        on = (!e || [e boolValue]) && (!g || [g boolValue]);
        (void)ex;     // the app exclusion list is for the card animations; switches look the same everywhere
    }
    return on;
}

@interface W12SwitchSkin : UIView
@property (nonatomic, strong) UIView *track, *thumb;
@property (nonatomic, strong) UIImageView *rim;
@property (nonatomic) BOOL pressed, isOn, placed;
@end

@implementation W12SwitchSkin
- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.userInteractionEnabled = NO;
        _track = [[UIView alloc] init]; _track.userInteractionEnabled = NO;
        _thumb = [[UIView alloc] init]; _thumb.userInteractionEnabled = NO;
        _thumb.backgroundColor = [UIColor whiteColor];
        _thumb.layer.cornerRadius = 100;                                   // clamped to a capsule at any size
        _thumb.layer.shadowColor = [UIColor blackColor].CGColor;
        _thumb.layer.shadowOpacity = 0.22; _thumb.layer.shadowRadius = 3; _thumb.layer.shadowOffset = CGSizeMake(0, 2);
        UIImage *ri = W12RimImageL(16.5, 16.5, NO, YES);
        CGFloat s = ri.size.width, c = s / 2 - 0.5;
        _rim = [[UIImageView alloc] initWithImage:[ri resizableImageWithCapInsets:UIEdgeInsetsMake(c, c, c, c)]];
        _rim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _rim.alpha = 0;
        [_thumb addSubview:_rim];
        [self addSubview:_track]; [self addSubview:_thumb];
    }
    return self;
}
static const CGFloat kExtra = 12;          // the iOS 26 switch is wider than the iOS 12 one: the skin grows to the left of the stock frame
- (CGRect)thumbFrameIn:(CGRect)b {
    CGFloat W = b.size.width + kExtra, tw = round(W * 0.60), th = b.size.height - 4;
    CGFloat w = tw + (_pressed ? 9 : 0), h = th + (_pressed ? 4 : 0);
    CGFloat x = _isOn ? b.size.width - 2 - w : 2 - kExtra;
    return CGRectMake(x, (b.size.height - h) / 2, w, h);
}
- (UIColor *)trackColorFor:(UISwitch *)sw {
    if (_isOn) return sw.onTintColor ?: [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1];
    return [UIColor colorWithWhite:0.80 alpha:1];
}
- (void)syncSwitch:(UISwitch *)sw animated:(BOOL)animated {
    CGRect b = sw.bounds;
    if (b.size.width < 10 || b.size.height < 10) return;
    BOOL on = sw.isOn;
    BOOL changed = (on != _isOn);
    _isOn = on;
    if (!CGRectEqualToRect(self.frame, b)) self.frame = b;
    self.alpha = sw.isEnabled ? 1 : 0.5;
    CGRect tf = [self thumbFrameIn:b];
    void (^apply)(void) = ^{
        self.track.frame = CGRectMake(-kExtra - 0.5, -0.5, b.size.width + kExtra + 1, b.size.height + 1);
        self.track.layer.cornerRadius = 100;
        self.track.backgroundColor = [self trackColorFor:sw];
        self.thumb.frame = tf;
        self.thumb.backgroundColor = [UIColor colorWithWhite:1 alpha:self.pressed ? 0.72 : 1];
        self.rim.alpha = self.pressed ? 1 : 0;
        self.thumb.layer.shadowOpacity = self.pressed ? 0.30 : 0.22;
    };
    if (animated && _placed && (changed || CGRectGetWidth(_thumb.frame) != tf.size.width)) {
        [UIView animateWithDuration:0.46 delay:0 usingSpringWithDamping:0.62 initialSpringVelocity:0.7
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:apply completion:nil];
    } else if (animated && _placed) {
        apply();
    } else {
        [UIView performWithoutAnimation:apply];
    }
    _placed = YES;
}
@end

static const void *kSkin = &kSkin, *kGest = &kGest;

@interface W12SwitchCtl : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
@end
@implementation W12SwitchCtl
+ (instancetype)shared { static W12SwitchCtl *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [W12SwitchCtl new]; }); return s; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o { return YES; }
- (void)press:(UILongPressGestureRecognizer *)g {
    UISwitch *sw = (UISwitch *)g.view;
    W12SwitchSkin *skin = objc_getAssociatedObject(sw, kSkin);
    if (!skin) return;
    BOOL down = (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged);
    if (skin.pressed == down) return;
    skin.pressed = down;
    // the stock switch flips its value a moment after the finger leaves: let that animation happen first, then settle the size
    [skin syncSwitch:sw animated:YES];
    if (!down) {
        __weak UISwitch *w = sw;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ UISwitch *s = w; W12SwitchSkin *k = s ? objc_getAssociatedObject(s, kSkin) : nil; if (k) [k syncSwitch:s animated:YES]; });
    }
}
@end

static void SkinAttach(UISwitch *sw) {
    W12SwitchSkin *skin = objc_getAssociatedObject(sw, kSkin);
    if (!SwitchSkinOn()) { skin.hidden = YES; return; }
    if (!skin) {
        skin = [[W12SwitchSkin alloc] init];
        objc_setAssociatedObject(sw, kSkin, skin, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:[W12SwitchCtl shared] action:@selector(press:)];
        g.minimumPressDuration = 0; g.allowableMovement = CGFLOAT_MAX; g.cancelsTouchesInView = NO; g.delaysTouchesBegan = NO; g.delaysTouchesEnded = NO;
        g.delegate = [W12SwitchCtl shared];
        [sw addGestureRecognizer:g];
        objc_setAssociatedObject(sw, kGest, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    skin.hidden = NO;
    { static int lg = 0; if (lg < 2 && skin.superview != sw) { lg++; SLog([NSString stringWithFormat:@"skin attached in %@", [NSBundle mainBundle].bundleIdentifier]); } }
    if (skin.superview != sw) [sw addSubview:skin];
    else if (sw.subviews.lastObject != skin) [sw bringSubviewToFront:skin];
    [skin syncSwitch:sw animated:NO];
}

void W12SwitchInit(void);
void W12SwitchInit(void) {
    SLog([NSString stringWithFormat:@"init in %@", [NSBundle mainBundle].bundleIdentifier]);
    @try {
        Class c = [UISwitch class];
        {
            SEL s = @selector(didMoveToWindow);
            Method m = class_getInstanceMethod(c, s); IMP o = method_getImplementation(m);
            class_replaceMethod(c, s, imp_implementationWithBlock(^(UISwitch *self) {
                ((void (*)(id, SEL))o)(self, s);
                if (self.window) SkinAttach(self);
            }), method_getTypeEncoding(m));
        }
        {
            SEL s = @selector(layoutSubviews);
            Method m = class_getInstanceMethod(c, s); IMP o = method_getImplementation(m);
            class_replaceMethod(c, s, imp_implementationWithBlock(^(UISwitch *self) {
                ((void (*)(id, SEL))o)(self, s);
                W12SwitchSkin *k = objc_getAssociatedObject(self, kSkin);
                if (self.window && (!k || !k.thumb.layer.animationKeys.count)) SkinAttach(self);      // never cut a running spring short
            }), method_getTypeEncoding(m));
        }
        {
            SEL s = @selector(setOn:animated:);
            Method m = class_getInstanceMethod(c, s); IMP o = method_getImplementation(m);
            class_replaceMethod(c, s, imp_implementationWithBlock(^(UISwitch *self, BOOL on, BOOL animated) {
                ((void (*)(id, SEL, BOOL, BOOL))o)(self, s, on, animated);
                W12SwitchSkin *k = objc_getAssociatedObject(self, kSkin);
                if (k && !k.hidden && self.window) [k syncSwitch:self animated:animated];
            }), method_getTypeEncoding(m));
        }
        {
            SEL s = @selector(setOnTintColor:);
            Method m = class_getInstanceMethod(c, s); IMP o = method_getImplementation(m);
            class_replaceMethod(c, s, imp_implementationWithBlock(^(UISwitch *self, UIColor *col) {
                ((void (*)(id, SEL, id))o)(self, s, col);
                W12SwitchSkin *k = objc_getAssociatedObject(self, kSkin);
                if (k && !k.hidden && self.window) [k syncSwitch:self animated:NO];
            }), method_getTypeEncoding(m));
        }
    } @catch (__unused id e) {}
}
