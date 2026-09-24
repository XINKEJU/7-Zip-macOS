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
// 长任务的完成告知（通知中心）。系统 10.14+ 自带，部署目标 11.0 覆盖得住；
// 运行时若不可用会自动降级，见 Z7SystemFeedback 里的探测。
#import <UserNotifications/UserNotifications.h>
#import <signal.h>
#import <unistd.h>
#import <stdlib.h>

#import "SevenZipEngineObjC.h"

#pragma mark - 常量与小工具

/// 无进度超时（技术方案 §7.4）：5 分钟
static const NSTimeInterval kNoProgressTimeout = 300.0;
/// 进度节流间隔（技术方案 §7.2）：50ms
static const NSTimeInterval kProgressThrottle = 0.05;

/// 引擎调用的全局锁。
///
/// 多窗口架构下每个窗口有自己的任务队列，但**引擎本身不是为并发会话设计的**：
/// 整个 SevenZipEngine.cpp 里没有任何跨调用的互斥原语（只有任务自己的取消标志是
/// atomic），而格式注册表、编解码器表一类全局状态是首次访问时惰性初始化的——两个
/// 线程同时踏进那条路径就是在赌运气。7-Zip 的 COM 接口也从未声明线程安全。
///
/// 所以这里做全局串行：窗口、界面、任务队列都是并行的，真到调用引擎那一刻排成一列。
/// 用户仍然可以在任意窗口随时发起操作（不必等前一个任务结束），也能在别的窗口浏览
/// 已经载入的归档——那不需要引擎。付出的是「同一时刻只有一个引擎任务在跑」，换来的是
/// 不必赌上游库的线程安全。
static NSLock *Z7EngineLock(void)
{
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

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

#pragma mark - 最近打开的归档

/// 「最近使用」列表存在 UserDefaults 里。
///
/// 应用自己的「文件 › 打开最近使用」与程序坞右键菜单都读这份列表，**不用**
/// NSDocumentController 的 recentDocumentURLs 去喂它们：那是给 NSDocument 架构
/// 准备的，本应用不是 document-based（窗口与控制器自管），拿它填菜单只会得到
/// 一个永远为空的菜单。两条线各司其职：
///   * 本文件里的数组 → 应用自己的两个菜单（可控顺序、可控条数、可清除）；
///   * Z7NoteRecentPath 里顺带调用的 noteNewRecentDocumentURL: → 只为了让归档
///     同时出现在系统「苹果菜单 › 最近使用的项目」里（那是系统自己维护的列表，
///     应用只能投递、不能读改）。
static NSString * const kZ7RecentKey = @"Z7RecentArchives";
static const NSUInteger kZ7RecentLimit = 10;

static NSArray<NSString *> *Z7RecentPaths(void)
{
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:kZ7RecentKey];
    return [a isKindOfClass:NSArray.class] ? a : @[];
}

static void Z7NoteRecentPath(NSString *path)
{
    if (!path.length) return;
    NSMutableArray<NSString *> *a = [Z7RecentPaths() mutableCopy];
    [a removeObject:path];      // 重复打开同一个归档时把它提到最前，而不是留两条
    [a insertObject:path atIndex:0];
    while (a.count > kZ7RecentLimit) [a removeLastObject];
    [[NSUserDefaults standardUserDefaults] setObject:a forKey:kZ7RecentKey];

    // 同时投递给系统，让归档出现在「苹果菜单 › 最近使用的项目」——这是 macOS
    // 上跨应用统一的最近文件入口，用户在那里就能直接选中它。
    [[NSDocumentController sharedDocumentController]
        noteNewRecentDocumentURL:[NSURL fileURLWithPath:path]];
}

static void Z7ForgetRecentPath(NSString *path)
{
    if (!path.length) return;
    NSMutableArray<NSString *> *a = [Z7RecentPaths() mutableCopy];
    [a removeObject:path];
    [[NSUserDefaults standardUserDefaults] setObject:a forKey:kZ7RecentKey];
}

static void Z7ClearRecentPaths(void)
{
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kZ7RecentKey];
    [[NSDocumentController sharedDocumentController] clearRecentDocuments:nil];
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

#pragma mark - 系统级任务反馈（程序坞徽标 / 通知 / 提示音）

/// 把「长任务在跑 / 跑完了 / 失败了」告诉系统和用户。
///
/// 为什么需要它：引擎调用是同步阻塞的，压缩几个 GB 会跑好几分钟。用户不会一直盯着
/// 窗口，切走之后如果没有反馈，就只能反复切回来查看——这不是 macOS 应用该有的样子。
/// 系统有三条现成的通道，这里按「打扰程度」从轻到重使用：
///
///   * 程序坞徽标（badgeLabel）——不打断、随时可见：单任务报百分比，多任务报任务数；
///   * 请求注意（requestUserAttention:）——图标弹跳，把用户叫回来；
///   * 通知中心——用户人已经在别的应用里时的正式告知。
///
/// 通知中心这一条在 ad-hoc 签名下不保证可用：UNUserNotificationCenter 拿不到有效的
/// bundle 代理时会直接抛异常。因此整条路径都带探测与降级，失败即永久退回
/// 「弹跳 + 提示音」——那两条在任何签名状态下都有效。
@interface Z7SystemFeedback : NSObject

+ (instancetype)shared;

/// 任务开始：程序坞徽标进入忙碌态。
- (void)taskBegan;
/// 任务进度（0.0–1.0；负数表示进度未知）。只在单任务时更新徽标。
- (void)taskProgress:(double)fraction;
/// 任务结束。仅当应用不在前台时才提醒——用户就在眼前时弹跳与通知都只是干扰。
- (void)taskEndedWithTitle:(NSString *)title success:(BOOL)ok;

@end

@implementation Z7SystemFeedback {
    NSInteger _running;      // 正在跑的任务数（多窗口架构下可能 > 1）
    NSInteger _lastPercent;  // 徽标上最后一次显示的整数百分比
    BOOL _probed;
    BOOL _notificationsUsable;
}

+ (instancetype)shared
{
    static Z7SystemFeedback *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[Z7SystemFeedback alloc] init]; });
    return s;
}

- (instancetype)init
{
    self = [super init];
    if (self) _lastPercent = NSNotFound;
    return self;
}

#pragma mark 程序坞徽标

- (void)taskBegan
{
    _running++;
    _lastPercent = NSNotFound;
    [self refreshBadge];
    [self prepareNotificationsIfNeeded];
}

- (void)taskProgress:(double)fraction
{
    if (_running != 1) return;      // 多任务并行时徽标改报任务数，见 refreshBadge
    if (fraction < 0.0) return;
    NSInteger pct = (NSInteger)(fraction * 100.0);
    // 只在整数百分比变化时碰程序坞。进度回调按毫秒级触发，不节流会把 Dock 拖垮。
    if (pct == _lastPercent) return;
    _lastPercent = pct;
    [self refreshBadge];
}

- (void)taskEndedWithTitle:(NSString *)title success:(BOOL)ok
{
    if (_running > 0) _running--;
    _lastPercent = NSNotFound;
    [self refreshBadge];

    if (NSApp.isActive) return;     // 用户就在本应用里看着，不需要任何提醒

    if (ok) {
        // 成功：图标跳一下就够了，不要缠着用户。
        [NSApp requestUserAttention:NSInformationalRequest];
    } else {
        // 失败：需要用户回来处理，所以持续弹跳 + 系统警告音。
        NSBeep();
        [NSApp requestUserAttention:NSCriticalRequest];
    }
    [self postNotification:title success:ok];
}

- (void)refreshBadge
{
    NSDockTile *tile = NSApp.dockTile;
    if (!tile) return;
    if (_running <= 0) { tile.badgeLabel = nil; return; }
    // 并发多个任务时百分比没有意义，改报任务数；单个任务时百分比信息量更大。
    tile.badgeLabel = (_running == 1 && _lastPercent != NSNotFound)
        ? [NSString stringWithFormat:@"%ld%%", (long)_lastPercent]
        : [NSString stringWithFormat:@"%ld", (long)_running];
}

#pragma mark 通知中心（可用性探测 + 降级）

- (void)prepareNotificationsIfNeeded
{
    if (_probed) return;
    _probed = YES;
    @try {
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        if (!center) return;
        _notificationsUsable = YES;
        // 授权对话框由系统只在首次弹一次。放在「用户刚发起一个任务」时请求，
        // 比在启动瞬间请求更有上下文。
        [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                              completionHandler:^(BOOL granted, NSError *err) {
            (void)granted; (void)err;   // 未授权时后续请求被系统静默丢弃，属可接受降级
        }];
    } @catch (NSException *ex) {
        // 未签名构建下 currentNotificationCenter 会抛 NSInternalInconsistencyException。
        _notificationsUsable = NO;
    }
}

- (void)postNotification:(NSString *)title success:(BOOL)ok
{
    if (!_notificationsUsable) return;
    UNMutableNotificationContent *c = [[UNMutableNotificationContent alloc] init];
    c.title = ok ? @"任务已完成" : @"任务失败";
    c.body = title.length ? title : @"7-Zip";
    if (!ok) c.sound = [UNNotificationSound defaultSound];

    UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:
        [NSString stringWithFormat:@"org.7-zip.macos.app.task.%ld",
         (long)([[NSDate date] timeIntervalSince1970] * 1000)] content:c trigger:nil];
    @try {
        [[UNUserNotificationCenter currentNotificationCenter]
            addNotificationRequest:req withCompletionHandler:^(NSError *err) { (void)err; }];
    } @catch (NSException *ex) {
        _notificationsUsable = NO;
    }
}

@end

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
/// 建包成功后立即用同一个引擎回读校验一遍（面板上的「验证压缩完整性」）
@property (nonatomic, assign) BOOL verifyAfterCreate;

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
    if (![Z7Engine createArchive:self.archivePath
                       fromPaths:self.inputPaths
                         options:self.options
                        callback:self
                           error:error]) {
        return NO;
    }
    if (!self.verifyAfterCreate) return YES;

    // 「验证压缩完整性」：用同一个引擎把刚建好的包回读校验一遍（testMode，不写盘）。
    NSError *verr = nil;
    Z7Archive *a = [Z7Archive openPath:self.archivePath
                              password:(self.options.password.length ? self.options.password : nil)
                              callback:self
                                 error:&verr];
    if (!a) {
        if (error) *error = verr ?: [NSError errorWithDomain:Z7ErrorDomain code:-1 userInfo:
                                     @{NSLocalizedDescriptionKey: @"归档已生成，但无法重新打开校验"}];
        return NO;
    }
    self.archive = a;
    if (![a extractItems:nil to:@"" testMode:YES overwrite:NO atomicFiles:NO
             createLinks:NO callback:self error:&verr]) {
        if (error) *error = verr ?: [NSError errorWithDomain:Z7ErrorDomain code:-1 userInfo:
                                     @{NSLocalizedDescriptionKey: @"完整性校验未通过"}];
        return NO;
    }
    return YES;
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
    // 只对「至少含一个文件 URL」的拖动给出接受反馈。旧实现无条件返回 Copy 并高亮，
    // 于是拖一段文本或一张图进来时整块内容区都会亮起边框、放开却什么都不发生——
    // 反馈与实际行为对不上。先验内容再表态。
    NSArray *urls = [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (!urls.count) return NSDragOperationNone;
    self.highlighted = YES;
    self.needsDisplay = YES;
    return NSDragOperationCopy;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender
{
    // 必须与 draggingEntered: 保持同一判断。NSView 默认实现是「全部接受」，
    // 只改写 draggingEntered: 的话，指针一移动就被默认值覆盖回接受。
    return [self draggingEntered:sender];
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

#pragma mark - 分组卡片（Keka 风格压缩面板的分组容器）

/// 浅色下是一张白色卡片，深色下比弹层底色略亮，圆角 10。语义色在深色下没有
/// 「比弹层更亮」的档位（controlBackgroundColor 反而更暗），故按外观解析后
/// 自己给一层白，保证两种外观下都是「卡片浮在底色之上」的层次。
@interface Z7CardView : NSView
@end

@implementation Z7CardView

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 10;
        self.layer.masksToBounds = YES;
        [self z7_applyFill];
    }
    return self;
}

- (void)viewDidChangeEffectiveAppearance
{
    [super viewDidChangeEffectiveAppearance];
    [self z7_applyFill];
}

- (void)z7_applyFill
{
    NSAppearanceName name = [self.effectiveAppearance bestMatchFromAppearancesWithNames:
                             @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    BOOL dark = [name isEqualToString:NSAppearanceNameDarkAqua];
    NSColor *fill = dark ? [NSColor colorWithSRGBRed:1.0 green:1.0 blue:1.0 alpha:0.07]
                         : [NSColor whiteColor];
    self.layer.backgroundColor = fill.CGColor;
}

@end

/// 面板底色。与状态栏同一取舍：不用弹层自带的玻璃材质——材质会透出弹层背后的
/// 窗口与桌面，浅色外观下前景文字的对比度不可控；直接用 windowBackgroundColor
/// 绘制，浅色/深色下都与系统窗口背景一致（弹层会把内容裁进自己的圆角里）。
@interface Z7PanelView : NSView
@end

@implementation Z7PanelView

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
     QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSSearchFieldDelegate>

/// 这个窗口是否闲置可复用：还没打开归档，也没有任务在跑。窗口管理器据此决定
/// 新来的归档是投进现有窗口还是另开一个。
@property (nonatomic, readonly) BOOL isVacant;

/// 供窗口管理器投递归档（多窗口下由它决定落到哪个窗口）。
- (void)openArchive:(NSString *)path;
/// 打开归档，成功后再执行后续动作（Finder 服务「用 7-Zip 解压」用）。
- (void)openArchive:(NSString *)path thenRun:(void (^)(BOOL ok))then;
/// 供 Finder 服务与拖放使用。
- (void)compressURLs:(NSArray<NSURL *> *)urls;
/// 供程序坞菜单使用——菜单弹出时不一定有 key window，无法靠响应链派发。
- (void)doOpen:(id)sender;
- (void)doCompressPick:(id)sender;
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
/// 搜索项的引用，供 ⌘F 判断搜索框当下是否在视图层级里（见 performFindPanelAction:）。
@property (nonatomic, strong) NSToolbarItem *searchItem;
/// 轮询搜索框文本的定时器与上一次的值。为什么需要它见 buildCompressionControls。
@property (nonatomic, strong) NSTimer *searchPollTimer;
@property (nonatomic, copy) NSString *lastSearchText;

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
@property (nonatomic, strong) NSComboBox *volumeCombo;      // 分卷（可编辑，占位「例如： 5 MB」）
@property (nonatomic, strong) NSPopUpButton *encryptMethPop;
@property (nonatomic, strong) NSSecureTextField *password;      // 密码（掩码态）
@property (nonatomic, strong) NSTextField *passwordPlain;       // 密码（明文回显态，与上一个同框互斥）
@property (nonatomic, strong) NSSecureTextField *passwordRepeat; // 重复（掩码态）
@property (nonatomic, strong) NSTextField *passwordRepeatPlain;  // 重复（明文回显态）
@property (nonatomic, strong) NSButton *passwordLockBtn;         // 锁：切换密码字段可编辑性
@property (nonatomic, strong) NSButton *passwordEyeBtn;          // 眼睛：切换明文回显
@property (nonatomic, assign) BOOL passwordRevealed;
@property (nonatomic, assign) BOOL passwordLocked;

@property (nonatomic, strong) NSButton *encryptHeaderCheck;     // 分组内：加密文件名
@property (nonatomic, strong) NSButton *sfxCheck;               // 分组内：Windows 自解压文件
@property (nonatomic, strong) NSButton *compressHeaderCheck;     // 折叠区：压缩头
@property (nonatomic, strong) NSButton *fullPathsCheck;          // 折叠区：保存完整路径
@property (nonatomic, strong) NSButton *excludeJunkCheck;        // 排除 Mac 资源文件
@property (nonatomic, strong) NSButton *verifyAfterCheck;        // 验证压缩完整性
@property (nonatomic, strong) NSButton *deleteSourceCheck;       // 压缩完成后删除源文件
@property (nonatomic, strong) NSButton *separateCheck;           // 分别压缩每个文件

@property (nonatomic, strong) NSButton *advancedToggle;          // 「高级参数」折叠开关
@property (nonatomic, strong) NSView *advancedBox;               // 折叠区内容
@property (nonatomic, assign) BOOL advancedExpanded;
@property (nonatomic, strong) NSLayoutConstraint *advancedZeroHeight; // 收起时把折叠区压成 0 高
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *advancedContentConstraints;

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
/// 建树 / 建索引 / 搜索这些纯计算用的队列。与引擎任务队列分开：它们不该和引擎
/// 调用抢同一条串行通道，也不受「同时只允许一个任务」那条约束。
@property (nonatomic, strong) NSOperationQueue *workQueue;
/// 内容代次。每次替换树（打开归档）或发起新搜索就 +1；后台算完回主线程时若代次
/// 已经变了，说明结果已过期，直接丢弃——用代次代替加锁，避免竞态又不引入死锁风险。
@property (nonatomic, assign) NSUInteger contentGeneration;
/// 当前任务进度的整数百分比（NSNotFound 表示未知）。只用于标题栏副标题，
/// 且只在整数位变化时才改写窗口——进度回调是毫秒级的。
@property (nonatomic, assign) NSInteger subtitlePercent;

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
- (void)syncPasswordFieldState;
- (void)syncOptionsPopoverSize;
- (NSString *)passwordText;
- (BOOL)validatePasswordMatch:(NSString **)message;
- (void)runCreateBatch:(NSArray<NSArray *> *)batch
                 index:(NSUInteger)idx
               options:(Z7CompressionOptions *)opts;
- (void)trashPaths:(NSArray<NSString *> *)paths;
- (void)updateAdvancedToggleStyle;
- (void)buildTreeAndIndexInBackground:(NSArray<Z7Item *> *)items then:(void (^)(void))then;
- (void)runSearch;
@end

@implementation MainViewController

- (void)dealloc
{
    // 搜索框的通知观察者必须在销毁前摘掉：选择器式的 addObserver: 是不持有（unretained）
    // 的，窗口关掉、控制器释放之后通知中心仍会向已释放的对象发消息。
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // 轮询搜索框的定时器由 runloop 持有，不随控制器一起走——不显式停掉，关掉的
    // 窗口会留下一个每 0.15 秒空转一次的定时器。
    [_searchPollTimer invalidate];
}

- (void)loadView
{
    self.drop = [[DropView alloc] initWithFrame:NSMakeRect(0, 0, 560, 420)];
    self.drop.dropDelegate = self;
    self.view = self.drop;

    self.queue = [[NSOperationQueue alloc] init];
    // 单个窗口内严格串行（§7.1：避免并发写同一个归档）；跨窗口的串行由
    // Z7EngineLock 负责，因为引擎本身没有跨会话同步。
    self.queue.maxConcurrentOperationCount = 1;
    self.queue.name = @"org.7-zip.macos.engine";
    self.workQueue = [[NSOperationQueue alloc] init];
    self.workQueue.maxConcurrentOperationCount = 1;
    self.workQueue.name = @"org.7-zip.macos.work";
    self.subtitlePercent = NSNotFound;
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
    // 纯图标按钮对 VoiceOver 而言只是一个「按钮」。必须显式给标签，否则读屏用户
    // 根本分不清工具栏上这一排同样大小的图标各自是什么。
    b.accessibilityLabel = title;
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

/// 无边框图标按钮（用于密码行的锁 / 眼睛）。SF Symbol 缺失时退化为文字，
/// 与 toolbarButton 同一策略：宁可显示文字，也不要出现空白按钮。
- (NSButton *)iconButton:(NSString *)symbol fallback:(NSString *)text action:(SEL)sel
{
    NSImage *img = Symbol(symbol, 13.0);
    NSButton *b = img ? [NSButton buttonWithImage:img target:self action:sel]
                      : [NSButton buttonWithTitle:text target:self action:sel];
    b.bordered = NO;
    b.bezelStyle = NSBezelStyleRegularSquare;
    if (img) b.imagePosition = NSImageOnly;
    b.contentTintColor = [NSColor secondaryLabelColor];
    b.refusesFirstResponder = YES;
    b.accessibilityLabel = text;    // 同上：图标按钮需要给读屏一个名字
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

#pragma mark 压缩方式档位（Keka 面板的 6 档滑杆）

/// 滑杆有 6 个刻度位，对应 7-Zip 的 -mx = 0/1/3/5/7/9。
/// 面板上只给 0/1/5/9 四档加文字（存储 快速 正常 慢速），与参考面板一致。
static const NSInteger kLevelTickValues[6] = {0, 1, 3, 5, 7, 9};

static NSInteger LevelForTick(NSInteger tick)
{
    if (tick < 0) tick = 0;
    if (tick > 5) tick = 5;
    return kLevelTickValues[tick];
}

static NSInteger TickForLevel(NSInteger level)
{
    NSInteger best = 3, bestDelta = 99;
    for (NSInteger i = 0; i < 6; i++) {
        NSInteger d = labs(kLevelTickValues[i] - level);
        if (d < bestDelta) { bestDelta = d; best = i; }
    }
    return best;
}

static NSString *LevelNameForTick(NSInteger tick)
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

#pragma mark 压缩选项控件（§5.1）

- (void)buildCompressionControls
{
    self.searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchField.placeholderString = @"搜索条目";
    self.searchField.accessibilityLabel = @"搜索归档内的条目";
    self.searchField.target = self;
    self.searchField.action = @selector(searchChanged:);
    self.searchField.sendsWholeSearchString = NO;
    self.searchField.sendsSearchStringImmediately = YES;
    // 边打边过滤：搜索框由普通工具栏 item 的自定义视图承载
    // （见 itemForItemIdentifier: 里「为什么不用 NSSearchToolbarItem」），
    // 编辑事件完全归自己，所以按 NSTextField 的标准做法接两条通道：
    //   ① delegate 的 controlTextDidChange:
    //   ② NSControlTextDidChangeNotification（字段编辑器直接投递，不经过 delegate）
    // 上面两个 sends* 决定 action 的发送时机，是第三条通道。三条都汇到同一个
    // 防抖入口，彼此幂等，多留一条只是保险。
    self.searchField.delegate = self;
    // 实时过滤的主通道：字段编辑器（NSTextView）自己 post 的变更通知。
    //
    // 实测（2026-09-24，逐字符注入复现）NSSearchField 会把 controlTextDidChange:
    // 那条链整个吞掉——编辑期间 delegate 回调与 NSControlTextDidChangeNotification
    // 一次都不来，只有编辑提交（回车）时才吐出，用户看到的就是「输入后必须回车才
    // 检索」。字段编辑器自己发的 NSTextDidChangeNotification 绕开了 NSCell 的转发，
    // 每敲一个字符都会到达；中文输入法在选词提交时同样会发。
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(editorTextDidChange:)
               name:NSTextDidChangeNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(searchTextDidChange:)
               name:NSControlTextDidChangeNotification
             object:self.searchField];

    // 实时过滤的兜底通道：轻量轮询。
    //
    // 实测（2026-09-24，逐字符注入复现）：搜索框编辑期间，delegate 的
    // controlTextDidChange:、NSControlTextDidChangeNotification、以及字段编辑器自己的
    // NSTextDidChangeNotification 全都收不到——三条都只在编辑提交（回车）时才一次性
    // 吐出，用户看到的就是「输入后必须回车才检索」。
    // 文本值本身随时可读（探针逐字读到了 r → re → … → report），所以用 0.15s 轮询
    // 兜底：比较一次字符串，变了就进同一个防抖入口。代价是一次属性比较，可忽略。
    // 上面三条事件通道保留：正常键入时它们能立即响应（轮询只是保险）。
    __weak MainViewController *weakSelf = self;
    self.lastSearchText = self.searchField.stringValue ?: @"";   // 免得首拍就当成一次变更
    self.searchPollTimer = [NSTimer timerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *t) {
        MainViewController *me = weakSelf;
        if (!me || !me.searchField.window) return;      // 窗口不在，没必要看
        NSString *v = me.searchField.stringValue ?: @"";
        if ([v isEqualToString:me.lastSearchText]) return;
        me.lastSearchText = v;
        [me searchChanged:nil];
    }];
    // Common modes：滚动列表时 runloop 会切到 event tracking，默认模式下的定时器
    // 会被暂停，输入跟手性就会丢。
    [[NSRunLoop mainRunLoop] addTimer:self.searchPollTimer forMode:NSRunLoopCommonModes];

    // 格式
    self.formatPop = [self popup:@[@"7z", @"zip", @"tar", @"xz", @"gz", @"bz2"]
                          action:@selector(formatChanged:)];

    self.levelSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    self.levelSlider.translatesAutoresizingMaskIntoConstraints = NO;
    // 6 档（0/1/3/5/7/9），与 Keka 压缩方式滑杆一致；面板只给 4 个档位加标签。
    self.levelSlider.minValue = 0; self.levelSlider.maxValue = 5;
    self.levelSlider.numberOfTickMarks = 6;
    self.levelSlider.allowsTickMarkValuesOnly = YES;
    self.levelSlider.integerValue = TickForLevel(5);
    self.levelSlider.continuous = YES;
    self.levelSlider.target = self;
    self.levelSlider.action = @selector(levelChanged:);
    self.levelLabel = [self label:@"正常"];
    self.levelLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
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
    self.solidCheck = [NSButton checkboxWithTitle:@"固实归档" target:self action:@selector(solidChanged:)];
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

    // 分卷：可编辑组合框，既能选预设也能直接敲「5 MB」这类自定义容量
    self.volumeCombo = [[NSComboBox alloc] initWithFrame:NSZeroRect];
    self.volumeCombo.translatesAutoresizingMaskIntoConstraints = NO;
    [self.volumeCombo addItemsWithObjectValues:@[@"不分卷", @"1 MB", @"5 MB", @"10 MB",
                                                 @"100 MB", @"700 MB", @"1 GB", @"4 GB"]];
    self.volumeCombo.placeholderString = @"例如： 5 MB";
    self.volumeCombo.completes = YES;
    self.volumeCombo.numberOfVisibleItems = 8;
    self.volumeCombo.stringValue = @"";   // 空 = 不分卷，界面上显示占位提示
    self.volumeCombo.target = self;
    self.volumeCombo.action = @selector(updateOptionsSummary:);

    // 加密
    self.encryptMethPop = [self popup:@[@"AES256", @"AES128", @"ZipCrypto"]
                               action:@selector(updateOptionsSummary:)];
    self.password = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.password.translatesAutoresizingMaskIntoConstraints = NO;
    self.password.target = self;
    self.password.action = @selector(passwordEdited:);

    // 明文回显态：NSSecureTextField 无法在运行期切换掩码，故用一个同位置的
    // 普通文本框与之互斥显示（眼睛按钮），两者始终同步取值。
    self.passwordPlain = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.passwordPlain.translatesAutoresizingMaskIntoConstraints = NO;
    self.passwordPlain.hidden = YES;
    self.passwordPlain.target = self;
    self.passwordPlain.action = @selector(passwordEdited:);

    self.passwordRepeat = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.passwordRepeat.translatesAutoresizingMaskIntoConstraints = NO;
    self.passwordRepeat.target = self;
    self.passwordRepeat.action = @selector(passwordEdited:);

    self.passwordRepeatPlain = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.passwordRepeatPlain.translatesAutoresizingMaskIntoConstraints = NO;
    self.passwordRepeatPlain.hidden = YES;
    self.passwordRepeatPlain.target = self;
    self.passwordRepeatPlain.action = @selector(passwordEdited:);

    self.passwordLockBtn = [self iconButton:@"lock.open" fallback:@"锁"
                                     action:@selector(passwordLockClicked:)];
    self.passwordLockBtn.toolTip = @"锁定密码栏，避免误改";
    self.passwordEyeBtn = [self iconButton:@"eye" fallback:@"显示"
                                    action:@selector(passwordEyeClicked:)];
    self.passwordEyeBtn.toolTip = @"显示/隐藏密码";

    self.encryptHeaderCheck = [NSButton checkboxWithTitle:@"加密文件名" target:self
                                                   action:@selector(optionsFlagChanged:)];
    self.encryptHeaderCheck.translatesAutoresizingMaskIntoConstraints = NO;
    self.encryptHeaderCheck.state = NSControlStateValueOn;
    self.encryptHeaderCheck.toolTip = @"需要先设置密码；否则归档头不会被加密";

    self.sfxCheck = [NSButton checkboxWithTitle:@"Windows 自解压文件" target:self
                                         action:@selector(optionsFlagChanged:)];
    self.sfxCheck.translatesAutoresizingMaskIntoConstraints = NO;
    self.sfxCheck.enabled = NO;
    self.sfxCheck.toolTip = @"自解压模块 7z.sfx 是 Windows 可执行文件，macOS 版不含该模块，暂不支持生成";

    self.compressHeaderCheck = [NSButton checkboxWithTitle:@"压缩头" target:self
                                                    action:@selector(updateOptionsSummary:)];
    self.compressHeaderCheck.translatesAutoresizingMaskIntoConstraints = NO;
    self.compressHeaderCheck.state = NSControlStateValueOn;
    self.fullPathsCheck = [NSButton checkboxWithTitle:@"保存完整路径" target:self
                                               action:@selector(updateOptionsSummary:)];
    self.fullPathsCheck.translatesAutoresizingMaskIntoConstraints = NO;

    // 组外四个开关（Keka 面板的下半部分）
    self.excludeJunkCheck = [NSButton checkboxWithTitle:@"排除 Mac 资源文件" target:self
                                                 action:@selector(optionsFlagChanged:)];
    self.excludeJunkCheck.translatesAutoresizingMaskIntoConstraints = NO;
    self.excludeJunkCheck.state = NSControlStateValueOn;
    self.excludeJunkCheck.toolTip = @"排除 .DS_Store / __MACOSX / ._* 等 macOS 元数据文件";

    self.verifyAfterCheck = [NSButton checkboxWithTitle:@"验证压缩完整性" target:self
                                                 action:@selector(optionsFlagChanged:)];
    self.verifyAfterCheck.translatesAutoresizingMaskIntoConstraints = NO;
    self.verifyAfterCheck.toolTip = @"建包完成后立即解压校验一遍（不写盘）";

    self.deleteSourceCheck = [NSButton checkboxWithTitle:@"压缩完成后删除源文件" target:self
                                                  action:@selector(optionsFlagChanged:)];
    self.deleteSourceCheck.translatesAutoresizingMaskIntoConstraints = NO;
    self.deleteSourceCheck.toolTip = @"源文件会被移到废纸篓，可从废纸篓恢复";

    self.separateCheck = [NSButton checkboxWithTitle:@"分别压缩每个文件" target:self
                                              action:@selector(optionsFlagChanged:)];
    self.separateCheck.translatesAutoresizingMaskIntoConstraints = NO;
    self.separateCheck.toolTip = @"每个输入项各建一个归档，而不是合并成一个";

    // 折叠开关：NSBezelStyleDisclosure 会忽略标题（只画三角形），故改用
    // 无边框按钮 + SF Symbol 箭头 + 自绘标题，展开/收起时换箭头方向。
    self.advancedToggle = [self button:@"" action:@selector(toggleAdvanced:)];
    self.advancedToggle.bordered = NO;
    self.advancedToggle.buttonType = NSButtonTypePushOnPushOff;
    self.advancedToggle.state = NSControlStateValueOff;
    [self updateAdvancedToggleStyle];
    self.advancedToggle.toolTip = @"方法 / 字典 / 字长 / 匹配查找器 / 线程 / 加密算法 等专家参数";

    // 更新模式（§5.1「更新模式」，作用于添加操作）
    self.updateModePop = [self popup:@[@"跳过同名", @"替换同名"]
                              action:@selector(updateOptionsSummary:)];
}

#pragma mark 「压缩选项」弹出面板

/// 面板里的行标签（左侧、次要色）。
- (NSTextField *)optionsLabel:(NSString *)s
{
    NSTextField *t = [self label:s];
    t.font = [NSFont systemFontOfSize:13];
    t.textColor = [NSColor labelColor];
    t.lineBreakMode = NSLineBreakByTruncatingTail;
    return t;
}

/// 一行「标签 + 控件」：标签固定宽，控件铺满剩余宽度。
/// 返回的行视图本身不带宽度，宽度由调用方给的左右约束决定。
- (NSView *)optionsLineWithLabel:(NSString *)title
                        control:(NSView *)control
                     labelWidth:(CGFloat)labelWidth
{
    NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *t = [self optionsLabel:title];
    t.textColor = [NSColor secondaryLabelColor];
    [row addSubview:t];
    [row addSubview:control];
    [NSLayoutConstraint activateConstraints:@[
        [t.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [t.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [t.widthAnchor constraintEqualToConstant:labelWidth],
        [control.leadingAnchor constraintEqualToAnchor:row.leadingAnchor
                                              constant:labelWidth + 8],
        [control.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [control.topAnchor constraintEqualToAnchor:row.topAnchor],
        [control.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
    ]];
    return row;
}

/// 折叠区里的「标签 + 开关 + 数值框」行（线程专用）。
- (NSView *)optionsLineWithLabel:(NSString *)title
                            toggle:(NSButton *)toggle
                              field:(NSTextField *)field
                         labelWidth:(CGFloat)labelWidth
                           fieldWidth:(CGFloat)fieldWidth
{
    NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *t = [self optionsLabel:title];
    t.textColor = [NSColor secondaryLabelColor];
    [row addSubview:t];
    [row addSubview:toggle];
    [row addSubview:field];
    [field.widthAnchor constraintEqualToConstant:fieldWidth].active = YES;
    [NSLayoutConstraint activateConstraints:@[
        [t.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [t.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [t.widthAnchor constraintEqualToConstant:labelWidth],
        [toggle.leadingAnchor constraintEqualToAnchor:row.leadingAnchor
                                            constant:labelWidth + 8],
        [toggle.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [field.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [field.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [field.leadingAnchor constraintGreaterThanOrEqualToAnchor:toggle.trailingAnchor
                                                         constant:8],
    ]];
    return row;
}

- (NSView *)buildOptionsView
{
    const CGFloat PAD   = 16;   // 面板左右内边距
    const CGFloat PANEL = 340;  // 面板内容宽度（参考面板 320，本面板多一行头部）
    const CGFloat LW    = 46;   // 分组内标签列宽
    const CGFloat GX    = 12;   // 分组卡片内边距
    const CGFloat ICO   = 22;   // 锁 / 眼睛按钮边长
    const CGFloat IGAP  = 6;
    const CGFloat ALW   = 76;   // 折叠区标签列宽

    Z7PanelView *box = [[Z7PanelView alloc] initWithFrame:NSZeroRect];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *head = [self label:@"压缩选项"];
    head.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    head.textColor = [NSColor secondaryLabelColor];

    NSTextField *fmtCap = [self label:@"格式"];
    fmtCap.font = [NSFont systemFontOfSize:12];
    fmtCap.textColor = [NSColor tertiaryLabelColor];

    [self.formatPop.widthAnchor constraintEqualToConstant:82].active = YES;
    [self.formatPop.heightAnchor constraintEqualToConstant:24].active = YES;

    NSButton *done = [self button:@"完成" action:@selector(closeOptions:)];
    done.bezelStyle = NSBezelStyleRounded;
    done.controlSize = NSControlSizeSmall;
    done.font = [NSFont systemFontOfSize:11];

    // ── 压缩方式（滑杆 + 刻度文字）────────────────────────────────
    NSTextField *cap = [self label:@"压缩方式："];
    cap.font = [NSFont systemFontOfSize:13];
    cap.textColor = [NSColor secondaryLabelColor];

    NSStackView *capRow = [NSStackView stackViewWithViews:@[cap, self.levelLabel]];
    capRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    capRow.alignment = NSLayoutAttributeCenterY;
    capRow.spacing = 6;
    capRow.translatesAutoresizingMaskIntoConstraints = NO;

    // 6 等分格，只在 0/1/3/5 号格放字 —— 存储 快速 正常 慢速（另两档无标签）
    NSArray<NSString *> *tickNames = @[@"存储", @"快速", @"", @"正常", @"", @"慢速"];
    NSMutableArray<NSView *> *cells = [NSMutableArray array];
    for (NSString *nm in tickNames) {
        NSTextField *t = [self label:nm];
        t.font = [NSFont systemFontOfSize:11];
        t.textColor = [NSColor tertiaryLabelColor];
        t.alignment = NSTextAlignmentCenter;
        [cells addObject:t];
    }
    NSStackView *ticks = [NSStackView stackViewWithViews:cells];
    ticks.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    ticks.alignment = NSLayoutAttributeCenterY;
    ticks.distribution = NSStackViewDistributionFillEqually;
    ticks.spacing = 0;
    ticks.translatesAutoresizingMaskIntoConstraints = NO;

    // ── 分组卡片：分卷 / 密码 / 重复 + 三个开关 ────────────────────
    Z7CardView *card = [[Z7CardView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *volL = [self optionsLabel:@"分卷"];
    NSTextField *pwL  = [self optionsLabel:@"密码"];
    NSTextField *rpL  = [self optionsLabel:@"重复"];

    for (NSTextField *f in @[self.password, self.passwordPlain,
                             self.passwordRepeat, self.passwordRepeatPlain]) {
        [f.heightAnchor constraintEqualToConstant:24].active = YES;
    }
    [self.volumeCombo.heightAnchor constraintEqualToConstant:24].active = YES;
    for (NSButton *b in @[self.passwordLockBtn, self.passwordEyeBtn]) {
        [b.widthAnchor constraintEqualToConstant:ICO].active = YES;
        [b.heightAnchor constraintEqualToConstant:ICO].active = YES;
    }

    for (NSView *v in @[volL, self.volumeCombo, pwL, self.password, self.passwordPlain,
                        self.passwordLockBtn, self.passwordEyeBtn, rpL,
                        self.passwordRepeat, self.passwordRepeatPlain,
                        self.encryptHeaderCheck, self.solidCheck, self.sfxCheck]) {
        [card addSubview:v];
    }

    const CGFloat CONTENT_X = GX + LW + 8;              // 控件列起点
    const CGFloat ICON_INSET = GX + ICO * 2 + IGAP * 2; // 密码行右侧给图标留的宽度

    [NSLayoutConstraint activateConstraints:@[
        // 分卷（铺满整行，含图标列）
        [volL.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:GX],
        [volL.widthAnchor constraintEqualToConstant:LW],
        [volL.centerYAnchor constraintEqualToAnchor:self.volumeCombo.centerYAnchor],
        [self.volumeCombo.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:CONTENT_X],
        [self.volumeCombo.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-GX],
        [self.volumeCombo.topAnchor constraintEqualToAnchor:card.topAnchor constant:GX],

        // 密码（掩码态与明文态同框，眼睛按钮切换显示哪一个）
        [pwL.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:GX],
        [pwL.widthAnchor constraintEqualToConstant:LW],
        [pwL.centerYAnchor constraintEqualToAnchor:self.password.centerYAnchor],
        [self.password.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:CONTENT_X],
        [self.password.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-ICON_INSET],
        [self.password.topAnchor constraintEqualToAnchor:self.volumeCombo.bottomAnchor constant:8],
        [self.passwordPlain.leadingAnchor constraintEqualToAnchor:self.password.leadingAnchor],
        [self.passwordPlain.trailingAnchor constraintEqualToAnchor:self.password.trailingAnchor],
        [self.passwordPlain.centerYAnchor constraintEqualToAnchor:self.password.centerYAnchor],
        [self.passwordLockBtn.leadingAnchor constraintEqualToAnchor:self.password.trailingAnchor
                                                          constant:IGAP],
        [self.passwordLockBtn.centerYAnchor constraintEqualToAnchor:self.password.centerYAnchor],
        [self.passwordEyeBtn.leadingAnchor constraintEqualToAnchor:self.passwordLockBtn.trailingAnchor
                                                         constant:IGAP],
        [self.passwordEyeBtn.centerYAnchor constraintEqualToAnchor:self.password.centerYAnchor],

        // 重复（与密码同左边界、同右边界）
        [rpL.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:GX],
        [rpL.widthAnchor constraintEqualToConstant:LW],
        [rpL.centerYAnchor constraintEqualToAnchor:self.passwordRepeat.centerYAnchor],
        [self.passwordRepeat.leadingAnchor constraintEqualToAnchor:self.password.leadingAnchor],
        [self.passwordRepeat.trailingAnchor constraintEqualToAnchor:self.password.trailingAnchor],
        [self.passwordRepeat.topAnchor constraintEqualToAnchor:self.password.bottomAnchor constant:8],
        [self.passwordRepeatPlain.leadingAnchor constraintEqualToAnchor:self.passwordRepeat.leadingAnchor],
        [self.passwordRepeatPlain.trailingAnchor constraintEqualToAnchor:self.passwordRepeat.trailingAnchor],
        [self.passwordRepeatPlain.centerYAnchor constraintEqualToAnchor:self.passwordRepeat.centerYAnchor],

        // 卡片内三个开关
        [self.encryptHeaderCheck.leadingAnchor constraintEqualToAnchor:card.leadingAnchor
                                                             constant:CONTENT_X],
        [self.encryptHeaderCheck.topAnchor constraintEqualToAnchor:self.passwordRepeat.bottomAnchor
                                                         constant:10],
        [self.solidCheck.leadingAnchor constraintEqualToAnchor:self.encryptHeaderCheck.leadingAnchor],
        [self.solidCheck.topAnchor constraintEqualToAnchor:self.encryptHeaderCheck.bottomAnchor constant:5],
        [self.sfxCheck.leadingAnchor constraintEqualToAnchor:self.encryptHeaderCheck.leadingAnchor],
        [self.sfxCheck.topAnchor constraintEqualToAnchor:self.solidCheck.bottomAnchor constant:5],
        [self.sfxCheck.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-GX],
    ]];

    // ── 卡片外四个开关 ────────────────────────────────────────────
    NSArray<NSButton *> *outer = @[self.excludeJunkCheck, self.verifyAfterCheck,
                                   self.deleteSourceCheck, self.separateCheck];

    // ── 高级参数折叠区（专家参数，默认收起）────────────────────────
    NSView *advBox = [self buildAdvancedOptionsView:ALW];
    self.advancedBox = advBox;
    advBox.hidden = YES;
    self.advancedZeroHeight = [advBox.heightAnchor constraintEqualToConstant:0];

    for (NSView *v in @[head, fmtCap, self.formatPop, done, capRow, self.levelSlider,
                        ticks, card, self.advancedToggle, advBox]) {
        [box addSubview:v];
    }
    for (NSButton *c in outer) [box addSubview:c];
    self.advancedZeroHeight.active = YES;

    NSMutableArray<NSLayoutConstraint *> *cs = [NSMutableArray arrayWithArray:@[
        // 头部
        [head.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:PAD],
        [head.topAnchor constraintEqualToAnchor:box.topAnchor constant:14],
        [done.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-PAD],
        [done.centerYAnchor constraintEqualToAnchor:head.centerYAnchor],
        [self.formatPop.trailingAnchor constraintEqualToAnchor:done.leadingAnchor constant:-8],
        [self.formatPop.centerYAnchor constraintEqualToAnchor:head.centerYAnchor],
        [fmtCap.trailingAnchor constraintEqualToAnchor:self.formatPop.leadingAnchor constant:-6],
        [fmtCap.centerYAnchor constraintEqualToAnchor:head.centerYAnchor],

        // 压缩方式
        [capRow.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:PAD],
        [capRow.topAnchor constraintEqualToAnchor:head.bottomAnchor constant:12],
        [self.levelSlider.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:PAD],
        [self.levelSlider.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-PAD],
        [self.levelSlider.topAnchor constraintEqualToAnchor:capRow.bottomAnchor constant:8],

        // 刻度文字：与滑杆轨道对齐（轨道两端各内缩约一个滑块半径）
        [ticks.leadingAnchor constraintEqualToAnchor:self.levelSlider.leadingAnchor constant:11],
        [ticks.trailingAnchor constraintEqualToAnchor:self.levelSlider.trailingAnchor constant:-11],
        [ticks.topAnchor constraintEqualToAnchor:self.levelSlider.bottomAnchor constant:3],

        // 分组卡片
        [card.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:PAD],
        [card.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-PAD],
        [card.topAnchor constraintEqualToAnchor:ticks.bottomAnchor constant:12],

        // 卡片外四个开关（比卡片左边界再缩进 6pt，与参考面板一致）
        [self.excludeJunkCheck.leadingAnchor constraintEqualToAnchor:box.leadingAnchor
                                                            constant:PAD + 6],
        [self.excludeJunkCheck.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:12],
        [self.verifyAfterCheck.leadingAnchor constraintEqualToAnchor:self.excludeJunkCheck.leadingAnchor],
        [self.verifyAfterCheck.topAnchor constraintEqualToAnchor:self.excludeJunkCheck.bottomAnchor
                                                        constant:6],
        [self.deleteSourceCheck.leadingAnchor constraintEqualToAnchor:self.excludeJunkCheck.leadingAnchor],
        [self.deleteSourceCheck.topAnchor constraintEqualToAnchor:self.verifyAfterCheck.bottomAnchor
                                                         constant:6],
        [self.separateCheck.leadingAnchor constraintEqualToAnchor:self.excludeJunkCheck.leadingAnchor],
        [self.separateCheck.topAnchor constraintEqualToAnchor:self.deleteSourceCheck.bottomAnchor
                                                     constant:6],

        // 高级参数
        [self.advancedToggle.leadingAnchor constraintEqualToAnchor:box.leadingAnchor
                                                          constant:PAD - 2],
        [self.advancedToggle.topAnchor constraintEqualToAnchor:self.separateCheck.bottomAnchor
                                                      constant:12],
        [advBox.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:PAD],
        [advBox.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-PAD],
        [advBox.topAnchor constraintEqualToAnchor:self.advancedToggle.bottomAnchor constant:8],
        [advBox.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-14],

        [box.widthAnchor constraintEqualToConstant:PANEL],
    ]];
    [NSLayoutConstraint activateConstraints:cs];
    return box;
}

/// 折叠区：专家参数，单列排布。视图始终在树中，但内部约束只在展开时激活——
/// 收起时若让「高度 0」与内部约束链同时生效，二者必然冲突并打断其中一条。
- (NSView *)buildAdvancedOptionsView:(CGFloat)ALW
{
    NSView *box = [[NSView alloc] initWithFrame:NSZeroRect];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.wantsLayer = YES;
    box.layer.masksToBounds = YES;

    NSArray<NSView *> *rows = @[
        [self optionsLineWithLabel:@"方法"       control:self.methodPop       labelWidth:ALW],
        [self optionsLineWithLabel:@"字典"       control:self.dictPop         labelWidth:ALW],
        [self optionsLineWithLabel:@"字长"       control:self.wordPop         labelWidth:ALW],
        [self optionsLineWithLabel:@"快速字节"   control:self.fastBytesField  labelWidth:ALW],
        [self optionsLineWithLabel:@"匹配查找器" control:self.matchPop        labelWidth:ALW],
        [self optionsLineWithLabel:@"固实分块"   control:self.solidBlockPop   labelWidth:ALW],
        [self optionsLineWithLabel:@"线程"       toggle:self.autoThreadsCheck
                              field:self.threadsField labelWidth:ALW fieldWidth:44],
        [self optionsLineWithLabel:@"加密算法"   control:self.encryptMethPop  labelWidth:ALW],
        [self optionsLineWithLabel:@"添加时"     control:self.updateModePop   labelWidth:ALW],
    ];
    for (NSView *r in rows) [box addSubview:r];

    NSMutableArray<NSLayoutConstraint *> *inner = [NSMutableArray array];
    [inner addObjectsFromArray:@[
        [rows.firstObject.topAnchor constraintEqualToAnchor:box.topAnchor],
        [rows.firstObject.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
        [rows.firstObject.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
        [rows.firstObject.heightAnchor constraintEqualToConstant:24],
    ]];
    for (NSUInteger i = 1; i < rows.count; i++) {
        [inner addObjectsFromArray:@[
            [rows[i].topAnchor constraintEqualToAnchor:rows[i - 1].bottomAnchor constant:6],
            [rows[i].leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
            [rows[i].trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
            [rows[i].heightAnchor constraintEqualToConstant:24],
        ]];
    }

    NSView *prev = rows.lastObject;
    for (NSButton *b in @[self.compressHeaderCheck, self.fullPathsCheck]) {
        [box addSubview:b];
        [inner addObjectsFromArray:@[
            [b.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:ALW + 8],
            [b.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:8],
        ]];
        prev = b;
    }
    [inner addObject:[prev.bottomAnchor constraintEqualToAnchor:box.bottomAnchor]];

    self.advancedContentConstraints = inner;
    return box;   // 内部约束由 toggleAdvanced: 按展开状态激活，此处不激活
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
            ? fit : NSMakeSize(340, 430);

        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(optionsPopoverDidClose:)
            name:NSPopoverDidCloseNotification
            object:self.optionsPopover];
    }
    [self syncPasswordFieldState];
    [self syncOptionsPopoverSize];

    // 锚点必须位于**窗口的视图层级里**，否则 showRelativeToRect:ofView: 无法定位、
    // 静默失败（弹层完全不出现）。
    //
    // 窗口是固定的紧凑尺寸，工具栏放不下的项会被 AppKit 收进「>>」溢出菜单；一旦被
    // 收起，该项的 view 就被移出工具栏层级，self.optionsBtn.window 变成 nil（探针
    // 实测：sender=NSMenuItem、btnWindow=0）。此时再拿按钮当锚点就是往游离视图上
    // 定位——点击菜单项毫无反应，正是「压缩选项点击后无反应」的根因。
    //
    // 因此分三级回退：按钮/ sender 视图在层级里就用它（弹在按钮下方，位置最自然）；
    // 都不可用就退到内容视图顶边中间——弹层从标题栏下方居中拉开，与工具栏同处一个
    // 视觉区域，用户不会找不到它。
    NSView *anchor = nil;
    NSRect anchorRect = NSZeroRect;
    if ([sender isKindOfClass:[NSView class]] && ((NSView *)sender).window) {
        anchor = (NSView *)sender;
        anchorRect = anchor.bounds;
    } else if (self.optionsBtn.window) {
        anchor = self.optionsBtn;
        anchorRect = anchor.bounds;
    } else if (self.view) {
        anchor = self.view;
        NSRect cb = anchor.bounds;
        // 1×1pt 的细条贴在内容区顶边正中：preferredEdge=MinY 把弹层挂在该矩形
        // 下沿，视觉上正好落在工具栏下方、水平居中。
        anchorRect = NSMakeRect(NSMidX(cb) - 0.5, NSMaxY(cb) - 1.0, 1.0, 1.0);
    }
    if (!anchor) { NSBeep(); return; }

    [self.optionsPopover showRelativeToRect:anchorRect
                                     ofView:anchor
                             preferredEdge:NSRectEdgeMinY];
    // 弹层出现后不要让第一个控件（分卷）自动获得焦点：面板是"看一眼/改一下"的
    // 辅助界面，进场就带高亮框会让人以为要立刻输入。
    NSWindow *pw = self.optionsPopover.contentViewController.view.window;
    [pw performSelector:@selector(makeFirstResponder:) withObject:nil afterDelay:0];
}

- (void)closeOptions:(id)s
{
    [self.optionsPopover close];
}

- (void)optionsPopoverDidClose:(NSNotification *)n
{
    [self updateOptionsSummary];
}

#pragma mark 面板交互（密码锁/眼睛、开关、高级折叠）

/// 密码行状态：掩码态与明文态互斥显示，锁按钮控制可编辑性，
/// 「加密文件名」只有在设有密码时才有意义。
- (void)syncPasswordFieldState
{
    BOOL revealed = self.passwordRevealed;
    self.password.hidden = revealed;
    self.passwordPlain.hidden = !revealed;
    self.passwordRepeat.hidden = revealed;
    self.passwordRepeatPlain.hidden = !revealed;
    if (revealed) {
        // 明文框当前可见 = 权威值，同步给隐藏的掩码框
        self.password.stringValue = self.passwordPlain.stringValue;
        self.passwordRepeat.stringValue = self.passwordRepeatPlain.stringValue;
    } else {
        // 掩码框当前可见 = 权威值，同步给隐藏的明文框
        self.passwordPlain.stringValue = self.password.stringValue;
        self.passwordRepeatPlain.stringValue = self.passwordRepeat.stringValue;
    }

    BOOL editable = !self.passwordLocked;
    for (NSTextField *f in @[self.password, self.passwordPlain,
                             self.passwordRepeat, self.passwordRepeatPlain]) {
        f.editable = editable;
        f.selectable = editable;
    }
    self.passwordLockBtn.image = Symbol(self.passwordLocked ? @"lock.fill" : @"lock.open", 13.0);
    self.passwordLockBtn.toolTip = self.passwordLocked ? @"解锁密码栏" : @"锁定密码栏，避免误改";

    BOOL hasPassword = self.passwordText.length > 0;
    self.passwordEyeBtn.enabled = hasPassword;
    self.passwordEyeBtn.contentTintColor = hasPassword ? [NSColor secondaryLabelColor]
                                                       : [NSColor tertiaryLabelColor];

    // 「加密文件名」需要密码；7z 之外的格式也不支持加密文件名
    BOOL is7z = [[self selectedFormat] isEqualToString:@"7z"];
    self.encryptHeaderCheck.enabled = hasPassword && is7z;
}

/// 当前密码（取可见的那个字段，两者已同步）。
- (NSString *)passwordText
{
    return self.passwordRevealed ? self.passwordPlain.stringValue : self.password.stringValue;
}

- (NSString *)passwordRepeatText
{
    return self.passwordRevealed ? self.passwordRepeatPlain.stringValue
                                 : self.passwordRepeat.stringValue;
}

- (void)passwordEdited:(id)s
{
    [self syncPasswordFieldState];
    [self updateOptionsSummary];
}

- (void)passwordLockClicked:(id)s
{
    self.passwordLocked = !self.passwordLocked;
    [self syncPasswordFieldState];
}

- (void)passwordEyeClicked:(id)s
{
    self.passwordRevealed = !self.passwordRevealed;
    [self syncPasswordFieldState];
}

/// 哪个开关被拨动都只影响摘要与联动禁用态，真正的取值在 currentOptions 里读。
- (void)optionsFlagChanged:(id)s
{
    // 「分别压缩每个文件」与「排除 Mac 资源文件」互不影响，仅刷新摘要。
    [self updateOptionsSummary];
}

/// 折叠开关的箭头与标题（随展开状态切换）。无边框按钮的标题必须用
/// attributedTitle 才能拿到次要色——contentTintColor 只作用于图像。
- (void)updateAdvancedToggleStyle
{
    self.advancedToggle.image = Symbol(self.advancedExpanded ? @"chevron.down"
                                                             : @"chevron.right", 11.0);
    self.advancedToggle.imagePosition = NSImageLeft;
    self.advancedToggle.contentTintColor = [NSColor secondaryLabelColor];
    self.advancedToggle.attributedTitle =
        [[NSAttributedString alloc] initWithString:@"高级参数"
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12],
                         NSForegroundColorAttributeName: [NSColor secondaryLabelColor]}];
}

- (void)toggleAdvanced:(id)s
{
    self.advancedExpanded = (self.advancedToggle.state == NSControlStateValueOn);
    self.advancedBox.hidden = !self.advancedExpanded;
    [self updateAdvancedToggleStyle];

    // 两套约束互斥：展开时用内部尺寸，收起时用固定的 0 高度。
    // 同时激活会让「0 高度」与内部约束链冲突，Auto Layout 会打断其中一条。
    if (self.advancedExpanded) {
        self.advancedZeroHeight.active = NO;
        [NSLayoutConstraint activateConstraints:self.advancedContentConstraints];
    } else {
        [NSLayoutConstraint deactivateConstraints:self.advancedContentConstraints];
        self.advancedZeroHeight.active = YES;
    }
    [self syncOptionsPopoverSize];
}

/// 面板高度随折叠区展开/收起变化，弹层尺寸必须跟着重算。
- (void)syncOptionsPopoverSize
{
    NSView *root = self.optionsPopover.contentViewController.view;
    if (!root) return;
    [root layoutSubtreeIfNeeded];
    NSSize fit = root.fittingSize;
    if (fit.width > 200 && fit.height > 80) self.optionsPopover.contentSize = fit;
}

/// 密码一致性检查：两次输入不一致时给出行内提示并拒绝开始压缩。
- (BOOL)validatePasswordMatch:(NSString **)message
{
    NSString *pw = [self passwordText];
    NSString *rp = [self passwordRepeatText];
    if (!pw.length || [pw isEqualToString:rp]) return YES;
    if (message) *message = @"两次输入的密码不一致，请重新确认";
    return NO;
}

/// 状态栏右侧的摘要：让用户不必展开面板就知道「新建归档」会用什么参数。
/// 状态栏右侧那一段文字有两个来源，按优先级取：
///
///   1. 列表里有选中项 → 「已选 N 项 · 合计 X」，与访达窗口底部的写法一致；
///   2. 没有选中 → 新建归档的参数摘要（7z · 正常 · …）。
///
/// 参数摘要不会因此丢失：它始终挂在 summaryLabel 的 tooltip 上，而压缩面板本身
/// 也完整列出了每一项。
- (void)updateOptionsSummary
{
    Z7CompressionOptions *o = [self currentOptions];
    NSMutableArray *bits = [NSMutableArray arrayWithObject:(o.format.length ? o.format : @"7z")];
    [bits addObject:LevelNameForTick(self.levelSlider.integerValue)];
    if (o.password.length) [bits addObject:@"已设密码"];
    if (o.hasVolumeSize) [bits addObject:[NSString stringWithFormat:@"分卷 %@", o.volumeSizeText]];
    if (self.verifyAfterCheck.state == NSControlStateValueOn) [bits addObject:@"建包后校验"];
    if (self.deleteSourceCheck.state == NSControlStateValueOn) [bits addObject:@"删源文件"];
    if (self.separateCheck.state == NSControlStateValueOn) [bits addObject:@"逐个建包"];
    NSString *optionsSummary = [NSString stringWithFormat:@"新建归档：%@",
                                [bits componentsJoinedByString:@" · "]];
    self.summaryLabel.toolTip = optionsSummary;

    NSArray<Z7Node *> *sel = [self selectedNodes];
    if (sel.count) {
        unsigned long long total = 0;
        BOOL any = NO;
        for (Z7Node *n in sel) {
            if (n.hasSize) { total += n.size; any = YES; }
        }
        NSMutableString *s = [NSMutableString stringWithFormat:@"已选 %lu 项",
                              (unsigned long)sel.count];
        // 目录没有大小，整选目录时只是不追加合计，而不是报一个假的 0 B。
        if (any) [s appendFormat:@" · 合计 %@", HumanSize(total, YES, NO)];
        self.summaryLabel.stringValue = s;
        return;
    }
    self.summaryLabel.stringValue = optionsSummary;
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
    [self.progress.widthAnchor constraintEqualToConstant:120].active = YES;

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
    [[self.drop.widthAnchor constraintGreaterThanOrEqualToConstant:460] setActive:YES];


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
    // 顺序即溢出优先级：窗口是固定的紧凑尺寸，排在后面的项会被收进「>>」。
    // 压缩选项是高频入口（也是 ⌘, 的落点），与「新建归档」成对放在常驻区，
    // 不留在溢出菜单里。
    return @[@"open", @"new", @"options", NSToolbarSpaceItemIdentifier,
             @"extract", @"add", @"delete", @"test",
             NSToolbarFlexibleSpaceItemIdentifier,
             @"search", @"log"];
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
        // 搜索框放在普通 item 的自定义视图里，而不是 NSSearchToolbarItem。
        //
        // NSSearchToolbarItem 会连属性、约束和编辑事件一起接管（SDK 原文
        // “the field properties and layout constraints are managed by the item”）。
        // 实测（2026-09-24）接管得很彻底：在框里打字时，NSSearchField 本该发出的
        // NSControlTextDidChangeNotification 一次都不投递（把观察者放宽到 object:nil
        // 也收不到），目标的 action 也退化成只有回车或点放大镜才发——用户看到的就是
        // 「输入后必须回车才检索」。改用普通 item 承载后编辑事件完全归自己，与其它
        // 工具栏按钮走同一条已验证的路径。
        // 宽度取 120 是实测出来的，不是随手定的：工具栏是统一样式，标题与按钮同在
        // 一行，默认窗口内容宽 560pt 时空间很紧。同一窗口下逐个试过——
        //   搜索框 190pt → 工具栏只放得下「打开归档」（新建归档、压缩选项全进「>>」）
        //   搜索框 150pt → 放得下「打开归档 / 新建归档」
        //   搜索框 120pt → 「打开归档 / 新建归档 / 压缩选项」三个全部常驻
        // 再往下压就开始切占位文字（「搜索条目」显示不全），故停在 120。
        NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 120, 28)];
        [box addSubview:self.searchField];
        [NSLayoutConstraint activateConstraints:@[
            [box.widthAnchor  constraintEqualToConstant:120],
            [box.heightAnchor constraintEqualToConstant:26],
            [self.searchField.leadingAnchor  constraintEqualToAnchor:box.leadingAnchor],
            [self.searchField.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
            [self.searchField.centerYAnchor  constraintEqualToAnchor:box.centerYAnchor],
        ]];
        NSToolbarItem *it = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
        it.view = box;
        it.label = @"搜索";
        it.paletteLabel = @"搜索";
        it.toolTip = @"按名称搜索归档内的条目";
        // 紧凑窗口里工具栏放不下所有项时优先保住搜索框：它是过滤列表的唯一入口，
        // 一旦被收进「>>」就既看不见、也没法聚焦。
        it.visibilityPriority = NSToolbarItemVisibilityPriorityHigh;
        self.searchItem = it;
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
    NSButton *btn = spec[0];

    NSToolbarItem *it = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
    it.view = btn;
    it.label = spec[1];
    it.paletteLabel = spec[1];
    it.toolTip = spec[1];
    // 窗口变窄时 AppKit 会把放不下的 item 收进「>>」溢出菜单，而菜单项执行的是
    // **item 自己**的 target/action —— 自定义 view 不参与菜单。只设 view 会让那些
    // 被收起来的按钮在菜单里灰着、点了毫无反应。把按钮的 target/action/image
    // 原样转给 item：工具栏内仍由按钮视图响应，溢出菜单项也能正常工作。
    it.target = btn.target;
    it.action = btn.action;
    it.image = btn.image;
    // 这里**不要**给「压缩选项」提 visibilityPriority：实测把它提到 High 之后，
    // AppKit 会优先保住两个 High 项（它 + 搜索框），反而把普通优先级的「打开归档」
    // 「新建归档」挤进「>>」——把最高频的操作藏起来，比原来更糟。紧凑窗口只放得下
    // 两个按钮，常驻名额留给「打开归档 / 新建归档」，「压缩选项」走溢出菜单 /
    // ⌘, / 应用菜单三个已验证可用的入口。
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
    self.volumeCombo.enabled = !single;
    self.encryptMethPop.enabled = zipLike || [f isEqualToString:@"7z"];
    self.compressHeaderCheck.enabled = [f isEqualToString:@"7z"];
    self.fullPathsCheck.enabled = YES;
    self.updateModePop.enabled = !single;
    // 「加密文件名」还要看是否设了密码，统一由密码行状态决定
    [self syncPasswordFieldState];
    [self updateOptionsSummary];
}

- (void)levelChanged:(id)s
{
    self.levelLabel.stringValue = LevelNameForTick(self.levelSlider.integerValue);
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
    // 滑杆是 6 档（刻度位），换成 7-Zip 的 -mx 值
    o.level = LevelForTick(self.levelSlider.integerValue);

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
    // 分卷是可编辑组合框：既能选预设，也能直接敲「5 MB」「700m」这类自定义容量
    NSString *volText = [self.volumeCombo.stringValue
                         stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (ParseVolumeSize(volText, &vol)) {
        o.hasVolumeSize = YES; o.volumeSize = vol;
        o.volumeSizeText = volText;
    }

    o.encryptMethod = self.encryptMethPop.titleOfSelectedItem ?: @"AES256";
    o.password = [self passwordText] ?: @"";

    // 没有密码时明确不设 -mhe：否则会向引擎传一个无意义的「加密头」开关
    o.hasEncryptHeader = o.password.length > 0;
    o.encryptHeader = o.hasEncryptHeader &&
        (self.encryptHeaderCheck.state == NSControlStateValueOn);
    o.hasCompressHeader = YES;
    o.compressHeader = (self.compressHeaderCheck.state == NSControlStateValueOn);
    o.fullPaths = (self.fullPathsCheck.state == NSControlStateValueOn);
    o.excludeMacJunk = (self.excludeJunkCheck.state == NSControlStateValueOn);
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

/// 日志文本的字符上限。引擎在整档操作里会逐条回警告（一个十万条目的归档可以
/// 刷出同样多的行），而日志抽屉是常驻视图：不封顶的话 NSTextStorage 只增不减，
/// 每条还各带一份属性字典，内存与重排代价都随会话时长线性增长。超限时从头部
/// 砍掉一半，保留最近的上下文。
static const NSUInteger kZ7LogCharLimit = 200000;

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
        if (st.length > kZ7LogCharLimit) {
            [st deleteCharactersInRange:NSMakeRange(0, st.length - kZ7LogCharLimit / 2)];
        }
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
    return [self passwordText] ?: @"";
}

/// 标题栏的归档标识：窗口标题保持应用名，文件名放进副标题，并挂上代理图标
/// （representedURL），于是标题栏支持 ⌘ 点按显示路径——这是 macOS 文档窗口
/// 的标准行为，比在内容区里塞一个长路径标签更符合系统习惯。
- (void)updateArchiveChrome
{
    NSWindow *w = self.view.window;
    if (!w) return;

    // 窗口标题用文件名，而不是固定的应用名。
    //
    // 这是 macOS 文档窗口的惯例（访达 / 预览 / 文本编辑都是这样），更关键的是
    // 多窗口架构下必须如此：窗口可能按用户偏好合并成标签页，而标签上显示的就是
    // 窗口标题——标题若一律是 "7-Zip"，几个标签页就完全无从分辨。
    NSString *name = self.archivePath.lastPathComponent;
    if (!name.length) name = @"7-Zip";

    // 任务进行中时副标题让位给进度。多窗口下用户可能同时开着几个窗口，副标题是
    // 「一眼看出这个窗口在忙什么、忙到哪了」的位置。
    if (self.current) {
        w.title = name;
        w.subtitle = (self.subtitlePercent == NSNotFound)
            ? (self.current.title ?: @"处理中")
            : [NSString stringWithFormat:@"%@ · %ld%%",
               self.current.title ?: @"处理中", (long)self.subtitlePercent];
        return;
    }

    if (self.archivePath.length) {
        w.title = name;
        w.representedURL = [NSURL fileURLWithPath:self.archivePath];
        w.subtitle = self.archiveHeaderEncrypted ? @"文件名已加密" : @"";
    } else {
        w.title = @"7-Zip";
        w.representedURL = nil;
        w.subtitle = @"";
    }
}

/// 闲置可复用：还没打开归档、也没有任务在跑。
- (BOOL)isVacant
{
    return self.archivePath.length == 0 && self.current == nil;
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
    [[Z7SystemFeedback shared] taskBegan];   // 程序坞徽标进入忙碌态

    __weak MainViewController *weakSelf = self;
    task.onProgress = ^(Z7Progress *p) {
        MainViewController *me = weakSelf;
        if (!me) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            // 进度未知（total 为 0）时传 -1，让副标题与程序坞徽标都退回「只报状态」。
            double frac = p.total > 0 ? (double)p.completed / (double)p.total : -1.0;
            if (frac >= 0.0) me.progress.doubleValue = 100.0 * frac;
            if (p.itemPath.length) me.statusLabel.stringValue = p.itemPath;
            [[Z7SystemFeedback shared] taskProgress:frac];

            NSInteger pct = frac >= 0.0 ? (NSInteger)(frac * 100.0) : NSNotFound;
            if (pct != me.subtitlePercent) {    // 同样只在整数位变化时碰标题栏
                me.subtitlePercent = pct;
                [me updateArchiveChrome];
            }
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
        BOOL ok = NO;
        // 引擎调用全局串行（理由见 Z7EngineLock）。用户可能在排队期间就按了「停止」，
        // 所以拿到锁之后先看一次取消标志，免得排到队首又白跑一遍。
        NSLock *engineLock = Z7EngineLock();
        [engineLock lock];
        if (task.cancelRequested) {
            err = [NSError errorWithDomain:Z7ErrorDomain code:-1 userInfo:
                  @{NSLocalizedDescriptionKey: @"操作已取消"}];
        } else {
            ok = [task execute:&err];
        }
        [engineLock unlock];
        dispatch_async(dispatch_get_main_queue(), ^{
            MainViewController *me = weakSelf;
            if (!me) return;
            me.current = nil;
            [me setBusy:NO];     // 副标题在这里恢复成文件名
            [[Z7SystemFeedback shared] taskEndedWithTitle:task.title success:ok];
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
    // 忙碌状态决定副标题报进度还是报文件名。状态切换的瞬间就同步一次，否则任务
    // 启动后标题栏会停在旧内容上，一直等到第一个进度回调到达才更新。
    self.subtitlePercent = NSNotFound;
    [self updateArchiveChrome];
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
    // 编辑菜单里的剪切 / 粘贴在本应用没有落点：归档条目不能就地改名，归档也不
    // 接受粘贴。留着它们全亮会让用户以为功能坏了——禁用才是诚实的界面。
    // 日志抽屉或搜索框获得焦点时走的是文本视图自己的 target，不经过这里。
    if (a == @selector(cut:) || a == @selector(paste:)) return NO;
    if (a == @selector(copy:)) return [self selectedNodes].count > 0;
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

/// 「查找 ⌘F」曾经是一条死菜单项：菜单里写好了条目与快捷键，却没有实现，
/// 于是动作沿响应链落到标准查找面板上（本窗口没有可查找的文本视图）——按下去
/// 毫无反应。本应用里「查找」只有一种含义：按文件名过滤归档列表，也就是工具栏
/// 上的搜索框。这里把它接过来：聚焦并全选，用户可以直接开始输入。
- (void)performFindPanelAction:(id)sender
{
    if (self.current) return;   // 任务进行中列表被锁定，搜索没有意义
    NSWindow *w = self.view.window;

    if (w && self.searchField.window == w) {
        [w makeFirstResponder:self.searchField];
        [self.searchField selectText:nil];
        return;
    }

    // 走到这里说明搜索框不在本窗口的视图层级里。理论上不该发生——搜索项的
    // visibilityPriority 已提到 High，紧凑窗口下也会优先保住它。真到了这一步
    // 也没有官方 API 能把它取回来，至少给一声提示音，别让 ⌘F 变成无声的空操作。
    NSBeep();
}

/// ⌘C 拷贝所选项。
///
/// 归档条目在文件系统里并不独立存在，给 fileURL 只会得到一个解析不了的位置；
/// 真正有用的是条目在归档内的路径（可以粘进脚本、粘进 7z 命令行、粘进工单）。
/// 多选时一行一条，与 Finder 拷贝多个文件名的可读性一致。
- (void)copy:(id)sender
{
    NSArray<Z7Node *> *nodes = [self selectedNodes];
    if (!nodes.count) { NSBeep(); return; }

    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:nodes.count];
    for (Z7Node *n in nodes) [lines addObject:n.path];

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:[lines componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
    [self showStatus:[NSString stringWithFormat:@"已拷贝 %lu 条路径",
                      (unsigned long)lines.count]];
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
    [self openArchive:path password:nil then:nil];
}

/// 打开归档，成功后再执行一个动作。Finder 服务「用 7-Zip 解压」要的是「打开完就解压」，
/// 而打开是异步的（大归档要读好几秒），靠延时猜时间不可靠——所以把后续动作挂到打开
/// 完成的回调上，而不是 `performSelector:afterDelay:`。
- (void)openArchive:(NSString *)path thenRun:(void (^)(BOOL ok))then
{
    [self openArchive:path password:nil then:then];
}

- (void)openArchive:(NSString *)path password:(NSString *)password
{
    [self openArchive:path password:password then:nil];
}

- (void)openArchive:(NSString *)path
           password:(NSString *)password
               then:(void (^)(BOOL ok))then
{
    if (!path.length) { if (then) then(NO); return; }

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
            me.contentGeneration++;     // 树上已经没内容，作废在途的搜索，免得旧命中回写
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
                    if (pw.length) [me openArchive:path password:pw then:then];
                    else if (then) then(NO);
                }];
            } else if (then) {
                then(NO);
            }
            return;
        }

        me.archiveHeaderEncrypted = t.headerEncryptedOut;
        me.filtering = NO;
        me.searchField.stringValue = @"";
        Z7NoteRecentPath(path);     // 只有真的打开成功才计入「最近使用」
        // 建树与建索引都是整棵树的全量遍历，十万条目的归档在主线程做会明显卡住
        // （表还没刷新，窗口就像死了一样）。挪到后台，回主线程只赋值 + 刷新。
        [me buildTreeAndIndexInBackground:t.openedItems then:^{
            if (then) then(YES);
        }];
    }];
}

/// 把「条目数组 -> 树 + 路径索引」这两遍全量遍历放到后台队列，完成后回主线程刷新。
///
/// 为什么值得单开一条队列：这一段是 O(n) 的两遍遍历（建树一遍、建索引一遍），n 是
/// 归档里的条目数。几百项无感，十万项就是肉眼可见的卡顿，而且卡在主线程上时窗口
/// 连重绘都做不到。索引是提取阶段「树节点 -> 引擎条目号」的映射，必须与树一起
/// 原子地换掉，否则两者会短暂不一致。
- (void)buildTreeAndIndexInBackground:(NSArray<Z7Item *> *)items
                                 then:(void (^)(void))then
{
    NSUInteger gen = ++self.contentGeneration;   // 让在途的旧搜索作废
    __weak MainViewController *weakSelf = self;
    [self.workQueue addOperationWithBlock:^{
        NSArray<Z7Node *> *tree = BuildTree(items);
        NSMutableDictionary<NSString *, NSValue *> *idx =
            [NSMutableDictionary dictionaryWithCapacity:items.count];
        NSMutableArray<Z7Node *> *stack = [NSMutableArray arrayWithArray:tree];
        while (stack.count) {
            Z7Node *n = stack.lastObject;
            [stack removeLastObject];
            if (n.index != UINT32_MAX) {
                idx[n.path] = [NSValue valueWithBytes:&(uint32_t){n.index}
                                             objCType:@encode(uint32_t)];
            }
            [stack addObjectsFromArray:n.children];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            MainViewController *me = weakSelf;
            if (!me) return;
            if (me.contentGeneration != gen) return;   // 已有更新的一次打开，丢弃本次
            me.roots = tree;
            me.displayRoots = tree;
            me.indexByPath = idx;
            [me.outline reloadData];
            [me.outline expandItem:nil expandChildren:NO];
            [me setControlsEnabled:YES];
            [me updateArchiveChrome];
            [me updateEmptyState];
            [me showStatus:[NSString stringWithFormat:@"已载入 %lu 项", (unsigned long)items.count]];
            if (then) then();
        });
    }];
}

#pragma mark 搜索（§6.3）

/// 边打边过滤的两个入口（注册处见 buildCompressionControls），都汇到下面的防抖。
///
/// delegate 与通知同时接：前者是 NSTextField 的标准回调，后者由字段编辑器直接
/// 投递、不经过 delegate 归属。两条路径幂等——都是「取消上一次、排队下一次」，
/// 任意一条先到都能让列表跟着指尖动。
- (void)controlTextDidChange:(NSNotification *)note
{
    if (note.object != self.searchField) return;
    [self searchChanged:nil];
}

/// 实时过滤的主通道：字段编辑器（NSTextView）的变更通知。
- (void)editorTextDidChange:(NSNotification *)note
{
    if (note.object != self.searchField.currentEditor) return;
    [self searchChanged:nil];
}

- (void)searchTextDidChange:(NSNotification *)note
{
    [self controlTextDidChange:note];
}

- (void)searchChanged:(id)s
{
    // 搜索框每敲一个键都会发 action（sendsWholeSearchString 默认为 NO），而一次搜索
    // 是整棵树的全量遍历。十万条目的归档里连续输入会明显发涩，所以先防抖：停下
    // 120ms 才真正搜，期间只取消上一次待执行的请求。
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(runSearch)
                                               object:nil];
    [self performSelector:@selector(runSearch) withObject:nil afterDelay:0.12];
}

- (void)runSearch
{
    NSString *q = self.searchField.stringValue;

    if (!q.length) {
        // 清空是即时动作：没有计算量，不该让用户等那 120ms 的防抖窗口。
        self.contentGeneration++;       // 作废在途搜索
        self.filtering = NO;
        self.displayRoots = self.roots;
        [self.outline reloadData];
        [self updateEmptyState];
        [self showStatus:[NSString stringWithFormat:@"共 %lu 个顶层条目",
                          (unsigned long)self.roots.count]];
        return;
    }

    self.filtering = YES;
    NSUInteger gen = ++self.contentGeneration;
    // 捕获当前的树：搜索期间用户可能又打开了别的归档，那时 me.contentGeneration 会
    // 变，这份结果自然被丢弃，不会把旧命中写到新树的界面上。
    NSArray<Z7Node *> *roots = self.roots;
    __weak MainViewController *weakSelf = self;
    [self.workQueue addOperationWithBlock:^{
        NSMutableArray<Z7Node *> *hits = [NSMutableArray array];
        NSMutableArray<Z7Node *> *stack = [NSMutableArray arrayWithArray:roots];
        while (stack.count) {
            Z7Node *n = stack.lastObject;
            [stack removeLastObject];
            if ([n.path rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [hits addObject:n];
            }
            [stack addObjectsFromArray:n.children];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            MainViewController *me = weakSelf;
            if (!me) return;
            if (me.contentGeneration != gen) return;    // 已被更晚的输入取代
            me.displayRoots = hits;
            [me.outline reloadData];
            [me updateEmptyState];
            [me showStatus:[NSString stringWithFormat:@"匹配 %lu 项", (unsigned long)hits.count]];
        });
    }];
}

#pragma mark 提取

- (NSArray<Z7Node *> *)selectedNodes
{
    // 直接取选中行集合，而不是从第 0 行扫到 numberOfRows。旧写法在十万条目的
    // 归档里每次都要走完全表（删除 / 解压 / 预览 / 菜单校验各一次），且稀疏选择
    // 下的代价与实际选中数无关。selectedRowIndexes 的代价只与选中数相关。
    NSMutableArray<Z7Node *> *out = [NSMutableArray array];
    NSInteger rows = self.outline.numberOfRows;
    // 用 enumerateIndexesUsingBlock: 而不是 for-in：NSIndexSet 的快枚举协议在
    // SDK 头里没有声明（clang 会报 may not respond to countByEnumeratingWithState:），
    // 这也正是 Apple 推荐的下标集合遍历方式。
    [self.outline.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger r, BOOL *stop) {
        if ((NSInteger)r >= rows) return;
        Z7Node *n = [self.outline itemAtRow:(NSInteger)r];
        if (n) [out addObject:n];
    }];
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
    [self addPaths:paths];
}

/// 加入归档的实际动作。文件选择面板与「拖入归档窗口」两条入口共用它，
/// 免得两条路径各写一份、行为逐渐分叉。
- (void)addPaths:(NSArray<NSString *> *)inputPaths
{
    if (!self.archivePath || !inputPaths.count) return;
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:inputPaths.count];
    for (NSString *s in inputPaths) if (s.length) [paths addObject:s];
    if (!paths.count) return;

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

/// 在目录下取一个不冲突的归档路径：name.7z / name 2.7z / name 3.7z …
static NSString *UniqueArchivePath(NSString *dir, NSString *base, NSString *ext)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *cand = [dir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"%@.%@", base, ext]];
    NSInteger n = 2;
    while ([fm fileExistsAtPath:cand]) {
        cand = [dir stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%@ %ld.%@", base, (long)n++, ext]];
    }
    return cand;
}

- (void)compressURLs:(NSArray<NSURL *> *)urls
{
    if (!urls.count) return;

    // 密码不一致时不静默继续：弹回面板并说明原因
    NSString *msg = nil;
    if (![self validatePasswordMatch:&msg]) {
        NSBeep();
        [self showStatus:msg];
        [self appendLog:[msg stringByAppendingString:@"\n"] reveal:YES];
        [self showOptions:self.optionsBtn];
        return;
    }

    NSString *fmt = [self selectedFormat];
    Z7CompressionOptions *opts = [self currentOptions];
    BOOL separate = (self.separateCheck.state == NSControlStateValueOn);

    // batch 每项 = @[目标归档路径, @[输入路径…]]；不勾「分别压缩」时只有一项。
    NSMutableArray<NSArray *> *batch = [NSMutableArray array];

    if (separate) {
        // 每个顶层项各建一个包：只问一次输出目录，包名取自各项自身名称
        NSOpenPanel *dp = [NSOpenPanel openPanel];
        dp.canChooseFiles = NO;
        dp.canChooseDirectories = YES;
        dp.allowsMultipleSelection = NO;
        dp.canCreateDirectories = YES;
        dp.prompt = @"在此建包";
        dp.message = @"选择输出目录（每个文件各建一个归档）";
        dp.directoryURL = urls[0].URLByDeletingLastPathComponent;
        if ([dp runModal] != NSModalResponseOK) return;
        NSString *outDir = dp.URL.path;
        for (NSURL *u in urls) {
            [batch addObject:@[UniqueArchivePath(outDir, u.lastPathComponent, fmt), @[u.path]]];
        }
    } else {
        NSString *base = urls.count == 1 ? urls[0].lastPathComponent : @"归档";
        NSString *dir  = urls[0].URLByDeletingLastPathComponent.path ?: NSHomeDirectory();

        NSSavePanel *sp = [NSSavePanel savePanel];
        sp.message = @"保存归档";
        sp.nameFieldStringValue = [NSString stringWithFormat:@"%@.%@", base, fmt];
        sp.directoryURL = [NSURL fileURLWithPath:dir];
        if ([sp runModal] != NSModalResponseOK) return;

        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSURL *u in urls) [paths addObject:u.path];
        [batch addObject:@[sp.URL.path, paths]];
    }

    [self runCreateBatch:batch index:0 options:opts];
}

/// 逐个建包。任务必须串行——引擎同一时刻只允许一个会话，
/// 因此用「上一个结束回调里启动下一个」的方式排队。
- (void)runCreateBatch:(NSArray<NSArray *> *)batch
                 index:(NSUInteger)idx
               options:(Z7CompressionOptions *)opts
{
    if (idx >= batch.count) return;

    NSString *dest = batch[idx][0];
    NSArray<NSString *> *inputs = batch[idx][1];
    BOOL verify = (self.verifyAfterCheck.state == NSControlStateValueOn);
    BOOL dropSource = (self.deleteSourceCheck.state == NSControlStateValueOn);

    Z7Task *t = [[Z7Task alloc] init];
    t.kind = Z7TaskKindCreate;
    t.title = [NSString stringWithFormat:@"正在压缩 %lu 项", (unsigned long)inputs.count];
    t.archivePath = dest;
    t.inputPaths = inputs;
    t.options = opts;
    t.verifyAfterCreate = verify;

    __weak MainViewController *weakSelf = self;
    [self runTask:t after:^(BOOL ok, NSError *error) {
        MainViewController *me = weakSelf;
        if (!me) return;
        if (ok) {
            [me appendLog:[NSString stringWithFormat:@"压缩完成：%@\n",
                           dest.lastPathComponent]];
            if (dropSource) [me trashPaths:inputs];
        } else {
            NSString *m = [NSString stringWithFormat:@"压缩失败（%@）：%@",
                           dest.lastPathComponent, error.localizedDescription];
            [me showStatus:m];
            [me appendLog:[m stringByAppendingString:@"\n"] reveal:YES];
        }

        if (idx + 1 < batch.count) {
            [me runCreateBatch:batch index:idx + 1 options:opts];
            return;
        }
        if (ok) {
            [me showStatus:@"压缩完成"];
            // 新归档用面板口令加密，因此直接把该口令交给打开流程，
            // 而不是让用户立刻为刚建的归档再输一次。
            NSString *pw = opts.password.length ? opts.password : nil;
            [me openArchive:dest password:pw];
        }
    }];
}

/// 「压缩完成后删除源文件」：一律走废纸篓，绝不直接 unlink——可恢复、可撤销。
- (void)trashPaths:(NSArray<NSString *> *)paths
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger failed = 0;
    for (NSString *p in paths) {
        NSError *e = nil;
        if (![fm trashItemAtURL:[NSURL fileURLWithPath:p] resultingItemURL:nil error:&e]) {
            failed++;
            NSString *m = [NSString stringWithFormat:@"无法移到废纸篓：%@（%@）",
                           p.lastPathComponent, e.localizedDescription];
            [self appendLog:[m stringByAppendingString:@"\n"] reveal:YES];
        }
    }
    if (failed < paths.count) {
        [self appendLog:[NSString stringWithFormat:@"已把 %lu 个源项目移到废纸篓\n",
                         (unsigned long)(paths.count - failed)]];
    }
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

/// 选中项变化时刷新状态栏右侧的「已选 N 项 · 合计 X」。
- (void)outlineViewSelectionDidChange:(NSNotification *)note
{
    [self updateOptionsSummary];
}

#pragma mark 拖入：把文件加入当前归档

/// 拖到已打开归档的窗口里 = 把文件加进这个归档（Windows 版 7-Zip 就是这么用的）。
///
/// 列表在空状态下由 DropView 接「拖入即打开」，归档打开后列表盖住它，于是拖进来
/// 什么反应也没有——旧版本正是如此。这里补上列表侧的投放：
///   * 行内拖动（draggingSource 是列表自己）是我们的拖出提取，交给系统落盘，
///     绝不能被当成「加入归档」；
///   * 没有归档、或正在跑任务时不接受投放。
- (NSDragOperation)outlineView:(NSOutlineView *)ov
                  validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(id)item
            proposedChildIndex:(NSInteger)index
{
    if (info.draggingSource == self.outline) return NSDragOperationNone;
    if (!self.archivePath.length || self.current) return NSDragOperationNone;
    NSArray *urls = [info.draggingPasteboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    return urls.count ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)outlineView:(NSOutlineView *)ov
         acceptDrop:(id<NSDraggingInfo>)info
               item:(id)item
         childIndex:(NSInteger)index
{
    NSArray<NSURL *> *urls = [info.draggingPasteboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (!urls.count) return NO;

    NSString *current = self.archivePath;
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *u in urls) {
        // 把归档拖到它自己的窗口上只会变成「归档加入自己」，直接忽略。
        if (current && [u.path isEqualToString:current]) continue;
        if (u.path.length) [paths addObject:u.path];
    }
    if (!paths.count) { NSBeep(); return NO; }

    // 投放会真的改写用户的归档，且「拖到列表上」的语义不如点「添加文件…」明确，
    // 所以这里先确认一次再动手。
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [NSString stringWithFormat:@"将 %lu 项加入归档？", (unsigned long)paths.count];
    a.informativeText = [NSString stringWithFormat:@"目标：%@\n归档会被重新打包。",
                         current.lastPathComponent ?: @""];
    [a addButtonWithTitle:@"加入"];
    [a addButtonWithTitle:@"取消"];
    if ([a runModal] != NSAlertFirstButtonReturn) return NO;

    [self addPaths:paths];
    return YES;
}

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
        // 引擎按条目在归档内的**完整路径**落盘：归档里的 src/docs/a.md 会解成
        // destDir/src/docs/a.md。所以先按 n.path 找。
        //
        // 旧实现只拼 basename（destDir/a.md），于是**凡是位于子目录里的条目，预览
        // 一律误报「无法提取条目」**——文件其实已经正确解出来了，只是找错了地方。
        // 实测证据：选中 src/docs/report-6.md 按空格，临时目录里确实有
        // z7preview.*/src/docs/report-6.md，而状态栏报失败。
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *produced = [t.destDir stringByAppendingPathComponent:n.path];
        if (![fm fileExistsAtPath:produced]) {
            // 兼容被工具剥掉路径前缀的归档（条目实际落在根下）。
            NSString *byName = [t.destDir stringByAppendingPathComponent:n.name];
            if ([fm fileExistsAtPath:byName]) produced = byName;
        }
        if (!ok || ![fm fileExistsAtPath:produced]) {
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
    QLPreviewPanel *panel = [QLPreviewPanel sharedPreviewPanel];
    if ([QLPreviewPanel sharedPreviewPanelExists] && panel.isVisible) {
        [panel orderOut:nil];
        return;
    }

    // QLPreviewPanel 是全局单例，它要沿响应链找到愿意接管它的控制器
    // （acceptsPreviewPanelControl: / beginPreviewPanelControl:）才会装上数据源，
    // 而响应链的起点是**当前 key window**。用户完全可能从一个非 key 的窗口触发
    // 预览（多窗口下很常见），那时数据源装不上，面板就会挂在那儿显示
    // 「未选定项目」——实测（2026-09-24）就是这个现象。
    // 所以：先把本窗口置前，再让面板出现，出现后立刻 reloadData 让它按最新数据源
    // 重新取一次条目数。
    [self.view.window makeKeyAndOrderFront:nil];
    [panel makeKeyAndOrderFront:nil];
    [panel reloadData];
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

#pragma mark - 窗口控制器（一个归档一个窗口）

/// 把关一个归档所需的一切收进一个 NSWindowController。
///
/// 旧实现是「全局唯一窗口 + 全局唯一任务」：第二个任务进来只会响一声「已有任务在
/// 执行」，用户必须先等前一个跑完才能动手。多窗口之后，用户可以在任意窗口随时发起
/// 操作，也能同时开着几个归档来回切换。
///
/// 注意「并行」的确切边界：窗口、界面、任务队列是并行的；**引擎调用不是**——
/// lib7z 没有跨会话的同步原语，所有引擎调用由 Z7EngineLock 全局串行（那里的注释
/// 说明了理由）。已载入归档的浏览与搜索不经过引擎，所以确实可以一边等任务、一边
/// 翻看另一个归档。
///
/// tabbingIdentifier 相同，于是系统允许把这些窗口合并为标签页——是否合并由
/// 「系统设置 › 桌面与程序坞 › 窗口」里的用户偏好决定，应用不替用户下这个判断。
@interface Z7WindowController : NSWindowController <NSWindowDelegate>
@property (nonatomic, strong) MainViewController *vc;
/// 窗口关闭时回调，让持有者把控制器从窗口列表里摘掉。
@property (nonatomic, copy) void (^onClose)(Z7WindowController *wc);
@end

@implementation Z7WindowController

- (instancetype)init
{
    // 尺寸只是初值：紧接着的 setFrameAutosaveName: 会用上次保存的框架覆盖它。
    NSRect frame = NSMakeRect(0, 0, 560, 420);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                   NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
          backing:NSBackingStoreBuffered defer:NO];
    self = [super initWithWindow:w];
    if (!self) return nil;

    w.title = @"7-Zip";
    w.backgroundColor = [NSColor windowBackgroundColor];
    // 统一工具栏：标题与工具栏同处一行，内容区从工具栏下方开始。
    w.toolbarStyle = NSWindowToolbarStyleUnified;
    // 先钉下最小尺寸，再挂 contentViewController：否则窗口会按内容的自适应尺寸
    // 收缩（内容区是显式 frame，不参与约束，窗口宽度无从约束）。
    w.contentMinSize = NSMakeSize(460, 320);
    w.minSize = NSMakeSize(460, 320);
    w.tabbingIdentifier = @"7ZipArchive";
    w.delegate = self;

    _vc = [[MainViewController alloc] init];
    w.contentViewController = _vc;
    w.toolbar = _vc.toolbar;

    // setFrameAutosaveName: 返回是否恢复了上次保存的框架；首次运行没有记录时窗口
    // 会停在内容自适应得到的最小尺寸上，这里显式给回默认尺寸。
    // 键名带版本后缀：早先的版本已把 1040×700 写进 @"7ZipMainWindow"，沿用旧名会
    // 让新默认尺寸被那份历史记录永久盖掉（改尺寸时必须一并换名）。
    if (![w setFrameAutosaveName:@"7ZipMainWindow2"]) {
        [w setContentSize:NSMakeSize(560, 420)];
        [w center];
    }
    return self;
}

- (void)windowWillClose:(NSNotification *)n
{
    if (self.onClose) self.onClose(self);
}

/// 任务进行中关窗口，会让这个任务失去唯一的界面：进度看不见了，「停止」按钮也
/// 没得点。任务本身还在后台把盘写完（它被 operation 持有），于是用户会以为已经
/// 取消了。多窗口架构下尤其容易发生——用户可能只是想关掉旁边那个窗口。
/// 所以先问一句，并说清「关了会怎样」。
- (BOOL)windowShouldClose:(NSWindow *)sender
{
    Z7Task *task = self.vc.current;
    if (!task) return YES;

    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"任务尚未完成";
    a.informativeText = [NSString stringWithFormat:
        @"「%@」还在进行中。现在关闭窗口会失去进度显示与「停止」入口，"
        @"任务会在后台继续执行完并写入磁盘。", task.title ?: @"当前任务"];
    [a addButtonWithTitle:@"继续关闭"];
    [a addButtonWithTitle:@"取消"];
    return [a runModal] == NSAlertFirstButtonReturn;
}

@end

#pragma mark - app delegate

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
/// 活着的窗口。关掉的窗口会通过 Z7WindowController.onClose 自我摘除。
@property (nonatomic, strong) NSMutableArray<Z7WindowController *> *windowControllers;
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
    [fileMenu addItemWithTitle:@"新建归档…" action:@selector(doCompressPick:) keyEquivalent:@"n"];
    [fileMenu addItemWithTitle:@"打开归档…" action:@selector(doOpen:) keyEquivalent:@"o"];
    // 「打开最近使用」由 menuNeedsUpdate: 在弹出时填充——最近列表是会变的，
    // 菜单内容不能在建菜单时一次性定死。
    NSMenuItem *recentItem = [[NSMenuItem alloc] initWithTitle:@"打开最近使用"
                                                       action:nil keyEquivalent:@""];
    NSMenu *recentMenu = [[NSMenu alloc] initWithTitle:@"打开最近使用"];
    recentMenu.delegate = self;
    recentItem.submenu = recentMenu;
    [fileMenu addItem:recentItem];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"解压到…" action:@selector(doExtract:) keyEquivalent:@"e"];
    [fileMenu addItemWithTitle:@"添加文件…" action:@selector(doAdd:) keyEquivalent:@"d"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"测试归档" action:@selector(doTest:) keyEquivalent:@"t"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    // 多窗口下 ⌘W 的含义是「关掉这个归档的窗口」。不设 target，让响应链把它交给
    // key window——只作用于前台窗口，正是用户预期的语义。
    [fileMenu addItemWithTitle:@"关闭窗口" action:@selector(performClose:) keyEquivalent:@"w"];
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
    [viewMenu addItem:[NSMenuItem separatorItem]];
    // 进入/退出全屏幕：窗口本来就可缩放，是全屏幕的合格对象，但 AppKit 只在
    // 窗口菜单里放「平铺」之类的排布命令，不会替你生成这一条。快捷键 ⌃⌘F 是
    // macOS 的固定约定，不写这条用户就只能靠绿色按钮，键盘用户没有入口。
    NSMenuItem *fsItem = [viewMenu addItemWithTitle:@"进入全屏幕"
                                             action:@selector(toggleFullScreen:)
                                      keyEquivalent:@"f"];
    fsItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
    viewItem.submenu = viewMenu;

    // 窗口
    NSMenuItem *winItem = [[NSMenuItem alloc] init];
    [bar addItem:winItem];
    NSMenu *winMenu = [[NSMenu alloc] initWithTitle:@"窗口"];
    [winMenu addItemWithTitle:@"最小化" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [winMenu addItemWithTitle:@"缩放" action:@selector(performZoom:) keyEquivalent:@""];
    [winMenu addItemWithTitle:@"全部置于顶层" action:@selector(arrangeInFront:) keyEquivalent:@""];
    // 注册为系统的「窗口」菜单后，AppKit 会自己在末尾维护窗口列表与标签页管理项
    // （显示上一个/下一个标签页、合并所有窗口…）。手写这些条目只会失去系统一致性，
    // 例如系统会按「系统设置」里的标签页偏好决定是否显示它们。
    winItem.submenu = winMenu;
    NSApp.windowsMenu = winMenu;

    // 帮助菜单。菜单栏里这是个固定位置，缺了它整条菜单栏就不完整。内容只放
    // 真正有用的两条：本应用里「帮助」约等于「怎么找东西」，所以把焦点动作
    // （搜索列表）与项目文档放在这里。
    NSMenuItem *helpItem = [[NSMenuItem alloc] init];
    [bar addItem:helpItem];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"帮助"];
    [helpMenu addItemWithTitle:@"搜索归档内的条目（⌘F）"
                        action:@selector(performFindPanelAction:) keyEquivalent:@""];
    [helpMenu addItem:[NSMenuItem separatorItem]];
    [helpMenu addItemWithTitle:@"7-Zip 使用说明"
                        action:@selector(showDocumentation:) keyEquivalent:@"?"];
    [helpMenu addItemWithTitle:@"7-Zip 官方网站"
                        action:@selector(showSevenZipWebsite:) keyEquivalent:@""];
    helpItem.submenu = helpMenu;
    NSApp.helpMenu = helpMenu;   // 登记后系统才会把它当作帮助菜单处理

    NSApp.mainMenu = bar;
}

- (void)showDocumentation:(id)s
{
    // 项目主页的 README 就是这本应用的说明书。
    NSURL *u = [NSURL URLWithString:@"https://github.com/XINKEJU/7-Zip-macOS#readme"];
    if (u) [[NSWorkspace sharedWorkspace] openURL:u];
}

- (void)showSevenZipWebsite:(id)s
{
    NSURL *u = [NSURL URLWithString:@"https://www.7-zip.org/"];
    if (u) [[NSWorkspace sharedWorkspace] openURL:u];
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

    // 启动即给一个空窗口——空窗口本身就是「把归档拖进来」的投放目标。
    //
    // 但只在这时候还没有任何窗口时才这么做：启动时若带着文件（Finder 里双击归档），
    // openURLs: 会先于本方法执行并已经建好那个归档的窗口。无条件再开一个空窗口的话，
    // 系统会把两个窗口并成标签页、并把后建的空窗口顶在前面——用户看到的是一句
    // 「未打开归档」，以为双击没反应，而归档其实已经读出来了、只是躲在后台标签页里。
    // 实测（2026-09-24）就是这个现象。
    if (self.windowControllers.count == 0) [self newWindowAndShow:YES];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }

- (void)applicationWillTerminate:(NSNotification *)n
{
    [[Z7TempRegistry shared] cleanupAll];
}

#pragma mark 窗口管理

- (NSMutableArray<Z7WindowController *> *)windowControllers
{
    if (!_windowControllers) _windowControllers = [NSMutableArray array];
    return _windowControllers;
}

- (Z7WindowController *)newWindowAndShow:(BOOL)show
{
    Z7WindowController *wc = [[Z7WindowController alloc] init];
    __weak AppDelegate *weakSelf = self;
    wc.onClose = ^(Z7WindowController *w) { [weakSelf.windowControllers removeObject:w]; };
    [self.windowControllers addObject:wc];

    // 与上一个窗口错开摆放，避免多个窗口完全重叠（macOS 新窗口的级联习惯）。
    NSWindow *prev = self.windowControllers.count > 1
        ? self.windowControllers[self.windowControllers.count - 2].window : nil;
    if (prev && prev.isVisible) {
        [wc.window setFrameTopLeftPoint:NSMakePoint(NSMinX(prev.frame) + 26.0,
                                                    NSMaxY(prev.frame) - 26.0)];
    }
    if (show) [wc showWindow:nil];
    return wc;
}

/// 可以当投放目标的窗口：还没打开任何归档，也没有任务在跑。
///
/// 从 Finder 拖归档进来时，如果桌面上正摆着这样一个空窗口，就应该复用它而不是
/// 再开一个——否则拖三次就多出三个空窗口，这是 Finder 与文本编辑器的共同习惯。
- (Z7WindowController *)vacantWindowController
{
    for (Z7WindowController *wc in self.windowControllers.reverseObjectEnumerator) {
        if (wc.vc.isVacant) return wc;
    }
    return nil;
}

/// 在合适的窗口里打开一个归档：优先复用空窗口，否则新开一个。
- (void)openArchive:(NSString *)path
{
    if (!path.length) return;
    Z7WindowController *wc = [self vacantWindowController] ?: [self newWindowAndShow:NO];
    [wc showWindow:nil];
    [wc.window makeKeyAndOrderFront:nil];
    [wc.vc openArchive:path];
}

- (void)openPathOnLaunch:(NSString *)path
{
    [self openArchive:path];
    [NSApp activateIgnoringOtherApps:YES];
}

/// Finder / LaunchServices 投递文件的主入口。
///
/// 用 macOS 10.13 起的 `application:openURLs:`，**不**再实现已废弃的
/// `application:openFiles:`：两者同时实现时，同一次「用 7-Zip 打开」存在被投递
/// 两次的风险（表现为凭空多出一个窗口）。部署目标是 11.0，新入口一定存在。
/// 本应用未开启 App Sandbox，URL 直接就是可用路径，无需 security-scoped 访问。
- (void)application:(NSApplication *)app openURLs:(NSArray<NSURL *> *)urls
{
    // 更早的实现逐个遍历却只处理第一个（循环体里 break），于是从 Finder 选中多个
    // 归档拖到程序坞图标上时只有一个会被打开。多窗口下每个文件都有归宿，全部打开。
    for (NSURL *u in urls) {
        if (u.isFileURL && u.path.length) [self openArchive:u.path];
    }
}

/// 点按程序坞图标而当前没有可见窗口时，给一个空窗口，而不是让应用「在运行但看不见」。
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag
{
    if (!flag) [self newWindowAndShow:YES];
    return YES;
}

/// 程序坞图标右键菜单。菜单弹出时不一定有 key window，所以所有条目都显式指向
/// 本对象，而不是靠响应链去找 MainViewController。
///
/// 与「文件 › 打开最近使用」用同一份最近列表：右键程序坞图标直接回到刚才那几个
/// 归档，是 macOS 上最省事的一条路径（不用先把窗口切到前台）。
- (NSMenu *)applicationDockMenu:(NSApplication *)sender
{
    NSMenu *m = [[NSMenu alloc] init];
    NSMenuItem *n = [m addItemWithTitle:@"新建归档…" action:@selector(dockNewArchive:) keyEquivalent:@""];
    n.target = self;
    NSMenuItem *o = [m addItemWithTitle:@"打开归档…" action:@selector(dockOpenArchive:) keyEquivalent:@""];
    o.target = self;

    NSArray<NSString *> *recent = Z7RecentPaths();
    if (recent.count) {
        [m addItem:[NSMenuItem separatorItem]];
        NSUInteger shown = MIN(recent.count, (NSUInteger)5);
        for (NSUInteger i = 0; i < shown; i++) {
            NSString *p = recent[i];
            NSMenuItem *it = [m addItemWithTitle:p.lastPathComponent
                                          action:@selector(dockOpenPath:)
                                   keyEquivalent:@""];
            it.target = self;
            it.representedObject = p;
            it.toolTip = p;
        }
    }
    return m;
}

- (void)dockOpenPath:(NSMenuItem *)item
{
    NSString *p = item.representedObject;
    if (!p.length) return;
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
        Z7ForgetRecentPath(p);      // 顺带清掉失效记录，别让它一直挂在菜单里
        NSBeep();
        return;
    }
    [self openArchive:p];
}


- (void)dockNewArchive:(id)s
{
    [self dockTarget:^(MainViewController *vc) { [vc doCompressPick:nil]; }];
}

- (void)dockOpenArchive:(id)s
{
    [self dockTarget:^(MainViewController *vc) { [vc doOpen:nil]; }];
}

- (void)dockTarget:(void (^)(MainViewController *vc))action
{
    Z7WindowController *wc = [self vacantWindowController] ?: [self newWindowAndShow:YES];
    [wc showWindow:nil];
    [wc.window makeKeyAndOrderFront:nil];
    action(wc.vc);
}

// macOS 13 起，未声明安全状态恢复的应用会被系统提示「未能恢复窗口」。本应用不做
// 窗口状态恢复（关闭即退出），显式声明支持即可消除这条噪音，而不是留一个假的恢复路径。
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { return YES; }

#pragma mark 最近使用

/// 菜单弹出时才填内容：最近列表每打开一个归档就变，建菜单时定死会一直显示旧内容。
- (void)menuNeedsUpdate:(NSMenu *)menu
{
    [menu removeAllItems];

    NSArray<NSString *> *recent = Z7RecentPaths();
    if (!recent.count) {
        NSMenuItem *empty = [menu addItemWithTitle:@"没有最近使用的归档"
                                           action:nil keyEquivalent:@""];
        empty.enabled = NO;
        return;
    }

    for (NSString *p in recent) {
        NSMenuItem *it = [menu addItemWithTitle:p.lastPathComponent
                                        action:@selector(openRecent:)
                                 keyEquivalent:@""];
        it.target = self;
        it.representedObject = p;
        it.toolTip = p;     // 同名文件靠位置区分，悬停能看到完整路径
    }

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *clear = [menu addItemWithTitle:@"清除菜单"
                                        action:@selector(clearRecent:)
                                 keyEquivalent:@""];
    clear.target = self;
}

- (void)openRecent:(NSMenuItem *)item
{
    NSString *p = item.representedObject;
    if (!p.length) return;

    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
        // 归档被移走或删掉时既不要静默失败，也不要留着这条死记录。
        Z7ForgetRecentPath(p);
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"找不到归档";
        a.informativeText = [NSString stringWithFormat:@"「%@」已被移动或删除，已从列表中移除。", p];
        [a addButtonWithTitle:@"好"];
        [a runModal];
        return;
    }
    [self openArchive:p];
}

- (void)clearRecent:(id)s
{
    Z7ClearRecentPaths();
}


#pragma mark 服务

- (void)compressWithSevenZip:(NSPasteboard *)pboard
                    userData:(NSString *)userData
                       error:(NSString **)error
{
    NSArray *urls = [pboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (!urls.count) { if (error) *error = @"没有收到文件"; return; }
    [self dockTarget:^(MainViewController *vc) { [vc compressURLs:urls]; }];
}

- (void)extractWithSevenZip:(NSPasteboard *)pboard
                   userData:(NSString *)userData
                      error:(NSString **)error
{
    NSArray *urls = [pboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (!urls.count) { if (error) *error = @"没有收到归档"; return; }

    // 「打开完再解压」必须挂在打开完成的回调上：旧实现用 afterDelay:0.4 猜时间，
    // 大归档 0.4 秒还没读完列表，解压就落到一个空窗口上、静默什么也不做。
    Z7WindowController *wc = [self vacantWindowController] ?: [self newWindowAndShow:NO];
    [wc showWindow:nil];
    [wc.window makeKeyAndOrderFront:nil];
    [wc.vc openArchive:[urls[0] path] thenRun:^(BOOL ok) {
        if (ok) [wc.vc doExtract:nil];
    }];
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
