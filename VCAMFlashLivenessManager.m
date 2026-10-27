//
//  VCAMFlashLivenessManager.m
//  VCAM iOS - KYC Active Flash Liveness Engine
//

#import "VCAMFlashLivenessManager.h"
#import "VCAMFlashBurstManager.h"
#import <dlfcn.h>
#import <sys/stat.h>

static const char *kVCAMFlashStateFileName = "vcam_flash_state";

#if defined(__cplusplus)
extern "C" {
#endif
CFTypeRef _UICreateScreenUIImage(void) __attribute__((weak_import));
#if defined(__cplusplus)
}
#endif

typedef CFTypeRef (*UICreateScreenUIImageFunc)(void);

@interface VCAMFlashLivenessManager () {
    dispatch_source_t _samplingTimer;
    dispatch_queue_t _samplingQueue;
    BOOL _isEnabled;
    BOOL _isTestMode;
    CGFloat _intensity;
    float _smoothedR;
    float _smoothedG;
    float _smoothedB;
    float _smoothedIntensity;
    NSInteger _testColorIndex;
    UICreateScreenUIImageFunc _uikitCreateScreenUIImage;
    int _consecutiveCaptureFailures;
    NSTimeInterval _monitorStartTime;

    // ── Rhythm Learner: Tự học nhịp chớp màu của app KYC ──
    // Ghi lại thời điểm phát hiện mỗi lần chớp màu mới
    NSTimeInterval _lastFlashOnsetTime;       // Thời điểm phát hiện lần chớp gần nhất
    NSTimeInterval _prevFlashOnsetTime;       // Thời điểm lần chớp trước đó
    // Bộ lọc EMA cho chu kỳ chớp (Period)
    double _learnedPeriodSec;                 // Chu kỳ học được (giây), 0 = chưa học
    int _rhythmSampleCount;                   // Số mẫu nhịp đã ghi nhận
    NSString *_lastDetectedColorName;         // Màu chớp trước đó để nhận biết đổi màu mới
    // Trạng thái hiện tại của máy học nhịp
    BOOL _rhythmInFlashPhase;                 // YES = đang trong pha sáng, NO = đang tối
    NSTimeInterval _rhythmPhaseStartTime;     // Thời điểm bắt đầu pha hiện tại
    // Dự đoán lần chớp tiếp theo (để pre-light trước khi quét kịp)
    NSTimeInterval _predictedNextFlashTime;   // Thời điểm dự đoán lần chớp tiếp theo
    float _predictionConfidence;              // Độ tin cậy dự đoán [0..1]
}
@end

@implementation VCAMFlashLivenessManager

+ (instancetype)sharedManager {
    static VCAMFlashLivenessManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCAMFlashLivenessManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _intensity = 0.35f;
        _smoothedR = 1.0f;
        _smoothedG = 1.0f;
        _smoothedB = 1.0f;
        _smoothedIntensity = 0.0f;
        _testColorIndex = 0;
        _consecutiveCaptureFailures = 0;
        _samplingQueue = dispatch_queue_create("com.vcam.flash.sampler", DISPATCH_QUEUE_SERIAL);

        // Safe resolution of screen capture function for SpringBoard (iOS 15 / 16 / Dopamine / RootHide)
        if (_UICreateScreenUIImage != NULL) {
            _uikitCreateScreenUIImage = _UICreateScreenUIImage;
        } else {
            void *handle = dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore", RTLD_NOW | RTLD_GLOBAL);
            if (!handle) handle = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW | RTLD_GLOBAL);
            if (!handle) handle = dlopen(NULL, RTLD_GLOBAL);
            if (handle) {
                _uikitCreateScreenUIImage = (UICreateScreenUIImageFunc)dlsym(handle, "_UICreateScreenUIImage");
            }
            if (!_uikitCreateScreenUIImage) {
                _uikitCreateScreenUIImage = (UICreateScreenUIImageFunc)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
            }
        }

        _isEnabled = NO;
        _isTestMode = NO;

        // Rhythm Learner initial state
        _lastFlashOnsetTime     = 0;
        _prevFlashOnsetTime     = 0;
        _learnedPeriodSec       = 0;
        _rhythmSampleCount      = 0;
        _lastDetectedColorName  = nil;
        _rhythmInFlashPhase     = NO;
        _rhythmPhaseStartTime   = 0;
        _predictedNextFlashTime = 0;
        _predictionConfidence   = 0.0f;
    }
    return self;
}

#pragma mark - Properties

- (BOOL)isLivenessEnabled {
    return _isEnabled;
}

- (void)setLivenessEnabled:(BOOL)enabled {
    _isEnabled = enabled;
    VCAMFlashState s = [VCAMFlashLivenessManager currentFlashState];
    s.active = NO;
    s.testMode = _isTestMode;
    s.intensity = 0.0f;
    [VCAMFlashLivenessManager saveFlashState:s];

    if (enabled) {
        [self startScreenColorMonitoring];
    } else {
        [self stopScreenColorMonitoring];
    }
}

- (BOOL)isTestModeEnabled {
    return _isTestMode;
}

- (void)setTestModeEnabled:(BOOL)enabled {
    _isTestMode = enabled;
    if (enabled) {
        _isEnabled = YES;
    }
    VCAMFlashState s = [VCAMFlashLivenessManager currentFlashState];
    s.active = _isEnabled;
    s.testMode = enabled;
    [VCAMFlashLivenessManager saveFlashState:s];

    if (_isEnabled) {
        [self startScreenColorMonitoring];
    } else {
        [self stopScreenColorMonitoring];
    }
}

- (CGFloat)flashIntensity {
    return _intensity;
}

- (void)setFlashIntensity:(CGFloat)intensity {
    if (intensity < 0.10f) intensity = 0.10f;
    if (intensity > 0.85f) intensity = 0.85f;
    _intensity = intensity;
    VCAMFlashState s = [VCAMFlashLivenessManager currentFlashState];
    s.intensity = (float)_intensity;
    [VCAMFlashLivenessManager saveFlashState:s];
}

#pragma mark - Shared File State & IPC

static NSArray<NSString *> *PossibleTmpDirs(void) {
    static NSArray<NSString *> *dirs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray *list = [NSMutableArray array];
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/rootfs/private/var/tmp"]) {
            [list addObject:@"/rootfs/private/var/tmp"];
        }
        [list addObject:@"/var/tmp"];
        [list addObject:@"/private/var/tmp"];
        dirs = [list copy];
    });
    return dirs;
}

static NSString *FindExistingStatePath(void) {
    static NSString *cachedPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (NSString *dir in PossibleTmpDirs()) {
            NSString *p = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMFlashStateFileName]];
            if (access([p UTF8String], F_OK) == 0) {
                cachedPath = p;
                break;
            }
        }
        if (!cachedPath) {
            for (NSString *dir in PossibleTmpDirs()) {
                if ([[NSFileManager defaultManager] fileExistsAtPath:dir]) {
                    cachedPath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMFlashStateFileName]];
                    break;
                }
            }
        }
        if (!cachedPath) {
            cachedPath = [@"/var/tmp" stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMFlashStateFileName]];
        }
    });
    return cachedPath;
}

+ (VCAMFlashState)currentFlashState {
    VCAMSharedFlashState *shared = VCAMGetSharedFlashState(false);
    if (shared && shared->magic == VCAM_SHARED_FLASH_MAGIC) {
        VCAMFlashState s;
        s.active = (shared->active != 0);
        s.r = shared->r;
        s.g = shared->g;
        s.b = shared->b;
        s.intensity = shared->intensity;
        s.testMode = NO;
        return s;
    }

    static VCAMFlashState cachedState = {1.0f, 1.0f, 1.0f, 0.35f, NO, NO};
    static NSTimeInterval lastReadTime = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - lastReadTime < 0.12) {
        return cachedState;
    }
    lastReadTime = now;

    NSString *path = FindExistingStatePath();
    FILE *f = fopen([path UTF8String], "r");
    if (f) {
        int act = 0, test = 0;
        float r = 1.0f, g = 1.0f, b = 1.0f, inten = 0.35f;
        if (fscanf(f, "%d %d %f %f %f %f", &act, &test, &r, &g, &b, &inten) >= 5) {
            cachedState.active = (act != 0);
            cachedState.testMode = (test != 0);
            cachedState.r = r;
            cachedState.g = g;
            cachedState.b = b;
            cachedState.intensity = (inten > 0.01f) ? inten : 0.35f;
        }
        fclose(f);
    }
    return cachedState;
}

+ (void)saveFlashState:(VCAMFlashState)state {
    // 1. Cập nhật tức thì vào Shared Memory (0ms latency, trực tiếp trong RAM)
    VCAMSharedFlashState *shared = VCAMGetSharedFlashState(true);
    if (shared) {
        shared->active = state.active ? 1 : 0;
        shared->r = state.r;
        shared->g = state.g;
        shared->b = state.b;
        shared->intensity = state.intensity;
        shared->isColorSync = 0;
        shared->sequence++;
        shared->timestamp = [NSDate timeIntervalSinceReferenceDate];
    }

    // 2. Fallback ghi file chia sẻ
    char buf[128];
    snprintf(buf, sizeof(buf), "%d %d %.3f %.3f %.3f %.2f\n",
             state.active ? 1 : 0,
             state.testMode ? 1 : 0,
             state.r, state.g, state.b,
             state.intensity);

    for (NSString *dir in PossibleTmpDirs()) {
        NSString *filePath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMFlashStateFileName]];
        FILE *f = fopen([filePath UTF8String], "w");
        if (f) {
            fputs(buf, f);
            fclose(f);
            chmod([filePath UTF8String], 0666);
        }
    }
}

#pragma mark - Screen Color Sampler (SpringBoard)

/// Các dải màu nhận diện KYC Flash
typedef enum {
    BIN_NONE = -1,
    BIN_RED = 0,
    BIN_GREEN,
    BIN_BLUE,
    BIN_YELLOW,
    BIN_CYAN,
    BIN_MAGENTA,
    BIN_COUNT
} KYCColorBinType;

typedef struct {
    float sumR;
    float sumG;
    float sumB;
    float totalWeight;
    int pixelCount;
} KYCColorBin;

static const char *kBinNames[BIN_COUNT] = {
    "ĐỎ (Red)",
    "XANH LỤC (Green)",
    "XANH LAM (Blue)",
    "VÀNG (Yellow)",
    "CYAN (Xanh ngọc)",
    "TÍM (Magenta)"
};

/// Thuật toán trích xuất dải màu và độ sáng màn hình theo thời gian thực (Zero-Lag Screen Flash Detection)
/// Quét lưới 24x24 (576 điểm ảnh) loại trừ nút tweak, nhận diện tức thì cả White Flash và Chroma Flash
static void ComputeDominantScreenRGB(CGImageRef cgImage, float *outR, float *outG, float *outB, float *outSat, float *outLum, NSString **outColorName, int *outVotedCount, float *outVotedWeight) {
    if (!cgImage) return;

    const int sampleW = 24;
    const int sampleH = 24;
    uint32_t pixels[sampleW * sampleH] = {0};

    static CGColorSpaceRef sColorSpace = NULL;
    static dispatch_once_t sColorOnce;
    dispatch_once(&sColorOnce, ^{
        sColorSpace = CGColorSpaceCreateDeviceRGB();
    });
    if (!sColorSpace) return;

    CGContextRef context = CGBitmapContextCreate(pixels, sampleW, sampleH, 8, sampleW * 4, sColorSpace,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (context) {
        CGContextSetInterpolationQuality(context, kCGInterpolationLow);
        CGContextDrawImage(context, CGRectMake(0, 0, sampleW, sampleH), cgImage);
        CGContextRelease(context);

        KYCColorBin bins[BIN_COUNT] = {0};
        float totalR = 0, totalG = 0, totalB = 0;
        int validCount = 0;

        for (int y = 0; y < sampleH; y++) {
            float normY = (float)y / (float)sampleH;

            // Loại trừ thanh status bar trên cùng và home indicator dưới cùng
            if (normY < 0.08f || normY > 0.94f) continue;

            for (int x = 0; x < sampleW; x++) {
                float normX = (float)x / (float)sampleW;

                // Loại trừ vị trí nút nổi của chính tweak
                if (VCamIsScreenPointInTweakUI(normX, normY)) continue;

                uint32_t p = pixels[y * sampleW + x];
                float r = (float)(p & 0xFF) / 255.0f;
                float g = (float)((p >> 8) & 0xFF) / 255.0f;
                float b = (float)((p >> 16) & 0xFF) / 255.0f;

                totalR += r;
                totalG += g;
                totalB += b;
                validCount++;

                float maxVal = MAX(r, MAX(g, b));
                float minVal = MIN(r, MIN(g, b));
                float delta = maxVal - minVal;

                // Phân loại dải màu (Chroma Binning) cho các pixel có độ bão hòa
                if (delta >= 0.10f && maxVal >= 0.18f) {
                    float weight = delta * delta * maxVal;
                    KYCColorBinType binIdx = BIN_NONE;

                    if (r > 0.40f && r > g * 1.25f && r > b * 1.25f) {
                        binIdx = BIN_RED; // ĐỎ
                    } else if (g > 0.35f && g > r * 1.15f && g > b * 1.10f) {
                        binIdx = BIN_GREEN; // XANH LỤC
                    } else if (b > 0.35f && b > r * 1.20f && b > g * 1.05f) {
                        binIdx = BIN_BLUE; // XANH LAM
                    } else if (g > 0.30f && b > 0.30f && (g + b) > 1.8f * r && fabsf(g - b) < 0.30f) {
                        binIdx = BIN_CYAN; // CYAN (Xanh ngọc)
                    } else if (r > 0.45f && g > 0.38f && b < 0.35f && (r + g) > 2.0f * b) {
                        binIdx = BIN_YELLOW; // VÀNG
                    } else if (r > 0.40f && b > 0.40f && g < 0.35f) {
                        binIdx = BIN_MAGENTA; // TÍM
                    }

                    if (binIdx != BIN_NONE) {
                        bins[binIdx].sumR += r * weight;
                        bins[binIdx].sumG += g * weight;
                        bins[binIdx].sumB += b * weight;
                        bins[binIdx].totalWeight += weight;
                        bins[binIdx].pixelCount++;
                    }
                }
            }
        }

        float meanR = (validCount > 0) ? (totalR / validCount) : 0.0f;
        float meanG = (validCount > 0) ? (totalG / validCount) : 0.0f;
        float meanB = (validCount > 0) ? (totalB / validCount) : 0.0f;
        float lum = 0.299f * meanR + 0.587f * meanG + 0.114f * meanB;
        if (outLum) *outLum = lum;

        // Tìm bin màu có trọng số cao nhất
        KYCColorBinType bestBin = BIN_NONE;
        float maxWeight = 0.0f;
        for (int k = 0; k < BIN_COUNT; k++) {
            if (bins[k].totalWeight > maxWeight) {
                maxWeight = bins[k].totalWeight;
                bestBin = (KYCColorBinType)k;
            }
        }

        // 1. Nhận diện chớp màu KYC đặc trưng (Red, Green, Blue, Cyan, Yellow, Magenta)
        if (bestBin != BIN_NONE && bins[bestBin].pixelCount >= 6 && maxWeight > 1.2f) {
            float avgR = bins[bestBin].sumR / bins[bestBin].totalWeight;
            float avgG = bins[bestBin].sumG / bins[bestBin].totalWeight;
            float avgB = bins[bestBin].sumB / bins[bestBin].totalWeight;

            // Chuẩn hóa độ rực
            float maxC = MAX(avgR, MAX(avgG, avgB));
            if (maxC > 0.01f) {
                avgR /= maxC;
                avgG /= maxC;
                avgB /= maxC;
            }
            float sat = maxC - MIN(avgR, MIN(avgG, avgB));

            if (outSat) *outSat = sat;
            *outR = avgR;
            *outG = avgG;
            *outB = avgB;
            if (outColorName) *outColorName = [NSString stringWithUTF8String:kBinNames[bestBin]];
            if (outVotedCount) *outVotedCount = bins[bestBin].pixelCount;
            if (outVotedWeight) *outVotedWeight = maxWeight;
        }
        // 2. Nhận diện chớp sáng trắng / trung tính (White Flash - phổ biến ở app test và KYC flash)
        else if (lum >= 0.48f) {
            if (outSat) *outSat = 0.0f;
            *outR = 1.0f;
            *outG = 1.0f;
            *outB = 1.0f;
            if (outColorName) *outColorName = @"Trắng Flash";
            if (outVotedCount) *outVotedCount = validCount;
            if (outVotedWeight) *outVotedWeight = lum * 10.0f;
        }
        // 3. Màn hình bình thường (không có flash)
        else {
            if (outSat) *outSat = 0.0f;
            *outR = meanR;
            *outG = meanG;
            *outB = meanB;
            if (outColorName) *outColorName = @"Bình thường";
            if (outVotedCount) *outVotedCount = 0;
            if (outVotedWeight) *outVotedWeight = 0.0f;
        }
    }
}

- (void)startScreenColorMonitoring {
    if (_samplingTimer) return;

    _monitorStartTime = [NSDate timeIntervalSinceReferenceDate];
    _samplingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _samplingQueue);
    // Tần số quét 25ms (40 FPS): Bắt tức thì mọi nhịp chớp màu màn hình eKYC thời gian thực (< 25ms)
    dispatch_source_set_timer(_samplingTimer, DISPATCH_TIME_NOW, 25 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_samplingTimer, ^{
        [weakSelf _sampleTick];
    });
    dispatch_resume(_samplingTimer);
}

- (void)stopScreenColorMonitoring {
    if (_samplingTimer) {
        dispatch_source_cancel(_samplingTimer);
        _samplingTimer = nil;
    }
}

- (void)_sampleTick {
    if (!_isEnabled) return;

    if (_isTestMode) {
        // Chế độ test mô phỏng: đảo 6 màu tuần hoàn mỗi 450ms
        static const float testPalette[6][3] = {
            {1.00f, 1.00f, 1.00f}, // Sáng trắng
            {0.20f, 0.75f, 1.00f}, // Xanh lam (Cyan/Blue)
            {1.00f, 0.25f, 0.25f}, // Đỏ (Red)
            {0.30f, 0.95f, 0.35f}, // Xanh lục (Green)
            {1.00f, 0.90f, 0.20f}, // Vàng (Yellow)
            {0.90f, 0.30f, 0.90f}  // Tím hồng (Magenta)
        };

        static NSTimeInterval lastCycleTime = 0;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - lastCycleTime > 0.45) {
            lastCycleTime = now;
            _testColorIndex = (_testColorIndex + 1) % 6;
        }

        float targetR = testPalette[_testColorIndex][0];
        float targetG = testPalette[_testColorIndex][1];
        float targetB = testPalette[_testColorIndex][2];

        _smoothedR = targetR;
        _smoothedG = targetG;
        _smoothedB = targetB;

        VCAMFlashState s;
        s.active = YES;
        s.testMode = YES;
        s.r = _smoothedR;
        s.g = _smoothedG;
        s.b = _smoothedB;
        s.intensity = (float)_intensity;
        [VCAMFlashLivenessManager saveFlashState:s];
        return;
    }

    // Tự động quét màu màn hình app eKYC theo thời gian thực (40 FPS)
    if (_uikitCreateScreenUIImage) {
        @autoreleasepool {
            @try {
                CFTypeRef rawImg = _uikitCreateScreenUIImage();
                if (rawImg) {
                    UIImage *screenImg = (__bridge_transfer UIImage *)rawImg;
                    if (screenImg && screenImg.CGImage) {
                        float sampleR = 1.0f, sampleG = 1.0f, sampleB = 1.0f;
                        float saturation = 0.0f;
                        float luminance = 0.0f;
                        NSString *detectedColorName = @"Bình thường";
                        int votedCount = 0;
                        float votedWeight = 0.0f;

                        ComputeDominantScreenRGB(screenImg.CGImage, &sampleR, &sampleG, &sampleB, &saturation, &luminance, &detectedColorName, &votedCount, &votedWeight);

                        BOOL isFlashingNow = NO;
                        float targetIntensity = 0.0f;

                        if ([detectedColorName isEqualToString:@"Trắng Flash"] || luminance >= 0.48f) {
                            // Chớp sáng trắng (White Flash - ví dụ app test chế độ 1s)
                            isFlashingNow = YES;
                            float boost = MIN(1.0f, (luminance - 0.35f) / 0.40f);
                            targetIntensity = (float)_intensity * MAX(0.25f, boost);
                            sampleR = 1.0f; sampleG = 1.0f; sampleB = 1.0f;
                        } else if (saturation >= 0.10f && votedCount >= 6) {
                            // Chớp màu KYC (Color Flash)
                            isFlashingNow = YES;
                            float boost = MIN(1.0f, MAX(luminance, saturation * 1.30f));
                            targetIntensity = (float)_intensity * MAX(0.25f, boost);
                        } else {
                            // Màn hình bình thường
                            isFlashingNow = NO;
                            targetIntensity = 0.0f;
                        }

                        // ── BẬT TỨC THÌ (Zero-Lag Snap) khi xuất hiện chớp mới ──
                        if (isFlashingNow) {
                            if (_smoothedIntensity < 0.05f) {
                                // Khung hình đầu tiên của cú chớp: BẬT 100% CƯỜNG ĐỘ NGAY TRONG 0MS!
                                _smoothedR = sampleR;
                                _smoothedG = sampleG;
                                _smoothedB = sampleB;
                                _smoothedIntensity = targetIntensity;
                            } else {
                                // Trong suốt cú chớp: bám sát màu màn hình tức thì
                                _smoothedR = _smoothedR * 0.10f + sampleR * 0.90f;
                                _smoothedG = _smoothedG * 0.10f + sampleG * 0.90f;
                                _smoothedB = _smoothedB * 0.10f + sampleB * 0.90f;
                                _smoothedIntensity = targetIntensity;
                            }
                        } else {
                            // Khi hết chớp: hạ ánh sáng nhanh trong 2-3 frame (~50-70ms)
                            _smoothedIntensity = _smoothedIntensity * 0.25f;
                            if (_smoothedIntensity < 0.02f) {
                                _smoothedIntensity = 0.0f;
                            }
                        }

                        // ── Cập nhật thẳng vào Shared Memory (0ms IPC, không qua file đĩa) ──
                        VCAMSharedFlashState *shared = VCAMGetSharedFlashState(true);
                        if (shared) {
                            shared->active = (_smoothedIntensity > 0.01f) ? 1 : 0;
                            shared->r = _smoothedR;
                            shared->g = _smoothedG;
                            shared->b = _smoothedB;
                            shared->intensity = _smoothedIntensity;
                            shared->isColorSync = 0;
                            shared->sequence++;
                            shared->timestamp = [NSDate timeIntervalSinceReferenceDate];
                        }

                        VCAMFlashState s;
                        s.active = (_smoothedIntensity > 0.01f);
                        s.testMode = _isTestMode;
                        s.r = _smoothedR;
                        s.g = _smoothedG;
                        s.b = _smoothedB;
                        s.intensity = _smoothedIntensity;

                        static NSTimeInterval lastLogTime = 0;
                        static BOOL lastLoggedActive = NO;
                        static NSString *lastLoggedColor = nil;
                        NSTimeInterval nowLog = [NSDate timeIntervalSinceReferenceDate];
                        BOOL stateChanged = (s.active != lastLoggedActive) || (![detectedColorName isEqualToString:lastLoggedColor]);
                        if (stateChanged || (nowLog - lastLogTime > 1.0)) {
                            lastLogTime = nowLog;
                            lastLoggedActive = s.active;
                            lastLoggedColor = detectedColorName;
                            NSString *logMsg = [NSString stringWithFormat:
                                @"[KYC Flash] %@ [voted: %d px] | Active=%s Inten=%.2f | "
                                 "Lum=%.2f Sat=%.2f | OutRGB=(%.2f, %.2f, %.2f)\n",
                                detectedColorName, votedCount,
                                s.active ? "YES" : "NO", _smoothedIntensity,
                                luminance, saturation, _smoothedR, _smoothedG, _smoothedB];
                            FILE *lf = fopen("/var/tmp/vcam_flash.log", "a");
                            if (!lf) lf = fopen("/tmp/vcam_flash.log", "a");
                            if (lf) {
                                fputs([logMsg UTF8String], lf);
                                fclose(lf);
                                chmod("/var/tmp/vcam_flash.log", 0666);
                            }
                        }
                    }
                }
            } @catch (NSException *e) {
                // Ignore capture exception
            }
        }
    }
}

#pragma mark - CoreImage Photometric Lighting Engine (Metal GPU)

+ (CIImage *)applyFlashLightingToImage:(CIImage *)sourceImage
                                  size:(CGSize)size
                                 state:(VCAMFlashState)state {
    if (!sourceImage || !state.active || state.intensity <= 0.01f) {
        return sourceImage;
    }

    @autoreleasepool {
        @try {
            float r = state.r;
            float g = state.g;
            float b = state.b;
            float intensity = state.intensity;
            if (intensity < 0.05f) intensity = 0.05f;
            if (intensity > 0.85f) intensity = 0.85f;

            // 1. Phản quang tán xạ tự nhiên bao phủ đều khuôn mặt (Diffuse Photometric Screen Reflection)
            CGFloat centerX = size.width / 2.0f;
            CGFloat centerY = size.height * 0.48f;
            CGFloat innerRadius = MIN(size.width, size.height) * 0.38f; // Lan tỏa đều trán, mắt, má, mũi
            CGFloat outerRadius = MAX(size.width, size.height) * 0.85f; // Tán xạ mềm biên ngoài màn hình

            CIColor *centerColor = [CIColor colorWithRed:r green:g blue:b alpha:intensity * 0.70f];
            CIColor *outerColor = [CIColor colorWithRed:r green:g blue:b alpha:intensity * 0.06f];

            CIFilter *radialGradient = [CIFilter filterWithName:@"CIRadialGradient"];
            [radialGradient setValue:[CIVector vectorWithX:centerX Y:centerY] forKey:@"inputCenter"];
            [radialGradient setValue:@(innerRadius) forKey:@"inputRadius0"];
            [radialGradient setValue:@(outerRadius) forKey:@"inputRadius1"];
            [radialGradient setValue:centerColor forKey:@"inputColor0"];
            [radialGradient setValue:outerColor forKey:@"inputColor1"];

            CIImage *lightGradient = [radialGradient.outputImage imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];
            if (!lightGradient) return sourceImage;

            // 2. Blend lighting onto video frame via Soft Light (photometric screen reflection)
            CIFilter *blendFilter = [CIFilter filterWithName:@"CISoftLightBlendMode"];
            [blendFilter setValue:lightGradient forKey:kCIInputImageKey];
            [blendFilter setValue:sourceImage forKey:kCIInputBackgroundImageKey];
            CIImage *output = blendFilter.outputImage;

            return output ?: sourceImage;
        } @catch (NSException *ex) {
            NSLog(@"[VCAMFlashLivenessManager] Lighting error: %@", ex);
            return sourceImage;
        }
    }
}

@end
