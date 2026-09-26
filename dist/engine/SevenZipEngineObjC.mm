// SevenZipEngineObjC.mm
//
// 7-Zip 引擎内嵌桥接层 —— Objective-C 适配层实现（技术方案 §4.2）
//
// 职责：
//   1. 把 z7::Callback 翻译成 Objective-C 协议 Z7Callback；
//   2. 把 z7::ItemInfo / CompressionOptions 双向翻译为 Foundation 值类型；
//   3. 把 std::string 错误信息翻译为 NSError；
//   4. 持有 C++ 对象的生命周期，保证 ARC 下不泄漏、不悬垂。
//
// 注意：本文件必须按 Objective-C++ 编译（-x objective-c++ 或 .mm 扩展名）。

#import "SevenZipEngineObjC.h"

#include "SevenZipEngine.h"

#include <atomic>
#include <memory>
#include <string>
#include <vector>

#include <sys/stat.h>

NSString *const Z7ErrorDomain = @"org.7-zip.engine";

#pragma mark - 内部可变属性

@interface Z7Progress ()
@property (nonatomic, readwrite) unsigned long long completed;
@property (nonatomic, readwrite) unsigned long long total;
@property (nonatomic, readwrite) uint32_t itemIndex;
@property (nonatomic, readwrite, copy) NSString *itemPath;
@end

@interface Z7ExtractStats ()
@property (nonatomic, readwrite) unsigned long long errors;
@property (nonatomic, readwrite) unsigned long long wrongPassword;
@property (nonatomic, readwrite) unsigned long long unsafeEntries;
@property (nonatomic, readwrite) unsigned long long skipped;
@property (nonatomic, readwrite) unsigned long long symLinks;
@property (nonatomic, readwrite) unsigned long long bytes;
@end

@interface Z7Item ()
@property (nonatomic, readwrite) uint32_t index;
@property (nonatomic, readwrite, copy) NSString *path;
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite, copy) NSString *parentPath;
@property (nonatomic, readwrite) NSInteger depth;
@property (nonatomic, readwrite) BOOL isDirectory;
@property (nonatomic, readwrite) BOOL isAnti;
@property (nonatomic, readwrite) BOOL isSymLink;
@property (nonatomic, readwrite, copy) NSString *linkTarget;
@property (nonatomic, readwrite) BOOL hasSize;
@property (nonatomic, readwrite) unsigned long long size;
@property (nonatomic, readwrite) BOOL hasPackedSize;
@property (nonatomic, readwrite) unsigned long long packedSize;
@property (nonatomic, readwrite, strong, nullable) NSDate *modificationDate;
@property (nonatomic, readwrite, strong, nullable) NSDate *creationDate;
@property (nonatomic, readwrite) BOOL hasAttributes;
@property (nonatomic, readwrite) uint32_t attributes;
@property (nonatomic, readwrite) BOOL hasCRC;
@property (nonatomic, readwrite) uint32_t crc;
@property (nonatomic, readwrite) BOOL encrypted;
@property (nonatomic, readwrite, copy) NSString *method;
@property (nonatomic, readwrite) double compressionRatio;
@end

#pragma mark - C++ 回调 -> Objective-C 协议

namespace {

/// 把 z7::Callback 的调用转发给 Objective-C 委托。
/// 委托用 __weak 持有，避免与上层任务对象形成环。
class ObjCCallback final : public z7::Callback {
public:
    __weak id<Z7Callback> delegate;
    std::atomic<bool> canceled{false};

    /// 密码以 UTF-8 暂存，作用域结束即清零（技术方案 §8.2「密码明文」）
    void SetPassword(NSString *_Nullable pw) {
        if (pw.length == 0) {
            Burn();
            return;
        }
        const char *utf8 = pw.UTF8String;
        pwBuf.assign(utf8 ? utf8 : "");
    }

    ~ObjCCallback() override { Burn(); }

    bool OnProgress(uint64_t completed, uint64_t total, uint32_t idx,
                    const std::string &path) override {
        id<Z7Callback> d = delegate;
        if (!d) return !canceled.load();
        if ([d respondsToSelector:@selector(engineProgress:)]) {
            @autoreleasepool {
                Z7Progress *p = [[Z7Progress alloc] init];
                p.completed = completed;
                p.total = total;
                p.itemIndex = idx;
                p.itemPath = Utf8ToNSString(path);
                [d engineProgress:p];
            }
        }
        return !IsCanceled();
    }

    bool IsCanceled() override {
        if (canceled.load()) return true;
        id<Z7Callback> d = delegate;
        if (!d) return false;
        if ([d respondsToSelector:@selector(engineIsCanceled)]) return [d engineIsCanceled];
        return false;
    }

    std::string GetPassword(bool retry) override {
        id<Z7Callback> d = delegate;
        if (d && [d respondsToSelector:@selector(enginePasswordForRetry:)]) {
            NSString *s = [d enginePasswordForRetry:retry];
            if (s.length) {
                const char *utf8 = s.UTF8String;
                return utf8 ? std::string(utf8) : std::string();
            }
        }
        return pwBuf;
    }

    void OnLog(z7::LogLevel level, const std::string &message) override {
        id<Z7Callback> d = delegate;
        if (!d) return;
        if ([d respondsToSelector:@selector(engineLog:level:)]) {
            @autoreleasepool {
                [d engineLog:Utf8ToNSString(message) level:(Z7LogLevel)level];
            }
        }
    }

private:
    std::string pwBuf;

    static NSString *Utf8ToNSString(const std::string &s) {
        NSString *r = [[NSString alloc] initWithBytes:s.data()
                                               length:s.size()
                                             encoding:NSUTF8StringEncoding];
        if (r) return r;
        return [[NSString alloc] initWithBytes:s.data()
                                        length:s.size()
                                      encoding:NSISOLatin1StringEncoding] ?: @"";
    }

    void Burn() {
        if (pwBuf.empty()) return;
        volatile char *p = const_cast<volatile char *>(pwBuf.data());
        for (size_t i = 0; i < pwBuf.size(); i++) p[i] = 0;
        pwBuf.clear();
    }
};

/// 任务级 C++ 系统错误 -> NSError
NSError *MakeError(const std::string &utf8Message) {
    NSString *msg = nil;
    if (!utf8Message.empty()) {
        msg = [[NSString alloc] initWithBytes:utf8Message.data()
                                       length:utf8Message.size()
                                     encoding:NSUTF8StringEncoding];
    }
    if (!msg.length) msg = @"引擎操作失败";
    return [NSError errorWithDomain:Z7ErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : msg}];
}

std::string StdStringFromUtf8(NSString *_Nullable s) {
    if (s.length == 0) return std::string();
    const char *utf8 = s.UTF8String;
    return utf8 ? std::string(utf8) : std::string();
}

NSString *Utf8ToNSString(const std::string &s) {
    NSString *r = [[NSString alloc] initWithBytes:s.data()
                                           length:s.size()
                                         encoding:NSUTF8StringEncoding];
    return r ?: @"";
}

/// POSIX 模式（st_mode）-> ls -l 风格属性串
NSString *AttributeTextFromMode(uint32_t attrib, BOOL isDir, BOOL isSymLink) {
    const uint32_t mode = attrib >> 16;
    char type = '-';
    if (S_ISLNK(mode)) {
        type = 'l';
    } else if (S_ISDIR(mode)) {
        type = 'd';
    } else if (S_ISCHR(mode)) {
        type = 'c';
    } else if (S_ISBLK(mode)) {
        type = 'b';
    } else if (S_ISFIFO(mode)) {
        type = 'p';
    } else if (S_ISSOCK(mode)) {
        type = 's';
    } else if (isSymLink) {
        type = 'l';
    } else if (isDir) {
        type = 'd';
    }

    const uint32_t m = mode & 07777;
    char buf[11];
    buf[0] = type;
    const char chars[] = {'r', 'w', 'x'};
    int pos = 1;
    for (int g = 2; g >= 0; g--) {
        for (int b = 2; b >= 0; b--) {
            const uint32_t bit = 1u << (g * 3 + b);
            buf[pos++] = (m & bit) ? chars[2 - b] : '-';
        }
    }
    // setuid / setgid / sticky 位
    if (m & 04000) buf[3] = (buf[3] == 'x') ? 's' : 'S';
    if (m & 02000) buf[6] = (buf[6] == 'x') ? 's' : 'S';
    if (m & 01000) buf[9] = (buf[9] == 'x') ? 't' : 'T';
    buf[10] = '\0';
    return [NSString stringWithUTF8String:buf] ?: @"";
}

} // namespace

#pragma mark - Z7Progress

@implementation Z7Progress
- (double)fraction {
    if (self.total == 0) return -1.0;
    return (double)self.completed / (double)self.total;
}
@end

#pragma mark - Z7ExtractStats

@implementation Z7ExtractStats
@end

#pragma mark - Z7Item

@implementation Z7Item {
    // 属性串与 CRC 串按需构造并缓存。
    //
    // 这三个串原本在创建条目时就无条件算好（crcText 还是 stringWithFormat），
    // 但应用侧「CRC / 方法 / 属性」三列默认隐藏——十万条目的归档会白白常驻
    // 十几 MB 字符串（实测每条约 190 B）。改为惰性后，隐藏时零开销，
    // 可见时也只构造一次（表格重绘会反复取用，故必须缓存而非每次现算）。
    NSString *_attributeTextCache;
    NSString *_permissionTextCache;
    NSString *_crcTextCache;
}

+ (NSString *)attributeTextFromMode:(uint32_t)attrib
                        isDirectory:(BOOL)isDir
                          isSymLink:(BOOL)isSymLink
{
    return AttributeTextFromMode(attrib, isDir, isSymLink);
}

- (instancetype)init {
    if ((self = [super init])) {
        _linkTarget = @"";
        _parentPath = @"";
        _method = @"";
        _compressionRatio = -1.0;
    }
    return self;
}

- (NSString *)attributeText {
    if (_attributeTextCache) return _attributeTextCache;
    if (self.hasAttributes) {
        _attributeTextCache = AttributeTextFromMode(self.attributes, self.isDirectory, self.isSymLink);
    } else {
        // 无属性位时，目录给一个占位串，其余保持空（与惰性化之前的取值一致）
        _attributeTextCache = self.isDirectory ? @"d---------" : @"";
    }
    return _attributeTextCache;
}

- (NSString *)permissionText {
    if (_permissionTextCache) return _permissionTextCache;
    NSString *full = self.attributeText;
    // 只有真的解析出属性位时才从属性串派生权限位；否则为空串
    _permissionTextCache = (self.hasAttributes && full.length > 1)
                               ? [full substringFromIndex:1]
                               : @"";
    return _permissionTextCache;
}

- (NSString *)crcText {
    if (_crcTextCache) return _crcTextCache;
    _crcTextCache = self.hasCRC ? [NSString stringWithFormat:@"%08X", self.crc] : @"";
    return _crcTextCache;
}

- (NSString *)displayName {
    if (self.isSymLink && self.linkTarget.length) {
        return [NSString stringWithFormat:@"%@ → %@", self.name, self.linkTarget];
    }
    return self.name;
}
@end

#pragma mark - 从 C++ 值类型构造

namespace {

Z7Item *ItemFromInfo(const z7::ItemInfo &info) {
    Z7Item *it = [[Z7Item alloc] init];
    it.index = info.index;
    it.path = Utf8ToNSString(info.path);
    it.name = Utf8ToNSString(info.name);
    it.parentPath = Utf8ToNSString(info.parent);
    it.depth = (NSInteger)info.depth;
    it.isDirectory = info.isDir;
    it.isAnti = info.isAnti;
    it.isSymLink = info.isSymLink;
    it.linkTarget = Utf8ToNSString(info.linkTarget);
    it.hasSize = info.hasSize;
    it.size = info.size;
    it.hasPackedSize = info.hasPackSize;
    it.packedSize = info.packSize;
    if (info.hasMTime) {
        it.modificationDate = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)info.mtime];
    }
    if (info.hasCTime) {
        it.creationDate = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)info.ctime];
    }
    it.hasAttributes = info.hasAttrib;
    it.attributes = info.attrib;
    // 属性串（attributeText / permissionText）不在这里预构造：技术列默认隐藏，
    // 十万级归档为每个条目预先建串会显著推高内存。改由 Z7Item 的 getter 惰性计算。
    it.hasCRC = info.hasCRC;
    it.crc = info.crc;
    // crcText 同上，同样交给惰性 getter。
    it.encrypted = info.encrypted;
    it.method = Utf8ToNSString(info.method);
    if (info.hasSize && info.hasPackSize && info.size > 0) {
        it.compressionRatio = info.compressionRatio();
    }
    return it;
}

Z7ExtractStats *StatsFromCxx(const z7::Archive::ExtractStats &s) {
    Z7ExtractStats *st = [[Z7ExtractStats alloc] init];
    st.errors = s.errors;
    st.wrongPassword = s.wrongPassword;
    st.unsafeEntries = s.unsafe;
    st.skipped = s.skipped;
    st.symLinks = s.symLinks;
    st.bytes = s.bytes;
    return st;
}

/// Foundation -> C++ 压缩参数
z7::CompressionOptions OptionsToCxx(Z7CompressionOptions *o) {
    z7::CompressionOptions c;
    const std::string fmt = StdStringFromUtf8(o.format);
    c.format = fmt.empty() ? "7z" : fmt;
    c.level = (int)o.level;
    c.method = StdStringFromUtf8(o.method);
    c.hasDict = o.hasDictionarySize;
    c.dictSize = o.dictionarySize;
    c.hasWordLength = o.hasWordLength;
    c.wordLength = (int)o.wordLength;
    c.hasFastBytes = o.hasFastBytes;
    c.fastBytes = (int)o.fastBytes;
    c.matchFinder = StdStringFromUtf8(o.matchFinder);
    c.hasSolid = o.hasSolid;
    c.solid = o.solid;
    c.solidBlock = StdStringFromUtf8(o.solidBlock);
    c.fullPaths = o.fullPaths;
    c.hasThreads = o.hasThreads;
    c.threads = (int)o.threads;
    c.hasVolumeSize = o.hasVolumeSize;
    c.volumeSize = o.volumeSize;
    c.encryptMethod = StdStringFromUtf8(o.encryptMethod);
    c.password = StdStringFromUtf8(o.password);
    c.hasEncryptHeader = o.hasEncryptHeader;
    c.encryptHeader = o.encryptHeader;
    c.hasCompressHeader = o.hasCompressHeader;
    c.compressHeader = o.compressHeader;
    c.excludeMacJunk = o.excludeMacJunk;
    return c;
}

} // namespace

#pragma mark - Z7Archive

@interface Z7Archive () {
    z7::Archive *_archive;          // 由本对象独占持有
    ObjCCallback *_cbBridge;        // z7 回调 -> ObjC 委托
    std::string _pathUtf8;          // 保留 C 串，供失效后仍在用的消息使用
}
@property (nonatomic, readwrite, copy) NSString *path;
@property (nonatomic, readwrite, copy) NSString *formatName;
@property (nonatomic, readwrite) uint32_t itemCount;
@property (nonatomic, readwrite) BOOL headerEncrypted;
@property (nonatomic, readwrite, strong) Z7ExtractStats *lastStats;
@end

@implementation Z7Archive

+ (nullable instancetype)openPath:(NSString *)path
                         password:(nullable NSString *)password
                         callback:(nullable id<Z7Callback>)callback
                            error:(NSError **)error {
    if (path.length == 0) {
        if (error) *error = MakeError("归档路径为空");
        return nil;
    }

    ObjCCallback *bridge = new ObjCCallback;
    bridge->delegate = callback;
    bridge->SetPassword(password);

    std::string err;
    z7::Archive *arch = z7::Archive::Open(StdStringFromUtf8(path), bridge, err);
    if (!arch) {
        if (error) *error = MakeError(err);
        delete bridge;
        return nil;
    }

    Z7Archive *a = [[Z7Archive alloc] init];
    a->_archive = arch;
    a->_cbBridge = bridge;
    a->_pathUtf8 = StdStringFromUtf8(path);
    a.path = path;
    a.formatName = Utf8ToNSString(arch->formatName());
    a.itemCount = arch->itemCount();
    a.headerEncrypted = arch->isHeaderEncrypted() ? YES : NO;
    a.lastStats = [[Z7ExtractStats alloc] init];
    return a;
}

- (void)dealloc {
    delete _archive;
    _archive = nullptr;
    delete _cbBridge;
    _cbBridge = nullptr;
}

- (nullable Z7Item *)itemAtIndex:(uint32_t)index {
    if (!_archive) return nil;
    z7::ItemInfo info;
    if (!_archive->getItem(index, info)) return nil;
    return ItemFromInfo(info);
}

- (NSArray<Z7Item *> *)allItems {
    if (!_archive) return @[];
    std::vector<z7::ItemInfo> infos;
    if (!_archive->getAllItems(infos)) return @[];
    NSMutableArray<Z7Item *> *out = [NSMutableArray arrayWithCapacity:infos.size()];
    for (size_t i = 0; i < infos.size(); i++) {
        @autoreleasepool {
            [out addObject:ItemFromInfo(infos[i])];
        }
    }
    return out;
}

- (BOOL)extractItems:(nullable NSArray<NSNumber *> *)indices
                  to:(NSString *)destination
            testMode:(BOOL)testMode
               clash:(Z7ClashPolicy)clash
         atomicFiles:(BOOL)atomicFiles
         createLinks:(BOOL)createLinks
            callback:(nullable id<Z7Callback>)callback
               error:(NSError **)error {
    if (!_archive) {
        if (error) *error = MakeError("归档未打开");
        return NO;
    }
    if (destination.length == 0 && !testMode) {
        if (error) *error = MakeError("目标目录为空");
        return NO;
    }

    std::vector<uint32_t> idx;
    if (indices) {
        idx.reserve(indices.count);
        for (NSNumber *n in indices) idx.push_back((uint32_t)n.unsignedIntValue);
    }

    _cbBridge->delegate = callback;
    std::string err;
    const bool ok = _archive->extract(idx, StdStringFromUtf8(destination), testMode,
                                      (z7::ClashPolicy)clash,
                                      _cbBridge, err, atomicFiles, createLinks);
    self.lastStats = StatsFromCxx(_archive->lastExtractStats());
    if (!ok && error) *error = MakeError(err);
    return ok;
}

- (BOOL)extractItemAtIndex:(uint32_t)index
                    toFile:(NSString *)destinationFile
                  callback:(nullable id<Z7Callback>)callback
                     error:(NSError **)error {
    if (!_archive) {
        if (error) *error = MakeError("归档未打开");
        return NO;
    }
    _cbBridge->delegate = callback;
    std::string err;
    const bool ok = _archive->extractToFile(index, StdStringFromUtf8(destinationFile),
                                            _cbBridge, err);
    self.lastStats = StatsFromCxx(_archive->lastExtractStats());
    if (!ok && error) *error = MakeError(err);
    return ok;
}

- (nullable NSData *)extractItemAtIndex:(uint32_t)index
                               maxBytes:(unsigned long long)maxBytes
                               tooLarge:(BOOL *)tooLarge
                               callback:(nullable id<Z7Callback>)callback
                                  error:(NSError **)error {
    if (tooLarge) *tooLarge = NO;
    if (!_archive) {
        if (error) *error = MakeError("归档未打开");
        return nil;
    }
    _cbBridge->delegate = callback;
    std::vector<uint8_t> data;
    bool large = false;
    std::string err;
    const bool ok = _archive->extractToMemory(index, data, maxBytes, large, _cbBridge, err);
    if (large) {
        if (tooLarge) *tooLarge = YES;
        if (error) *error = MakeError("条目超过预览大小上限");
        return nil;
    }
    self.lastStats = StatsFromCxx(_archive->lastExtractStats());
    if (!ok) {
        if (error) *error = MakeError(err);
        return nil;
    }
    return [NSData dataWithBytes:data.data() length:data.size()];
}

- (BOOL)addPaths:(NSArray<NSString *> *)inputPaths
         options:(Z7CompressionOptions *)options
 replaceExisting:(BOOL)replaceExisting
        callback:(nullable id<Z7Callback>)callback
           error:(NSError **)error {
    if (!_archive) {
        if (error) *error = MakeError("归档未打开");
        return NO;
    }
    if (inputPaths.count == 0) {
        if (error) *error = MakeError("没有待添加的输入");
        return NO;
    }
    std::vector<std::string> paths;
    paths.reserve(inputPaths.count);
    for (NSString *p in inputPaths) paths.push_back(StdStringFromUtf8(p));

    _cbBridge->delegate = callback;
    z7::CompressionOptions c = OptionsToCxx(options);
    std::string err;
    const bool ok = _archive->addItems(paths, c, replaceExisting, _cbBridge, err);

    // CompressionOptions / 回调里的密码副本清零（§8.2）
    if (!c.password.empty()) {
        volatile char *p = const_cast<volatile char *>(c.password.data());
        for (size_t i = 0; i < c.password.size(); i++) p[i] = 0;
        c.password.clear();
    }

    // addItems 成功后原文件已被替换，本对象持有的处理器与流均已失效
    if (ok) {
        _archive->cancel();
        self.itemCount = 0;
    }
    if (!ok && error) *error = MakeError(err);
    return ok;
}

- (BOOL)removePaths:(NSArray<NSString *> *)arcPaths
            options:(Z7CompressionOptions *)options
           callback:(nullable id<Z7Callback>)callback
              error:(NSError **)error {
    if (!_archive) {
        if (error) *error = MakeError("归档未打开");
        return NO;
    }
    if (arcPaths.count == 0) {
        if (error) *error = MakeError("没有指定要删除的条目");
        return NO;
    }
    std::vector<std::string> paths;
    paths.reserve(arcPaths.count);
    for (NSString *p in arcPaths) paths.push_back(StdStringFromUtf8(p));

    _cbBridge->delegate = callback;
    z7::CompressionOptions c = OptionsToCxx(options);
    // 容器格式由 C++ 层强制沿用原归档格式（options.format 在 removeItems 中被忽略），
    // 此处无需推导。

    std::string err;
    const bool ok = _archive->removeItems(paths, c, _cbBridge, err);

    // CompressionOptions / 回调里的密码副本清零（§8.2）
    if (!c.password.empty()) {
        volatile char *p = const_cast<volatile char *>(c.password.data());
        for (size_t i = 0; i < c.password.size(); i++) p[i] = 0;
        c.password.clear();
    }

    // removeItems 成功后原文件已被替换，本对象持有的处理器与流均已失效
    if (ok) {
        _archive->cancel();
        self.itemCount = 0;
    }
    if (!ok && error) *error = MakeError(err);
    return ok;
}

- (void)requestCancel {
    // canceled 是原子量，且 C++ 回调在高频路径上读取它，故可跨线程调用
    if (_cbBridge) _cbBridge->canceled.store(true);
}

@end

#pragma mark - Z7CompressionOptions

@implementation Z7CompressionOptions

- (instancetype)init {
    if ((self = [super init])) {
        _format = @"7z";
        _level = 5;
        _method = @"";
        _wordLength = 3;
        _fastBytes = 32;
        _matchFinder = @"";
        _solid = YES;
        _solidBlock = @"";
        _threads = 0;
        _volumeSizeText = @"";
        _encryptMethod = @"AES256";
        _password = @"";
        _encryptHeader = YES;
        _compressHeader = YES;
        _excludeMacJunk = YES;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    Z7CompressionOptions *c = [[Z7CompressionOptions allocWithZone:zone] init];
    c.format = self.format;
    c.level = self.level;
    c.method = self.method;
    c.hasDictionarySize = self.hasDictionarySize;
    c.dictionarySize = self.dictionarySize;
    c.hasWordLength = self.hasWordLength;
    c.wordLength = self.wordLength;
    c.hasFastBytes = self.hasFastBytes;
    c.fastBytes = self.fastBytes;
    c.matchFinder = self.matchFinder;
    c.hasSolid = self.hasSolid;
    c.solid = self.solid;
    c.solidBlock = self.solidBlock;
    c.fullPaths = self.fullPaths;
    c.hasThreads = self.hasThreads;
    c.threads = self.threads;
    c.hasVolumeSize = self.hasVolumeSize;
    c.volumeSize = self.volumeSize;
    c.volumeSizeText = self.volumeSizeText;
    c.encryptMethod = self.encryptMethod;
    c.password = self.password;
    c.hasEncryptHeader = self.hasEncryptHeader;
    c.encryptHeader = self.encryptHeader;
    c.hasCompressHeader = self.hasCompressHeader;
    c.compressHeader = self.compressHeader;
    c.excludeMacJunk = self.excludeMacJunk;
    return c;
}

@end

#pragma mark - Z7Engine

@implementation Z7Engine

+ (NSString *)engineVersion {
    return Utf8ToNSString(z7::engineVersion());
}

+ (NSArray<NSArray *> *)supportedFormats {
    std::vector<z7::FormatInfo> formats;
    if (!z7::listFormats(formats)) return @[];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:formats.size()];
    for (size_t i = 0; i < formats.size(); i++) {
        [out addObject:@[ Utf8ToNSString(formats[i].name),
                          Utf8ToNSString(formats[i].extensions),
                          @(formats[i].canUpdate) ]];
    }
    return out;
}

+ (NSArray<NSString *> *)writableFormats {
    // 技术方案 §5.1：7z 默认，tar 用于不压缩的打包
    return @[ @"7z", @"zip", @"tar", @"gzip", @"bzip2", @"xz" ];
}

+ (nullable NSString *)formatForExtension:(NSString *)extension {
    NSString *e = extension.lowercaseString;
    if ([e isEqualToString:@"7z"]) return @"7z";
    if ([e isEqualToString:@"zip"]) return @"zip";
    if ([e isEqualToString:@"tar"]) return @"tar";
    if ([e isEqualToString:@"gz"] || [e isEqualToString:@"tgz"] ||
        [e isEqualToString:@"gzip"]) return @"gzip";
    if ([e isEqualToString:@"bz2"] || [e isEqualToString:@"tbz"] ||
        [e isEqualToString:@"bzip2"]) return @"bzip2";
    if ([e isEqualToString:@"xz"] || [e isEqualToString:@"txz"]) return @"xz";
    return nil;
}

+ (BOOL)createArchive:(NSString *)destinationArchive
            fromPaths:(NSArray<NSString *> *)inputPaths
              options:(Z7CompressionOptions *)options
             callback:(nullable id<Z7Callback>)callback
                error:(NSError **)error {
    if (destinationArchive.length == 0) {
        if (error) *error = MakeError("目标归档路径为空");
        return NO;
    }
    if (inputPaths.count == 0) {
        if (error) *error = MakeError("没有待压缩的输入");
        return NO;
    }

    std::vector<std::string> paths;
    paths.reserve(inputPaths.count);
    for (NSString *p in inputPaths) paths.push_back(StdStringFromUtf8(p));

    ObjCCallback bridge;
    bridge.delegate = callback;
    bridge.SetPassword(options.password);

    z7::CompressionOptions c = OptionsToCxx(options);
    std::string err;
    const bool ok = z7::create(paths, StdStringFromUtf8(destinationArchive), c, &bridge, err);

    // 密码副本清零（§8.2）
    if (!c.password.empty()) {
        volatile char *p = const_cast<volatile char *>(c.password.data());
        for (size_t i = 0; i < c.password.size(); i++) p[i] = 0;
        c.password.clear();
    }

    if (!ok && error) *error = MakeError(err);
    return ok;
}

@end
