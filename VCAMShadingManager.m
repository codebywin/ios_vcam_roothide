//
//  VCAMShadingManager.m
//  VCAM iOS - 3D Volumetric Face Shading & Camera Sensor Noise Engine
//

#import "VCAMShadingManager.h"
#import <sys/stat.h>
#import <unistd.h>

static const char *kVCAMShadingStateFileName = "vcam_shading_state";

static NSArray<NSString *> *ShadingPossibleDirs(void) {
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

static NSString *FindExistingShadingStatePath(void) {
    static NSString *cachedPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (NSString *dir in ShadingPossibleDirs()) {
            NSString *p = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMShadingStateFileName]];
            if (access([p UTF8String], F_OK) == 0) {
                cachedPath = p;
                break;
            }
        }
        if (!cachedPath) {
            for (NSString *dir in ShadingPossibleDirs()) {
                if ([[NSFileManager defaultManager] fileExistsAtPath:dir]) {
                    cachedPath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMShadingStateFileName]];
                    break;
                }
            }
        }
        if (!cachedPath) {
            cachedPath = [@"/var/tmp" stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMShadingStateFileName]];
        }
    });
    return cachedPath;
}

@interface VCAMShadingManager () {
    BOOL _shadingEnabled;
    BOOL _grainEnabled;
    CGFloat _shadingIntensity;
    CGFloat _grainIntensity;
    CGFloat _lightX;   // 0.0-1.0, vị trí chùm sáng trục X
    CGFloat _lightY;   // 0.0-1.0, vị trí chùm sáng trục Y
}
@end

@implementation VCAMShadingManager

+ (instancetype)sharedManager {
    static VCAMShadingManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCAMShadingManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        VCAMShadingState s = [VCAMShadingManager currentShadingState];
        _shadingEnabled = s.shadingEnabled;
        _grainEnabled = s.grainEnabled;
        _shadingIntensity = s.shadingIntensity;
        _grainIntensity = s.grainIntensity;
        _lightX = (s.lightX > 0.0f && s.lightX < 1.0f) ? s.lightX : 0.50f;
        _lightY = (s.lightY > 0.0f && s.lightY < 1.0f) ? s.lightY : 0.46f;
    }
    return self;
}

#pragma mark - Properties

- (BOOL)isShadingEnabled {
    return _shadingEnabled;
}

- (void)setShadingEnabled:(BOOL)shadingEnabled {
    _shadingEnabled = shadingEnabled;
    [self _persistState];
}

- (BOOL)isGrainEnabled {
    return _grainEnabled;
}

- (void)setGrainEnabled:(BOOL)grainEnabled {
    _grainEnabled = grainEnabled;
    [self _persistState];
}

- (CGFloat)shadingIntensity {
    return _shadingIntensity;
}

- (void)setShadingIntensity:(CGFloat)shadingIntensity {
    if (shadingIntensity < 0.05f) shadingIntensity = 0.05f;
    if (shadingIntensity > 1.0f) shadingIntensity = 1.0f;
    _shadingIntensity = shadingIntensity;
    [self _persistState];
}

- (CGFloat)grainIntensity {
    return _grainIntensity;
}

- (void)setGrainIntensity:(CGFloat)grainIntensity {
    if (grainIntensity < 0.02f) grainIntensity = 0.02f;
    if (grainIntensity > 0.80f) grainIntensity = 0.80f;
    _grainIntensity = grainIntensity;
    [self _persistState];
}

- (CGFloat)lightX {
    return _lightX;
}

- (CGFloat)lightY {
    return _lightY;
}

- (void)setLightPositionX:(CGFloat)x y:(CGFloat)y {
    _lightX = MAX(0.01f, MIN(0.99f, x));
    _lightY = MAX(0.01f, MIN(0.99f, y));
    [self _persistState];
}

- (void)_persistState {
    VCAMShadingState s;
    s.shadingEnabled = _shadingEnabled;
    s.grainEnabled = _grainEnabled;
    s.shadingIntensity = (float)_shadingIntensity;
    s.grainIntensity = (float)_grainIntensity;
    s.lightX = (float)(_lightX > 0.0f ? _lightX : 0.50f);
    s.lightY = (float)(_lightY > 0.0f ? _lightY : 0.46f);
    [VCAMShadingManager saveShadingState:s];
}

#pragma mark - Shared State IPC

+ (VCAMShadingState)currentShadingState {
    static VCAMShadingState cachedState = {YES, YES, 0.45f, 0.28f, 0.50f, 0.46f};
    static NSTimeInterval lastReadTime = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    // Tối ưu cache 50ms: Giúp phản hồi cực nhạy tức thì khi bấm D-pad điều khiển đèn
    if (now - lastReadTime < 0.05) {
        return cachedState;
    }
    lastReadTime = now;

    NSString *path = FindExistingShadingStatePath();
    FILE *f = fopen([path UTF8String], "r");
    if (f) {
        int sEn = 1, gEn = 1;
        float sInt = 0.45f, gInt = 0.28f, lx = 0.50f, ly = 0.46f;
        int n = fscanf(f, "%d %d %f %f %f %f", &sEn, &gEn, &sInt, &gInt, &lx, &ly);
        if (n >= 2) {
            cachedState.shadingEnabled = (sEn != 0);
            cachedState.grainEnabled = (gEn != 0);
            cachedState.shadingIntensity = (sInt > 0.01f) ? sInt : 0.45f;
            cachedState.grainIntensity = (gInt > 0.01f) ? gInt : 0.28f;
            // lightX/lightY: chỉ cập nhật nếu file có đủ 6 giá trị (backward compat)
            if (n >= 6) {
                cachedState.lightX = (lx > 0.0f && lx < 1.0f) ? lx : 0.50f;
                cachedState.lightY = (ly > 0.0f && ly < 1.0f) ? ly : 0.46f;
            }
        }
        fclose(f);
    }
    return cachedState;
}

+ (void)saveShadingState:(VCAMShadingState)state {
    char buf[128];
    snprintf(buf, sizeof(buf), "%d %d %.2f %.2f %.3f %.3f\n",
             state.shadingEnabled ? 1 : 0,
             state.grainEnabled ? 1 : 0,
             state.shadingIntensity,
             state.grainIntensity,
             state.lightX,
             state.lightY);

    for (NSString *dir in ShadingPossibleDirs()) {
        NSString *filePath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMShadingStateFileName]];
        FILE *f = fopen([filePath UTF8String], "w");
        if (f) {
            fputs(buf, f);
            fclose(f);
            chmod([filePath UTF8String], 0666);
        }
    }
}

#pragma mark - CoreImage Metal Processing Pipeline

+ (CIImage *)apply3DShadingAndGrainToImage:(CIImage *)image
                                     size:(CGSize)size
                                    state:(VCAMShadingState)state {
    if (!image || size.width <= 0 || size.height <= 0) return image;
    if (!state.shadingEnabled && !state.grainEnabled) return image;

    CIImage *currentImage = image;

    // === DIAGNOSTIC LOG: Bật define VCAM_ENABLE_SHADING_LOG 1 bên dưới nếu cần ghi log liên tục ===
#define VCAM_ENABLE_SHADING_LOG 0
#if VCAM_ENABLE_SHADING_LOG
    static NSTimeInterval lastLog = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - lastLog > 2.0) {
        lastLog = now;
        const char *logPaths[] = {
            "/rootfs/private/var/tmp/vcam_shading.log",
            "/var/tmp/vcam_shading.log",
            "/private/var/tmp/vcam_shading.log",
            "/var/mobile/vcam_shading.log",
            NULL
        };
        for (int pi = 0; logPaths[pi]; pi++) {
            FILE *f = fopen(logPaths[pi], "a");
            if (f) {
                fprintf(f, "[Shading] CALLED Shading=%d (%.2f) Grain=%d (%.2f) Size=%.0fx%.0f\n",
                        state.shadingEnabled, state.shadingIntensity,
                        state.grainEnabled, state.grainIntensity,
                        size.width, size.height);
                fclose(f);
                chmod(logPaths[pi], 0666);
                break;
            }
        }
    }
#endif


    // ──────────────────────────────────────────────────────────────────────────
    // 1. ĐÈN PIN CHIẾU VÀO MẶT (True Flashlight / Torch Beam)
    //    - Điểm sáng chói cực nhỏ ở tâm, rìa chuyển tối sắc nét
    //    - Ngoài rìa chùm đèn tối sâu như đang soi đèn pin trong phòng tối
    // ──────────────────────────────────────────────────────────────────────────
    if (state.shadingEnabled && state.shadingIntensity > 0.02f) {
        @try {
            float intensity = state.shadingIntensity;
            // Tọa độ chùm sáng từ state (do người dùng kéo), mặc định giữa mặt nếu chưa set
            CGFloat centerX = (state.lightX > 0.01f) ? state.lightX * size.width  : size.width  * 0.50f;
            CGFloat centerY = (state.lightY > 0.01f) ? state.lightY * size.height : size.height * 0.46f;
            CGFloat baseR   = MIN(size.width, size.height);

            // ── LỚP 1: Chùm đèn pin chói sáng (Flashlight Hot Beam) ──
            // Lõi sáng chói trắng ấm — chỉ chiếu trúng khuôn mặt
            {
                CIColor *lightCore   = [CIColor colorWithRed:1.0f green:0.99f blue:0.92f
                                                       alpha:intensity * 0.78f]; // Rất chói ở tâm
                CIColor *lightEdge   = [CIColor colorWithRed:0.0f green:0.0f blue:0.0f alpha:0.0f];

                CIFilter *lightGrad = [CIFilter filterWithName:@"CIRadialGradient"];
                [lightGrad setValue:[CIVector vectorWithX:centerX Y:centerY] forKey:@"inputCenter"];
                [lightGrad setValue:@(baseR * 0.03f) forKey:@"inputRadius0"]; // Hot spot điểm cực nhỏ
                [lightGrad setValue:@(baseR * 0.22f) forKey:@"inputRadius1"]; // Chùm đèn nhỏ lại
                [lightGrad setValue:lightCore  forKey:@"inputColor0"];
                [lightGrad setValue:lightEdge  forKey:@"inputColor1"];

                CIImage *lightImg = lightGrad.outputImage;
                if (lightImg) {
                    // Elip dọc 1:1.25 theo khuôn mặt oval
                    CGAffineTransform t = CGAffineTransformIdentity;
                    t = CGAffineTransformTranslate(t, centerX, centerY);
                    t = CGAffineTransformScale(t, 1.0f, 1.25f);
                    t = CGAffineTransformTranslate(t, -centerX, -centerY);
                    lightImg = [lightImg imageByApplyingTransform:t];
                    lightImg = [lightImg imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];

                    CIFilter *screenBlend = [CIFilter filterWithName:@"CIScreenBlendMode"];
                    [screenBlend setValue:lightImg     forKey:kCIInputImageKey];
                    [screenBlend setValue:currentImage forKey:kCIInputBackgroundImageKey];
                    CIImage *lit = screenBlend.outputImage;
                    if (lit) currentImage = lit;
                }
            }

            // ── LỚP 2: Bóng tối sâu ngoài chùm đèn (Deep Torch Falloff Shadow) ──
            // Background và rìa ngoài tối mạnh — rõ ràng vùng bị chiếu và không bị chiếu
            {
                CIColor *shadowCenter = [CIColor colorWithRed:0.0f green:0.0f blue:0.0f alpha:0.0f];
                CIColor *shadowEdge   = [CIColor colorWithRed:0.0f green:0.0f blue:0.0f
                                                        alpha:intensity * 0.62f]; // Tối sâu ngoài rìa

                CIFilter *shadowGrad = [CIFilter filterWithName:@"CIRadialGradient"];
                [shadowGrad setValue:[CIVector vectorWithX:centerX Y:centerY] forKey:@"inputCenter"];
                [shadowGrad setValue:@(baseR * 0.14f) forKey:@"inputRadius0"]; // Trong chùm sáng không tối
                [shadowGrad setValue:@(baseR * 0.42f) forKey:@"inputRadius1"]; // Bóng tối bắt đầu từ rìa chùm đèn
                [shadowGrad setValue:shadowCenter forKey:@"inputColor0"];
                [shadowGrad setValue:shadowEdge   forKey:@"inputColor1"];

                CIImage *shadowImg = shadowGrad.outputImage;
                if (shadowImg) {
                    CGAffineTransform t = CGAffineTransformIdentity;
                    t = CGAffineTransformTranslate(t, centerX, centerY);
                    t = CGAffineTransformScale(t, 1.0f, 1.25f);
                    t = CGAffineTransformTranslate(t, -centerX, -centerY);
                    shadowImg = [shadowImg imageByApplyingTransform:t];
                    shadowImg = [shadowImg imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];

                    CIFilter *overBlend = [CIFilter filterWithName:@"CISourceOverCompositing"];
                    [overBlend setValue:shadowImg   forKey:kCIInputImageKey];
                    [overBlend setValue:currentImage forKey:kCIInputBackgroundImageKey];
                    CIImage *shaded = overBlend.outputImage;
                    if (shaded) currentImage = shaded;
                }
            }
        } @catch (__unused NSException *ex) {}
    }

    // ──────────────────────────────────────────────────────────────────────────
    // 2. HẠT NHIỄU CẢM BIẾN LI TI THƯA (Sparse 1px CMOS Sensor Grain)
    // ──────────────────────────────────────────────────────────────────────────
    if (state.grainEnabled && state.grainIntensity > 0.02f) {
        @try {
            float intensity = state.grainIntensity;

            // Texture nhiễu hạt 256x256 rải hạt rất thưa (chỉ ~3.5% pixel có hạt)
            static NSData  *sNoiseData     = nil;
            static CIImage *sBaseNoiseTile = nil;
            static dispatch_once_t sNoiseOnce;
            dispatch_once(&sNoiseOnce, ^{
                const int w = 256, h = 256;
                uint8_t *bytes = (uint8_t *)malloc(w * h * 4);
                if (bytes) {
                    uint32_t seed = 0x1337cafe;
                    for (int i = 0; i < w * h; i++) {
                        seed = seed * 1664525u + 1013904223u;
                        uint32_t r = seed >> 16;
                        uint8_t byteVal = 128; // Mặc định 128: trung tính tuyệt đối (không làm mờ/ảnh hưởng ảnh gốc)

                        // Giảm số hạt lại, rải thưa ~3.5% pixel xuất hiện đốm li ti
                        if ((r % 1000) < 35) {
                            if ((r & 1) == 0) {
                                // Hạt sáng li ti (specular highlight / hot pixel)
                                byteVal = (uint8_t)(128 + 40 + ((r >> 8) % 65)); // 168..233
                            } else {
                                // Hạt tối li ti
                                byteVal = (uint8_t)(128 - 30 - ((r >> 8) % 40)); // 58..98
                            }
                        }

                        bytes[i*4+0] = byteVal;
                        bytes[i*4+1] = byteVal;
                        bytes[i*4+2] = byteVal;
                        bytes[i*4+3] = 255;
                    }
                    sNoiseData = [NSData dataWithBytesNoCopy:bytes length:w*h*4 freeWhenDone:YES];
                    CIImage *rawNoise = [CIImage imageWithBitmapData:sNoiseData
                                                         bytesPerRow:w * 4
                                                                size:CGSizeMake(w, h)
                                                              format:kCIFormatRGBA8
                                                          colorSpace:nil];
                    // Dùng CIAffineTile để lặp texture 256x256 trải đều toàn màn hình
                    CIFilter *tileFilter = [CIFilter filterWithName:@"CIAffineTile"];
                    [tileFilter setValue:rawNoise forKey:kCIInputImageKey];
                    sBaseNoiseTile = tileFilter.outputImage;
                }
            });

            if (sBaseNoiseTile) {
                // Điều chỉnh độ rõ nét của hạt nhiễu theo slider intensity
                CIFilter *contrastFilter = [CIFilter filterWithName:@"CIColorControls"];
                [contrastFilter setValue:sBaseNoiseTile forKey:kCIInputImageKey];
                [contrastFilter setValue:@(0.0f) forKey:@"inputBrightness"];
                [contrastFilter setValue:@(0.30f + intensity * 1.05f) forKey:@"inputContrast"];
                CIImage *tunedNoise = contrastFilter.outputImage;

                if (tunedNoise) {
                    // Dịch chuyển ngẫu nhiên mỗi frame để hạt nhiễu động chân thực
                    static uint32_t sFrameSeed = 0;
                    sFrameSeed = (sFrameSeed + 97) % 100000;
                    CGFloat dx = (CGFloat)(sFrameSeed % 251);
                    CGFloat dy = (CGFloat)((sFrameSeed * 23) % 251);

                    CIImage *jitteredNoise = [tunedNoise imageByApplyingTransform:CGAffineTransformMakeTranslation(dx, dy)];
                    jitteredNoise = [jitteredNoise imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];

                    // Soft Light blend: pixel 128 giữ nguyên ảnh gốc, đốm sáng/tối tạo hạt li ti thưa
                    CIFilter *grainBlend = [CIFilter filterWithName:@"CISoftLightBlendMode"];
                    [grainBlend setValue:jitteredNoise forKey:kCIInputImageKey];
                    [grainBlend setValue:currentImage forKey:kCIInputBackgroundImageKey];
                    CIImage *grained = grainBlend.outputImage;
                    if (grained) currentImage = grained;
                }
            }
        } @catch (__unused NSException *ex) {}
    }


    return currentImage;
}

@end

