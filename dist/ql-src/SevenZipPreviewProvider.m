//
//  SevenZipPreviewProvider.m
//  7-Zip Quick Look Preview Extension
//
//  Data-based Quick Look preview for archive files. Runs the embedded `7zz`
//  engine with `l -slt` (technical listing) and renders the archive contents
//  as an HTML table inside the Quick Look panel (Space bar in Finder).
//
//  Distribution: macOS 12.0+ (QLPreviewProvider / QLPreviewReply are macOS 12 APIs).
//

#import <Foundation/Foundation.h>
#import <QuickLookUI/QuickLookUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <spawn.h>
#include <sys/wait.h>
#include <signal.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>

#include "ArchiveReader.h"

extern char **environ;

#pragma mark - Diagnostics

// A sandboxed extension cannot be observed from outside with NSLog, so
// diagnostics are appended to a file inside the extension's own container
// (NSTemporaryDirectory() resolves there).
//
// Logging stays silent on the happy path: nothing is written unless
// SEVENZIP_QUICKLOOK_DEBUG is set in the environment, or a genuine failure
// occurs. Once a failure is recorded the log is kept for the rest of the
// launch so the surrounding context is available too.
static BOOL       SevenZipDebugVerbose = NO;
static NSString  *SevenZipDebugPath    = nil;
static NSMutableArray<NSString *> *SevenZipDebugPending = nil;
static dispatch_once_t SevenZipDebugOnce;

static void SevenZipDebugWrite(BOOL force, NSString *format, va_list ap) NS_FORMAT_FUNCTION(2, 0);

static void SevenZipDebugWrite(BOOL force, NSString *format, va_list ap)
{
    dispatch_once(&SevenZipDebugOnce, ^{
        SevenZipDebugPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"7zip-quicklook.log"];
        [[NSFileManager defaultManager] removeItemAtPath:SevenZipDebugPath error:NULL];
        SevenZipDebugPending = [NSMutableArray array];
        SevenZipDebugVerbose = (getenv("SEVENZIP_QUICKLOOK_DEBUG") != NULL);
    });

    NSString *message = [[NSString alloc] initWithFormat:format arguments:ap];
    NSString *line = [NSString stringWithFormat:@"%.3f %@\n",
                      [NSDate date].timeIntervalSince1970, message];

    if (!SevenZipDebugVerbose && !force) {
        /* Hold recent context so that a later failure can still be understood. */
        if (SevenZipDebugPending.count >= 40)
            [SevenZipDebugPending removeObjectAtIndex:0];
        [SevenZipDebugPending addObject:line];
        return;
    }

    if (force)
        SevenZipDebugVerbose = YES;

    /* Context lines that preceded the first failure were buffered; replay them
       so the log reads as a complete transcript rather than starting mid-way. */
    NSMutableString *chunk = [NSMutableString string];
    for (NSString *pending in SevenZipDebugPending)
        [chunk appendString:pending];
    [SevenZipDebugPending removeAllObjects];
    [chunk appendString:line];

    NSData *data = [chunk dataUsingEncoding:NSUTF8StringEncoding];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:SevenZipDebugPath];
    if (!fh) {
        [data writeToFile:SevenZipDebugPath atomically:NO];
        return;
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:data];
        [fh closeFile];
    } @catch (__unused NSException *e) {
        /* diagnostics must never break a preview */
    }
}

static void SevenZipDebugLog(NSString *format, ...)
{
    va_list ap;
    va_start(ap, format);
    SevenZipDebugWrite(NO, format, ap);
    va_end(ap);
}

static void SevenZipDebugForce(NSString *format, ...)
{
    va_list ap;
    va_start(ap, format);
    SevenZipDebugWrite(YES, format, ap);
    va_end(ap);
}

#pragma mark - Listing parser

// Human-readable byte count.
static NSString *SevenZipFormatBytes(unsigned long long bytes)
{
    if (bytes < 1024ULL)
        return [NSString stringWithFormat:@"%llu B", bytes];
    static const char *units[] = { "KiB", "MiB", "GiB", "TiB", "PiB" };
    double value = (double)bytes;
    int idx = -1;
    while (value >= 1024.0 && idx < 4) {
        value /= 1024.0;
        idx++;
    }
    if (value >= 100.0)
        return [NSString stringWithFormat:@"%.0f %s", value, units[idx]];
    if (value >= 10.0)
        return [NSString stringWithFormat:@"%.1f %s", value, units[idx]];
    return [NSString stringWithFormat:@"%.2f %s", value, units[idx]];
}

static NSString *SevenZipEscapeHTML(NSString *s)
{
    if (s.length == 0)
        return @"";
    NSMutableString *m = [s mutableCopy];
    [m replaceOccurrencesOfString:@"&" withString:@"&amp;"  options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"<" withString:@"&lt;"   options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@">" withString:@"&gt;"   options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, m.length)];
    return m;
}

#pragma mark - HTML rendering

static NSString *SevenZipBuildHTML(NSURL *fileURL,
                                   NSDictionary *archiveInfo,
                                   NSArray<NSDictionary *> *entries,
                                   NSString *fallbackError,
                                   NSString *note)
{
    NSString *name = fileURL.lastPathComponent;
    NSString *type = archiveInfo[@"Type"] ?: @"";
    NSString *physical = archiveInfo[@"Physical Size"];
    NSString *method = archiveInfo[@"Method"];
    NSString *solid = archiveInfo[@"Solid"];
    NSString *encrypted = archiveInfo[@"Encrypted"];
    NSString *headers = archiveInfo[@"Headers Size"];

    unsigned long long totalUncompressed = 0;
    NSUInteger fileCount = 0, folderCount = 0;
    for (NSDictionary *e in entries) {
        BOOL isFolder = (e[@"Folder"] != nil) || [e[@"Attributes"] hasPrefix:@"D"] || [e[@"Path"] hasSuffix:@"/"];
        if (isFolder) {
            folderCount++;
        } else {
            fileCount++;
            totalUncompressed += [e[@"Size"] longLongValue];
        }
    }

    NSMutableString *rows = [NSMutableString string];
    // Cap the rendered rows so a huge archive cannot produce a multi-megabyte page.
    const NSUInteger kMaxRows = 2000;
    NSUInteger rendered = 0;
    for (NSDictionary *e in entries) {
        if (rendered >= kMaxRows)
            break;
        rendered++;

        NSString *path = e[@"Path"] ?: @"";
        BOOL isFolder = (e[@"Folder"] != nil) || [path hasSuffix:@"/"] || [e[@"Attributes"] hasPrefix:@"D"];

        NSString *sizeText, *packedText;
        if (isFolder) {
            sizeText = @"—";
            packedText = @"—";
        } else {
            unsigned long long size = [e[@"Size"] longLongValue];
            unsigned long long packed = [e[@"Packed Size"] longLongValue];
            sizeText = SevenZipFormatBytes(size);
            // `Packed Size` is meaningless for solid blocks: 7-Zip reports the
            // whole block, so only show it when the archive is non-solid.
            packedText = ([e[@"Packed Size"] length] && ![solid isEqualToString:@"+"])
                       ? SevenZipFormatBytes(packed) : @"—";
        }

        NSString *modified = e[@"Modified"] ?: @"";
        NSString *attr = e[@"Attributes"] ?: @"";
        NSString *rowClass = isFolder ? @" class=\"folder\"" : @"";
        NSString *icon = isFolder ? @"📁" : @"📄";

        [rows appendFormat:
            @"<tr%@><td class=\"n\"><span class=\"ic\">%@</span>%@</td>"
             "<td class=\"r\">%@</td><td class=\"r dim\">%@</td>"
             "<td class=\"dim mono\">%@</td><td class=\"dim mono\">%@</td></tr>\n",
            rowClass, icon, SevenZipEscapeHTML(path),
            sizeText, packedText,
            SevenZipEscapeHTML(modified), SevenZipEscapeHTML(attr)];
    }

    NSString *truncNote = entries.count > kMaxRows
        ? [NSString stringWithFormat:@"<p class=\"note\">仅显示前 %lu 项，共 %lu 项。请使用 7-Zip 应用查看完整列表。</p>",
                                     (unsigned long)kMaxRows, (unsigned long)entries.count]
        : @"";
    if (note.length)
        truncNote = [truncNote stringByAppendingFormat:@"<p class=\"note\">%@</p>", SevenZipEscapeHTML(note)];

    NSMutableString *meta = [NSMutableString string];
    if (type.length)       [meta appendFormat:@"<span class=\"badge\">%@</span>", SevenZipEscapeHTML(type)];
    if (physical.length)   [meta appendFormat:@"<span class=\"kv\">压缩包 <b>%@</b></span>", SevenZipFormatBytes([physical longLongValue])];
    if (headers.length)    [meta appendFormat:@"<span class=\"kv\">头信息 <b>%@</b></span>", SevenZipFormatBytes([headers longLongValue])];
    if (method.length)     [meta appendFormat:@"<span class=\"kv\">方法 <b>%@</b></span>", SevenZipEscapeHTML(method)];
    if (entries.count > 0)
        [meta appendFormat:@"<span class=\"kv\">内容 <b>%@</b></span>", SevenZipFormatBytes(totalUncompressed)];
    if ([solid isEqualToString:@"+"])     [meta appendString:@"<span class=\"badge warn\">Solid</span>"];
    if (encrypted.length && ![encrypted isEqualToString:@"-"]) [meta appendString:@"<span class=\"badge lock\">🔒 加密</span>"];

    NSString *counts = entries.count > 0
        ? [NSString stringWithFormat:@"<span class=\"kv\">%lu 个文件 · %lu 个文件夹</span>",
                                     (unsigned long)fileCount, (unsigned long)folderCount]
        : @"";

    NSString *body;
    if (entries.count == 0) {
        NSString *msg = fallbackError.length ? fallbackError : @"无法读取归档内容，或归档为空。";
        body = [NSString stringWithFormat:
                @"<div class=\"empty\"><p>%@</p></div>", SevenZipEscapeHTML(msg)];
    } else {
        body = [NSString stringWithFormat:
                @"<table><thead><tr>"
                 "<th class=\"n\">名称</th><th class=\"r\">大小</th><th class=\"r\">压缩后</th>"
                 "<th>修改时间</th><th>属性</th>"
                 "</tr></thead><tbody>\n%@</tbody></table>", rows];
    }

    NSString *html = [NSString stringWithFormat:
        @"<!DOCTYPE html>\n<html lang=\"zh\"><head><meta charset=\"utf-8\">"
         "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
         "<style>\n"
         ":root{--bg:#ffffff;--fg:#1c1c1e;--dim:#6e6e73;--line:#e4e4e7;--head:#f5f5f7;"
         "--alt:#fafafa;--accent:#0a84ff;--chip:#eef1f5;}\n"
         "@media (prefers-color-scheme: dark){:root{--bg:#1e1e1e;--fg:#f2f2f7;--dim:#98989d;"
         "--line:#38383a;--head:#252527;--alt:#232325;--accent:#0a84ff;--chip:#2c2c2e;}}\n"
         "*{box-sizing:border-box;}\n"
         "html,body{margin:0;padding:0;background:var(--bg);color:var(--fg);"
         "font:13px/1.5 -apple-system,BlinkMacSystemFont,\"Helvetica Neue\",\"PingFang SC\",sans-serif;}\n"
         "header{padding:14px 18px 12px;border-bottom:1px solid var(--line);position:sticky;top:0;"
         "background:var(--bg);z-index:2;}\n"
         "h1{margin:0 0 8px;font-size:15px;font-weight:600;letter-spacing:-.01em;"
         "white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}\n"
         ".meta{display:flex;flex-wrap:wrap;gap:6px 12px;align-items:center;color:var(--dim);font-size:11.5px;}\n"
         ".kv b{color:var(--fg);font-weight:600;}\n"
         ".badge{background:var(--chip);color:var(--fg);padding:1px 7px;border-radius:5px;"
         "font-size:11px;font-weight:600;letter-spacing:.02em;}\n"
         ".badge.warn{background:#ffd60a22;color:#b58900;}\n"
         ".badge.lock{background:#ff3b3022;color:#d70015;}\n"
         "@media (prefers-color-scheme: dark){.badge.warn{color:#ffd60a;}.badge.lock{color:#ff6961;}}\n"
         "table{width:100%%;border-collapse:collapse;font-size:12.5px;}\n"
         "thead th{position:sticky;top:0;background:var(--head);color:var(--dim);text-align:left;"
         "font-weight:600;font-size:11px;letter-spacing:.03em;text-transform:uppercase;"
         "padding:7px 12px;border-bottom:1px solid var(--line);white-space:nowrap;}\n"
         "tbody tr:nth-child(even){background:var(--alt);}\n"
         "tbody td{padding:6px 12px;border-bottom:1px solid var(--line);vertical-align:top;}\n"
         "td.n{word-break:break-all;}\n"
         "tr.folder td.n{font-weight:600;}\n"
         ".ic{display:inline-block;margin-right:6px;opacity:.75;font-size:11px;}\n"
         "td.r{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums;}\n"
         ".dim{color:var(--dim);}\n"
         ".mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11.5px;}\n"
         ".empty{padding:48px 24px;text-align:center;color:var(--dim);}\n"
         ".empty p{white-space:pre-wrap;text-align:left;display:inline-block;"
         "max-width:640px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;"
         "font-size:11.5px;line-height:1.7;}\n"
         ".note{margin:10px 18px 18px;color:var(--dim);font-size:11.5px;}\n"
         "footer{padding:10px 18px 18px;color:var(--dim);font-size:11px;}\n"
         "</style></head><body>\n"
         "<header><h1>%@</h1><div class=\"meta\">%@%@</div></header>\n"
         "%@%@\n"
         "<footer>7-Zip 26.03 · Quick Look 预览</footer>\n"
         "</body></html>",
        SevenZipEscapeHTML(name), meta, counts, body, truncNote];

    return html;
}

#pragma mark - Native reader bridge

static NSString *SevenZipFormatTimestamp(int64_t seconds)
{
    if (seconds <= 0)
        return @"";
    struct tm tmv;
    time_t t = (time_t)seconds;
    if (localtime_r(&t, &tmv) == NULL)
        return @"";
    char buf[32];
    if (strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &tmv) == 0)
        return @"";
    return @(buf);
}

// Convert a QlListing into the (archiveInfo, entries) shape the renderer
// already understands, so both the engine and the native reader share one
// presentation path.
static void SevenZipAdoptNativeListing(NSURL *url,
                                       QlListing *lst,
                                       NSMutableDictionary *info,
                                       NSMutableArray<NSDictionary *> *entries)
{
    info[@"Type"] = @(lst->format);
    if (lst->method[0]) info[@"Method"] = @(lst->method);

    // The renderer treats every archiveInfo value as text (it calls -length),
    // so the file size must be converted rather than stored as an NSNumber.
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:NULL];
    if (attrs[NSFileSize]) {
        info[@"Physical Size"] = [NSString stringWithFormat:@"%llu",
                                  [attrs[NSFileSize] unsignedLongLongValue]];
    }

    for (size_t i = 0; i < lst->count; i++) {
        QlEntry *e = &lst->items[i];
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"Path"] = e->name ? @(e->name) : @"";
        if (e->is_dir) {
            d[@"Folder"] = @"+";
            d[@"Attributes"] = @"D";
        } else {
            d[@"Size"] = [NSString stringWithFormat:@"%llu", (unsigned long long)e->size];
            d[@"Packed Size"] = [NSString stringWithFormat:@"%llu", (unsigned long long)e->packed];
            if (e->attr[0]) d[@"Attributes"] = @(e->attr);
        }
        NSString *ts = SevenZipFormatTimestamp(e->mtime);
        if (ts.length) d[@"Modified"] = ts;
        [entries addObject:d];
    }
}

#pragma mark - Principal class

@interface SevenZipPreviewProvider : QLPreviewProvider <QLPreviewingController>
@end

@implementation SevenZipPreviewProvider

- (void)providePreviewForFileRequest:(QLFilePreviewRequest *)request
                   completionHandler:(void (^)(QLPreviewReply *_Nullable, NSError *_Nullable))handler
{
    NSURL *url = request.fileURL;
    SevenZipDebugLog(@"=== preview request: %@", url.path);

    QLPreviewReply *reply =
        [[QLPreviewReply alloc] initWithDataOfContentType:UTTypeHTML
                                              contentSize:CGSizeMake(760, 820)
                                        dataCreationBlock:^NSData *(QLPreviewReply *r, NSError **error) {

        (void)error;   // failures are reported inline in the HTML body

        @try {
            NSMutableDictionary *archiveInfo = [NSMutableDictionary dictionary];
            NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
            NSString *fallback = nil;
            NSString *note = nil;

            // 单一列举路径。QlReadListing 优先驱动链接进来的 7-Zip 引擎
            // （EngineListing.mm），引擎拒绝该文件时才回退到内置解析器 ——
            // 两者填的是同一个 QlListing，故下面的呈现逻辑共享。
            //
            // 这里不派生子进程。原先那条「执行内嵌 7zz」的路径已于
            // 2026-09-26 移除：在沙箱内执行助手需要 com.apple.security.inherit
            // 这一受限权利，ad-hoc 签名拿不到（EPERM）；而把引擎当动态库
            // **加载**是允许的，且能力更强。见 ql-src/build_ql.sh。
            QlListing lst;
            int recognised = QlReadListing(url.fileSystemRepresentation, &lst);
            SevenZipDebugLog(@"listing: recognised=%d format=%s complete=%d count=%zu via_engine=%d err=%s",
                             recognised, lst.format, lst.complete, lst.count, lst.via_engine,
                             lst.error ? lst.error : "-");

            if (recognised) {
                SevenZipAdoptNativeListing(url, &lst, archiveInfo, entries);
                SevenZipDebugLog(@"adopted %lu rows", (unsigned long)entries.count);

                if (lst.detail[0])
                    note = @(lst.detail);

                if (entries.count == 0) {
                    fallback = @"已识别该归档容器，但其中没有可列出的条目。";
                } else if (!lst.complete && note.length) {
                    note = [note stringByAppendingString:
                            @"\n使用 7-Zip 应用可查看完整内容列表。"];
                }
                QlListingFree(&lst);
            } else {
                NSMutableString *why = [NSMutableString string];
                if (lst.error)
                    [why appendFormat:@"%@\n", @(lst.error)];
                [why appendString:@"\n7-Zip 引擎未能打开该文件，内置解析器也不认识这种格式。"];
                fallback = why;
                QlListingFree(&lst);
            }

            NSString *html = SevenZipBuildHTML(url, archiveInfo, entries, fallback, note);
            SevenZipDebugLog(@"html %lu bytes -> reply", (unsigned long)html.length);
            r.title = url.lastPathComponent;
            return [html dataUsingEncoding:NSUTF8StringEncoding];
        } @catch (NSException *ex) {
            // Never let an exception escape: a thrown exception would make
            // Quick Look discard the preview and show its generic fallback.
            SevenZipDebugForce(@"EXCEPTION %@: %@", ex.name, ex.reason);
            NSString *html = SevenZipBuildHTML(url, @{}, @[],
                [NSString stringWithFormat:@"预览时发生内部错误：\n%@\n%@", ex.name, ex.reason],
                nil);
            r.title = url.lastPathComponent;
            return [html dataUsingEncoding:NSUTF8StringEncoding];
        }
    }];

    SevenZipDebugLog(@"reply constructed, calling handler");
    handler(reply, nil);
}

@end
