// SevenZipEngine.cpp
//
// 7-Zip 引擎内嵌桥接层实现。
//
// 与 lib7z.dylib 的交互方式参照 7-Zip 自带的示例客户端
// CPP/7zip/UI/Client7z/Client7z.cpp：
//   * 通过 C 入口 CreateObject() 由 CLSID 取得 IInArchive / IOutArchive；
//   * 通过 GetNumberOfFormats() + GetHandlerProperty2(kClassID) 枚举全部
//     已注册的格式处理器，逐个尝试 Open，实现格式自动探测；
//   * 实现 IArchiveOpenCallback / IArchiveExtractCallback /
//     IArchiveUpdateCallback2 / IProgress / ICryptoGetTextPassword(2)；
//   * 分卷输出复用引擎自带的 CMultiOutStream（与 7zz -v 行为一致）。
//
// 安全加固（对应技术方案 §8.2）：
//   * 路径穿越、绝对路径、盘符样式条目一律拒绝并记录；
//   * 写入前校验落盘路径仍位于目标目录内，并解析父目录真实路径防符号链接劫持；
//   * 符号链接只在目标解析后仍位于目标目录内时创建，绝对路径与上溯越界一律拒绝；
//   * 压缩炸弹上限（声明总量与实时写入量双重检查）；
//   * 覆盖策略可配置，默认不覆盖已有文件；
//   * 落盘原子化：先写 "<目标>.partial"，成功后改名，失败即删除半成品（§7.4）；
//   * 密码副本在作用域结束或引擎不再需要时显式清零。

#include "SevenZipEngine.h"

#include <atomic>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>   // mkstemps
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "Common/MyWindows.h"
#include "Common/MyLinux.h"
#include "Common/MyInitGuid.h"

#include "Common/ComTry.h"
#include "Common/Defs.h"
#include "Common/IntToString.h"
#include "Common/MyCom.h"
#include "Common/StringConvert.h"
#include "Common/UTFConvert.h"

#include "Windows/FileDir.h"
#include "Windows/FileFind.h"
#include "Windows/FileName.h"
#include "Windows/PropVariant.h"
#include "Windows/PropVariantConv.h"
#include "Windows/TimeUtils.h"

#include "7zip/Archive/IArchive.h"
#include "7zip/Common/FileStreams.h"
#include "7zip/Common/MultiOutStream.h"
#include "7zip/IPassword.h"
#include "7zip/IStream.h"
#include "7zip/PropID.h"

#include "Z7ExtCodec.h"
#include "Z7IsoWriter.h"
#include "Z7DmgWriter.h"
#include "7zVersion.h"

using namespace NWindows;

// ---------------------------------------------------------------------------
// lib7z.dylib 的 C 入口（Archive2.def 导出）
// ---------------------------------------------------------------------------

extern "C" HRESULT CreateObject(const GUID *clsid, const GUID *iid, void **outObject);
extern "C" HRESULT GetNumberOfFormats(UInt32 *numFormats);
extern "C" HRESULT GetHandlerProperty2(UInt32 formatIndex, PROPID propID, PROPVARIANT *value);

namespace z7 {

// ---------------------------------------------------------------------------
// 格式 CLSID（Data4[5] 即处理器 Id，见 ArchiveExports.cpp）
// ---------------------------------------------------------------------------

#define Z7_ARC_CLSID(name, id)                                                        \
  Z7_DEFINE_GUID(name, 0x23170F69, 0x40C1, 0x278A, 0x10, 0x00, 0x00, 0x01, 0x10, id, \
                 0x00, 0x00);

Z7_ARC_CLSID(g_CLSID_7z, 0x07)
Z7_ARC_CLSID(g_CLSID_Zip, 0x01)
Z7_ARC_CLSID(g_CLSID_BZip2, 0x02)
Z7_ARC_CLSID(g_CLSID_Xz, 0x0C)
Z7_ARC_CLSID(g_CLSID_Tar, 0xEE)
Z7_ARC_CLSID(g_CLSID_GZip, 0xEF)

// ---------------------------------------------------------------------------
// 字符串工具（non-Windows 下 7-Zip 强制 UTF-8：StringConvert.cpp g_ForceToUTF8）
// ---------------------------------------------------------------------------

static std::string ToUtf8(const UString &s) {
  if (s.IsEmpty()) return std::string();
  AString a;
  UnicodeStringToMultiByte2(a, s, CP_UTF8);
  return std::string(a.Ptr(), a.Len());
}

static UString ToUString(const std::string &s) {
  UString u;
  if (s.empty()) return u;
  AString a;
  a.SetFrom(s.c_str(), (unsigned)s.size());
  MultiByteToUnicodeString2(u, a, CP_UTF8);
  return u;
}

static FString ToFString(const std::string &s) {
  FString f;
  if (!s.empty()) f.SetFrom(s.c_str(), (unsigned)s.size());
  return f;
}

static std::string HRText(HRESULT hr) {
  char buf[32];
  sprintf(buf, "0x%08X", (unsigned)hr);
  return std::string(buf);
}

static const char *HRReason(HRESULT hr) {
  switch (hr) {
    case S_OK: return "OK";
    case S_FALSE: return "无更多数据";
    case E_ABORT: return "操作被中止";
    case E_INVALIDARG: return "参数无效";
    case E_NOTIMPL: return "暂不支持该操作";
    case E_OUTOFMEMORY: return "内存不足";
    case E_NOINTERFACE: return "接口不可用";
    case E_FAIL: return "未指定的失败";
    default: return NULL;
  }
}

// ---------------------------------------------------------------------------
// §8.2 路径安全
// ---------------------------------------------------------------------------

static bool SanitizeArcPath(const UString &arcPath, UString &relative, std::string &reason) {
  relative.Empty();
  reason.clear();

  if (arcPath.IsEmpty()) {
    reason = "条目路径为空";
    return false;
  }

  const wchar_t *p = arcPath.Ptr();
  if (p[0] == L'/' || p[0] == L'\\') {
    reason = "条目为绝对路径";
    return false;
  }
  if (p[0] != 0 && p[1] == L':') {
    reason = "条目路径含盘符前缀";
    return false;
  }

  UString comp;
  for (unsigned i = 0;; i++) {
    const wchar_t c = p[i];
    if (c == 0 || c == L'/' || c == L'\\') {
      if (!comp.IsEmpty()) {
        if (comp == L".") {
          // 忽略
        } else if (comp == L"..") {
          reason = "条目路径含上级引用 ..";
          return false;
        } else {
          if (comp.Find(L':') >= 0) {
            reason = "条目路径含非法字符 ':'";
            return false;
          }
          if (!relative.IsEmpty()) relative += L'/';
          relative += comp;
        }
        comp.Empty();
      }
      if (c == 0) break;
    } else {
      comp += c;
    }
  }

  if (relative.IsEmpty()) {
    reason = "条目路径规范化后为空";
    return false;
  }
  return true;
}

static bool StaysInside(const std::string &destDirUtf8, const std::string &fullPathUtf8) {
  std::string base = destDirUtf8;
  while (!base.empty() && base[base.size() - 1] == '/') base.erase(base.size() - 1);
  if (base.empty()) return false;
  if (fullPathUtf8.size() <= base.size()) return false;
  if (fullPathUtf8.compare(0, base.size(), base) != 0) return false;
  return fullPathUtf8[base.size()] == '/';
}

// 解析 dirUtf8 最深已存在祖先的真实路径，确认其未跳出 destDirUtf8。
static bool ParentRealPathInside(const std::string &destDirUtf8, const std::string &dirUtf8) {
  char destReal[PATH_MAX];
  if (realpath(destDirUtf8.c_str(), destReal) == NULL) return false;
  const std::string dest(destReal);
  if (dest.empty()) return false;

  std::string cur = dirUtf8;
  for (;;) {
    char real[PATH_MAX];
    if (realpath(cur.c_str(), real) != NULL) {
      const std::string r(real);
      if (r == dest) return true;
      return r.size() > dest.size() && r.compare(0, dest.size(), dest) == 0 &&
             r[dest.size()] == '/';
    }
    const size_t pos = cur.find_last_of('/');
    if (pos == std::string::npos || pos == 0) return false;
    cur.erase(pos);
  }
}

static std::string JoinPath(const std::string &dir, const std::string &rel) {
  std::string out = dir;
  if (!out.empty() && out[out.size() - 1] != '/') out += "/";
  out += rel;
  return out;
}

static bool EnsureDir(const std::string &utf8Dir) {
  if (utf8Dir.empty()) return true;
  return NFile::NDir::CreateComplexDir(ToFString(utf8Dir));
}

// 目标文件已存在时，给出「名称 (2).扩展名」「名称 (3).扩展名」…… 的第一个空闲名字
// （ClashPolicy::Rename 用，思路同 7-Zip 命令行的 -aou）。
// 从 2 开始：1 就是原名本身。全部被占则原样返回，交由调用方按覆盖处理。
static std::string MakeUniqueDestPath(const std::string &path) {
  struct stat st;
  if (stat(path.c_str(), &st) != 0) return path;   // 不存在，直接用原名

  const size_t slash = path.find_last_of('/');
  const size_t dot = path.find_last_of('.');
  const std::string dir = (slash == std::string::npos) ? std::string() : path.substr(0, slash + 1);
  std::string base, ext;
  // 只有点出现在最后一段分隔符之后才算扩展名（"/a.b/c" 的 "c" 没有扩展名）
  if (dot != std::string::npos && (slash == std::string::npos || dot > slash)) {
    base = path.substr(dir.size(), dot - dir.size());
    ext = path.substr(dot);
  } else {
    base = path.substr(dir.size());
  }

  for (int i = 2; i < 10000; i++) {
    const std::string cand = dir + base + " (" + std::to_string(i) + ")" + ext;
    if (stat(cand.c_str(), &st) != 0) return cand;
  }
  return path;
}

// 归一化路径（折叠 "." 与 ".."），不触盘。返回 false 表示 ".." 上溯越过了根。
static std::string NormalizePath(const std::string &p, bool *escapedRoot) {
  if (escapedRoot) *escapedRoot = false;
  const bool absolute = (!p.empty() && p[0] == '/');
  std::vector<std::string> parts;
  size_t i = 0;
  while (i < p.size()) {
    while (i < p.size() && p[i] == '/') i++;
    size_t j = i;
    while (j < p.size() && p[j] != '/') j++;
    if (j > i) {
      const std::string seg = p.substr(i, j - i);
      if (seg == ".") {
        // 忽略
      } else if (seg == "..") {
        if (!parts.empty()) {
          parts.pop_back();
        } else if (!absolute) {
          if (escapedRoot) *escapedRoot = true;
          parts.push_back(seg);
        } else if (escapedRoot) {
          *escapedRoot = true;
        }
      } else {
        parts.push_back(seg);
      }
    }
    i = j;
  }
  std::string out = absolute ? std::string("/") : std::string();
  for (size_t k = 0; k < parts.size(); k++) {
    if (k) out += "/";
    out += parts[k];
  }
  return out;
}

// 符号链接目标安全校验（技术方案 §8.2「符号链接劫持」）：
//   拒绝绝对路径、拒绝解析后跳出目标目录的相对路径。
static bool SymLinkTargetIsSafe(const std::string &destDirUtf8, const std::string &linkDiskPath,
                                const std::string &target, std::string &reason) {
  if (target.empty()) {
    reason = "链接目标为空";
    return false;
  }
  if (target[0] == '/') {
    reason = "目标为绝对路径";
    return false;
  }
  // 目标相对链接所在目录解析
  std::string linkDir = linkDiskPath;
  const size_t slash = linkDir.find_last_of('/');
  linkDir = (slash == std::string::npos) ? std::string(".") : linkDir.substr(0, slash);

  // 两侧都要归一化后再比较：目标目录可能含重复斜杠（例如 TMPDIR 以 '/' 结尾），
  // 而归一化结果会折叠斜杠，不统一处理会把安全链接误判为越界。
  bool escaped = false;
  const std::string destNorm = NormalizePath(destDirUtf8, &escaped);
  const std::string resolved = NormalizePath(JoinPath(linkDir, target), &escaped);
  if (escaped) {
    reason = "目标上溯越出目标目录";
    return false;
  }
  if (!StaysInside(destNorm, resolved)) {
    reason = "解析后位于目标目录之外";
    return false;
  }
  return true;
}

// 读取符号链接目标（UTF-8）
static std::string ReadLinkUtf8(const FString &linkPath) {
  std::vector<char> buf(1025);
  const ssize_t n = readlink(linkPath.Ptr(), &buf[0], buf.size() - 1);
  if (n <= 0) return std::string();
  buf[(size_t)n] = 0;
  return std::string(&buf[0], (size_t)n);
}

// 密码等敏感数据的显式清零（技术方案 §8.2「密码明文」）
static void BurnString(std::string &s) {
  if (s.empty()) return;
  volatile char *p = const_cast<volatile char *>(s.data());
  for (size_t i = 0; i < s.size(); i++) p[i] = 0;
  s.clear();
}

// RAII：作用域结束即清零持有的密码副本，避免中途 return 泄漏
struct CPasswordGuard {
  std::string pw;
  explicit CPasswordGuard(const std::string &s) : pw(s) {}
  ~CPasswordGuard() { BurnString(pw); }
  const std::string &get() const { return pw; }
};

// ---------------------------------------------------------------------------
// Open 回调
// ---------------------------------------------------------------------------

class COpenCallback Z7_final : public IArchiveOpenCallback,
                               public ICryptoGetTextPassword,
                               public CMyUnknownImp {
  Z7_IFACES_IMP_UNK_2(IArchiveOpenCallback, ICryptoGetTextPassword)

public:
  Callback *cb = NULL;
  std::string password;
  bool passwordAsked = false;
  // 是否真的向handler提供了非空密码。用于区分两种失败：
  //   提供了密码仍打不开 → 密码多半是错的（或文件损坏）
  //   没提供密码         → handler 报 E_ABORT，即"需要密码"
  // 缺少该标志时，头加密归档配错密码会退化成"无法识别归档格式"，对用户是误导。
  bool passwordSupplied = false;

  COpenCallback() {}
};

Z7_COM7F_IMF(COpenCallback::SetTotal(const UInt64 *, const UInt64 *)) { return S_OK; }

Z7_COM7F_IMF(COpenCallback::SetCompleted(const UInt64 *, const UInt64 *)) {
  if (cb && cb->IsCanceled()) return E_ABORT;
  return S_OK;
}

Z7_COM7F_IMF(COpenCallback::CryptoGetTextPassword(BSTR *outPassword)) {
  if (!passwordAsked) {
    passwordAsked = true;
    if (cb) password = cb->GetPassword(false);
  }
  if (password.empty()) return E_ABORT;
  passwordSupplied = true;
  return StringToBstr(ToUString(password), outPassword);
}

// ---------------------------------------------------------------------------
// 计数输出流：转发写入并累计字节数，用于压缩炸弹实时上限
// ---------------------------------------------------------------------------

Z7_CLASS_IMP_NOQIB_1(
  CCountingOutStream
  , ISequentialOutStream
)
public:
  CMyComPtr<ISequentialOutStream> inner;
  UInt64 *counter = NULL;
  UInt64 limit = 0;
  bool *tripped = NULL;
};

Z7_COM7F_IMF(CCountingOutStream::Write(const void *data, UInt32 size,
                                       UInt32 *processedSize)) {
  if (processedSize) *processedSize = 0;
  if (!inner) return E_FAIL;
  if (limit != 0 && counter && tripped && (*counter + size) > limit) {
    *tripped = true;
    return E_ABORT;
  }
  UInt32 done = 0;
  RINOK(inner->Write(data, size, &done));
  if (counter) *counter += done;
  if (processedSize) *processedSize = done;
  return S_OK;
}

// ---------------------------------------------------------------------------
// 符号链接捕获流：把条目数据（链接目标文本）收集到内存
// 部分格式（如 tar / 7z for Unix）把符号链接目标作为条目内容存放，
// 而另有格式通过 kpidSymLink 属性直接给出，两条路径都要覆盖。
// ---------------------------------------------------------------------------

Z7_CLASS_IMP_NOQIB_1(
  CSymLinkCaptureStream
  , ISequentialOutStream
)
public:
  static const size_t kMaxTarget = 4095; // 与 Linux PATH_MAX 对齐
  std::string data;
  bool overflow = false;
  UInt64 *writtenBytes = NULL;
};

Z7_COM7F_IMF(CSymLinkCaptureStream::Write(const void *bytes, UInt32 size,
                                          UInt32 *processedSize)) {
  if (processedSize) *processedSize = size;
  if (writtenBytes) *writtenBytes += size;
  if (overflow) return S_OK;
  if (data.size() + size > kMaxTarget) {
    overflow = true;
    data.clear();
    return S_OK;
  }
  data.append((const char *)bytes, size);
  return S_OK;
}

// ---------------------------------------------------------------------------
// 解压 / 测试回调
// ---------------------------------------------------------------------------

class CExtractCallback Z7_final : public IArchiveExtractCallback,
                                  public ICryptoGetTextPassword,
                                  public CMyUnknownImp {
  Z7_IFACES_IMP_UNK_2(IArchiveExtractCallback, ICryptoGetTextPassword)
  Z7_IFACE_COM7_IMP(IProgress)

  CMyComPtr<IInArchive> _archive;
  std::string _destDirUtf8;
  bool _testMode = false;
  ClashPolicy _clash = ClashPolicy::Overwrite;
  std::string _explicitDestFile; // 非空时只写该文件（单条目提取 / 预览）

  // 技术方案 §7.4：先写 .partial 再原子改名；§8.2：符号链接白名单创建
  bool _atomicFiles = true;
  bool _createSymLinks = true;

  // 注意：COutFileStream 的 AddRef/Release 由 Z7_CLASS_IMP_COM_1 放在私有区，
  // 因此只能用接口类型的智能指针持有它，另外保留裸指针用于 Close/SetMTime。
  COutFileStream *_fileSpec = NULL;
  CMyComPtr<ISequentialOutStream> _outStream;

  // 符号链接状态
  bool _isSymLink = false;
  std::string _linkTarget;
  CSymLinkCaptureStream *_captureSpec = NULL;
  CMyComPtr<ISequentialOutStream> _captureStream;

  UString _currentArcPath;
  UInt32 _currentIndex = 0;
  bool _currentIsDir = false;
  bool _hasMTime = false;
  CFiTime _currentMTime;
  bool _hasAttrib = false;
  UInt32 _currentAttrib = 0;
  std::string _currentDiskPath;
  std::string _partialPath;
  bool _wroteFile = false;

public:
  Callback *cb = NULL;
  std::string password;
  bool passwordAsked = false;

  UInt64 numErrors = 0;
  UInt64 numWrongPassword = 0;
  UInt64 numUnsafe = 0;
  UInt64 numSkipped = 0;
  UInt64 numSymLinks = 0;
  UInt64 writtenBytes = 0;
  UInt64 bombLimit = 0;
  bool bombTripped = false;
  bool atomicFallback = false;

  void Init(IInArchive *archive, const std::string &destDirUtf8, bool testMode,
            ClashPolicy clash) {
    _archive = archive;
    _destDirUtf8 = destDirUtf8;
    while (_destDirUtf8.size() > 1 && _destDirUtf8[_destDirUtf8.size() - 1] == '/')
      _destDirUtf8.erase(_destDirUtf8.size() - 1);
    _testMode = testMode;
    _clash = clash;
  }
  void SetExplicitDestFile(const std::string &f) { _explicitDestFile = f; }
  void SetPolicy(bool atomicFiles, bool createSymLinks) {
    _atomicFiles = atomicFiles;
    _createSymLinks = createSymLinks;
  }
};

Z7_COM7F_IMF(CExtractCallback::SetTotal(UInt64 total)) {
  if (cb && !cb->OnProgress(0, total, 0, std::string())) return E_ABORT;
  return S_OK;
}

Z7_COM7F_IMF(CExtractCallback::SetCompleted(const UInt64 *completeValue)) {
  if (bombTripped) {
    if (cb) cb->OnLog(LogLevel::Error, "解压总量超过安全上限，已中止（疑似压缩炸弹）");
    return E_ABORT;
  }
  if (cb) {
    if (cb->IsCanceled()) return E_ABORT;
    if (!cb->OnProgress(completeValue ? *completeValue : 0, 0, _currentIndex,
                        ToUtf8(_currentArcPath)))
      return E_ABORT;
  }
  return S_OK;
}

Z7_COM7F_IMF(CExtractCallback::GetStream(UInt32 index, ISequentialOutStream **outStream,
                                         Int32 askExtractMode)) {
  *outStream = NULL;
  _outStream.Release();
  _captureStream.Release();
  _captureSpec = NULL;
  _fileSpec = NULL;
  _currentIndex = index;
  _currentIsDir = false;
  _hasMTime = false;
  _hasAttrib = false;
  _isSymLink = false;
  _linkTarget.clear();
  _currentDiskPath.clear();
  _partialPath.clear();
  _wroteFile = false;

  NCOM::CPropVariant prop;
  RINOK(_archive->GetProperty(index, kpidPath, &prop));
  if (prop.vt == VT_BSTR && prop.bstrVal)
    _currentArcPath = prop.bstrVal;
  else if (prop.vt == VT_EMPTY)
    _currentArcPath = L"[Content]";
  else
    return E_FAIL;

  if (askExtractMode != NArchive::NExtract::NAskMode::kExtract) return S_OK;

  {
    NCOM::CPropVariant p;
    RINOK(_archive->GetProperty(index, kpidIsDir, &p));
    if (p.vt == VT_BOOL) _currentIsDir = (p.boolVal != VARIANT_FALSE);
  }
  {
    NCOM::CPropVariant p;
    RINOK(_archive->GetProperty(index, kpidAttrib, &p));
    if (p.vt == VT_UI4) {
      _currentAttrib = p.ulVal;
      _hasAttrib = true;
    }
  }
  {
    NCOM::CPropVariant p;
    RINOK(_archive->GetProperty(index, kpidMTime, &p));
    if (p.vt == VT_FILETIME) {
      FILETIME_To_timespec(p.filetime, _currentMTime);
      _hasMTime = true;
    }
  }

  // 符号链接探测（技术方案 §8.2）。
  // 优先读 kpidSymLink（RAR5 / WIM 等直接给出目标），否则看 kpidAttrib
  // 高 16 位的 POSIX 模式是否带 S_IFLNK（tar / 7z for Unix 用这种表示）。
  if (!_currentIsDir) {
    {
      NCOM::CPropVariant p;
      if (_archive->GetProperty(index, kpidSymLink, &p) == S_OK && p.vt == VT_BSTR &&
          p.bstrVal) {
        _linkTarget = ToUtf8(p.bstrVal);
        _isSymLink = !_linkTarget.empty();
      }
    }
    if (!_isSymLink && _hasAttrib && MY_LIN_S_ISLNK(_currentAttrib >> 16)) _isSymLink = true;
  }

  // 目标路径：显式指定优先，否则按归档内路径推导并做安全校验
  if (!_explicitDestFile.empty()) {
    if (_currentIsDir) return S_OK;
    // 单文件提取 / 预览：符号链接按普通文件写出（内容是目标文本），
    // 避免在用户指定目录之外创建链接。
    _currentDiskPath = _explicitDestFile;
    const size_t slash = _currentDiskPath.find_last_of('/');
    if (slash != std::string::npos && !EnsureDir(_currentDiskPath.substr(0, slash))) {
      numErrors++;
      if (cb) cb->OnLog(LogLevel::Error, "无法创建目录");
      return S_OK;
    }
    _isSymLink = false;
  } else {
    UString relative;
    std::string reason;
    if (!SanitizeArcPath(_currentArcPath, relative, reason)) {
      numUnsafe++;
      if (cb)
        cb->OnLog(LogLevel::Error, "已拒绝不安全条目 \"" + ToUtf8(_currentArcPath) +
                                       "\"：" + reason);
      return S_OK;
    }

    _currentDiskPath = JoinPath(_destDirUtf8, ToUtf8(relative));

    if (!StaysInside(_destDirUtf8, _currentDiskPath)) {
      numUnsafe++;
      if (cb) cb->OnLog(LogLevel::Error, "已拒绝越界条目：" + _currentDiskPath);
      return S_OK;
    }

    if (_currentIsDir) {
      if (!EnsureDir(_currentDiskPath)) {
        numErrors++;
        if (cb) cb->OnLog(LogLevel::Error, "无法创建目录：" + _currentDiskPath);
      }
      return S_OK;
    }

    const size_t slash = _currentDiskPath.find_last_of('/');
    if (slash != std::string::npos) {
      const std::string parent = _currentDiskPath.substr(0, slash);
      if (!ParentRealPathInside(_destDirUtf8, parent)) {
        numUnsafe++;
        if (cb)
          cb->OnLog(LogLevel::Error, "父目录真实路径越界或不可解析，已拒绝：" + parent);
        return S_OK;
      }
      if (!EnsureDir(parent)) {
        numErrors++;
        if (cb) cb->OnLog(LogLevel::Error, "无法创建目录：" + parent);
        return S_OK;
      }
    }

    // 目标已存在时的处理（-ao 系列语义）
    if (_clash != ClashPolicy::Overwrite) {
      struct stat st;
      if (stat(_currentDiskPath.c_str(), &st) == 0) {
        if (_clash == ClashPolicy::Skip) {
          numSkipped++;
          if (cb) cb->OnLog(LogLevel::Info, "已存在，跳过：" + _currentDiskPath);
          return S_OK;
        }
        // Rename：改成一个空闲名字，后续写入、日志与统计都落在这个新名字上
        const std::string renamed = MakeUniqueDestPath(_currentDiskPath);
        if (renamed != _currentDiskPath) {
          if (cb) cb->OnLog(LogLevel::Info, "已存在，改名为：" + renamed);
          _currentDiskPath = renamed;
        }
      }
    }

    // 符号链接：此处只建立捕获流，真正的创建与安全校验在 SetOperationResult
    // 里完成，因为目标既可能来自 kpidSymLink，也可能来自条目数据流。
    if (_isSymLink) {
      if (_testMode) return S_OK;
      CSymLinkCaptureStream *cap = new CSymLinkCaptureStream;
      CMyComPtr<ISequentialOutStream> capHolder(cap);
      cap->writtenBytes = &writtenBytes;
      _captureSpec = cap;
      _captureStream = capHolder;
      *outStream = capHolder.Detach();
      return S_OK;
    }
  }

  COutFileStream *file = new COutFileStream;
  CMyComPtr<ISequentialOutStream> fileStream(file);

  // 技术方案 §7.4：先写 "<目标>.partial"，成功后再原子改名，失败则删除半成品。
  const bool usePartial = (_atomicFiles && !_testMode);
  std::string createPath = usePartial ? (_currentDiskPath + ".partial") : _currentDiskPath;
  if (!file->Create_ALWAYS(ToFString(createPath))) {
    if (!usePartial) {
      numErrors++;
      if (cb) cb->OnLog(LogLevel::Error, "无法写入文件：" + _currentDiskPath);
      return S_OK;
    }
    // .partial 建不出来（例如残留同名目录）时降级为直写目标路径
    createPath = _currentDiskPath;
    atomicFallback = true;
    if (!file->Create_ALWAYS(ToFString(createPath))) {
      numErrors++;
      if (cb) cb->OnLog(LogLevel::Error, "无法写入文件：" + _currentDiskPath);
      return S_OK;
    }
  }
  if (usePartial && createPath != _currentDiskPath) _partialPath = createPath;
  _wroteFile = true;

  CCountingOutStream *counting = new CCountingOutStream;
  CMyComPtr<ISequentialOutStream> countingStream(counting);
  counting->inner = fileStream;
  counting->counter = &writtenBytes;
  counting->limit = bombLimit;
  counting->tripped = &bombTripped;

  _fileSpec = file;
  _outStream = countingStream;
  *outStream = countingStream.Detach();
  return S_OK;
}

Z7_COM7F_IMF(CExtractCallback::PrepareOperation(Int32)) { return S_OK; }

Z7_COM7F_IMF(CExtractCallback::SetOperationResult(Int32 operationResult)) {
  const bool ok = (operationResult == NArchive::NExtract::NOperationResult::kOK);

  switch (operationResult) {
    case NArchive::NExtract::NOperationResult::kOK:
      break;
    case NArchive::NExtract::NOperationResult::kWrongPassword:
      numWrongPassword++;
      if (cb) cb->OnLog(LogLevel::Error, "密码错误：" + ToUtf8(_currentArcPath));
      break;
    default: {
      numErrors++;
      if (cb) {
        const char *s = NULL;
        switch (operationResult) {
          case NArchive::NExtract::NOperationResult::kUnsupportedMethod:
            s = "不支持的压缩方法";
            break;
          case NArchive::NExtract::NOperationResult::kCRCError: s = "CRC 校验失败"; break;
          case NArchive::NExtract::NOperationResult::kDataError: s = "数据错误"; break;
          case NArchive::NExtract::NOperationResult::kUnavailable: s = "数据不可用"; break;
          case NArchive::NExtract::NOperationResult::kUnexpectedEnd:
            s = "数据意外结束";
            break;
          case NArchive::NExtract::NOperationResult::kDataAfterEnd:
            s = "负载后仍有数据";
            break;
          case NArchive::NExtract::NOperationResult::kIsNotArc: s = "不是归档"; break;
          case NArchive::NExtract::NOperationResult::kHeadersError: s = "头部错误"; break;
          default: break;
        }
        std::string msg = ToUtf8(_currentArcPath) + "：";
        msg += s ? s : ("错误码 " + HRText(operationResult));
        cb->OnLog(LogLevel::Error, msg);
      }
      break;
    }
  }

  if (_fileSpec) {
    if (_hasMTime) _fileSpec->SetMTime(&_currentMTime);
    _fileSpec->Close();
  }
  _outStream.Release();
  _fileSpec = NULL;

  // ---------- 符号链接收尾（技术方案 §8.2）----------
  if (_isSymLink) {
    std::string target = _linkTarget;
    const bool overflowed = (_captureSpec == NULL || _captureSpec->overflow);
    if (target.empty() && !overflowed) target = _captureSpec->data;
    _captureStream.Release();
    _captureSpec = NULL;
    _isSymLink = false;

    if (!ok || _testMode) return S_OK;

    if (target.empty()) {
      numErrors++;
      if (cb)
        cb->OnLog(LogLevel::Error,
                  std::string(overflowed ? "符号链接目标过长，已拒绝：" : "符号链接目标为空，已拒绝：") +
                      ToUtf8(_currentArcPath));
      return S_OK;
    }
    if (!_createSymLinks) {
      numSkipped++;
      if (cb)
        cb->OnLog(LogLevel::Warning,
                  "已跳过符号链接（当前策略禁止创建）：" + ToUtf8(_currentArcPath));
      return S_OK;
    }

    std::string reason;
    if (!SymLinkTargetIsSafe(_destDirUtf8, _currentDiskPath, target, reason)) {
      numUnsafe++;
      if (cb)
        cb->OnLog(LogLevel::Error, "已拒绝不安全符号链接 \"" + ToUtf8(_currentArcPath) +
                                       "\"（-> " + target + "）：" + reason);
      return S_OK;
    }

    struct stat lst;
    if (lstat(_currentDiskPath.c_str(), &lst) == 0) {
      if (MY_LIN_S_ISDIR(lst.st_mode)) {
        numErrors++;
        if (cb)
          cb->OnLog(LogLevel::Error, "同名目录已存在，无法创建符号链接：" + _currentDiskPath);
        return S_OK;
      }
      unlink(_currentDiskPath.c_str());
    }

    if (symlink(target.c_str(), _currentDiskPath.c_str()) == 0) {
      numSymLinks++;
      if (_hasMTime) {
        struct timespec ts[2];
        ts[0].tv_sec = _currentMTime.tv_sec;
        ts[0].tv_nsec = _currentMTime.tv_nsec;
        ts[1] = ts[0];
        utimensat(AT_FDCWD, _currentDiskPath.c_str(), ts, AT_SYMLINK_NOFOLLOW);
      }
      if (cb)
        cb->OnLog(LogLevel::Info, "符号链接 " + ToUtf8(_currentArcPath) + " -> " + target);
    } else {
      numErrors++;
      if (cb) cb->OnLog(LogLevel::Error, "无法创建符号链接：" + _currentDiskPath);
    }
    return S_OK;
  }

  // ---------- 普通文件收尾（技术方案 §7.4）----------
  if (_testMode || !_wroteFile || _currentIsDir || _currentDiskPath.empty()) return S_OK;

  if (!_partialPath.empty()) {
    if (ok) {
      if (rename(_partialPath.c_str(), _currentDiskPath.c_str()) != 0) {
        unlink(_partialPath.c_str());
        numErrors++;
        if (cb) cb->OnLog(LogLevel::Error, "原子落盘失败，已删除临时文件：" + _currentDiskPath);
        return S_OK;
      }
      _partialPath.clear();
    } else {
      // 半成品一律清理，不留残渣在目标目录
      unlink(_partialPath.c_str());
      _partialPath.clear();
      return S_OK;
    }
  } else if (!ok) {
    // 直写降级路径：同样不保留半成品
    unlink(_currentDiskPath.c_str());
    return S_OK;
  }

  // kpidAttrib 的高 16 位承载 POSIX 模式（FILE_ATTRIBUTE_UNIX_EXTENSION），
  // 直接 & 07777 会丢失全部权限位，必须走上游的检测函数。
  if (_hasAttrib)
    NFile::NDir::SetFileAttrib_PosixHighDetect(ToFString(_currentDiskPath),
                                               _currentAttrib);
  if (_hasMTime) {
    struct timespec ts[2];
    ts[0].tv_sec = _currentMTime.tv_sec;
    ts[0].tv_nsec = _currentMTime.tv_nsec;
    ts[1] = ts[0];
    utimensat(AT_FDCWD, _currentDiskPath.c_str(), ts, 0);
  }
  return S_OK;
}

Z7_COM7F_IMF(CExtractCallback::CryptoGetTextPassword(BSTR *outPassword)) {
  if (!passwordAsked) {
    passwordAsked = true;
    if (cb) password = cb->GetPassword(false);
  }
  if (password.empty()) return E_ABORT;
  return StringToBstr(ToUString(password), outPassword);
}

// ---------------------------------------------------------------------------
// 内存提取回调
// ---------------------------------------------------------------------------

Z7_CLASS_IMP_NOQIB_1(
  CMemoryStream
  , ISequentialOutStream
)
public:
  std::vector<Byte> *data = NULL;
  UInt64 limit = 0;
  bool tooLarge = false;
};

Z7_COM7F_IMF(CMemoryStream::Write(const void *bytes, UInt32 size, UInt32 *processedSize)) {
  if (processedSize) *processedSize = 0;
  if (!data || tooLarge) return S_OK;
  if (limit != 0 && (UInt64)data->size() + size > limit) {
    tooLarge = true;
    return E_ABORT;
  }
  const Byte *p = (const Byte *)bytes;
  const size_t old = data->size();
  data->resize(old + size);
  memcpy(&(*data)[old], p, size);
  if (processedSize) *processedSize = size;
  return S_OK;
}

class CMemoryExtractCallback Z7_final : public IArchiveExtractCallback,
                                        public ICryptoGetTextPassword,
                                        public CMyUnknownImp {
  Z7_IFACES_IMP_UNK_2(IArchiveExtractCallback, ICryptoGetTextPassword)
  Z7_IFACE_COM7_IMP(IProgress)

  CMyComPtr<IInArchive> _archive;
  std::vector<Byte> *_data = NULL;
  CMyComPtr<ISequentialOutStream> _held;
  bool _skipping = false;

public:
  bool tooLarge = false;
  UInt64 limit = 0;
  Callback *cb = NULL;
  std::string password;
  std::string errorText;

  void Init(IInArchive *a, std::vector<Byte> *d, UInt64 lim) {
    _archive = a;
    _data = d;
    limit = lim;
  }
};

Z7_COM7F_IMF(CMemoryExtractCallback::SetTotal(UInt64)) { return S_OK; }
Z7_COM7F_IMF(CMemoryExtractCallback::SetCompleted(const UInt64 *)) {
  if (cb && cb->IsCanceled()) return E_ABORT;
  return S_OK;
}

Z7_COM7F_IMF(CMemoryExtractCallback::GetStream(UInt32 index, ISequentialOutStream **outStream,
                                               Int32 askExtractMode)) {
  *outStream = NULL;
  _held.Release();
  if (askExtractMode != NArchive::NExtract::NAskMode::kExtract) return S_OK;

  _skipping = false;
  if (_archive) {
    NCOM::CPropVariant p;
    if (_archive->GetProperty(index, kpidIsDir, &p) == S_OK && p.vt == VT_BOOL &&
        p.boolVal != VARIANT_FALSE)
      _skipping = true;
    if (_archive->GetProperty(index, kpidSize, &p) == S_OK) {
      UInt64 sz = 0;
      if (ConvertPropVariantToUInt64(p, sz) && limit != 0 && sz > limit) {
        tooLarge = true;
        _skipping = true;
      }
    }
  }
  if (_skipping) return S_OK;

  CMemoryStream *m = new CMemoryStream;
  CMyComPtr<ISequentialOutStream> holder(m);
  m->data = _data;
  m->limit = limit;
  _held = holder;
  *outStream = holder.Detach();
  return S_OK;
}

Z7_COM7F_IMF(CMemoryExtractCallback::PrepareOperation(Int32)) { return S_OK; }

Z7_COM7F_IMF(CMemoryExtractCallback::SetOperationResult(Int32 operationResult)) {
  if (_held) {
    CMemoryStream *m = NULL;
    // 通过独立查询取回 tooLarge 标记不可行，改为在 Write 上抛 E_ABORT 由外层判定
    (void)m;
  }
  _held.Release();
  if (operationResult != NArchive::NExtract::NOperationResult::kOK) {
    if (operationResult == NArchive::NExtract::NOperationResult::kWrongPassword)
      errorText = "密码错误";
    else if (operationResult == NArchive::NExtract::NOperationResult::kCRCError)
      errorText = "CRC 校验失败";
    else
      errorText = "提取失败（" + HRText(operationResult) + "）";
  }
  return S_OK;
}

Z7_COM7F_IMF(CMemoryExtractCallback::CryptoGetTextPassword(BSTR *outPassword)) {
  if (password.empty()) return E_ABORT;
  return StringToBstr(ToUString(password), outPassword);
}

// ---------------------------------------------------------------------------
// 压缩回调
// ---------------------------------------------------------------------------

struct SDirItem {
  FString diskPath;
  UString arcPath;
  bool isDir = false;
  bool isSymLink = false;
  std::string linkTarget; // UTF-8，仅 isSymLink 时有效（作为条目数据）
  UInt64 size = 0;
  CFiTime ctime, atime, mtime;
  UInt32 winAttrib = 0;
  UInt32 posixAttrib = 0;
};

// 只读内存输入流：用于把符号链接目标文本作为条目数据交给引擎
Z7_CLASS_IMP_NOQIB_1(
  CBufferInStream
  , ISequentialInStream
)
public:
  std::string data;
  size_t pos = 0;
};

Z7_COM7F_IMF(CBufferInStream::Read(void *buffer, UInt32 size, UInt32 *processedSize)) {
  if (processedSize) *processedSize = 0;
  if (pos >= data.size()) return S_OK;
  const size_t remain = data.size() - pos;
  const size_t n = (remain < (size_t)size) ? remain : (size_t)size;
  memcpy(buffer, data.data() + pos, n);
  pos += n;
  if (processedSize) *processedSize = (UInt32)n;
  return S_OK;
}

class CUpdateCallback Z7_final : public IArchiveUpdateCallback2,
                                 public ICryptoGetTextPassword2,
                                 public CMyUnknownImp {
  Z7_IFACES_IMP_UNK_2(IArchiveUpdateCallback2, ICryptoGetTextPassword2)
  Z7_IFACE_COM7_IMP(IProgress)
  Z7_IFACE_COM7_IMP(IArchiveUpdateCallback)

  const std::vector<SDirItem> *_items = NULL;
  UInt64 _completed = 0;

public:
  Callback *cb = NULL;
  std::string password;
  std::vector<std::string> failedFiles;
  UInt64 totalBytes = 0;

  // ---- 更新模式（addItems）----
  // 空 pairs 表示"全部为新条目"（创建新归档的常规路径）。
  struct SUpdatePair {
    bool newData = true;
    bool newProps = true;
    UInt32 indexInArchive = (UInt32)(Int32)-1;
  };
  std::vector<SUpdatePair> pairs;
  // 每个输出槽位对应的 _items 下标；-1 表示复用归档中的既有条目、不提供数据
  std::vector<int> slotToItem;

  void Init(const std::vector<SDirItem> *items) { _items = items; }
  void InitUpdate(const std::vector<SDirItem> *items, const std::vector<SUpdatePair> *p,
                  const std::vector<int> *map) {
    _items = items;
    if (p) pairs = *p;
    if (map) slotToItem = *map;
  }

  // 输出槽位 -> _items 下标；返回 -1 表示复用旧条目
  int ItemIndexForSlot(UInt32 index) const {
    if (slotToItem.empty()) return (int)index;
    if (index >= slotToItem.size()) return -1;
    return slotToItem[index];
  }
};

Z7_COM7F_IMF(CUpdateCallback::SetTotal(UInt64 size)) {
  totalBytes = size;
  if (cb && !cb->OnProgress(0, size, 0, std::string())) return E_ABORT;
  return S_OK;
}

Z7_COM7F_IMF(CUpdateCallback::SetCompleted(const UInt64 *completeValue)) {
  if (completeValue) _completed = *completeValue;
  if (cb) {
    if (cb->IsCanceled()) return E_ABORT;
    if (!cb->OnProgress(_completed, totalBytes, 0, std::string())) return E_ABORT;
  }
  return S_OK;
}

Z7_COM7F_IMF(CUpdateCallback::GetUpdateItemInfo(UInt32 index, Int32 *newData,
                                                Int32 *newProperties,
                                                UInt32 *indexInArchive)) {
  if (pairs.empty()) {
    if (newData) *newData = BoolToInt(true);
    if (newProperties) *newProperties = BoolToInt(true);
    if (indexInArchive) *indexInArchive = (UInt32)(Int32)-1;
    return S_OK;
  }
  if (index >= pairs.size()) return E_INVALIDARG;
  const SUpdatePair &p = pairs[index];
  if (newData) *newData = BoolToInt(p.newData);
  if (newProperties) *newProperties = BoolToInt(p.newProps);
  if (indexInArchive) *indexInArchive = p.indexInArchive;
  return S_OK;
}

Z7_COM7F_IMF(CUpdateCallback::GetProperty(UInt32 index, PROPID propID, PROPVARIANT *value)) {
  NCOM::CPropVariant prop;
  if (!_items) return E_INVALIDARG;
  const int ii = ItemIndexForSlot(index);
  if (ii < 0) return S_OK; // 复用旧条目，引擎不应查询属性
  if ((size_t)ii >= _items->size()) return E_INVALIDARG;
  const SDirItem &di = (*_items)[(size_t)ii];

  switch (propID) {
    case kpidIsAnti: prop = false; break;
    case kpidPath: prop = di.arcPath; break;
    case kpidIsDir: prop = di.isDir; break;
    case kpidSize: prop = di.isDir ? (UInt64)0 : di.size; break;
    case kpidCTime: PropVariant_SetFrom_FiTime(prop, di.ctime); break;
    case kpidATime: PropVariant_SetFrom_FiTime(prop, di.atime); break;
    case kpidMTime: PropVariant_SetFrom_FiTime(prop, di.mtime); break;
    // 符号链接用 POSIX 模式的 S_IFLNK 位标记，与 7zz / Unix 版 7-Zip 一致；
    // 目标文本作为条目数据由 GetStream 提供。
    case kpidAttrib:
      prop = di.isSymLink ? (UInt32)((((UInt32)MY_LIN_S_IFLNK) << 16) | 0x8000u)
                          : (UInt32)di.winAttrib;
      break;
    case kpidPosixAttrib:
      prop = di.isSymLink ? (UInt32)MY_LIN_S_IFLNK : (UInt32)di.posixAttrib;
      break;
    case kpidSymLink:
      if (di.isSymLink) prop = ToUString(di.linkTarget);
      break;
    default: break;
  }
  prop.Detach(value);
  return S_OK;
}

Z7_COM7F_IMF(CUpdateCallback::GetStream(UInt32 index, ISequentialInStream **inStream)) {
  *inStream = NULL;
  if (!_items) return E_INVALIDARG;
  const int ii = ItemIndexForSlot(index);
  if (ii < 0) return S_OK; // 复用旧条目，不提供数据
  if ((size_t)ii >= _items->size()) return E_INVALIDARG;
  const SDirItem &di = (*_items)[(size_t)ii];
  if (di.isDir) return S_OK; // 目录没有数据流

  // 符号链接：条目数据就是链接目标文本，不再打开磁盘文件
  if (di.isSymLink) {
    CBufferInStream *buf = new CBufferInStream;
    CMyComPtr<ISequentialInStream> stream(buf);
    buf->data = di.linkTarget;
    *inStream = stream.Detach();
    return S_OK;
  }

  CInFileStream *spec = new CInFileStream;
  CMyComPtr<ISequentialInStream> stream(spec);
  if (!spec->Open(di.diskPath)) {
    failedFiles.push_back(ToUtf8(fs2us(di.diskPath)));
    if (cb) cb->OnLog(LogLevel::Error, "无法读取：" + ToUtf8(fs2us(di.diskPath)));
    return S_FALSE;
  }
  *inStream = stream.Detach();
  return S_OK;
}

Z7_COM7F_IMF(CUpdateCallback::SetOperationResult(Int32)) { return S_OK; }

// 分卷输出走 CMultiOutStream（与 7zz -v 一致），因此不启用回调驱动的分卷。
Z7_COM7F_IMF(CUpdateCallback::GetVolumeSize(UInt32, UInt64 *)) { return S_FALSE; }

Z7_COM7F_IMF(CUpdateCallback::GetVolumeStream(UInt32, ISequentialOutStream **)) {
  return E_NOTIMPL;
}

Z7_COM7F_IMF(CUpdateCallback::CryptoGetTextPassword2(Int32 *passwordIsDefined,
                                                     BSTR *outPassword)) {
  *passwordIsDefined = BoolToInt(!password.empty());
  if (password.empty()) return StringToBstr(UString(), outPassword);
  return StringToBstr(ToUString(password), outPassword);
}

// ---------------------------------------------------------------------------
// 目录遍历（符号链接存为链接条目，不跟随、不递归，天然无环）
// ---------------------------------------------------------------------------

// macOS / Windows 系统元数据垃圾文件：压缩与列表时默认排除，避免污染归档。
// 压缩侧是否排除由 CompressionOptions::excludeMacJunk 决定（面板上的
// 「排除 Mac 资源文件」开关）；列表侧（getAllItems）始终排除。
// 覆盖 .DS_Store、__MACOSX（Apple 的 zip 资源派生容器）、._*（AppleDouble 资源文件）、
// .AppleDouble、.Spotlight-V100、.Trashes 等 macOS 产物，以及 Thumbs.db / Desktop.ini 等 Windows 产物。
static bool IsMacJunkComponent(const std::string &name) {
  if (name.empty()) return false;
  if (name == ".DS_Store") return true;
  if (name == "__MACOSX") return true;
  if (name == ".AppleDouble") return true;
  if (name == ".VolumeIcon.icns") return true;
  if (name == ".Spotlight-V100") return true;
  if (name == ".Trashes") return true;
  if (name == ".fseventsd") return true;
  if (name == ".TemporaryItems") return true;
  if (name == ".apdisk") return true;
  if (name == ".DocumentRevisions-V100") return true;
  if (name == ".metadata_never_index") return true;
  if (name == "Thumbs.db") return true;
  if (name == "Desktop.ini") return true;
  if (name == "ehthumbs.db") return true;
  if (name == "Network Trash Folder") return true;
  if (name == "Temporary Items") return true;
  if (name.size() >= 2 && name[0] == '.' && name[1] == '_') return true; // AppleDouble: ._xxx
  return false;
}

// 路径的任意分段命中垃圾名则返回 true（用于归档内条目，例如 __MACOSX/._foo）。
static bool IsMacJunkPath(const std::string &path) {
  size_t start = 0;
  while (start < path.size()) {
    size_t slash = path.find('/', start);
    std::string comp = (slash == std::string::npos)
        ? path.substr(start)
        : path.substr(start, slash - start);
    if (IsMacJunkComponent(comp)) return true;
    if (slash == std::string::npos) break;
    start = slash + 1;
  }
  return false;
}

static void CollectItems(const FString &diskPath, const UString &arcPath,
                         std::vector<SDirItem> &out, Callback *cb, unsigned depth,
                         bool excludeJunk) {
  if (depth > 128) {
    if (cb) cb->OnLog(LogLevel::Warning, "目录层级过深，已停止递归：" + ToUtf8(arcPath));
    return;
  }

  // 排除 macOS/Windows 系统元数据垃圾文件（.DS_Store / __MACOSX / ._* / ...）
  if (excludeJunk && IsMacJunkComponent(ToUtf8(arcPath))) {
    if (cb) cb->OnLog(LogLevel::Warning, "已跳过系统元数据文件：" + ToUtf8(arcPath));
    return;
  }

  NFile::NFind::CFileInfo fi;
  if (!fi.Find(diskPath)) {
    if (cb) cb->OnLog(LogLevel::Warning, "无法访问，已跳过：" + ToUtf8(arcPath));
    return;
  }

  // 符号链接存为链接条目（目标文本作为数据），不跟随、不递归，
  // 这既与 7zz 的 Unix 默认行为一致（-snl），也天然规避了目录环。
  if (fi.IsPosixLink()) {
    const std::string target = ReadLinkUtf8(diskPath);
    if (target.empty()) {
      if (cb) cb->OnLog(LogLevel::Warning, "符号链接目标不可读，已跳过：" + ToUtf8(arcPath));
      return;
    }
    SDirItem di;
    di.diskPath = diskPath;
    di.arcPath = arcPath;
    di.isSymLink = true;
    di.linkTarget = target;
    di.size = (UInt64)target.size();
    di.ctime = fi.CTime;
    di.atime = fi.ATime;
    di.mtime = fi.MTime;
    di.winAttrib = 0;
    di.posixAttrib = MY_LIN_S_IFLNK | 0777;
    out.push_back(di);
    return;
  }

  if (fi.IsDir()) {
    SDirItem di;
    di.diskPath = diskPath;
    di.arcPath = arcPath;
    di.isDir = true;
    di.ctime = fi.CTime;
    di.atime = fi.ATime;
    di.mtime = fi.MTime;
    di.winAttrib = fi.GetWinAttrib();
    di.posixAttrib = fi.GetPosixAttrib();
    out.push_back(di);

    const std::string dirUtf8 = ToUtf8(fs2us(diskPath));
    DIR *d = opendir(dirUtf8.c_str());
    if (!d) {
      if (cb) cb->OnLog(LogLevel::Warning, "无法列出目录：" + dirUtf8);
      return;
    }
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
      const char *nm = ent->d_name;
      if (strcmp(nm, ".") == 0 || strcmp(nm, "..") == 0) continue;
      // 跳过 macOS/Windows 系统元数据垃圾文件，避免污染归档
      if (excludeJunk && IsMacJunkComponent(std::string(nm))) {
        if (cb) cb->OnLog(LogLevel::Warning, "已跳过系统元数据文件：" + JoinPath(dirUtf8, std::string(nm)));
        continue;
      }
      const std::string childUtf8 = JoinPath(dirUtf8, std::string(nm));
      UString childArc = arcPath;
      childArc += L'/';
      childArc += ToUString(std::string(nm));
      CollectItems(ToFString(childUtf8), childArc, out, cb, depth + 1, excludeJunk);
    }
    closedir(d);
  } else {
    SDirItem di;
    di.diskPath = diskPath;
    di.arcPath = arcPath;
    di.isDir = false;
    di.size = fi.Size;
    di.ctime = fi.CTime;
    di.atime = fi.ATime;
    di.mtime = fi.MTime;
    di.winAttrib = fi.GetWinAttrib();
    di.posixAttrib = fi.GetPosixAttrib();
    out.push_back(di);
  }
}

// ---------------------------------------------------------------------------
// 格式枚举
// ---------------------------------------------------------------------------

struct HandlerEntry {
  GUID clsid;
  std::string name;
  std::string extensions;
  bool canUpdate = false;
  // 处理器注册标志（NArcInfoFlags）。当前只关心 kByExtOnlyOpen ——
  // Base64 / IHex 这类「任何文本都像」的处理器靠它限定只在扩展名匹配时才启用。
  // 不看这个标志的话，纯文本会被 Base64 处理器认领（官方 7zz 不会），
  // 打开 .txt 也会显示成一个只有 [Content] 一条的「Base64 归档」。
  uint32_t flags = 0;
  // 非空表示这是外部链入的编解码器（lz4 / brotli / zstd），走我们自己的处理器
  // 而非上游注册表。zstd 上游已有解码器，故不入 Open 候选（避免重复认领），
  // 只通过 FindExternalCodec 用于创建。
  const ExternalCodec *extCodec = nullptr;
};

static bool GetHandlerClsid(UInt32 i, GUID &g) {
  NCOM::CPropVariant prop;
  if (GetHandlerProperty2(i, NArchive::NHandlerPropID::kClassID, &prop) != S_OK) return false;
  if (prop.vt != VT_BSTR || !prop.bstrVal) return false;
  if (SysStringByteLen(prop.bstrVal) != sizeof(GUID)) return false;
  memcpy(&g, prop.bstrVal, sizeof(GUID));
  return true;
}

static std::string GetHandlerStringProp(UInt32 i, PROPID propID) {
  NCOM::CPropVariant prop;
  if (GetHandlerProperty2(i, propID, &prop) != S_OK) return std::string();
  if (prop.vt == VT_BSTR && prop.bstrVal) return ToUtf8(prop.bstrVal);
  return std::string();
}

static void EnumerateHandlers(std::vector<HandlerEntry> &out) {
  UInt32 num = 0;
  if (GetNumberOfFormats(&num) != S_OK) return;
  for (UInt32 i = 0; i < num; i++) {
    HandlerEntry e;
    if (!GetHandlerClsid(i, e.clsid)) continue;
    e.name = GetHandlerStringProp(i, NArchive::NHandlerPropID::kName);
    e.extensions = GetHandlerStringProp(i, NArchive::NHandlerPropID::kExtension);
    NCOM::CPropVariant prop;
    if (GetHandlerProperty2(i, NArchive::NHandlerPropID::kUpdate, &prop) == S_OK &&
        prop.vt == VT_BOOL)
      e.canUpdate = (prop.boolVal != VARIANT_FALSE);
    NCOM::CPropVariant flagsProp;
    if (GetHandlerProperty2(i, NArchive::NHandlerPropID::kFlags, &flagsProp) == S_OK &&
        flagsProp.vt == VT_UI4)
      e.flags = flagsProp.ulVal;
    out.push_back(e);
  }

  // 注入外部链入的编解码器（lz4 / brotli / lzip / snappy）。它们不在上游注册表
  // 里，必须显式登记，否则 Open 路径不会尝试它们。zstd 上游已有解码器，这里不
  // 重复注入；它只通过 FindExternalCodec 用于「创建」（上游的 zstd 处理器没有
  // IOutArchive）。
  const std::vector<ExternalCodec> &exts = GetExternalCodecs();
  for (size_t k = 0; k < exts.size(); k++) {
    const ExternalCodec &c = exts[k];
    if (!c.canDecode) continue;
    if (strcmp(c.name, "zstd") == 0) continue;  // 上游已能解，避免重复认领
    HandlerEntry e;
    e.extCodec = &exts[k];
    e.name = c.name;
    e.extensions = c.extensions;
    e.canUpdate = c.canEncode;
    // byExtOnly（无魔数）的编解码器只能按扩展名认领；有魔数的（lz4 / lzip）
    // 靠内容探测，扩展名不是必要条件。
    if (c.byExtOnly) e.flags = NArcInfoFlags::kByExtOnlyOpen;
    out.push_back(e);
  }
}

static bool ExtensionMatches(const std::string &extList, const std::string &lowerName) {
  if (extList.empty()) return false;
  std::string cur;
  for (size_t i = 0; i <= extList.size(); i++) {
    const char c = (i < extList.size()) ? extList[i] : ' ';
    if (c == ' ' || c == '.') {
      if (!cur.empty()) {
        if (lowerName.size() > cur.size() &&
            lowerName.compare(lowerName.size() - cur.size(), cur.size(), cur) == 0 &&
            lowerName[lowerName.size() - cur.size() - 1] == '.')
          return true;
        cur.clear();
      }
    } else {
      cur += (char)tolower((unsigned char)c);
    }
  }
  return false;
}

// 候选处理器排序：先按扩展名命中，再把常见容器提前，减少无效尝试。
// 第一层与级联的内层共用这一份逻辑 —— 内层用子条目的名字当路径提示，
// 例如 "s.tar" 会把 tar 处理器排在前面。
static std::vector<HandlerEntry> OrderHandlersForPath(const std::vector<HandlerEntry> &handlers,
                                                      const std::string &pathHint) {
  std::string lower = pathHint;
  for (size_t i = 0; i < lower.size(); i++)
    lower[i] = (char)tolower((unsigned char)lower[i]);

  std::vector<HandlerEntry> ordered;
  for (size_t i = 0; i < handlers.size(); i++) {
    const bool em = ExtensionMatches(handlers[i].extensions, lower);
    if (!em) continue;
    ordered.push_back(handlers[i]);
  }
  for (size_t i = 0; i < handlers.size(); i++) {
    const bool extMatch = ExtensionMatches(handlers[i].extensions, lower);
    if (extMatch) continue;
    // kByExtOnlyOpen：处理器自己声明「只在扩展名匹配时才该被调用」。Base64 /
    // IHex 这类「什么文本都像」的处理器靠它兜底 —— 忽略它就会把任意纯文本
    // 认领成「Base64 归档」，而官方 7zz 在同样输入上是直接失败的。
    if (handlers[i].flags & NArcInfoFlags::kByExtOnlyOpen) continue;
    ordered.push_back(handlers[i]);
  }

  const char *preferred[] = {"7z", "zip", "tar", "gzip", "bzip2", "xz", NULL};
  std::vector<HandlerEntry> finalOrder;
  for (int p = 0; preferred[p]; p++)
    for (size_t i = 0; i < ordered.size(); i++)
      if (ordered[i].name == preferred[p]) finalOrder.push_back(ordered[i]);
  for (size_t i = 0; i < ordered.size(); i++) {
    bool seen = false;
    for (size_t j = 0; j < finalOrder.size(); j++) {
      // 外部编解码器不在上游注册表里，HandlerEntry.clsid 是未初始化的占位值，
      // 不能用它和上游处理器做 memcmp —— 栈上垃圾字节可能恰好等于某个上游
      // 格式（如 gzip）的 CLSID，从而被误判成「重复」而丢弃。
      // 规则：只要比较双方有一方是外部处理器，就改用 extCodec 指针判重；
      // 两个外部处理器只有同一指针才算重复，外部与上游永远不同、直接放行。
      if (ordered[i].extCodec || finalOrder[j].extCodec) {
        if (ordered[i].extCodec && finalOrder[j].extCodec &&
            ordered[i].extCodec == finalOrder[j].extCodec) {
          seen = true;
          break;
        }
        continue;
      }
      if (memcmp(&finalOrder[j].clsid, &ordered[i].clsid, sizeof(GUID)) == 0) {
        seen = true;
        break;
      }
    }
    if (!seen) finalOrder.push_back(ordered[i]);
  }
  return finalOrder;
}

// 一层归档的输入来源：要么是磁盘上的文件（第一层），要么是外层归档里某个
// 条目的流（级联的内层）。每次 Create 都返回一个新打开、位置在 0 的流 ——
// 沿用原实现「每个候选格式重新打开一次输入流」的做法，避免依赖 Seek 复位语义。
class CLevelStreamSource {
public:
  explicit CLevelStreamSource(const std::string *path) : _path(path) {}
  CLevelStreamSource(IInArchiveGetStream *getStream, UInt32 index)
      : _getStream(getStream), _index(index) {}

  bool Create(CMyComPtr<IInStream> &out) const {
    if (_path) {
      CInFileStream *spec = new CInFileStream;
      CMyComPtr<IInStream> stream(spec);
      if (!spec->Open(ToFString(*_path))) return false;
      out = stream;
      return true;
    }
    if (!_getStream) return false;
    CMyComPtr<ISequentialInStream> seq;
    if (_getStream->GetStream(_index, &seq) != S_OK || !seq) return false;
    CMyComPtr<IInStream> stream;
    if (seq.QueryInterface(IID_IInStream, &stream) != S_OK || !stream) return false;
    out = stream;
    return true;
  }

private:
  const std::string *_path = NULL;
  CMyComPtr<IInArchiveGetStream> _getStream;
  UInt32 _index = 0;
};

// 在给定来源上依次尝试候选处理器。成功时返回该层的归档对象，并把「本层实际
// 使用的流」「本层的格式名」「本层是否索要过密码」一并交回 —— 级联时这三样
// 都必须由调用方持有，否则内层的流会被提前释放。
//
// usedStreamOut 用 IInStream** 而不是 CMyComPtr* ：CMyComPtr 重载了 operator&
// 直接返回内部指针的地址（见 Common/MyCom.h），写成 CMyComPtr* 反而接不上。
// 成功时所有权随之转移（Detach），调用方接住即可。
//
// streamUnavailable 用于区分「来源本身打不开」和「格式都不匹配」：前者是硬
// 失败（第一层就是文件打不开），后者只是这一层不是归档。
static IInArchive *TryHandlersOnStream(const std::vector<HandlerEntry> &candidates,
                                       const std::string &pathHint,
                                       const CLevelStreamSource &src, Callback *cb,
                                       IInStream **usedStreamOut,
                                       std::string *formatNameOut, bool *attemptPwOut,
                                       bool &sawPasswordSupplied, bool &sawNeedPassword,
                                       HRESULT &lastHR, bool *streamUnavailable) {
  if (streamUnavailable) *streamUnavailable = false;
  for (size_t h = 0; h < candidates.size(); h++) {
    if (cb && cb->IsCanceled()) return NULL;

    CMyComPtr<IInStream> stream;
    if (!src.Create(stream)) {
      if (streamUnavailable) *streamUnavailable = true;
      return NULL;
    }

    CMyComPtr<IInArchive> arch;
    if (candidates[h].extCodec) {
      // 外部链入的编解码器不在上游注册表里，必须走我们自己的处理器。
      arch = CreateExternalInHandler(candidates[h].extCodec);
      if (!arch) continue;
      // 单流容器里不存文件名，条目的名字只能由路径推导，必须赶在 GetProperty
      // 之前告诉处理器。
      Z7ExternalHandlerSetPath(arch, pathHint);
    } else if (CreateObject(&candidates[h].clsid, &IID_IInArchive, (void **)&arch) != S_OK ||
               !arch) {
      continue;
    }

    COpenCallback *openCbSpec = new COpenCallback;
    CMyComPtr<IArchiveOpenCallback> openCb(openCbSpec);
    openCbSpec->cb = cb;

    const UInt64 scanSize = (UInt64)1 << 23;
    const HRESULT hr = arch->Open(stream, &scanSize, openCb);
    if (openCbSpec->passwordSupplied) sawPasswordSupplied = true;

    if (hr == S_OK) {
      if (usedStreamOut) *usedStreamOut = stream.Detach();
      if (attemptPwOut) *attemptPwOut = openCbSpec->passwordSupplied;
      if (formatNameOut) {
        // 用处理器的注册名，与 CLI 的 "Type = gzip" 完全同源（实测逐项一致：
        // gzip / xz / zstd / Iso / wim / Dmg / APFS …）。
        //
        // 不要拿归档属性 kpidName 当格式名：那是处理器自报的名字，有些格式给的
        // 是内部名 —— WIM 会返回 "E0C318FD.wim"、gzip 会把原始文件名当名字 ——
        // 于是徽标会显示成文件名而不是格式。kpidType 也不能用：这些处理器在
        // 被直接查询时并不返回它（OpenArchive.cpp 里的 Type 取自 CArc::ArcType，
        // 不是归档属性）。故只把两者当兜底。
        if (!candidates[h].name.empty()) {
          *formatNameOut = candidates[h].name;
        } else {
          NCOM::CPropVariant typeProp;
          NCOM::CPropVariant nameProp;
          if (arch->GetArchiveProperty(kpidType, &typeProp) == S_OK &&
              typeProp.vt == VT_BSTR && typeProp.bstrVal)
            *formatNameOut = ToUtf8(typeProp.bstrVal);
          else if (arch->GetArchiveProperty(kpidName, &nameProp) == S_OK &&
                   nameProp.vt == VT_BSTR && nameProp.bstrVal)
            *formatNameOut = ToUtf8(nameProp.bstrVal);
          else
            *formatNameOut = "?";
        }
      }
      return arch.Detach();
    }

    if (hr == E_ABORT) sawNeedPassword = true;
    lastHR = hr;
  }
  return NULL;
}

// 级联层数上限。上游用的是 kpidMainSubfile 链，理论上有限；设一个硬上限既
// 防畸形归档构造出无限链，也让失败路径可预期。
static const int kMaxNestingDepth = 10;

// 沿 kpidMainSubfile 链继续往里开层，直到某一层不再声明它、或内层不是归档。
// 供 Archive::Open 与 Archive::OpenNestedItem 共用。
//
// 上游的取舍要如实说明：真正会声明 kpidMainSubfile 的只有磁盘映像与容器类
// 处理器（MBR / GPT / Dmg / APM / VHD(X) / VMDK / VDI / QCOW / Split /
// Sparse / LVM / RPM / XAR / COM / PE / AR / LP / AVB）。压缩层那几个
// （gzip / bzip2 / zstd）根本不声明，xz 那边上游甚至把赋值注释掉了
// （"debug only, comment it"）—— 所以 .tar.gz / .tar.xz / .tar.zst 在官方
// 7zz 上同样要解两次：实测 `7zz x s.tar.gz` 只得到 s.tar。想一步进到 tar 层
// 靠的是界面上的「进入内层归档」，不是这里。这段照搬上游语义，不额外发明。
static void ExtendChain(std::vector<CMyComPtr<IInArchive>> &chainArchives,
                        std::vector<CMyComPtr<IInStream>> &chainStreams,
                        std::vector<std::string> &chainTypes,
                        const std::vector<HandlerEntry> &handlers, Callback *cb,
                        bool &sawPasswordSupplied, bool &sawNeedPassword, HRESULT &lastHR) {
  for (int depth = 0; depth < kMaxNestingDepth; depth++) {
    IInArchive *cur = chainArchives.back();
    if (!cur) break;

    NCOM::CPropVariant mainProp;
    if (cur->GetArchiveProperty(kpidMainSubfile, &mainProp) != S_OK || mainProp.vt != VT_UI4)
      break;
    const UInt32 mainIndex = mainProp.ulVal;

    UInt32 numItems = 0;
    if (cur->GetNumberOfItems(&numItems) != S_OK || mainIndex >= numItems) break;

    CMyComPtr<IInArchiveGetStream> getStream;
    if (cur->QueryInterface(IID_IInArchiveGetStream, (void **)&getStream) != S_OK || !getStream)
      break;

    std::string subPath;
    {
      NCOM::CPropVariant pathProp;
      if (cur->GetProperty(mainIndex, kpidPath, &pathProp) == S_OK &&
          pathProp.vt == VT_BSTR && pathProp.bstrVal)
        subPath = ToUtf8(pathProp.bstrVal);
    }
    if (cb)
      cb->OnLog(LogLevel::Info,
                "进入内层归档：" + (subPath.empty() ? std::string("[流]") : subPath));

    std::vector<HandlerEntry> subOrder = OrderHandlersForPath(handlers, subPath);
    CLevelStreamSource subSrc(getStream, mainIndex);
    CMyComPtr<IInStream> subStream;
    std::string subFmt;
    bool subPw = false;
    bool subUnavailable = false;
    CMyComPtr<IInArchive> next;
    next.Attach(TryHandlersOnStream(subOrder, subPath, subSrc, cb, &subStream, &subFmt,
                                    &subPw, sawPasswordSupplied, sawNeedPassword,
                                    lastHR, &subUnavailable));
    if (!next) break;   // 内层不是归档：保留当前层

    chainArchives.push_back(next);
    chainStreams.push_back(subStream);
    chainTypes.push_back(subFmt);
    if (subPw) sawPasswordSupplied = true;
  }
}

// ---------------------------------------------------------------------------
// Archive
// ---------------------------------------------------------------------------

struct Archive::Impl {
  CMyComPtr<IInArchive> archive;
  CMyComPtr<IInStream> stream;
  std::string path;
  std::string formatName;
  std::atomic<bool> canceled;
  UInt32 numItems = 0;
  ExtractStats stats;

  // 容器级联：由外到内每一层的归档与它实际使用的流。必须整条链一起持有 ——
  // 内层归档的流是外层归档提供的子流，外层一旦析构，内层的流就成了悬垂引用。
  // 单层文件时这两个数组各有一个元素。
  std::vector<CMyComPtr<IInArchive>> chainArchives;
  std::vector<CMyComPtr<IInStream>> chainStreams;

  // 每一层的格式名（最外层在前）。单层时只有一个元素，等于 formatName。
  // 界面可用它显示 "Dmg ▸ APFS" 之类的层级信息。
  std::vector<std::string> chainTypes;

  // 经「进入内层归档」打开时，记录进入的是哪个条目（用于面包屑）。
  std::string nestedLabel;

  // 由 OpenNestedItem 打开时，持有父归档：内层的流最终读的是父归档持有的
  // 文件流，父级必须活到内层关闭为止。由本对象负责释放。
  Archive *parentKeepAlive = NULL;

  // 走「解到临时文件再进入」时，临时的内层归档路径；析构时删除。
  std::string tempFilePath;

  // 打开时是否被 handler 索要过密码。
  // 对 7z 而言这等价于"文件名/头部已加密"（-mhe）：仅数据加密的归档打开时不需要密码。
  // 删除走重建路径，必须据此还原 -mhe，否则会悄悄削弱归档的机密性。
  bool headerEncrypted = false;

  Impl() : canceled(false) {}
};

Archive::Archive() : m_impl(new Impl) {}

Archive::~Archive() {
  if (m_impl) {
    // 由内到外逐个关闭；最内层在 chainStreams.back() 上也由 chainArchives 持有
    for (size_t i = m_impl->chainArchives.size(); i > 0; i--)
      if (m_impl->chainArchives[i - 1]) m_impl->chainArchives[i - 1]->Close();
    if (m_impl->archive) m_impl->archive->Close();
    // 父归档必须在所有内层流释放之后再销毁
    m_impl->chainArchives.clear();
    m_impl->chainStreams.clear();
    if (m_impl->parentKeepAlive) {
      delete m_impl->parentKeepAlive;
      m_impl->parentKeepAlive = NULL;
    }
    // 临时解出的内层归档最后删（上面的 Close 可能还在读它）
    if (!m_impl->tempFilePath.empty()) unlink(m_impl->tempFilePath.c_str());
    delete m_impl;
    m_impl = NULL;
  }
}

const std::vector<std::string> &Archive::chainTypes() const { return m_impl->chainTypes; }
const std::string &Archive::nestedLabel() const { return m_impl->nestedLabel; }

const std::string &Archive::formatName() const { return m_impl->formatName; }
const std::string &Archive::archivePath() const { return m_impl->path; }
bool Archive::isHeaderEncrypted() const { return m_impl->headerEncrypted; }
uint32_t Archive::itemCount() const { return m_impl->numItems; }
void Archive::cancel() { m_impl->canceled = true; }
const Archive::ExtractStats &Archive::lastExtractStats() const { return m_impl->stats; }

Archive *Archive::Open(const std::string &utf8Path, Callback *cb, std::string &error) {
  error.clear();

  std::vector<HandlerEntry> handlers;
  EnumerateHandlers(handlers);
  if (handlers.empty()) {
    error = "无法从引擎枚举归档格式";
    return NULL;
  }

  // 候选顺序：第一层用文件路径当提示
  std::vector<HandlerEntry> ordered = OrderHandlersForPath(handlers, utf8Path);

  HRESULT lastHR = S_OK;
  bool sawNeedPassword = false;
  bool sawPasswordSupplied = false;

  std::vector<CMyComPtr<IInArchive>> chainArchives;
  std::vector<CMyComPtr<IInStream>> chainStreams;
  std::vector<std::string> chainTypes;

  // ---- 第一层：磁盘文件 ----------------------------------------------------
  std::string fmtName;
  CMyComPtr<IInStream> usedStream;
  bool level1Pw = false;
  bool fileUnavailable = false;
  {
    CLevelStreamSource src(&utf8Path);
    CMyComPtr<IInArchive> first;
    // 必须用 Attach 而不是「构造函数 + 裸指针」：TryHandlersOnStream 交回的是
    // 已转移所有权的指针，而 CMyComPtr(T*) 会再 AddRef 一次，那样会白白漏一个引用。
    first.Attach(TryHandlersOnStream(ordered, utf8Path, src, cb, &usedStream, &fmtName,
                                     &level1Pw, sawPasswordSupplied,
                                     sawNeedPassword, lastHR, &fileUnavailable));
    if (!first) {
      if (cb && cb->IsCanceled()) {
        error = "已取消";
        return NULL;
      }
      if (fileUnavailable) {
        error = "无法打开文件：" + utf8Path;
        return NULL;
      }
      // 失败原因分类（顺序即优先级）：
      //   1. 已提供密码仍打不开 —— 密码错误是首要嫌疑（头加密归档尤其如此）
      //   2. 完全没提供密码且 handler 索要过 —— 明确提示需要密码
      //   3. 其余 —— 格式不识别或文件损坏
      if (sawPasswordSupplied) {
        const char *t = HRReason(lastHR);
        error = "密码错误或归档已损坏";
        error += t ? (std::string("（") + t + "）") : ("（" + HRText(lastHR) + "）");
      } else if (sawNeedPassword) {
        error = "归档已加密，需要正确密码";
      } else {
        const char *t = HRReason(lastHR);
        error = "无法识别归档格式或文件已损坏";
        error += t ? (std::string("（") + t + "）") : ("（" + HRText(lastHR) + "）");
      }
      return NULL;
    }
    chainArchives.push_back(first);
    chainStreams.push_back(usedStream);
    chainTypes.push_back(fmtName);
  }

  // ---- 容器级联 ------------------------------------------------------------
  ExtendChain(chainArchives, chainStreams, chainTypes, handlers, cb,
              sawPasswordSupplied, sawNeedPassword, lastHR);

  Archive *a = new Archive;
  a->m_impl->archive = chainArchives.back();
  a->m_impl->stream = chainStreams.back();
  a->m_impl->chainArchives.swap(chainArchives);
  a->m_impl->chainStreams.swap(chainStreams);
  a->m_impl->path = utf8Path;

  // formatName 取**最外层**的格式名：单层文件就是原来那个值；级联时是用户
  // 实际打开的那个容器（例如 Dmg），里面是什么由 chainTypes 表达，界面据此
  // 显示 "Dmg ▸ APFS" 这样的层级。
  a->m_impl->formatName = chainTypes.empty() ? std::string("?") : chainTypes.front();
  a->m_impl->chainTypes = chainTypes;

  // 只采信第一层那次成功尝试的密码索取标志（与各处理的语义不变）
  a->m_impl->headerEncrypted = level1Pw;
  a->m_impl->archive->GetNumberOfItems(&a->m_impl->numItems);
  return a;
}

// 「进入内层归档」走临时文件时的体积上限。单流压缩（gzip/bzip2/zstd）没有
// 按条目取流的接口，只能先落盘；给一个上限，避免 4 GB 的 tar 被无声解开占满磁盘。
static const UInt64 kMaxNestedTempBytes = (UInt64)8 << 30;   // 8 GiB

// 生成一个带合适后缀的临时文件名（后缀用于让内层格式探测有线索）。
// 失败返回空串。
static std::string MakeNestedTempPath(const std::string &itemName) {
  std::string suffix;
  const size_t dot = itemName.find_last_of('.');
  if (dot != std::string::npos && dot + 1 < itemName.size() && itemName.size() - dot <= 12) {
    suffix = itemName.substr(dot);   // 含点
    for (size_t i = 0; i < suffix.size(); i++) {
      const char c = suffix[i];
      if (!isalnum((unsigned char)c) && c != '.') suffix[i] = '_';
    }
  }
  const char *tmp = getenv("TMPDIR");
  std::string dir = (tmp && *tmp) ? tmp : "/tmp";
  while (dir.size() > 1 && dir[dir.size() - 1] == '/') dir.erase(dir.size() - 1);

  std::string tmpl = dir + "/7z-nested-XXXXXX" + suffix;
  std::vector<char> buf(tmpl.begin(), tmpl.end());
  buf.push_back('\0');
  const int fd = mkstemps(buf.data(), (int)suffix.size());
  if (fd < 0) return std::string();
  close(fd);
  return std::string(buf.data());
}

Archive *Archive::OpenNestedItem(Archive *outer, uint32_t index, Callback *cb,
                                 std::string &error) {
  error.clear();
  if (!outer || !outer->m_impl || !outer->m_impl->archive) {
    error = "内部错误：父归档未打开";
    return NULL;
  }

  IInArchive *cur = outer->m_impl->archive;
  UInt32 numItems = 0;
  if (cur->GetNumberOfItems(&numItems) != S_OK || index >= numItems) {
    error = "条目不存在";
    return NULL;
  }

  std::string subPath;
  {
    NCOM::CPropVariant pathProp;
    if (cur->GetProperty(index, kpidPath, &pathProp) == S_OK &&
        pathProp.vt == VT_BSTR && pathProp.bstrVal)
      subPath = ToUtf8(pathProp.bstrVal);
  }
  if (subPath.empty()) {
    // 单流压缩的条目常常没有名字（xz 就不给 kpidPath），退而用格式名当标签
    NCOM::CPropVariant nameProp;
    if (cur->GetArchiveProperty(kpidName, &nameProp) == S_OK &&
        nameProp.vt == VT_BSTR && nameProp.bstrVal)
      subPath = ToUtf8(nameProp.bstrVal);
  }
  if (subPath.empty()) subPath = "[Content]";

  std::vector<HandlerEntry> handlers;
  EnumerateHandlers(handlers);
  if (handlers.empty()) {
    error = "无法从引擎枚举归档格式";
    return NULL;
  }

  std::vector<HandlerEntry> ordered = OrderHandlersForPath(handlers, subPath);

  // 两条路：处理器提供按条目取流就直接读；不提供就先把条目解到临时文件。
  //
  // 需要退路的是单流压缩处理器 —— gzip / bzip2 / zstd / lzma / Z 都只声明了
  // IInArchive + IArchiveOpenSeq + ISetProperties，没有 IInArchiveGetStream
  // （见 Archive/GzHandler.cpp 的 Z7_CLASS_IMP_CHandler_IInArchive_3、
  // Archive/ZstdHandler.cpp 的 Z7_COM_QI_BEGIN2）。上游 7zz 因此进不去
  // .tar.gz / .tar.zst，只能解两次；落盘这条退路是上游没有的。
  std::string tmpPath;
  bool usedTempFile = false;
  CMyComPtr<IInArchiveGetStream> getStream;
  if (cur->QueryInterface(IID_IInArchiveGetStream, (void **)&getStream) != S_OK || !getStream) {
    if (numItems != 1) {
      error = "该归档不支持按条目取数据流，无法进入内层";
      return NULL;
    }
    ItemInfo probe;
    if (!outer->getItem(index, probe)) {
      error = "无法读取该条目的信息";
      return NULL;
    }
    if (probe.size > kMaxNestedTempBytes) {
      error = "内层体积超过 8 GiB，请先用「解压到…」展开后再打开";
      return NULL;
    }
    tmpPath = MakeNestedTempPath(subPath);
    if (tmpPath.empty()) {
      error = "无法创建临时文件";
      return NULL;
    }
    if (!outer->extractToFile(index, tmpPath, cb, error)) {
      unlink(tmpPath.c_str());
      if (error.empty()) error = "解出内层归档时失败";
      return NULL;
    }
    usedTempFile = true;
    if (cb) cb->OnLog(LogLevel::Info, "已解出内层以便继续进入：" + tmpPath);
  }

  HRESULT lastHR = S_OK;
  bool sawPasswordSupplied = false;
  bool sawNeedPassword = false;
  CMyComPtr<IInStream> usedStream;
  std::string fmt;
  bool attemptPw = false;
  bool unavailable = false;
  CMyComPtr<IInArchive> opened;
  if (usedTempFile) {
    CLevelStreamSource src(&tmpPath);
    opened.Attach(TryHandlersOnStream(ordered, subPath, src, cb, &usedStream, &fmt, &attemptPw,
                                      sawPasswordSupplied, sawNeedPassword, lastHR, &unavailable));
  } else {
    CLevelStreamSource src(getStream, index);
    opened.Attach(TryHandlersOnStream(ordered, subPath, src, cb, &usedStream, &fmt, &attemptPw,
                                      sawPasswordSupplied, sawNeedPassword, lastHR, &unavailable));
  }
  if (!opened) {
    if (!tmpPath.empty()) unlink(tmpPath.c_str());
    if (cb && cb->IsCanceled())
      error = "已取消";
    else if (unavailable)
      error = "无法读取该条目的数据流";
    else if (sawPasswordSupplied)
      error = "内层归档的密码错误或已损坏";
    else if (sawNeedPassword)
      error = "内层归档已加密，需要密码";
    else
      error = "该条目不是引擎能识别的归档";
    return NULL;
  }

  std::vector<CMyComPtr<IInArchive>> chainArchives;
  std::vector<CMyComPtr<IInStream>> chainStreams;
  std::vector<std::string> chainTypes;
  chainArchives.push_back(opened);
  chainStreams.push_back(usedStream);
  chainTypes.push_back(fmt);

  // 内层如果还能继续级联（例如进了 dmg 里的分区表），同样走一遍
  ExtendChain(chainArchives, chainStreams, chainTypes, handlers, cb,
              sawPasswordSupplied, sawNeedPassword, lastHR);

  Archive *a = new Archive;
  a->m_impl->archive = chainArchives.back();
  a->m_impl->stream = chainStreams.back();
  a->m_impl->chainArchives.swap(chainArchives);
  a->m_impl->chainStreams.swap(chainStreams);
  // 路径仍是最外层文件：钥匙串按它存取密码，窗口标题也仍指同一个文件
  a->m_impl->path = outer->m_impl->path;
  a->m_impl->formatName = chainTypes.front();
  a->m_impl->chainTypes = outer->m_impl->chainTypes;
  a->m_impl->chainTypes.insert(a->m_impl->chainTypes.end(),
                               chainTypes.begin(), chainTypes.end());
  a->m_impl->nestedLabel = subPath;
  a->m_impl->headerEncrypted = outer->m_impl->headerEncrypted || attemptPw;
  a->m_impl->tempFilePath = tmpPath;   // 空串表示走的取流路径
  a->m_impl->parentKeepAlive = outer;  // 父级的生命周期交给本对象
  a->m_impl->archive->GetNumberOfItems(&a->m_impl->numItems);
  return a;
}

bool Archive::getItem(uint32_t index, ItemInfo &out) const {
  if (!m_impl->archive || index >= m_impl->numItems) return false;
  IInArchive *a = m_impl->archive;
  NCOM::CPropVariant prop;

  out = ItemInfo();
  out.index = index;

  if (a->GetProperty(index, kpidPath, &prop) == S_OK && prop.vt == VT_BSTR && prop.bstrVal)
    out.path = ToUtf8(prop.bstrVal);
  if (out.path.empty()) out.path = "[Content]";
  for (size_t i = 0; i < out.path.size(); i++)
    if (out.path[i] == '\\') out.path[i] = '/';

  {
    const size_t slash = out.path.find_last_of('/');
    if (slash == std::string::npos) {
      out.name = out.path;
      out.parent.clear();
      out.depth = 0;
    } else {
      out.name = out.path.substr(slash + 1);
      out.parent = out.path.substr(0, slash);
      int d = 1;
      for (size_t i = 0; i < out.parent.size(); i++)
        if (out.parent[i] == '/') d++;
      out.depth = d;
    }
  }

  if (a->GetProperty(index, kpidIsDir, &prop) == S_OK && prop.vt == VT_BOOL)
    out.isDir = (prop.boolVal != VARIANT_FALSE);
  if (a->GetProperty(index, kpidIsAnti, &prop) == S_OK && prop.vt == VT_BOOL)
    out.isAnti = (prop.boolVal != VARIANT_FALSE);

  // 符号链接：优先 kpidSymLink，其次 kpidAttrib 高 16 位的 POSIX S_IFLNK
  if (a->GetProperty(index, kpidSymLink, &prop) == S_OK && prop.vt == VT_BSTR &&
      prop.bstrVal) {
    out.linkTarget = ToUtf8(prop.bstrVal);
    out.isSymLink = !out.linkTarget.empty();
  }

  if (a->GetProperty(index, kpidSize, &prop) == S_OK) {
    UInt64 v = 0;
    if (ConvertPropVariantToUInt64(prop, v)) {
      out.size = v;
      out.hasSize = true;
    }
  }
  if (a->GetProperty(index, kpidPackSize, &prop) == S_OK) {
    UInt64 v = 0;
    if (ConvertPropVariantToUInt64(prop, v)) {
      out.packSize = v;
      out.hasPackSize = true;
    }
  }
  if (a->GetProperty(index, kpidMTime, &prop) == S_OK && prop.vt == VT_FILETIME) {
    CFiTime ts;
    if (FILETIME_To_timespec(prop.filetime, ts)) {
      out.mtime = (int64_t)ts.tv_sec;
      out.hasMTime = true;
    }
  }
  if (a->GetProperty(index, kpidCTime, &prop) == S_OK && prop.vt == VT_FILETIME) {
    CFiTime ts;
    if (FILETIME_To_timespec(prop.filetime, ts)) {
      out.ctime = (int64_t)ts.tv_sec;
      out.hasCTime = true;
    }
  }
  if (a->GetProperty(index, kpidATime, &prop) == S_OK && prop.vt == VT_FILETIME) {
    CFiTime ts;
    if (FILETIME_To_timespec(prop.filetime, ts)) {
      out.atime = (int64_t)ts.tv_sec;
      out.hasATime = true;
    }
  }
  if (a->GetProperty(index, kpidAttrib, &prop) == S_OK && prop.vt == VT_UI4) {
    out.attrib = prop.ulVal;
    out.hasAttrib = true;
    if (MY_LIN_S_ISLNK(out.attrib >> 16)) out.isSymLink = true;
  }
  if (a->GetProperty(index, kpidPosixAttrib, &prop) == S_OK && prop.vt == VT_UI4) {
    out.posixAttrib = prop.ulVal;
    out.hasPosixAttrib = true;
  }
  if (a->GetProperty(index, kpidCRC, &prop) == S_OK && prop.vt == VT_UI4) {
    out.crc = prop.ulVal;
    out.hasCRC = true;
  }
  if (a->GetProperty(index, kpidEncrypted, &prop) == S_OK && prop.vt == VT_BOOL)
    out.encrypted = (prop.boolVal != VARIANT_FALSE);
  if (a->GetProperty(index, kpidMethod, &prop) == S_OK && prop.vt == VT_BSTR && prop.bstrVal)
    out.method = ToUtf8(prop.bstrVal);
  if (a->GetProperty(index, kpidExtension, &prop) == S_OK && prop.vt == VT_BSTR &&
      prop.bstrVal)
    out.extension = ToUtf8(prop.bstrVal);
  return true;
}

bool Archive::getAllItems(std::vector<ItemInfo> &out) const {
  out.clear();
  out.reserve(m_impl->numItems);
  for (UInt32 i = 0; i < m_impl->numItems; i++) {
    ItemInfo info;
    if (!getItem(i, info)) return false;
    // 排除 macOS/Windows 系统元数据垃圾项（__MACOSX / ._xxx / .DS_Store 等）
    if (IsMacJunkPath(info.path)) continue;
    out.push_back(info);
  }
  return true;
}

bool Archive::extract(const std::vector<uint32_t> &indices, const std::string &utf8DestDir,
                      bool testMode, ClashPolicy clash, Callback *cb, std::string &error,
                      bool atomicFiles, bool createSymLinks) {
  error.clear();
  m_impl->canceled = false;
  m_impl->stats = ExtractStats();
  if (!m_impl->archive) {
    error = "归档未打开";
    return false;
  }
  if (!testMode && !EnsureDir(utf8DestDir)) {
    error = "无法创建目标目录：" + utf8DestDir;
    return false;
  }

  // 压缩炸弹上限：max(归档文件大小 × 40, 8 GiB)，并按声明总量预检
  UInt64 bombLimit = (UInt64)8 << 30;
  {
    struct stat st;
    if (stat(m_impl->path.c_str(), &st) == 0 && st.st_size > 0) {
      const UInt64 scaled = (UInt64)st.st_size * 40;
      if (scaled > bombLimit) bombLimit = scaled;
    }
    UInt64 declared = 0;
    const UInt32 upto = indices.empty() ? m_impl->numItems : (UInt32)indices.size();
    for (UInt32 k = 0; k < upto; k++) {
      ItemInfo it;
      const UInt32 idx = indices.empty() ? k : indices[k];
      if (getItem(idx, it) && it.hasSize && !it.isDir) declared += it.size;
    }
    if (declared > bombLimit) {
      char buf[64];
      sprintf(buf, "%llu", (unsigned long long)declared);
      error = std::string("解压后总量（") + buf + " 字节）超过安全上限，已拒绝";
      return false;
    }
  }

  CExtractCallback *spec = new CExtractCallback;
  CMyComPtr<IArchiveExtractCallback> holder(spec);
  spec->Init(m_impl->archive, utf8DestDir, testMode, clash);
  spec->SetPolicy(atomicFiles, createSymLinks);
  spec->cb = cb;
  spec->bombLimit = bombLimit;
  spec->password = cb ? cb->GetPassword(false) : std::string();

  UInt32 count = (UInt32)(Int32)-1;
  const UInt32 *items = NULL;
  if (!indices.empty()) {
    count = (UInt32)indices.size();
    items = (const UInt32 *)&indices[0];
  }

  const HRESULT hr = m_impl->archive->Extract(items, count, testMode, holder);

  const UInt64 errors = spec->numErrors;
  const UInt64 wrongPw = spec->numWrongPassword;
  const UInt64 unsafe = spec->numUnsafe;
  const bool tripped = spec->bombTripped;

  // 统计回填，供上层 UI 展示「已拒绝 N 个不安全条目」等信息
  m_impl->stats.errors = errors;
  m_impl->stats.wrongPassword = wrongPw;
  m_impl->stats.unsafe = unsafe;
  m_impl->stats.skipped = spec->numSkipped;
  m_impl->stats.symLinks = spec->numSymLinks;
  m_impl->stats.bytes = spec->writtenBytes;

  // 密码明文不在回调对象存活期间停留（技术方案 §8.2）
  BurnString(spec->password);

  if (wrongPw > 0) {
    error = "密码错误";
    return false;
  }
  if (tripped) {
    error = "解压总量超过安全上限，已中止";
    return false;
  }
  if (hr != S_OK && hr != S_FALSE) {
    if (m_impl->canceled) {
      error = "已取消";
    } else {
      const char *t = HRReason(hr);
      error = t ? std::string(t) : ("提取失败（" + HRText(hr) + "）");
    }
    return false;
  }
  if (errors > 0) {
    char buf[64];
    sprintf(buf, "%llu", (unsigned long long)errors);
    error = std::string("有 ") + buf + " 个条目提取失败";
    return false;
  }
  if (unsafe > 0 && cb) {
    char buf[64];
    sprintf(buf, "%llu", (unsigned long long)unsafe);
    cb->OnLog(LogLevel::Warning,
              std::string("已按安全策略拒绝 ") + buf + " 个不安全条目（路径穿越 / 越界符号链接）");
  }
  return true;
}

bool Archive::extractToFile(uint32_t index, const std::string &utf8DestFile, Callback *cb,
                            std::string &error) {
  error.clear();
  if (!m_impl->archive || index >= m_impl->numItems) {
    error = "条目索引越界";
    return false;
  }

  const size_t slash = utf8DestFile.find_last_of('/');
  if (slash != std::string::npos) {
    if (!EnsureDir(utf8DestFile.substr(0, slash))) {
      error = "无法创建目标目录";
      return false;
    }
  }

  ItemInfo info;
  if (getItem(index, info) && info.isDir) {
    error = "该条目是目录";
    return false;
  }

  m_impl->canceled = false;

  CExtractCallback *spec = new CExtractCallback;
  CMyComPtr<IArchiveExtractCallback> holder(spec);
  spec->Init(m_impl->archive, std::string(), false, ClashPolicy::Overwrite);
  spec->SetExplicitDestFile(utf8DestFile);
  // 单条目提取到任意路径：不建符号链接、不写 .partial（目标是用户明确指定的文件）
  spec->SetPolicy(false, false);
  spec->cb = cb;
  spec->bombLimit = 0;
  spec->password = cb ? cb->GetPassword(false) : std::string();

  const UInt32 one = index;
  const HRESULT hr = m_impl->archive->Extract(&one, 1, false, holder);

  m_impl->stats = ExtractStats();
  m_impl->stats.errors = spec->numErrors;
  m_impl->stats.wrongPassword = spec->numWrongPassword;
  m_impl->stats.unsafe = spec->numUnsafe;
  m_impl->stats.bytes = spec->writtenBytes;
  BurnString(spec->password);

  if (spec->numWrongPassword > 0) {
    error = "密码错误";
    return false;
  }
  if (hr != S_OK) {
    const char *t = HRReason(hr);
    error = t ? std::string(t) : ("提取失败（" + HRText(hr) + "）");
    return false;
  }
  return spec->numErrors == 0;
}

bool Archive::extractToMemory(uint32_t index, std::vector<uint8_t> &out, uint64_t maxBytes,
                              bool &tooLarge, Callback *cb, std::string &error) {
  error.clear();
  tooLarge = false;
  out.clear();
  if (!m_impl->archive || index >= m_impl->numItems) {
    error = "条目索引越界";
    return false;
  }

  ItemInfo info;
  if (getItem(index, info) && info.hasSize && maxBytes != 0 && info.size > maxBytes) {
    tooLarge = true;
    return false;
  }

  m_impl->canceled = false;

  std::vector<Byte> data;
  CMemoryExtractCallback *spec = new CMemoryExtractCallback;
  CMyComPtr<IArchiveExtractCallback> holder(spec);
  spec->Init(m_impl->archive, &data, maxBytes);
  spec->cb = cb;
  spec->password = cb ? cb->GetPassword(false) : std::string();

  const UInt32 one = index;
  const HRESULT hr = m_impl->archive->Extract(&one, 1, false, holder);

  m_impl->stats = ExtractStats();
  m_impl->stats.bytes = data.size();
  BurnString(spec->password);

  if (spec->tooLarge) {
    tooLarge = true;
    return false;
  }
  if (hr != S_OK) {
    error = spec->errorText.empty() ? ("提取失败（" + HRText(hr) + "）") : spec->errorText;
    return false;
  }
  out.assign(data.begin(), data.end());
  return true;
}

// ---------------------------------------------------------------------------
// 创建归档
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 压缩参数应用（技术方案 §5.1 字段映射）
// 抽出为独立函数，使「新建归档」与「更新归档」共用同一套映射。
// ---------------------------------------------------------------------------

static bool ApplyCompressionOptions(IOutArchive *outArchive, const CompressionOptions &options,
                                    const std::string &format, std::string &error) {
  std::vector<UString> names;
  std::vector<NCOM::CPropVariant> values;
  const bool is7z = (format == "7z");
  const bool isZip = (format == "zip");

  names.push_back(UString(L"x"));
  values.push_back(NCOM::CPropVariant((UInt32)options.level));

  if (!options.method.empty()) {
    names.push_back(UString(L"0"));
    values.push_back(NCOM::CPropVariant(ToUString(options.method)));
  }
  if (options.hasDict && options.dictSize > 0) {
    names.push_back(UString(L"0d"));
    values.push_back(NCOM::CPropVariant((UInt32)options.dictSize));
  }
  if (options.hasWordLength && options.wordLength > 0) {
    names.push_back(UString(L"0lc"));
    values.push_back(NCOM::CPropVariant((UInt32)options.wordLength));
  }
  if (options.hasFastBytes && options.fastBytes > 0) {
    names.push_back(UString(L"0fb"));
    values.push_back(NCOM::CPropVariant((UInt32)options.fastBytes));
  }
  if (!options.matchFinder.empty()) {
    names.push_back(UString(L"0mf"));
    values.push_back(NCOM::CPropVariant(ToUString(options.matchFinder)));
  }
  if (options.hasThreads && options.threads > 0) {
    names.push_back(UString(L"mt"));
    values.push_back(NCOM::CPropVariant((UInt32)options.threads));
  }
  if (is7z) {
    // 固实分块优先：属性名 "s<suffix>"、值为 VT_EMPTY（7zHandlerOut.cpp）
    if (!options.solidBlock.empty()) {
      names.push_back(UString(L"s") + ToUString(options.solidBlock));
      values.push_back(NCOM::CPropVariant());
    } else if (options.hasSolid) {
      names.push_back(UString(L"s"));
      values.push_back(NCOM::CPropVariant(options.solid));
    }
    if (options.hasCompressHeader) {
      names.push_back(UString(L"hc"));
      values.push_back(NCOM::CPropVariant(options.compressHeader));
    }
    if (options.hasEncryptHeader) {
      names.push_back(UString(L"he"));
      values.push_back(NCOM::CPropVariant(options.encryptHeader));
    }
  }
  if (!options.encryptMethod.empty() && (isZip || format == "tar")) {
    names.push_back(UString(L"em"));
    values.push_back(NCOM::CPropVariant(ToUString(options.encryptMethod)));
  }

  CMyComPtr<ISetProperties> setProps;
  if (outArchive->QueryInterface(IID_ISetProperties, (void **)&setProps) != S_OK || !setProps)
    return true; // 该格式不接受属性设置，交给引擎默认值

  std::vector<const wchar_t *> namePtrs;
  std::vector<PROPVARIANT> valueArr;
  for (size_t i = 0; i < names.size(); i++) {
    namePtrs.push_back(names[i].Ptr());
    PROPVARIANT pv;
    values[i].Detach(&pv);
    valueArr.push_back(pv);
  }
  const HRESULT hr =
      setProps->SetProperties(&namePtrs[0], &valueArr[0], (UInt32)valueArr.size());
  for (size_t i = 0; i < valueArr.size(); i++) NCOM::PropVariant_Clear(&valueArr[i]);
  if (hr != S_OK) {
    error = "压缩参数被引擎拒绝（" + HRText(hr) + "）";
    return false;
  }
  return true;
}

// 计算条目在归档内的根路径（技术方案 §5.1「保留完整路径」-spf）
static UString ArchiveRootForPath(const std::string &utf8Path, const CompressionOptions &options) {
  std::string base = utf8Path;
  while (base.size() > 1 && base[base.size() - 1] == '/') base.erase(base.size() - 1);
  if (options.fullPaths) {
    // 去掉开头的 '/'，使归档内路径为相对路径（与 7zz -spf 的存储形式一致），
    // 否则条目会被本层与官方 7zz 的安全策略判为绝对路径而拒绝。
    while (!base.empty() && base[0] == '/') base.erase(0, 1);
    return ToUString(base);
  }
  const size_t slash = base.find_last_of('/');
  return ToUString(slash == std::string::npos ? base : base.substr(slash + 1));
}

// 格式别名 -> 处理器注册名（即 listFormats 输出的「名称」列，也是 7zz -t 的名字）。
// 例如 "gz"/"tgz"/"tar.gz" 都归到 gzip；组合格式的外层名也在这里归一化。
static std::string CanonicalFormatName(const std::string &format) {
  std::string f;
  for (size_t i = 0; i < format.size(); i++)
    f += (char)tolower((unsigned char)format[i]);
  if (f == "7z") return "7z";
  if (f == "zip") return "zip";
  if (f == "tar") return "tar";
  if (f == "wim" || f == "swm") return "wim";
  if (f == "gz" || f == "gzip") return "gzip";
  if (f == "bz2" || f == "bzip2") return "bzip2";
  if (f == "xz") return "xz";
  if (f == "zst" || f == "zstd") return "zstd";
  // 外部编解码器的别名。界面/命令行可能给出短写，而处理器注册名是长写
  // —— 不归一化的话 FindExternalCodec 找不到，会掉进 CLSID 查找然后报
  // 「不支持的压缩格式」，症状很难联想到是别名问题。
  if (f == "lz4") return "lz4";
  if (f == "br" || f == "brotli") return "brotli";
  if (f == "lz" || f == "lzip") return "lzip";
  if (f == "sz" || f == "snappy") return "snappy";
  return f;
}

// 组合格式（tar + 单流外层）：上游 7zz 无法一步生成 —— 多个输入时 -tgzip 直接
// E_INVALIDARG，写成 -ttar 又只产出裸 tar（名字却是 .tar.gz，会误导）。
// 这里自己分两段完成，故需要拆出外层格式名。
//
// 注意：必须拿**原始**格式串来判定，不能先过 CanonicalFormatName —— 后者会把
// "tar.gz" 折叠成 "gzip"，组合信息就丢了。
static bool IsComposedTarFormat(const std::string &formatRaw, std::string &outer) {
  std::string f;
  for (size_t i = 0; i < formatRaw.size(); i++)
    f += (char)tolower((unsigned char)formatRaw[i]);

  // 短写法：整名即 tar+外层的合写
  if (f == "tgz") { outer = "gzip"; return true; }
  if (f == "tbz2" || f == "tbz") { outer = "bzip2"; return true; }
  if (f == "txz") { outer = "xz"; return true; }
  if (f == "tzst") { outer = "zstd"; return true; }

  // 长写法：tar.<ext>。只有单流压缩层能当外层，tar.tar / tar.zip 没有意义。
  const size_t p = f.rfind('.');
  if (p == std::string::npos) return false;
  if (f.substr(0, p) != "tar") return false;
  const std::string o = f.substr(p + 1);
  if (o == "gz" || o == "gzip") { outer = "gzip"; return true; }
  if (o == "bz2" || o == "bzip2") { outer = "bzip2"; return true; }
  if (o == "xz") { outer = "xz"; return true; }
  if (o == "zst" || o == "zstd") { outer = "zstd"; return true; }
  return false;
}

// 按处理器注册名查 CLSID。走运行时枚举而不是硬编码 id 字节 —— 7-Zip 的
// 格式 CLSID 只是 {23170F69-40C1-278A-1000-000110<id>0000}，靠 id 区分，
// 抄错一个字节就会静默创建出别的东西。枚举表取自 lib7z 自己注册的元数据，
// 因此新增格式（如 wim）不需要再手抄。
static bool ClsidByHandlerName(const std::string &handlerName, GUID &out) {
  std::vector<HandlerEntry> hs;
  EnumerateHandlers(hs);
  for (size_t i = 0; i < hs.size(); i++) {
    // 跳过外部编解码器：它们的 clsid 是占位值（非上游注册表），不能拿去 CreateObject。
    // 否则 lz4 / brotli 这类没有编码器的格式会被匹配到垃圾 CLSID，创建时静默行为错乱。
    if (hs[i].extCodec) continue;
    if (hs[i].name == handlerName) {
      out = hs[i].clsid;
      return true;
    }
  }
  // 枚举不可用时退回已知 id（保证旧行为不因枚举失败而整体失效）
  if (handlerName == "7z") { out = g_CLSID_7z; return true; }
  if (handlerName == "zip") { out = g_CLSID_Zip; return true; }
  if (handlerName == "gzip") { out = g_CLSID_GZip; return true; }
  if (handlerName == "bzip2") { out = g_CLSID_BZip2; return true; }
  if (handlerName == "tar") { out = g_CLSID_Tar; return true; }
  if (handlerName == "xz") { out = g_CLSID_Xz; return true; }
  return false;
}

static bool FormatToClsid(const std::string &format, GUID &out, std::string &error) {
  const std::string name = CanonicalFormatName(format);
  if (name.empty()) {
    error = "不支持的压缩格式：" + format;
    return false;
  }
  std::string outer;
  if (IsComposedTarFormat(format, outer)) {
    error = "组合格式 " + format + " 应走两段式创建路径";
    return false;
  }
  if (!ClsidByHandlerName(name, out)) {
    error = "不支持的压缩格式：" + format;
    return false;
  }
  return true;
}

// 组合格式里内层 tar 在归档中显示的条目名。官方两步法的结果是
// "out.tar.gz" 内含 "out.tar"，这里保持一致。
static std::string InnerTarEntryName(const std::string &destUtf8) {
  const size_t s = destUtf8.find_last_of('/');
  std::string b = (s == std::string::npos) ? destUtf8 : destUtf8.substr(s + 1);
  std::string lower;
  for (size_t i = 0; i < b.size(); i++) lower += (char)tolower((unsigned char)b[i]);

  // 短后缀：.tgz / .tbz2 / .tbz / .txz / .tzst —— 整段替换成 .tar
  const char *shortExt[] = {"tgz", "tbz2", "tbz", "txz", "tzst", NULL};
  for (int i = 0; shortExt[i]; i++) {
    const std::string e = std::string(".") + shortExt[i];
    if (lower.size() > e.size() && lower.compare(lower.size() - e.size(), e.size(), e) == 0)
      return b.substr(0, b.size() - e.size()) + ".tar";
  }
  // 长后缀：.tar.gz / .tar.bz2 / .tar.xz / .tar.zst —— 去掉外层即可
  const char *longExt[] = {"gz", "bz2", "xz", "zst", NULL};
  for (int i = 0; longExt[i]; i++) {
    const std::string e = std::string(".") + longExt[i];
    if (lower.size() > e.size() && lower.compare(lower.size() - e.size(), e.size(), e) == 0) {
      std::string base = b.substr(0, b.size() - e.size());
      if (base.size() > 4) {
        std::string bl;
        for (size_t k = 0; k < base.size(); k++) bl += (char)tolower((unsigned char)base[k]);
        if (bl.compare(bl.size() - 4, 4, ".tar") == 0) return base;
      }
      return base + ".tar";
    }
  }
  return b;
}

// 单段创建：把给定条目写成一个归档。组合格式（tar.*）调用它两次。
static bool CreateSingleArchive(const std::vector<std::string> &utf8InputPaths,
                                const std::string &utf8DestArchive,
                                const CompressionOptions &options,
                                Callback *cb, std::string &error) {
  error.clear();
  // 密码副本的生存期被严格限制在本函数内（技术方案 §8.2）
  CPasswordGuard pwGuard(options.password);

  if (utf8InputPaths.empty()) {
    error = "没有待压缩的输入";
    return false;
  }

  // 外部编解码器里只解压、不编码的格式：明确拒绝创建，避免落到上游 CLSID 查找
  // 给出含糊的「不支持的压缩格式」。（当前实现里几种都是既能解也能编，
  // 这条是给将来「只加解码器」的格式留的兜底。）
  // 查表用归一化后的名字 —— 界面可能给短写（br / lz / sz），注册名却是长写。
  const ExternalCodec *extCodec = FindExternalCodec(CanonicalFormatName(options.format));
  if (extCodec && !extCodec->canEncode) {
    error = "「" + options.format + "」仅支持解压，无法创建归档";
    return false;
  }

  // 单流格式（归档里只有一个条目、没有元数据表）一次只能压一个文件。
  // 上游的 gz / bz2 / xz 本身就有限制；外部编解码器（zstd / lz4 / brotli /
  // lzip / snappy）按格式定义全是单流，所以只要命中 extCodec 就一并拦截。
  const std::string cf = CanonicalFormatName(options.format);
  const bool singleStream =
      (extCodec != NULL) || cf == "gzip" || cf == "bzip2" || cf == "xz" || cf == "zstd";
  if (singleStream && utf8InputPaths.size() > 1) {
    error = "「" + cf + "」是单流格式，一次只能压缩一个文件";
    return false;
  }

  // 只有上游处理器才需要 CLSID。外部编解码器由我们自己 new 出来，上游注册表里
  // 没有它的条目 —— 去查只会失败，把明明能用的格式误判成「不支持」。
  GUID clsid;
  if (!extCodec && !FormatToClsid(options.format, clsid, error)) return false;

  std::vector<SDirItem> items;
  for (size_t i = 0; i < utf8InputPaths.size(); i++) {
    std::string base = utf8InputPaths[i];
    while (base.size() > 1 && base[base.size() - 1] == '/') base.erase(base.size() - 1);
    UString name = ArchiveRootForPath(base, options);
    if (name.IsEmpty()) {
      error = "无法从路径得到名称：" + base;
      return false;
    }
    CollectItems(ToFString(base), name, items, cb, 0, options.excludeMacJunk);
  }
  if (items.empty()) {
    error = "没有可压缩的条目";
    return false;
  }

  const size_t destSlash = utf8DestArchive.find_last_of('/');
  if (destSlash != std::string::npos) {
    if (!EnsureDir(utf8DestArchive.substr(0, destSlash))) {
      error = "无法创建目标目录";
      return false;
    }
  }

  // 外部编解码器优先：上游注册表里 zstd 的处理器没有 IOutArchive（7-Zip 只带
  // 解码器），创建必须走我们自己的实现。lz4 / brotli / lzip / snappy 更是上游
  // 完全没有的格式，注册表里连名字都查不到。extCodec 在上面已经查过，复用即可。
  CMyComPtr<IOutArchive> outArchive =
      extCodec ? CreateExternalOutHandler(extCodec) : CMyComPtr<IOutArchive>();
  if (!outArchive) {
    if (CreateObject(&clsid, &IID_IOutArchive, (void **)&outArchive) != S_OK || !outArchive) {
      error = extCodec ? ("该格式暂时不支持创建归档（" + std::string(extCodec->name) +
                          " 编码器未链接）")
                       : "该格式不支持创建归档";
      return false;
    }
  }

  // ---- 应用压缩选项（技术方案 §5.1 字段映射）----
  if (!ApplyCompressionOptions(outArchive, options, options.format, error)) return false;

  CUpdateCallback *upSpec = new CUpdateCallback;
  CMyComPtr<IArchiveUpdateCallback2> holder(upSpec);
  upSpec->cb = cb;
  upSpec->password = pwGuard.get();
  upSpec->Init(&items);

  HRESULT hr;
  if (options.hasVolumeSize && options.volumeSize > 0) {
    // 分卷：使用引擎自带的 CMultiOutStream，行为与 7zz -v 一致。
    // 该流把数据缓冲在内部，必须显式调用 FinalFlush_and_CloseFiles() 才会落盘。
    CMultiOutStream *vol = new CMultiOutStream;
    CMyComPtr<IOutStream> volHolder(vol);
    vol->Prefix = ToFString(utf8DestArchive);
    vol->Prefix.Add_Dot();
    CRecordVector<UInt64> sizes;
    sizes.Add(options.volumeSize);
    vol->Init(sizes);

    hr = outArchive->UpdateItems(volHolder, (UInt32)items.size(), holder);
    if (hr == S_OK) {
      unsigned numVolumes = 0;
      hr = vol->FinalFlush_and_CloseFiles(numVolumes);
      // 与 7zz 的 DisableDeletion() 等价：落盘成功后必须关闭析构删除，
      // 否则 CMultiOutStream::Destruct() 会把刚写出的分卷全部删掉。
      if (hr == S_OK) vol->NeedDelete = false;
      if (cb) {
        char buf[160];
        sprintf(buf, "分卷输出：%u 个卷，共 %llu 字节", numVolumes,
                (unsigned long long)vol->GetSize());
        cb->OnLog(LogLevel::Info, buf);
      }
    }
  } else {
    COutFileStream *outSpec = new COutFileStream;
    CMyComPtr<IOutStream> outHolder(outSpec);
    if (!outSpec->Create_ALWAYS(ToFString(utf8DestArchive))) {
      error = "无法创建归档文件：" + utf8DestArchive;
      return false;
    }
    hr = outArchive->UpdateItems(outHolder, (UInt32)items.size(), holder);
  }

  // 引擎已不再需要密码，立即从回调对象中抹除（技术方案 §8.2）
  BurnString(upSpec->password);

  if (hr != S_OK) {
    const char *t = HRReason(hr);
    error = t ? std::string(t) : ("创建归档失败（" + HRText(hr) + "）");
    return false;
  }
  if (!upSpec->failedFiles.empty()) {
    char buf[64];
    sprintf(buf, "%llu", (unsigned long long)upSpec->failedFiles.size());
    error = std::string("有 ") + buf + " 个文件无法读取";
    return false;
  }
  return true;
}

// 组合格式用的临时目录：单独建一个子目录，避免同名归档互相踩。
// 目录内文件名固定为内层条目名（见 InnerTarEntryName）。
static bool MakeComposedTempTar(const std::string &innerName, std::string &dirOut,
                                std::string &pathOut) {
  const char *tmp = getenv("TMPDIR");
  std::string base = (tmp && *tmp) ? tmp : "/tmp";
  while (base.size() > 1 && base[base.size() - 1] == '/') base.erase(base.size() - 1);
  std::string tmpl = base + "/7z-compose-XXXXXX";
  std::vector<char> buf(tmpl.begin(), tmpl.end());
  buf.push_back('\0');
  if (!mkdtemp(buf.data())) return false;
  dirOut = std::string(buf.data());
  pathOut = dirOut + "/" + innerName;
  return true;
}

bool create(const std::vector<std::string> &utf8InputPaths,
            const std::string &utf8DestArchive, const CompressionOptions &options,
            Callback *cb, std::string &error) {
  // 镜像类格式先分流：它们不是上游 handler（7-Zip 只能读 ISO/DMG），也不是单流
  // 编解码器，必须在 CreateSingleArchive 的 CLSID 查找之前处理。
  //   iso —— 进程内自研 ISO9660+Joliet 写入器（Z7IsoWriter）；
  //   dmg —— 调系统 hdiutil（Z7DmgWriter，唯一的子进程例外）。
  {
    std::string lf;
    for (size_t i = 0; i < options.format.size(); i++)
      lf += (char)tolower((unsigned char)options.format[i]);
    if (lf == "iso")
      return iso::CreateIso(utf8InputPaths, utf8DestArchive, options.volumeName,
                            options.excludeMacJunk, cb, error);
    if (lf == "dmg")
      return dmg::CreateDmg(utf8InputPaths, utf8DestArchive, options.volumeName, cb, error);
  }

  std::string outer;
  if (!IsComposedTarFormat(options.format, outer))
    return CreateSingleArchive(utf8InputPaths, utf8DestArchive, options, cb, error);

  // tar.<外层> 两段式：先把条目打成 tar 临时文件，再用外层单流格式压缩它。
  // 这是官方 7zz 做不到的一步生成（多输入 -tgzip 直接 E_INVALIDARG）。
  const std::string innerName = InnerTarEntryName(utf8DestArchive);
  std::string tmpDir, tmpTar;
  if (!MakeComposedTempTar(innerName, tmpDir, tmpTar)) {
    error = "无法创建临时目录";
    return false;
  }

  bool ok = false;
  do {
    CompressionOptions innerOpts = options;
    innerOpts.format = "tar";
    // 分卷只对最外层有意义；内层 tar 若也分卷会先写出一串 .001 中间文件
    innerOpts.hasVolumeSize = false;
    if (cb) cb->OnLog(LogLevel::Info, "组合归档：第 1/2 段 打包 tar");
    if (!CreateSingleArchive(utf8InputPaths, tmpTar, innerOpts, cb, error)) break;

    CompressionOptions outerOpts = options;
    outerOpts.format = outer;
    // 外层只装这一个 tar，条目名必须就是它；「保留完整路径」只对内层内容生效，
    // 否则归档里会存下一个 /var/folders/... 的绝对路径。
    outerOpts.fullPaths = false;
    if (cb) cb->OnLog(LogLevel::Info, std::string("组合归档：第 2/2 段 ") + outer + " 压缩");
    ok = CreateSingleArchive(std::vector<std::string>(1, tmpTar), utf8DestArchive, outerOpts,
                             cb, error);
  } while (false);

  unlink(tmpTar.c_str());
  rmdir(tmpDir.c_str());
  return ok;
}

// ---------------------------------------------------------------------------
// 更新归档（技术方案 §5.1「更新模式」）
// 复用已打开的处理器对象：同一实例既提供 IInArchive 也提供 IOutArchive，
// 因此先在 IInArchive 上枚举既有条目，再 QI 到 IOutArchive 执行增量写入。
// 写入落到 "<归档>.update.tmp"，成功后才原子替换原文件。
// ---------------------------------------------------------------------------

static std::string LowerAscii(const std::string &s) {
  std::string r = s;
  for (size_t i = 0; i < r.size(); i++) r[i] = (char)tolower((unsigned char)r[i]);
  return r;
}

bool Archive::addItems(const std::vector<std::string> &utf8InputPaths,
                       const CompressionOptions &options, bool replaceExisting, Callback *cb,
                       std::string &error) {
  error.clear();
  if (!m_impl->archive) {
    error = "归档未打开";
    return false;
  }
  if (utf8InputPaths.empty()) {
    error = "没有待添加的输入";
    return false;
  }
  CPasswordGuard pwGuard(options.password);

  // 1. 既有条目路径表（冲突判定用）
  std::vector<std::string> existingPaths(m_impl->numItems);
  for (UInt32 i = 0; i < m_impl->numItems; i++) {
    ItemInfo it;
    if (getItem(i, it)) existingPaths[i] = it.path;
  }

  // 2. 收集待添加条目
  std::vector<SDirItem> newItems;
  for (size_t i = 0; i < utf8InputPaths.size(); i++) {
    std::string base = utf8InputPaths[i];
    while (base.size() > 1 && base[base.size() - 1] == '/') base.erase(base.size() - 1);
    UString name = ArchiveRootForPath(base, options);
    if (name.IsEmpty()) {
      error = "无法从路径得到名称：" + base;
      return false;
    }
    CollectItems(ToFString(base), name, newItems, cb, 0, options.excludeMacJunk);
  }
  if (newItems.empty()) {
    error = "没有可添加的条目";
    return false;
  }

  // 3. 建立"输出槽位 -> 条目"映射：先保留全部既有条目，再追加新条目
  std::vector<CUpdateCallback::SUpdatePair> pairs;
  std::vector<int> slotToItem;
  std::vector<char> consumed(newItems.size(), 0);
  UInt64 replaced = 0;

  for (UInt32 i = 0; i < m_impl->numItems; i++) {
    int matched = -1;
    if (replaceExisting) {
      for (size_t k = 0; k < newItems.size(); k++) {
        if (consumed[k]) continue;
        if (ToUtf8(newItems[k].arcPath) == existingPaths[i]) {
          matched = (int)k;
          break;
        }
      }
    }
    CUpdateCallback::SUpdatePair p;
    if (matched >= 0) {
      consumed[(size_t)matched] = 1;
      p.newData = true;
      p.newProps = true;
      p.indexInArchive = i;
      replaced++;
    } else {
      // 复用归档中已有条目：newData / newProps 均为 0，引擎原样保留，不回调数据
      p.newData = false;
      p.newProps = false;
      p.indexInArchive = i;
    }
    pairs.push_back(p);
    slotToItem.push_back(matched);
  }

  UInt64 skipped = 0;
  UInt64 added = 0;
  for (size_t k = 0; k < newItems.size(); k++) {
    if (consumed[k]) continue;
    const std::string p = ToUtf8(newItems[k].arcPath);
    bool collides = false;
    for (size_t i = 0; i < existingPaths.size(); i++)
      if (existingPaths[i] == p) {
        collides = true;
        break;
      }
    if (collides) {
      skipped++;
      if (cb) cb->OnLog(LogLevel::Warning, "归档中已存在同名条目，已按策略跳过：" + p);
      continue;
    }
    CUpdateCallback::SUpdatePair pr;
    pr.newData = true;
    pr.newProps = true;
    pr.indexInArchive = (UInt32)(Int32)-1;
    pairs.push_back(pr);
    slotToItem.push_back((int)k);
    added++;
  }

  if (added == 0 && replaced == 0) {
    char buf[96];
    sprintf(buf, "没有需要写入的条目（已跳过 %llu 个同名条目）", (unsigned long long)skipped);
    error = buf;
    return false;
  }

  // 4. 复用既有处理器取得 IOutArchive
  CMyComPtr<IOutArchive> outArchive;
  if (m_impl->archive->QueryInterface(IID_IOutArchive, (void **)&outArchive) != S_OK ||
      !outArchive) {
    error = "该归档格式不支持写入（更新），请改用新建归档";
    return false;
  }
  if (!ApplyCompressionOptions(outArchive, options, LowerAscii(m_impl->formatName), error))
    return false;

  // 5. 写临时文件
  const std::string tmpPath = m_impl->path + ".update.tmp";
  unlink(tmpPath.c_str());

  CUpdateCallback *upSpec = new CUpdateCallback;
  CMyComPtr<IArchiveUpdateCallback2> holder(upSpec);
  upSpec->cb = cb;
  upSpec->password = pwGuard.get();
  upSpec->InitUpdate(&newItems, &pairs, &slotToItem);

  HRESULT hr = E_FAIL;
  {
    COutFileStream *outSpec = new COutFileStream;
    CMyComPtr<IOutStream> outHolder(outSpec);
    if (!outSpec->Create_ALWAYS(ToFString(tmpPath))) {
      error = "无法创建临时归档文件：" + tmpPath;
      return false;
    }
    hr = outArchive->UpdateItems(outHolder, (UInt32)pairs.size(), holder);
  }
  BurnString(upSpec->password);

  // 6. 关闭读取端——必须先释放对原文件的引用，随后才能安全替换
  m_impl->archive->Close();
  m_impl->archive.Release();
  m_impl->stream.Release();
  m_impl->numItems = 0;

  if (hr != S_OK) {
    unlink(tmpPath.c_str());
    const char *t = HRReason(hr);
    error = t ? std::string(t) : ("更新归档失败（" + HRText(hr) + "）");
    return false;
  }
  if (!upSpec->failedFiles.empty()) {
    unlink(tmpPath.c_str());
    char buf[64];
    sprintf(buf, "%llu", (unsigned long long)upSpec->failedFiles.size());
    error = std::string("有 ") + buf + " 个文件无法读取";
    return false;
  }
  if (rename(tmpPath.c_str(), m_impl->path.c_str()) != 0) {
    unlink(tmpPath.c_str());
    error = "无法替换原归档文件：" + m_impl->path;
    return false;
  }

  if (cb) {
    char buf[192];
    sprintf(buf, "更新完成：新增 %llu 个，替换 %llu 个，跳过 %llu 个",
            (unsigned long long)added, (unsigned long long)replaced,
            (unsigned long long)skipped);
    cb->OnLog(LogLevel::Info, buf);
  }
  return true;
}

// ---------------------------------------------------------------------------
// 从归档中删除条目（技术方案 §6.4「删除键（更新归档时）」）
//
// 实现策略说明（重要）：
//   7-Zip 的 update 协议确实定义了 IArchiveUpdateCallback 的 anti 条目语义，
//   但实测在 7z handler 上「报告成功却不生效」——即条目仍在归档中，
//   这种静默失效对用户数据是危险的。因此本层改用**可验证的重建路径**：
//     解压保留项到临时目录 → 关闭读取端 → 以给定参数重新打包 → 原子替换。
//   代价是被保留条目会重新压缩（压缩参数按本次 options 统一）；
//   收益是结果与 create/extract 两条已验证路径完全一致，不会静默出错。
// ---------------------------------------------------------------------------

static bool RemoveDirRecursive(const std::string &utf8Dir) {
  DIR *d = opendir(utf8Dir.c_str());
  if (!d) return false;
  struct dirent *ent;
  bool ok = true;
  while ((ent = readdir(d)) != NULL) {
    const char *nm = ent->d_name;
    if (strcmp(nm, ".") == 0 || strcmp(nm, "..") == 0) continue;
    const std::string p = JoinPath(utf8Dir, std::string(nm));
    struct stat st;
    if (lstat(p.c_str(), &st) == 0 && MY_LIN_S_ISDIR(st.st_mode)) {
      if (!RemoveDirRecursive(p)) ok = false;
    } else if (unlink(p.c_str()) != 0) {
      ok = false;
    }
  }
  closedir(d);
  if (rmdir(utf8Dir.c_str()) != 0) ok = false;
  return ok;
}

static void ListTopLevel(const std::string &utf8Dir, std::vector<std::string> &out) {
  out.clear();
  DIR *d = opendir(utf8Dir.c_str());
  if (!d) return;
  struct dirent *ent;
  while ((ent = readdir(d)) != NULL) {
    const char *nm = ent->d_name;
    if (strcmp(nm, ".") == 0 || strcmp(nm, "..") == 0) continue;
    out.push_back(JoinPath(utf8Dir, std::string(nm)));
  }
  closedir(d);
}

bool Archive::removeItems(const std::vector<std::string> &utf8ArcPaths,
                          const CompressionOptions &options, Callback *cb,
                          std::string &error) {
  error.clear();
  if (!m_impl->archive) {
    error = "归档未打开";
    return false;
  }
  if (utf8ArcPaths.empty()) {
    error = "没有指定要删除的条目";
    return false;
  }

  // 单流容器（gzip/bzip2/xz 等）没有"条目"概念，重建无意义
  if (m_impl->numItems <= 1) {
    error = "该归档只有一个条目或不含独立条目，不支持删除";
    return false;
  }

  // 1. 计算保留集合。删除一个目录路径时，其下所有后代一并删除。
  std::vector<uint32_t> keep;
  UInt64 matched = 0;
  for (UInt32 i = 0; i < m_impl->numItems; i++) {
    ItemInfo it;
    if (!getItem(i, it)) continue;
    bool hit = false;
    for (size_t k = 0; k < utf8ArcPaths.size(); k++) {
      const std::string &t = utf8ArcPaths[k];
      if (it.path == t ||
          (it.path.size() > t.size() && it.path.compare(0, t.size(), t) == 0 &&
           it.path[t.size()] == '/')) {
        hit = true;
        break;
      }
    }
    if (hit) {
      matched++;
      // 根路径 "[Content]" 说明是单流内容归档，不允许删除
      if (it.path == "[Content]") {
        error = "该归档为单流容器，不支持删除条目";
        return false;
      }
    } else {
      keep.push_back(i);
    }
  }
  if (matched == 0) {
    error = "归档中没有匹配的条目";
    return false;
  }
  if (keep.empty()) {
    error = "不能删除归档中的全部条目（引擎不支持生成空归档）";
    return false;
  }

  // 2. 解压保留项到临时目录
  const char *tmpBase = getenv("TMPDIR");
  if (!tmpBase || !*tmpBase) tmpBase = "/tmp";
  std::string tmpPattern = std::string(tmpBase);
  while (tmpPattern.size() > 1 && tmpPattern[tmpPattern.size() - 1] == '/')
    tmpPattern.erase(tmpPattern.size() - 1);
  tmpPattern += "/z7rebuild.XXXXXX";

  std::vector<char> tmpBuf(tmpPattern.begin(), tmpPattern.end());
  tmpBuf.push_back('\0');
  char *tmpDir = mkdtemp(&tmpBuf[0]);
  if (!tmpDir) {
    error = "无法创建临时目录";
    return false;
  }
  const std::string workDir(tmpDir);
  const std::string workDirNorm = workDir;

  std::string extractErr;
  // 重建用的临时目录是空的，冲突策略无实际影响，沿用覆盖。
  const bool extracted = extract(keep, workDir, false, ClashPolicy::Overwrite, cb, extractErr,
                                 true /*atomicFiles*/, true /*createSymLinks*/);
  if (!extracted) {
    RemoveDirRecursive(workDir);
    error = "删除前的解压失败：" + extractErr;
    return false;
  }

  // 3. 关闭读取端，随后才能替换原文件
  m_impl->archive->Close();
  m_impl->archive.Release();
  m_impl->stream.Release();
  m_impl->numItems = 0;

  // 4. 按原结构重新打包（顶层条目名保持不变，归档内路径因此不变）
  std::vector<std::string> topLevel;
  ListTopLevel(workDir, topLevel);
  if (topLevel.empty()) {
    RemoveDirRecursive(workDir);
    error = "临时目录为空，已取消操作";
    return false;
  }

  const std::string tmpArchive = m_impl->path + ".rebuild.tmp";
  unlink(tmpArchive.c_str());

  CompressionOptions opts = options;
  // 容器格式永远沿用原归档——删除操作不应把 zip 悄悄变成 7z。
  // 注意不能用 "opts.format 为空则继承" 的写法：CompressionOptions::format 的
  // 默认值就是 "7z"，调用方不显式清空就会导致静默换容器。
  opts.format = LowerAscii(m_impl->formatName);

  // 原归档若为文件名加密（-mhe），重建时必须还它一个 -mhe。
  // 否则"删掉一个文件"会把整个归档的机密性降级为仅数据加密——这是静默的安全退化，
  // 官方 7zz d 在同一场景下是保留 -mhe 的（见 §10.3 行为等价要求）。
  if (m_impl->headerEncrypted) {
    opts.hasEncryptHeader = true;
    opts.encryptHeader = true;
  }

  std::string createErr;
  const bool recreated = create(topLevel, tmpArchive, opts, cb, createErr);
  RemoveDirRecursive(workDir);
  if (!recreated) {
    unlink(tmpArchive.c_str());
    error = "重新打包失败：" + createErr;
    return false;
  }

  if (rename(tmpArchive.c_str(), m_impl->path.c_str()) != 0) {
    unlink(tmpArchive.c_str());
    error = "无法替换原归档文件：" + m_impl->path;
    return false;
  }

  if (cb) {
    char buf[128];
    sprintf(buf, "删除完成：移除 %llu 个条目，保留 %llu 个（已按当前参数重新打包）",
            (unsigned long long)matched, (unsigned long long)keep.size());
    cb->OnLog(LogLevel::Info, buf);
  }
  return true;
}

// ---------------------------------------------------------------------------
// 能力查询
// ---------------------------------------------------------------------------

bool listFormats(std::vector<FormatInfo> &out) {
  out.clear();
  std::vector<HandlerEntry> handlers;
  EnumerateHandlers(handlers);
  // 外部编解码器的「可创建」能力：zstd 上游只报可解（canUpdate=0），我们补了
  // 编码器，这里按真实能力覆盖。
  // 其余外部格式（lz4 / brotli / lzip / snappy）在 EnumerateHandlers 里就是按
  // ExternalCodec::canEncode 注入的，canUpdate 已经是对的，不需要在这里再改。
  bool zstdCanEncode = (FindExternalCodec("zstd") != NULL);
  for (size_t i = 0; i < handlers.size(); i++) {
    FormatInfo fi;
    fi.name = handlers[i].name;
    fi.extensions = handlers[i].extensions;
    fi.canUpdate = handlers[i].canUpdate;
    if (zstdCanEncode && handlers[i].name == "zstd") fi.canUpdate = true;
    out.push_back(fi);
  }

  // 镜像类格式：上游的 Iso / Dmg handler 只能读（没有 IOutArchive），本移植补了
  // 「创建」（ISO 自研写入器 / DMG 调 hdiutil），因此把 canUpdate 置 true；
  // 用大小写不敏感的匹配覆盖上游注册表里的 Iso / Dmg 条目，缺失时才补一条。
  const char *extraName[2] = {"iso", "dmg"};
  for (int e = 0; e < 2; e++) {
    bool found = false;
    for (size_t i = 0; i < out.size(); i++) {
      std::string ln;
      for (size_t k = 0; k < out[i].name.size(); k++)
        ln += (char)tolower((unsigned char)out[i].name[k]);
      if (ln == extraName[e]) { out[i].canUpdate = true; found = true; break; }
    }
    if (!found) {
      FormatInfo fi;
      fi.name = extraName[e];
      fi.extensions = extraName[e];
      fi.canUpdate = true;
      out.push_back(fi);
    }
  }
  return !out.empty();
}

std::string engineVersion() {
  std::string v = MY_VERSION;
  while (!v.empty() && v[0] == ' ') v.erase(0, 1);
  return v;
}

std::string attributeString(uint32_t attrib) {
  std::string s;
  const uint32_t m = attrib & 07777;
  const char chars[] = {'r', 'w', 'x'};
  for (int g = 2; g >= 0; g--)
    for (int b = 2; b >= 0; b--) {
      const uint32_t bit = 1u << (g * 3 + b);
      s += (m & bit) ? chars[2 - b] : '-';
    }
  return s;
}

std::string methodDisplayName(const std::string &rawMethod) { return rawMethod; }

} // namespace z7
