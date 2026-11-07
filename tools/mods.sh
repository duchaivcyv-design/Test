# Module table:  id | -D flag | master pref key | package id | display name | dylib file | prefs bundle | filter kind
# filter kind: sb = SpringBoard only, ui = SpringBoard + every UIKit app
MODS="code wave morph tab home cc box wall dyna"
modinfo() {   # $1 = id -> sets M_FLAG M_EN M_PKG M_NAME M_DYLIB M_BUNDLE M_FILTER M_DESC
  case $1 in
    code)  M_FLAG=W12_M_CODE;  M_EN=en_code;  M_PKG=com.wave12.unlockcode; M_NAME=UnlockCode;  M_DYLIB=W12-1-unlockcode; M_BUNDLE=W12PrefCode;  M_FILTER=sb ;;
    wave)  M_FLAG=W12_M_WAVE;  M_EN=enabled;  M_PKG=com.wave12.unlockwave; M_NAME=OpenWave;    M_DYLIB=W12-2-openwave;   M_BUNDLE=Wave12Prefs;  M_FILTER=sb ;;
    morph) M_FLAG=W12_M_MORPH; M_EN=en_morph; M_PKG=com.wave12.morph26;    M_NAME=26Morph;     M_DYLIB=W12-3-26morph;    M_BUNDLE=W12PrefMorph; M_FILTER=sb ;;
    tab)   M_FLAG=W12_M_TAB;   M_EN=en_tab;   M_PKG=com.wave12.liquidtab;  M_NAME="Liquid Tab"; M_DYLIB=W12-4-liquidtab;  M_BUNDLE=W12PrefTab;   M_FILTER=ui ;;
    home)  M_FLAG=W12_M_HOME;  M_EN=en_home;  M_PKG=com.wave12.home26;     M_NAME=26Home;      M_DYLIB=W12-5-26home;     M_BUNDLE=W12PrefHome;  M_FILTER=sb ;;
    cc)    M_FLAG=W12_M_CC;    M_EN=en_cc;    M_PKG=com.wave12.cc27;       M_NAME=27CC;        M_DYLIB=W12-6-27cc;       M_BUNDLE=W12PrefCC;    M_FILTER=sb ;;
    box)   M_FLAG=W12_M_BOX;   M_EN=en_box;   M_PKG=com.wave12.box26;      M_NAME=26Box;       M_DYLIB=W12-7-26box;      M_BUNDLE=W12PrefBox;   M_FILTER=ui ;;
    wall)  M_FLAG=W12_M_WALL;  M_EN=en_wall;  M_PKG=com.wave12.wall26;     M_NAME=26Wall;      M_DYLIB=W12-8-26wall;     M_BUNDLE=W12PrefWall;  M_FILTER=sb ;;
    dyna)  M_FLAG=W12_M_DYNA;  M_EN=en_dyna;  M_PKG=com.wave12.dynafake;   M_NAME=DynaFake;    M_DYLIB=W12-9-dynafake;   M_BUNDLE=W12PrefDyna;  M_FILTER=ui ;;
  esac
}
CLASSES="H26Glass H26Slider H26UI H26Window W12AlertTicker W12CardState W12CloseWatch W12FixedLabel W12Island W12IslandBtn W12IslandVC W12IslandWindow W12PCTramp W12PillView W12TabBack W12TabCtl W12TabLens W12Ticker W12WallLinker"
PCLASSES="W12ChildController W12HomeController W12PageView W12RootController W12Row"
