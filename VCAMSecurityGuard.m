//
//  VCAMSecurityGuard.m
//  VCAM iOS - Multi-Layer Security Guard & Anti-Bypass Engine
//

#import "VCAMSecurityGuard.h"
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#import <unistd.h>

static const char *kVCAMAuthTokenFileName = ".vcam_token";
static const char *kVCamSharedHwidPath    = "/var/mobile/Library/Preferences/.vcam_device_id";

// ── 1. Chuỗi Secret Salt được mã hóa XOR động (Chống hoàn toàn lệnh strings) ──
static const uint8_t kXORSaltData[] = {
    0x00, 0x3E, 0x3D, 0x17, 0x6D, 0x31, 0x20, 0x12, 0x0D, 0x2D, 0x62, 0x08, 0x0C, 0x6F, 0x62, 0x0E,
    0x1C, 0x0B, 0x0E, 0x6D, 0x12, 0x39, 0x6D, 0x10, 0x00, 0x3F, 0x1D, 0x6C, 0x3C, 0x38, 0x1F, 0x34,
    0x62, 0x38, 0x12, 0x2E, 0x3E, 0x1E, 0x3D, 0x68
};
static const size_t kXORSaltLen = sizeof(kXORSaltData);
static const uint8_t kXORKey = 0x5A;

NSString *VCAMGetDecryptedSecretSalt(void) {
    char buf[kXORSaltLen + 1];
    for (size_t i = 0; i < kXORSaltLen; i++) {
        buf[i] = (char)(kXORSaltData[i] ^ kXORKey);
    }
    buf[kXORSaltLen] = '\0';
    return [NSString stringWithUTF8String:buf];
}

#import <dlfcn.h>
#import <sys/sysctl.h>

// ── 2. Lấy định danh phần cứng thực tế đa nguồn (MobileGestalt + IOKit + sysctl) ──

static NSString *VCAMFetchMobileGestalt(CFStringRef prop) {
    void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_GLOBAL | RTLD_LAZY);
    if (!gestalt) return nil;
    
    CFPropertyListRef (*MGCopyAnswer)(CFStringRef) = (CFPropertyListRef (*)(CFStringRef))dlsym(gestalt, "MGCopyAnswer");
    if (!MGCopyAnswer) return nil;
    
    CFPropertyListRef val = MGCopyAnswer(prop);
    if (!val) return nil;
    
    NSString *result = nil;
    if (CFGetTypeID(val) == CFStringGetTypeID()) {
        result = [NSString stringWithString:(__bridge NSString *)val];
    }
    CFRelease(val);
    return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

typedef mach_port_t vcam_io_service_t;
typedef mach_port_t vcam_io_object_t;

static NSString *VCAMFetchIOKit(CFStringRef prop) {
    vcam_io_service_t (*pIOServiceGetMatchingService)(mach_port_t, CFDictionaryRef) = 
        (vcam_io_service_t (*)(mach_port_t, CFDictionaryRef))dlsym(RTLD_DEFAULT, "IOServiceGetMatchingService");
    CFMutableDictionaryRef (*pIOServiceMatching)(const char *) = 
        (CFMutableDictionaryRef (*)(const char *))dlsym(RTLD_DEFAULT, "IOServiceMatching");
    CFTypeRef (*pIORegistryEntryCreateCFProperty)(vcam_io_service_t, CFStringRef, CFAllocatorRef, uint32_t) = 
        (CFTypeRef (*)(vcam_io_service_t, CFStringRef, CFAllocatorRef, uint32_t))dlsym(RTLD_DEFAULT, "IORegistryEntryCreateCFProperty");
    kern_return_t (*pIOObjectRelease)(vcam_io_object_t) = 
        (kern_return_t (*)(vcam_io_object_t))dlsym(RTLD_DEFAULT, "IOObjectRelease");
        
    if (!pIOServiceGetMatchingService || !pIOServiceMatching || !pIORegistryEntryCreateCFProperty || !pIOObjectRelease) {
        return nil;
    }
    
    CFMutableDictionaryRef matching = pIOServiceMatching("IOPlatformExpertDevice");
    if (!matching) return nil;
    
    vcam_io_service_t service = pIOServiceGetMatchingService(0, matching);
    if (!service) return nil;
    
    CFTypeRef propVal = pIORegistryEntryCreateCFProperty(service, prop, kCFAllocatorDefault, 0);
    pIOObjectRelease(service);
    if (!propVal) return nil;
    
    NSString *result = nil;
    if (CFGetTypeID(propVal) == CFStringGetTypeID()) {
        result = [NSString stringWithString:(__bridge NSString *)propVal];
    } else if (CFGetTypeID(propVal) == CFDataGetTypeID()) {
        NSData *data = (__bridge NSData *)propVal;
        result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!result) {
            const unsigned char *bytes = (const unsigned char *)[data bytes];
            NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
            for (NSUInteger i = 0; i < data.length; i++) {
                [hex appendFormat:@"%02x", bytes[i]];
            }
            result = hex;
        }
    }
    CFRelease(propVal);
    return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *VCAMFetchSysctl(const char *name) {
    size_t size = 0;
    if (sysctlbyname(name, NULL, &size, NULL, 0) != 0 || size == 0) return @"";
    char *buf = malloc(size);
    if (!buf) return @"";
    if (sysctlbyname(name, buf, &size, NULL, 0) == 0) {
        NSString *val = [NSString stringWithUTF8String:buf];
        free(buf);
        return [val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    }
    free(buf);
    return @"";
}

NSString *VCAMGetSharedDeviceHWID(void) {
    static NSString *sCachedHWID = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 1. Quét phần cứng từ MobileGestalt
        NSString *mgSerial = VCAMFetchMobileGestalt(CFSTR("SerialNumber"));
        NSString *mgUdid   = VCAMFetchMobileGestalt(CFSTR("UniqueDeviceID"));

        // 2. Quét phần cứng từ IOKit (IOPlatformExpertDevice)
        NSString *ioSerial = VCAMFetchIOKit(CFSTR("IOPlatformSerialNumber"));
        NSString *ioUUID   = VCAMFetchIOKit(CFSTR("IOPlatformUUID"));

        // 3. Quét thông số vi xử lý & model từ Kernel sysctl
        NSString *hwModel   = VCAMFetchSysctl("hw.model");    // vd: D20AP
        NSString *hwMachine = VCAMFetchSysctl("hw.machine");  // vd: iPhone10,1

        // Chọn mã Serial ưu tiên
        NSString *finalSerial = (mgSerial.length >= 6) ? mgSerial : ((ioSerial.length >= 6) ? ioSerial : @"");
        // Chọn mã UUID/UDID ưu tiên
        NSString *finalUUID   = (ioUUID.length >= 16) ? ioUUID : ((mgUdid.length >= 16) ? mgUdid : @"");

        NSString *hwSeed = nil;
        if (finalSerial.length > 0 || finalUUID.length > 0) {
            // Ghép nối định danh phần cứng thực tế với Salt bí mật (bất biến 100% trên chiếc iPhone này)
            hwSeed = [NSString stringWithFormat:@"VCAM-HW-%@-%@-%@-%@-%@",
                      finalSerial ?: @"NOSER",
                      finalUUID ?: @"NOUUID",
                      hwModel ?: @"NOMODEL",
                      hwMachine ?: @"NOMACH",
                      VCAMGetDecryptedSecretSalt()];
        } else {
            // Fallback nếu sandbox app bên thứ 3 chặn cả Gestalt & IOKit: Đọc file cache đã ghi từ SpringBoard/mediaserverd
            NSString *path = [NSString stringWithUTF8String:kVCamSharedHwidPath];
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                NSString *saved = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
                saved = [saved stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (saved.length >= 16) {
                    sCachedHWID = [saved copy];
                    return;
                }
            }
            hwSeed = [NSString stringWithFormat:@"VCAM-STATIC-%@-%@-%@", hwModel, hwMachine, VCAMGetDecryptedSecretSalt()];
        }

        // Băm SHA-256 chuỗi phần cứng để tạo mã HWID 64 ký tự chuẩn hóa
        const char *s = [hwSeed UTF8String];
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(s, (CC_LONG)strlen(s), digest);
        NSMutableString *hwidStr = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
            [hwidStr appendFormat:@"%02x", digest[i]];
        }
        sCachedHWID = [hwidStr copy];

        // Lưu file cache với quyền 0666 để chia sẻ giữa các tiến trình
        NSString *path = [NSString stringWithUTF8String:kVCamSharedHwidPath];
        [sCachedHWID writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod(kVCamSharedHwidPath, 0666);
    });

    return sCachedHWID ?: @"";
}

// ── 3. Danh sách thư mục tmp khả dụng ──
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

// ── 4. Kiểm tra tính toàn vẹn nhị phân ARM64 trong RAM (Anti-Binary-Patching) ──
BOOL VCAMCheckBinaryIntegrity(void) {
    uint32_t *fnPtr = (uint32_t *)&VCAMVerifyProcessAuthorization;
    if (fnPtr) {
        uint32_t insn = *fnPtr;
        // 0x52800020 = mov w0, #1
        // 0xD65F03C0 = ret
        if (insn == 0x52800020 || insn == 0xD65F03C0) {
            NSLog(@"[VCAMSecurity] CẢNH BÁO: Phát hiện hàm bị can thiệp nhị phân! Tự động từ chối.");
            return NO;
        }
    }
    return YES;
}

// ── 5. Hàm C xác thực bản quyền trực tiếp (chạy ở cả mediaserverd và SpringBoard) ──
BOOL VCAMVerifyProcessAuthorization(void) {
    // Kiểm tra tính toàn vẹn nhị phân trước
    if (!VCAMCheckBinaryIntegrity()) {
        return NO;
    }

    // Cache RAM 3.0s khi hợp lệ, 0.5s khi chưa hợp lệ để triệt tiêu tải CPU/HMAC trên luồng camera
    static BOOL sCachedValid = NO;
    static NSTimeInterval sLastCheck = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval cacheInterval = sCachedValid ? 3.0 : 0.5;
    if (now - sLastCheck < cacheInterval) {
        return sCachedValid;
    }
    sLastCheck = now;

    // Tìm file token ủy quyền (cache đường dẫn)
    static NSString *tokenPath = nil;
    static dispatch_once_t tokenOnce;
    dispatch_once(&tokenOnce, ^{
        for (NSString *dir in PossibleTmpDirs()) {
            NSString *p = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMAuthTokenFileName]];
            if (access([p UTF8String], F_OK) == 0) {
                tokenPath = p;
                break;
            }
        }
        if (!tokenPath) {
            tokenPath = [@"/var/tmp" stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMAuthTokenFileName]];
        }
    });

    if (!tokenPath || access([tokenPath UTF8String], F_OK) != 0) {
        sCachedValid = NO;
        return NO;
    }

    NSString *content = [NSString stringWithContentsOfFile:tokenPath encoding:NSUTF8StringEncoding error:nil];
    if (!content || content.length == 0) {
        sCachedValid = NO;
        return NO;
    }

    NSArray *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    if (lines.count < 5) {
        sCachedValid = NO;
        return NO;
    }

    NSString *key = lines[0];
    NSString *tokenHwid = lines[1];
    double expiresAt = [lines[2] doubleValue];
    double issuedAt = [lines[3] doubleValue];
    NSString *sig = lines[4];

    // Xác thực HWID trùng khớp máy hiện tại
    NSString *currentHwid = VCAMGetSharedDeviceHWID();
    if (currentHwid.length >= 16 && tokenHwid.length >= 16) {
        if (![currentHwid isEqualToString:tokenHwid]) {
            NSLog(@"[VCAMSecurity] LỖI: Token bị copy từ máy khác (HWID không khớp)!");
            sCachedValid = NO;
            return NO;
        }
    }

    // Xác thực thời hạn sử dụng
    NSTimeInterval wallNow = [[NSDate date] timeIntervalSince1970];
    if (expiresAt > 0 && wallNow > (expiresAt / 1000.0)) {
        sCachedValid = NO;
        return NO;
    }

    // Chống lùi/sai lệch giờ (+300s dung sai)
    if (issuedAt > wallNow + 300.0) {
        sCachedValid = NO;
        return NO;
    }

    // Tính toán và kiểm tra chữ ký số HMAC-SHA256 với Secret Salt đã giải mã
    NSString *payload = [NSString stringWithFormat:@"%@|%@|%.0f|%.0f", key, tokenHwid, expiresAt, issuedAt];
    NSString *salt = VCAMGetDecryptedSecretSalt();
    const char *cKey = [salt cStringUsingEncoding:NSUTF8StringEncoding];
    const char *cData = [payload cStringUsingEncoding:NSUTF8StringEncoding];

    unsigned char cHMAC[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, cKey, strlen(cKey), cData, strlen(cData), cHMAC);
    NSMutableString *expectedSig = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [expectedSig appendFormat:@"%02x", cHMAC[i]];
    }

    if (![expectedSig isEqualToString:sig]) {
        NSLog(@"[VCAMSecurity] LỖI: Chữ ký số token không hợp lệ (Dấu hiệu giả mạo)!");
        sCachedValid = NO;
        return NO;
    }

    sCachedValid = YES;
    return YES;
}

@implementation VCAMSecurityGuard

+ (instancetype)sharedGuard {
    static VCAMSecurityGuard *guard = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        guard = [[VCAMSecurityGuard alloc] init];
    });
    return guard;
}

+ (void)issueAuthorizationTokenWithKey:(NSString *)key expiresAt:(NSTimeInterval)expiresAt hwid:(NSString *)hwid {
    if (!key || key.length == 0 || !hwid || hwid.length == 0) return;
    NSTimeInterval issuedAt = [[NSDate date] timeIntervalSince1970];

    NSString *payload = [NSString stringWithFormat:@"%@|%@|%.0f|%.0f", key, hwid, expiresAt, issuedAt];
    NSString *salt = VCAMGetDecryptedSecretSalt();
    const char *cKey = [salt cStringUsingEncoding:NSUTF8StringEncoding];
    const char *cData = [payload cStringUsingEncoding:NSUTF8StringEncoding];

    unsigned char cHMAC[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, cKey, strlen(cKey), cData, strlen(cData), cHMAC);
    NSMutableString *sigStr = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [sigStr appendFormat:@"%02x", cHMAC[i]];
    }

    NSString *content = [NSString stringWithFormat:@"%@\n%@\n%.0f\n%.0f\n%@\n", key, hwid, expiresAt, issuedAt, sigStr];
    for (NSString *dir in PossibleTmpDirs()) {
        NSString *p = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMAuthTokenFileName]];
        [content writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod([p UTF8String], 0666);
    }
    NSLog(@"[VCAMSecurity] Đã cấp phát token chữ ký số bản quyền mới.");
}

+ (void)revokeAuthorizationToken {
    for (NSString *dir in PossibleTmpDirs()) {
        NSString *p = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMAuthTokenFileName]];
        unlink([p UTF8String]);
    }
    NSLog(@"[VCAMSecurity] Đã thu hồi toàn bộ token bản quyền.");
}

- (BOOL)isTokenValid {
    return VCAMVerifyProcessAuthorization();
}

@end

