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
    static VCAMFlashState cachedState = {1.0f, 1.0f, 1.0f, 0.35f, NO, NO};
    static NSTimeInterval lastReadTime = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - lastReadTime < 0.12) { // 120ms throttle cache: 8-9 reads/sec for fast responsiveness with low I/O
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

/// Thuật toán trích xuất dải màu bão hòa chủ đạo (Dominant Chroma Bin Voting)
/// Quét lưới 24x24 (576 điểm ảnh), loại trừ 100% giao diện tweak, phân loại cụm màu áp đảo
static void ComputeDominantScreenRGB(CGImageRef cgImage, float *outR, float *outG, float *outB, float *outSat, NSString **outColorName, int *outVotedCount, float *outVotedWeight) {
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
        int validSampledCount = 0;

        for (int y = 0; y < sampleH; y++) {
            float normY = (float)y / (float)sampleH;

            // 1. Loại trừ top 12% (Header, Status Bar, App Title) và bottom 10% (Home Indicator, Guide Banner)
            // Ngăn chặn 100% việc nhận diện nhầm thanh giao diện màu xanh của MSB Bank!
            if (normY < 0.12f || normY > 0.90f) {
                continue;
            }

            for (int x = 0; x < sampleW; x++) {
                float normX = (float)x / (float)sampleW;

                // 2. Loại trừ 100% vùng giao diện của chính tweak (Floating Button & Control Panel)
                if (VCamIsScreenPointInTweakUI(normX, normY)) {
                    continue;
                }

                // 3. QUAN TRỌNG: Loại trừ vùng Camera Preview ở trung tâm màn hình (vùng hiển thị khuôn mặt)
                // để phá vỡ hoàn toàn vòng lặp hồi tiếp quang học (Optical Feedback Loop)!
                // Khung oval khuôn mặt nằm ở: X từ 0.22 đến 0.78, Y từ 0.20 đến 0.76.
                // Ánh sáng chớp eKYC bao phủ viền màn hình và nền ngoài oval, do đó việc chỉ quét viền ngoài
                // vừa bắt trúng 100% nhịp chớp thật của app, vừa không bao giờ nhìn thấy ánh sáng mà tweak chiếu lên mặt!
                if (normX >= 0.22f && normX <= 0.78f && normY >= 0.20f && normY <= 0.76f) {
                    continue;
                }

                uint32_t p = pixels[y * sampleW + x];
                float r = (float)(p & 0xFF) / 255.0f;
                float g = (float)((p >> 8) & 0xFF) / 255.0f;
                float b = (float)((p >> 16) & 0xFF) / 255.0f;

                totalR += r;
                totalG += g;
                totalB += b;
                validSampledCount++;

                float maxVal = MAX(r, MAX(g, b));
                float minVal = MIN(r, MIN(g, b));
                float delta = maxVal - minVal;

                // Bỏ qua các điểm ảnh tối hoặc xám/trắng/trung tính (da mặt bình thường, nền xám/đen)
                // Ngưỡng bão hòa delta >= 0.18f
                if (maxVal < 0.18f || delta < 0.18f) {
                    continue;
                }

                // Trọng số bão hòa bình phương: điểm ảnh càng rực màu thì tiếng nói càng áp đảo
                float weight = delta * delta * maxVal;
                // Vùng viền màn hình (nơi app eKYC hay chớp màu) được tăng 30% trọng số
                if (y < 6 || y > 17 || x < 5 || x > 18) {
                    weight *= 1.30f;
                }

                // Phân loại dải màu (Chroma Bin Classification)
                KYCColorBinType binIdx = BIN_NONE;

                if (r > 0.40f && r > g * 1.30f && r > b * 1.30f) {
                    binIdx = BIN_RED; // ĐỎ
                } else if (g > 0.35f && g > r * 1.20f && g > b * 1.15f) {
                    binIdx = BIN_GREEN; // XANH LỤC
                } else if (b > 0.38f && b > r * 1.25f && b > g * 1.05f) {
                    binIdx = BIN_BLUE; // XANH LAM
                } else if (g > 0.35f && b > 0.35f && (g + b) > 2.0f * r && fabsf(g - b) < 0.25f) {
                    binIdx = BIN_CYAN; // CYAN (Xanh ngọc)
                } else if (r > 0.50f && g > 0.42f && b < 0.32f && (r + g) > 2.2f * b) {
                    binIdx = BIN_YELLOW; // VÀNG
                } else if (r > 0.45f && b > 0.45f && g < 0.35f) {
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

        // Tìm bin màu áp đảo (Dominant Bin)
        KYCColorBinType bestBin = BIN_NONE;
        float maxWeight = 0.0f;
        for (int k = 0; k < BIN_COUNT; k++) {
            if (bins[k].totalWeight > maxWeight) {
                maxWeight = bins[k].totalWeight;
                bestBin = (KYCColorBinType)k;
            }
        }

        // Ngưỡng xác nhận KYC Flash ngoại vi: cần ít nhất 18 điểm ảnh viền bão hòa cao và tổng trọng số > 6.0
        // (Tránh hoàn toàn việc các icon nhỏ hay viền màu nhẹ kích hoạt nhầm)
        if (bestBin != BIN_NONE && bins[bestBin].pixelCount >= 18 && maxWeight > 6.0f) {
            float avgR = bins[bestBin].sumR / bins[bestBin].totalWeight;
            float avgG = bins[bestBin].sumG / bins[bestBin].totalWeight;
            float avgB = bins[bestBin].sumB / bins[bestBin].totalWeight;

            // Tăng cường độ rực màu (Boost Saturation) để phản chiếu lên da mặt rõ nét nhất
            float maxC = MAX(avgR, MAX(avgG, avgB));
            if (maxC > 0.01f) {
                avgR /= maxC;
                avgG /= maxC;
                avgB /= maxC;
            }

            float minC = MIN(avgR, MIN(avgG, avgB));
            float sat = maxC - minC;

            if (outSat) *outSat = sat;
            *outR = avgR;
            *outG = avgG;
            *outB = avgB;
            if (outColorName) *outColorName = [NSString stringWithUTF8String:kBinNames[bestBin]];
            if (outVotedCount) *outVotedCount = bins[bestBin].pixelCount;
            if (outVotedWeight) *outVotedWeight = maxWeight;
        } else {
            // Không có chớp màu đặc biệt (màn hình trung tính, camera preview bình thường, hoặc đang chụp ảnh khuôn mặt)
            if (outSat) *outSat = 0.0f;
            if (validSampledCount > 0) {
                *outR = totalR / validSampledCount;
                *outG = totalG / validSampledCount;
                *outB = totalB / validSampledCount;
            } else {
                *outR = 1.0f; *outG = 1.0f; *outB = 1.0f;
            }
            if (outColorName) *outColorName = @"Trắng/Trung tính";
            if (outVotedCount) *outVotedCount = 0;
            if (outVotedWeight) *outVotedWeight = 0.0f;
        }
    }
}

- (void)startScreenColorMonitoring {
    if (_samplingTimer) return;

    _monitorStartTime = [NSDate timeIntervalSinceReferenceDate];

    // Reset Rhythm Learner mỗi lần bật lại để học nhịp mới từ đầu
    _lastFlashOnsetTime     = 0;
    _prevFlashOnsetTime     = 0;
    _learnedPeriodSec       = 0;
    _rhythmSampleCount      = 0;
    _lastDetectedColorName  = nil;
    _rhythmInFlashPhase     = NO;
    _rhythmPhaseStartTime   = 0;
    _predictedNextFlashTime = 0;
    _predictionConfidence   = 0.0f;

    _samplingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _samplingQueue);
    // Tần số quét 120ms (~8 FPS): bắt trúng kể cả các nhịp chớp nhanh 150-200ms của eKYC hiện đại
    // (tăng từ 320ms cũ lên 120ms - CPU overhead thêm rất nhỏ vì _UICreateScreenUIImage chỉ downscale 24x24)
    dispatch_source_set_timer(_samplingTimer, DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC, 15 * NSEC_PER_MSEC);

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

    // Tự động tắt sau 90 giây để bảo vệ pin và chống chạy ngầm kéo dài
    if ([NSDate timeIntervalSinceReferenceDate] - _monitorStartTime > 90.0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLivenessEnabled:NO];
        });
        return;
    }

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

        // Lọc trễ quang học EMA mượt mà
        _smoothedR = _smoothedR * 0.35f + targetR * 0.65f;
        _smoothedG = _smoothedG * 0.35f + targetG * 0.65f;
        _smoothedB = _smoothedB * 0.35f + targetB * 0.65f;

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

    // Tự động quét màu màn hình app eKYC theo thời gian thực
    BOOL capturedSuccess = NO;
    if (_uikitCreateScreenUIImage) {
        @autoreleasepool {
            @try {
                CFTypeRef rawImg = _uikitCreateScreenUIImage();
                if (rawImg) {
                    UIImage *screenImg = (__bridge_transfer UIImage *)rawImg;
                    if (screenImg && screenImg.CGImage) {
                        capturedSuccess = YES;
                        _consecutiveCaptureFailures = 0;

                        float sampleR = 1.0f, sampleG = 1.0f, sampleB = 1.0f;
                        float saturation = 0.0f;
                        NSString *detectedColorName = @"Trắng/Trung tính";
                        int votedCount = 0;
                        float votedWeight = 0.0f;

                        ComputeDominantScreenRGB(screenImg.CGImage, &sampleR, &sampleG, &sampleB, &saturation, &detectedColorName, &votedCount, &votedWeight);

                        // ── Rhythm Learner: Phát hiện flash onset & học chu kỳ chớp ──
                        BOOL isFlashingNow = (saturation > 0.20f && votedCount >= 12);

                        // Nhận diện "onset" (bắt đầu chớp mới): khi đổi màu KYC hoặc chuyển từ tối → sáng màu
                        BOOL isNewFlashOnset = NO;
                        NSTimeInterval nowSampleTime = [NSDate timeIntervalSinceReferenceDate];

                        if (isFlashingNow) {
                            // Đổi màu = lần chớp mới (VPBank, MSB thường đổi màu liên tục)
                            BOOL colorChanged = (_lastDetectedColorName != nil &&
                                                 ![_lastDetectedColorName isEqualToString:detectedColorName]);
                            // Hoặc vừa bật lại sau pha tối (pha tối kéo dài > 60ms)
                            BOOL wasInDark = (!_rhythmInFlashPhase &&
                                             (nowSampleTime - _rhythmPhaseStartTime) > 0.06);

                            if (colorChanged || wasInDark || _lastFlashOnsetTime == 0) {
                                isNewFlashOnset = YES;
                            }

                            _rhythmInFlashPhase = YES;
                            _lastDetectedColorName = detectedColorName;
                        } else {
                            // Pha tối bắt đầu
                            if (_rhythmInFlashPhase) {
                                _rhythmInFlashPhase = NO;
                                _rhythmPhaseStartTime = nowSampleTime;
                            }
                        }

                        // Ghi nhận onset và cập nhật chu kỳ học
                        if (isNewFlashOnset && nowSampleTime > 0) {
                            if (_lastFlashOnsetTime > 0) {
                                double measuredPeriod = nowSampleTime - _lastFlashOnsetTime;
                                // Chỉ học nếu chu kỳ hợp lý (100ms – 2000ms) = range của mọi app KYC thực tế
                                if (measuredPeriod >= 0.10 && measuredPeriod <= 2.0) {
                                    if (_learnedPeriodSec == 0) {
                                        _learnedPeriodSec = measuredPeriod;
                                    } else {
                                        // Bộ lọc EMA với alpha = 0.35 (học nhanh nhưng không giật)
                                        _learnedPeriodSec = _learnedPeriodSec * 0.65 + measuredPeriod * 0.35;
                                    }
                                    _rhythmSampleCount++;

                                    // Tính độ tin cậy: tăng tuyến tính theo số mẫu (bão hòa sau 6 mẫu)
                                    _predictionConfidence = MIN(1.0f, (float)_rhythmSampleCount / 6.0f);

                                    // Dự đoán lần chớp tiếp theo
                                    _predictedNextFlashTime = nowSampleTime + _learnedPeriodSec;
                                }
                            }
                            _prevFlashOnsetTime = _lastFlashOnsetTime;
                            _lastFlashOnsetTime = nowSampleTime;
                        }

                        // ── Tính intensity phản quang kết hợp: thực tế + dự đoán nhịp ──
                        float effectiveIntensity = 0.0f;

                        if (_isTestMode) {
                            effectiveIntensity = (float)_intensity;
                            _smoothedR = _smoothedR * 0.15f + sampleR * 0.85f;
                            _smoothedG = _smoothedG * 0.15f + sampleG * 0.85f;
                            _smoothedB = _smoothedB * 0.15f + sampleB * 0.85f;
                        } else if (isFlashingNow) {
                            // Màn hình thực sự đang chớp màu KYC → phản quang trực tiếp
                            NSTimeInterval flashDuration = nowSampleTime - _lastFlashOnsetTime;
                            float decay = 1.0f;
                            if (flashDuration > 1.2) {
                                decay = MAX(0.0f, 1.0f - (float)(flashDuration - 1.2) / 0.5f);
                            }
                            effectiveIntensity = (float)_intensity * MIN(1.0f, saturation * 1.35f) * decay;
                            // EMA nhanh hơn (0.10/0.90) khi 120ms sampling để không lag thị giác
                            _smoothedR = _smoothedR * 0.10f + sampleR * 0.90f;
                            _smoothedG = _smoothedG * 0.10f + sampleG * 0.90f;
                            _smoothedB = _smoothedB * 0.10f + sampleB * 0.90f;
                        } else if (_predictionConfidence >= 0.5f && _predictedNextFlashTime > 0) {
                            // ── Chế độ Predictive Pre-light: Dự đoán lần chớp tiếp theo ──
                            // Nếu đang trong cửa sổ ±60ms xung quanh thời điểm dự đoán → chiếu trước ánh sáng
                            // (giải quyết hoàn toàn vấn đề camera bỏ lỡ frame chớp nhanh)
                            double dtToNextFlash = _predictedNextFlashTime - nowSampleTime;
                            if (dtToNextFlash >= -0.06 && dtToNextFlash <= 0.06) {
                                // Đang trong cửa sổ dự đoán → chiếu phản quang nhân tạo với màu của lần chớp trước
                                float predIntensity = (float)_intensity * _predictionConfidence * (float)(1.0 - fabs(dtToNextFlash) / 0.06);
                                effectiveIntensity = predIntensity;
                                // Giữ nguyên màu từ lần chớp thực tế gần nhất
                            } else {
                                // Ngoài cửa sổ → tắt hoàn toàn
                                effectiveIntensity = 0.0f;
                                _smoothedR = _smoothedR * 0.40f + 1.0f * 0.60f;
                                _smoothedG = _smoothedG * 0.40f + 1.0f * 0.60f;
                                _smoothedB = _smoothedB * 0.40f + 1.0f * 0.60f;
                            }
                        } else {
                            // Trạng thái bình thường / chụp ảnh: TẮT HOÀN TOÀN TINT
                            effectiveIntensity = 0.0f;
                            _smoothedR = _smoothedR * 0.40f + 1.0f * 0.60f;
                            _smoothedG = _smoothedG * 0.40f + 1.0f * 0.60f;
                            _smoothedB = _smoothedB * 0.40f + 1.0f * 0.60f;
                        }

                        VCAMFlashState s;
                        s.active = (effectiveIntensity > 0.01f);
                        s.testMode = _isTestMode;
                        s.r = _smoothedR;
                        s.g = _smoothedG;
                        s.b = _smoothedB;
                        s.intensity = effectiveIntensity;
                        [VCAMFlashLivenessManager saveFlashState:s];

                        // Ghi log sự kiện có thay đổi hoặc định kỳ 1.0s vào /var/tmp/vcam_flash.log
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
                                @"[KYC Flash] %@ [voted: %d px, w=%.1f] | Active=%s Inten=%.2f | "
                                 "Sat=%.2f | OutRGB=(%.2f, %.2f, %.2f) | "
                                 "Rhythm: period=%.0fms conf=%.0f%% samples=%d\n",
                                detectedColorName, votedCount, votedWeight,
                                s.active ? "YES" : "NO", effectiveIntensity,
                                saturation, _smoothedR, _smoothedG, _smoothedB,
                                _learnedPeriodSec * 1000.0, _predictionConfidence * 100.0,
                                _rhythmSampleCount];
                            FILE *lf = fopen("/var/tmp/vcam_flash.log", "a");
                            if (lf) {
                                fputs([logMsg UTF8String], lf);
                                fclose(lf);
                                chmod("/var/tmp/vcam_flash.log", 0666);
                            }
                        }
                    }
                }
            } @catch (__unused NSException *ex) {
                capturedSuccess = NO;
            }
        }
    }

    // Cơ chế thông minh dự phòng: Nếu hệ điều hành / app chặn đọc màn hình (> 1.5s liên tiếp)
    if (!capturedSuccess) {
        _consecutiveCaptureFailures++;
        if (_consecutiveCaptureFailures > 15) {
            // Tự động luân chuyển dải màu KYC để đảm bảo luôn có phản quang trên da mặt
            static const float fallbackPalette[6][3] = {
                {1.00f, 1.00f, 1.00f}, // Sáng trắng
                {0.20f, 0.75f, 1.00f}, // Xanh lam
                {1.00f, 0.25f, 0.25f}, // Đỏ
                {0.30f, 0.95f, 0.35f}, // Xanh lục
                {1.00f, 0.90f, 0.20f}, // Vàng
                {0.90f, 0.30f, 0.90f}  // Tím hồng
            };

            static NSTimeInterval lastFallbackCycle = 0;
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            if (now - lastFallbackCycle > 0.45) {
                lastFallbackCycle = now;
                _testColorIndex = (_testColorIndex + 1) % 6;
            }

            float targetR = fallbackPalette[_testColorIndex][0];
            float targetG = fallbackPalette[_testColorIndex][1];
            float targetB = fallbackPalette[_testColorIndex][2];

            _smoothedR = _smoothedR * 0.35f + targetR * 0.65f;
            _smoothedG = _smoothedG * 0.35f + targetG * 0.65f;
            _smoothedB = _smoothedB * 0.35f + targetB * 0.65f;

            VCAMFlashState s;
            s.active = YES;
            s.testMode = YES;
            s.r = _smoothedR;
            s.g = _smoothedG;
            s.b = _smoothedB;
            s.intensity = (float)_intensity;
            [VCAMFlashLivenessManager saveFlashState:s];

            static NSTimeInterval lastWarnLog = 0;
            if (now - lastWarnLog > 2.0) {
                lastWarnLog = now;
                FILE *lf = fopen("/var/tmp/vcam_flash.log", "a");
                if (lf) {
                    fputs("[KYC Flash Dự Phòng] Chụp màn hình bị chặn bảo mật. Đang tự động đảo dải màu KYC chuẩn.\n", lf);
                    fclose(lf);
                    chmod("/var/tmp/vcam_flash.log", 0666);
                }
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
