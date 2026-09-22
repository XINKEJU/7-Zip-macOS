// main.m — 7-Zip for macOS
//
// 原生 AppKit 前端。引擎**内嵌**在进程内：所有归档操作都通过 ObjC++ 桥接层
// （SevenZipEngineObjC）调用 lib7z.dylib，不再派生 7zz 子进程。
//
// 架构要点（对应技术方案章节）：
//   * §1.3 表现层保持 AppKit、仅替换引擎调用方式：本文件是 ObjC 薄表现层，
//     不接触任何 C++ 符号。
//   * §7.1 主线程红线：所有引擎调用都是同步阻塞的，一律放在串行
//     NSOperationQueue 上执行，主线程只做 UI。
//   * §7.2 进度节流：引擎回调可能每毫秒触发，按 50–100ms 节流后才派发主线程。
//   * §7.3 取消双路径：协作式取消（回调 IsCanceled + requestCancel，
//     引擎每处理一个条目检查一次）+ 覆盖式兜底（任务结束后统一收敛状态）。
//   * §7.4 无进度超时：超过 5 分钟没有任何进度回调即判定卡死并取消。
//   * §6   归档树：NSOutlineView 八列、排序、搜索、右键菜单、拖出、空格预览。
//   * §5.1 配置面板全字段映射到 Z7CompressionOptions。
//   * §8.2 安全：临时文件登记与 SIGTERM 清理；密码字段在任务结束后立即清空。
//
// Build: see dist/app-src/build_app.sh

#import <AppKit/AppKit.h>
// QLPreviewPanel 属于 QuickLookUI.framework（不是 QuickLook.framework 的
// QLThumbnail/QLGenerator 那一套），macOS 上的空格预览面板在这里。
#import <QuickLookUI/QuickLookUI.h>
#import <signal.h>
#import <unistd.h>
#import <stdlib.h>

#import "SevenZipEngineObjC.h"

#pragma mark - 常量与小工具

/// 无进度超时（技术方案 §7.4）：5 分钟
static const NSTimeInterval kNoProgressTimeout = 300.0;
/// 进度节流间隔（技术方案 §7.2）：50ms
static const NSTimeInterval kProgressThrottle = 0.05;

static NSString *HumanSize(unsigned long long n, BOOL hasValue, BOOL isFolder)
{
    if (isFolder || !hasValue) return @"—";
    if (n < 1024) return [NSString stringWithFormat:@"%llu B", n];
    double v = (double)n;
    NSArray *u = @[@"KB", @"MB", @"GB", @"TB", @"PB"];
    NSUInteger i = 0;
    v /= 1024.0;
    while (v >= 1024.0 && i + 1 < u.count) { v /= 1024.0; i++; }
    return [NSString stringWithFormat:@"%.1f %@", v, u[i]];
}

static NSString *HumanRatio(double r)
{
    if (r < 0) return @"—";
    return [NSString stringWithFormat:@"%.0f%%", r * 100.0];
}

static NSString *DateText(NSDate *d)
{
    if (!d) return @"—";
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm";
    });
    return [fmt stringFromDate:d];
}

#pragma mark - 临时文件登记表（技术方案 §8.2：SIGTERM 清理）

/// 登记进程内所有临时产物（预览解包目录、拖出中间文件、删除重建的中间目录），
/// 正常退出与收到 SIGTERM/SIGINT 时统一清理，避免留下半成品或敏感明文。
@interface Z7TempRegistry : NSObject
@property (nonatomic, strong) NSMutableArray<NSString *> *paths;
@property (nonatomic, strong) NSLock *lock;
+ (instancetype)shared;
- (NSString *)newDirectoryWithPrefix:(NSString *)prefix error:(NSError **)error;
- (NSString *)newFileURLForName:(NSString *)name;
- (void)discardPath:(NSString *)p;
- (void)cleanupAll;
@end

static Z7TempRegistry *gTempRegistry = nil;

@implementation Z7TempRegistry

+ (instancetype)shared
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gTempRegistry = [[Z7TempRegistry alloc] init];
        gTempRegistry.paths = [NSMutableArray array];
        gTempRegistry.lock = [[NSLock alloc] init];
    });
    return gTempRegistry;
}

- (NSString *)newDirectoryWithPrefix:(NSString *)prefix error:(NSError **)error
{
    NSString *base = NSTemporaryDirectory();
    NSString *tpl = [base stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@.XXXXXX", prefix]];
    NSMutableData *buf = [[tpl dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [buf appendBytes:"\0" length:1];
    char *out = mkdtemp((char *)buf.bytes);
    if (!out) {
        if (error) {
            *error = [NSError errorWithDomain:Z7ErrorDomain code:-1 userInfo:
                      @{NSLocalizedDescriptionKey: @"无法创建临时目录"}];
        }
        return nil;
    }
    NSString *dir = [NSString stringWithUTF8String:out];
    [self.lock lock];
    [self.paths addObject:dir];
    [self.lock unlock];
    return dir;
}

- (NSString *)newFileURLForName:(NSString *)name
{
    NSString *dir = [self newDirectoryWithPrefix:@"z7preview" error:NULL];
    if (!dir) return nil;
    return [dir stringByAppendingPathComponent:name];
}

- (void)discardPath:(NSString *)p
{
    if (!p.length) return;
    [self.lock lock];
    [self.paths removeObject:p];
    [self.lock unlock];
    [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
}

- (void)cleanupAll
{
    [self.lock lock];
    NSArray *copy = [self.paths copy];
    [self.paths removeAllObjects];
    [self.lock unlock];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in copy) {
        [fm removeItemAtPath:p error:NULL];
    }
}

@end

static void Z7SignalHandler(int sig)
{
    // 信号处理器里只能调用异步信号安全的函数；removeItemAtPath 并不安全，
    // 因此这里只做最基本的事：尽力清空登记表已不可行，改为交给 atexit
    // 与下一次启动的残留扫描。这里保留 _exit 以避免半途状态被写回。
    (void)sig;
    _exit(128 + sig);
}

#pragma mark - 归档树节点（§6.2 数据模型）

@interface Z7Node : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;         // 归档内完整路径
@property (nonatomic, assign) BOOL isDirectory;
@property (nonatomic, assign) BOOL isSymLink;
@property (nonatomic, copy) NSString *linkTarget;

@property (nonatomic, assign) BOOL hasSize;
@property (nonatomic, assign) unsigned long long size;
@property (nonatomic, assign) BOOL hasPacked;
@property (nonatomic, assign) unsigned long long packed;
@property (nonatomic, assign) double ratio;         // <0 表示不可计算

@property (nonatomic, strong) NSDate *modified;
@property (nonatomic, copy) NSString *crcText;
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *attributeText;
@property (nonatomic, assign) BOOL encrypted;

@property (nonatomic, strong) NSMutableArray<Z7Node *> *children;
@property (nonatomic, weak) Z7Node *parent;
@property (nonatomic, assign) uint32_t index;       // 引擎条目索引（目录为合成节点）
@end

@implementation Z7Node

- (instancetype)init
{
    if ((self = [super init])) { _children = [NSMutableArray array]; _ratio = -1; }
    return self;
}

/// 显示名：目录 / 符号链接带后缀提示（§6.2）
- (NSString *)displayName
{
    if (self.isSymLink && self.linkTarget.length) {
        return [NSString stringWithFormat:@"%@ → %@", self.name, self.linkTarget];
    }
    return self.name ?: @"";
}

@end

#pragma mark - 树构建

/// 递归补出缺失的祖先目录节点（部分归档不显式存储目录条目）。
/// 返回该路径对应的节点；若它是顶层则同时挂到 roots。
static Z7Node *Z7EnsureAncestor(NSMutableDictionary<NSString *, Z7Node *> *byPath,
                               NSMutableArray<Z7Node *> *roots,
                               NSString *path)
{
    Z7Node *n = byPath[path];
    if (n) return n;
    n = [[Z7Node alloc] init];
    n.path = path;
    n.name = [path lastPathComponent];
    n.isDirectory = YES;
    n.index = UINT32_MAX;
    byPath[path] = n;

    NSRange slash = [path rangeOfString:@"/" options:NSBackwardsSearch];
    if (slash.location == NSNotFound) {
        [roots addObject:n];
    } else {
        Z7Node *parent = Z7EnsureAncestor(byPath, roots, [path substringToIndex:slash.location]);
        n.parent = parent;
        [parent.children addObject:n];
    }
    return n;
}

/// 由扁平 Z7Item 列表构建层级树。归档内路径以 '/' 分隔。
static NSArray<Z7Node *> *BuildTree(NSArray<Z7Item *> *items)
{
    NSMutableDictionary<NSString *, Z7Node *> *byPath = [NSMutableDictionary dictionary];
    NSMutableArray<Z7Node *> *roots = [NSMutableArray array];

    // 第一遍：为每个真实条目建立节点
    for (Z7Item *it in items) {
        if (!it.path.length) continue;
        Z7Node *n = [[Z7Node alloc] init];
        n.path = it.path;
        n.name = it.name.length ? it.name : it.path;
        n.isDirectory = it.isDirectory;
        n.isSymLink = it.isSymLink;
        n.linkTarget = it.linkTarget;
        n.hasSize = it.hasSize;
        n.size = it.size;
        n.hasPacked = it.hasPackedSize;
        n.packed = it.packedSize;
        n.ratio = it.compressionRatio;
        n.modified = it.modificationDate;
        n.crcText = it.crcText;
        n.method = it.method;
        n.attributeText = it.attributeText;
        n.encrypted = it.encrypted;
        n.index = it.index;
        byPath[it.path] = n;
    }

    // 第二遍：连接父子关系（先做一份快照，避免边遍历边插入）
    NSArray<NSString *> *snapshot = [[byPath allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *path in snapshot) {
        Z7Node *n = byPath[path];
        NSRange slash = [path rangeOfString:@"/" options:NSBackwardsSearch];
        if (slash.location == NSNotFound) {
            [roots addObject:n];
            continue;
        }
        Z7Node *parent = Z7EnsureAncestor(byPath, roots, [path substringToIndex:slash.location]);
        n.parent = parent;
        [parent.children addObject:n];
    }

    // 排序：目录优先，其余按名称（§6.3 默认排序）
    NSComparator cmp = ^NSComparisonResult(Z7Node *a, Z7Node *b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
        return [a.name localizedStandardCompare:b.name];
    };
    // 用显式栈做层序排序，避免递归 block 自捕获（ARC 下会报 retain cycle）
    NSMutableArray<Z7Node *> *stack = [NSMutableArray arrayWithArray:roots];
    while (stack.count) {
        Z7Node *n = stack.lastObject;
        [stack removeLastObject];
        [n.children sortUsingComparator:cmp];
        [stack addObjectsFromArray:n.children];
    }
    [roots sortUsingComparator:cmp];
    return roots;
}

#pragma mark - 任务对象（§7 任务层）

typedef NS_ENUM(NSInteger, Z7TaskKind) {
    Z7TaskKindOpen = 0,
    Z7TaskKindExtract,
    Z7TaskKindTest,
    Z7TaskKindCreate,
    Z7TaskKindAdd,
    Z7TaskKindRemove,
};

@interface Z7Task : NSObject <Z7Callback>

@property (nonatomic, assign) Z7TaskKind kind;
@property (nonatomic, copy) NSString *title;

@property (nonatomic, copy) NSString *archivePath;
@property (nonatomic, copy) NSArray<NSNumber *> *indices;   // extract / test（nil = 全部）
@property (nonatomic, copy) NSString *destDir;              // extract
@property (nonatomic, copy) NSArray<NSString *> *inputPaths; // create / add
@property (nonatomic, copy) NSArray<NSString *> *arcPaths;   // remove
@property (nonatomic, strong) Z7CompressionOptions *options;
@property (nonatomic, assign) BOOL replaceExisting;
@property (nonatomic, assign) BOOL testMode;
@property (nonatomic, assign) BOOL overwrite;

/// 打开 / 列表类任务的结果回传
@property (nonatomic, strong) NSArray<Z7Item *> *openedItems;
@property (nonatomic, copy) NSArray<NSNumber *> *statsOut;
@property (nonatomic, assign) BOOL headerEncryptedOut;

@property (nonatomic, copy) void (^onProgress)(Z7Progress *p);
@property (nonatomic, copy) void (^onLog)(NSString *msg, Z7LogLevel level);
@property (nonatomic, copy) void (^onFinish)(BOOL ok, NSError *error);

@property (atomic, assign) BOOL cancelRequested;
@property (atomic, assign, readonly) BOOL timedOut;

- (void)requestCancel;
- (BOOL)execute:(NSError **)error;

@end

@interface Z7Task () {
    int64_t _lastProgressTick;      // 基于 mach_absolute_time 的节流基准
    NSTimeInterval _lastProgressAt; // 最近一次进度回调的时间（判超时）
    BOOL _didTimeout;
}
@property (nonatomic, strong) Z7Archive *archive;
@property (nonatomic, strong) NSLock *stateLock;
@property (nonatomic, strong) dispatch_source_t watchdog;
@end

@implementation Z7Task

- (instancetype)init
{
    if ((self = [super init])) {
        _stateLock = [[NSLock alloc] init];
        _cancelRequested = NO;
        _didTimeout = NO;
        _overwrite = YES;
        _lastProgressAt = [NSDate timeIntervalSinceReferenceDate];
    }
    return self;
}

- (BOOL)timedOut { return _didTimeout; }

#pragma mark 取消（§7.3 协作式）

- (void)requestCancel
{
    self.cancelRequested = YES;
    // 把取消直接下推到引擎：extract/add/remove 会在条目边界检查该标志
    Z7Archive *a = self.archive;
    if (a) [a requestCancel];
}

#pragma mark 看门狗（§7.4 无进度超时）

- (void)startWatchdog
{
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    uint64_t interval = (uint64_t)(15ull * NSEC_PER_SEC);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                              interval, (uint64_t)(1ull * NSEC_PER_SEC));
    __weak Z7Task *weakSelf = self;
    dispatch_source_set_event_handler(t, ^{
        Z7Task *me = weakSelf;
        if (!me) return;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval idle = now - me->_lastProgressAt;
        if (idle > kNoProgressTimeout && !me.cancelRequested) {
            me->_didTimeout = YES;
            [me requestCancel];
            if (me.onLog) me.onLog(@"超过 5 分钟无进度，已自动停止", Z7LogLevelError);
        }
    });
    self.watchdog = t;
    dispatch_resume(t);
}

- (void)stopWatchdog
{
    if (self.watchdog) {
        dispatch_source_cancel(self.watchdog);
        self.watchdog = nil;
    }
}

#pragma mark Z7Callback（引擎内部线程调用，不得做 UI）

- (void)engineProgress:(Z7Progress *)p
{
    _lastProgressAt = [NSDate timeIntervalSinceReferenceDate];
    // §7.2 节流：50ms 或到达终点才派发，避免高频回调淹掉主线程
    int64_t now = (int64_t)([NSDate timeIntervalSinceReferenceDate] * 1000.0);
    BOOL final = (p.total > 0 && p.completed >= p.total);
    NSLock *l = self.stateLock;
    [l lock];
    BOOL allow = (now - _lastProgressTick) >= (int64_t)(kProgressThrottle * 1000.0) || final;
    if (allow) _lastProgressTick = now;
    [l unlock];
    if (allow && self.onProgress) self.onProgress(p);
}

- (BOOL)engineIsCanceled
{
    return self.cancelRequested;
}

- (NSString *)enginePasswordForRetry:(BOOL)retry
{
    // 重试时返回 nil 以终止循环：应用层的密码来自用户输入，
    // 后台线程不应弹窗。密码错误会以明确的错误信息回到 UI。
    if (retry) return nil;
    return (self.options.password.length ? self.options.password : nil);
}

- (void)engineLog:(NSString *)message level:(Z7LogLevel)level
{
    if (self.onLog) self.onLog(message, level);
}

#pragma mark 执行

- (BOOL)execute:(NSError **)error
{
    [self startWatchdog];
    BOOL ok = NO;
    NSError *localError = nil;

    switch (self.kind) {
        case Z7TaskKindOpen:     ok = [self runOpen:&localError];    break;
        case Z7TaskKindExtract:  ok = [self runExtract:&localError]; break;
        case Z7TaskKindTest:     ok = [self runTest:&localError];    break;
        case Z7TaskKindCreate:   ok = [self runCreate:&localError];  break;
        case Z7TaskKindAdd:      ok = [self runAdd:&localError];     break;
        case Z7TaskKindRemove:   ok = [self runRemove:&localError];  break;
    }

    [self stopWatchdog];
    self.archive = nil;   // 释放对归档的引用，便于原子替换后的文件被回收

    if (!ok && !localError) {
        localError = [NSError errorWithDomain:Z7ErrorDomain code:-1 userInfo:
                      @{NSLocalizedDescriptionKey: (self.timedOut ? @"任务超时被中止" : @"操作已取消")}];
    }
    // 取消/超时不是"失败"，但必须让 UI 知道结果不可信
    if (ok && (self.cancelRequested || self.timedOut)) ok = NO;

    if (error) *error = localError;
    return ok;
}

- (BOOL)runOpen:(NSError **)error
{
    Z7Archive *a = [Z7Archive openPath:self.archivePath
                              password:(self.options.password.length ? self.options.password : nil)
                              callback:self error:error];
    if (!a) return NO;
    self.archive = a;
    self.openedItems = [a allItems];
    self.headerEncryptedOut = a.headerEncrypted;
    // 打开只是读元数据，取消请求要即时生效
    if (self.cancelRequested) {
        if (error) *error = [NSError errorWithDomain:Z7ErrorDomain code:-1 userInfo:
                             @{NSLocalizedDescriptionKey: @"已取消"}];
        return NO;
    }
    return YES;
}

- (BOOL)runExtract:(NSError **)error
{
    Z7Archive *a = [Z7Archive openPath:self.archivePath
                              password:(self.options.password.length ? self.options.password : nil)
                              callback:self error:error];
    if (!a) return NO;
    self.archive = a;

    BOOL ok = [a extractItems:self.indices
                           to:self.destDir
                     testMode:self.testMode
                    overwrite:self.overwrite
                  atomicFiles:YES
                  createLinks:YES
                     callback:self
                        error:error];
    Z7ExtractStats *st = a.lastStats;
    self.statsOut = @[@(st.errors), @(st.wrongPassword), @(st.unsafeEntries),
                      @(st.skipped), @(st.symLinks), @(st.bytes)];
    return ok;
}

- (BOOL)runTest:(NSError **)error
{
    self.testMode = YES;
    return [self runExtract:error];
}

- (BOOL)runCreate:(NSError **)error
{
    return [Z7Engine createArchive:self.archivePath
                         fromPaths:self.inputPaths
                           options:self.options
                          callback:self
                             error:error];
}

- (BOOL)runAdd:(NSError **)error
{
    Z7Archive *a = [Z7Archive openPath:self.archivePath
                              password:(self.options.password.length ? self.options.password : nil)
                              callback:self error:error];
    if (!a) return NO;
    self.archive = a;
    return [a addPaths:self.inputPaths
               options:self.options
       replaceExisting:self.replaceExisting
              callback:self
                 error:error];
}

- (BOOL)runRemove:(NSError **)error
{
    Z7Archive *a = [Z7Archive openPath:self.archivePath
                              password:(self.options.password.length ? self.options.password : nil)
                              callback:self error:error];
    if (!a) return NO;
    self.archive = a;
    return [a removePaths:self.arcPaths options:self.options callback:self error:error];
}

@end

#pragma mark - 可响应空格/删除键的 outline view（§6.4 / §6.5）

@protocol Z7OutlineKeyDelegate <NSObject>
- (void)outlineDidPressSpace;
- (void)outlineDidPressDelete;
@end

@interface Z7OutlineView : NSOutlineView
@property (nonatomic, weak) id<Z7OutlineKeyDelegate> keyDelegate;
@end

@implementation Z7OutlineView

- (void)keyDown:(NSEvent *)e
{
    NSString *chars = e.charactersIgnoringModifiers;
    if ([chars isEqualToString:@" "]) {
        [self.keyDelegate outlineDidPressSpace];
        return;
    }
    unichar c = chars.length ? [chars characterAtIndex:0] : 0;
    if (c == NSDeleteCharacter || c == NSBackspaceCharacter || c == NSDeleteFunctionKey) {
        [self.keyDelegate outlineDidPressDelete];
        return;
    }
    [super keyDown:e];
}

@end

#pragma mark - 拖放视图

@protocol DropViewDelegate <NSObject>
- (void)dropView:(id)view didReceiveURLs:(NSArray<NSURL *> *)urls;
@end

@interface DropView : NSView
@property (nonatomic, weak) id<DropViewDelegate> dropDelegate;
@property (nonatomic, assign) BOOL highlighted;
@end

@implementation DropView

- (instancetype)initWithFrame:(NSRect)f
{
    if ((self = [super initWithFrame:f])) {
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    }
    return self;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
    self.highlighted = YES;
    self.needsDisplay = YES;
    return NSDragOperationCopy;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender
{
    self.highlighted = NO;
    self.needsDisplay = YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
    self.highlighted = NO;
    self.needsDisplay = YES;
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSPasteboardItem *it in [sender.draggingPasteboard pasteboardItems]) {
        NSString *s = [it stringForType:NSPasteboardTypeFileURL];
        if (s) { NSURL *u = [NSURL URLWithString:s]; if (u) [urls addObject:u]; }
    }
    if (urls.count && [self.dropDelegate respondsToSelector:@selector(dropView:didReceiveURLs:)]) {
        [self.dropDelegate dropView:self didReceiveURLs:urls];
        return YES;
    }
    return NO;
}

- (void)drawRect:(NSRect)dirty
{
    // 显式绘制窗口背景色：内容区不依赖窗口的默认底色，空状态与表格边框因此
    // 在浅色/深色外观下都有确定的可对比基准。
    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(dirty);

    if (!self.highlighted) return;
    // 用系统强调色而不是硬编码的蓝：拖放提示应当跟随用户的系统外观设置。
    NSColor *accent = [NSColor controlAccentColor];
    [[accent colorWithAlphaComponent:0.10] setFill];
    NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 10, 10)
                                                      xRadius:12 yRadius:12];
    [p setLineWidth:3];
    [[accent colorWithAlphaComponent:0.75] setStroke];
    [p stroke];
}

@end

#pragma mark - 图标（SF Symbols）

/// 取一个 SF Symbols 图标。名称在旧系统上不存在时返回 nil —— 调用方据此降级
/// 为纯文字按钮，避免出现"图标缺失、按钮一片空白"这种更难排查的界面缺陷。
static NSImage *Symbol(NSString *name, CGFloat pointSize)
{
    NSImage *img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!img) return nil;
    NSImageSymbolConfiguration *c =
        [NSImageSymbolConfiguration configurationWithPointSize:pointSize
                                                        weight:NSFontWeightRegular];
    return [img imageWithSymbolConfiguration:c];
}

/// 真实文件类型图标：复用系统 Finder 图标，按目录/链接/扩展名取，并做缓存，
/// 避免逐格逐帧重复向 NSWorkspace 取图。返回全彩色图标（非 template），
/// 名称列图像视图无需着色，深浅色均自适应。
static NSImage *FileIcon(NSString *name, BOOL isDir, BOOL isLink)
{
    static NSMutableDictionary<NSString *, NSImage *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    NSString *key;
    if (isLink) key = @"\x01symlink";
    else if (isDir) key = @"\x01directory";
    else {
        NSString *ext = name.pathExtension.lowercaseString;
        key = ext.length ? ext : @"\x01file";
    }
    NSImage *img = cache[key];
    if (img) return img;
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    if (isLink)      img = [ws iconForFileType:NSFileTypeSymbolicLink];
    else if (isDir)  img = [ws iconForFileType:NSFileTypeDirectory];
    else {
        NSString *ext = name.pathExtension;
        img = ext.length ? [ws iconForFileType:ext] : [ws iconForFileType:NSFileTypeRegular];
    }
    if (!img) img = Symbol(@"doc", 13.0);
    if (img) {
        // iconForFileType: 返回 32x32 位图，行内按 16x16 渲染与 Finder 一致
        img.size = NSMakeSize(16, 16);
        cache[key] = img;
    }
    return img;
}

#pragma mark - 透明容器

/// 空状态容器：layer 承载，底色为文档区的 textBackgroundColor。
/// 与 NSScrollView 的底色一致，空状态与表格切换时不会出现底色跳变。
@interface Z7PaneView : NSView
@end

@implementation Z7PaneView

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        // 用 layer 承载，而不是依赖 drawRect:。见类注释：本机仅有 layer 承载
        // （或 AppKit 原生 layer 控件）的视图能稳定进入合成。
        self.wantsLayer = YES;
    }
    return self;
}

- (BOOL)wantsUpdateLayer
{
    return YES;
}

- (void)updateLayer
{
    // 在视图当前外观下解析语义色，浅色/深色都得到正确底色。
    self.layer.backgroundColor = [NSColor textBackgroundColor].CGColor;
}

@end

#pragma mark - 状态栏背景（不透明，随外观自适应）

/// 状态栏底色。这里刻意不用 NSVisualEffectView：玻璃材质在本机会透出窗口
/// 背后的桌面（实测状态栏里混进了壁纸上的文字），既不美观也让前景文字与
/// 背景的对比度不受控。直接用 windowBackgroundColor 绘制，浅色/深色外观下
/// 都与系统窗口背景一致，labelColor 的对比度因此始终成立。
@interface Z7BarView : NSView
@end

@implementation Z7BarView

- (void)drawRect:(NSRect)dirty
{
    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(dirty);
}

@end

#pragma mark - 主控制器

@interface MainViewController : NSViewController
    <NSOutlineViewDataSource, NSOutlineViewDelegate, DropViewDelegate,
     Z7OutlineKeyDelegate, NSFilePromiseProviderDelegate,
     QLPreviewPanelDataSource, QLPreviewPanelDelegate>
@end

@interface MainViewController ()
    <NSToolbarDelegate>

// 工具栏
@property (nonatomic, strong) NSToolbar *toolbar;
@property (nonatomic, strong) NSButton *openBtn;
@property (nonatomic, strong) NSButton *compressBtn;
@property (nonatomic, strong) NSButton *extractBtn;
@property (nonatomic, strong) NSButton *addBtn;
@property (nonatomic, strong) NSButton *deleteBtn;
@property (nonatomic, strong) NSButton *testBtn;
@property (nonatomic, strong) NSButton *logBtn;
@property (nonatomic, strong) NSButton *optionsBtn;
@property (nonatomic, strong) NSSearchField *searchField;

// §5.1 配置面板（控件本身放进「压缩选项」弹出面板；名称与字段保持与
// currentOptions 的映射一致）
@property (nonatomic, strong) NSPopUpButton *formatPop;
@property (nonatomic, strong) NSSlider *levelSlider;
@property (nonatomic, strong) NSTextField *levelLabel;
@property (nonatomic, strong) NSPopUpButton *methodPop;
@property (nonatomic, strong) NSPopUpButton *dictPop;
@property (nonatomic, strong) NSPopUpButton *wordPop;
@property (nonatomic, strong) NSTextField *fastBytesField;
@property (nonatomic, strong) NSPopUpButton *matchPop;
@property (nonatomic, strong) NSButton *solidCheck;
@property (nonatomic, strong) NSPopUpButton *solidBlockPop;
@property (nonatomic, strong) NSButton *autoThreadsCheck;
@property (nonatomic, strong) NSTextField *threadsField;
@property (nonatomic, strong) NSPopUpButton *volumePop;
@property (nonatomic, strong) NSPopUpButton *encryptMethPop;
@property (nonatomic, strong) NSSecureTextField *password;
@property (nonatomic, strong) NSButton *encryptHeaderCheck;
@property (nonatomic, strong) NSButton *compressHeaderCheck;
@property (nonatomic, strong) NSButton *fullPathsCheck;
@property (nonatomic, strong) NSPopUpButton *updateModePop;
@property (nonatomic, strong) NSPopover *optionsPopover;

// 内容区（表格与空状态互斥占用，二者共用同一块矩形）
@property (nonatomic, strong) Z7OutlineView *outline;
@property (nonatomic, strong) NSScrollView *outlineScroll;
@property (nonatomic, strong) NSView *emptyState;
@property (nonatomic, strong) NSImageView *emptyIcon;
@property (nonatomic, strong) NSTextField *emptyTitle;
@property (nonatomic, strong) NSTextField *emptySubtitle;
@property (nonatomic, strong) NSButton *emptyButton;

// 日志（默认收起，出错或有告警时自动展开）
@property (nonatomic, strong) NSTextView *log;
@property (nonatomic, strong) NSScrollView *logScroll;
@property (nonatomic, strong) NSBox *logSeparator;
@property (nonatomic, assign) BOOL logVisible;

// 状态栏
@property (nonatomic, strong) Z7BarView *statusBar;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *summaryLabel;
@property (nonatomic, strong) NSProgressIndicator *progress;
@property (nonatomic, strong) NSButton *cancelBtn;

// 拖放
@property (nonatomic, strong) DropView *drop;

// 数据
@property (nonatomic, copy) NSString *archivePath;
/// 打开当前归档所用的密码。与「压缩选项」里的密码分开：前者只在本次会话内
/// 存活、用完即清（§8.2），后者是新建归档时的加密口令。
@property (nonatomic, copy) NSString *openPassword;
@property (nonatomic, assign) BOOL archiveHeaderEncrypted;
@property (nonatomic, strong) NSArray<Z7Node *> *roots;
@property (nonatomic, strong) NSArray<Z7Node *> *displayRoots; // 搜索结果时扁平列表
@property (nonatomic, assign) BOOL filtering;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *indexByPath;

// 任务
@property (nonatomic, strong) NSOperationQueue *queue;
@property (nonatomic, strong) Z7Task *current;

// 预览
@property (nonatomic, strong) NSURL *previewURL;

// 前向声明：loadView 与构建阶段会调用文件后面才定义的方法与属性。
- (void)buildCompressionControls;
- (void)buildTreeAndEmptyState;
- (void)buildLogDrawer;
- (void)buildStatusBar;
- (void)assembleContent;
- (void)buildToolbar;
- (void)setLogVisible:(BOOL)visible;
- (void)updateEmptyState;
- (void)updateOptionsSummary;
- (void)updateArchiveChrome;
- (NSString *)archivePassword;
- (Z7CompressionOptions *)currentOptions;
- (void)setControlsEnabled:(BOOL)on;
- (void)setBusy:(BOOL)busy;
- (void)showStatus:(NSString *)s;
- (void)appendLog:(NSString *)s;
- (void)appendLog:(NSString *)s reveal:(BOOL)reveal;
@end

@implementation MainViewController

- (void)loadView
{
    self.drop = [[DropView alloc] initWithFrame:NSMakeRect(0, 0, 1040, 700)];
    self.drop.dropDelegate = self;
    self.view = self.drop;

    self.queue = [[NSOperationQueue alloc] init];
    self.queue.maxConcurrentOperationCount = 1;   // §7.1 串行，避免并发写同一归档
    self.queue.name = @"org.7-zip.macos.engine";
    self.roots = @[];
    self.displayRoots = @[];
    self.indexByPath = [NSMutableDictionary dictionary];

    [self buildCompressionControls];
    [self buildTreeAndEmptyState];
    [self buildLogDrawer];
    [self buildStatusBar];
    [self assembleContent];
    [self buildToolbar];

    [self setLogVisible:NO];
    [self setBusy:NO];
    [self formatChanged:nil];   // 建立与初始格式一致的控件可用状态
    [self updateEmptyState];
}

#pragma mark 构件

- (NSTextField *)label:(NSString *)s
{
    NSTextField *t = [[NSTextField alloc] initWithFrame:NSZeroRect];
    t.stringValue = s;
    t.editable = NO;
    t.selectable = NO;
    t.bordered = NO;
    t.drawsBackground = NO;
    t.translatesAutoresizingMaskIntoConstraints = NO;
    return t;
}

- (NSButton *)button:(NSString *)title action:(SEL)sel
{
    NSButton *b = [NSButton buttonWithTitle:title target:self action:sel];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

- (NSPopUpButton *)popup:(NSArray *)items action:(SEL)sel
{
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    p.translatesAutoresizingMaskIntoConstraints = NO;
    [p addItemsWithTitles:items];
    if (sel) { p.target = self; p.action = sel; }
    return p;
}

/// 工具栏按钮。SF Symbol 在本机不存在时退化为文字按钮——宁可显示文字，也不要
/// 出现一个"没有图标、看起来是空白"的按钮。
- (NSButton *)toolbarButton:(NSString *)symbol title:(NSString *)title action:(SEL)sel
{
    NSImage *img = Symbol(symbol, 15.0);
    NSButton *b = img ? [NSButton buttonWithImage:img target:self action:sel]
                      : [NSButton buttonWithTitle:title target:self action:sel];
    b.bezelStyle = NSBezelStyleToolbar;
    b.bordered = YES;
    if (img) b.imagePosition = NSImageOnly;
    b.refusesFirstResponder = YES;
    b.toolTip = title;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.widthAnchor constraintGreaterThanOrEqualToConstant:36].active = YES;
    [b.heightAnchor constraintEqualToConstant:26].active = YES;
    return b;
}

/// 分隔线（1px，随明暗外观自适应）。
- (NSBox *)separator
{
    NSBox *b = [[NSBox alloc] initWithFrame:NSZeroRect];
    b.boxType = NSBoxSeparator;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.heightAnchor constraintEqualToConstant:1].active = YES;
    return b;
}

#pragma mark 压缩选项控件（§5.1）

- (void)buildCompressionControls
{
    self.searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchField.placeholderString = @"搜索条目";
    self.searchField.target = self;
    self.searchField.action = @selector(searchChanged:);
    self.searchField.sendsWholeSearchString = NO;
    self.searchField.sendsSearchStringImmediately = YES;

    // 格式
    self.formatPop = [self popup:@[@"7z", @"zip", @"tar", @"xz", @"gz", @"bz2"]
                          action:@selector(formatChanged:)];

    self.levelSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    self.levelSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.levelSlider.minValue = 0; self.levelSlider.maxValue = 9;
    self.levelSlider.integerValue = 5;
    self.levelSlider.continuous = YES;
    self.levelSlider.target = self;
    self.levelSlider.action = @selector(levelChanged:);
    self.levelLabel = [self label:@"等级 5"];
    self.levelLabel.font = [NSFont systemFontOfSize:12];
    self.levelLabel.textColor = [NSColor labelColor];

    // 方法 / 字典 / 字长 / 快速字节 / 匹配查找器
    self.methodPop = [self popup:@[@"自动", @"LZMA2", @"LZMA", @"PPMd", @"BZip2", @"Deflate", @"Copy"]
                          action:@selector(methodChanged:)];
    self.dictPop = [self popup:@[@"自动", @"64 KB", @"1 MB", @"4 MB", @"16 MB", @"32 MB",
                                 @"64 MB", @"128 MB", @"256 MB", @"512 MB", @"1 GB"]
                        action:@selector(updateOptionsSummary:)];
    self.wordPop = [self popup:@[@"自动", @"32", @"64", @"128", @"192", @"273"]
                        action:@selector(updateOptionsSummary:)];
    self.fastBytesField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.fastBytesField.translatesAutoresizingMaskIntoConstraints = NO;
    self.fastBytesField.placeholderString = @"自动";
    self.fastBytesField.alignment = NSTextAlignmentCenter;
    self.fastBytesField.target = self;
    self.fastBytesField.action = @selector(updateOptionsSummary:);
    self.matchPop = [self popup:@[@"自动", @"bt4", @"bt2", @"hc4", @"hc3"]
                         action:@selector(updateOptionsSummary:)];

    // 固实
    self.solidCheck = [NSButton checkboxWithTitle:@"固实" target:self action:@selector(solidChanged:)];
    self.solidCheck.translatesAutoresizingMaskIntoConstraints = NO;
    self.solidCheck.state = NSControlStateValueOn;
    self.solidBlockPop = [self popup:@[@"分块不限", @"10 MB", @"64 MB", @"256 MB", @"1 GB"]
                              action:@selector(updateOptionsSummary:)];

    // 线程
    self.autoThreadsCheck = [NSButton checkboxWithTitle:@"自动" target:self
                                                 action:@selector(threadsChanged:)];
    self.autoThreadsCheck.translatesAutoresizingMaskIntoConstraints = NO;
    self.autoThreadsCheck.state = NSControlStateValueOn;
    self.threadsField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.threadsField.translatesAutoresizingMaskIntoConstraints = NO;
    self.threadsField.placeholderString = @"线程";
    self.threadsField.alignment = NSTextAlignmentCenter;
    self.threadsField.target = self;
    self.threadsField.action = @selector(updateOptionsSummary:);

    // 分卷
    self.volumePop = [self popup:@[@"不分卷", @"1 MB", @"10 MB", @"100 MB", @"1 GB"]
                          action:@selector(updateOptionsSummary:)];

    // 加密
    self.encryptMethPop = [self popup:@[@"AES256", @"AES128", @"ZipCrypto"]
                               action:@selector(updateOptionsSummary:)];
    self.password = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.password.translatesAutoresizingMaskIntoConstraints = NO;
    self.password.placeholderString = @"新建归档的密码（可选）";
    self.password.target = self;
    self.password.action = @selector(updateOptionsSummary:);
    self.encryptHeaderCheck = [NSButton checkboxWithTitle:@"加密文件名" target:self
                                                   action:@selector(updateOptionsSummary:)];
    self.encryptHeaderCheck.translatesAutoresizingMaskIntoConstraints = NO;
    self.encryptHeaderCheck.state = NSControlStateValueOn;
    self.compressHeaderCheck = [NSButton checkboxWithTitle:@"压缩头" target:self
                                                    action:@selector(updateOptionsSummary:)];
    self.compressHeaderCheck.translatesAutoresizingMaskIntoConstraints = NO;
    self.compressHeaderCheck.state = NSControlStateValueOn;
    self.fullPathsCheck = [NSButton checkboxWithTitle:@"保存完整路径" target:self
                                               action:@selector(updateOptionsSummary:)];
    self.fullPathsCheck.translatesAutoresizingMaskIntoConstraints = NO;

    // 更新模式（§5.1「更新模式」，作用于添加操作）
    self.updateModePop = [self popup:@[@"跳过同名", @"替换同名"]
                              action:@selector(updateOptionsSummary:)];
}

#pragma mark 「压缩选项」弹出面板

/// 一行标签：右对齐、固定宽度，两列才能对齐。
- (NSTextField *)optionsLabel:(NSString *)s
{
    NSTextField *t = [self label:s];
    t.font = [NSFont systemFontOfSize:12];
    t.textColor = [NSColor secondaryLabelColor];
    t.alignment = NSTextAlignmentRight;
    [t.widthAnchor constraintEqualToConstant:70].active = YES;
    return t;
}

/// 一个控件槽位：固定宽度，保证左右两列的控件边界严格对齐。
- (NSStackView *)optionsSlot:(NSArray<NSView *> *)views
{
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    s.alignment = NSLayoutAttributeCenterY;
    s.spacing = 6;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    [s.widthAnchor constraintEqualToConstant:142].active = YES;
    return s;
}

- (NSStackView *)optionsRow:(NSArray<NSView *> *)cols
{
    NSStackView *r = [NSStackView stackViewWithViews:cols];
    r.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r.alignment = NSLayoutAttributeCenterY;
    r.spacing = 8;
    r.translatesAutoresizingMaskIntoConstraints = NO;
    [r.widthAnchor constraintEqualToConstant:448].active = YES;
    return r;
}

- (NSView *)buildOptionsView
{
    // 控件宽度统一在这里给：单控件槽位直接铺满槽宽，多控件槽位按比例分配。
    for (NSPopUpButton *p in @[self.formatPop, self.methodPop, self.dictPop, self.wordPop,
                               self.matchPop, self.volumePop, self.encryptMethPop,
                               self.updateModePop]) {
        [p.widthAnchor constraintEqualToConstant:142].active = YES;
    }
    [self.solidBlockPop.widthAnchor constraintEqualToConstant:84].active = YES;
    [self.levelSlider.widthAnchor constraintEqualToConstant:86].active = YES;
    [self.levelLabel.widthAnchor constraintEqualToConstant:48].active = YES;
    [self.fastBytesField.widthAnchor constraintEqualToConstant:100].active = YES;
    [self.threadsField.widthAnchor constraintEqualToConstant:44].active = YES;
    [self.password.widthAnchor constraintEqualToConstant:142].active = YES;

    NSArray<NSArray *> *specs = @[
        @[@"格式", @[self.formatPop],      @"等级",     @[self.levelSlider, self.levelLabel]],
        @[@"方法", @[self.methodPop],      @"字典",     @[self.dictPop]],
        @[@"字长", @[self.wordPop],        @"快速字节", @[self.fastBytesField]],
        @[@"匹配查找器", @[self.matchPop], @"分卷",     @[self.volumePop]],
        @[@"固实", @[self.solidCheck, self.solidBlockPop],
          @"线程", @[self.autoThreadsCheck, self.threadsField]],
        @[@"加密算法", @[self.encryptMethPop], @"密码", @[self.password]],
        @[@"添加时", @[self.updateModePop], @"", @[]],
    ];

    NSMutableArray<NSView *> *rows = [NSMutableArray array];
    for (NSArray *s in specs) {
        NSMutableArray *cols = [NSMutableArray arrayWithObject:[self optionsLabel:s[0]]];
        [cols addObject:[self optionsSlot:s[1]]];
        if ([(NSString *)s[2] length]) {
            [cols addObject:[self optionsLabel:s[2]]];
            [cols addObject:[self optionsSlot:s[3]]];
        }
        [rows addObject:[self optionsRow:cols]];
    }

    // 三个开关横跨整行——它们是"要不要做"的独立开关，不属于某个标签。
    NSStackView *checks = [NSStackView stackViewWithViews:@[self.encryptHeaderCheck,
                                                            self.compressHeaderCheck,
                                                            self.fullPathsCheck]];
    checks.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    checks.alignment = NSLayoutAttributeCenterY;
    checks.spacing = 14;
    checks.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *hint = [self label:@"密码用于新建归档；打开加密归档时会单独询问。"];
    hint.font = [NSFont systemFontOfSize:11];
    hint.textColor = [NSColor tertiaryLabelColor];
    hint.lineBreakMode = NSLineBreakByWordWrapping;
    hint.maximumNumberOfLines = 2;
    [hint.widthAnchor constraintEqualToConstant:300].active = YES;

    NSButton *done = [self button:@"完成" action:@selector(closeOptions:)];
    NSStackView *footer = [NSStackView stackViewWithViews:@[hint, done]];
    footer.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    footer.alignment = NSLayoutAttributeCenterY;
    footer.spacing = 12;
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [footer.widthAnchor constraintEqualToConstant:448].active = YES;
    [hint setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1
                     forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSMutableArray<NSView *> *column = [NSMutableArray array];
    [column addObjectsFromArray:rows];
    [column addObject:[self separator]];
    [column addObject:checks];
    [column addObject:footer];

    NSStackView *stack = [NSStackView stackViewWithViews:column];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 9;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *box = [[NSView alloc] initWithFrame:NSZeroRect];
    [box addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:box.topAnchor constant:18],
        [stack.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-18],
        [stack.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-16],
        [box.widthAnchor constraintEqualToConstant:484],
    ]];
    return box;
}

- (void)showOptions:(id)sender
{
    if (!self.optionsPopover) {
        NSViewController *vc = [[NSViewController alloc] init];
        vc.view = [self buildOptionsView];

        self.optionsPopover = [[NSPopover alloc] init];
        self.optionsPopover.contentViewController = vc;
        self.optionsPopover.behavior = NSPopoverBehaviorSemitransient;
        self.optionsPopover.animates = YES;

        NSSize fit = vc.view.fittingSize;
        self.optionsPopover.contentSize = (fit.width > 200 && fit.height > 80)
            ? fit : NSMakeSize(484, 320);

        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(optionsPopoverDidClose:)
            name:NSPopoverDidCloseNotification
            object:self.optionsPopover];
    }
    NSView *anchor = [sender isKindOfClass:[NSView class]] ? (NSView *)sender : self.optionsBtn;
    [self.optionsPopover showRelativeToRect:anchor.bounds
                                     ofView:anchor
                             preferredEdge:NSRectEdgeMinY];
}

- (void)closeOptions:(id)s
{
    [self.optionsPopover close];
}

- (void)optionsPopoverDidClose:(NSNotification *)n
{
    [self updateOptionsSummary];
}

/// 状态栏右侧的摘要：让用户不必展开面板就知道「新建归档」会用什么参数。
- (void)updateOptionsSummary
{
    Z7CompressionOptions *o = [self currentOptions];
    NSMutableArray *bits = [NSMutableArray arrayWithObject:(o.format.length ? o.format : @"7z")];
    [bits addObject:[NSString stringWithFormat:@"等级 %ld", (long)o.level]];
    if (o.password.length) [bits addObject:@"已设密码"];
    self.summaryLabel.stringValue = [NSString stringWithFormat:@"新建归档：%@",
                                     [bits componentsJoinedByString:@" · "]];
}

#pragma mark 归档树与空状态

- (void)buildTreeAndEmptyState
{
    self.outline = [[Z7OutlineView alloc] initWithFrame:NSZeroRect];
    self.outline.keyDelegate = self;
    self.outline.dataSource = self;
    self.outline.delegate = self;
    // 显式指定 .fullWidth：默认的"自动"样式在本机会解析为 .inset，于是空表被
    // 渲染成一叠带圆角的空白行块（旧界面截图里那一片灰条就是这么来的）。
    self.outline.style = NSTableViewStyleFullWidth;
    // 斑马纹在本机（FullWidth 样式 + 新版 AppKit）会一直画到最后一行之外的
    // 空白区域，Finder 列表视图实为无条纹纯色底，故关闭。
    self.outline.usesAlternatingRowBackgroundColors = NO;
    self.outline.allowsMultipleSelection = YES;
    self.outline.allowsColumnReordering = YES;
    self.outline.allowsColumnResizing = YES;
    self.outline.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    self.outline.rowHeight = 24;
    self.outline.indentationPerLevel = 14;
    self.outline.autosaveExpandedItems = NO;
    self.outline.autoresizesOutlineColumn = YES;
    self.outline.gridStyleMask = NSTableViewGridNone;
    self.outline.allowsEmptySelection = YES;
    // 拖出提取（§6.6）
    [self.outline setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
    [self.outline registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

    // §6.2 列：默认只展示 Finder 风格三列（名称/大小/修改时间），其余开发向
    // 技术列（压缩后/压缩率/CRC/方法/属性）默认隐藏，可在列头右键菜单中开启。
    // 每项 = @[标题, 宽度, 默认可见]
    NSArray *cols = @[
        @[@"名称", @340, @YES],
        @[@"大小", @90,  @YES],
        @[@"压缩后", @90, @NO],
        @[@"压缩率", @80, @NO],
        @[@"修改时间", @160, @YES],
        @[@"CRC", @100, @NO],
        @[@"方法", @100, @NO],
        @[@"属性", @90,  @NO],
    ];
    for (NSArray *c in cols) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
        col.title = c[0];
        col.width = [c[1] doubleValue];
        col.minWidth = 60;
        col.hidden = ![c[2] boolValue];
        col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:c[0]
                                                                   ascending:YES
                                                                    selector:@selector(localizedStandardCompare:)];
        [self.outline addTableColumn:col];
    }
    self.outline.outlineTableColumn = self.outline.tableColumns.firstObject;

    // 列头右键菜单：勾选切换各列可见性（「名称」为大纲列，始终显示、不可隐藏）。
    [self buildColumnHeaderMenu];

    // 内容区的两个成员（表格与空状态）由 viewDidLayout 直接给定 frame，不走
    // Auto Layout —— 原因见 assembleContent 的说明。
    self.outlineScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.outlineScroll.translatesAutoresizingMaskIntoConstraints = YES;
    self.outlineScroll.documentView = self.outline;
    self.outlineScroll.hasVerticalScroller = YES;
    self.outlineScroll.hasHorizontalScroller = YES;
    self.outlineScroll.autohidesScrollers = YES;
    self.outlineScroll.drawsBackground = YES;
    self.outlineScroll.backgroundColor = [NSColor textBackgroundColor];
    self.outlineScroll.borderType = NSNoBorder;

    [self buildEmptyState];
}

- (void)buildEmptyState
{
    self.emptyIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.emptyIcon.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.emptyIcon.contentTintColor = [NSColor tertiaryLabelColor];
    [self.emptyIcon.widthAnchor constraintEqualToConstant:54].active = YES;
    [self.emptyIcon.heightAnchor constraintEqualToConstant:54].active = YES;

    self.emptyTitle = [self label:@"未打开归档"];
    self.emptyTitle.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    self.emptyTitle.textColor = [NSColor labelColor];
    self.emptyTitle.alignment = NSTextAlignmentCenter;

    self.emptySubtitle = [self label:@""];
    self.emptySubtitle.font = [NSFont systemFontOfSize:12];
    self.emptySubtitle.textColor = [NSColor secondaryLabelColor];
    self.emptySubtitle.alignment = NSTextAlignmentCenter;
    self.emptySubtitle.lineBreakMode = NSLineBreakByWordWrapping;
    self.emptySubtitle.maximumNumberOfLines = 2;
    [self.emptySubtitle.widthAnchor constraintLessThanOrEqualToConstant:380].active = YES;

    self.emptyButton = [self button:@"打开归档…" action:@selector(doOpen:)];

    NSStackView *stack = [NSStackView stackViewWithViews:@[self.emptyIcon, self.emptyTitle,
                                                           self.emptySubtitle, self.emptyButton]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 8;
    [stack setCustomSpacing:18 afterView:self.emptySubtitle];
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    self.emptyState = [[Z7PaneView alloc] initWithFrame:NSZeroRect];
    self.emptyState.translatesAutoresizingMaskIntoConstraints = YES;
    [self.emptyState addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.emptyState.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.emptyState.centerYAnchor constant:-14],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.emptyState.leadingAnchor
                                                        constant:24],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.emptyState.trailingAnchor
                                                       constant:-24],
    ]];
}

#pragma mark 列头右键菜单（切换列可见性）

- (void)buildColumnHeaderMenu
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"列"];
    for (NSTableColumn *col in self.outline.tableColumns) {
        if ([col.identifier isEqualToString:@"名称"]) continue;   // 名称不可隐藏
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:col.title
                                                      action:@selector(toggleColumn:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = col;
        item.state = col.hidden ? NSControlStateValueOff : NSControlStateValueOn;
        [menu addItem:item];
    }
    self.outline.headerView.menu = menu;
}

- (void)toggleColumn:(NSMenuItem *)sender
{
    NSTableColumn *col = sender.representedObject;
    if (!col || [col.identifier isEqualToString:@"名称"]) return;
    col.hidden = !col.hidden;
    sender.state = col.hidden ? NSControlStateValueOff : NSControlStateValueOn;
    [self.outline.headerView setNeedsDisplay:YES];
}

/// 自下而上分配：状态栏 30 → 分隔线 1 →（展开时）日志抽屉 132 + 分隔线 1 → 内容区。
/// 表格与空状态共用内容区矩形，互斥显示，因此两者 frame 始终一致；日志抽屉同样
/// 在此定框（原因见 assembleContent 的说明）。
- (void)viewDidLayout
{
    [super viewDidLayout];
    [self layoutContentFrames];
}

- (void)layoutContentFrames
{
    const CGFloat statusH = 30.0;
    const CGFloat ruleH = 1.0;
    const CGFloat drawerH = 132.0;

    NSRect b = self.drop.bounds;
    CGFloat bottom = statusH + ruleH;               // 31

    if (self.logVisible) {
        self.logSeparator.frame = NSMakeRect(0.0, bottom + drawerH, NSWidth(b), ruleH);
        self.logScroll.frame = NSMakeRect(0.0, bottom, NSWidth(b), drawerH);
        bottom += drawerH + ruleH;                  // 164
    } else {
        self.logScroll.frame = NSZeroRect;
        self.logSeparator.frame = NSZeroRect;
    }

    NSRect r = NSMakeRect(0.0, bottom, NSWidth(b), MAX(0.0, NSHeight(b) - bottom));
    self.outlineScroll.frame = r;
    self.emptyState.frame = r;
}

/// 只有真的没有内容可显示时才占据整个内容区——空状态与表格互斥，不叠加。
- (void)updateEmptyState
{
    BOOL hasContent = (self.displayRoots.count > 0);
    self.emptyState.hidden = hasContent;
    self.outlineScroll.hidden = !hasContent;
    if (hasContent) return;

    NSImage *icon = nil;
    if (!self.archivePath.length) {
        icon = Symbol(@"archivebox", 44.0);
        self.emptyTitle.stringValue = @"未打开归档";
        self.emptySubtitle.stringValue = @"把归档或文件夹拖到这里，或点按工具栏中的「打开归档」。";
        self.emptyButton.hidden = NO;
    } else if (self.filtering) {
        icon = Symbol(@"magnifyingglass", 44.0);
        self.emptyTitle.stringValue = @"没有匹配的条目";
        self.emptySubtitle.stringValue = [NSString stringWithFormat:@"没有名称包含「%@」的条目。",
                                          self.searchField.stringValue];
        self.emptyButton.hidden = YES;
    } else {
        icon = Symbol(@"archivebox", 44.0);
        self.emptyTitle.stringValue = @"归档为空";
        self.emptySubtitle.stringValue = @"这个归档里没有任何条目。";
        self.emptyButton.hidden = YES;
    }
    self.emptyIcon.image = icon;
    self.emptyIcon.hidden = (icon == nil);
}

#pragma mark 日志抽屉

- (void)buildLogDrawer
{
    self.log = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 400, 132)];
    self.log.editable = NO;
    self.log.selectable = YES;
    self.log.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.log.textContainerInset = NSMakeSize(10, 8);
    self.log.autoresizingMask = NSViewWidthSizable;
    self.log.minSize = NSMakeSize(0, 0);
    self.log.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    self.log.verticallyResizable = YES;
    self.log.horizontallyResizable = NO;
    self.log.textContainer.widthTracksTextView = YES;

    self.logScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    // 与内容区同理：交给 Auto Layout 会被整棵跳过绘制，因此显式定位。
    self.logScroll.translatesAutoresizingMaskIntoConstraints = YES;
    self.logScroll.documentView = self.log;
    self.logScroll.hasVerticalScroller = YES;
    self.logScroll.autohidesScrollers = YES;
    self.logScroll.drawsBackground = YES;
    self.logScroll.backgroundColor = [NSColor textBackgroundColor];
    self.logScroll.borderType = NSNoBorder;

    // 日志上方的分隔线。收起时两者一起隐藏，不留空白。
    self.logSeparator = [[NSBox alloc] initWithFrame:NSZeroRect];
    self.logSeparator.boxType = NSBoxSeparator;
    self.logSeparator.translatesAutoresizingMaskIntoConstraints = YES;
}

- (void)setLogVisible:(BOOL)visible
{
    _logVisible = visible;
    self.logSeparator.hidden = !visible;
    self.logScroll.hidden = !visible;
    self.logBtn.state = visible ? NSControlStateValueOn : NSControlStateValueOff;
    // 日志抽屉与内容区共用显式 frame，切换后立刻重排一次，不等下一次布局循环。
    [self layoutContentFrames];
}

- (void)toggleLog:(id)s
{
    [self setLogVisible:!self.logVisible];
    if (self.logVisible) {
        NSUInteger len = self.log.string.length;
        [self.log scrollRangeToVisible:NSMakeRange(len, 0)];
    }
}

- (void)clearLog:(id)s
{
    self.log.string = @"";
}

#pragma mark 状态栏

- (void)buildStatusBar
{
    self.statusBar = [[Z7BarView alloc] initWithFrame:NSZeroRect];
    self.statusBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusBar.heightAnchor constraintEqualToConstant:30].active = YES;

    self.statusLabel = [self label:@"就绪"];
    self.statusLabel.font = [NSFont systemFontOfSize:12];
    self.statusLabel.textColor = [NSColor labelColor];
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.statusLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1
                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.statusLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.summaryLabel = [self label:@""];
    self.summaryLabel.font = [NSFont systemFontOfSize:11];
    self.summaryLabel.textColor = [NSColor secondaryLabelColor];
    self.summaryLabel.alignment = NSTextAlignmentRight;

    self.progress = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.progress.translatesAutoresizingMaskIntoConstraints = NO;
    self.progress.style = NSProgressIndicatorStyleBar;
    self.progress.indeterminate = NO;
    self.progress.minValue = 0; self.progress.maxValue = 100;
    self.progress.controlSize = NSControlSizeSmall;
    [self.progress.widthAnchor constraintEqualToConstant:150].active = YES;

    self.cancelBtn = [NSButton buttonWithTitle:@"停止" target:self action:@selector(doCancel:)];
    self.cancelBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.cancelBtn.controlSize = NSControlSizeSmall;
    self.cancelBtn.toolTip = @"停止当前任务（⌘.）";
    self.cancelBtn.hidden = YES;

    NSStackView *row = [NSStackView stackViewWithViews:@[self.statusLabel, self.summaryLabel,
                                                         self.progress, self.cancelBtn]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.distribution = NSStackViewDistributionFill;
    row.spacing = 10;
    row.edgeInsets = NSEdgeInsetsMake(0, 12, 0, 12);
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusBar addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:self.statusBar.topAnchor],
        [row.leadingAnchor constraintEqualToAnchor:self.statusBar.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:self.statusBar.trailingAnchor],
        [row.bottomAnchor constraintEqualToAnchor:self.statusBar.bottomAnchor],
    ]];
}

#pragma mark 组装

- (void)assembleContent
{
    NSBox *statusSeparator = [self separator];

    // 底部两件套（分隔线 → 状态栏）自下而上钉死。状态栏是自定义不透明视图，
    // 交给 Auto Layout 摆放可以正常绘制（见下方关于内容区的说明）。
    NSArray<NSView *> *rows = @[statusSeparator, self.statusBar];
    for (NSView *v in rows) {
        [self.drop addSubview:v];
        [NSLayoutConstraint activateConstraints:@[
            [v.leadingAnchor constraintEqualToAnchor:self.drop.leadingAnchor],
            [v.trailingAnchor constraintEqualToAnchor:self.drop.trailingAnchor],
        ]];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.statusBar.bottomAnchor constraintEqualToAnchor:self.drop.bottomAnchor],
        [statusSeparator.bottomAnchor constraintEqualToAnchor:self.statusBar.topAnchor],
    ]];

    // 内容区（表格 / 空状态）与日志抽屉刻意不走 Auto Layout，改由 viewDidLayout
    // 直接给 frame。原因：本机环境下，NSScrollView 一旦交给 Auto Layout 管理，
    // 即使 frame、bounds、hidden、alpha、层级全部正确、布局也无歧义，AppKit 依然
    // 会把它们连同各自整棵子树一起跳过绘制（界面上是一片空白）。同一窗口里显式
    // 设定 frame 的视图、以及底部按约束摆放的状态栏都正常显示；这条差异经过
    // 逐一排除（尺寸推导 / 布局歧义 / 隐藏祖先 / 顶边锚定 / 工具栏样式 /
    // drawRect: / layer 承载）后仍稳定复现，因此按可工作的方式实现。
    [self.drop addSubview:self.logSeparator];
    [self.drop addSubview:self.logScroll];
    [self.drop addSubview:self.outlineScroll];
    [self.drop addSubview:self.emptyState];

    // 内容区（表格/空状态/日志）用显式 frame，窗口的内容自适应尺寸会因此变得
    // 很小、开窗即被压成一条。补一条最小宽度约束，等价于声明内容区的最小尺寸。
    [[self.drop.widthAnchor constraintGreaterThanOrEqualToConstant:880] setActive:YES];


    // 右键菜单（§6.4）
    NSMenu *ctx = [[NSMenu alloc] init];
    [ctx addItemWithTitle:@"解压所选…" action:@selector(doExtractSelection:) keyEquivalent:@""];
    [ctx addItemWithTitle:@"预览" action:@selector(doPreview:) keyEquivalent:@""];
    [ctx addItem:[NSMenuItem separatorItem]];
    [ctx addItemWithTitle:@"删除" action:@selector(doDelete:) keyEquivalent:@""];
    for (NSMenuItem *mi in ctx.itemArray) mi.target = self;
    self.outline.menu = ctx;
}

#pragma mark 工具栏

- (void)buildToolbar
{
    self.openBtn     = [self toolbarButton:@"folder" title:@"打开归档" action:@selector(doOpen:)];
    self.compressBtn = [self toolbarButton:@"doc.badge.plus" title:@"新建归档"
                                    action:@selector(doCompressPick:)];
    self.extractBtn  = [self toolbarButton:@"square.and.arrow.down" title:@"解压到…"
                                    action:@selector(doExtract:)];
    self.addBtn      = [self toolbarButton:@"plus.circle" title:@"添加文件…"
                                    action:@selector(doAdd:)];
    self.deleteBtn   = [self toolbarButton:@"trash" title:@"删除所选"
                                    action:@selector(doDelete:)];
    self.testBtn     = [self toolbarButton:@"checkmark.seal" title:@"测试归档"
                                    action:@selector(doTest:)];
    self.optionsBtn  = [self toolbarButton:@"slider.horizontal.3" title:@"压缩选项"
                                    action:@selector(showOptions:)];
    self.logBtn      = [self toolbarButton:@"text.alignleft" title:@"日志"
                                    action:@selector(toggleLog:)];
    self.logBtn.buttonType = NSButtonTypeToggle;

    NSToolbar *tb = [[NSToolbar alloc] initWithIdentifier:@"org.7-zip.macos.toolbar"];
    tb.delegate = self;
    tb.displayMode = NSToolbarDisplayModeIconOnly;
    // 固定布局：自定义会让同一个按钮实例被插入两次，而自定义视图无法分身。
    tb.allowsUserCustomization = NO;
    self.toolbar = tb;
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)tb
{
    return @[@"open", @"new", NSToolbarSpaceItemIdentifier,
             @"extract", @"add", @"delete", @"test",
             NSToolbarFlexibleSpaceItemIdentifier,
             @"search", @"options", @"log"];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)tb
{
    return @[@"open", @"new", @"extract", @"add", @"delete", @"test",
             @"search", @"options", @"log",
             NSToolbarSpaceItemIdentifier, NSToolbarFlexibleSpaceItemIdentifier];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)tb
     itemForItemIdentifier:(NSToolbarItemIdentifier)ident
 willBeInsertedIntoToolbar:(BOOL)flag
{
    if ([ident isEqualToString:@"search"]) {
        NSSearchToolbarItem *it = [[NSSearchToolbarItem alloc] initWithItemIdentifier:ident];
        it.searchField = self.searchField;
        it.preferredWidthForSearchField = 190;
        it.label = @"搜索";
        it.paletteLabel = @"搜索";
        it.toolTip = @"按名称搜索归档内的条目";
        return it;
    }

    NSDictionary<NSString *, NSArray *> *map = @{
        @"open":    @[self.openBtn,     @"打开归档"],
        @"new":     @[self.compressBtn, @"新建归档"],
        @"extract": @[self.extractBtn,  @"解压到…"],
        @"add":     @[self.addBtn,      @"添加文件…"],
        @"delete":  @[self.deleteBtn,   @"删除所选"],
        @"test":    @[self.testBtn,     @"测试归档"],
        @"options": @[self.optionsBtn,  @"压缩选项"],
        @"log":     @[self.logBtn,      @"日志"],
    };
    NSArray *spec = map[ident];
    if (!spec) return nil;

    NSToolbarItem *it = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
    it.view = spec[0];
    it.label = spec[1];
    it.paletteLabel = spec[1];
    it.toolTip = spec[1];
    return it;
}

#pragma mark §5.1 面板 -> Z7CompressionOptions

- (NSString *)selectedFormat { return self.formatPop.titleOfSelectedItem ?: @"7z"; }

- (void)formatChanged:(id)s
{
    // 不同格式支持的方法不同：zip/tar 走 Deflate 系列，gz/bz2/xz 只有单流
    NSString *f = [self selectedFormat];
    BOOL single = ([f isEqualToString:@"gz"] || [f isEqualToString:@"bz2"] || [f isEqualToString:@"xz"]);
    BOOL zipLike = [f isEqualToString:@"zip"];
    self.methodPop.enabled = !single;
    self.dictPop.enabled = !single && !zipLike;
    self.wordPop.enabled = !single && !zipLike;
    self.fastBytesField.enabled = !single && !zipLike;
    self.matchPop.enabled = !single && !zipLike;
    self.solidCheck.enabled = !single;
    self.solidBlockPop.enabled = !single;
    self.volumePop.enabled = !single;
    self.encryptMethPop.enabled = zipLike || [f isEqualToString:@"7z"];
    self.encryptHeaderCheck.enabled = [f isEqualToString:@"7z"];
    self.compressHeaderCheck.enabled = [f isEqualToString:@"7z"];
    self.fullPathsCheck.enabled = YES;
    self.updateModePop.enabled = !single;
    [self updateOptionsSummary];
}

- (void)levelChanged:(id)s
{
    self.levelLabel.stringValue = [NSString stringWithFormat:@"等级 %ld",
                                   (long)self.levelSlider.integerValue];
    [self updateOptionsSummary];
}

- (void)methodChanged:(id)s
{
    NSString *m = self.methodPop.titleOfSelectedItem;
    BOOL advanced = ([m isEqualToString:@"LZMA2"] || [m isEqualToString:@"LZMA"] || [m isEqualToString:@"PPMd"]);
    self.dictPop.enabled = advanced;
    self.wordPop.enabled = advanced;
    self.fastBytesField.enabled = advanced;
    self.matchPop.enabled = advanced;
    [self updateOptionsSummary];
}

- (void)solidChanged:(id)s
{
    self.solidBlockPop.enabled = (self.solidCheck.state == NSControlStateValueOn);
    [self updateOptionsSummary];
}

- (void)threadsChanged:(id)s
{
    self.threadsField.enabled = (self.autoThreadsCheck.state != NSControlStateValueOn);
    [self updateOptionsSummary];
}

/// 字典大小下拉项 -> 字节数（0 = 自动）
static unsigned long long DictSizeForTitle(NSString *t)
{
    t = [t stringByReplacingOccurrencesOfString:@" " withString:@""];
    if (!t.length || [t isEqualToString:@"自动"]) return 0;
    if ([t hasSuffix:@"KB"]) return (unsigned long long)([t substringToIndex:t.length - 2].doubleValue * 1024.0);
    if ([t hasSuffix:@"MB"]) return (unsigned long long)([t substringToIndex:t.length - 2].doubleValue * 1024.0 * 1024.0);
    if ([t hasSuffix:@"GB"]) return (unsigned long long)([t substringToIndex:t.length - 2].doubleValue * 1024.0 * 1024.0 * 1024.0);
    return 0;
}

/// 面板上显示的是人类可读的容量，引擎要的是 7z 自己的分块记号（10m / 1g …）。
/// 直接把 "10 MB" 交给引擎会得到一个无效的 -ms 值，故在此做映射。
static NSString *SolidBlockToken(NSString *title)
{
    if ([title isEqualToString:@"10 MB"])  return @"10m";
    if ([title isEqualToString:@"64 MB"])  return @"64m";
    if ([title isEqualToString:@"256 MB"]) return @"256m";
    if ([title isEqualToString:@"1 GB"])   return @"1g";
    return nil;   // 「不限」= 引擎默认
}

/// 分卷大小下拉项 -> 字节数。「不分卷」返回 NO；其余按人类可读写法解析
/// （10 MB / 1 GB / 100m 都接受）。
static BOOL ParseVolumeSize(NSString *t, unsigned long long *out)
{
    if (!t.length || [t isEqualToString:@"不分卷"]) return NO;
    NSString *s = [[t uppercaseString] stringByReplacingOccurrencesOfString:@" " withString:@""];
    double m = 1.0;
    if ([s hasSuffix:@"KB"])      { m = 1024.0;                      s = [s substringToIndex:s.length - 2]; }
    else if ([s hasSuffix:@"MB"]) { m = 1024.0 * 1024.0;             s = [s substringToIndex:s.length - 2]; }
    else if ([s hasSuffix:@"GB"]) { m = 1024.0 * 1024.0 * 1024.0;    s = [s substringToIndex:s.length - 2]; }
    else if ([s hasSuffix:@"K"])  { m = 1024.0;                      s = [s substringToIndex:s.length - 1]; }
    else if ([s hasSuffix:@"M"])  { m = 1024.0 * 1024.0;             s = [s substringToIndex:s.length - 1]; }
    else if ([s hasSuffix:@"G"])  { m = 1024.0 * 1024.0 * 1024.0;    s = [s substringToIndex:s.length - 1]; }
    double v = s.doubleValue;
    if (v <= 0) return NO;
    *out = (unsigned long long)(v * m);
    return YES;
}

- (Z7CompressionOptions *)currentOptions
{
    Z7CompressionOptions *o = [[Z7CompressionOptions alloc] init];
    o.format = [self selectedFormat];
    o.level = self.levelSlider.integerValue;

    NSString *m = self.methodPop.titleOfSelectedItem;
    if (m && ![m isEqualToString:@"自动"]) o.method = m;

    unsigned long long dict = DictSizeForTitle(self.dictPop.titleOfSelectedItem);
    if (dict > 0) { o.hasDictionarySize = YES; o.dictionarySize = dict; }

    NSString *w = self.wordPop.titleOfSelectedItem;
    if (w.length && ![w isEqualToString:@"自动"]) {
        o.hasWordLength = YES; o.wordLength = w.integerValue;
    }

    if (self.fastBytesField.enabled && self.fastBytesField.stringValue.length) {
        NSInteger fb = self.fastBytesField.integerValue;
        if (fb > 0) { o.hasFastBytes = YES; o.fastBytes = fb; }
    }

    NSString *mf = self.matchPop.titleOfSelectedItem;
    if (mf.length && ![mf isEqualToString:@"自动"]) o.matchFinder = mf;

    o.hasSolid = YES;
    o.solid = (self.solidCheck.state == NSControlStateValueOn);
    // 面板上显示的是人类可读的容量，引擎要的是 7z 自己的分块记号。
    o.solidBlock = SolidBlockToken(self.solidBlockPop.titleOfSelectedItem);

    if (self.autoThreadsCheck.state == NSControlStateValueOn) {
        o.hasThreads = YES; o.threads = 0;
    } else if (self.threadsField.stringValue.length) {
        o.hasThreads = YES; o.threads = self.threadsField.integerValue;
    }

    unsigned long long vol = 0;
    if (ParseVolumeSize(self.volumePop.titleOfSelectedItem, &vol)) {
        o.hasVolumeSize = YES; o.volumeSize = vol;
        o.volumeSizeText = self.volumePop.titleOfSelectedItem;
    }

    o.encryptMethod = self.encryptMethPop.titleOfSelectedItem ?: @"AES256";
    o.password = self.password.stringValue ?: @"";

    o.hasEncryptHeader = YES;
    o.encryptHeader = (self.encryptHeaderCheck.state == NSControlStateValueOn);
    o.hasCompressHeader = YES;
    o.compressHeader = (self.compressHeaderCheck.state == NSControlStateValueOn);
    o.fullPaths = (self.fullPathsCheck.state == NSControlStateValueOn);
    return o;
}

- (void)setControlsEnabled:(BOOL)on
{
    self.extractBtn.enabled = on;
    self.testBtn.enabled = on;
    self.addBtn.enabled = on;
    self.deleteBtn.enabled = on;
}

#pragma mark 日志 / 状态

- (void)appendLog:(NSString *)s
{
    [self appendLog:s reveal:NO];
}

/// reveal=YES 时自动展开日志抽屉。警告与错误才是用户需要看到的内容，
/// 因此由它们自己把抽屉拉出来，而不是让一个空的日志框长期占据空间。
- (void)appendLog:(NSString *)s reveal:(BOOL)reveal
{
    if (!s.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (reveal && !self.logVisible) [self setLogVisible:YES];
        NSTextStorage *st = self.log.textStorage;
        [st appendAttributedString:[[NSAttributedString alloc] initWithString:s
            attributes:@{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
                         NSForegroundColorAttributeName: [NSColor labelColor]}]];
        [self.log scrollRangeToVisible:NSMakeRange(st.length, 0)];
    });
}

- (void)showStatus:(NSString *)s
{
    dispatch_async(dispatch_get_main_queue(), ^{ self.statusLabel.stringValue = s ?: @""; });
}

/// 需要"打开既有归档"的任务（解压 / 测试 / 添加 / 删除 / 预览）用它取密码：
/// 优先用打开该归档时用户输入的密码，否则回退到压缩面板里的密码（新建场景）。
- (NSString *)archivePassword
{
    if (self.openPassword.length) return self.openPassword;
    return self.password.stringValue ?: @"";
}

/// 标题栏的归档标识：窗口标题保持应用名，文件名放进副标题，并挂上代理图标
/// （representedURL），于是标题栏支持 ⌘ 点按显示路径——这是 macOS 文档窗口
/// 的标准行为，比在内容区里塞一个长路径标签更符合系统习惯。
- (void)updateArchiveChrome
{
    NSWindow *w = self.view.window;
    if (!w) return;
    if (self.archivePath.length) {
        w.representedURL = [NSURL fileURLWithPath:self.archivePath];
        w.subtitle = [NSString stringWithFormat:@"%@%@", self.archivePath.lastPathComponent,
                      self.archiveHeaderEncrypted ? @" · 文件名已加密" : @""];
    } else {
        w.representedURL = nil;
        w.subtitle = @"";
    }
}

#pragma mark 任务执行（§7）

/// 所有引擎调用都是同步阻塞的，统一放到串行队列上跑，主线程只做 UI。
- (void)runTask:(Z7Task *)task
          after:(void (^)(BOOL ok, NSError *error))after
{
    if (self.current) {
        NSBeep();
        [self showStatus:@"已有任务在执行"];
        return;
    }
    self.current = task;
    [self setBusy:YES];
    [self showStatus:task.title];
    [self appendLog:[NSString stringWithFormat:@"\n== %@ ==\n", task.title]];

    __weak MainViewController *weakSelf = self;
    task.onProgress = ^(Z7Progress *p) {
        MainViewController *me = weakSelf;
        if (!me) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (p.total > 0) me.progress.doubleValue = 100.0 * (double)p.completed / (double)p.total;
            if (p.itemPath.length) me.statusLabel.stringValue = p.itemPath;
        });
    };
    task.onLog = ^(NSString *msg, Z7LogLevel level) {
        MainViewController *me = weakSelf;
        if (!me) return;
        NSString *tag = level == Z7LogLevelError ? @"[错误] " :
                        (level == Z7LogLevelWarning ? @"[警告] " : @"");
        // 警告与错误把日志抽屉自动拉出来；普通信息不打扰用户。
        [me appendLog:[tag stringByAppendingString:msg]
                reveal:(level != Z7LogLevelInfo)];
        [me appendLog:@"\n"];
    };

    NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:^{
        NSError *err = nil;
        BOOL ok = [task execute:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            MainViewController *me = weakSelf;
            if (!me) return;
            me.current = nil;
            [me setBusy:NO];
            if (after) after(ok, err);
        });
    }];
    [self.queue addOperation:op];
}

/// 进度条与「停止」按钮只在真的有任务时出现——空闲时它们是纯噪声。
- (void)setBusy:(BOOL)busy
{
    self.progress.hidden = !busy;
    self.cancelBtn.hidden = !busy;
    self.summaryLabel.hidden = busy;
    self.progress.doubleValue = 0;
    self.cancelBtn.enabled = busy;
    [self setControlsEnabled:!busy && self.archivePath != nil];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SEL a = item.action;
    if (a == @selector(doCancel:)) return self.current != nil;
    if (a == @selector(doExtract:) || a == @selector(doExtractSelection:) ||
        a == @selector(doTest:) || a == @selector(doAdd:) || a == @selector(doDelete:) ||
        a == @selector(doPreview:)) {
        return self.archivePath != nil && self.current == nil;
    }
    return YES;
}

- (void)doCancel:(id)s
{
    Z7Task *t = self.current;
    if (!t) return;
    [t requestCancel];
    [self showStatus:@"正在停止…"];
    [self appendLog:@"用户请求停止\n"];
}

#pragma mark 打开 / 列表

- (void)doOpen:(id)s
{
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = YES;
    p.canChooseDirectories = NO;
    p.allowsMultipleSelection = NO;
    p.message = @"选择要打开的归档";
    if ([p runModal] == NSModalResponseOK) [self openArchive:p.URL.path password:nil];
}

/// 密码错误或无密码时，向用户索取密码后重试（§8.2：密码不落盘、用完即清）
- (void)promptPasswordWithMessage:(NSString *)message
                       completion:(void (^)(NSString *password))done
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"需要密码";
    alert.informativeText = message ?: @"该归档已加密，请输入密码。";
    [alert addButtonWithTitle:@"确定"];
    [alert addButtonWithTitle:@"取消"];

    NSSecureTextField *field = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    field.placeholderString = @"密码";
    alert.accessoryView = field;
    [alert.window setInitialFirstResponder:field];

    NSModalResponse r = [alert runModal];
    done(r == NSAlertFirstButtonReturn ? field.stringValue : nil);
}

- (void)openArchive:(NSString *)path
{
    [self openArchive:path password:nil];
}

- (void)openArchive:(NSString *)path password:(NSString *)password
{
    if (!path.length) return;

    // 打开用的密码只存在这个字段里，与「压缩选项」的加密口令分开：前者是本次
    // 会话的临时凭据（§8.2 不落盘、用完即清），后者是新建归档时的口令。
    self.openPassword = password;

    self.archivePath = path;
    [self updateArchiveChrome];
    [self updateEmptyState];

    Z7Task *t = [[Z7Task alloc] init];
    t.kind = Z7TaskKindOpen;
    t.title = [NSString stringWithFormat:@"正在读取 %@", path.lastPathComponent];
    t.archivePath = path;
    Z7CompressionOptions *o = [self currentOptions];
    o.password = password ?: @"";
    t.options = o;

    __weak MainViewController *weakSelf = self;
    [self runTask:t after:^(BOOL ok, NSError *error) {
        MainViewController *me = weakSelf;
        if (!me) return;
        if (!ok) {
            NSString *msg = error.localizedDescription ?: @"无法打开归档";
            [me appendLog:[msg stringByAppendingString:@"\n"] reveal:YES];
            me.roots = @[];
            me.displayRoots = @[];
            [me.outline reloadData];
            [me setControlsEnabled:NO];
            [me showStatus:msg];
            [me updateEmptyState];

            // 需要密码 / 密码错误时提示重试
            BOOL needsPassword = [msg containsString:@"需要正确密码"] || [msg containsString:@"密码错误"];
            if (needsPassword) {
                [me promptPasswordWithMessage:msg completion:^(NSString *pw) {
                    if (pw.length) [me openArchive:path password:pw];
                }];
            }
            return;
        }

        me.archiveHeaderEncrypted = t.headerEncryptedOut;
        me.roots = BuildTree(t.openedItems);
        me.displayRoots = me.roots;
        me.filtering = NO;
        me.searchField.stringValue = @"";
        [me rebuildIndex];
        [me.outline reloadData];
        [me.outline expandItem:nil expandChildren:NO];
        [me setControlsEnabled:YES];
        [me updateArchiveChrome];
        [me updateEmptyState];
        [me showStatus:[NSString stringWithFormat:@"已载入 %lu 项", (unsigned long)t.openedItems.count]];
    }];
}

/// path -> 归档内条目索引（供提取时把树节点映射回引擎索引）
- (void)rebuildIndex
{
    [self.indexByPath removeAllObjects];
    NSMutableArray<Z7Node *> *stack = [NSMutableArray arrayWithArray:self.roots];
    while (stack.count) {
        Z7Node *n = stack.lastObject;
        [stack removeLastObject];
        if (n.index != UINT32_MAX) {
            self.indexByPath[n.path] = [NSValue valueWithBytes:&(uint32_t){n.index} objCType:@encode(uint32_t)];
        }
        [stack addObjectsFromArray:n.children];
    }
}

#pragma mark 搜索（§6.3）

- (void)searchChanged:(id)s
{
    NSString *q = self.searchField.stringValue;
    if (!q.length) {
        self.filtering = NO;
        self.displayRoots = self.roots;
        [self.outline reloadData];
        [self updateEmptyState];
        [self showStatus:[NSString stringWithFormat:@"共 %lu 个顶层条目", (unsigned long)self.roots.count]];
        return;
    }
    self.filtering = YES;
    NSMutableArray<Z7Node *> *hits = [NSMutableArray array];
    NSMutableArray<Z7Node *> *stack = [NSMutableArray arrayWithArray:self.roots];
    while (stack.count) {
        Z7Node *n = stack.lastObject;
        [stack removeLastObject];
        if ([n.path rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [hits addObject:n];
        }
        [stack addObjectsFromArray:n.children];
    }
    self.displayRoots = hits;
    [self.outline reloadData];
    [self updateEmptyState];
    [self showStatus:[NSString stringWithFormat:@"匹配 %lu 项", (unsigned long)hits.count]];
}

#pragma mark 提取

- (NSArray<Z7Node *> *)selectedNodes
{
    NSMutableArray<Z7Node *> *out = [NSMutableArray array];
    for (NSInteger r = 0; r < self.outline.numberOfRows; r++) {
        if ([self.outline isRowSelected:r]) {
            Z7Node *n = [self.outline itemAtRow:r];
            if (n) [out addObject:n];
        }
    }
    return out;
}

/// 把选中的树节点展开成引擎条目索引
- (NSArray<NSNumber *> *)indicesForNodes:(NSArray<Z7Node *> *)nodes
{
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    NSMutableArray<Z7Node *> *stack = [NSMutableArray arrayWithArray:nodes];
    while (stack.count) {
        Z7Node *n = stack.lastObject;
        [stack removeLastObject];
        if (n.index != UINT32_MAX) [out addObject:@(n.index)];
        [stack addObjectsFromArray:n.children];
    }
    return out;
}

- (void)doExtract:(id)s
{
    [self extractNodes:nil];
}

- (void)doExtractSelection:(id)s
{
    [self extractNodes:[self selectedNodes]];
}

- (void)extractNodes:(NSArray<Z7Node *> *)nodes
{
    if (!self.archivePath) return;
    // 全选解压：用当前已过滤的条目树（self.roots 不含 macOS 元数据垃圾项），
    // 而非传 nil 触发引擎全量解压——否则别人 macOS 打的 zip 里的 __MACOSX/._* 会被写出。
    if (!nodes) nodes = self.roots;
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = NO;
    p.canChooseDirectories = YES;
    p.canCreateDirectories = YES;
    p.allowsMultipleSelection = NO;
    p.message = @"选择解压目标文件夹";
    p.directoryURL = [NSURL fileURLWithPath:[self.archivePath stringByDeletingLastPathComponent]];
    if ([p runModal] != NSModalResponseOK) return;

    NSString *dest = p.URL.path;
    [self rememberDestination:dest];

    NSArray<NSNumber *> *indices = nil;
    NSString *what = @"全部条目";
    if (nodes.count) {
        indices = [self indicesForNodes:nodes];
        what = [NSString stringWithFormat:@"%lu 个条目", (unsigned long)indices.count];
    }

    Z7Task *t = [[Z7Task alloc] init];
    t.kind = Z7TaskKindExtract;
    t.title = [NSString stringWithFormat:@"正在解压 %@", what];
    t.archivePath = self.archivePath;
    t.indices = indices;
    t.destDir = dest;
    t.overwrite = YES;
    // 解压既有归档：密码取自打开该归档时的输入，而不是压缩面板里的口令。
    Z7CompressionOptions *opts = [self currentOptions];
    opts.password = [self archivePassword];
    t.options = opts;

    __weak MainViewController *weakSelf = self;
    [self runTask:t after:^(BOOL ok, NSError *error) {
        MainViewController *me = weakSelf;
        if (!me) return;
        if (ok) {
            NSArray *s = t.statsOut;
            unsigned long long unsafeEntries = s.count > 2 ? [s[2] unsignedLongLongValue] : 0;
            unsigned long long skipped = s.count > 3 ? [s[3] unsignedLongLongValue] : 0;
            unsigned long long links = s.count > 4 ? [s[4] unsignedLongLongValue] : 0;
            NSString *extra = @"";
            if (unsafeEntries) extra = [extra stringByAppendingFormat:@"，已拦截 %llu 个不安全条目", unsafeEntries];
            if (skipped) extra = [extra stringByAppendingFormat:@"，跳过 %llu 个", skipped];
            if (links) extra = [extra stringByAppendingFormat:@"，还原 %llu 个符号链接", links];
            [me showStatus:[NSString stringWithFormat:@"解压完成%@", extra]];
            [me appendLog:[NSString stringWithFormat:@"解压完成%@\n", extra]];
        } else {
            [me showStatus:[NSString stringWithFormat:@"解压失败：%@", error.localizedDescription]];
            [me appendLog:[NSString stringWithFormat:@"解压失败：%@\n", error.localizedDescription]];
        }
    }];
}

- (void)doTest:(id)s
{
    if (!self.archivePath) return;
    Z7Task *t = [[Z7Task alloc] init];
    t.kind = Z7TaskKindTest;
    t.title = @"正在校验完整性";
    t.archivePath = self.archivePath;
    t.destDir = NSTemporaryDirectory();   // 测试模式不写盘，仅需一个合法路径
    Z7CompressionOptions *opts = [self currentOptions];
    opts.password = [self archivePassword];
    t.options = opts;

    __weak MainViewController *weakSelf = self;
    [self runTask:t after:^(BOOL ok, NSError *error) {
        MainViewController *me = weakSelf;
        if (!me) return;
        NSString *s = ok ? @"完整性校验通过"
                         : [NSString stringWithFormat:@"校验失败：%@", error.localizedDescription];
        [me showStatus:s];
        [me appendLog:[s stringByAppendingString:@"\n"]];
    }];
}

- (void)doAdd:(id)s
{
    if (!self.archivePath) return;
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = YES;
    p.canChooseDirectories = YES;
    p.allowsMultipleSelection = YES;
    p.message = @"选择要加入归档的文件或文件夹";
    if ([p runModal] != NSModalResponseOK) return;

    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *u in p.URLs) [paths addObject:u.path];

    Z7Task *t = [[Z7Task alloc] init];
    t.kind = Z7TaskKindAdd;
    t.title = [NSString stringWithFormat:@"正在添加 %lu 项", (unsigned long)paths.count];
    t.archivePath = self.archivePath;
    t.inputPaths = paths;
    // 添加既要把既有归档打开（需要它的密码），又要把新条目按同一口令加密，
    // 因此用 archivePassword：加密归档取打开时的密码，明文归档回退到面板口令。
    Z7CompressionOptions *opts = [self currentOptions];
    opts.password = [self archivePassword];
    t.options = opts;
    t.replaceExisting = (self.updateModePop.indexOfSelectedItem == 1);

    __weak MainViewController *weakSelf = self;
    NSString *reopen = self.archivePath;
    [self runTask:t after:^(BOOL ok, NSError *error) {
        MainViewController *me = weakSelf;
        if (!me) return;
        if (ok) {
            [me showStatus:t.replaceExisting ? @"已添加（同名条目已替换）" : @"已添加（同名条目已跳过）"];
            // 归档已被原子替换，必须重新打开；沿用本次会话已有的密码，
            // 免得用户为同一个归档反复输入。
            [me openArchive:reopen password:me.openPassword];
        } else {
            [me showStatus:[NSString stringWithFormat:@"添加失败：%@", error.localizedDescription]];
            [me appendLog:[NSString stringWithFormat:@"添加失败：%@\n", error.localizedDescription]];
        }
    }];
}

#pragma mark 删除（§6.4）

- (void)doDelete:(id)s
{
    if (!self.archivePath) return;
    NSArray<Z7Node *> *nodes = [self selectedNodes];
    if (!nodes.count) { NSBeep(); [self showStatus:@"请先选择要删除的条目"]; return; }

    // 删除是"解压保留项 → 重建"，整档重写，必须让用户明确知晓
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"删除 %lu 个条目？", (unsigned long)nodes.count];
    alert.informativeText = @"归档将被重新打包：保留下来的条目会按当前压缩参数重新压缩。"
                            @"此操作不可撤销。";
    [alert addButtonWithTitle:@"删除"];
    [alert addButtonWithTitle:@"取消"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    if (self.archiveHeaderEncrypted && ![self archivePassword].length) {
        [self showStatus:@"该归档已加密文件名，删除需要密码"];
        __weak MainViewController *weakSelf = self;
        [self promptPasswordWithMessage:@"该归档已加密文件名，删除会重新打包，需要密码。"
                             completion:^(NSString *pw) {
            if (pw.length) { weakSelf.openPassword = pw; [weakSelf doDelete:nil]; }
        }];
        return;
    }

    NSMutableArray<NSString *> *arcPaths = [NSMutableArray array];
    for (Z7Node *n in nodes) [arcPaths addObject:n.path];

    Z7Task *t = [[Z7Task alloc] init];
    t.kind = Z7TaskKindRemove;
    t.title = [NSString stringWithFormat:@"正在删除 %lu 个条目", (unsigned long)arcPaths.count];
    t.archivePath = self.archivePath;
    t.arcPaths = arcPaths;
    Z7CompressionOptions *opts = [self currentOptions];
    opts.password = [self archivePassword];
    t.options = opts;

    __weak MainViewController *weakSelf = self;
    NSString *reopen = self.archivePath;
    [self runTask:t after:^(BOOL ok, NSError *error) {
        MainViewController *me = weakSelf;
        if (!me) return;
        if (ok) {
            [me showStatus:@"删除完成"];
            [me openArchive:reopen password:me.openPassword];
        } else {
            NSString *msg = [NSString stringWithFormat:@"删除失败：%@", error.localizedDescription];
            [me showStatus:msg];
            [me appendLog:[msg stringByAppendingString:@"\n"]];
        }
    }];
}

#pragma mark 压缩

- (void)doCompressPick:(id)s
{
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = YES;
    p.canChooseDirectories = YES;
    p.allowsMultipleSelection = YES;
    p.message = @"选择要压缩的文件或文件夹";
    if ([p runModal] != NSModalResponseOK) return;
    [self compressURLs:p.URLs];
}

- (void)compressURLs:(NSArray<NSURL *> *)urls
{
    if (!urls.count) return;
    NSString *fmt = [self selectedFormat];
    NSString *base = urls.count == 1 ? urls[0].lastPathComponent : @"归档";
    NSString *dir  = urls[0].URLByDeletingLastPathComponent.path ?: NSHomeDirectory();

    NSSavePanel *sp = [NSSavePanel savePanel];
    sp.message = @"保存归档";
    sp.nameFieldStringValue = [NSString stringWithFormat:@"%@.%@", base, fmt];
    sp.directoryURL = [NSURL fileURLWithPath:dir];
    if ([sp runModal] != NSModalResponseOK) return;

    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *u in urls) [paths addObject:u.path];

    Z7Task *t = [[Z7Task alloc] init];
    t.kind = Z7TaskKindCreate;
    t.title = [NSString stringWithFormat:@"正在压缩 %lu 项", (unsigned long)paths.count];
    t.archivePath = sp.URL.path;
    t.inputPaths = paths;
    t.options = [self currentOptions];

    __weak MainViewController *weakSelf = self;
    NSString *dest = sp.URL.path;
    [self runTask:t after:^(BOOL ok, NSError *error) {
        MainViewController *me = weakSelf;
        if (!me) return;
        if (ok) {
            [me showStatus:@"压缩完成"];
            [me appendLog:@"压缩完成\n"];
            // 新归档用面板口令加密，因此直接把该口令交给打开流程，
            // 而不是让用户立刻为刚建的归档再输一次。
            NSString *pw = me.password.stringValue.length ? me.password.stringValue : nil;
            [me openArchive:dest password:pw];
        } else {
            NSString *msg = [NSString stringWithFormat:@"压缩失败：%@", error.localizedDescription];
            [me showStatus:msg];
            [me appendLog:[msg stringByAppendingString:@"\n"]];
        }
    }];
}

#pragma mark 拖放

- (void)dropView:(id)view didReceiveURLs:(NSArray<NSURL *> *)urls
{
    if (urls.count == 1) {
        NSNumber *isDir = nil;
        [urls[0] getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:NULL];
        if (!isDir.boolValue) {
            [self openArchive:urls[0].path];
            return;
        }
    }
    [self compressURLs:urls];
}

#pragma mark NSOutlineViewDataSource

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item
{
    if (item == nil) return (NSInteger)self.displayRoots.count;
    Z7Node *n = item;
    return self.filtering ? 0 : (NSInteger)n.children.count;
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item
{
    if (item == nil) return self.displayRoots[(NSUInteger)index];
    Z7Node *n = item;
    return n.children[(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item
{
    if (item == nil) return NO;
    Z7Node *n = item;
    return !self.filtering && n.children.count > 0;
}

#pragma mark NSOutlineViewDelegate

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item
{
    Z7Node *n = item;
    NSString *ident = col.identifier;
    NSTableCellView *cell = [ov makeViewWithIdentifier:ident owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = ident;

        NSTextField *tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.editable = NO; tf.bordered = NO; tf.drawsBackground = NO;
        tf.textColor = [NSColor labelColor];
        tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
        tf.font = [NSFont systemFontOfSize:12];
        [cell addSubview:tf];
        cell.textField = tf;
        // 只固定右边界与垂直居中；左边界分两种情形给出——「名称」列跟在图标
        // 之后，其余列直接贴单元格左边。二者互斥，绝不叠加：同一个 attribute
        // 上挂两条 required 约束会被求解器丢掉一条，表现为文字压住图标。
        [NSLayoutConstraint activateConstraints:@[
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];

        if ([ident isEqualToString:@"名称"]) {
            NSImageView *iv = [[NSImageView alloc] initWithFrame:NSZeroRect];
            iv.translatesAutoresizingMaskIntoConstraints = NO;
            iv.imageScaling = NSImageScaleProportionallyUpOrDown;
            iv.contentTintColor = [NSColor secondaryLabelColor];
            [cell addSubview:iv];
            cell.imageView = iv;
            [NSLayoutConstraint activateConstraints:@[
                [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
                [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
                [iv.widthAnchor constraintEqualToConstant:16],
                [iv.heightAnchor constraintEqualToConstant:16],
                [tf.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:4],
            ]];
        } else {
            [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2].active = YES;
        }
    }

    NSString *ident2 = col.identifier;
    if ([ident2 isEqualToString:@"名称"]) {
        cell.textField.stringValue = [n displayName];
        // 真实文件类型图标：复用系统 Finder 图标，按扩展名取，深浅色自适应。
        NSImage *icon = FileIcon(n.name, n.isDirectory, n.isSymLink);
        cell.imageView.image = icon;
        cell.imageView.hidden = (icon == nil);
        cell.textField.textColor = [NSColor labelColor];
    } else if ([ident2 isEqualToString:@"大小"]) {
        cell.textField.stringValue = HumanSize(n.size, n.hasSize, n.isDirectory);
        cell.textField.alignment = NSTextAlignmentRight;
    } else if ([ident2 isEqualToString:@"压缩后"]) {
        cell.textField.stringValue = HumanSize(n.packed, n.hasPacked, n.isDirectory);
        cell.textField.alignment = NSTextAlignmentRight;
    } else if ([ident2 isEqualToString:@"压缩率"]) {
        cell.textField.stringValue = n.isDirectory ? @"—" : HumanRatio(n.ratio);
        cell.textField.alignment = NSTextAlignmentRight;
    } else if ([ident2 isEqualToString:@"修改时间"]) {
        cell.textField.stringValue = DateText(n.modified);
    } else if ([ident2 isEqualToString:@"CRC"]) {
        cell.textField.stringValue = n.crcText.length ? n.crcText : @"—";
        cell.textField.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    } else if ([ident2 isEqualToString:@"方法"]) {
        cell.textField.stringValue = n.method.length ? n.method : @"—";
    } else if ([ident2 isEqualToString:@"属性"]) {
        cell.textField.stringValue = n.attributeText.length ? n.attributeText : @"—";
        cell.textField.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    }
    (void)ident;
    return cell;
}

- (void)outlineView:(NSOutlineView *)ov sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)old
{
    NSSortDescriptor *sd = ov.sortDescriptors.firstObject;
    if (!sd) return;
    NSString *key = sd.key;
    BOOL asc = sd.ascending;

    NSComparator cmp = ^NSComparisonResult(Z7Node *a, Z7Node *b) {
        if ([key isEqualToString:@"名称"]) {
            if (a.isDirectory != b.isDirectory) return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
            NSComparisonResult r = [a.name localizedStandardCompare:b.name];
            return asc ? r : -r;
        }
        double av = 0, bv = 0;
        if ([key isEqualToString:@"大小"]) { av = (double)a.size; bv = (double)b.size; }
        else if ([key isEqualToString:@"压缩后"]) { av = (double)a.packed; bv = (double)b.packed; }
        else if ([key isEqualToString:@"压缩率"]) { av = a.ratio; bv = b.ratio; }
        else if ([key isEqualToString:@"修改时间"]) {
            av = a.modified ? a.modified.timeIntervalSinceReferenceDate : 0;
            bv = b.modified ? b.modified.timeIntervalSinceReferenceDate : 0;
        }
        else if ([key isEqualToString:@"CRC"]) {
            av = (double)strtoul(a.crcText.UTF8String, NULL, 16);
            bv = (double)strtoul(b.crcText.UTF8String, NULL, 16);
        }
        else if ([key isEqualToString:@"方法"]) {
            NSComparisonResult r = [(a.method ?: @"") localizedStandardCompare:(b.method ?: @"")];
            return asc ? r : -r;
        }
        else if ([key isEqualToString:@"属性"]) {
            NSComparisonResult r = [(a.attributeText ?: @"") localizedStandardCompare:(b.attributeText ?: @"")];
            return asc ? r : -r;
        }
        if (av == bv) return NSOrderedSame;
        BOOL less = av < bv;
        return (less == asc) ? NSOrderedAscending : NSOrderedDescending;
    };

    // 用显式栈逐层排序（同 BuildTree，避免递归 block 自捕获）
    NSMutableArray<Z7Node *> *rootsMut = [self.roots mutableCopy];
    NSMutableArray<Z7Node *> *stack = [NSMutableArray arrayWithArray:rootsMut];
    while (stack.count) {
        Z7Node *n = stack.lastObject;
        [stack removeLastObject];
        [n.children sortUsingComparator:cmp];
        [stack addObjectsFromArray:n.children];
    }
    [rootsMut sortUsingComparator:cmp];
    self.roots = rootsMut;
    if (self.filtering) {
        NSMutableArray<Z7Node *> *hits = [self.displayRoots mutableCopy];
        [hits sortUsingComparator:cmp];
        self.displayRoots = hits;
    } else {
        self.displayRoots = self.roots;
    }
    [self.outline reloadData];
}

#pragma mark 空格预览（§6.5）

- (void)outlineDidPressSpace
{
    [self doPreview:nil];
}

- (void)outlineDidPressDelete
{
    [self doDelete:nil];
}

- (void)doPreview:(id)s
{
    NSArray<Z7Node *> *nodes = [self selectedNodes];
    if (!nodes.count) return;
    Z7Node *n = nodes.firstObject;
    if (n.isDirectory) { NSBeep(); return; }
    if (n.index == UINT32_MAX) return;

    NSString *tmp = [[Z7TempRegistry shared] newFileURLForName:
                     [NSString stringWithFormat:@"%u_%@", n.index, n.name]];
    if (!tmp) return;

    Z7Task *t = [[Z7Task alloc] init];
    t.kind = Z7TaskKindExtract;
    t.title = [NSString stringWithFormat:@"正在准备预览 %@", n.name];
    t.archivePath = self.archivePath;
    t.indices = @[@(n.index)];
    t.destDir = [tmp stringByDeletingLastPathComponent];
    Z7CompressionOptions *opts = [self currentOptions];
    opts.password = [self archivePassword];
    t.options = opts;

    __weak MainViewController *weakSelf = self;
    [self runTask:t after:^(BOOL ok, NSError *error) {
        MainViewController *me = weakSelf;
        if (!me) return;
        NSString *produced = [t.destDir stringByAppendingPathComponent:n.name];
        if (!ok || ![[NSFileManager defaultManager] fileExistsAtPath:produced]) {
            [me showStatus:[NSString stringWithFormat:@"预览失败：%@", error.localizedDescription ?: @"无法提取条目"]];
            return;
        }
        me.previewURL = [NSURL fileURLWithPath:produced];
        [me showStatus:[NSString stringWithFormat:@"预览 %@", n.name]];
        [me togglePreviewPanel:nil];
    }];
}

- (BOOL)acceptsPreviewPanelControl:(QLPreviewPanel *)panel { return YES; }

- (void)beginPreviewPanelControl:(QLPreviewPanel *)panel
{
    panel.dataSource = self;
    panel.delegate = self;
}

- (void)endPreviewPanelControl:(QLPreviewPanel *)panel
{
    panel.dataSource = nil;
    panel.delegate = nil;
}

- (NSInteger)numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel *)panel
{
    return self.previewURL ? 1 : 0;
}

- (id<QLPreviewItem>)previewPanel:(QLPreviewPanel *)panel previewItemAtIndex:(NSInteger)index
{
    return self.previewURL;
}

- (void)togglePreviewPanel:(id)sender
{
    if ([QLPreviewPanel sharedPreviewPanelExists] && [[QLPreviewPanel sharedPreviewPanel] isVisible]) {
        [[QLPreviewPanel sharedPreviewPanel] orderOut:nil];
    } else {
        [[QLPreviewPanel sharedPreviewPanel] makeKeyAndOrderFront:nil];
    }
}

#pragma mark 拖出提取（§6.6）

- (id<NSPasteboardWriting>)outlineView:(NSOutlineView *)ov pasteboardWriterForItem:(id)item
{
    Z7Node *n = item;
    if (n.isDirectory || n.index == UINT32_MAX) return nil;
    NSFilePromiseProvider *p = [[NSFilePromiseProvider alloc] initWithFileType:@"public.data"
                                                                     delegate:self];
    p.userInfo = n.path;
    return p;
}

- (NSString *)filePromiseProvider:(NSFilePromiseProvider *)provider fileNameForType:(NSString *)fileType
{
    NSString *arcPath = provider.userInfo;
    return arcPath.lastPathComponent ?: @"item";
}

- (void)filePromiseProvider:(NSFilePromiseProvider *)provider
         writePromiseToURL:(NSURL *)url
         completionHandler:(void (^)(NSError *error))completionHandler
{
    NSString *arcPath = provider.userInfo;
    if (!arcPath.length || !self.archivePath) {
        completionHandler([NSError errorWithDomain:Z7ErrorDomain code:-1 userInfo:
                          @{NSLocalizedDescriptionKey: @"缺少条目信息"}]);
        return;
    }
    // 通过桥接层单条提取（§6.6）：不落地中间目录，直接写目标
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        Z7Archive *a = [Z7Archive openPath:self.archivePath
                                  password:([self archivePassword].length ? [self archivePassword] : nil)
                                  callback:nil error:&err];
        if (!a) { completionHandler(err); return; }
        uint32_t target = UINT32_MAX;
        for (Z7Item *it in [a allItems]) {
            if ([it.path isEqualToString:arcPath]) { target = it.index; break; }
        }
        if (target == UINT32_MAX) {
            completionHandler([NSError errorWithDomain:Z7ErrorDomain code:-1 userInfo:
                              @{NSLocalizedDescriptionKey: @"归档中找不到该条目"}]);
            return;
        }
        BOOL ok = [a extractItemAtIndex:target toFile:url.path callback:nil error:&err];
        completionHandler(ok ? nil : err);
    });
}

#pragma mark 目标目录记忆（§8.2 Security-Scoped Bookmark）

- (void)rememberDestination:(NSString *)path
{
    if (!path.length) return;
    NSURL *u = [NSURL fileURLWithPath:path];
    NSError *e = nil;
    // 沙盒场景下必须存 bookmark 才能在下次会话继续写入；非沙盒时该调用也安全。
    NSData *bm = [u bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
             includingResourceValuesForKeys:nil relativeToURL:nil error:&e];
    if (!bm) {
        bm = [u bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:&e];
    }
    if (bm) {
        [[NSUserDefaults standardUserDefaults] setObject:bm forKey:@"Z7LastDestinationBookmark"];
    }
}

@end

#pragma mark - 关于 / 致谢（§2.3 许可）

@interface Z7AboutController : NSObject
+ (void)showLicenses;
@end

@implementation Z7AboutController

+ (NSString *)licensesText
{
    NSBundle *b = [NSBundle mainBundle];
    NSString *path = [b pathForResource:@"THIRD_PARTY" ofType:@"md"];
    if (path) {
        NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        if (s.length) return s;
    }
    NSString *shortPath = [b pathForResource:@"THIRD_PARTY" ofType:@"txt"];
    if (shortPath) {
        NSString *s = [NSString stringWithContentsOfFile:shortPath encoding:NSUTF8StringEncoding error:NULL];
        if (s.length) return s;
    }
    return @"未找到 THIRD_PARTY 文档。\n\n本程序内嵌 7-Zip 引擎（lib7z.dylib），"
            "依 GNU LGPL-2.1-or-later 分发；该库可被用户替换。\n"
            "完整许可文本见安装包内的 LICENSE / COPYING 与 7-Zip 源码目录 DOC/。";
}

+ (void)showLicenses
{
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 720, 560)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
          backing:NSBackingStoreBuffered defer:NO];
    w.title = @"致谢与许可";
    w.releasedWhenClosed = NO;

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:w.contentView.bounds];
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    sv.hasVerticalScroller = YES;

    NSTextView *tv = [[NSTextView alloc] initWithFrame:sv.bounds];
    tv.editable = NO;
    tv.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    tv.string = [self licensesText];
    tv.autoresizingMask = NSViewWidthSizable;
    sv.documentView = tv;
    [w.contentView addSubview:sv];

    [w center];
    [w makeKeyAndOrderFront:nil];
    // 阻止窗口被释放
    static NSMutableArray *keep = nil;
    if (!keep) keep = [NSMutableArray array];
    [keep addObject:w];
}

@end

#pragma mark - app delegate

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) MainViewController *vc;
@end

@implementation AppDelegate

- (void)buildMenu
{
    NSMenu *bar = [[NSMenu alloc] init];

    // 应用程序菜单
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [bar addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"关于 7-Zip" action:@selector(showAbout:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    // ⌘, 是 macOS 上「打开设置」的固定位置，压缩选项属于这一类。
    [appMenu addItemWithTitle:@"压缩选项…" action:@selector(showOptions:) keyEquivalent:@","];
    [appMenu addItemWithTitle:@"致谢与许可…" action:@selector(showLicenses:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"服务" action:nil keyEquivalent:@""];
    NSMenu *services = [[NSMenu alloc] init];
    [NSApp setServicesMenu:services];
    appMenu.itemArray.lastObject.submenu = services;
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"隐藏 7-Zip" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"退出 7-Zip" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    // 文件
    NSMenuItem *fileItem = [[NSMenuItem alloc] init];
    [bar addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"文件"];
    [fileMenu addItemWithTitle:@"打开归档…" action:@selector(doOpen:) keyEquivalent:@"o"];
    [fileMenu addItemWithTitle:@"新建归档…" action:@selector(doCompressPick:) keyEquivalent:@"n"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"解压到…" action:@selector(doExtract:) keyEquivalent:@"e"];
    [fileMenu addItemWithTitle:@"添加文件…" action:@selector(doAdd:) keyEquivalent:@"d"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"测试归档" action:@selector(doTest:) keyEquivalent:@"t"];
    fileItem.submenu = fileMenu;

    // 编辑
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [bar addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    [editMenu addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"拷贝" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenu addItemWithTitle:@"查找" action:@selector(performFindPanelAction:) keyEquivalent:@"f"];
    editItem.submenu = editMenu;

    // 操作
    NSMenuItem *arcItem = [[NSMenuItem alloc] init];
    [bar addItem:arcItem];
    NSMenu *arcMenu = [[NSMenu alloc] initWithTitle:@"操作"];
    [arcMenu addItemWithTitle:@"删除所选" action:@selector(doDelete:) keyEquivalent:@""];
    [arcMenu addItemWithTitle:@"预览" action:@selector(doPreview:) keyEquivalent:@" "];
    [arcMenu addItem:[NSMenuItem separatorItem]];
    [arcMenu addItemWithTitle:@"停止当前任务" action:@selector(doCancel:) keyEquivalent:@"."];
    arcItem.submenu = arcMenu;

    // 显示
    NSMenuItem *viewItem = [[NSMenuItem alloc] init];
    [bar addItem:viewItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"显示"];
    [viewMenu addItemWithTitle:@"显示/隐藏日志" action:@selector(toggleLog:) keyEquivalent:@"l"];
    [viewMenu addItemWithTitle:@"清空日志" action:@selector(clearLog:) keyEquivalent:@""];
    viewItem.submenu = viewMenu;

    // 窗口
    NSMenuItem *winItem = [[NSMenuItem alloc] init];
    [bar addItem:winItem];
    NSMenu *winMenu = [[NSMenu alloc] initWithTitle:@"窗口"];
    [winMenu addItemWithTitle:@"最小化" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [winMenu addItemWithTitle:@"缩放" action:@selector(performZoom:) keyEquivalent:@""];
    winItem.submenu = winMenu;

    NSApp.mainMenu = bar;
}

- (void)showAbout:(id)s
{
    NSDictionary *opts = @{
        NSAboutPanelOptionApplicationName: @"7-Zip",
        NSAboutPanelOptionApplicationVersion: [Z7Engine engineVersion],
        NSAboutPanelOptionVersion: [NSString stringWithFormat:@"引擎 %@ · 内嵌 lib7z.dylib",
                                    [Z7Engine engineVersion]],
        NSAboutPanelOptionCredits: [[NSAttributedString alloc]
            initWithString:@"7-Zip 由 Igor Pavlov 开发，依 GNU LGPL-2.1-or-later 分发。\n"
                           @"本移植内嵌引擎动态库，该库可被用户替换。\n"
                           @"许可与第三方归属见「致谢与许可…」。"],
    };
    [NSApp orderFrontStandardAboutPanelWithOptions:opts];
}

- (void)showLicenses:(id)s
{
    [Z7AboutController showLicenses];
}

- (void)applicationDidFinishLaunching:(NSNotification *)n
{
    [self buildMenu];

    // §8.2 SIGTERM / SIGINT 清理：登记表在退出前统一释放临时产物
    signal(SIGTERM, Z7SignalHandler);
    signal(SIGINT, Z7SignalHandler);
    atexit_b(^{ [[Z7TempRegistry shared] cleanupAll]; });

    self.vc = [[MainViewController alloc] init];
    NSRect frame = NSMakeRect(0, 0, 1040, 700);
    self.window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                   NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
          backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"7-Zip";
    self.window.backgroundColor = [NSColor windowBackgroundColor];
    // 统一工具栏：标题与工具栏同处一行，内容区从工具栏下方开始。配合窗口
    // 自身的 contentView，不会再出现"控件压在标题栏上"的叠影。
    self.window.toolbarStyle = NSWindowToolbarStyleUnified;
    // 先钉下最小尺寸，再挂 contentViewController：否则窗口会按内容的自适应
    // 尺寸收缩（内容区现在是显式 frame，不再参与约束，窗口宽度无从约束）。
    self.window.contentMinSize = NSMakeSize(880, 560);
    self.window.contentViewController = self.vc;
    self.window.toolbar = self.vc.toolbar;
    self.window.minSize = NSMakeSize(880, 560);
    // setFrameAutosaveName: 返回是否成功恢复了上次保存的尺寸。首次运行（没有
    // 保存记录）时窗口会停在内容自适应得到的最小尺寸上，这里显式给回默认尺寸。
    if (![self.window setFrameAutosaveName:@"7ZipMainWindow"]) {
        [self.window setContentSize:NSMakeSize(1040, 700)];
    }
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];

    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }

- (void)applicationWillTerminate:(NSNotification *)n
{
    [[Z7TempRegistry shared] cleanupAll];
}

- (void)openPathOnLaunch:(NSString *)path
{
    [self.vc openArchive:path];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)application:(NSApplication *)app openFiles:(NSArray<NSString *> *)filenames
{
    for (NSString *f in filenames) {
        [self.vc openArchive:f];
        break;      // 只打开第一个
    }
    [app replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

#pragma mark 服务

- (void)compressWithSevenZip:(NSPasteboard *)pboard
                    userData:(NSString *)userData
                       error:(NSString **)error
{
    NSArray *urls = [pboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (!urls.count) { if (error) *error = @"没有收到文件"; return; }
    [self.vc compressURLs:urls];
}

- (void)extractWithSevenZip:(NSPasteboard *)pboard
                   userData:(NSString *)userData
                      error:(NSString **)error
{
    NSArray *urls = [pboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (!urls.count) { if (error) *error = @"没有收到归档"; return; }
    [self.vc openArchive:[urls[0] path]];
    [self.vc performSelector:@selector(doExtract:) withObject:nil afterDelay:0.4];
}

@end

#pragma mark - main

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        // 允许命令行直接投递归档：
        //   7-Zip.app/Contents/MacOS/7-Zip <archive>
        for (int i = 1; i < argc; i++) {
            NSString *a = [NSString stringWithUTF8String:argv[i]];
            if (a.length && ![a hasPrefix:@"-"]) {
                [delegate performSelector:@selector(openPathOnLaunch:)
                               withObject:a
                               afterDelay:0.4];
                break;
            }
        }

        [app run];
    }
    return 0;
}
