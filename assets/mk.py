from PIL import Image, ImageDraw, ImageFilter, ImageFont
import math
F='/usr/share/fonts/opentype/inter/'
def font(n,s): return ImageFont.truetype(F+n,s)
def hexc(h): return ((h>>16)&255,(h>>8)&255,h&255)
def mix(c,t): return tuple(int(x+(255-x)*t) for x in c)
G=hexc(0x34C759)
BOLT=[(17.5,5),(9,16.8),(14.4,16.8),(12.5,25),(21.2,12.8),(15.6,12.8)]

def icon(size, rounded=False):
    S=4; n=size*S
    bg=Image.new('RGB',(n,n))
    top=mix(G,0.22); bot=G
    px=bg.load()
    d=ImageDraw.Draw(bg)
    for y in range(n):
        t=y/(n-1); d.line([(0,y),(n,y)],fill=tuple(int(top[i]+(bot[i]-top[i])*t) for i in range(3)))
    # soft top gloss
    gl=Image.new('RGBA',(n,n),(0,0,0,0)); gd=ImageDraw.Draw(gl)
    gd.ellipse([-n*0.25,-n*0.75,n*1.25,n*0.52],fill=(255,255,255,46))
    bg=Image.alpha_composite(bg.convert('RGBA'),gl)
    # bolt (grid 30 like the in-app icon)
    k=n/30.0
    pts=[(x*k,y*k) for x,y in BOLT]
    sh=Image.new('RGBA',(n,n),(0,0,0,0)); sd=ImageDraw.Draw(sh)
    sd.polygon([(x,y+n*0.018) for x,y in pts],fill=(0,70,20,120))
    sh=sh.filter(ImageFilter.GaussianBlur(n*0.02))
    bg=Image.alpha_composite(bg,sh)
    bd=ImageDraw.Draw(bg); bd.polygon(pts,fill=(255,255,255,255))
    bd.line(pts+[pts[0]],fill=(255,255,255,255),width=int(k*1.0),joint='curve')
    out=bg.resize((size,size),Image.LANCZOS)
    if rounded:
        m=Image.new('L',(size*4,size*4),0); ImageDraw.Draw(m).rounded_rectangle([0,0,size*4-1,size*4-1],radius=int(size*4*0.225),fill=255)
        m=m.resize((size,size),Image.LANCZOS); out.putalpha(m)
    return out

def banner(W=1500,H=600):
    img=Image.new('RGB',(W,H))
    d=ImageDraw.Draw(img)
    for y in range(H):
        t=y/(H-1); c=(int(5+8*t),int(14+22*t),int(12+20*t)); d.line([(0,y),(W,y)],fill=c)
    def glow(cx,cy,r,col,a):
        l=Image.new('RGBA',(W,H),(0,0,0,0)); ld=ImageDraw.Draw(l)
        ld.ellipse([cx-r,cy-r,cx+r,cy+r],fill=col+(a,)); l=l.filter(ImageFilter.GaussianBlur(r*0.45))
        return l
    img=Image.alpha_composite(img.convert('RGBA'),glow(260,300,330,(52,199,89),120))
    img=Image.alpha_composite(img,glow(1250,80,300,(10,190,170),85))
    img=Image.alpha_composite(img,glow(1000,640,380,(60,120,255),55))
    # liquid ripples
    rp=Image.new('RGBA',(W,H),(0,0,0,0)); rd=ImageDraw.Draw(rp)
    for i,r in enumerate([250,360,480,610,750]):
        rd.ellipse([260-r,300-r,260+r,300+r],outline=(255,255,255,max(8,34-i*6)),width=2)
    img=Image.alpha_composite(img,rp)
    # icon tile with glow
    ic=icon(300,rounded=True)
    g=Image.new('RGBA',(W,H),(0,0,0,0)); g.paste(Image.new('RGBA',(300,300),(52,199,89,150)),(110,150))
    g=g.filter(ImageFilter.GaussianBlur(46)); img=Image.alpha_composite(img,g)
    img.alpha_composite(ic,(110,150))
    # rim on icon
    d=ImageDraw.Draw(img)
    d.rounded_rectangle([110,150,410,450],radius=68,outline=(255,255,255,90),width=3)
    # text
    d.text((480,128),"2712",font=font('InterDisplay-Bold.otf',168),fill=(255,255,255,255))
    d.text((486,330),"Giao diện iOS 26 cho iOS 12",font=font('Inter-SemiBold.otf',46),fill=(222,246,230,255))
    d.text((486,396),"Liquid Glass  ·  Dynamic Island  ·  Hộp thoại  ·  Công tắc",font=font('Inter-Medium.otf',30),fill=(170,205,185,255))
    # glass chips
    chips=["Mở khóa","Mở / đóng app","Thanh tab kính","Trung tâm điều khiển"]
    x=486; y=474; f=font('Inter-Medium.otf',27)
    ov=Image.new('RGBA',(W,H),(0,0,0,0)); od=ImageDraw.Draw(ov)
    for c in chips:
        w=int(od.textlength(c,font=f))+44
        od.rounded_rectangle([x,y,x+w,y+58],radius=29,fill=(255,255,255,34),outline=(255,255,255,96),width=2)
        od.text((x+22,y+13),c,font=f,fill=(255,255,255,235)); x+=w+16
    img=Image.alpha_composite(img,ov)
    d=ImageDraw.Draw(img)
    d.text((W-40,H-52),"PucPucPuc",font=font('Inter-SemiBold.otf',28),fill=(255,255,255,150),anchor='ra')
    return img.convert('RGB')

icon(512).save('icon-512.png')                      # full-bleed (Sileo / Cydia round the corners themselves)
icon(180).save('icon-180.png')
banner().save('banner.png'); banner().resize((750,300),Image.LANCZOS).save('banner-750.png')
