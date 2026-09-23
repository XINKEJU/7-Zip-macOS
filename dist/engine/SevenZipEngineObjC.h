// SevenZipEngineObjC.h
//
// 7-Zip 引擎内嵌桥接层 —— Objective-C 适配层（技术方案 §4.2「桥接层」）
//
// 定位：
//   C++ 桥接层（SevenZipEngine.{h,cpp}）只暴露 z7:: 命名空间下的纯 C++ 类型；
//   本层把它翻译成 Foundation 值类型（NSString / NSDate / NSArray / NSError），
//   使表现层（AppKit）无需接触任何 C++ 符号。
//
// 线程约定：
//   * 所有方法同步执行，并且可能长时间阻塞 —— 调用方必须放到后台线程
//     （技术方案 §7.1「主线程红线」）。
//   * 同一个 Z7Archive 实例不得被多个线程并发调用；requestCancel 除外，
//     它可以从任意线程调用。
//   * 回调（Z7Callback）在引擎内部线程上被调用，实现方不得在其中做 UI 操作，
//     必须自行派发回主线程并节流。
//
// 许可：本项目整体以 LGPL-2.1-or-later 分发；本文件源自 7-Zip 移植工作。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 日志级别

typedef NS_ENUM(NSInteger, Z7LogLevel) {
    Z7LogLevelInfo = 0,
    Z7LogLevelWarning = 1,
    Z7LogLevelError = 2,
};

#pragma mark - 进度

/// 一次进度回调的快照。`fraction` 在总量未知时为 -1。
@interface Z7Progress : NSObject
@property (nonatomic, readonly) unsigned long long completed;
@property (nonatomic, readonly) unsigned long long total;
@property (nonatomic, readonly) uint32_t itemIndex;
@property (nonatomic, readonly, copy) NSString *itemPath;
@property (nonatomic, readonly) double fraction;
@end

#pragma mark - 条目

/// 归档内单个条目（技术方案 §6.2 数据模型的值类型版本）。
@interface Z7Item : NSObject

@property (nonatomic, readonly) uint32_t index;          // 引擎内条目索引
@property (nonatomic, readonly, copy) NSString *path;     // 归档内完整路径（'/' 分隔）
@property (nonatomic, readonly, copy) NSString *name;     // 末段名称
@property (nonatomic, readonly, copy) NSString *parentPath; // 父目录路径，根级为 @""
@property (nonatomic, readonly) NSInteger depth;          // 层级深度，根级 0

@property (nonatomic, readonly) BOOL isDirectory;
@property (nonatomic, readonly) BOOL isAnti;
@property (nonatomic, readonly) BOOL isSymLink;
@property (nonatomic, readonly, copy) NSString *linkTarget; // 符号链接目标，非链接为 @""

@property (nonatomic, readonly) BOOL hasSize;
@property (nonatomic, readonly) unsigned long long size;
@property (nonatomic, readonly) BOOL hasPackedSize;
@property (nonatomic, readonly) unsigned long long packedSize;

@property (nonatomic, readonly, nullable) NSDate *modificationDate;
@property (nonatomic, readonly, nullable) NSDate *creationDate;

@property (nonatomic, readonly) BOOL hasAttributes;
@property (nonatomic, readonly) uint32_t attributes;
/// 权限串，如 "rw-r--r--"（仅权限位）
@property (nonatomic, readonly, copy) NSString *permissionText;
/// ls -l 风格，如 "-rw-r--r--" / "drwxr-xr-x" / "lrwxrwxrwx"
@property (nonatomic, readonly, copy) NSString *attributeText;

@property (nonatomic, readonly) BOOL hasCRC;
@property (nonatomic, readonly) uint32_t crc;
@property (nonatomic, readonly, copy) NSString *crcText; // 8 位大写十六进制，未知为 @""

@property (nonatomic, readonly) BOOL encrypted;
@property (nonatomic, readonly, copy) NSString *method; // 压缩方法链，未压缩为 @""

/// 压缩率（压缩后 / 原始 × 100）。无法计算时为 -1。
@property (nonatomic, readonly) double compressionRatio;

/// 用于 NSOutlineView 的显示名（目录/链接带后缀提示）
@property (nonatomic, readonly, copy) NSString *displayName;

@end

#pragma mark - 统计

/// 一次解压/校验的统计（技术方案 §8.2：不安全条目必须可见、可上报）。
@interface Z7ExtractStats : NSObject
@property (nonatomic, readonly) unsigned long long errors;
@property (nonatomic, readonly) unsigned long long wrongPassword;
@property (nonatomic, readonly) unsigned long long unsafeEntries;
@property (nonatomic, readonly) unsigned long long skipped;
@property (nonatomic, readonly) unsigned long long symLinks;
@property (nonatomic, readonly) unsigned long long bytes;
@end

#pragma mark - 回调

@protocol Z7Callback <NSObject>
@optional
/// 引擎内部线程调用。实现方必须自行节流并派发主线程。
- (void)engineProgress:(Z7Progress *)progress;
/// 返回 YES 请求中止。会被高频调用，必须廉价且线程安全。
- (BOOL)engineIsCanceled;
/// retry == YES 表示上一次提供的密码被拒绝。
- (nullable NSString *)enginePasswordForRetry:(BOOL)retry;
/// 引擎日志，engine 内部线程调用。
- (void)engineLog:(NSString *)message level:(Z7LogLevel)level;
@end

#pragma mark - 归档（只读 + 更新）

@class Z7CompressionOptions;

@interface Z7Archive : NSObject

/// 打开归档并自动探测格式。失败时返回 nil 并填充 error。
+ (nullable instancetype)openPath:(NSString *)path
                         password:(nullable NSString *)password
                         callback:(nullable id<Z7Callback>)callback
                            error:(NSError **)error;

@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly, copy) NSString *formatName;
@property (nonatomic, readonly) uint32_t itemCount;

/// 打开该归档是否需要密码。对 7z 等价于「文件名加密（-mhe）」。
/// UI 据此判断是否提示输入密码；删除/更新重建时会据此保留 -mhe。
@property (nonatomic, readonly) BOOL headerEncrypted;

/// 最近一次操作的统计
@property (nonatomic, readonly, strong) Z7ExtractStats *lastStats;

- (nullable Z7Item *)itemAtIndex:(uint32_t)index;
/// 一次性取回全部条目。10 万级条目建议在后台线程调用。
- (NSArray<Z7Item *> *)allItems;

/// 提取。indices 为 nil 表示全部。
///   testMode    仅校验完整性，不写盘（方案 §5 的「测试」）
///   overwrite   NO 时已存在的文件被跳过
///   atomicFiles YES 时先写 .partial 再原子改名（方案 §7.4）
///   createLinks YES 时允许创建符号链接，但目标必须落在目标目录内（方案 §8.2）
- (BOOL)extractItems:(nullable NSArray<NSNumber *> *)indices
                  to:(NSString *)destination
            testMode:(BOOL)testMode
           overwrite:(BOOL)overwrite
         atomicFiles:(BOOL)atomicFiles
         createLinks:(BOOL)createLinks
            callback:(nullable id<Z7Callback>)callback
               error:(NSError **)error;

/// 单条目提取到指定文件（供 Quick Look 预览、拖出导出使用）。
- (BOOL)extractItemAtIndex:(uint32_t)index
                    toFile:(NSString *)destinationFile
                  callback:(nullable id<Z7Callback>)callback
                     error:(NSError **)error;

/// 提取到内存。tooLarge 在超出 maxBytes 时置 YES。
- (nullable NSData *)extractItemAtIndex:(uint32_t)index
                               maxBytes:(unsigned long long)maxBytes
                               tooLarge:(BOOL *)tooLarge
                               callback:(nullable id<Z7Callback>)callback
                                  error:(NSError **)error;

/// 向已打开的归档追加条目（方案 §5.1「更新模式」）。
/// replaceExisting == NO 时，同名条目被跳过；YES 时被替换。
/// 注意：成功后本对象即失效（原文件已被替换），必须重新 openPath:。
- (BOOL)addPaths:(NSArray<NSString *> *)inputPaths
         options:(Z7CompressionOptions *)options
 replaceExisting:(BOOL)replaceExisting
        callback:(nullable id<Z7Callback>)callback
           error:(NSError **)error;

/// 从已打开的归档中删除条目（方案 §6.4「删除键（更新归档时）」）。
/// arcPaths 为归档内完整路径；删除目录路径时其下所有后代一并删除。
///
/// 实现为「解压保留项 → 重建 → 原子替换」，因此保留条目会按 options 中的
/// 压缩参数重新压缩。容器格式始终沿用原归档格式（删除不应改变容器类型），
/// options.format 在此方法中被忽略。
/// 注意：成功后本对象即失效（原文件已被替换），必须重新 openPath:。
- (BOOL)removePaths:(NSArray<NSString *> *)arcPaths
            options:(Z7CompressionOptions *)options
           callback:(nullable id<Z7Callback>)callback
              error:(NSError **)error;

/// 请求取消正在进行的操作。可从任意线程调用。
- (void)requestCancel;

@end

#pragma mark - 压缩参数（技术方案 §5.1 面板字段映射）

/// 面板字段 → 引擎属性的载体。全部为值语义，可在任务间安全传递。
@interface Z7CompressionOptions : NSObject <NSCopying>

@property (nonatomic, copy) NSString *format; // 7z | zip | tar | gzip | bzip2 | xz
@property (nonatomic) NSInteger level;        // 0..9

@property (nonatomic, copy) NSString *method; // LZMA2/LZMA/PPMd/BZip2/Deflate/Copy，@"" = 默认
@property (nonatomic) BOOL hasDictionarySize;
@property (nonatomic) unsigned long long dictionarySize;
@property (nonatomic) BOOL hasWordLength;
@property (nonatomic) NSInteger wordLength;
@property (nonatomic) BOOL hasFastBytes;
@property (nonatomic) NSInteger fastBytes;
@property (nonatomic, copy) NSString *matchFinder; // bt4/hc4/bt2/hc3，@"" = 默认

@property (nonatomic) BOOL hasSolid;
@property (nonatomic) BOOL solid;
/// 固实分块，合法形式为 "e" / "100f" / "64m"，@"" = 不限制。
@property (nonatomic, copy) NSString *solidBlock;
/// 保留完整路径（-spf）
@property (nonatomic) BOOL fullPaths;

@property (nonatomic) BOOL hasThreads;
@property (nonatomic) NSInteger threads; // 0 = 自动

@property (nonatomic) BOOL hasVolumeSize;
@property (nonatomic) unsigned long long volumeSize;
/// 分卷大小的原始输入（如 "100m"），仅供 UI 回显
@property (nonatomic, copy) NSString *volumeSizeText;

@property (nonatomic, copy) NSString *encryptMethod; // zip/tar 的 -mem
@property (nonatomic, copy) NSString *password;
@property (nonatomic) BOOL hasEncryptHeader;
@property (nonatomic) BOOL encryptHeader;
@property (nonatomic) BOOL hasCompressHeader;
@property (nonatomic) BOOL compressHeader;

/// 压缩时排除 macOS/Windows 系统元数据垃圾（.DS_Store / __MACOSX / ._* /
/// Thumbs.db …）。默认 YES。关闭后这些文件会按普通文件写入归档；
/// 归档「列表」侧的同类过滤始终生效，不受本属性影响。
@property (nonatomic) BOOL excludeMacJunk;

@end

#pragma mark - 引擎能力

@interface Z7Engine : NSObject

/// lib7z 版本串
+ (NSString *)engineVersion;

/// 已注册的格式处理器：@[ @[name, extensions, @(canUpdate)], ... ]
+ (NSArray<NSArray *> *)supportedFormats;

/// 可写入（创建）的格式名列表，按 UI 期望顺序排列
+ (NSArray<NSString *> *)writableFormats;

/// 由文件扩展名推断引擎格式名；无法判断时返回 nil。
+ (nullable NSString *)formatForExtension:(NSString *)extension;

/// 新建归档。成功返回 YES。
+ (BOOL)createArchive:(NSString *)destinationArchive
            fromPaths:(NSArray<NSString *> *)inputPaths
              options:(Z7CompressionOptions *)options
             callback:(nullable id<Z7Callback>)callback
                error:(NSError **)error;

/// 由 ISO 8601 风格的错误码常量
extern NSString *const Z7ErrorDomain;

@end

NS_ASSUME_NONNULL_END
