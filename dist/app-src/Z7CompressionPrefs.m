#import "Z7CompressionPrefs.h"

#include <stdlib.h>   // labs，供 TickForLevel 使用

NSString * const kZ7OptFormatKey      = @"Z7OptFormat";
NSString * const kZ7OptLevelKey       = @"Z7OptLevelTick";
NSString * const kZ7OptMethodKey      = @"Z7OptMethod";
NSString * const kZ7OptDictKey        = @"Z7OptDict";
NSString * const kZ7OptWordKey        = @"Z7OptWordLength";
NSString * const kZ7OptFastBytesKey   = @"Z7OptFastBytes";
NSString * const kZ7OptMatchKey       = @"Z7OptMatchFinder";
NSString * const kZ7OptSolidKey       = @"Z7OptSolid";
NSString * const kZ7OptSolidBlockKey  = @"Z7OptSolidBlock";
NSString * const kZ7OptAutoThreadsKey = @"Z7OptAutoThreads";
NSString * const kZ7OptThreadsKey     = @"Z7OptThreads";
NSString * const kZ7OptVolumeKey      = @"Z7OptVolume";
NSString * const kZ7OptEncMethKey     = @"Z7OptEncryptMethod";
NSString * const kZ7OptEncHeaderKey   = @"Z7OptEncryptHeader";
NSString * const kZ7OptCompHeaderKey  = @"Z7OptCompressHeader";
NSString * const kZ7OptFullPathsKey   = @"Z7OptFullPaths";
NSString * const kZ7OptExcludeJunkKey = @"Z7OptExcludeMacJunk";
NSString * const kZ7OptVerifyKey      = @"Z7OptVerifyAfter";
NSString * const kZ7OptSeparateKey    = @"Z7OptSeparate";
NSString * const kZ7OptUpdateModeKey  = @"Z7OptUpdateMode";
NSString * const kZ7OptAdvancedKey    = @"Z7OptAdvancedExpanded";

// 刻意**不**在这里的两项（不是遗漏，改之前请先读 main.m 里 saveCompressionOptions
// 末尾那段说明）：
//   * 密码 —— 明文口令落 plist 是安全缺陷；需要记住密码的场景走钥匙串。
//   * 「压缩完成后删除源文件」 —— 不可逆的破坏性开关，每次重新勾选更安全。
// objc-test 有一条断言盯住「默认值字典里不含任何 password 相关键」，防止日后顺手加进来。

const NSInteger kZ7LevelTickValues[6] = {0, 1, 3, 5, 7, 9};

NSInteger LevelForTick(NSInteger tick)
{
    if (tick < 0) tick = 0;
    if (tick > 5) tick = 5;
    return kZ7LevelTickValues[tick];
}

NSInteger TickForLevel(NSInteger level)
{
    NSInteger best = 3, bestDelta = 99;
    for (NSInteger i = 0; i < 6; i++) {
        NSInteger d = labs(kZ7LevelTickValues[i] - level);
        if (d < bestDelta) { bestDelta = d; best = i; }
    }
    return best;
}

NSString *LevelNameForTick(NSInteger tick)
{
    switch (tick) {
        case 0: return @"存储";
        case 1: return @"快速";
        case 2: return @"较快";
        case 3: return @"正常";
        case 4: return @"较好";
        default: return @"慢速";
    }
}

NSDictionary *Z7CompressionPrefsDefaults(void)
{
    static NSDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = @{
            kZ7OptFormatKey:      @"7z",
            kZ7OptLevelKey:       @(TickForLevel(5)),   // 出厂档位 = 控件初值「正常」
            kZ7OptMethodKey:      @"自动",
            kZ7OptDictKey:        @"自动",
            kZ7OptWordKey:        @"自动",
            kZ7OptFastBytesKey:   @"",
            kZ7OptMatchKey:       @"自动",
            kZ7OptSolidKey:       @YES,
            kZ7OptSolidBlockKey:  @"分块不限",
            kZ7OptAutoThreadsKey: @YES,
            kZ7OptThreadsKey:     @"",
            kZ7OptVolumeKey:      @"",
            kZ7OptEncMethKey:     @"AES256",
            kZ7OptEncHeaderKey:   @YES,
            kZ7OptCompHeaderKey:  @YES,
            kZ7OptFullPathsKey:   @NO,
            kZ7OptExcludeJunkKey: @YES,
            kZ7OptVerifyKey:      @NO,
            kZ7OptSeparateKey:    @NO,
            kZ7OptUpdateModeKey:  @"跳过同名",
            kZ7OptAdvancedKey:    @NO,
        };
    });
    return d;
}
