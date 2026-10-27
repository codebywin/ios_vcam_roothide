//
//  VCAMColorPickerView.h
//  VCAM iOS - On-Screen Loupe Eyedropper & Screen Pixel Reader
//
//  Cơ chế trích xuất màu pixel màn hình theo VcamNextPlus:
//  - Vòng Loupe hiển thị trực quan điểm (X, Y) và màu live real-time
//  - CARenderServerRenderDisplay + IOSurface lấy màu chuẩn xác từng pixel
//  - Kéo thả tự do trên toàn màn hình, hỗ trợ lấy màu da mặt, môi, ánh sáng môi trường
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCAMColorPickerView : UIView

/// Hiển thị kính lúp lấy màu trên màn hình
+ (void)showColorPicker;

/// Ẩn kính lúp lấy màu
+ (void)hideColorPicker;

/// Kiểm tra kính lúp có đang hiển thị hay không
+ (BOOL)isColorPickerVisible;

/// Lấy màu hiện tại mà kính lúp đang chỉ vào
+ (UIColor *)currentlySampledColor;

/// Bật chế độ chạy ngầm tự động bắt màu nháy màn hình eKYC (Active Flash Tracking)
+ (void)startBackgroundFlashTracking;

/// Dừng chế độ chạy ngầm bắt nháy
+ (void)stopBackgroundFlashTracking;

/// Kiểm tra chế độ chạy ngầm bắt nháy có đang bật không
+ (BOOL)isBackgroundFlashTrackingActive;

@end

NS_ASSUME_NONNULL_END

