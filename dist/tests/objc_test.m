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
