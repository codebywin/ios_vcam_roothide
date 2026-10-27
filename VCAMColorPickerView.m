//
//  VCAMColorPickerView.m
//  VCAM iOS - On-Screen Loupe Eyedropper & Screen Pixel Reader
//

#import "VCAMColorPickerView.h"
#import "VCAMColorSyncManager.h"
#import <dlfcn.h>
#import <mach/mach.h>

#define kIOSurfaceLockReadOnly 0x00000001

typedef struct __IOSurface *IOSurfaceRef;

// Khai báo dynamic loader cho IOSurface & CARenderServerRenderDisplay
typedef IOSurfaceRef (*IOSurfaceCreateFunc)(CFDictionaryRef properties);
typedef IOReturn (*IOSurfaceLockFunc)(IOSurfaceRef buffer, uint32_t options, uint32_t *seed);
typedef IOReturn (*IOSurfaceUnlockFunc)(IOSurfaceRef buffer, uint32_t options, uint32_t *seed);
typedef void *(*IOSurfaceGetBaseAddressFunc)(IOSurfaceRef buffer);
typedef size_t (*IOSurfaceGetBytesPerRowFunc)(IOSurfaceRef buffer);
typedef void (*CARenderServerRenderDisplayFunc)(uint32_t a, CFStringRef display, IOSurfaceRef surface, uint32_t b, uint32_t c);

static IOSurfaceCreateFunc gIOSurfaceCreate = NULL;
static IOSurfaceLockFunc gIOSurfaceLock = NULL;
static IOSurfaceUnlockFunc gIOSurfaceUnlock = NULL;
static IOSurfaceGetBaseAddressFunc gIOSurfaceGetBaseAddress = NULL;
static IOSurfaceGetBytesPerRowFunc gIOSurfaceGetBytesPerRow = NULL;
static CARenderServerRenderDisplayFunc gCARenderServerRenderDisplay = NULL;

static void VCAMInitColorPickerSymbols(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *ioHandle = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW | RTLD_GLOBAL);
        if (ioHandle) {
            gIOSurfaceCreate = (IOSurfaceCreateFunc)dlsym(ioHandle, "IOSurfaceCreate");
            gIOSurfaceLock = (IOSurfaceLockFunc)dlsym(ioHandle, "IOSurfaceLock");
            gIOSurfaceUnlock = (IOSurfaceUnlockFunc)dlsym(ioHandle, "IOSurfaceUnlock");
            gIOSurfaceGetBaseAddress = (IOSurfaceGetBaseAddressFunc)dlsym(ioHandle, "IOSurfaceGetBaseAddress");
            gIOSurfaceGetBytesPerRow = (IOSurfaceGetBytesPerRowFunc)dlsym(ioHandle, "IOSurfaceGetBytesPerRow");
        }
        void *qcHandle = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW | RTLD_GLOBAL);
        if (qcHandle) {
            gCARenderServerRenderDisplay = (CARenderServerRenderDisplayFunc)dlsym(qcHandle, "CARenderServerRenderDisplay");
        }
    });
}

#pragma mark - Floating Window

@interface VCAMColorPickerWindow : UIWindow
@end

@implementation VCAMColorPickerWindow
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    for (UIView *subview in self.subviews) {
        if ([subview pointInside:[self convertPoint:point toView:subview] withEvent:event]) {
            return YES;
        }
    }
    return NO;
}
@end

#pragma mark - VCAMColorPickerView Implementation

@interface VCAMColorPickerView ()
@property (nonatomic, strong) UIView *loupeContainer;
@property (nonatomic, strong) UIView *previewRing;
@property (nonatomic, strong) UIView *badgeView;
@property (nonatomic, strong) UILabel *colorHexLabel;
@property (nonatomic, strong) UILabel *rgbLabel;
@property (nonatomic, strong) UIButton *syncButton;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, assign) CGPoint samplePoint;
@property (nonatomic, assign) CGFloat currentR;
@property (nonatomic, assign) CGFloat currentG;
@property (nonatomic, assign) CGFloat currentB;
@property (nonatomic, strong) dispatch_queue_t sampleQueue;
@property (nonatomic, strong) dispatch_source_t sampleTimer;
@property (nonatomic, assign) IOSurfaceRef captureSurface;
@property (nonatomic, assign) size_t captureWidth;
@property (nonatomic, assign) size_t captureHeight;
@end

static VCAMColorPickerWindow *sPickerWindow = nil;
static VCAMColorPickerView *sPickerView = nil;
static dispatch_source_t sBackgroundTimer = nil;
static dispatch_queue_t sBackgroundQueue = nil;
static IOSurfaceRef sBackgroundSurface = nil;
static size_t sBackgroundWidth = 0, sBackgroundHeight = 0;

static void VCAMSamplePixelAtNormalizedPoint(CGFloat normX, CGFloat normY, void (^completion)(CGFloat r, CGFloat g, CGFloat b)) {
    if (!gCARenderServerRenderDisplay || !gIOSurfaceLock || !gIOSurfaceUnlock || !gIOSurfaceGetBaseAddress || !gIOSurfaceGetBytesPerRow) {
        return;
    }
    if (!sBackgroundSurface && gIOSurfaceCreate) {
        CGRect native = [UIScreen mainScreen].nativeBounds;
        sBackgroundWidth = (size_t)native.size.width;
        sBackgroundHeight = (size_t)native.size.height;
        if (sBackgroundWidth == 0 || sBackgroundHeight == 0) {
            sBackgroundWidth = 1170; sBackgroundHeight = 2532;
        }
        size_t bytesPerRow = (sBackgroundWidth * 4 + 63) & ~63;
        size_t totalBytes = bytesPerRow * sBackgroundHeight;
        NSDictionary *props = @{
            (id)kIOSurfaceWidth: @(sBackgroundWidth),
            (id)kIOSurfaceHeight: @(sBackgroundHeight),
            (id)kIOSurfaceBytesPerElement: @4,
            (id)kIOSurfaceBytesPerRow: @(bytesPerRow),
            (id)kIOSurfaceAllocSize: @(totalBytes),
            (id)kIOSurfacePixelFormat: @(0x42475241), // 'BGRA'
        };
        sBackgroundSurface = gIOSurfaceCreate((__bridge CFDictionaryRef)props);
    }
    if (!sBackgroundSurface) return;

    gCARenderServerRenderDisplay(0, CFSTR("LCD"), sBackgroundSurface, 0, 0);

    if (gIOSurfaceLock(sBackgroundSurface, kIOSurfaceLockReadOnly, NULL) == kIOReturnSuccess) {
        uint8_t *baseAddr = (uint8_t *)gIOSurfaceGetBaseAddress(sBackgroundSurface);
        size_t bytesPerRow = gIOSurfaceGetBytesPerRow(sBackgroundSurface);

        if (baseAddr && bytesPerRow > 0) {
            size_t targetX = (size_t)round(normX * sBackgroundWidth);
            size_t targetY = (size_t)round(normY * sBackgroundHeight);
            targetX = MIN(sBackgroundWidth - 1, targetX);
            targetY = MIN(sBackgroundHeight - 1, targetY);

            double sumR = 0, sumG = 0, sumB = 0;
            int count = 0;

            for (int dy = -3; dy <= 3; dy++) {
                ssize_t py = (ssize_t)targetY + dy;
                if (py < 0 || py >= (ssize_t)sBackgroundHeight) continue;
                for (int dx = -3; dx <= 3; dx++) {
                    ssize_t px = (ssize_t)targetX + dx;
                    if (px < 0 || px >= (ssize_t)sBackgroundWidth) continue;
                    size_t offset = (size_t)py * bytesPerRow + (size_t)px * 4;
                    sumB += baseAddr[offset + 0];
                    sumG += baseAddr[offset + 1];
                    sumR += baseAddr[offset + 2];
                    count++;
                }
            }

            if (count > 0 && completion) {
                completion((sumR / count) / 255.0, (sumG / count) / 255.0, (sumB / count) / 255.0);
            }
        }
        gIOSurfaceUnlock(sBackgroundSurface, kIOSurfaceLockReadOnly, NULL);
    }
}

@implementation VCAMColorPickerView

+ (void)startBackgroundFlashTracking {
    if (sBackgroundTimer) return;
    VCAMInitColorPickerSymbols();

    sBackgroundQueue = dispatch_queue_create("com.vcam.colorpicker.background", DISPATCH_QUEUE_SERIAL);
    sBackgroundTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sBackgroundQueue);

    // 25 FPS (40ms) - bắt mọi nhịp chớp màu màn hình eKYC thời gian thực
    dispatch_source_set_timer(sBackgroundTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 40 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);

    static CGFloat lastR = -1, lastG = -1, lastB = -1;
    dispatch_source_set_event_handler(sBackgroundTimer, ^{
        VCAMColorSyncState st = [VCAMColorSyncManager currentColorSyncState];
        if (!st.liveTracking && !st.enabled) return;

        CGFloat px = st.pickerPointX;
        CGFloat py = st.pickerPointY;
        if (px <= 0.01 && py <= 0.01) { px = 0.50; py = 0.15; }

        VCAMSamplePixelAtNormalizedPoint(px, py, ^(CGFloat r, CGFloat g, CGFloat b) {
            if (fabs(r - lastR) > 0.005 || fabs(g - lastG) > 0.005 || fabs(b - lastB) > 0.005) {
                lastR = r; lastG = g; lastB = b;
                [[VCAMColorSyncManager sharedManager] updateColorSyncRed:r green:g blue:b];
            }
        });
    });

    dispatch_resume(sBackgroundTimer);
}

+ (void)stopBackgroundFlashTracking {
    if (sBackgroundTimer) {
        dispatch_source_cancel(sBackgroundTimer);
        sBackgroundTimer = nil;
    }
    sBackgroundQueue = nil;
    if (sBackgroundSurface && gIOSurfaceUnlock) {
        CFRelease(sBackgroundSurface);
        sBackgroundSurface = NULL;
    }
}

+ (BOOL)isBackgroundFlashTrackingActive {
    return (sBackgroundTimer != nil);
}

+ (void)showColorPicker {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sPickerWindow && !sPickerWindow.hidden) return;

        // Dừng background tracking khi mở giao diện kính lúp
        [VCAMColorPickerView stopBackgroundFlashTracking];

        VCAMInitColorPickerSymbols();

        CGRect screen = [UIScreen mainScreen].bounds;

        UIWindowScene *activeScene = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                    activeScene = (UIWindowScene *)scene;
                    break;
                }
            }
        }

        if (activeScene) {
            sPickerWindow = [[VCAMColorPickerWindow alloc] initWithWindowScene:activeScene];
        } else {
            sPickerWindow = [[VCAMColorPickerWindow alloc] initWithFrame:screen];
        }

        sPickerWindow.windowLevel = UIWindowLevelAlert + 100;
        sPickerWindow.backgroundColor = [UIColor clearColor];
        sPickerWindow.hidden = NO;

        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        rootVC.view.userInteractionEnabled = YES;
        sPickerWindow.rootViewController = rootVC;

        sPickerView = [[VCAMColorPickerView alloc] initWithFrame:screen];
        [rootVC.view addSubview:sPickerView];
    });
}

+ (void)hideColorPicker {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sPickerView) {
            [sPickerView _stopSampling];
            [sPickerView removeFromSuperview];
            sPickerView = nil;
        }
        if (sPickerWindow) {
            sPickerWindow.hidden = YES;
            sPickerWindow = nil;
        }

        // Nếu người dùng đang bật Live Tracking, tiếp tục chạy ngầm để bắt nháy màn hình eKYC
        VCAMColorSyncState st = [VCAMColorSyncManager currentColorSyncState];
        if (st.liveTracking && st.enabled) {
            [VCAMColorPickerView startBackgroundFlashTracking];
        }
    });
}

+ (BOOL)isColorPickerVisible {
    return (sPickerWindow != nil && !sPickerWindow.hidden);
}

+ (UIColor *)currentlySampledColor {
    if (!sPickerView) {
        VCAMColorSyncState st = [VCAMColorSyncManager currentColorSyncState];
        return [UIColor colorWithRed:st.red green:st.green blue:st.blue alpha:1.0];
    }
    return [UIColor colorWithRed:sPickerView.currentR green:sPickerView.currentG blue:sPickerView.currentB alpha:1.0];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;

        // Điểm lấy mẫu mặc định: giữa màn hình
        VCAMColorSyncState st = [VCAMColorSyncManager currentColorSyncState];
        _currentR = st.red;
        _currentG = st.green;
        _currentB = st.blue;

        CGFloat initialX = (st.pickerPointX > 0.05 && st.pickerPointX < 0.95) ? st.pickerPointX * frame.size.width : frame.size.width * 0.50;
        CGFloat initialY = (st.pickerPointY > 0.05 && st.pickerPointY < 0.95) ? st.pickerPointY * frame.size.height : frame.size.height * 0.45;
        _samplePoint = CGPointMake(initialX, initialY);

        [self _buildUI];
        [self _startSampling];
    }
    return self;
}

- (void)dealloc {
    [self _stopSampling];
}

#pragma mark - UI Building

- (void)_buildUI {
    CGFloat loupeSize = 64.0;

    // 1. Khung chứa Loupe kính lúp (có thể kéo di chuyển)
    _loupeContainer = [[UIView alloc] initWithFrame:CGRectMake(_samplePoint.x - loupeSize / 2.0,
                                                               _samplePoint.y - loupeSize / 2.0,
                                                               loupeSize,
                                                               loupeSize)];
    _loupeContainer.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    _loupeContainer.layer.cornerRadius = loupeSize / 2.0;
    _loupeContainer.layer.borderWidth = 2.5;
    _loupeContainer.layer.borderColor = [UIColor whiteColor].CGColor;
    _loupeContainer.layer.shadowColor = [UIColor blackColor].CGColor;
    _loupeContainer.layer.shadowOpacity = 0.55;
    _loupeContainer.layer.shadowRadius = 6.0;
    _loupeContainer.layer.shadowOffset = CGSizeMake(0, 3);
    _loupeContainer.userInteractionEnabled = YES;
    [self addSubview:_loupeContainer];

    // 2. Vòng nhẫn hiển thị màu live (Preview Ring)
    CGFloat ringSize = 48.0;
    _previewRing = [[UIView alloc] initWithFrame:CGRectMake((loupeSize - ringSize) / 2.0,
                                                            (loupeSize - ringSize) / 2.0,
                                                            ringSize,
                                                            ringSize)];
    _previewRing.backgroundColor = [UIColor clearColor];
    _previewRing.layer.cornerRadius = ringSize / 2.0;
    _previewRing.layer.borderWidth = 5.0;
    _previewRing.layer.borderColor = [UIColor colorWithRed:_currentR green:_currentG blue:_currentB alpha:1.0].CGColor;
    _previewRing.userInteractionEnabled = NO;
    [_loupeContainer addSubview:_previewRing];

    // 3. Tâm ngắm chữ thập (Crosshair Reticle 4 hướng)
    CGFloat mid = loupeSize / 2.0;
    CGFloat tickLen = 7.0, tickThick = 1.2;
    UIColor *crossColor = [UIColor colorWithWhite:1.0 alpha:0.85];

    // Trái
    UIView *tLeft = [[UIView alloc] initWithFrame:CGRectMake(mid - 12 - tickLen, mid - tickThick / 2.0, tickLen, tickThick)];
    tLeft.backgroundColor = crossColor;
    [_loupeContainer addSubview:tLeft];

    // Phải
    UIView *tRight = [[UIView alloc] initWithFrame:CGRectMake(mid + 12, mid - tickThick / 2.0, tickLen, tickThick)];
    tRight.backgroundColor = crossColor;
    [_loupeContainer addSubview:tRight];

    // Trên
    UIView *tTop = [[UIView alloc] initWithFrame:CGRectMake(mid - tickThick / 2.0, mid - 12 - tickLen, tickThick, tickLen)];
    tTop.backgroundColor = crossColor;
    [_loupeContainer addSubview:tTop];

    // Dưới
    UIView *tBottom = [[UIView alloc] initWithFrame:CGRectMake(mid - tickThick / 2.0, mid + 12, tickThick, tickLen)];
    tBottom.backgroundColor = crossColor;
    [_loupeContainer addSubview:tBottom];

    // Chấm tâm nhỏ 2x2
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(mid - 1.5, mid - 1.5, 3.0, 3.0)];
    dot.backgroundColor = [UIColor whiteColor];
    dot.layer.cornerRadius = 1.5;
    [_loupeContainer addSubview:dot];

    // 4. Bảng điều khiển màu nổi bên dưới kính lúp (Badge View)
    CGFloat badgeW = 160.0, badgeH = 74.0;
    _badgeView = [[UIView alloc] initWithFrame:CGRectMake(_samplePoint.x - badgeW / 2.0,
                                                          CGRectGetMaxY(_loupeContainer.frame) + 12.0,
                                                          badgeW,
                                                          badgeH)];
    _badgeView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.88];
    _badgeView.layer.cornerRadius = 14.0;
    _badgeView.layer.borderWidth = 1.0;
    _badgeView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    _badgeView.layer.shadowColor = [UIColor blackColor].CGColor;
    _badgeView.layer.shadowOpacity = 0.50;
    _badgeView.layer.shadowRadius = 8.0;
    _badgeView.layer.shadowOffset = CGSizeMake(0, 4);
    _badgeView.userInteractionEnabled = YES;
    [self addSubview:_badgeView];

    // Label mã màu Hex
    _colorHexLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 6, badgeW - 16, 18)];
    _colorHexLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightBold];
    _colorHexLabel.textColor = [UIColor whiteColor];
    _colorHexLabel.textAlignment = NSTextAlignmentCenter;
    [_badgeView addSubview:_colorHexLabel];

    // Label RGB chi tiết
    _rgbLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 24, badgeW - 16, 14)];
    _rgbLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightRegular];
    _rgbLabel.textColor = [UIColor colorWithWhite:0.80 alpha:1.0];
    _rgbLabel.textAlignment = NSTextAlignmentCenter;
    [_badgeView addSubview:_rgbLabel];

    // Nút [ Đồng bộ / Bắt nháy live ]
    _syncButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _syncButton.frame = CGRectMake(10, 42, 102, 24);
    _syncButton.backgroundColor = [UIColor colorWithRed:0.20 green:0.75 blue:0.42 alpha:0.95];
    _syncButton.layer.cornerRadius = 7.0;
    _syncButton.titleLabel.font = [UIFont boldSystemFontOfSize:10];
    [_syncButton addTarget:self action:@selector(_syncAction) forControlEvents:UIControlEventTouchUpInside];
    [_badgeView addSubview:_syncButton];
    [self _updateSyncButtonUI];

    // Nút [ ✕ ] (Đóng)
    _closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _closeButton.frame = CGRectMake(badgeW - 38 - 10, 42, 38, 24);
    _closeButton.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.90];
    _closeButton.layer.cornerRadius = 7.0;
    [_closeButton setTitle:@"✕" forState:UIControlStateNormal];
    [_closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _closeButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [_closeButton addTarget:self action:@selector(_closeAction) forControlEvents:UIControlEventTouchUpInside];
    [_badgeView addSubview:_closeButton];

    [self _updateColorLabelsWithR:_currentR g:_currentG b:_currentB];

    // 5. Cử chỉ kéo Loupe
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_handlePan:)];
    [_loupeContainer addGestureRecognizer:pan];
}

- (void)_updateColorLabelsWithR:(CGFloat)r g:(CGFloat)g b:(CGFloat)b {
    int ir = (int)round(r * 255.0);
    int ig = (int)round(g * 255.0);
    int ib = (int)round(b * 255.0);
    _colorHexLabel.text = [NSString stringWithFormat:@"#%02X%02X%02X", ir, ig, ib];
    _rgbLabel.text = [NSString stringWithFormat:@"RGB: %d, %d, %d", ir, ig, ib];
    _previewRing.layer.borderColor = [UIColor colorWithRed:r green:g blue:b alpha:1.0].CGColor;
}

#pragma mark - Gesture Handling

- (void)_handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self];
    CGPoint newCenter = CGPointMake(_loupeContainer.center.x + translation.x,
                                    _loupeContainer.center.y + translation.y);

    // Giới hạn trong màn hình
    CGRect bounds = self.bounds;
    CGFloat margin = 32.0;
    newCenter.x = MAX(margin, MIN(bounds.size.width - margin, newCenter.x));
    newCenter.y = MAX(margin, MIN(bounds.size.height - margin, newCenter.y));

    _loupeContainer.center = newCenter;
    _samplePoint = newCenter;

    // Cập nhật vị trí Badge đi theo
    CGFloat badgeW = _badgeView.frame.size.width;
    CGFloat badgeH = _badgeView.frame.size.height;
    CGFloat badgeY = CGRectGetMaxY(_loupeContainer.frame) + 12.0;
    if (badgeY + badgeH > bounds.size.height - 10) {
        badgeY = CGRectGetMinY(_loupeContainer.frame) - badgeH - 12.0;
    }
    CGFloat badgeX = MAX(10, MIN(bounds.size.width - badgeW - 10, newCenter.x - badgeW / 2.0));
    _badgeView.frame = CGRectMake(badgeX, badgeY, badgeW, badgeH);

    [pan setTranslation:CGPointZero inView:self];

    // Kích hoạt lấy mẫu ngay khi di chuyển
    [self _sampleScreenPixel];
}

#pragma mark - Actions

- (void)_syncAction {
    BOOL nextState = ![[VCAMColorSyncManager sharedManager] isLiveTrackingEnabled];
    [[VCAMColorSyncManager sharedManager] setLiveTrackingEnabled:nextState];
    [[VCAMColorSyncManager sharedManager] setColorSyncEnabled:YES];

    CGRect bounds = self.bounds;
    CGFloat normX = (bounds.size.width > 0) ? _samplePoint.x / bounds.size.width : 0.5;
    CGFloat normY = (bounds.size.height > 0) ? _samplePoint.y / bounds.size.height : 0.5;

    [[VCAMColorSyncManager sharedManager] updatePickerPointX:normX y:normY];
    [[VCAMColorSyncManager sharedManager] updateColorSyncRed:_currentR green:_currentG blue:_currentB];

    [self _updateSyncButtonUI];

    // Hiệu ứng phản hồi
    [UIView animateWithDuration:0.15 animations:^{
        _syncButton.transform = CGAffineTransformMakeScale(1.08, 1.08);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.15 animations:^{
            _syncButton.transform = CGAffineTransformIdentity;
        }];
    }];
}

- (void)_updateSyncButtonUI {
    BOOL isLive = [[VCAMColorSyncManager sharedManager] isLiveTrackingEnabled];
    if (isLive) {
        [_syncButton setTitle:@"⚡ Bắt nháy: BẬT" forState:UIControlStateNormal];
        [_syncButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _syncButton.backgroundColor = [UIColor colorWithRed:0.20 green:0.80 blue:0.40 alpha:0.95];
    } else {
        [_syncButton setTitle:@"✓ Khóa tĩnh" forState:UIControlStateNormal];
        [_syncButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _syncButton.backgroundColor = [UIColor colorWithWhite:0.28 alpha:0.90];
    }
}

- (void)_closeAction {
    [VCAMColorPickerView hideColorPicker];
}

#pragma mark - Pixel Sampling Engine (CARenderServerRenderDisplay + IOSurface)

- (void)_startSampling {
    if (_sampleTimer) return;

    _sampleQueue = dispatch_queue_create("com.vcam.colorpicker.sample", DISPATCH_QUEUE_SERIAL);
    _sampleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _sampleQueue);

    // Lấy mẫu 20 FPS (50ms mỗi lần)
    dispatch_source_set_timer(_sampleTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 50 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_sampleTimer, ^{
        [weakSelf _sampleScreenPixel];
    });

    dispatch_resume(_sampleTimer);
}

- (void)_stopSampling {
    if (_sampleTimer) {
        dispatch_source_cancel(_sampleTimer);
        _sampleTimer = nil;
    }
    _sampleQueue = nil;

    if (_captureSurface && gIOSurfaceUnlock) {
        // CFRelease bề mặt IOSurface khi đóng
        CFRelease(_captureSurface);
        _captureSurface = NULL;
    }
}

- (void)_ensureCaptureSurface {
    if (_captureSurface) return;
    if (!gIOSurfaceCreate) return;

    CGRect native = [UIScreen mainScreen].nativeBounds;
    _captureWidth = (size_t)native.size.width;
    _captureHeight = (size_t)native.size.height;
    if (_captureWidth == 0 || _captureHeight == 0) {
        _captureWidth = 1170;
        _captureHeight = 2532;
    }

    size_t bytesPerRow = (_captureWidth * 4 + 63) & ~63;
    size_t totalBytes = bytesPerRow * _captureHeight;

    NSDictionary *props = @{
        (id)kIOSurfaceWidth: @(_captureWidth),
        (id)kIOSurfaceHeight: @(_captureHeight),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfaceBytesPerRow: @(bytesPerRow),
        (id)kIOSurfaceAllocSize: @(totalBytes),
        (id)kIOSurfacePixelFormat: @(0x42475241), // 'BGRA'
    };

    _captureSurface = gIOSurfaceCreate((__bridge CFDictionaryRef)props);
}

- (void)_sampleScreenPixel {
    CGFloat sampledR = _currentR, sampledG = _currentG, sampledB = _currentB;
    BOOL sampledSuccess = NO;

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat screenW = screenBounds.size.width;
    CGFloat screenH = screenBounds.size.height;
    if (screenW <= 0 || screenH <= 0) return;

    // 1. Ưu tiên cơ chế CARenderServerRenderDisplay + IOSurface như VcamNextPlus
    if (gCARenderServerRenderDisplay && gIOSurfaceLock && gIOSurfaceUnlock && gIOSurfaceGetBaseAddress && gIOSurfaceGetBytesPerRow) {
        [self _ensureCaptureSurface];

        if (_captureSurface) {
            // Render toàn bộ hiển thị phần cứng LCD vào IOSurface
            gCARenderServerRenderDisplay(0, CFSTR("LCD"), _captureSurface, 0, 0);

            if (gIOSurfaceLock(_captureSurface, kIOSurfaceLockReadOnly, NULL) == kIOReturnSuccess) {
                uint8_t *baseAddr = (uint8_t *)gIOSurfaceGetBaseAddress(_captureSurface);
                size_t bytesPerRow = gIOSurfaceGetBytesPerRow(_captureSurface);

                if (baseAddr && bytesPerRow > 0) {
                    size_t targetX = (size_t)round((_samplePoint.x / screenW) * _captureWidth);
                    size_t targetY = (size_t)round((_samplePoint.y / screenH) * _captureHeight);

                    targetX = MIN(_captureWidth - 1, targetX);
                    targetY = MIN(_captureHeight - 1, targetY);

                    // Lấy mẫu trung bình cửa sổ 7x7 pixel xung quanh điểm ngắm để khử nhiễu màn hình
                    double sumR = 0, sumG = 0, sumB = 0;
                    int count = 0;

                    for (int dy = -3; dy <= 3; dy++) {
                        ssize_t py = (ssize_t)targetY + dy;
                        if (py < 0 || py >= (ssize_t)_captureHeight) continue;

                        for (int dx = -3; dx <= 3; dx++) {
                            ssize_t px = (targetX + dx);
                            if (px < 0 || px >= (ssize_t)_captureWidth) continue;

                            size_t offset = (size_t)py * bytesPerRow + (size_t)px * 4;
                            uint8_t b = baseAddr[offset + 0];
                            uint8_t g = baseAddr[offset + 1];
                            uint8_t r = baseAddr[offset + 2];

                            sumB += b;
                            sumG += g;
                            sumR += r;
                            count++;
                        }
                    }

                    if (count > 0) {
                        sampledB = (sumB / count) / 255.0;
                        sampledG = (sumG / count) / 255.0;
                        sampledR = (sumR / count) / 255.0;
                        sampledSuccess = YES;
                    }
                }
                gIOSurfaceUnlock(_captureSurface, kIOSurfaceLockReadOnly, NULL);
            }
        }
    }

    // 2. Fallback qua UIKit View Hierarchy nếu CARenderServer bị chặn
    if (!sampledSuccess) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            UIWindow *topWin = [UIApplication sharedApplication].keyWindow;
            if (!topWin) {
                for (UIWindow *w in [UIApplication sharedApplication].windows) {
                    if (!w.hidden && w != sPickerWindow) { topWin = w; break; }
                }
            }
            if (topWin) {
                UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, 1), NO, 0.0);
                CGContextRef ctx = UIGraphicsGetCurrentContext();
                if (ctx) {
                    CGContextTranslateCTM(ctx, -self.samplePoint.x, -self.samplePoint.y);
                    [topWin.layer renderInContext:ctx];
                    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
                    UIGraphicsEndImageContext();

                    if (img && img.CGImage) {
                        CFDataRef pixelData = CGDataProviderCopyData(CGImageGetDataProvider(img.CGImage));
                        if (pixelData) {
                            const UInt8 *data = CFDataGetBytePtr(pixelData);
                            if (data) {
                                [self _handleColorChangedR:data[0]/255.0 g:data[1]/255.0 b:data[2]/255.0];
                            }
                            CFRelease(pixelData);
                        }
                    }
                } else {
                    UIGraphicsEndImageContext();
                }
            }
        });
        return;
    }

    [self _handleColorChangedR:sampledR g:sampledG b:sampledB];
}

- (void)_handleColorChangedR:(CGFloat)r g:(CGFloat)g b:(CGFloat)b {
    // Ngưỡng hysteresis ~0.005 để tránh giật giao diện
    if (fabs(r - _currentR) < 0.005 && fabs(g - _currentG) < 0.005 && fabs(b - _currentB) < 0.005) {
        return;
    }

    _currentR = r;
    _currentG = g;
    _currentB = b;

    // Tự động đẩy màu mới vào pipeline camera ngay lập tức (Bắt màu nháy màn hình eKYC Real-time Flash Tracking)
    VCAMColorSyncState st = [VCAMColorSyncManager currentColorSyncState];
    if (st.liveTracking || st.enabled) {
        [[VCAMColorSyncManager sharedManager] updateColorSyncRed:r green:g blue:b];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self _updateColorLabelsWithR:r g:g b:b];
    });
}

@end

