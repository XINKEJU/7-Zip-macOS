//
//  EngineListing.mm
//  Engine-backed archive listing for the 7-Zip Quick Look extension.
//
//  Why this file exists at all: the extension used to shell out to an embedded
//  `7zz` helper. Inside the App Sandbox a spawn needs `com.apple.security.inherit`,
//  which the kernel grants only to binaries signed with a real team identity —
//  ad-hoc builds are refused with EPERM, so the helper never produced a byte.
//  Loading a dylib *in-process* is a different question: this project signs
//  ad-hoc without the hardened runtime (codesign flags = 0x2(adhoc), no
//  `runtime`), and without the hardened runtime macOS does not enforce library
//  validation. So the engine can simply be linked, exactly as the main
//  application does.
//
//  The engine API in SevenZipEngine.h is fully synchronous, which is what a
//  Quick Look provider wants: no run loop, no task queue, no callbacks to
//  marshal back to the main thread.
//
//  The result is handed back in the same QlListing shape the built-in reader
//  produces, so the provider renders both paths identically and ArchiveReader.c
//  can fall back to its own parsers whenever the engine declines a file.
//

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>

#include "SevenZipEngine.h"
#include "ArchiveReader.h"

namespace {

/// 一次预览最多列出多少条。Quick Look 扩展的可用内存远小于常规 App，
/// 十万条目的列表既没人看，也会把扩展推到内存上限。超出即截断并标记
/// complete = 0，由调用方在界面上说明。
const uint32_t kMaxItems = 8000;

class SilentCallback final : public z7::Callback {
public:
  // 不弹密码框：预览场景下拿不到用户输入。返回空串会让加密归档的 Open
  // 失败，调用方随后回退到内置解析器（至少能给出容器摘要）。
  std::string GetPassword(bool /*retry*/) override { return std::string(); }
};

/// 9 字符的 POSIX 权限串（"rwxr-xr-x"）。QlEntry::attr 只有 10 字节，
/// 放不下类型字符，故由 is_dir 单独表达类型。
void ModeToRwx(uint32_t mode, int isDir, char *out, size_t cap) {
  if (cap < 10) return;
  out[0] = (mode & 0400) ? 'r' : '-';
  out[1] = (mode & 0200) ? 'w' : '-';
  out[2] = (mode & 0100) ? 'x' : '-';
  out[3] = (mode & 0040) ? 'r' : '-';
  out[4] = (mode & 0020) ? 'w' : '-';
  out[5] = (mode & 0010) ? 'x' : '-';
  out[6] = (mode & 0004) ? 'r' : '-';
  out[7] = (mode & 0002) ? 'w' : '-';
  out[8] = (mode & 0001) ? 'x' : '-';
  out[9] = '\0';
  (void)isDir;
}

char *DupStr(const std::string &s) {
  char *p = (char *)malloc(s.size() + 1);
  if (p) memcpy(p, s.c_str(), s.size() + 1);
  return p;
}

}  // namespace

extern "C" {

/// 引擎版本串（用于预览页脚显示），返回静态存储，调用方不得释放。
const char *Z7EngineVersionString(void) {
  static std::string v = z7::engineVersion();
  return v.c_str();
}

/// 用 7-Zip 引擎列出归档内容。
///
/// 成功返回 1，并按 QlListing 的约定填充 *items（malloc，元素内 name 为
/// strdup）与 *count；失败返回 0 且不分配任何内存，让调用方回退到内置解析器。
/// 所有 out 字符串缓冲在失败时也会被写上原因，便于记日志。
int Z7EngineListArchive(const char *utf8Path,
                        QlEntry **itemsOut, size_t *countOut, size_t *capOut,
                        int *completeOut,
                        char *format, size_t formatCap,
                        char *method, size_t methodCap,
                        char *detail, size_t detailCap,
                        char **errorOut) {
  *itemsOut = NULL;
  *countOut = 0;
  *capOut = 0;
  *completeOut = 0;
  *errorOut = NULL;

  std::string error;
  SilentCallback cb;
  z7::Archive *arc = z7::Archive::Open(utf8Path, &cb, error);
  if (!arc) {
    if (errorOut) *errorOut = DupStr(error.empty() ? "引擎无法打开该文件。" : error);
    return 0;
  }

  const uint32_t total = arc->itemCount();
  const uint32_t take = total > kMaxItems ? kMaxItems : total;

  QlEntry *rows = (QlEntry *)calloc(take ? take : 1, sizeof(QlEntry));
  if (!rows) {
    delete arc;
    if (errorOut) *errorOut = DupStr("内存不足。");
    return 0;
  }

  std::string firstMethod;
  size_t n = 0;
  for (uint32_t i = 0; i < take; i++) {
    z7::ItemInfo it;
    if (!arc->getItem(i, it)) continue;
    QlEntry *e = &rows[n];
    e->name = DupStr(it.path.empty() ? it.name : it.path);
    e->size = it.hasSize ? it.size : 0;
    e->packed = it.hasPackSize ? it.packSize : 0;
    e->mtime = it.hasMTime ? it.mtime : -1;
    e->is_dir = it.isDir ? 1 : 0;
    if (it.hasAttrib) {
      ModeToRwx(it.attrib, e->is_dir, e->attr, sizeof(e->attr));
    } else if (it.isSymLink) {
      snprintf(e->attr, sizeof(e->attr), "%s", "rwxrwxrwx");
    } else if (it.isDir) {
      snprintf(e->attr, sizeof(e->attr), "%s", "rwxr-xr-x");
    }
    if (e->is_dir && e->name && e->name[0] && e->name[strlen(e->name) - 1] != '/') {
      // 目录名统一补斜杠，与内置解析器保持一致，界面据此加粗。
      size_t len = strlen(e->name);
      char *grown = (char *)realloc(e->name, len + 2);
      if (grown) {
        grown[len] = '/';
        grown[len + 1] = '\0';
        e->name = grown;
      }
    }
    if (firstMethod.empty() && !it.method.empty()) firstMethod = it.method;
    n++;
  }

  const std::string fmtRaw = arc->formatName();
  std::string fmt = fmtRaw.empty() ? std::string("未知") : fmtRaw;
  for (size_t i = 0; i < fmt.size(); i++) {
    if (fmt[i] >= 'a' && fmt[i] <= 'z') fmt[i] = (char)(fmt[i] - 32);
  }

  snprintf(format, formatCap, "%s", fmt.c_str());
  snprintf(method, methodCap, "%s", firstMethod.c_str());

  std::string d;
  char buf[128];
  if (take < total) {
    snprintf(buf, sizeof(buf), "引擎直读 · 共 %u 项，仅列出前 %u 项", (unsigned)total,
             (unsigned)take);
  } else {
    snprintf(buf, sizeof(buf), "引擎直读 · %u 项", (unsigned)total);
  }
  d = buf;
  snprintf(detail, detailCap, "%s", d.c_str());

  delete arc;

  *itemsOut = rows;
  *countOut = n;
  *capOut = take;
  *completeOut = (take >= total) ? 1 : 0;
  return 1;
}

}  // extern "C"
