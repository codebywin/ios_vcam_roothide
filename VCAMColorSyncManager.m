//
//  VCAMColorSyncManager.m
//  VCAM iOS - Virtual Camera Color Sync & Skin Tone Matching Engine
//

#import "VCAMColorSyncManager.h"
#import "VCAMSharedState.h"
#import <notify.h>
#import <sys/stat.h>

#define VCAM_COLORSYNC_NOTIF "com.vcam.colorsync.changed"

static NSString *VCAMGetColorSyncPlistPath(void) {
    // Ưu tiên roothide / rootless path nếu có, fallback /var/tmp
    NSArray *candidates = @[
        @"/var/jb/var/mobile/Library/Preferences/com.vcam.colorsync.plist",
        @"/var/mobile/Library/Preferences/com.vcam.colorsync.plist",
        @"/rootfs/private/var/tmp/vcam_colorsync.plist",
        @"/var/tmp/vcam_colorsync.plist"
    ];
    for (NSString *path in candidates) {
        NSString *dir = [path stringByDeletingLastPathComponent];
        if ([[NSFileManager defaultManager] isWritableFileAtPath:dir] ||
            [[NSFileManager defaultManager] fileExistsAtPath:path]) {
            return path;
        }
    }
    return @"/var/tmp/vcam_colorsync.plist";
}

@interface VCAMColorSyncManager ()
@property (nonatomic, assign) VCAMColorSyncState state;
@end

@implementation VCAMColorSyncManager {
    int _notifyToken;
}

+ (instancetype)sharedManager {
    static VCAMColorSyncManager *sManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sManager = [[self alloc] init];
    });
    return sManager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Trạng thái mặc định: Tông màu da tự nhiên Á Đông / Châu Âu (Warm Peach: R=0.92, G=0.78, B=0.71)
        _state.enabled = NO;
        _state.red = 0.92f;
        _state.green = 0.78f;
        _state.blue = 0.71f;
        _state.intensity = 0.65f;
        _state.pickerPointX = 0.50f;
        _state.pickerPointY = 0.45f;
        _state.region = VCAMColorSyncRegionCenterFace;

        [self _loadFromDisk];

        // Lắng nghe Darwin Notification khi tiến trình khác (overlay hoặc mediaserverd) thay đổi màu
        __weak typeof(self) weakSelf = self;
        notify_register_dispatch(VCAM_COLORSYNC_NOTIF, &_notifyToken, dispatch_get_main_queue(), ^(int token) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf) {
                [strongSelf _loadFromDisk];
            }
        });
    }
    return self;
}

- (void)dealloc {
    if (_notifyToken != 0) {
        notify_cancel(_notifyToken);
        _notifyToken = 0;
    }
}

#pragma mark - Properties

- (BOOL)isColorSyncEnabled {
    return _state.enabled;
}

- (void)setColorSyncEnabled:(BOOL)enabled {
    if (_state.enabled != enabled) {
        _state.enabled = enabled;
        [self _saveToDisk];
    }
}

- (BOOL)isLiveTrackingEnabled {
    return _state.liveTracking;
}

- (void)setLiveTrackingEnabled:(BOOL)liveTracking {
    if (_state.liveTracking != liveTracking) {
        _state.liveTracking = liveTracking;
        [self _saveToDisk];
    }
}

- (CGFloat)colorSyncRed {
    return _state.red;
}

- (void)setColorSyncRed:(CGFloat)colorSyncRed {
    _state.red = (float)MAX(0.0, MIN(1.0, colorSyncRed));
    [self _saveToDisk];
}

- (CGFloat)colorSyncGreen {
    return _state.green;
}

- (void)setColorSyncGreen:(CGFloat)colorSyncGreen {
    _state.green = (float)MAX(0.0, MIN(1.0, colorSyncGreen));
    [self _saveToDisk];
}

- (CGFloat)colorSyncBlue {
    return _state.blue;
}

- (void)setColorSyncBlue:(CGFloat)colorSyncBlue {
    _state.blue = (float)MAX(0.0, MIN(1.0, colorSyncBlue));
    [self _saveToDisk];
}

- (CGFloat)colorSyncIntensity {
    return _state.intensity;
}

- (void)setColorSyncIntensity:(CGFloat)colorSyncIntensity {
    _state.intensity = (float)MAX(0.05, MIN(1.0, colorSyncIntensity));
    [self _saveToDisk];
}

- (CGFloat)pickerPointX {
    return _state.pickerPointX;
}

- (void)setPickerPointX:(CGFloat)pickerPointX {
    _state.pickerPointX = (float)MAX(0.0, MIN(1.0, pickerPointX));
    [self _saveToDisk];
}

- (CGFloat)pickerPointY {
    return _state.pickerPointY;
}

- (void)setPickerPointY:(CGFloat)pickerPointY {
    _state.pickerPointY = (float)MAX(0.0, MIN(1.0, pickerPointY));
    [self _saveToDisk];
}

- (VCAMColorSyncRegion)colorSyncRegion {
    return _state.region;
}

- (void)setColorSyncRegion:(VCAMColorSyncRegion)colorSyncRegion {
    _state.region = colorSyncRegion;
    [self _saveToDisk];
}

- (void)updateColorSyncRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b {
    _state.red = (float)MAX(0.0, MIN(1.0, r));
    _state.green = (float)MAX(0.0, MIN(1.0, g));
    _state.blue = (float)MAX(0.0, MIN(1.0, b));
    _state.enabled = YES;
    [self _saveToDisk];
}

- (void)updatePickerPointX:(CGFloat)x y:(CGFloat)y {
    _state.pickerPointX = (float)MAX(0.0, MIN(1.0, x));
    _state.pickerPointY = (float)MAX(0.0, MIN(1.0, y));
    [self _saveToDisk];
}

#pragma mark - Persistence & IPC

- (void)_loadFromDisk {
    NSString *path = VCAMGetColorSyncPlistPath();
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    if (dict) {
        if (dict[@"enabled"]) _state.enabled = [dict[@"enabled"] boolValue];
        if (dict[@"liveTracking"]) _state.liveTracking = [dict[@"liveTracking"] boolValue];
        if (dict[@"red"]) _state.red = [dict[@"red"] floatValue];
        if (dict[@"green"]) _state.green = [dict[@"green"] floatValue];
        if (dict[@"blue"]) _state.blue = [dict[@"blue"] floatValue];
        if (dict[@"intensity"]) _state.intensity = [dict[@"intensity"] floatValue];
        if (dict[@"pickerPointX"]) _state.pickerPointX = [dict[@"pickerPointX"] floatValue];
        if (dict[@"pickerPointY"]) _state.pickerPointY = [dict[@"pickerPointY"] floatValue];
        if (dict[@"region"]) _state.region = (VCAMColorSyncRegion)[dict[@"region"] integerValue];
    }
}

- (void)_saveToDisk {
    [VCAMColorSyncManager saveColorSyncState:_state];
}

+ (VCAMColorSyncState)currentColorSyncState {
    VCAMSharedFlashState *shared = VCAMGetSharedFlashState(false);
    if (shared && shared->magic == VCAM_SHARED_FLASH_MAGIC) {
        VCAMColorSyncState s = [[VCAMColorSyncManager sharedManager] state];
        s.enabled = (shared->colorSyncActive != 0);
        s.red = shared->colorSyncR;
        s.green = shared->colorSyncG;
        s.blue = shared->colorSyncB;
        s.intensity = shared->colorSyncIntensity;
        s.region = (VCAMColorSyncRegion)shared->colorSyncRegion;
        return s;
    }
    return [[VCAMColorSyncManager sharedManager] state];
}

+ (void)saveColorSyncState:(VCAMColorSyncState)state {
    [VCAMColorSyncManager sharedManager].state = state;
    VCAMSharedFlashState *shared = VCAMGetSharedFlashState(true);
    if (shared && shared->magic == VCAM_SHARED_FLASH_MAGIC) {
        shared->colorSyncActive = state.enabled ? 1 : 0;
        shared->colorSyncR = state.red;
        shared->colorSyncG = state.green;
        shared->colorSyncB = state.blue;
        shared->colorSyncIntensity = state.intensity;
        shared->colorSyncRegion = (uint32_t)state.region;
        shared->colorSyncSequence++;
        shared->colorSyncTimestamp = [NSDate timeIntervalSinceReferenceDate];
    }
    NSString *path = VCAMGetColorSyncPlistPath();
    NSDictionary *dict = @{
        @"enabled": @(state.enabled),
        @"liveTracking": @(state.liveTracking),
        @"red": @(state.red),
        @"green": @(state.green),
        @"blue": @(state.blue),
        @"intensity": @(state.intensity),
        @"pickerPointX": @(state.pickerPointX),
        @"pickerPointY": @(state.pickerPointY),
        @"region": @((NSInteger)state.region),
    };
    [dict writeToFile:path atomically:YES];
    chmod([path UTF8String], 0666);
    notify_post(VCAM_COLORSYNC_NOTIF);
}

#pragma mark - CoreImage GPU Shading Pipeline

+ (CIImage *)applyColorSyncToImage:(CIImage *)image
                             size:(CGSize)size
                            state:(VCAMColorSyncState)state {
    if (!image || !state.enabled) return image;

    CGRect extent = image.extent;
    if (CGRectIsEmpty(extent) || CGRectIsInfinite(extent)) {
        extent = CGRectMake(0, 0, size.width, size.height);
    }

    // 1. Tạo lớp màu đơn sắc chuẩn hóa từ mã màu đã picker
    CIColor *targetCIColor = [CIColor colorWithRed:state.red
                                             green:state.green
                                              blue:state.blue
                                             alpha:1.0];
    CIImage *solidColorImg = [[CIImage imageWithColor:targetCIColor] imageByCroppingToRect:extent];

    // 2. Hòa trộn Soft Light (CISoftLightBlendMode)
    // Giữ nguyên 100% đường nét khuôn mặt, nếp gấp, đổ bóng tự nhiên, chỉ phủ ánh sắc da
    CIFilter *softLightFilter = [CIFilter filterWithName:@"CISoftLightBlendMode"];
    [softLightFilter setValue:solidColorImg forKey:kCIInputImageKey];
    [softLightFilter setValue:image forKey:kCIInputBackgroundImageKey];
    CIImage *gradedImage = softLightFilter.outputImage;
    if (!gradedImage) gradedImage = image;

    // 3. Nếu chọn chế độ CenterFace: Áp dụng Radial Gradient Mask + Gaussian Blur
    // Giúp màu da ở vùng giữa mặt được blend mạnh nhất, giảm dần mượt mà ra ngoài viền nền
    if (state.region == VCAMColorSyncRegionCenterFace) {
        CGPoint center = CGPointMake(extent.origin.x + extent.size.width * 0.50,
                                     extent.origin.y + extent.size.height * 0.52);
        CGFloat minDim = MIN(extent.size.width, extent.size.height);
        CGFloat r0 = minDim * 0.28;
        CGFloat r1 = minDim * 0.65;

        CIFilter *radialGradient = [CIFilter filterWithName:@"CIRadialGradient"];
        [radialGradient setValue:[CIVector vectorWithX:center.x Y:center.y] forKey:@"inputCenter"];
        [radialGradient setValue:@(r0) forKey:@"inputRadius0"];
        [radialGradient setValue:@(r1) forKey:@"inputRadius1"];
        [radialGradient setValue:[CIColor colorWithRed:1 green:1 blue:1 alpha:1] forKey:@"inputColor0"];
        [radialGradient setValue:[CIColor colorWithRed:0 green:0 blue:0 alpha:0] forKey:@"inputColor1"];
        CIImage *maskImg = [radialGradient.outputImage imageByCroppingToRect:extent];

        if (maskImg) {
            // Làm mịn biên viền mặt bằng GaussianBlur nhẹ
            CIFilter *blurFilter = [CIFilter filterWithName:@"CIGaussianBlur"];
            [blurFilter setValue:[maskImg imageByClampingToExtent] forKey:kCIInputImageKey];
            [blurFilter setValue:@(minDim * 0.05) forKey:kCIInputRadiusKey];
            CIImage *blurredMask = [blurFilter.outputImage imageByCroppingToRect:extent];

            // Hòa trộn vùng mặt đã match màu với ảnh gốc bên ngoài viền
            CIFilter *maskBlend = [CIFilter filterWithName:@"CIBlendWithMask"];
            [maskBlend setValue:gradedImage forKey:kCIInputImageKey];
            [maskBlend setValue:image forKey:kCIInputBackgroundImageKey];
            [maskBlend setValue:blurredMask forKey:kCIInputMaskImageKey];
            CIImage *maskedGraded = maskBlend.outputImage;
            if (maskedGraded) gradedImage = maskedGraded;
        }
    }

    // 4. Áp dụng độ mạnh (Intensity 0.0 - 1.0)
    if (state.intensity < 0.98f) {
        // Tạo mặt nạ độ trong suốt theo intensity để hòa trộn tỷ lệ giữa graded và image gốc
        CIColor *alphaColor = [CIColor colorWithRed:1 green:1 blue:1 alpha:state.intensity];
        CIImage *alphaMask = [[CIImage imageWithColor:alphaColor] imageByCroppingToRect:extent];
        CIFilter *alphaBlend = [CIFilter filterWithName:@"CIBlendWithMask"];
        [alphaBlend setValue:gradedImage forKey:kCIInputImageKey];
        [alphaBlend setValue:image forKey:kCIInputBackgroundImageKey];
        [alphaBlend setValue:alphaMask forKey:kCIInputMaskImageKey];
        CIImage *finalResult = alphaBlend.outputImage;
        if (finalResult) return [finalResult imageByCroppingToRect:extent];
    }

    return [gradedImage imageByCroppingToRect:extent];
}

@end

