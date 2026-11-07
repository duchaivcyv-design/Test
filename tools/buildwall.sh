#!/bin/bash
# usage: buildwall.sh <srcdir (Wave12)> <outdir>  -> <outdir>/26wallseg   (segmentation helper run by the 26Wall tweak)
set -e
SRC=$1; OUT=$2; SDK=/home/claude/sdks/iPhoneOS12.4.sdk; mkdir -p $OUT/wobj; W=$SRC/wall
C="-target arm64-apple-ios11.0 -isysroot $SDK -Wno-everything -I$W"
clang $C -fobjc-arc -O2 -c $W/wallseg.m -o $OUT/wobj/wallseg.o
clang $C -O3 -c $W/u2seg.c -o $OUT/wobj/u2seg.o
clang $C -O3 -c $W/wallcore.c -o $OUT/wobj/wallcore.o
ld64.lld-18 -arch arm64 -platform_version ios 11.0 12.4 -syslibroot $SDK -e _main -lSystem -lobjc -framework Foundation -framework ImageIO -framework CoreGraphics -framework Accelerate \
  $OUT/wobj/wallseg.o $OUT/wobj/u2seg.o $OUT/wobj/wallcore.o -o $OUT/26wallseg
/home/claude/local/ldid -S $OUT/26wallseg
echo BUILD OK 26wallseg
