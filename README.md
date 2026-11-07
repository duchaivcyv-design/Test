# Wave12

Port/viết lại tweak **26Unlock** (blu_tek, iOS 16 rootless) cho **iOS 12 (rootful)** — tối ưu iPhone 6.
Khi mở khóa hoặc thoát app về Home, icon + dock bay ra theo làn sóng từ tâm màn hình, bằng spring tắt dần tới hạn (**không nảy**).
Chỉ animate transform/position/opacity (chạy hoàn toàn trên GPU, không blur/shadow) nên mượt trên A8.

## Cài
- Dùng file trong `prebuilt/` (hoặc tab Actions → artifact `Wave12-deb`) rồi cài bằng Filza/dpkg: `dpkg -i *.deb`, sau đó respring.
- Cần: unc0ver/Chimera/checkra1n (rootful), Substrate/Substitute và `PreferenceLoader` (trang Cài đặt cần gói này).

## Build
Push repo lên GitHub → Actions tự build ra `.deb`. Hoặc cục bộ: `export THEOS=~/theos && make package`.

## Gỡ lỗi
Log nằm trong syslog của SpringBoard, lọc theo `[Wave12]`: các dòng `hooked ...` cho biết hook nào gắn được, `skip/sig mismatch` là hook không khớp trên bản iOS của bạn.

## Log chẩn đoán
Tweak ghi log vào `/var/mobile/Library/Logs/Wave12.log` (mở bằng Filza). Gửi file này khi hiệu ứng mở/đóng app không chạy.

## Trang Cài đặt kiểu iOS 26 (v3.0.0)
Thư mục `wave12prefs/` là một Preferences bundle riêng (không dùng bảng Root.plist mặc định), vẽ giao diện giống app Cài đặt iOS 26:
nền tối, nhóm bo tròn kiểu kính, icon màu bo góc, tiêu đề lớn thu nhỏ khi cuộn, nút quay lại tròn, thanh tìm kiếm nổi (lọc được mọi mục), công tắc xanh lá,
chế độ giao diện sáng, nút Khôi phục mặc định và Respring. Mọi giá trị lưu ở domain `com.wave12.unlockwave`, cùng khóa với tweak.

## Khi có lỗi
Nếu trang chính văng, lấy báo cáo lỗi: Cài đặt → Quyền riêng tư → Phân tích & Cải tiến → Dữ liệu phân tích → tệp `Preferences-…` (hoặc `/var/mobile/Library/Logs/CrashReporter`), và tệp `/var/mobile/Library/Logs/Wave12.log`.
