#!/usr/bin/env python3
"""packall.py <srcdir> <builddir> <version> <outdir> [repo_dir]
Builds one .deb per module (+ the optional meta package) from the output of buildmod.sh."""
import os, sys, shutil, subprocess, json, colorsys, plistlib, tempfile
from PIL import Image, ImageDraw, ImageFont
SRC, B, VER, OUT = [os.path.abspath(x) for x in sys.argv[1:5]]; VER = sys.argv[3]
REPO = sys.argv[5] if len(sys.argv) > 5 else None
os.makedirs(OUT, exist_ok=True)
RES = SRC + "/wave12prefs/Resources"
DEP = "mobilesubstrate, preferenceloader, firmware (>= 11.0)"
# id: (pkg, name, dylib, bundle, filter, hue shift, section blurb, bullets, settings path)
M = {
 "code":  ("com.wave12.unlockcode", "UnlockCode", "W12-1-unlockcode", "W12PrefCode",  "sb", 0.62, "Phím mật khẩu nảy kiểu iOS 26",
           ["Phím mã khóa nảy theo làn sóng khi chạm", "Viền kính quanh từng phím", "Chạy độc lập, không cần tweak nào khác"]),
 "wave":  ("com.wave12.unlockwave", "OpenWave", "W12-2-openwave", "Wave12Prefs", "sb", 0.0, "Hiệu ứng mở khóa lan từ tâm",
           ["Mở khóa: icon bay ra theo làn sóng từ tâm màn hình", "Thoát app về Home cũng chạy làn sóng", "Chỉnh độ phóng, độ trễ, độ nảy, tốc độ", "Danh sách loại trừ ứng dụng"]),
 "morph": ("com.wave12.morph26", "26Morph", "W12-3-26morph", "W12PrefMorph", "sb", 0.74, "Hiệu ứng mở / đóng ứng dụng kiểu iOS 26",
           ["Ứng dụng phóng ra từ đúng icon vừa chạm, thu về icon khi thoát", "Bo góc, nghiêng 3D, làm mờ màn hình chính", "Nếu có DynaFake: app bay vào island khi thoát", "Danh sách loại trừ ứng dụng"]),
 "tab":   ("com.wave12.liquidtab", "Liquid Tab", "W12-4-liquidtab", "W12PrefTab", "ui", 0.09, "Thanh tab kính nổi",
           ["Thanh tab nổi bằng kính, viên thấu kính lỏng khi chạm giữ", "Tự đổi sáng / tối theo nền", "Danh sách loại trừ ứng dụng"]),
 "home":  ("com.wave12.home26", "26Home", "W12-5-26home", "W12PrefHome", "sb", 0.33, "Icon màn hình chính kiểu iOS 26",
           ["Kiểu icon: Mặc định, Tối, Trong suốt, Phủ màu", "Giữ vào chỗ trống để mở bảng tùy chỉnh", "Kèm bộ icon iOS 26 (~19 MB)"]),
 "cc":    ("com.wave12.cc27", "27CC", "W12-6-27cc", "W12PrefCC", "sb", 0.52, "Trung tâm điều khiển kiểu kính",
           ["Viền kính mảnh quanh các ô trong Trung tâm điều khiển", "Bo tròn ô, chỉnh độ đặc nền ô"]),
 "box":   ("com.wave12.box26", "26Box", "W12-7-26box", "W12PrefBox", "ui", 0.88, "Hộp thoại kiểu iOS 26",
           ["Hộp thoại & bảng chọn: nút viên thuốc trong suốt, xếp chồng, chữ canh giữa", "Hoạt động trong SpringBoard và mọi ứng dụng"]),
 "wall":  ("com.wave12.wall26", "26Wall", "W12-8-26wall", "W12PrefWall", "sb", 0.0, "Màn hình khóa kiểu iOS 16: chủ thể che đồng hồ",
           ["Tự tách người, thú cưng, vật nổi bật khỏi hình nền khóa bằng AI chạy ngay trên máy", "Đồng hồ chìm phía sau chủ thể, che cả ngày tháng", "Đồng hồ lớn chữ dày, chọn màu đồng hồ", "Có nút tách lại; gói kèm mô hình AI (~4,5 MB)"]),
 "dyna":  ("com.wave12.dynafake", "DynaFake", "W12-9-dynafake", "W12PrefDyna", "ui", 0.58, "Dynamic Island ảo",
           ["Island ảo: hẹn giờ, bấm giờ, báo thức, nhạc, cuộc gọi, âm lượng, đèn pin, pin yếu, sạc", "Hiệu ứng Face ID khi mở khóa + ổ khóa trên màn hình khóa", "Thanh trạng thái gọn", "Cần được nạp sau cùng (đã đặt tên tệp để tự đúng thứ tự)"]),
}
ORDER = ["code", "wave", "morph", "tab", "home", "cc", "box", "wall", "dyna"]

def hue(im, shift):
    if shift == 0: return im.copy()
    rgba = im.convert("RGBA"); px = rgba.load(); w, h = rgba.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            hh, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            r2, g2, b2 = colorsys.hsv_to_rgb((hh + shift) % 1, s, v)
            px[x, y] = (int(r2 * 255), int(g2 * 255), int(b2 * 255), a)
    return rgba
def banner(name, shift):
    im = hue(Image.open(RES + "/banner.png").convert("RGB"), shift)
    d = ImageDraw.Draw(im, "RGBA"); W, H = im.size
    f = ImageFont.truetype("/usr/share/fonts/truetype/google-fonts/Poppins-Bold.ttf", 170)
    tw = d.textlength(name, font=f)
    d.rounded_rectangle((W / 2 - tw / 2 - 50, H / 2 - 150, W / 2 + tw / 2 + 50, H / 2 + 150), 70, fill=(0, 0, 0, 120))
    d.text((W / 2, H / 2), name, font=f, fill=(255, 255, 255, 255), anchor="mm")
    return im


TILE = {"code": ((94,92,230),(60,58,190)), "wave": ((10,132,255),(0,90,210)), "morph": ((191,90,242),(140,50,200)), "tab": ((255,159,10),(230,110,0)),
        "home": ((48,209,88),(25,160,60)), "cc": ((100,210,255),(40,150,220)), "box": ((255,69,58),(200,30,40)), "wall": ((255,55,95),(120,40,200)), "dyna": ((58,58,60),(10,10,12)), "suite": ((52,199,89),(30,150,60))}
def glyph(mod, sz=720):
    S = sz; a, b = TILE[mod]
    im = Image.new("RGBA", (S, S)); px = im.load()
    for y in range(S):
        t = y / (S - 1)
        for x in range(S): px[x, y] = (int(a[0]+(b[0]-a[0])*t), int(a[1]+(b[1]-a[1])*t), int(a[2]+(b[2]-a[2])*t), 255)
    d = ImageDraw.Draw(im, "RGBA"); W = (255, 255, 255, 255); c = S / 2; u = S / 100
    if mod == "code":
        for i in range(3):
            for j in range(3):
                x = c + (j-1)*22*u; y = c + (i-1)*22*u - 3*u; d.ellipse((x-8.5*u, y-8.5*u, x+8.5*u, y+8.5*u), fill=W if (i, j) != (1, 1) else (255, 255, 255, 150))
        d.ellipse((c-8.5*u, c+57*u-S/2+10*u, c+8.5*u, c+74*u-S/2+10*u), fill=W) if False else None
    elif mod == "wave":
        for r, al in ((36, 255), (25, 200), (14, 255)):
            d.ellipse((c-r*u, c-r*u, c+r*u, c+r*u), outline=(255, 255, 255, al), width=int(5.5*u))
        d.ellipse((c-4*u, c-4*u, c+4*u, c+4*u), fill=W)
    elif mod == "morph":
        d.rounded_rectangle((c-36*u, c-36*u, c+36*u, c+36*u), 14*u, outline=(255, 255, 255, 140), width=int(5*u))
        d.rounded_rectangle((c-20*u, c-20*u, c+20*u, c+20*u), 9*u, fill=W)
    elif mod == "tab":
        d.rounded_rectangle((c-40*u, c-17*u, c+40*u, c+17*u), 17*u, fill=(255, 255, 255, 110))
        d.rounded_rectangle((c-16*u, c-23*u, c+30*u, c+23*u), 23*u, fill=W)
    elif mod == "home":
        for i in (-1, 1):
            for j in (-1, 1):
                x = c + j*20*u; y = c + i*20*u; d.rounded_rectangle((x-15*u, y-15*u, x+15*u, y+15*u), 7*u, fill=W)
    elif mod == "cc":
        d.rounded_rectangle((c-38*u, c-38*u, c-2*u, c-2*u), 12*u, fill=W)
        d.rounded_rectangle((c+2*u, c-38*u, c+38*u, c-2*u), 12*u, fill=(255, 255, 255, 170))
        d.rounded_rectangle((c-38*u, c+2*u, c+38*u, c+38*u), 17*u, fill=(255, 255, 255, 220))
        d.ellipse((c+14*u, c+8*u, c+32*u, c+32*u), fill=(60, 150, 220, 255))
    elif mod == "box":
        d.rounded_rectangle((c-36*u, c-30*u, c+36*u, c+30*u), 14*u, fill=W)
        for k in (-1, 1): d.rounded_rectangle((c+k*17*u-13*u, c+9*u, c+k*17*u+13*u, c+22*u), 6.5*u, fill=(220, 40, 50, 255))
        d.rounded_rectangle((c-18*u, c-17*u, c+18*u, c-10*u), 3.5*u, fill=(200, 200, 205, 255))
    elif mod == "wall":
        d.rounded_rectangle((c-40*u, c-34*u, c+40*u, c-4*u), 10*u, fill=(255, 255, 255, 150))
        d.ellipse((c-17*u, c-24*u, c+17*u, c+10*u), fill=W)
        d.rounded_rectangle((c-34*u, c+8*u, c+34*u, c+44*u), 20*u, fill=W)
    elif mod == "dyna":
        d.rounded_rectangle((c-34*u, c-34*u, c+34*u, c-8*u), 13*u, fill=(0, 0, 0, 255), outline=W, width=int(4*u))
        d.ellipse((c+14*u, c-28*u, c+25*u, c-14*u), fill=(255, 255, 255, 120))
        d.rounded_rectangle((c-34*u, c+8*u, c+34*u, c+34*u), 8*u, fill=(255, 255, 255, 60))
    else:   # suite: bolt
        d.polygon([(c+8*u, c-42*u), (c-24*u, c+6*u), (c-3*u, c+6*u), (c-10*u, c+42*u), (c+24*u, c-8*u), (c+3*u, c-8*u)], fill=W)
    return im
def icons(mod, d):
    g = glyph(mod)
    for f, n in (("icon.png", 29), ("icon@2x.png", 58), ("icon@3x.png", 87), ("sileo-icon.png", 180)):
        g.resize((n, n), Image.LANCZOS).save(d + "/" + f)

def control(pkg, name, desc, depends, bundle=None, extra=""):
    t = "Package: %s\nName: %s\n" % (pkg, name)
    if depends: t += "Depends: %s\n" % depends
    t += "Version: %s\nArchitecture: iphoneos-arm\nDescription: %s\nMaintainer: PucPucPuc\nAuthor: PucPucPuc\nSection: Tweaks\n" % (VER, desc)
    if bundle:
        t += "Icon: file:///Library/PreferenceBundles/%s.bundle/sileo-icon.png\nSileoDepiction: file:///Library/PreferenceBundles/%s.bundle/depiction.json\n" % (bundle, bundle)
    return t + extra

def depiction(pkg, name, tag, bullets, header, changelog):
    md = "**%s** — %s.\n\n" % (name, tag) + "\n".join("- " + b for b in bullets) + "\n\nTách ra từ tweak 2712: chạy độc lập, có trang cài đặt riêng tại **Cài đặt › %s**." % name
    return {"minVersion": "0.1", "class": "DepictionTabView", "tintColor": "#34C759", "tabs": [
        {"tabname": "Chi tiết", "class": "DepictionStackView", "views": [
            {"class": "DepictionSubheaderView", "title": tag, "useBoldText": True, "useBottomMargin": False},
            {"class": "DepictionMarkdownView", "markdown": md, "useSpacing": True},
            {"class": "DepictionSeparatorView"},
            {"class": "DepictionTableTextView", "title": "Tác giả", "text": "PucPucPuc"},
            {"class": "DepictionTableTextView", "title": "Phiên bản", "text": VER},
            {"class": "DepictionTableTextView", "title": "Hỗ trợ", "text": "iOS 12 · arm64 · rootful"},
            {"class": "DepictionSpacerView", "spacing": 16}]},
        {"tabname": "Thay đổi nhật ký", "class": "DepictionStackView", "views": [
            {"class": "DepictionMarkdownView", "markdown": changelog, "useSpacing": True}]}]}

CHANGELOG_T = "### %s\n- Bỏ banner ở trang cài đặt, icon riêng cho từng tweak\n- Chưa kiểm tra trên máy thật"
SUITELOG_T = "### %s\n- Cập nhật theo các tweak lẻ: 26Home 6.0.4 (icon Đồng hồ thay thẳng mặt hệ thống)\n- Chưa kiểm tra trên máy thật"
HOMELOG_T = "### %s\n- Icon Đồng hồ: thay thẳng mặt đồng hồ của icon hệ thống (kim vẫn chạy thật), không còn lấy icon khác đè lên\n- Có bộ icon iOS 27 (Cài đặt > 26Home > Bộ icon), iOS 18 sẽ thêm khi có file\n- Chưa kiểm tra trên máy thật"
CCLOG_T = "### %s\n- Sửa lỗi mất bo cong: phần nền của các ô giờ bo tròn khớp với viền kính\n- Chưa kiểm tra trên máy thật"
WALLLOG_T = "### %s\n- Hết run nhẹ: hình tách không còn đọc vị trí của hình nền (vốn bị hiệu ứng parallax làm rung), đặt cố định giữa màn hình\n- Vẫn mờ dần cùng đồng hồ khi hiện bàn phím mật mã\n- Chưa kiểm tra trên máy thật"

# Per-tweak versions: only bump the tweak that actually changed (the others keep their number so Sileo shows no useless update).
VERS = {"wall": "1.0.7", "cc": "6.0.5", "home": "6.0.4", "suite": "6.1.3"}      # every other tweak: DEFAULT_VER
DEFAULT_VER = "6.0.2"
def build(mod):
    global VER
    VER = VERS.get(mod, DEFAULT_VER)
    pkg, name, dylib, bundle, flt, shift, tag, bullets = M[mod]
    st = tempfile.mkdtemp() + "/pkg"
    dl = st + "/Library/MobileSubstrate/DynamicLibraries"; os.makedirs(dl)
    bd = st + "/Library/PreferenceBundles/%s.bundle" % bundle; os.makedirs(bd)
    pl = st + "/Library/PreferenceLoader/Preferences"; os.makedirs(pl); os.makedirs(st + "/DEBIAN")
    shutil.copy("%s/%s.dylib" % (B, dylib), dl)
    bundles = ["com.apple.springboard"] if flt == "sb" else ["com.apple.springboard", "com.apple.UIKit", "com.apple.UIKitCore"]
    plistlib.dump({"Filter": {"Bundles": bundles}}, open("%s/%s.plist" % (dl, dylib), "wb"), fmt=plistlib.FMT_XML)
    shutil.copy("%s/%s.bundle/%s" % (B, bundle, bundle), bd)
    icons(mod, bd)
    plistlib.dump({"CFBundleDevelopmentRegion": "en", "CFBundleExecutable": bundle, "CFBundleIdentifier": "com.wave12.prefs." + mod,
                   "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": bundle, "CFBundlePackageType": "BNDL",
                   "CFBundleShortVersionString": VER, "CFBundleVersion": VER, "NSPrincipalClass": "W12RootController_" + mod, "MinimumOSVersion": "11.0"},
                  open(bd + "/Info.plist", "wb"), fmt=plistlib.FMT_XML)
    plistlib.dump({"entry": {"bundle": bundle, "cell": "PSLinkCell", "detail": "W12RootController_" + mod, "icon": "icon.png", "isController": True, "label": name}},
                  open("%s/%s.plist" % (pl, bundle), "wb"), fmt=plistlib.FMT_XML)
    json.dump(depiction(pkg, name, tag, bullets, None, (WALLLOG_T if mod == "wall" else CCLOG_T if mod == "cc" else HOMELOG_T if mod == "home" else CHANGELOG_T) % VER), open(bd + "/depiction.json", "w"), ensure_ascii=False, indent=1)
    if mod == "wall":
        os.makedirs(st + "/usr/libexec"); shutil.copy(B + "/26wallseg", st + "/usr/libexec/26wallseg"); os.chmod(st + "/usr/libexec/26wallseg", 0o755)
        os.makedirs(st + "/Library/Application Support/26Wall"); shutil.copy(SRC + "/wall/u2netp_256.u2p", st + "/Library/Application Support/26Wall/u2netp_256.u2p")
    if mod == "home":
        shutil.copytree(SRC + "/layout/Library/Application Support", st + "/Library/Application Support")
    desc = "%s\n %s." % (tag, " · ".join(bullets[:2]))
    open(st + "/DEBIAN/control", "w").write(control(pkg, name, desc, DEP, bundle, "Suggests: preferenceloader\n"))
    os.chmod(st + "/DEBIAN", 0o755)
    out = "%s/%s_%s_iphoneos-arm.deb" % (OUT, pkg, VER)
    subprocess.check_call(["dpkg-deb", "-Zgzip", "-b", st, out], stdout=subprocess.DEVNULL)
    print("PACK OK", out, os.path.getsize(out))
    if REPO:
        d = REPO + "/depictions"
        json.dump(depiction(pkg, name, tag, bullets, None, (WALLLOG_T if mod == "wall" else CCLOG_T if mod == "cc" else HOMELOG_T if mod == "home" else CHANGELOG_T) % VER), open("%s/%s.json" % (d, pkg), "w"), ensure_ascii=False)
    return out

def meta():
    global VER
    VER = VERS["suite"]
    pkg = "com.wave12.suite"; st = tempfile.mkdtemp() + "/pkg"; os.makedirs(st + "/DEBIAN")
    deps = ", ".join(M[m][0] for m in ORDER)
    open(st + "/DEBIAN/control", "w").write(control(pkg, "2712 (trọn bộ)", "Cài đủ 9 tweak của 2712 một lần", deps))
    out = "%s/%s_%s_iphoneos-arm.deb" % (OUT, pkg, VER)
    subprocess.check_call(["dpkg-deb", "-Zgzip", "-b", st, out], stdout=subprocess.DEVNULL)
    print("PACK OK", out, os.path.getsize(out))
    if REPO:
        json.dump(depiction(pkg, "2712 (trọn bộ)", "Cài đủ 9 tweak của 2712 một lần", ["UnlockCode · OpenWave · 26Morph · Liquid Tab · 26Home · 27CC · 26Box · 26Wall · DynaFake"], None, SUITELOG_T % VER).copy(), open(REPO + "/depictions/%s.json" % pkg, "w"), ensure_ascii=False)
import os as _os
ONLY = [x for x in _os.environ.get('ONLY','').split(',') if x]
for m in ORDER:
    if not ONLY or m in ONLY: build(m)
meta()      # the suite is re-packed with every update of any single tweak (version bumped by hand in VERS)
