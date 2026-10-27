//
//  VCAMColorSyncManager.h
//  VCAM iOS - Virtual Camera Color Sync & Skin Tone Matching Engine
//
//  Cơ chế đồng bộ màu da / ambient lighting chuẩn xác từ VcamNextPlus:
//  - Lấy màu pixel (X,Y) trên màn hình (RGB chuẩn hóa 0.0 - 1.0)
//  - Áp dụng CISoftLightBlendMode + CIScreenBlendMode + Vignette Mask + CIGaussianBlur
//  - Đồng bộ hòa trộn màu da tự nhiên, giữ nguyên texture lỗ chân lông và khối mặt
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VCAMColorSyncRegion) {
    VCAMColorSyncRegionCenterFace = 0, // Trọng tâm khuôn mặt (Radial gradient falloff mượt mà)
    VCAMColorSyncRegionFullFrame  = 1, // Toàn bộ khung hình camera
};

typedef struct {
    BOOL enabled;
    BOOL liveTracking;       // Tự động bắt màu nháy màn hình eKYC thời gian thực (Active Flash Tracking)
    float red;               // 0.0 - 1.0 (Target Red, mặc định 0.92)
    float green;             // 0.0 - 1.0 (Target Green, mặc định 0.78)
    float blue;              // 0.0 - 1.0 (Target Blue, mặc định 0.71)
    float intensity;         // 0.05 - 1.00 (Độ mạnh đồng bộ màu, mặc định 0.65)
    float pickerPointX;      // Tọa độ chuẩn hóa X (0.0 - 1.0)
    float pickerPointY;      // Tọa độ chuẩn hóa Y (0.0 - 1.0)
    VCAMColorSyncRegion region;
} VCAMColorSyncState;

@interface VCAMColorSyncManager : NSObject

+ (instancetype)sharedManager;

@property (nonatomic, assign, getter=isColorSyncEnabled, setter=setColorSyncEnabled:) BOOL colorSyncEnabled;
@property (nonatomic, assign, getter=isLiveTrackingEnabled, setter=setLiveTrackingEnabled:) BOOL liveTracking;
@property (nonatomic, assign) CGFloat colorSyncRed;
@property (nonatomic, assign) CGFloat colorSyncGreen;
@property (nonatomic, assign) CGFloat colorSyncBlue;
@property (nonatomic, assign) CGFloat colorSyncIntensity;
@property (nonatomic, assign) CGFloat pickerPointX;
@property (nonatomic, assign) CGFloat pickerPointY;
@property (nonatomic, assign) VCAMColorSyncRegion colorSyncRegion;

- (void)setColorSyncEnabled:(BOOL)enabled;
- (BOOL)isColorSyncEnabled;

/// Cập nhật giá trị RGB đã chuẩn hóa (0.0 - 1.0) từ Loupe Color Picker
- (void)updateColorSyncRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b;

/// Cập nhật vị trí picker chuẩn hóa (0.0 - 1.0)
- (void)updatePickerPointX:(CGFloat)x y:(CGFloat)y;

/// Lấy trạng thái Color Sync hiện tại
+ (VCAMColorSyncState)currentColorSyncState;

/// Lưu trạng thái Color Sync xuống disk và phát thông báo Darwin IPC
+ (void)saveColorSyncState:(VCAMColorSyncState)state;

/// Áp dụng pipeline màu (CISoftLightBlendMode + Mask + GaussianBlur) vào CIImage
+ (CIImage *)applyColorSyncToImage:(CIImage *)image
                             size:(CGSize)size
                            state:(VCAMColorSyncState)state;

@end

NS_ASSUME_NONNULL_END

