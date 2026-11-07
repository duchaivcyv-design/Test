// Wave12 settings, drawn in the style of the iOS 26 Settings app (dark glass cards, coloured icon tiles,
// large title, round back button, floating search pill). Runs inside the Preferences app on iOS 12.
// The whole page is custom UIKit (no UITableView / PSListController cells), only the principal class
// derives from PSViewController so that the Preferences app can host it.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import "W12L.h"

@interface PSViewController : UIViewController
@end

#define W12_DOMAIN CFSTR("com.wave12.unlockwave")
#define W12S2(x) @#x
#define W12S(x) W12S2(x)

static void PLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[Wave12Prefs] %@", m);
    FILE *f = fopen("/var/mobile/Library/Logs/Wave12.log", "a");
    if (f) { fprintf(f, "prefs: %s\n", m.UTF8String); fclose(f); }
}

#pragma mark - Preferences

static id PGet(NSString *k) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)k, W12_DOMAIN);
    return CFBridgingRelease(v);
}
static double PNum(NSString *k, double d) {
    id v = PGet(k);
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : d;
}
static void PSet(NSString *k, id v) {
    CFPreferencesSetAppValue((__bridge CFStringRef)k, (__bridge CFPropertyListRef)v, W12_DOMAIN);
    CFPreferencesAppSynchronize(W12_DOMAIN);
    notify_post("com.wave12.prefs");
}

static NSArray<NSString *> *AllKeys(void) {
    return @[@"enabled", @"unlock", @"home", @"speed", @"zoom", @"stagger", @"bounce",
             @"appanim", @"appExp", @"appBlur", @"home26", @"home26Edit", @"h26Snow", @"h26Ver", @"appCorner", @"appTilt", @"appTiltAxis",
             @"corners", @"cornerRadius", @"coverAlpha",
             @"passAnim", @"island", @"islandLive", @"islandFly", @"islandBorder", @"islandBorderW", @"islandVol", @"islandTorch", @"islandHideLand", @"faceID", @"faceStyle", @"faceLock", @"faceDelay", @"uiLang", @"islandW", @"islandH", @"islandY",
             @"sbOn", @"sbHideCarrier", @"sbHidePercent", @"sbTimeScale", @"sbTimeX", @"sbRightX", @"uiLight",
             @"exclude", @"ccGlass", @"ccRound", @"ccAlpha", @"alertGlass", @"tabOn", @"tabCustom", @"tabPad", @"tabAlpha", @"tabLens", @"tabLift", @"tabLiftStd", @"tabMag", @"tabInflate", @"lsClock", @"lsPad", @"lsNotif", @"lsClockAlpha", @"lsClockScale", @"lsNotifRadius"];
}

#pragma mark - Theme

static BOOL gLight = NO;

static UIColor *Hex(uint32_t h) {
    return [UIColor colorWithRed:((h >> 16) & 255) / 255.0 green:((h >> 8) & 255) / 255.0 blue:(h & 255) / 255.0 alpha:1];
}
static UIColor *Mix(uint32_t h, CGFloat t) {   // lighten towards white
    CGFloat r = ((h >> 16) & 255) / 255.0, g = ((h >> 8) & 255) / 255.0, b = (h & 255) / 255.0;
    return [UIColor colorWithRed:r + (1 - r) * t green:g + (1 - g) * t blue:b + (1 - b) * t alpha:1];
}
static UIColor *cText(void)   { return gLight ? [UIColor blackColor] : [UIColor whiteColor]; }
static UIColor *cSub(void)    { return gLight ? Hex(0x8E8E93) : [UIColor colorWithWhite:1 alpha:0.55]; }
static UIColor *cCard(void)   { return gLight ? [UIColor whiteColor] : [UIColor colorWithWhite:1 alpha:0.10]; }
static UIColor *cBorder(void) { return gLight ? [UIColor clearColor] : [UIColor colorWithWhite:1 alpha:0.08]; }
static UIColor *cSep(void)    { return gLight ? Hex(0xD1D1D6) : [UIColor colorWithWhite:1 alpha:0.12]; }
static UIColor *cHi(void)     { return gLight ? [UIColor colorWithWhite:0 alpha:0.07] : [UIColor colorWithWhite:1 alpha:0.14]; }
static UIColor *cAccent(void) { return Hex(0x0A84FF); }
static UIColor *cGreen(void)  { return Hex(0x34C759); }

#pragma mark - Drawn images

static UIImage *Icon(NSString *name, uint32_t color, CGFloat size, BOOL circle) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *ck = [NSString stringWithFormat:@"%@|%x|%.0f|%d", name, color, size, circle];
    UIImage *hit = cache[ck];
    if (hit) return hit;
    UIGraphicsImageRenderer *rd = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
    UIImage *img = [rd imageWithActions:^(UIGraphicsImageRendererContext *rc) {
        CGContextRef c = rc.CGContext;
        CGFloat k = size / 30.0;
        UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size, size) cornerRadius:circle ? size / 2 : 8 * k];
        [bg addClip];
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        NSArray *cols = @[(id)Mix(color, 0.22).CGColor, (id)Hex(color).CGColor];
        CGFloat locs[2] = {0, 1};
        CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)cols, locs);
        CGContextDrawLinearGradient(c, g, CGPointMake(0, 0), CGPointMake(0, size), 0);
        CGGradientRelease(g); CGColorSpaceRelease(cs);

        CGContextScaleCTM(c, k, k);
        UIColor *w = [UIColor whiteColor];
        [w setFill]; [w setStroke];
        UIBezierPath *p = [UIBezierPath bezierPath];
        p.lineCapStyle = kCGLineCapRound; p.lineJoinStyle = kCGLineJoinRound; p.lineWidth = 2.2;
        if ([name isEqualToString:@"bolt"]) {
            [p moveToPoint:CGPointMake(17.5, 5)]; [p addLineToPoint:CGPointMake(9, 16.8)]; [p addLineToPoint:CGPointMake(14.4, 16.8)];
            [p addLineToPoint:CGPointMake(12.5, 25)]; [p addLineToPoint:CGPointMake(21.2, 12.8)]; [p addLineToPoint:CGPointMake(15.6, 12.8)];
            [p closePath]; p.lineWidth = 1; [p fill]; [p stroke];
        } else if ([name isEqualToString:@"lock"]) {
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(8.5, 13.5, 13, 10) cornerRadius:2.6] fill];
            [p addArcWithCenter:CGPointMake(15, 12.2) radius:3.8 startAngle:M_PI endAngle:0 clockwise:YES];
            [p stroke];
        } else if ([name isEqualToString:@"app"]) {
            CGFloat xs[2] = {8, 16}, ys[2] = {8, 16};
            for (int i = 0; i < 2; i++) for (int j = 0; j < 2; j++)
                [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(xs[i], ys[j], 6.2, 6.2) cornerRadius:1.8] fill];
        } else if ([name isEqualToString:@"glass"]) {
            [p addArcWithCenter:CGPointMake(15, 15) radius:8 startAngle:0 endAngle:2 * M_PI clockwise:YES]; [p stroke];
            [[w colorWithAlphaComponent:0.4] setFill];
            [[UIBezierPath bezierPathWithArcCenter:CGPointMake(15, 15) radius:5 startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];
        } else if ([name isEqualToString:@"island"]) {
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(6, 11.5, 18, 7.5) cornerRadius:3.75] fill];
        } else if ([name isEqualToString:@"bars"]) {
            CGFloat hs[4] = {5, 9, 13, 17};
            for (int i = 0; i < 4; i++) [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(6 + i * 5, 23 - hs[i], 3, hs[i]) cornerRadius:1] fill];
        } else if ([name isEqualToString:@"wave"]) {
            CGFloat rs[3] = {4.5, 8.5, 12.5};
            for (int i = 0; i < 3; i++) {
                UIBezierPath *a = [UIBezierPath bezierPathWithArcCenter:CGPointMake(15, 21.5) radius:rs[i] startAngle:1.22 * M_PI endAngle:1.78 * M_PI clockwise:YES];
                a.lineWidth = 2.2; a.lineCapStyle = kCGLineCapRound; [a stroke];
            }
            [[UIBezierPath bezierPathWithArcCenter:CGPointMake(15, 21.5) radius:1.7 startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];
        } else if ([name isEqualToString:@"speed"]) {
            [p addArcWithCenter:CGPointMake(15, 17) radius:9 startAngle:0.85 * M_PI endAngle:2.15 * M_PI clockwise:YES]; [p stroke];
            UIBezierPath *n = [UIBezierPath bezierPath]; n.lineWidth = 2.2; n.lineCapStyle = kCGLineCapRound;
            [n moveToPoint:CGPointMake(15, 17)]; [n addLineToPoint:CGPointMake(19.8, 11.5)]; [n stroke];
            [[UIBezierPath bezierPathWithArcCenter:CGPointMake(15, 17) radius:2 startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];
        } else if ([name isEqualToString:@"corner"]) {
            p.lineWidth = 2.6;
            [p moveToPoint:CGPointMake(8, 23)]; [p addLineToPoint:CGPointMake(8, 14.5)];
            [p addArcWithCenter:CGPointMake(14.5, 14.5) radius:6.5 startAngle:M_PI endAngle:1.5 * M_PI clockwise:YES];
            [p addLineToPoint:CGPointMake(23, 8)]; [p stroke];
        } else if ([name isEqualToString:@"tilt"]) {
            [p moveToPoint:CGPointMake(9, 10)]; [p addLineToPoint:CGPointMake(22, 7.5)]; [p addLineToPoint:CGPointMake(21, 21)];
            [p addLineToPoint:CGPointMake(8, 23.5)]; [p closePath];
            [[w colorWithAlphaComponent:0.28] setFill]; [p fill]; [w setStroke]; [p stroke];
        } else if ([name isEqualToString:@"sun"]) {
            [[UIBezierPath bezierPathWithArcCenter:CGPointMake(15, 15) radius:4.2 startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];
            for (int i = 0; i < 8; i++) {
                CGFloat a = i * M_PI / 4;
                UIBezierPath *r = [UIBezierPath bezierPath]; r.lineWidth = 2; r.lineCapStyle = kCGLineCapRound;
                [r moveToPoint:CGPointMake(15 + cos(a) * 7.8, 15 + sin(a) * 7.8)];
                [r addLineToPoint:CGPointMake(15 + cos(a) * 10, 15 + sin(a) * 10)]; [r stroke];
            }
        } else if ([name isEqualToString:@"power"]) {
            p.lineWidth = 2.4;
            [p addArcWithCenter:CGPointMake(15, 15.5) radius:7.5 startAngle:-M_PI_2 + 0.7 endAngle:-M_PI_2 - 0.7 + 2 * M_PI clockwise:YES]; [p stroke];
            UIBezierPath *l = [UIBezierPath bezierPath]; l.lineWidth = 2.4; l.lineCapStyle = kCGLineCapRound;
            [l moveToPoint:CGPointMake(15, 6.5)]; [l addLineToPoint:CGPointMake(15, 14.5)]; [l stroke];
        } else if ([name isEqualToString:@"reset"]) {
            [p addArcWithCenter:CGPointMake(15, 15) radius:7.5 startAngle:-0.35 * M_PI endAngle:1.2 * M_PI clockwise:YES]; [p stroke];
            UIBezierPath *t = [UIBezierPath bezierPath];
            [t moveToPoint:CGPointMake(13.8, 5.6)]; [t addLineToPoint:CGPointMake(19.9, 5.4)]; [t addLineToPoint:CGPointMake(16.9, 11.2)]; [t closePath]; [t fill];
        } else if ([name isEqualToString:@"info"]) {
            [p addArcWithCenter:CGPointMake(15, 15) radius:8.5 startAngle:0 endAngle:2 * M_PI clockwise:YES]; [p stroke];
            [[UIBezierPath bezierPathWithArcCenter:CGPointMake(15, 10.6) radius:1.3 startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];
            UIBezierPath *l = [UIBezierPath bezierPath]; l.lineWidth = 2.2; l.lineCapStyle = kCGLineCapRound;
            [l moveToPoint:CGPointMake(15, 14)]; [l addLineToPoint:CGPointMake(15, 20)]; [l stroke];
        }
    }];
    cache[ck] = img;
    return img;
}

static UIImage *Draw(CGSize sz, void (^blk)(CGContextRef c)) {
    UIGraphicsImageRenderer *rd = [[UIGraphicsImageRenderer alloc] initWithSize:sz];
    return [rd imageWithActions:^(UIGraphicsImageRendererContext *rc) { blk(rc.CGContext); }];
}
static UIImage *ChevronRight(UIColor *col) {
    return Draw(CGSizeMake(9, 15), ^(CGContextRef c) {
        UIBezierPath *p = [UIBezierPath bezierPath]; p.lineWidth = 2; p.lineCapStyle = kCGLineCapRound; p.lineJoinStyle = kCGLineJoinRound;
        [p moveToPoint:CGPointMake(1.5, 1.5)]; [p addLineToPoint:CGPointMake(7, 7.5)]; [p addLineToPoint:CGPointMake(1.5, 13.5)];
        [col setStroke]; [p stroke];
    });
}
static UIImage *ChevronLeft(UIColor *col) {
    return Draw(CGSizeMake(12, 20), ^(CGContextRef c) {
        UIBezierPath *p = [UIBezierPath bezierPath]; p.lineWidth = 2.6; p.lineCapStyle = kCGLineCapRound; p.lineJoinStyle = kCGLineJoinRound;
        [p moveToPoint:CGPointMake(9.5, 2)]; [p addLineToPoint:CGPointMake(2.5, 10)]; [p addLineToPoint:CGPointMake(9.5, 18)];
        [col setStroke]; [p stroke];
    });
}
static UIImage *Magnifier(UIColor *col) {
    return Draw(CGSizeMake(20, 20), ^(CGContextRef c) {
        UIBezierPath *p = [UIBezierPath bezierPathWithArcCenter:CGPointMake(8.5, 8.5) radius:6 startAngle:0 endAngle:2 * M_PI clockwise:YES];
        p.lineWidth = 2; p.lineCapStyle = kCGLineCapRound;
        [p moveToPoint:CGPointMake(13, 13)]; [p addLineToPoint:CGPointMake(18, 18)];
        [col setStroke]; [p stroke];
    });
}
static UIImage *Mic(UIColor *col) {
    return Draw(CGSizeMake(18, 22), ^(CGContextRef c) {
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(5.5, 1.5, 7, 12) cornerRadius:3.5];
        p.lineWidth = 1.8;
        UIBezierPath *a = [UIBezierPath bezierPath]; a.lineWidth = 1.8; a.lineCapStyle = kCGLineCapRound;
        [a addArcWithCenter:CGPointMake(9, 11) radius:6.5 startAngle:0 endAngle:M_PI clockwise:YES];
        [a moveToPoint:CGPointMake(9, 17.5)]; [a addLineToPoint:CGPointMake(9, 20.5)];
        [col setStroke]; [p stroke]; [a stroke];
    });
}

#pragma mark - Model

static NSDictionary *Sw(NSString *t, NSString *k, BOOL d, NSString *ic, uint32_t c) {
    return @{@"type": @"switch", @"title": t, @"key": k, @"def": @(d), @"icon": ic ?: @"", @"color": @(c)};
}
static NSDictionary *Sl(NSString *t, NSString *k, double d, double mn, double mx, NSString *fmt, NSString *ic, uint32_t c) {
    return @{@"type": @"slider", @"title": t, @"key": k, @"def": @(d), @"min": @(mn), @"max": @(mx), @"fmt": fmt, @"icon": ic ?: @"", @"color": @(c)};
}
static NSDictionary *Sg(NSString *t, NSString *k, double d, NSArray *titles, NSArray *vals, NSString *ic, uint32_t c) {
    return @{@"type": @"segment", @"title": t, @"key": k, @"def": @(d), @"titles": titles, @"values": vals, @"icon": ic ?: @"", @"color": @(c)};
}
static NSDictionary *Lk(NSString *t, NSString *page, NSString *ic, uint32_t c, NSString *subkey) {
    return @{@"type": @"link", @"title": t, @"page": page, @"icon": ic ?: @"", @"color": @(c), @"subkey": subkey ?: @""};
}
static NSDictionary *Bt(NSString *t, NSString *action, NSString *ic, uint32_t c, BOOL red) {
    return @{@"type": @"button", @"title": t, @"action": action, @"icon": ic ?: @"", @"color": @(c), @"red": @(red)};
}
static NSDictionary *Rp(NSString *page) {   // "reset this page" button
    return @{@"type": @"button", @"title": W12Tr(@"Đặt lại mặc định trang này"), @"action": @"resetpage", @"page": page, @"icon": @"reset", @"color": @(0x8E8E93), @"red": @NO};
}
static NSDictionary *Ap(NSString *name, NSString *bid) { return @{@"type": @"app", @"title": name, @"bid": bid}; }
static NSDictionary *If(NSString *t, NSString *v) { return @{@"type": @"info", @"title": t, @"value": v}; }
static NSDictionary *Sec(NSString *h, NSString *f, NSArray *items) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (h) d[@"header"] = h;
    if (f) d[@"footer"] = f;
    d[@"items"] = items;
    return d;
}

static NSArray<NSString *> *ExcludeList(void) {
    id a = PGet(@"exclude");
    return [a isKindOfClass:[NSArray class]] ? a : @[];
}

// Installed apps: list written by the SpringBoard side of the tweak, with LaunchServices as a fallback.
static NSArray<NSDictionary *> *InstalledApps(void) {
    NSMutableDictionary *seen = [NSMutableDictionary dictionary];
    NSArray *dumped = [NSArray arrayWithContentsOfFile:@"/var/mobile/Library/Preferences/com.wave12.apps.plist"];
    for (NSDictionary *d in dumped) if ([d[@"bid"] length] && [d[@"name"] length]) seen[d[@"bid"]] = d[@"name"];
    if (!seen.count) {
        @try {
            Class W = NSClassFromString(@"LSApplicationWorkspace");
            id ws = [W respondsToSelector:@selector(defaultWorkspace)] ? [W performSelector:@selector(defaultWorkspace)] : nil;
            NSArray *apps = [ws respondsToSelector:NSSelectorFromString(@"allInstalledApplications")] ? [ws performSelector:NSSelectorFromString(@"allInstalledApplications")] : nil;
            for (id px in apps) {
                id b = [px respondsToSelector:NSSelectorFromString(@"applicationIdentifier")] ? [px performSelector:NSSelectorFromString(@"applicationIdentifier")] : nil;
                id n = [px respondsToSelector:NSSelectorFromString(@"localizedName")] ? [px performSelector:NSSelectorFromString(@"localizedName")] : nil;
                if ([b isKindOfClass:[NSString class]] && [n isKindOfClass:[NSString class]] && ![(NSString *)b hasPrefix:@"com.apple.webapp"]) seen[b] = n;
            }
        } @catch (NSException *e) { PLog(@"apps: LaunchServices failed %@", e.reason); }
    }
    for (NSString *b in ExcludeList()) if (!seen[b]) seen[b] = b;     // keep entries of apps that are no longer listed
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *k in seen) [out addObject:@{@"bid": k, @"name": seen[k]}];
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) { return [x[@"name"] localizedCaseInsensitiveCompare:y[@"name"]]; }];
    PLog(@"apps: %lu listed", (unsigned long)out.count);
    return out;
}

static UIImage *AppIcon(NSString *bid) {
    @try {
        Class c = [UIImage class];
        SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
        if ([c respondsToSelector:sel]) {
            UIImage *im = ((UIImage *(*)(id, SEL, id, int, double))objc_msgSend)(c, sel, bid, 2, [UIScreen mainScreen].scale);
            if (im) return im;
        }
    } @catch (NSException *e) {}
    UIGraphicsImageRenderer *rd = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(30, 30)];
    return [rd imageWithActions:^(UIGraphicsImageRendererContext *rc) {
        [[UIColor colorWithWhite:0.5 alpha:0.5] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 30, 30) cornerRadius:7] fill];
    }];
}

static NSString *Version(void) {
    NSBundle *b = [NSBundle bundleForClass:NSClassFromString(W12S(W12RootController))];
    return [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"3.0.0";
}

static NSString *ModTitle(void) {
#if defined(W12_PM_code)
    return @"UnlockCode";
#elif defined(W12_PM_wave)
    return @"OpenWave";
#elif defined(W12_PM_morph)
    return @"26Morph";
#elif defined(W12_PM_tab)
    return @"Liquid Tab";
#elif defined(W12_PM_home)
    return @"26Home";
#elif defined(W12_PM_cc)
    return @"27CC";
#elif defined(W12_PM_box)
    return @"26Box";
#elif defined(W12_PM_wall)
    return @"26Wall";
#else
    return @"DynaFake";
#endif
}
static NSString *PageTitle(NSString *pid) {
    NSDictionary *t = @{@"root": ModTitle(), @"wave": W12Tr(@"Mở khóa & Home"), @"app": W12Tr(@"Mở/đóng ứng dụng"), @"h26": W12Tr(@"Tùy chỉnh màn hình chính"), @"tab": @"Liquid Tab", @"lock": W12Tr(@"Màn hình khóa"),
                        @"island": W12Tr(@"Dynamic Island ảo"), @"sb": W12Tr(@"Thanh trạng thái"), @"excl": W12Tr(@"Danh sách loại trừ"), @"about": W12Tr(@"Giới thiệu")};
    return t[pid] ?: ModTitle();
}

static NSArray *Sections(NSString *pid);
static NSArray *RootSections(void) {
    NSMutableArray *a = [NSMutableArray array];
    NSString *respringNote = W12Tr(@"Cần Respring sau khi đổi.");
#if defined(W12_PM_code)
    [a addObject:Sec(nil, W12Tr(@"Phím mật khẩu nảy theo làn sóng khi bạn chạm, kèm viền kính. Cần Respring sau khi đổi."),
        @[Sw(W12Tr(@"Bật UnlockCode"), @"en_code", YES, @"bolt", 0x34C759),
          Sw(W12Tr(@"Hiệu ứng bàn phím mật khẩu"), @"passAnim", YES, @"lock", 0x5E5CE6)])];
#elif defined(W12_PM_wave)
    [a addObject:Sec(nil, W12Tr(@"Tắt công tắc này để vô hiệu hóa hiệu ứng mở khóa mà không cần gỡ cài đặt."),
        @[Sw(W12Tr(@"Bật OpenWave"), @"enabled", YES, @"bolt", 0x34C759)])];
    [a addObject:Sec(nil, nil, @[Sl(W12Tr(@"Tốc độ hiệu ứng"), @"speed", 1.0, 0.6, 1.6, @"%.2f×", @"speed", 0xFF9500)])];
    [a addObjectsFromArray:Sections(@"wave")];
    [a addObject:Sec(nil, nil, @[Lk(W12Tr(@"Danh sách loại trừ"), @"excl", @"power", 0xFF453A, nil)])];
#elif defined(W12_PM_morph)
    [a addObject:Sec(nil, W12Tr(@"Tắt công tắc này để vô hiệu hóa hiệu ứng mở/đóng ứng dụng mà không cần gỡ cài đặt."),
        @[Sw(W12Tr(@"Bật 26Morph"), @"en_morph", YES, @"bolt", 0x34C759)])];
    [a addObject:Sec(nil, nil, @[Sl(W12Tr(@"Tốc độ hiệu ứng"), @"speed", 1.0, 0.6, 1.6, @"%.2f×", @"speed", 0xFF9500)])];
    [a addObjectsFromArray:Sections(@"app")];
    [a addObject:Sec(nil, nil, @[Lk(W12Tr(@"Danh sách loại trừ"), @"excl", @"power", 0xFF453A, nil)])];
#elif defined(W12_PM_tab)
    [a addObjectsFromArray:Sections(@"tab")];
    [a addObject:Sec(nil, nil, @[Lk(W12Tr(@"Danh sách loại trừ"), @"excl", @"power", 0xFF453A, nil)])];
#elif defined(W12_PM_home)
    [a addObjectsFromArray:Sections(@"h26")];
#elif defined(W12_PM_cc)
    [a addObject:Sec(nil, W12Tr(@"Viền kính mảnh quanh các ô trong Trung tâm điều khiển, giống iOS 26. Kéo độ đặc của nền ô về thấp để nền đen trong suốt hơn (1.00 = như gốc). Cần Respring."),
        @[Sw(W12Tr(@"Bật 27CC"), @"en_cc", YES, @"bolt", 0x34C759),
          Sw(W12Tr(@"Viền kính Trung tâm điều khiển"), @"ccGlass", YES, @"glass", 0x64D2FF),
          Sw(W12Tr(@"Bo tròn ô Trung tâm điều khiển"), @"ccRound", YES, @"glass", 0x64D2FF),
          Sl(W12Tr(@"Độ đặc nền ô"), @"ccAlpha", 0.55, 0.2, 1.0, @"%.2f", @"glass", 0x64D2FF)])];
#elif defined(W12_PM_wall)
    [a addObject:Sec(nil, W12Tr(@"Tách chủ thể (người, thú cưng, vật nổi bật) khỏi hình nền khóa và đặt đồng hồ chìm phía sau, giống iOS 16. Cần Respring sau khi cài."),
        @[Sw(W12Tr(@"Bật 26Wall"), @"wallOn", YES, @"bolt", 0x34C759),
          Sw(W12Tr(@"Tự tách khi đổi hình nền khóa"), @"wallAuto", YES, @"glass", 0x64D2FF),
          Sw(W12Tr(@"Ưu tiên tách ở vùng đồng hồ"), @"wallClockFirst", YES, @"glass", 0x64D2FF),
          Sw(W12Tr(@"Bỏ qua hình nền trừu tượng"), @"wallSkipAbstract", NO, @"glass", 0x64D2FF),
          Bt(W12Tr(@"Tách nền hình khóa hiện tại"), @"wallregen", @"glass", 0x30B0C7, NO)])];
    [a addObject:Sec(W12Tr(@"Đồng hồ"), W12Tr(@"Cỡ và màu áp dụng ở lần khóa máy kế tiếp."),
        @[Sw(W12Tr(@"Đồng hồ lớn, chữ dày kiểu iOS 16"), @"wallBigClock", YES, @"sun", 0xFF9F0A),
          Sl(W12Tr(@"Cỡ chữ đồng hồ"), @"wallClockSize", 92, 60, 130, @"%.0f", @"sun", 0xFF9F0A),
          Sg(W12Tr(@"Màu đồng hồ"), @"wallClockColor", 0, @[W12Tr(@"Gốc"), W12Tr(@"Trắng"), W12Tr(@"Vàng"), W12Tr(@"Hồng"), W12Tr(@"Xanh"), W12Tr(@"Lá")], @[@0, @1, @2, @3, @4, @5], @"sun", 0xFF9F0A)])];
#elif defined(W12_PM_box)
    [a addObject:Sec(nil, W12Tr(@"Hộp thoại và công tắc kiểu iOS 26 (kính, bo tròn). Thoát hẳn ứng dụng rồi mở lại để áp dụng."),
        @[Sw(W12Tr(@"Bật 26Box"), @"en_box", YES, @"bolt", 0x34C759),
          Sw(W12Tr(@"Hộp thoại kiểu iOS 26"), @"alertGlass", YES, @"glass", 0x64D2FF)])];
#else
    [a addObject:Sec(nil, nil, @[Sw(W12Tr(@"Bật DynaFake"), @"en_dyna", YES, @"bolt", 0x34C759)])];
    [a addObjectsFromArray:Sections(@"island")];
#endif
    [a addObject:Sec(nil, nil, @[Sw(W12Tr(@"Giao diện sáng"), @"uiLight", NO, @"sun", 0xFF9F0A)])];
    [a addObject:Sec(W12Tr(@"Ngôn ngữ"), nil, @[Sg(W12Tr(@"Ngôn ngữ"), @"uiLang", 0, @[W12Tr(@"Tự động"), @"Tiếng Việt", @"English"], @[@0, @1, @2], @"app", 0x0A84FF)])];
    [a addObject:Sec(nil, [NSString stringWithFormat:W12Tr(@"%@ %@ · bởi PucPucPuc · Thay đổi có hiệu lực ngay ở lần kế tiếp. Một số mục cần Respring."), ModTitle(), Version()],
        @[Rp(@"root"), Bt(W12Tr(@"Respring để áp dụng"), @"respring", @"power", 0xFF453A, YES)])];
    (void)respringNote;
    return a;
}

static NSArray *Sections(NSString *pid) {
    if ([pid isEqualToString:@"root"]) return RootSections();
    if ([pid isEqualToString:@"wave"]) {
        return @[
            Sec(nil, W12Tr(@"Icon bay ra theo làn sóng từ tâm màn hình, dùng lò xo có độ nảy chỉnh được."),
                @[Sw(W12Tr(@"Hiệu ứng khi mở khóa"), @"unlock", YES, @"lock", 0xFF9500),
                  Sw(W12Tr(@"Hiệu ứng khi thoát app về Home"), @"home", YES, @"wave", 0x0A84FF)]),
            Sec(W12Tr(@"Làn sóng"), W12Tr(@"Độ phóng là kích thước icon lúc bắt đầu. Độ trễ là khoảng cách thời gian giữa icon ở tâm và icon ở rìa."),
                @[Sl(W12Tr(@"Độ phóng"), @"zoom", 3.0, 1.1, 4.0, @"%.2f×", @"glass", 0x32ADE6),
                  Sl(W12Tr(@"Độ trễ giữa các icon"), @"stagger", 0.14, 0.0, 0.4, @"%.2f s", @"wave", 0x0A84FF),
                  Sl(W12Tr(@"Độ nảy"), @"bounce", 0.7, 0.0, 1.0, @"%.2f", @"speed", 0xFF9500)])];
    }
    if ([pid isEqualToString:@"app"]) {
        return @[
            Sec(nil, W12Tr(@"Ứng dụng phóng ra từ đúng icon vừa chạm (hoặc thu về icon khi thoát), có bo góc và nghiêng 3D."),
                @[Sw(W12Tr(@"Hiệu ứng mở/đóng kiểu iOS 26"), @"appanim", YES, @"app", 0x5E5CE6),
                  Sw(W12Tr(@"Hiệu ứng khi đóng ứng dụng"), @"appClose", YES, @"app", 0x5E5CE6),
                  Sw(W12Tr(@"Làm mờ màn hình chính khi mở/đóng"), @"appBlur", YES, @"app", 0x5E5CE6)]),
            Sec(W12Tr(@"Thử nghiệm"), W12Tr(@"Animation mới (thẻ cắt vuông, phối cảnh, icon nảy) để bạn test. Tắt = dùng animation cũ ổn định. Công tắc làm mờ chỉ có tác dụng khi bật mục này."),
                @[Sw(W12Tr(@"Animation đóng/mở app thử nghiệm"), @"appExp", NO, @"app", 0xFF9F0A)]),
            Sec(W12Tr(@"Hình dạng thẻ"), nil,
                @[Sl(W12Tr(@"Độ cong góc"), @"appCorner", 40, 8, 90, @"%.0f pt", @"corner", 0x5E5CE6),
                  Sl(W12Tr(@"Độ nghiêng 3D"), @"appTilt", 1.0, 0.0, 5.0, @"%.1f", @"tilt", 0xBF5AF2)]),
            Sec(W12Tr(@"Hướng nghiêng"), W12Tr(@"App ở nửa trên màn hình nghiêng ngược chiều với app ở nửa dưới."),
                @[Sg(W12Tr(@"Trục nghiêng"), @"appTiltAxis", 2, @[W12Tr(@"Trái–phải"), W12Tr(@"Trên–dưới"), W12Tr(@"Cả hai")], @[@0, @1, @2], @"tilt", 0xBF5AF2)]),
            Sec(nil, nil, @[Rp(@"app")])];
    }
    if ([pid isEqualToString:@"h26"]) {
        return @[
            Sec(nil, W12Tr(@"26Home Beta 1. Giữ vào chỗ trống trên màn hình chính để mở bảng Tùy chỉnh: chọn kiểu icon (Mặc định, Tối, Trong suốt, Phủ màu), màu và Sáng / Tối / Tự động."),
                @[Sw(W12Tr(@"Bật tùy chỉnh màn hình chính"), @"home26", YES, @"app", 0x30D158)]),
            Sec(W12Tr(@"Chế độ chỉnh sửa"), W12Tr(@"Hiện thanh Sửa / Xong phía trên và dấu trừ trên icon khi giữ vào màn hình chính."),
                @[Sw(W12Tr(@"Thanh Sửa / Xong và dấu trừ"), @"home26Edit", YES, @"app", 0x30D158)]),
            Sec(W12Tr(@"Bộ icon"), W12Tr(@"iOS 26: Solid Glass 2. iOS 27: Solid Glass 27 (Sáng, Tối, Trong suốt). Icon app nào bộ đã chọn không có thì dùng icon iOS 26. iOS 18 sẽ thêm khi có file. Cần Respring sau khi đổi."),
                @[Sg(W12Tr(@"Kiểu icon"), @"h26Ver", 0, @[@"iOS 26", @"iOS 27"], @[@0, @1], @"app", 0x30D158)]),
            Sec(@"Theme icon", W12Tr(@"Khi Snowboard đang dùng theme, kiểu Mặc định giữ icon của theme và chỉ đổi icon Apple sang bộ icon iOS 26."),
                @[Sw(W12Tr(@"Tự nhận Snowboard"), @"h26Snow", YES, @"app", 0x30D158)]),
            Sec(nil, W12Tr(@"Cần Respring sau khi đổi."), @[Bt(W12Tr(@"Respring để áp dụng"), @"respring", @"power", 0xFF453A, YES)])];
    }
    if ([pid isEqualToString:@"tab"]) {
        return @[
            Sec(nil, W12Tr(@"Thanh tab thành viên kính nổi cách đáy, kéo ngón qua lại chỉ di chuyển viên kính, thả tay mới chọn mục gần nhất. Thoát hẳn app rồi mở lại để áp dụng. Mặc định chỉ áp dụng cho thanh tab chuẩn của iOS; app tự dựng thanh tab (như Zalo) giữ nguyên để không bị lỗi cảm ứng."),
                @[Sw(W12Tr(@"Thanh tab kính nổi"), @"tabOn", YES, @"bars", 0xFF9F0A),
                  Sw(W12Tr(@"Viên kính phóng đại khi chạm"), @"tabLens", YES, @"glass", 0xFF9F0A),
                  Sw(W12Tr(@"Cả thanh tab tự dựng (Zalo…)"), @"tabCustom", NO, @"bars", 0xFF9F0A),
                  Sl(W12Tr(@"Độ cao thanh (đệm)"), @"tabPad", 10, 4, 30, @"%.0f pt", @"bars", 0xFF9F0A),
                  Sl(W12Tr(@"Độ đậm màu nền thanh tab"), @"tabAlpha", 0.6, 0.2, 1.0, @"%.2f", @"glass", 0xFF9F0A),
                  Sl(W12Tr(@"Độ nổi cách đáy (app thường)"), @"tabLiftStd", 14, 0, 60, @"%.0f pt", @"bars", 0xFF9F0A),
                  Sl(W12Tr(@"Độ nổi (Zalo / tab tùy biến)"), @"tabLift", 40, 0, 60, @"%.0f pt", @"bars", 0xFF9F0A),
                  Sl(W12Tr(@"Độ phồng khi kéo"), @"tabInflate", 1.45, 1.0, 1.8, @"%.2f×", @"glass", 0xFF9F0A),
                  Sl(W12Tr(@"Độ phóng đại"), @"tabMag", 1.30, 1.0, 1.9, @"%.2f×", @"glass", 0xFF9F0A)]),
            Sec(nil, nil, @[Rp(@"tab")])];
    }
    if ([pid isEqualToString:@"island"]) {
        return @[
            Sec(nil, W12Tr(@"Viên thuốc đen cố định ở đỉnh màn hình, không có tính năng. Tự ẩn khi xoay ngang."),
                @[Sw(W12Tr(@"Bật Dynamic Island ảo"), @"island", NO, @"island", 0x3A3A3C),
                  Sw(W12Tr(@"Viền xám trên nền đen"), @"islandBorder", YES, @"glass", 0x636366),
                  Sl(W12Tr(@"Độ dày viền xám"), @"islandBorderW", 0.75, 0.25, 3.0, @"%.2f", @"glass", 0x636366),
                  Sw(W12Tr(@"Ẩn island khi xoay ngang"), @"islandHideLand", YES, @"island", 0x3A3A3C)]),
            Sec(W12Tr(@"Hoạt động trực tiếp"), W12Tr(@"Island nở ra khi có hẹn giờ, báo thức sắp reo, nhạc đang phát hoặc cuộc gọi. Chạm vào island để mở app đó. Hẹn giờ/báo thức đọc từ app Đồng hồ."),
                @[Sw(W12Tr(@"Hiện hoạt động trên island"), @"islandLive", YES, @"island", 0xFF9F0A),
                  Sw(W12Tr(@"App bay vào island khi thoát"), @"islandFly", YES, @"island", 0xFF9F0A),
                  Sw(W12Tr(@"Âm lượng trên island (ẩn bảng âm lượng iOS 12)"), @"islandVol", YES, @"island", 0xFF9F0A),
                  Sw(W12Tr(@"Đèn pin trên island"), @"islandTorch", YES, @"island", 0xFF9F0A),
                  Sw(W12Tr(@"Hiệu ứng Face ID khi mở khoá"), @"faceID", YES, @"lock", 0x30D158),
                  Sg(W12Tr(@"Kiểu Face ID"), @"faceStyle", 1, @[W12Tr(@"Thanh island"), W12Tr(@"Khung vuông")], @[@0, @1], @"lock", 0x30D158),
                  Sw(W12Tr(@"Ổ khoá trên island ở màn hình khoá"), @"faceLock", YES, @"lock", 0x30D158),
                  Sw(W12Tr(@"Chờ Face ID xong mới mở khoá (trễ ~1,3 giây)"), @"faceDelay", YES, @"lock", 0x30D158)]),
            Sec(W12Tr(@"Thử thông báo"), W12Tr(@"Bấm để xem thử từng thông báo trên island. Cần bật Dynamic Island ảo (Respring nếu vừa bật)."),
                @[Bt(W12Tr(@"Pin yếu"), @"test8", @"island", 0xFF453A, NO),
                  Bt(W12Tr(@"Cắm sạc"), @"test7", @"island", 0x30D158, NO),
                  Bt(W12Tr(@"Rút sạc"), @"test9", @"island", 0x8E8E93, NO),
                  Bt(W12Tr(@"Chuông"), @"test10", @"island", 0x0A84FF, NO),
                  Bt(W12Tr(@"Im lặng"), @"test11", @"island", 0xFF453A, NO),
                  Bt(W12Tr(@"Âm lượng"), @"test12", @"island", 0x5E5CE6, NO),
                  Bt(W12Tr(@"Đèn pin"), @"test13", @"island", 0xFFD60A, NO),
                  Bt(W12Tr(@"Face ID"), @"test14", @"lock", 0x30D158, NO)]),
            Sec(W12Tr(@"Kích thước & vị trí"), nil,
                @[Sl(W12Tr(@"Chiều rộng"), @"islandW", 126, 70, 220, @"%.0f pt", @"island", 0x3A3A3C),
                  Sl(W12Tr(@"Chiều cao"), @"islandH", 37, 20, 60, @"%.0f pt", @"island", 0x3A3A3C),
                  Sl(W12Tr(@"Cách mép trên"), @"islandY", 11, 0, 40, @"%.0f pt", @"island", 0x3A3A3C)])];
    }
    if ([pid isEqualToString:@"excl"]) {
        NSMutableArray *rows = [NSMutableArray array];
        for (NSDictionary *d in InstalledApps()) [rows addObject:Ap(d[@"name"], d[@"bid"])];
        return @[
            Sec(nil, W12Tr(@"Bật công tắc để loại trừ ứng dụng khỏi thanh tab kính, hiệu ứng mở/đóng. Thoát hẳn ứng dụng rồi mở lại để áp dụng. Danh sách cập nhật mỗi lần Respring."),
                @[If(W12Tr(@"Đã loại trừ"), [NSString stringWithFormat:W12Tr(@"%lu ứng dụng"), (unsigned long)ExcludeList().count])]),
            Sec(rows.count ? W12Tr(@"Ứng dụng") : nil, rows.count ? nil : W12Tr(@"Chưa có danh sách ứng dụng. Hãy Respring một lần, đợi vài giây rồi mở lại trang này."), rows)];
    }
    return @[
        Sec(nil, nil, @[If(W12Tr(@"Phiên bản"), Version()), If(W12Tr(@"Hệ điều hành"), @"iOS 12 · arm64"), If(W12Tr(@"Tối ưu cho"), @"iPhone 6")]),
        Sec(nil, W12Tr(@"Tweak ghi nhật ký chẩn đoán tại /var/mobile/Library/Logs/Wave12.log. Gửi tệp này khi có hiệu ứng không chạy. Ý tưởng dựa trên 26Unlock của blu_tek."),
            @[If(W12Tr(@"Nhật ký"), @"Logs/Wave12.log")])];
}

static NSString *Fold(NSString *s) {
    return [s stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch | NSWidthInsensitiveSearch locale:nil];
}

static NSArray *SearchSections(NSString *q) {
    NSString *fq = Fold(q);
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *pid in @[@"root"]) {
        for (NSDictionary *sec in Sections(pid)) {
            for (NSDictionary *it in sec[@"items"]) {
                NSString *ty = it[@"type"];
                if ([ty isEqualToString:@"hero"] || [ty isEqualToString:@"info"] || [ty isEqualToString:@"button"]) continue;
                if ([pid isEqualToString:@"root"] && [ty isEqualToString:@"link"]) continue;
                if ([Fold(it[@"title"]) rangeOfString:fq].location != NSNotFound) [out addObject:it];
            }
        }
    }
    if (!out.count) return @[Sec(nil, W12Tr(@"Không tìm thấy mục nào khớp với từ khóa."), @[])];
    return @[Sec(W12Tr(@"Kết quả"), nil, out)];
}

#pragma mark - Row

@interface W12Row : UIControl
@property (nonatomic) CGFloat rh;
@property (nonatomic, strong) NSDictionary *item;
@property (nonatomic, strong) UIColor *hl;
@end
@implementation W12Row
- (void)setHighlighted:(BOOL)h {
    [super setHighlighted:h];
    self.backgroundColor = (h && self.hl) ? self.hl : [UIColor clearColor];
}
@end

static const void *kItemKey = &kItemKey;
static const void *kValueLabelKey = &kValueLabelKey;

#pragma mark - Page view

@interface W12PageView : UIView <UIScrollViewDelegate, UITextFieldDelegate>
@property (nonatomic, copy) NSString *pid;
@property (nonatomic, weak) UIViewController *owner;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIView *content;
@property (nonatomic, strong) CAGradientLayer *bgGrad;
@property (nonatomic, strong) UIView *topFade;
@property (nonatomic, strong) CAGradientLayer *fadeGrad;
@property (nonatomic, strong) UIVisualEffectView *back;
@property (nonatomic, strong) UIImageView *backArrow;
@property (nonatomic, strong) UIButton *backBtn;
@property (nonatomic, strong) UILabel *smallTitle;
@property (nonatomic, strong) UILabel *largeTitle;
@property (nonatomic, strong) UIVisualEffectView *pill;
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UIImageView *pillIcon;
@property (nonatomic, strong) UIImageView *pillMic;
@property (nonatomic, copy) NSString *query;
@property (nonatomic) CGSize lastSize;
@property (nonatomic) CGFloat lastTop;
@property (nonatomic) CGFloat kb;
@end

@implementation W12PageView

- (instancetype)initWithPage:(NSString *)pid owner:(UIViewController *)vc {
    self = [super initWithFrame:[UIScreen mainScreen].bounds];
    if (!self) return nil;
    _pid = [pid copy]; _owner = vc; _query = @"";
    gLight = PNum(@"uiLight", 0) > 0.5;
    self.clipsToBounds = YES;

    _bgGrad = [CAGradientLayer layer];
    [self.layer addSublayer:_bgGrad];

    _scroll = [[UIScrollView alloc] init];
    _scroll.delegate = self;
    _scroll.alwaysBounceVertical = YES;
    _scroll.showsVerticalScrollIndicator = YES;
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    if (@available(iOS 11.0, *)) _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self addSubview:_scroll];
    _content = [[UIView alloc] init];
    [_scroll addSubview:_content];

    _topFade = [[UIView alloc] init];
    _topFade.userInteractionEnabled = NO;
    _topFade.alpha = 0;
    _fadeGrad = [CAGradientLayer layer];
    [_topFade.layer addSublayer:_fadeGrad];
    [self addSubview:_topFade];

    _smallTitle = [[UILabel alloc] init];
    _smallTitle.text = PageTitle(pid);
    _smallTitle.textAlignment = NSTextAlignmentCenter;
    _smallTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _smallTitle.alpha = 0;
    [self addSubview:_smallTitle];

    _back = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    _back.layer.cornerRadius = 22; _back.clipsToBounds = YES;
    _backArrow = [[UIImageView alloc] init];
    _backArrow.contentMode = UIViewContentModeCenter;
    [_back.contentView addSubview:_backArrow];
    _backBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [_backBtn addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];
    [_backBtn addTarget:self action:@selector(backDown) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [_backBtn addTarget:self action:@selector(backUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    [_back.contentView addSubview:_backBtn];
    [self addSubview:_back];

    if ([pid isEqualToString:@"root"]) {
        _pill = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
        _pill.layer.cornerRadius = 26; _pill.clipsToBounds = YES;
        _pill.layer.borderWidth = 0.5;
        _pillIcon = [[UIImageView alloc] init]; _pillIcon.contentMode = UIViewContentModeCenter;
        _pillMic = [[UIImageView alloc] init]; _pillMic.contentMode = UIViewContentModeCenter;
        _field = [[UITextField alloc] init];
        _field.delegate = self;
        _field.placeholder = W12Tr(@"Tìm kiếm");
        _field.font = [UIFont systemFontOfSize:17];
        _field.returnKeyType = UIReturnKeySearch;
        _field.clearButtonMode = UITextFieldViewModeWhileEditing;
        _field.autocorrectionType = UITextAutocorrectionTypeNo;
        [_field addTarget:self action:@selector(queryChanged) forControlEvents:UIControlEventEditingChanged];
        [_pill.contentView addSubview:_pillIcon];
        [_pill.contentView addSubview:_pillMic];
        [_pill.contentView addSubview:_field];
        [self addSubview:_pill];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbChanged:) name:UIKeyboardWillChangeFrameNotification object:nil];
    }
    [self applyTheme];
    return self;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)applyTheme {
    UIBlurEffectStyle st = gLight ? UIBlurEffectStyleExtraLight : UIBlurEffectStyleDark;
    if (gLight) { _bgGrad.colors = @[(id)Hex(0xF2F2F7).CGColor, (id)Hex(0xF2F2F7).CGColor]; }
    else        { _bgGrad.colors = @[(id)Hex(0x0B1220).CGColor, (id)Hex(0x000000).CGColor]; }
    _bgGrad.startPoint = CGPointMake(0.5, 0); _bgGrad.endPoint = CGPointMake(0.5, 0.7);
    UIColor *bgTop = gLight ? Hex(0xF2F2F7) : Hex(0x0B1220);
    _fadeGrad.colors = @[(id)[bgTop colorWithAlphaComponent:0.96].CGColor, (id)[bgTop colorWithAlphaComponent:0].CGColor];
    _back.effect = [UIBlurEffect effectWithStyle:st];
    _backArrow.image = ChevronLeft(cText());
    _smallTitle.textColor = cText();
    _pill.effect = [UIBlurEffect effectWithStyle:st];
    _pill.layer.borderColor = (gLight ? [UIColor colorWithWhite:0 alpha:0.08] : [UIColor colorWithWhite:1 alpha:0.14]).CGColor;
    _pillIcon.image = Magnifier(cSub());
    _pillMic.image = Mic(cSub());
    _field.textColor = cText();
    _field.keyboardAppearance = gLight ? UIKeyboardAppearanceLight : UIKeyboardAppearanceDark;
    _field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:W12Tr(@"Tìm kiếm") attributes:@{NSForegroundColorAttributeName: cSub()}];
    [self setNeedsLayout];
}

- (void)reloadAll { [self applyTheme]; _lastSize = CGSizeZero; [self setNeedsLayout]; }

- (void)backDown { _back.alpha = 0.6; }
- (void)backUp { [UIView animateWithDuration:0.2 animations:^{ self.back.alpha = 1; }]; }
- (void)goBack { [_owner.navigationController popViewControllerAnimated:YES]; }

- (void)queryChanged {
    _query = _field.text ?: @"";
    _lastSize = CGSizeZero;
    [self setNeedsLayout];
}
- (BOOL)textFieldShouldReturn:(UITextField *)f { [f resignFirstResponder]; return YES; }
- (void)kbChanged:(NSNotification *)n {
    CGRect f = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect inView = [self convertRect:[self.window convertRect:f fromWindow:nil] fromView:nil];
    CGFloat h = MAX(0, CGRectGetHeight(self.bounds) - CGRectGetMinY(inView));
    _kb = h > 80 ? h : 0;
    NSTimeInterval d = [n.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:d animations:^{ [self layoutPill]; }];
}

- (UIEdgeInsets)safe {
    UIEdgeInsets si = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) si = self.safeAreaInsets;
    si.top = MAX(si.top, 20);
    return si;
}

- (void)layoutPill {
    if (!_pill) return;
    UIEdgeInsets si = [self safe];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    CGFloat bottom = _kb > 0 ? _kb + 10 : si.bottom + 12;
    _pill.frame = CGRectMake(16, H - bottom - 52, W - 32, 52);
    _pillIcon.frame = CGRectMake(16, 0, 24, 52);
    _pillMic.frame = CGRectMake(W - 32 - 16 - 22, 0, 22, 52);
    _field.frame = CGRectMake(48, 0, W - 32 - 48 - 52, 52);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    UIEdgeInsets si = [self safe];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _bgGrad.frame = self.bounds;
    _fadeGrad.frame = CGRectMake(0, 0, s.width, si.top + 64);
    [CATransaction commit];
    _scroll.frame = self.bounds;
    _topFade.frame = CGRectMake(0, 0, s.width, si.top + 64);
    _back.frame = CGRectMake(16, si.top + 4, 44, 44);
    _backArrow.frame = CGRectMake(0, 0, 44, 44);
    _backBtn.frame = CGRectMake(0, 0, 44, 44);
    _smallTitle.frame = CGRectMake(72, si.top + 4, s.width - 144, 44);
    [self layoutPill];
    if (fabs(s.width - _lastSize.width) > 0.5 || fabs(s.height - _lastSize.height) > 0.5 || fabs(si.top - _lastTop) > 0.5) {
        _lastSize = s; _lastTop = si.top;
        [self rebuild];
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)sv {
    CGFloat o = sv.contentOffset.y;
    _smallTitle.alpha = MAX(0, MIN(1, (o - 34) / 18));
    _topFade.alpha = MAX(0, MIN(1, o / 24));
}

#pragma mark Building

- (UILabel *)lbl:(NSString *)t size:(CGFloat)sz color:(UIColor *)c weight:(UIFontWeight)w {
    UILabel *l = [[UILabel alloc] init];
    l.text = t; l.textColor = c; l.font = [UIFont systemFontOfSize:sz weight:w];
    l.backgroundColor = [UIColor clearColor];
    return l;
}

- (BOOL)boolFor:(NSString *)key def:(BOOL)d { return PNum(key, d) > 0.5; }

- (W12Row *)rowFor:(NSDictionary *)it width:(CGFloat)cw {
    NSString *ty = it[@"type"];
    W12Row *row = [[W12Row alloc] init];
    row.item = it;
    row.rh = 52;
    NSString *icon = it[@"icon"];
    BOOL hasIcon = icon.length > 0;
    uint32_t col = (uint32_t)[it[@"color"] unsignedIntValue];
    CGFloat tx = hasIcon ? 62 : 16;

    if ([ty isEqualToString:@"hero"]) {
        UIImage *ban = [UIImage imageWithContentsOfFile:[[NSBundle bundleForClass:NSClassFromString(W12S(W12RootController))] pathForResource:@"banner" ofType:@"png"]];
        if (ban) {                                                       // banner of the package (same picture as in the package page)
            row.rh = round(cw * 0.40);
            row.hl = cHi();
            UIImageView *bi = [[UIImageView alloc] initWithImage:ban];
            bi.contentMode = UIViewContentModeScaleAspectFill; bi.clipsToBounds = YES; bi.userInteractionEnabled = NO;
            bi.frame = CGRectMake(0, 0, cw, row.rh);
            [row addSubview:bi];
            [row addTarget:self action:@selector(heroTap) forControlEvents:UIControlEventTouchUpInside];
            return row;
        }
        row.rh = 88;
        row.hl = cHi();
        UIImageView *iv = [[UIImageView alloc] initWithImage:Icon(@"bolt", 0x34C759, 60, YES)];
        iv.frame = CGRectMake(16, 14, 60, 60);
        UILabel *t = [self lbl:@"2712" size:21 color:cText() weight:UIFontWeightSemibold];
        t.frame = CGRectMake(92, 19, cw - 92 - 40, 26);
        UILabel *s = [self lbl:W12Tr(@"Hiệu ứng iOS 26 cho iOS 12 · tối ưu iPhone 6") size:13 color:cSub() weight:UIFontWeightRegular];
        s.numberOfLines = 2;
        s.frame = CGRectMake(92, 46, cw - 92 - 40, 34);
        UIImageView *ch = [[UIImageView alloc] initWithImage:ChevronRight(cSub())];
        ch.frame = CGRectMake(cw - 16 - 9, 44 - 7.5, 9, 15);
        [row addSubview:iv]; [row addSubview:t]; [row addSubview:s]; [row addSubview:ch];
        [row addTarget:self action:@selector(heroTap) forControlEvents:UIControlEventTouchUpInside];
        return row;
    }

    if ([ty isEqualToString:@"switch"] || [ty isEqualToString:@"app"]) {
        BOOL isApp = [ty isEqualToString:@"app"];
        if (isApp) tx = 62;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.onTintColor = cGreen();
        sw.on = isApp ? [ExcludeList() containsObject:it[@"bid"]] : [self boolFor:it[@"key"] def:[it[@"def"] boolValue]];
        sw.frame = CGRectMake(cw - 16 - 51, (52 - 31) / 2, 51, 31);
        objc_setAssociatedObject(sw, kItemKey, it, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sw addTarget:self action:@selector(swChanged:) forControlEvents:UIControlEventValueChanged];
        UILabel *t = [self lbl:it[@"title"] size:17 color:cText() weight:UIFontWeightRegular];
        t.frame = CGRectMake(tx, 0, cw - tx - 16 - 51 - 8, 52);
        t.adjustsFontSizeToFitWidth = YES; t.minimumScaleFactor = 0.8;
        if (isApp) {
            UIImageView *iv = [[UIImageView alloc] initWithImage:AppIcon(it[@"bid"])];
            iv.frame = CGRectMake(16, 11, 30, 30); iv.contentMode = UIViewContentModeScaleAspectFit;
            iv.layer.cornerRadius = 7; iv.clipsToBounds = YES;
            [row addSubview:iv];
        } else if (hasIcon) { UIImageView *iv = [[UIImageView alloc] initWithImage:Icon(icon, col, 30, NO)]; iv.frame = CGRectMake(16, 11, 30, 30); [row addSubview:iv]; }
        [row addSubview:t]; [row addSubview:sw];
        return row;
    }

    if ([ty isEqualToString:@"slider"]) {
        row.rh = 82;
        double mn = [it[@"min"] doubleValue], mx = [it[@"max"] doubleValue];
        double v = PNum(it[@"key"], [it[@"def"] doubleValue]);
        v = MAX(mn, MIN(mx, v));
        UILabel *t = [self lbl:it[@"title"] size:17 color:cText() weight:UIFontWeightRegular];
        t.frame = CGRectMake(tx, 8, cw - tx - 16 - 84, 30);
        t.adjustsFontSizeToFitWidth = YES; t.minimumScaleFactor = 0.8;
        UILabel *val = [self lbl:[NSString stringWithFormat:it[@"fmt"], v] size:17 color:cSub() weight:UIFontWeightRegular];
        val.textAlignment = NSTextAlignmentRight;
        val.frame = CGRectMake(cw - 16 - 80, 8, 80, 30);
        UISlider *sl = [[UISlider alloc] init];
        sl.minimumValue = mn; sl.maximumValue = mx; sl.value = v;
        sl.minimumTrackTintColor = cAccent();
        sl.maximumTrackTintColor = gLight ? Hex(0xD1D1D6) : [UIColor colorWithWhite:1 alpha:0.2];
        sl.frame = CGRectMake(16, 42, cw - 32, 30);
        objc_setAssociatedObject(sl, kItemKey, it, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sl, kValueLabelKey, val, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sl addTarget:self action:@selector(slMoved:) forControlEvents:UIControlEventValueChanged];
        [sl addTarget:self action:@selector(slDone:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        if (hasIcon) { UIImageView *iv = [[UIImageView alloc] initWithImage:Icon(icon, col, 30, NO)]; iv.frame = CGRectMake(16, 9, 30, 30); [row addSubview:iv]; }
        [row addSubview:t]; [row addSubview:val]; [row addSubview:sl];
        return row;
    }

    if ([ty isEqualToString:@"segment"]) {
        row.rh = 92;
        UILabel *t = [self lbl:it[@"title"] size:17 color:cText() weight:UIFontWeightRegular];
        t.frame = CGRectMake(tx, 8, cw - tx - 16, 30);
        UISegmentedControl *sg = [[UISegmentedControl alloc] initWithItems:it[@"titles"]];
        NSArray *vals = it[@"values"];
        double cur = PNum(it[@"key"], [it[@"def"] doubleValue]);
        NSInteger idx = 0;
        for (NSInteger i = 0; i < (NSInteger)vals.count; i++) if (fabs([vals[i] doubleValue] - cur) < 0.01) idx = i;
        sg.selectedSegmentIndex = idx;
        sg.tintColor = cAccent();
        sg.frame = CGRectMake(16, 46, cw - 32, 34);
        objc_setAssociatedObject(sg, kItemKey, it, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sg addTarget:self action:@selector(sgChanged:) forControlEvents:UIControlEventValueChanged];
        if (hasIcon) { UIImageView *iv = [[UIImageView alloc] initWithImage:Icon(icon, col, 30, NO)]; iv.frame = CGRectMake(16, 9, 30, 30); [row addSubview:iv]; }
        [row addSubview:t]; [row addSubview:sg];
        return row;
    }

    if ([ty isEqualToString:@"link"] || [ty isEqualToString:@"button"]) {
        BOOL isLink = [ty isEqualToString:@"link"];
        row.hl = cHi();
        BOOL red = [it[@"red"] boolValue];
        UILabel *t = [self lbl:it[@"title"] size:17 color:(red ? Hex(0xFF453A) : cText()) weight:UIFontWeightRegular];
        CGFloat rightPad = isLink ? 16 + 9 + 8 : 16;
        NSString *sub = nil;
        if (isLink && [it[@"subkey"] length]) sub = [self boolFor:it[@"subkey"] def:([it[@"subkey"] isEqualToString:@"island"] || [it[@"subkey"] isEqualToString:@"sbOn"]) ? NO : YES] ? W12Tr(@"Bật") : W12Tr(@"Tắt");
        CGFloat subW = sub ? 44 : 0;
        t.frame = CGRectMake(tx, 0, cw - tx - rightPad - subW, 52);
        t.adjustsFontSizeToFitWidth = YES; t.minimumScaleFactor = 0.8;
        if (hasIcon) { UIImageView *iv = [[UIImageView alloc] initWithImage:Icon(icon, col, 30, NO)]; iv.frame = CGRectMake(16, 11, 30, 30); [row addSubview:iv]; }
        [row addSubview:t];
        if (sub) {
            UILabel *sl = [self lbl:sub size:17 color:cSub() weight:UIFontWeightRegular];
            sl.textAlignment = NSTextAlignmentRight;
            sl.frame = CGRectMake(cw - rightPad - 44, 0, 44, 52);
            [row addSubview:sl];
        }
        if (isLink) {
            UIImageView *ch = [[UIImageView alloc] initWithImage:ChevronRight(cSub())];
            ch.frame = CGRectMake(cw - 16 - 9, 26 - 7.5, 9, 15);
            [row addSubview:ch];
        }
        [row addTarget:self action:@selector(rowTap:) forControlEvents:UIControlEventTouchUpInside];
        return row;
    }

    // info
    UILabel *t = [self lbl:it[@"title"] size:17 color:cText() weight:UIFontWeightRegular];
    t.frame = CGRectMake(16, 0, 130, 52);
    UILabel *v = [self lbl:it[@"value"] size:17 color:cSub() weight:UIFontWeightRegular];
    v.textAlignment = NSTextAlignmentRight;
    v.adjustsFontSizeToFitWidth = YES; v.minimumScaleFactor = 0.7;
    v.frame = CGRectMake(150, 0, cw - 150 - 16, 52);
    [row addSubview:t]; [row addSubview:v];
    return row;
}

- (CGFloat)addSection:(NSDictionary *)sec y:(CGFloat)y W:(CGFloat)W {
    CGFloat mx = 16, cw = W - 2 * mx;
    NSString *hd = sec[@"header"];
    if (hd.length) {
        UILabel *l = [self lbl:[hd uppercaseString] size:13 color:cSub() weight:UIFontWeightRegular];
        l.frame = CGRectMake(mx + 16, y + 2, cw - 32, 18);
        [_content addSubview:l];
        y += 26;
    }
    NSArray *items = sec[@"items"];
    if (items.count) {
        UIView *card = [[UIView alloc] init];
        card.backgroundColor = cCard();
        card.layer.cornerRadius = 24;
        card.layer.borderWidth = gLight ? 0 : 0.5;
        card.layer.borderColor = cBorder().CGColor;
        card.clipsToBounds = YES;
        CGFloat ry = 0;
        for (NSUInteger i = 0; i < items.count; i++) {
            W12Row *row = [self rowFor:items[i] width:cw];
            row.frame = CGRectMake(0, ry, cw, row.rh);
            [card addSubview:row];
            ry += row.rh;
            if (i + 1 < items.count) {
                BOOL ic = [items[i][@"icon"] length] > 0;
                UIView *sp = [[UIView alloc] initWithFrame:CGRectMake(ic ? 62 : 16, ry - 0.5, cw - (ic ? 62 : 16), 0.5)];
                sp.backgroundColor = cSep();
                sp.userInteractionEnabled = NO;
                [card addSubview:sp];
            }
        }
        card.frame = CGRectMake(mx, y, cw, ry);
        [_content addSubview:card];
        y += ry;
    }
    NSString *ft = sec[@"footer"];
    if (ft.length) {
        UIFont *f = [UIFont systemFontOfSize:13];
        CGRect r = [ft boundingRectWithSize:CGSizeMake(cw - 32, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName: f} context:nil];
        UILabel *l = [self lbl:ft size:13 color:cSub() weight:UIFontWeightRegular];
        l.numberOfLines = 0;
        l.frame = CGRectMake(mx + 16, y + 8, cw - 32, ceil(r.size.height) + 2);
        [_content addSubview:l];
        y += 8 + ceil(r.size.height) + 2;
    }
    return y + 24;
}

- (void)rebuild {
    for (UIView *v in [_content.subviews copy]) [v removeFromSuperview];
    CGFloat W = self.bounds.size.width;
    UIEdgeInsets si = [self safe];
    CGFloat y = si.top + 58;
    _largeTitle = [self lbl:PageTitle(_pid) size:34 color:cText() weight:UIFontWeightBold];
    _largeTitle.adjustsFontSizeToFitWidth = YES; _largeTitle.minimumScaleFactor = 0.6;
    _largeTitle.frame = CGRectMake(20, y, W - 40, 44);
    [_content addSubview:_largeTitle];
    y += 54;
    BOOL searching = _query.length > 0 && _pill != nil;
    NSArray *secs = searching ? SearchSections(_query) : Sections(_pid);
    for (NSDictionary *sec in secs) {
        @try { y = [self addSection:sec y:y W:W]; }
        @catch (NSException *e) {
            PLog(@"section build failed: %@ %@", e.name, e.reason);
            UILabel *el = [self lbl:[NSString stringWithFormat:W12Tr(@"Lỗi hiển thị: %@\n%@"), e.name, e.reason] size:13 color:Hex(0xFF453A) weight:UIFontWeightRegular];
            el.numberOfLines = 0;
            el.frame = CGRectMake(20, y, W - 40, 80);
            [_content addSubview:el];
            y += 90;
        }
    }
    y += (_pill ? 96 : 24) + si.bottom;
    _content.frame = CGRectMake(0, 0, W, y);
    _scroll.contentSize = CGSizeMake(W, y);
    [self scrollViewDidScroll:_scroll];
}

#pragma mark Actions

- (void)swChanged:(UISwitch *)sw {
    NSDictionary *it = objc_getAssociatedObject(sw, kItemKey);
    if (it[@"bid"]) {                                       // exclusion list entry
        NSMutableArray *a = [ExcludeList() mutableCopy];
        [a removeObject:it[@"bid"]];
        if (sw.isOn) [a addObject:it[@"bid"]];
        PSet(@"exclude", a);
        return;
    }
    NSString *key = it[@"key"];
    PSet(key, @(sw.isOn));
    if ([key isEqualToString:@"uiLight"]) {
        gLight = sw.isOn;
        UIView *host = self;
        [UIView transitionWithView:host duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{ [self reloadAll]; [self layoutIfNeeded]; } completion:nil];
    }
}

- (void)slMoved:(UISlider *)sl {
    NSDictionary *it = objc_getAssociatedObject(sl, kItemKey);
    UILabel *val = objc_getAssociatedObject(sl, kValueLabelKey);
    double v = sl.value;
    if ([it[@"fmt"] rangeOfString:@"%.0f"].location != NSNotFound || [it[@"fmt"] rangeOfString:@"%+.0f"].location != NSNotFound) v = round(v);
    val.text = [NSString stringWithFormat:it[@"fmt"], v];
}
- (void)slDone:(UISlider *)sl {
    NSDictionary *it = objc_getAssociatedObject(sl, kItemKey);
    double v = sl.value;
    if ([it[@"fmt"] rangeOfString:@"%.0f"].location != NSNotFound || [it[@"fmt"] rangeOfString:@"%+.0f"].location != NSNotFound) { v = round(v); sl.value = v; }
    PSet(it[@"key"], @(v));
}
- (void)sgChanged:(UISegmentedControl *)sg {
    NSDictionary *it = objc_getAssociatedObject(sg, kItemKey);
    NSArray *vals = it[@"values"];
    if (sg.selectedSegmentIndex >= 0 && sg.selectedSegmentIndex < (NSInteger)vals.count) PSet(it[@"key"], vals[sg.selectedSegmentIndex]);
    if ([it[@"key"] isEqualToString:@"uiLang"]) dispatch_async(dispatch_get_main_queue(), ^{ W12LangReset(); [self rebuild]; });
}

- (void)push:(NSString *)pid {
    Class cls = NSClassFromString(W12S(W12ChildController));
    UIViewController *vc = [[cls alloc] init];
    [vc setValue:pid forKey:@"pid"];
    [_owner.navigationController pushViewController:vc animated:YES];
}
- (void)heroTap { [_field resignFirstResponder]; [self push:@"about"]; }

- (void)rowTap:(W12Row *)row {
    NSDictionary *it = row.item;
    [_field resignFirstResponder];
    if ([it[@"type"] isEqualToString:@"link"]) { [self push:it[@"page"]]; return; }
    NSString *a = it[@"action"];
    if ([a isEqualToString:@"reset"]) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:W12Tr(@"Khôi phục mặc định?") message:W12Tr(@"Các cài đặt của tweak này sẽ trở về giá trị ban đầu.") preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:W12Tr(@"Hủy") style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:W12Tr(@"Khôi phục") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            for (NSString *k in AllKeys()) CFPreferencesSetAppValue((__bridge CFStringRef)k, NULL, W12_DOMAIN);
            CFPreferencesAppSynchronize(W12_DOMAIN);
            notify_post("com.wave12.prefs");
            gLight = NO;
            [self reloadAll];
        }]];
        [_owner presentViewController:ac animated:YES completion:nil];
    } else if ([a isEqualToString:@"resetpage"]) {
        NSString *pg = it[@"page"];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:W12Tr(@"Đặt lại mặc định?") message:W12Tr(@"Các cài đặt trong trang này sẽ trở về giá trị ban đầu.") preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:W12Tr(@"Hủy") style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:W12Tr(@"Đặt lại") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            for (NSDictionary *sec in Sections(pg)) for (NSDictionary *r in sec[@"items"]) {
                NSString *k = r[@"key"];
                if (k.length && ![k isEqualToString:@"exclude"]) CFPreferencesSetAppValue((__bridge CFStringRef)k, NULL, W12_DOMAIN);
            }
            if ([pg isEqualToString:@"tab"]) CFPreferencesSetAppValue(CFSTR("tabLiftStd"), NULL, W12_DOMAIN);
            CFPreferencesAppSynchronize(W12_DOMAIN);
            notify_post("com.wave12.prefs");
            [self reloadAll];
        }]];
        [_owner presentViewController:ac animated:YES completion:nil];
    } else if ([a hasPrefix:@"test"]) {
        if (!PNum(@"island", 0)) {
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:W12Tr(@"Hãy bật Dynamic Island ảo trước.") preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [_owner presentViewController:ac animated:YES completion:nil];
        } else notify_post([[@"com.wave12.test." stringByAppendingString:[a substringFromIndex:4]] UTF8String]);
    } else if ([a isEqualToString:@"wallregen"]) {
        notify_post("com.wave12.wall.regen");
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:W12Tr(@"Đang tách nền hình khóa hiện tại. Mất vài giây đến vài chục giây, khóa máy rồi mở lại để xem kết quả.") preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [_owner presentViewController:ac animated:YES completion:nil];
    } else if ([a isEqualToString:@"respring"]) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Respring?" message:W12Tr(@"SpringBoard sẽ khởi động lại để áp dụng thay đổi.") preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:W12Tr(@"Hủy") style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            notify_post("com.wave12.respring");
        }]];
        [_owner presentViewController:ac animated:YES completion:nil];
    }
}

@end

#pragma mark - Controllers

static const void *kOrigPopDelegate = &kOrigPopDelegate;

static UIView *W12MakeView(NSString *pid, UIViewController *vc) {
    @try {
        PLog(@"building page %@", pid);
        return [[W12PageView alloc] initWithPage:pid owner:vc];
    } @catch (NSException *e) {
        PLog(@"page %@ failed: %@ %@", pid, e.name, e.reason);
        UIView *v = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
        v.backgroundColor = [UIColor blackColor];
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectInset(v.bounds, 20, 80)];
        l.numberOfLines = 0; l.textColor = [UIColor whiteColor]; l.font = [UIFont systemFontOfSize:14];
        l.text = [NSString stringWithFormat:W12Tr(@"2712: không dựng được trang Cài đặt.\n\n%@\n%@\n\nHãy chụp màn hình này gửi cho tác giả, và dùng mục \"2712 (dự phòng)\" trong Cài đặt."), e.name, e.reason];
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [v addSubview:l];
        return v;
    }
}

static void W12AppearImpl(UIViewController *vc, BOOL animated);
static void W12Appear(UIViewController *vc, BOOL animated) {
    @try { W12AppearImpl(vc, animated); }
    @catch (NSException *e) { PLog(@"appear failed: %@ %@", e.name, e.reason); }
}
static void W12AppearImpl(UIViewController *vc, BOOL animated) {
    UINavigationController *nav = vc.navigationController;
    [nav setNavigationBarHidden:YES animated:animated];
    UIGestureRecognizer *g = nav.interactivePopGestureRecognizer;
    if (g) {
        if (!objc_getAssociatedObject(nav, kOrigPopDelegate) && g.delegate != (id)vc)
            objc_setAssociatedObject(nav, kOrigPopDelegate, g.delegate, OBJC_ASSOCIATION_ASSIGN);
        g.delegate = (id<UIGestureRecognizerDelegate>)vc;
    }
    W12PageView *pv = (W12PageView *)vc.view;
    BOOL was = gLight;
    gLight = PNum(@"uiLight", 0) > 0.5;
    if ([pv isKindOfClass:[W12PageView class]]) { if (was != gLight) [pv applyTheme]; [pv reloadAll]; }
}

static void W12Disappear(UIViewController *vc, BOOL animated) {
    if (!vc.isMovingFromParentViewController) return;
    UINavigationController *nav = vc.navigationController;
    if ([vc isKindOfClass:NSClassFromString(W12S(W12RootController))]) {   // only when leaving the whole Wave12 screen
        [nav setNavigationBarHidden:NO animated:animated];
        UIGestureRecognizer *g = nav.interactivePopGestureRecognizer;
        id orig = objc_getAssociatedObject(nav, kOrigPopDelegate);
        if (g && orig) g.delegate = orig;
    }
}

@interface W12RootController : PSViewController <UIGestureRecognizerDelegate>
@property (nonatomic, copy) NSString *pid;
@end
@implementation W12RootController
- (void)loadView { self.view = W12MakeView(@"root", self); }
- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; W12Appear(self, a); }
- (void)viewWillDisappear:(BOOL)a { [super viewWillDisappear:a]; W12Disappear(self, a); }
- (UIStatusBarStyle)preferredStatusBarStyle { return gLight ? UIStatusBarStyleDefault : UIStatusBarStyleLightContent; }
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g { return self.navigationController.viewControllers.count > 1; }
@end

@interface W12HomeController : W12RootController
@end
@implementation W12HomeController
- (void)loadView { self.view = W12MakeView(@"h26", self); }
@end

@interface W12ChildController : UIViewController <UIGestureRecognizerDelegate>
@property (nonatomic, copy) NSString *pid;
@end
@implementation W12ChildController
- (void)loadView { self.view = W12MakeView(self.pid ?: @"about", self); }
- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; W12Appear(self, a); }
- (void)viewWillDisappear:(BOOL)a { [super viewWillDisappear:a]; W12Disappear(self, a); }
- (UIStatusBarStyle)preferredStatusBarStyle { return gLight ? UIStatusBarStyleDefault : UIStatusBarStyleLightContent; }
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g { return self.navigationController.viewControllers.count > 1; }
@end
