// objc_test.m
//
// Objective-C 适配层（SevenZipEngineObjC）验收测试。
//
// 为什么单独做这一层测试：
//   engine_test 覆盖的是纯 C++ 桥接层；而 App 只接触 Objective-C 层。
//   两者之间存在一整套翻译逻辑（值类型映射、ARC 生命周期、错误域、
//   回调跨线程转发），这层若出错，App 会以"崩溃/静默失败"的形式暴露，
//   排查成本远高于在这里断言。
//
// 用法：objc_test <workdir>

#import <Foundation/Foundation.h>
// 菜单栏状态图标那一节要直接用 AppKit（NSStatusItem / NSStatusBarButton）和
// runtime（class_addMethod 的装配结果只能从 type encoding 上核对）。
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#import "SevenZipEngineObjC.h"
#import "Z7StatusItem.h"
#import "Z7ListContextMenu.h"
#import "Z7CompressionPrefs.h"
#import "Z7OutlineView.h"

static int g_pass = 0;
static int g_fail = 0;
static int g_skip = 0;

static void ok(BOOL cond, NSString *what) {
    if (cond) {
        g_pass++;
        printf("  PASS  %s\n", what.UTF8String);
    } else {
        g_fail++;
        printf("  FAIL  %s\n", what.UTF8String);
    }
}

// 环境本身不具备某项能力时用它。刻意与 ok() 分开：把这类断言写成恒真（例如
// 「拿不到状态栏按钮就当作通过」）会让门禁在真正的环境里也永远绿灯，等于没测。
static void skip(NSString *what) {
    g_skip++;
    printf("  SKIP  %s\n", what.UTF8String);
}

#pragma mark - 回调

@interface TestCallback : NSObject <Z7Callback>
@property (nonatomic, assign) NSInteger progressCalls;
@property (nonatomic, assign) NSInteger logCalls;
@end

@implementation TestCallback
- (void)engineProgress:(Z7Progress *)p {
    _progressCalls++;
    (void)p;
}
- (BOOL)engineIsCanceled { return NO; }
- (NSString *)enginePasswordForRetry:(BOOL)retry {
    return retry ? nil : nil;
}
- (void)engineLog:(NSString *)m level:(Z7LogLevel)l {
    _logCalls++;
    (void)m; (void)l;
}
@end

#pragma mark - 状态栏拖放接收方

// 应用的 AppDelegate 扮演的角色，这里用一个最小替身。测试不模拟真实拖放事件
// （那需要合成鼠标事件，本机 CGEventPost 无效），只验证装配结果与接收方契约。
@interface TestDropReceiver : NSObject <Z7StatusDropReceiver>
@property (nonatomic, assign) NSInteger calls;
@property (nonatomic, copy) NSArray<NSURL *> *lastURLs;
@end

@implementation TestDropReceiver
- (void)statusItemReceivedURLs:(NSArray<NSURL *> *)urls {
    _calls++;
    _lastURLs = urls;
}
@end

#pragma mark - 列表事件的替身接收方

// 只记调用次数。keyDown: 的分发不依赖窗口（只读 charactersIgnoringModifiers），
// 所以合成键盘事件可以真实驱动它，不像鼠标事件那样在本机被静默丢弃。
@interface TestOutlineDelegate : NSObject <Z7OutlineKeyDelegate>
@property (nonatomic, assign) NSInteger spaceCount;
@property (nonatomic, assign) NSInteger deleteCount;
@end

@implementation TestOutlineDelegate
- (void)outlineDidPressSpace  { _spaceCount++; }
- (void)outlineDidPressDelete { _deleteCount++; }
@end

/// 菜单项标题的指纹（分隔线记作 ---），用来一眼看出结构变化。
static NSString *MenuTitleSignature(NSMenu *m) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSMenuItem *it in m.itemArray) {
        [parts addObject:it.isSeparatorItem ? @"---" : it.title];
    }
    return [parts componentsJoinedByString:@" | "];
}

/// 菜单项动作名的指纹（分隔线记作 -）。菜单动作是字符串写的，拼错不会报错、
/// 只表现为「点了没反应」，所以要把名字本身也钉住。
static NSString *MenuActionSignature(NSMenu *m) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSMenuItem *it in m.itemArray) {
        if (it.isSeparatorItem) { [parts addObject:@"-"]; continue; }
        [parts addObject:it.action ? NSStringFromSelector(it.action) : @"(nil)"];
    }
    return [parts componentsJoinedByString:@" | "];
}

// 装配用的是运行期 class_addMethod，类型编码是**手写的字符串字面量**，写错不会
// 有编译错误，只会在 AppKit 回调时取到垃圾值。这里让编译器为同一组签名生成一份
// 编码当基准——它是 ABI 的事实来源，比任何人凭印象写的字面量都可靠。
@interface Z7ProbeDragTarget : NSObject <NSDraggingDestination>
@end

@implementation Z7ProbeDragTarget
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)s { (void)s; return NSDragOperationNone; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)s { (void)s; return NSDragOperationNone; }
- (void)draggingExited:(id<NSDraggingInfo>)s { (void)s; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)s { (void)s; return YES; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)s { (void)s; return YES; }
- (void)concludeDragOperation:(id<NSDraggingInfo>)s { (void)s; }
- (void)draggingEnded:(id<NSDraggingInfo>)s { (void)s; }
@end

// class_addMethod 收的编码只写返回类型与参数类型（不写偏移），编译器给的是带偏移
// 的完整形式（如 B24@0:8@16）。去掉数字再比，既校验类型字母正确，又不依赖具体 ABI 偏移。
static NSString *StripDigits(const char *enc) {
    NSMutableString *out = [NSMutableString string];
    for (const char *p = enc; p && *p; p++) {
        if (*p < '0' || *p > '9') [out appendFormat:@"%c", *p];
    }
    return out;
}

// 「方法装上了」不等于「拖放真的能跑通」。本机合成不了真实拖放事件（CGEventPost
// 被静默丢弃），所以这里造一个最小的 NSDraggingInfo 替身，直接驱动装上去的方法，
// 把「粘贴板里的文件 URL → 接收方」这条链路真正走一遍。这是本功能唯一可行的
// 端到端验证手段。
@interface Z7FakeDragInfo : NSObject <NSDraggingInfo>
@property (nonatomic, strong) NSPasteboard *pb;
@end

@implementation Z7FakeDragInfo
- (NSWindow *)draggingDestinationWindow { return nil; }
- (NSDragOperation)draggingSourceOperationMask { return NSDragOperationCopy; }
- (NSPoint)draggingLocation { return NSZeroPoint; }
- (NSPoint)draggedImageLocation { return NSZeroPoint; }
- (NSImage *)draggedImage { return nil; }
- (NSPasteboard *)draggingPasteboard { return _pb; }
- (id<NSDraggingSource>)draggingSource { return nil; }
- (NSInteger)draggingSequenceNumber { return 0; }
- (void)slideDraggedImageTo:(NSPoint)screenPoint { (void)screenPoint; }
- (NSArray<NSString *> *)namesOfPromisedFilesDroppedAtDestination:(NSURL *)dropDestination {
    (void)dropDestination; return @[];
}
- (void)enumerateDraggingItemsWithOptions:(NSDraggingItemEnumerationOptions)enumOpts
                                  forView:(NSView *)view
                                  classes:(NSArray<Class> *)classArray
                            searchOptions:(NSDictionary<NSPasteboardReadingOptionKey, id> *)searchOptions
                               usingBlock:(void (^)(NSDraggingItem *, NSInteger, BOOL *))block {
    (void)enumOpts; (void)view; (void)classArray; (void)searchOptions; (void)block;
}
@end

#pragma mark - helpers

static NSString *WriteFile(NSString *path, NSString *contents) {
    [contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return path;
}

static BOOL FileExists(NSString *p) {
    return [[NSFileManager defaultManager] fileExistsAtPath:p];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "用法: objc_test <workdir>\n");
            return 2;
        }
        NSString *work = [NSString stringWithUTF8String:argv[1]];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:NULL];

        printf("\n== A. 引擎能力查询 ==\n");
        NSString *ver = [Z7Engine engineVersion];
        ok(ver.length > 0, [NSString stringWithFormat:@"engineVersion = %@", ver]);

        NSArray<NSArray *> *formats = [Z7Engine supportedFormats];
        ok(formats.count > 5, [NSString stringWithFormat:@"supportedFormats 返回 %lu 项", (unsigned long)formats.count]);

        NSArray<NSString *> *writable = [Z7Engine writableFormats];
        ok([writable containsObject:@"7z"] && [writable containsObject:@"zip"],
           @"writableFormats 含 7z 与 zip");

        ok([[Z7Engine formatForExtension:@"7z"] isEqualToString:@"7z"],
           @"formatForExtension:7z -> 7z");
        ok([[Z7Engine formatForExtension:@"tar"] length] > 0,
           @"formatForExtension:tar 可解析");

        printf("\n== B. 创建归档（Z7Engine）==\n");
        NSString *srcDir = [work stringByAppendingPathComponent:@"src"];
        NSString *d1 = [srcDir stringByAppendingPathComponent:@"d1"];
        [fm createDirectoryAtPath:d1 withIntermediateDirectories:YES attributes:nil error:NULL];
        WriteFile([d1 stringByAppendingPathComponent:@"a.txt"], @"alpha\n");
        WriteFile([d1 stringByAppendingPathComponent:@"b.txt"], @"beta\n");

        NSString *arc = [work stringByAppendingPathComponent:@"a.7z"];
        [fm removeItemAtPath:arc error:NULL];

        Z7CompressionOptions *opt = [[Z7CompressionOptions alloc] init];
        opt.format = @"7z";
        opt.level = 1;

        TestCallback *cb = [[TestCallback alloc] init];
        NSError *err = nil;
        BOOL created = [Z7Engine createArchive:arc fromPaths:@[d1] options:opt callback:cb error:&err];
        ok(created && FileExists(arc), created ? @"创建归档成功" : [NSString stringWithFormat:@"创建失败: %@", err.localizedDescription]);

        printf("\n== C. 打开与枚举 ==\n");
        Z7Archive *a = [Z7Archive openPath:arc password:nil callback:cb error:&err];
        ok(a != nil, a ? @"打开归档成功" : [NSString stringWithFormat:@"打开失败: %@", err.localizedDescription]);
        if (!a) {
            printf("\n通过: %d   失败: %d\n", g_pass, g_fail);
            return g_fail == 0 ? 0 : 1;
        }
        ok([a.formatName isEqualToString:@"7z"], [NSString stringWithFormat:@"formatName = %@", a.formatName]);
        ok(a.itemCount >= 2, [NSString stringWithFormat:@"itemCount = %u", a.itemCount]);
        ok(a.headerEncrypted == NO, @"明文归档 headerEncrypted = NO");

        NSArray<Z7Item *> *items = [a allItems];
        ok(items.count == a.itemCount, @"allItems 数量与 itemCount 一致");

        Z7Item *file = nil, *dir = nil;
        for (Z7Item *it in items) {
            if (!it.isDirectory && [it.path hasSuffix:@"a.txt"]) file = it;
            if (it.isDirectory && [it.path isEqualToString:@"d1"]) dir = it;
        }
        ok(file != nil, @"枚举到文件条目 d1/a.txt");
        ok(file && [file.name isEqualToString:@"a.txt"], @"条目 name 为末段名称");
        ok(file && [file.parentPath isEqualToString:@"d1"], @"条目 parentPath 正确");
        ok(file && file.depth == 1, @"条目 depth = 1");
        ok(file && file.size == 6, [NSString stringWithFormat:@"条目 size = %llu", file ? file.size : 0]);
        ok(file && file.crcText.length == 8, @"条目 crcText 为 8 位十六进制");
        ok(file && file.attributeText.length == 10, [NSString stringWithFormat:@"attributeText = %@", file.attributeText]);
        ok(dir != nil, @"枚举到目录条目 d1");

        printf("\n== D. 解压 ==\n");
        NSString *outDir = [work stringByAppendingPathComponent:@"out"];
        [fm removeItemAtPath:outDir error:NULL];
        [fm createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:NULL];

        BOOL extracted = [a extractItems:nil to:outDir testMode:NO clash:Z7ClashPolicyOverwrite
                             atomicFiles:YES createLinks:YES callback:cb error:&err];
        ok(extracted, extracted ? @"全部解压成功" : [NSString stringWithFormat:@"解压失败: %@", err.localizedDescription]);
        ok(FileExists([outDir stringByAppendingPathComponent:@"d1/a.txt"]), @"解压产物 d1/a.txt 存在");

        Z7ExtractStats *st = a.lastStats;
        ok(st != nil && st.errors == 0, @"lastStats 报告 0 错误");
        ok(cb.progressCalls > 0, [NSString stringWithFormat:@"进度回调被调用 %ld 次", (long)cb.progressCalls]);

        printf("\n== E. 单条目提取 ==\n");
        NSString *one = [work stringByAppendingPathComponent:@"one.txt"];
        [fm removeItemAtPath:one error:NULL];
        BOOL oneOK = [a extractItemAtIndex:file.index toFile:one callback:cb error:&err];
        ok(oneOK && FileExists(one), oneOK ? @"extractItemAtIndex:toFile: 成功" : @"单条目提取失败");

        BOOL tooLarge = NO;
        NSData *blob = [a extractItemAtIndex:file.index maxBytes:1024 tooLarge:&tooLarge callback:cb error:&err];
        ok(blob.length == 6, [NSString stringWithFormat:@"内存提取得到 %lu 字节", (unsigned long)blob.length]);

        tooLarge = NO;
        NSData *small = [a extractItemAtIndex:file.index maxBytes:2 tooLarge:&tooLarge callback:cb error:&err];
        ok(small == nil && tooLarge, @"超出 maxBytes 时 tooLarge 置位且不返回数据");

        printf("\n== F. 更新（追加 / 跳过 / 替换）==\n");
        NSString *d2 = [srcDir stringByAppendingPathComponent:@"d2"];
        [fm createDirectoryAtPath:d2 withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *b2 = WriteFile([d2 stringByAppendingPathComponent:@"c.txt"], @"gamma\n");

        BOOL added = [a addPaths:@[b2] options:opt replaceExisting:NO callback:cb error:&err];
        ok(added, added ? @"追加条目成功" : [NSString stringWithFormat:@"追加失败: %@", err.localizedDescription]);
        ok(a.itemCount == 0, @"更新成功后 itemCount 被重置（对象已失效）");

        Z7Archive *a2 = [Z7Archive openPath:arc password:nil callback:cb error:&err];
        ok(a2 != nil, @"重新打开更新后的归档");
        BOOL hasNew = NO, keptOld = NO;
        for (Z7Item *it in [a2 allItems]) {
            if ([it.path isEqualToString:@"c.txt"]) hasNew = YES;
            if ([it.path isEqualToString:@"d1/a.txt"]) keptOld = YES;
        }
        ok(hasNew && keptOld, @"追加后既有条目保留且新条目存在");

        printf("\n== G. 删除 ==\n");
        BOOL removed = [a2 removePaths:@[@"d1/b.txt"] options:opt callback:cb error:&err];
        ok(removed, removed ? @"删除条目成功" : [NSString stringWithFormat:@"删除失败: %@", err.localizedDescription]);

        Z7Archive *a3 = [Z7Archive openPath:arc password:nil callback:cb error:&err];
        BOOL gone = YES, stillThere = NO;
        for (Z7Item *it in [a3 allItems]) {
            if ([it.path isEqualToString:@"d1/b.txt"]) gone = NO;
            if ([it.path isEqualToString:@"d1/a.txt"]) stillThere = YES;
        }
        ok(gone && stillThere, @"删除后目标条目消失、其余条目保留");

        printf("\n== H. 加密归档 ==\n");
        NSString *encArc = [work stringByAppendingPathComponent:@"enc.7z"];
        [fm removeItemAtPath:encArc error:NULL];
        opt.password = @"Pw-测试123";
        opt.encryptHeader = YES;
        opt.hasEncryptHeader = YES;
        BOOL encCreated = [Z7Engine createArchive:encArc fromPaths:@[d1] options:opt callback:cb error:&err];
        ok(encCreated, @"创建文件名加密归档成功");

        // 回调的 GetPassword 返回 nil，故无密码打开必须失败
        NSError *encErr = nil;
        Z7Archive *noPw = [Z7Archive openPath:encArc password:nil callback:cb error:&encErr];
        ok(noPw == nil && encErr != nil, @"无密码打开加密归档失败且带错误信息");

        Z7Archive *withPw = [Z7Archive openPath:encArc password:@"Pw-测试123" callback:cb error:&err];
        ok(withPw != nil, @"正确密码打开加密归档成功");
        ok(withPw.headerEncrypted == YES, @"加密归档 headerEncrypted = YES");

        // 删除后必须保持 -mhe（重建路径的安全性关键）
        if (withPw) {
            BOOL encRemoved = [withPw removePaths:@[@"d1/b.txt"] options:opt callback:cb error:&err];
            ok(encRemoved, @"加密归档删除成功");
            Z7Archive *after = [Z7Archive openPath:encArc password:@"Pw-测试123" callback:cb error:&err];
            ok(after != nil && after.headerEncrypted == YES, @"加密归档删除后仍保持文件名加密");
            NSError *e2 = nil;
            Z7Archive *shouldFail = [Z7Archive openPath:encArc password:nil callback:cb error:&e2];
            ok(shouldFail == nil, @"加密归档删除后无密码仍无法打开");
        }

        printf("\n== J. 压缩侧「排除 Mac 资源文件」开关 ==\n");
        {
            // 面板上的这个开关直通 CompressionOptions::excludeMacJunk。
            // 判定方式：建包后把归档解回磁盘，看 .DS_Store / ._* 有没有落盘——
            // 不能用 allItems 判定，因为列表侧始终过滤垃圾项（与压缩侧无关）。
            NSString *junkRoot = [work stringByAppendingPathComponent:@"junk"];
            NSString *srcDir = [junkRoot stringByAppendingPathComponent:@"src"];
            [fm createDirectoryAtPath:[srcDir stringByAppendingPathComponent:@"sub"]
          withIntermediateDirectories:YES attributes:nil error:NULL];
            [@"hi" writeToFile:[srcDir stringByAppendingPathComponent:@"normal.txt"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            [@"junk" writeToFile:[srcDir stringByAppendingPathComponent:@".DS_Store"]
                      atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            [@"ad" writeToFile:[srcDir stringByAppendingPathComponent:@"sub/._normal.txt"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL];

            TestCallback *jcb = [[TestCallback alloc] init];
            BOOL (^junkLandsOnDisk)(BOOL, NSString *) = ^BOOL(BOOL exclude, NSString *tag) {
                NSString *arc = [junkRoot stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"%@.7z", tag]];
                Z7CompressionOptions *o = [[Z7CompressionOptions alloc] init];
                o.format = @"7z";
                o.level = 1;
                o.excludeMacJunk = exclude;
                NSError *e = nil;
                if (![Z7Engine createArchive:arc fromPaths:@[srcDir] options:o
                                    callback:jcb error:&e]) {
                    ok(NO, [NSString stringWithFormat:@"建包失败（%@）：%@", tag,
                            e.localizedDescription]);
                    return YES;
                }
                NSString *out = [junkRoot stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"out-%@", tag]];
                [fm createDirectoryAtPath:out withIntermediateDirectories:YES
                               attributes:nil error:NULL];
                Z7Archive *a = [Z7Archive openPath:arc password:nil callback:jcb error:&e];
                if (!a) {
                    ok(NO, [NSString stringWithFormat:@"打开失败（%@）", tag]);
                    return YES;
                }
                [a extractItems:nil to:out testMode:NO clash:Z7ClashPolicyOverwrite atomicFiles:YES
                    createLinks:YES callback:jcb error:&e];
                return [fm fileExistsAtPath:
                        [out stringByAppendingPathComponent:@"src/.DS_Store"]]
                    || [fm fileExistsAtPath:
                        [out stringByAppendingPathComponent:@"src/sub/._normal.txt"]];
            };

            ok(junkLandsOnDisk(YES, @"excl") == NO,
               @"excludeMacJunk=YES 时 .DS_Store / ._* 不进归档");
            ok(junkLandsOnDisk(NO, @"keep") == YES,
               @"excludeMacJunk=NO 时 .DS_Store / ._* 按普通文件进归档（开关确实生效）");
            ok([fm fileExistsAtPath:
                [junkRoot stringByAppendingPathComponent:@"out-excl/src/normal.txt"]],
               @"两种设置下正常文件都被压缩");
        }

        printf("\n== K. 菜单栏状态图标 ==\n");
        {
            // 三态：从没设置过要显示（首次启动就该有常驻入口）；关掉要记住；清掉
            // 偏好要回到默认。这一节纯逻辑，不依赖窗口服务器。
            Z7ResetStatusItemPreference();
            ok(Z7StatusItemWanted() == YES, @"从未设置过时默认显示菜单栏图标");
            Z7SetStatusItemWanted(NO);
            ok(Z7StatusItemWanted() == NO, @"显式关闭后读回「不显示」");
            Z7SetStatusItemWanted(YES);
            ok(Z7StatusItemWanted() == YES, @"显式打开后读回「显示」");
            Z7ResetStatusItemPreference();
            ok(Z7StatusItemWanted() == YES, @"清除偏好后回到默认（显示）");

            // 装配。NSStatusBarButton 由系统创建、既不能子类化也不能替换，拖放方法
            // 只能在本进程内用 class_addMethod 补上。补错了没有运行时症状——界面上
            // 只表现为「拖上去没反应」，不报错、不留日志，所以必须在这里逐条核对
            // 方法的类型编码。
            NSStatusItem *si = [[NSStatusBar systemStatusBar]
                                   statusItemWithLength:NSSquareStatusItemLength];
            NSStatusBarButton *btn = si.button;
            if (btn == nil) {
                // 无窗口服务器（纯 ssh / 无 GUI 会话）时拿不到按钮。此时不能把断言
                // 写成恒真：那等于永远绿灯。显式 SKIP，并说明是环境原因。
                skip(@"拿不到状态栏按钮（无窗口服务器），跳过拖放装配断言");
            } else {
                Class cls = NSStatusBarButton.class;

                // 前提，同时也是哨兵。实测 NSView 自己就声明了 NSDraggingDestination
                // 的这几个方法，所以「沿继承链查得到」并不代表我们装过；而旧实现恰好
                // 拿 class_getInstanceMethod 当幂等守卫，导致 class_addMethod 永不执行
                // ——拖放整段成了死代码。这两条把那个前提钉在这里，将来系统改了
                // 继承关系会立刻报警，而不是让守卫又悄悄失效。
                ok(Z7StatusButtonDraggingInstalled() == NO,
                   @"装配前本模块的拖放处理尚未装上");
                ok(class_getInstanceMethod(cls, @selector(performDragOperation:)) != NULL,
                   @"但沿继承链确实查得到该方法（继承自 NSView，正是不能用它当守卫的原因）");

                TestDropReceiver *recv = [[TestDropReceiver alloc] init];
                Z7InstallStatusButtonDragging(si, recv);

                ok(Z7StatusButtonDraggingInstalled() == YES,
                   @"装配后本模块的拖放处理已装上");

                // 真正装上会覆盖掉继承来的那份实现，IMP 必然与 NSView 的不同。
                IMP ours = class_getMethodImplementation(cls, @selector(performDragOperation:));
                IMP base = class_getMethodImplementation(NSView.class,
                                                         @selector(performDragOperation:));
                ok(ours != base && ours != NULL,
                   @"装上去的是我们自己的实现（IMP 已覆盖 NSView 继承来的那份）");

                // 逐条核对类型编码，基准取编译器为同一签名生成的编码。
                SEL sels[] = { @selector(draggingEntered:), @selector(draggingUpdated:),
                               @selector(draggingExited:), @selector(prepareForDragOperation:),
                               @selector(performDragOperation:), @selector(concludeDragOperation:),
                               @selector(draggingEnded:) };
                for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
                    Method got = class_getInstanceMethod(cls, sels[i]);
                    Method want = class_getInstanceMethod(Z7ProbeDragTarget.class, sels[i]);
                    NSString *g = got ? StripDigits(method_getTypeEncoding(got)) : @"(缺失)";
                    NSString *w = StripDigits(method_getTypeEncoding(want));
                    ok([g isEqualToString:w],
                       [NSString stringWithFormat:@"%@ 编码与编译器一致（实际 %@，应为 %@）",
                        NSStringFromSelector(sels[i]), g, w]);
                }

                // 幂等：状态栏图标可以被用户关掉再打开，装配会被再次调用。第二次
                // 只更新内部弱引用，不能重新添加方法（重新添加会替换 IMP，是隐患）。
                Z7InstallStatusButtonDragging(si, nil);   // 换一个接收方，也不应崩
                Z7InstallStatusButtonDragging(si, recv);
                ok(Z7StatusButtonDraggingInstalled() == YES, @"重复装配后仍然处于已装上状态");
                ok(class_getMethodImplementation(cls, @selector(performDragOperation:)) == ours,
                   @"重复装配不替换已装好的 IMP（幂等）");

                ok([[btn registeredDraggedTypes] containsObject:NSPasteboardTypeFileURL],
                   @"状态栏按钮已注册文件 URL 拖放类型");

                // 接收方契约：协议方法确实被实现（编译期约束 + 运行期可响应）。
                ok([recv respondsToSelector:@selector(statusItemReceivedURLs:)],
                   @"接收方实现了 Z7StatusDropReceiver 的协议方法");

                // 端到端：把「拖进来的粘贴板内容 → 接收方」这条链路真正跑一遍。
                // 这一步才回答「拖上去有没有反应」，前面几条只说明装配对了。
                NSURL *dropped = [NSURL fileURLWithPath:
                                     [work stringByAppendingPathComponent:@"dropped.7z"]];
                NSPasteboard *pb = [NSPasteboard pasteboardWithUniqueName];
                [pb clearContents];
                ok([pb writeObjects:@[dropped]], @"构造拖放粘贴板（一个文件 URL）");

                Z7FakeDragInfo *info = [[Z7FakeDragInfo alloc] init];
                info.pb = pb;

                recv.calls = 0;
                recv.lastURLs = nil;
                BOOL handled = [(id)btn performDragOperation:(id<NSDraggingInfo>)info];
                ok(handled, @"文件拖到状态栏图标上返回「已处理」");
                ok(recv.calls == 1, @"拖进来的 URL 被转交给了接收方");
                ok(recv.lastURLs.count == 1 &&
                   [[[recv.lastURLs firstObject] path] isEqualToString:dropped.path],
                   @"转交的正是拖进来的那个文件");

                // 拖的不是文件（例如一段文本）时不该表态：图标不高亮、也不转交。
                // 拖放反馈必须与实际行为对得上，否则用户会以为放进去了。
                [pb clearContents];
                [pb setString:@"这不是文件" forType:NSPasteboardTypeString];
                recv.calls = 0;
                BOOL handledText = [(id)btn performDragOperation:(id<NSDraggingInfo>)info];
                ok(handledText == NO && recv.calls == 0,
                   @"非文件内容不触发接收方（图标不会假装接受）");
                [pb releaseGlobally];

                [[NSStatusBar systemStatusBar] removeStatusItem:si];
            }
            Z7ResetStatusItemPreference();   // 不留痕迹：测试进程用的是真实的偏好域
        }

        printf("\n== L. 压缩选项持久化 ==\n");
        {
            // 键与出厂值必须一一对应。少登记一个键 → 对应控件永远回默认值，
            // 而界面上看不出任何异常，是最难被发现的一类故障。
            NSArray<NSString *> *keys = @[
                kZ7OptFormatKey, kZ7OptLevelKey, kZ7OptMethodKey, kZ7OptDictKey,
                kZ7OptWordKey, kZ7OptFastBytesKey, kZ7OptMatchKey, kZ7OptSolidKey,
                kZ7OptSolidBlockKey, kZ7OptAutoThreadsKey, kZ7OptThreadsKey,
                kZ7OptVolumeKey, kZ7OptEncMethKey, kZ7OptEncHeaderKey,
                kZ7OptCompHeaderKey, kZ7OptFullPathsKey, kZ7OptExcludeJunkKey,
                kZ7OptVerifyKey, kZ7OptSeparateKey, kZ7OptUpdateModeKey,
                kZ7OptAdvancedKey,
            ];
            NSDictionary *defs = Z7CompressionPrefsDefaults();
            ok(defs.count == keys.count,
               [NSString stringWithFormat:@"出厂值条数与键数一致（%lu / %lu）",
                (unsigned long)defs.count, (unsigned long)keys.count]);

            NSMutableArray<NSString *> *missing = [NSMutableArray array];
            for (NSString *k in keys) if (!defs[k]) [missing addObject:k];
            ok(missing.count == 0,
               [NSString stringWithFormat:@"每个键都有出厂值%@",
                missing.count ? [@"，缺：" stringByAppendingString:
                                 [missing componentsJoinedByString:@", "]] : @""]);

            // 键名统一前缀，免得与别的持久化项（Z7RecentArchives / Z7ShowStatusItem / AppleLanguages）撞名。
            NSMutableArray<NSString *> *badPrefix = [NSMutableArray array];
            for (NSString *k in keys) if (![k hasPrefix:@"Z7Opt"]) [badPrefix addObject:k];
            ok(badPrefix.count == 0, @"持久化键统一以 Z7Opt 开头");

            // 密码绝不能落盘。这是安全断言，不是风格问题：明文口令写进 plist 后
            // 任何能读到用户 Library 的进程都能拿到它。
            NSMutableArray<NSString *> *secretish = [NSMutableArray array];
            for (NSString *k in defs) {
                NSString *low = k.lowercaseString;
                if ([low containsString:@"password"] || [low containsString:@"passwd"] ||
                    [k containsString:@"密码"]) {
                    [secretish addObject:k];
                }
            }
            ok(secretish.count == 0,
               [NSString stringWithFormat:@"出厂值中不含任何密码相关键%@",
                secretish.count ? [@"，发现：" stringByAppendingString:
                                   [secretish componentsJoinedByString:@", "]] : @""]);

            // 出厂值必须与面板控件的硬编码初值一致，否则「首次启动」与「恢复后」表现不同。
            ok([defs[kZ7OptFormatKey] isEqualToString:@"7z"], @"出厂格式为 7z");
            ok([defs[kZ7OptLevelKey] integerValue] == TickForLevel(5),
               @"出厂档位 = TickForLevel(5)（与滑杆初值同源）");
            ok([defs[kZ7OptMethodKey] isEqualToString:@"自动"], @"出厂压缩方法为「自动」");
            ok([defs[kZ7OptSolidKey] boolValue] == YES, @"出厂为固实归档");
            ok([defs[kZ7OptAutoThreadsKey] boolValue] == YES, @"出厂为自动线程");
            ok([defs[kZ7OptAdvancedKey] boolValue] == NO, @"出厂为高级参数收起");

            // 档位映射：越界必须夹取，否则会越界读 kZ7LevelTickValues[]。
            ok(LevelForTick(-1) == 0 && LevelForTick(99) == 9, @"档位越界被夹到两端");
            BOOL roundTrip = YES;
            for (NSInteger t = 0; t < 6; t++) {
                if (TickForLevel(LevelForTick(t)) != t) roundTrip = NO;
            }
            ok(roundTrip, @"6 个档位往返一致（Tick→Level→Tick）");

            // 注册域：registerDefaults 之后应能直接读到出厂值。
            [[NSUserDefaults standardUserDefaults] registerDefaults:defs];
            ok([[NSUserDefaults standardUserDefaults] stringForKey:kZ7OptFormatKey] != nil,
               @"registerDefaults 后可直接读到出厂格式");

            // 写读往返。用独立 suite 域，**绝不碰**用户真实的 org.7-zip.macos.app。
            // 盯的是 saveCompressionOptions 真正依赖的那个机制：写入后
            // persistentDomainForName: 能不能立刻看到——它决定「重启后记不记得住」。
            NSString *dom = @"org.7-zip.macos.prefs-selftest";
            NSUserDefaults *scoped = [[NSUserDefaults alloc] initWithSuiteName:dom];
            [scoped setObject:@"tar.xz" forKey:kZ7OptFormatKey];
            [scoped setInteger:4 forKey:kZ7OptLevelKey];
            [scoped synchronize];
            NSDictionary *back = [scoped persistentDomainForName:dom];
            ok([back[kZ7OptFormatKey] isEqualToString:@"tar.xz"],
               [NSString stringWithFormat:@"写入后 persistentDomain 立即读回格式（读到 %@）",
                back[kZ7OptFormatKey] ?: @"(nil)"]);
            ok([back[kZ7OptLevelKey] integerValue] == 4, @"写入后读回档位 4");
            [scoped removePersistentDomainForName:dom];
            NSDictionary *gone = [scoped persistentDomainForName:dom];
            ok(gone[kZ7OptFormatKey] == nil, @"清理后自检域无残留");
        }

        printf("\n== M. 列表右键菜单 ==\n");
        {
            // 标题在测试进程里就是**中文原文**：应用用「中文原文当键」的本地化方案
            // （开发区域 zh-Hans），而本进程没有 Localizable.strings 表，查表落空
            // 正好回退成键本身。若哪天测试环境带上了翻译表，这两条会失败——那是
            // 提示，不是误报。
            NSObject *target = [[NSObject alloc] init];
            NSMenu *rowMenu   = Z7BuildListContextMenu(YES, target);
            NSMenu *blankMenu = Z7BuildListContextMenu(NO,  target);

            ok([MenuTitleSignature(rowMenu) isEqualToString:
                @"预览 | 解压所选… | 拷贝路径 | --- | 删除所选 | --- | 全选"],
               [NSString stringWithFormat:@"行上右键：条目级动作，破坏性项单独一段放最后（实际：%@）",
                MenuTitleSignature(rowMenu)]);

            ok([MenuTitleSignature(blankMenu) isEqualToString:
                @"添加文件… | 测试归档 | 在访达中显示 | 重新载入 | --- | 全选"],
               [NSString stringWithFormat:@"空白处右键：整档动作，不出现条目级项（实际：%@）",
                MenuTitleSignature(blankMenu)]);

            // 动作名钉死。菜单动作是字符串写的（本文件不 #import main.m），
            // 拼错既不会编译失败也不会运行期报错，只表现为「点那一项没反应」。
            ok([MenuActionSignature(rowMenu) isEqualToString:
                [@[Z7ListSelPreview, Z7ListSelExtractSelected, Z7ListSelCopyPath, @"-",
                   Z7ListSelDelete, @"-", Z7ListSelSelectAll] componentsJoinedByString:@" | "]],
               [NSString stringWithFormat:@"行上右键的动作名与常量一致（实际：%@）",
                MenuActionSignature(rowMenu)]);

            ok([MenuActionSignature(blankMenu) isEqualToString:
                [@[Z7ListSelAddFiles, Z7ListSelTestArchive, Z7ListSelRevealInFinder,
                   Z7ListSelReload, @"-", Z7ListSelSelectAll] componentsJoinedByString:@" | "]],
               [NSString stringWithFormat:@"空白处右键的动作名与常量一致（实际：%@）",
                MenuActionSignature(blankMenu)]);

            // target 归属：非「全选」项指向调用方（由其 validateMenuItem: 决定可用性），
            // 「全选」必须留空走响应链——控制器上没有 selectAll:，指向自己会
            // unrecognized selector 崩掉。
            BOOL targetsOK = YES, selectAllNil = YES;
            for (NSMenuItem *it in rowMenu.itemArray) {
                if (it.isSeparatorItem) continue;
                if (it.action == NSSelectorFromString(Z7ListSelSelectAll)) {
                    if (it.target != nil) selectAllNil = NO;
                } else if (it.target != target) {
                    targetsOK = NO;
                }
            }
            ok(targetsOK, @"非「全选」项的 target 均指向传入对象");
            ok(selectAllNil, @"「全选」的 target 留空（交响应链给 NSOutlineView）");
        }

        printf("\n== N. 列表视图的事件重写 ==\n");
        {
            // 哨兵：这两处重写一旦被删掉，右键会**静默**退回 AppKit 的默认菜单、
            // 空格/Delete 也不再有效——不报错，只是功能没了。本机无法用鼠标复现，
            // 只能靠断言守住。
            Method mine = class_getInstanceMethod(Z7OutlineView.class, @selector(menuForEvent:));
            Method base = class_getInstanceMethod(NSOutlineView.class, @selector(menuForEvent:));
            ok(mine && base && method_getImplementation(mine) != method_getImplementation(base),
               @"Z7OutlineView 重写了 menuForEvent:");

            Method kMine = class_getInstanceMethod(Z7OutlineView.class, @selector(keyDown:));
            Method kBase = class_getInstanceMethod(NSOutlineView.class, @selector(keyDown:));
            ok(kMine && kBase && method_getImplementation(kMine) != method_getImplementation(kBase),
               @"Z7OutlineView 重写了 keyDown:");

            // 键盘分发可以真实驱动：keyDown: 只读 charactersIgnoringModifiers，
            // 不需要窗口，因此合成事件在本机是有效的（鼠标事件才无效）。
            TestOutlineDelegate *del = [[TestOutlineDelegate alloc] init];
            Z7OutlineView *v = [[Z7OutlineView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
            v.keyDelegate = del;

            NSEvent *space = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                              location:NSZeroPoint modifierFlags:0
                                             timestamp:0 windowNumber:0 context:nil
                                            characters:@" " charactersIgnoringModifiers:@" "
                                              isARepeat:NO keyCode:49];
            [v keyDown:space];
            ok(del.spaceCount == 1 && del.deleteCount == 0, @"空格键分发给 outlineDidPressSpace");

            NSString *delChar = [NSString stringWithFormat:@"%C", (unichar)NSDeleteCharacter];
            NSEvent *delEv = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                              location:NSZeroPoint modifierFlags:0
                                             timestamp:0 windowNumber:0 context:nil
                                            characters:delChar charactersIgnoringModifiers:delChar
                                              isARepeat:NO keyCode:51];
            [v keyDown:delEv];
            ok(del.deleteCount == 1 && del.spaceCount == 1,
               @"Delete 键分发给 outlineDidPressDelete（且不重复派发空格）");

            // 其它按键必须交给 super，不能吞掉：否则列表就再也收不到方向键、
            // 打字搜索这些正常输入。
            NSEvent *arrow = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                              location:NSZeroPoint modifierFlags:0
                                             timestamp:0 windowNumber:0 context:nil
                                            characters:@"a" charactersIgnoringModifiers:@"a"
                                              isARepeat:NO keyCode:0];
            [v keyDown:arrow];
            ok(del.spaceCount == 1 && del.deleteCount == 1,
               @"普通字符不触发任何 delegate 回调（继续走 super）");
        }

        printf("\n== I. 错误路径 ==\n");
        NSError *badErr = nil;
        Z7Archive *missing = [Z7Archive openPath:[work stringByAppendingPathComponent:@"nope.7z"]
                                        password:nil callback:cb error:&badErr];
        ok(missing == nil && badErr != nil, @"打开不存在的文件返回 nil 并填充 NSError");
        ok([badErr.domain isEqualToString:Z7ErrorDomain], [NSString stringWithFormat:@"错误域为 %@", badErr.domain]);

        printf("\n================ 汇总 ================\n");
        printf("通过: %d   失败: %d   跳过: %d\n", g_pass, g_fail, g_skip);
        return g_fail == 0 ? 0 : 1;
    }
}
