#!/bin/bash
# usage: buildmod.sh <srcdir (Wave12)> <outdir> <mod id>   -> <outdir>/<dylib>.dylib and <outdir>/<bundle>.bundle/<bundle>
set -e
SRC=$1; OUT=$2; MOD=$3; SDK=/home/claude/sdks/iPhoneOS12.4.sdk; LDID=/home/claude/local/ldid
. $SRC/tools/mods.sh; modinfo $MOD
mkdir -p $OUT/obj; O=$OUT/obj/$MOD
RN=""; for c in $CLASSES; do RN="$RN -D$c=${c}_$MOD"; done
CF="-target arm64-apple-ios11.0 -isysroot $SDK -fobjc-arc -Os -fvisibility=hidden -Wno-deprecated-declarations -Wno-error -Wno-everything -I$SRC -D$M_FLAG=1 -DW12_MOD_S=$MOD -DW12_ENKEY_S=$M_EN $RN"
FILES="Tweak"; [ $MOD = tab ] && FILES="Tweak TabBar"
OBJS=""
for f in $FILES; do clang $CF -c $SRC/$f.m -o ${O}_$f.o & OBJS="$OBJS ${O}_$f.o"; done; wait
ld64.lld-18 -arch arm64 -platform_version ios 11.0 12.4 -dylib -dead_strip -syslibroot $SDK -lSystem -lobjc \
  -install_name /Library/MobileSubstrate/DynamicLibraries/$M_DYLIB.dylib \
  -framework UIKit -framework QuartzCore -framework CoreGraphics -framework Foundation -framework CoreFoundation -framework ImageIO \
  $OBJS -o $OUT/$M_DYLIB.dylib
$LDID -S $OUT/$M_DYLIB.dylib
# preferences bundle
PR=""; for c in $PCLASSES; do PR="$PR -D$c=${c}_$MOD"; done
clang -target arm64-apple-ios11.0 -isysroot $SDK -fobjc-arc -Os -fvisibility=hidden -Wno-everything -I$SRC -DW12_PM_$MOD=1 -DW12_PMOD_S=$MOD $PR -c $SRC/wave12prefs/W12Prefs.m -o ${O}_prefs.o
mkdir -p $OUT/$M_BUNDLE.bundle
ld64.lld-18 -arch arm64 -platform_version ios 11.0 12.4 -bundle -dead_strip -syslibroot $SDK -lSystem -lobjc \
  -F$SDK/System/Library/PrivateFrameworks -framework Preferences -framework UIKit -framework QuartzCore -framework CoreGraphics -framework Foundation \
  ${O}_prefs.o -o $OUT/$M_BUNDLE.bundle/$M_BUNDLE
$LDID -S $OUT/$M_BUNDLE.bundle/$M_BUNDLE
echo BUILD OK $MOD
