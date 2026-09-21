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

#import "SevenZipEngineObjC.h"

static int g_pass = 0;
static int g_fail = 0;

static void ok(BOOL cond, NSString *what) {
    if (cond) {
        g_pass++;
        printf("  PASS  %s\n", what.UTF8String);
    } else {
        g_fail++;
        printf("  FAIL  %s\n", what.UTF8String);
    }
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

        BOOL extracted = [a extractItems:nil to:outDir testMode:NO overwrite:YES
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

        printf("\n== I. 错误路径 ==\n");
        NSError *badErr = nil;
        Z7Archive *missing = [Z7Archive openPath:[work stringByAppendingPathComponent:@"nope.7z"]
                                        password:nil callback:cb error:&badErr];
        ok(missing == nil && badErr != nil, @"打开不存在的文件返回 nil 并填充 NSError");
        ok([badErr.domain isEqualToString:Z7ErrorDomain], [NSString stringWithFormat:@"错误域为 %@", badErr.domain]);

        printf("\n================ 汇总 ================\n");
        printf("通过: %d   失败: %d\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
