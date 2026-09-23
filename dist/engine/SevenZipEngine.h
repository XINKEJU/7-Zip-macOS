// SevenZipEngine.h
//
// 7-Zip 引擎内嵌桥接层 —— C++ 核心接口（技术方案 §4.2 桥接层）
//
// 设计要点：
//   * 本层只依赖 7-Zip 公开接口（IInArchive / IOutArchive / 各类 Callback），
//     通过 lib7z.dylib 的 C 入口 CreateObject() 取得处理器实例；
//   * 所有路径以 UTF-8 传递（7-Zip 在非 Windows 平台强制 UTF-8，见
//     Common/StringConvert.cpp 的 g_ForceToUTF8）；
//   * 本层不做线程调度，全部为同步调用，由上层（Objective-C++ adapter /
//     NSOperationQueue）负责放到后台线程并节流进度。
//
// 许可：本项目整体以 LGPL-2.1-or-later 分发；本文件源自 7-Zip 移植工作。

#ifndef SEVEN_ZIP_ENGINE_H
#define SEVEN_ZIP_ENGINE_H

#include <cstdint>
#include <string>
#include <vector>

namespace z7 {

// ---------------------------------------------------------------------------
// 进度与取消回调
// ---------------------------------------------------------------------------

enum class LogLevel { Info, Warning, Error };

class Callback {
public:
  virtual ~Callback() {}

  // 返回 false 表示请求中止（等价于取消）。
  virtual bool OnProgress(uint64_t /*completed*/, uint64_t /*total*/,
                          uint32_t /*itemIndex*/, const std::string & /*itemPath*/) {
    return true;
  }
  virtual bool IsCanceled() { return false; }

  // 返回空串表示"无密码"。retry == true 表示上一次提供的密码被拒绝。
  virtual std::string GetPassword(bool /*retry*/) { return std::string(); }

  virtual void OnLog(LogLevel /*level*/, const std::string & /*message*/) {}
};

// ---------------------------------------------------------------------------
// 条目属性（PROPVARIANT 已翻译为普通值类型）
// ---------------------------------------------------------------------------

struct ItemInfo {
  uint32_t index = 0;
  std::string path;   // 归档内完整路径，'/' 分隔（UTF-8）
  std::string name;   // 末段名称
  std::string parent; // 父目录路径，根级为 ""
  int depth = 0;      // 层级深度，根级为 0

  bool isDir = false;
  bool isAnti = false;

  // 符号链接条目（技术方案 §8.2「符号链接劫持」）
  bool isSymLink = false;
  std::string linkTarget; // 链接目标原文（UTF-8），来自 kpidSymLink

  bool hasSize = false;
  uint64_t size = 0;
  bool hasPackSize = false;
  uint64_t packSize = 0;

  bool hasMTime = false;
  int64_t mtime = 0; // Unix 秒（UTC）
  bool hasCTime = false;
  int64_t ctime = 0;
  bool hasATime = false;
  int64_t atime = 0;

  bool hasAttrib = false;
  uint32_t attrib = 0; // 7-Zip 的 kpidAttrib（POSIX 模式下即 st_mode）
  // 部分 handler 单独提供 POSIX 模式；删除条目时需要原样回填
  bool hasPosixAttrib = false;
  uint32_t posixAttrib = 0;

  bool hasCRC = false;
  uint32_t crc = 0;

  bool encrypted = false;
  std::string method;    // 压缩方法链，UTF-8
  std::string extension;

  double compressionRatio() const {
    if (!hasSize || !hasPackSize || size == 0) return 0.0;
    return 100.0 * (double)packSize / (double)size;
  }
};

// ---------------------------------------------------------------------------
// 压缩参数（对应技术方案 §5.1 的面板字段映射）
// ---------------------------------------------------------------------------

struct CompressionOptions {
  std::string format = "7z"; // 7z | zip | tar | gzip | bzip2 | xz
  int level = 5;             // -mx=0..9

  std::string method;         // -m0=…（空 = 处理器默认）
  bool hasDict = false;       // -md
  uint64_t dictSize = 0;      // 字节
  bool hasWordLength = false; // -mlc
  int wordLength = 0;
  bool hasFastBytes = false; // -mfb
  int fastBytes = 0;
  std::string matchFinder; // -mmf（bt4 / hc4 / bt2 / hc3 / hc3b）

  bool hasSolid = false; // -ms（off / on）
  bool solid = true;
  // 固实分块（-ms=…）：形如 "100e"（按文件数）或 "64m"（按字节），空 = 不限制。
  // 引擎通过属性名 "s<suffix>" + VT_EMPTY 值接收该设置（见 7zHandlerOut.cpp）。
  std::string solidBlock;

  // 保留完整路径（-spf）：归档内条目使用完整源路径而非仅末段名称。
  bool fullPaths = false;

  bool hasThreads = false; // -mmt
  int threads = 0;         // 0 = 自动（跟随 CPU 核数）

  bool hasVolumeSize = false; // -v
  uint64_t volumeSize = 0;

  std::string encryptMethod; // -mem（zip 等支持选择加密算法）

  std::string password;          // -p
  bool hasEncryptHeader = false; // -mhe（7z）
  bool encryptHeader = true;
  bool hasCompressHeader = false; // -mhc（7z）
  bool compressHeader = true;

  // 压缩时是否排除 macOS/Windows 系统元数据垃圾（.DS_Store / __MACOSX / ._* /
  // Thumbs.db …）。默认开启；关闭后这些文件会按普通文件写入归档。
  // 注意：归档「列表」侧的同类过滤始终生效，不受本开关影响。
  bool excludeMacJunk = true;

  bool storeAltStreams = false;
};

// ---------------------------------------------------------------------------
// 归档读取
// ---------------------------------------------------------------------------

class Archive {
public:
  // 解压统计（技术方案 §8.2：不安全条目必须可见、可上报）
  struct ExtractStats {
    uint64_t errors = 0;        // 提取失败条目数
    uint64_t wrongPassword = 0; // 密码错误条目数
    uint64_t unsafe = 0;        // 被安全策略拒绝的条目数（穿越 / 越界链接）
    uint64_t skipped = 0;       // 已存在被跳过（overwrite = false）
    uint64_t symLinks = 0;      // 成功创建的符号链接数
    uint64_t bytes = 0;         // 实际写出字节数
  };

  // 打开归档并自动探测格式。失败返回 nullptr，error 填入原因（UTF-8）。
  // 若归档加密且 cb->GetPassword() 返回空串，Open 失败并给出提示。
  static Archive *Open(const std::string &utf8Path, Callback *cb, std::string &error);

  ~Archive();

  Archive(const Archive &) = delete;
  Archive &operator=(const Archive &) = delete;

  const std::string &formatName() const;
  const std::string &archivePath() const;

  // 打开该归档时是否需要密码。对 7z 而言等价于「文件名加密（-mhe）」——
  // 仅数据加密的归档在打开阶段不需要密码。
  // UI 可据此决定是否提示输入密码；removeItems 依此在重建时保留 -mhe。
  bool isHeaderEncrypted() const;

  uint32_t itemCount() const;
  bool getItem(uint32_t index, ItemInfo &out) const;
  bool getAllItems(std::vector<ItemInfo> &out) const;

  // 提取（indices 为空 = 全部）。testMode = true 时只做完整性校验（Test）。
  // overwrite = false 时已存在的文件会被跳过（否则覆盖）。
  //   atomicFiles    — 先写 "<目标>.partial" 再原子改名，失败即删除半成品
  //                    （技术方案 §7.4）；测试模式忽略该参数。
  //   createSymLinks — 允许创建符号链接，但目标必须落在目标目录内，否则拒绝
  //                    （技术方案 §8.2）。
  bool extract(const std::vector<uint32_t> &indices, const std::string &utf8DestDir,
               bool testMode, bool overwrite, Callback *cb, std::string &error,
               bool atomicFiles = true, bool createSymLinks = true);

  // 最近一次 extract / extractToFile / extractToMemory 的统计。
  const ExtractStats &lastExtractStats() const;

  // 单条目提取到指定磁盘文件（供 Quick Look 预览、拖拽导出使用）。
  bool extractToFile(uint32_t index, const std::string &utf8DestFile, Callback *cb,
                     std::string &error);

  // 提取到内存（上限 maxBytes，超出返回 false 并设置 tooLarge）。用于小文件预览。
  bool extractToMemory(uint32_t index, std::vector<uint8_t> &out, uint64_t maxBytes,
                       bool &tooLarge, Callback *cb, std::string &error);

  // 请求取消：正在进行的 extract 会尽快返回。
  void cancel();

  // 向已打开的归档追加条目（技术方案 §5.1「更新模式」）。
  //   replaceExisting = false —— 已存在同名条目时跳过新条目（等价 7zz 默认）
  //   replaceExisting = true  —— 用新条目替换已有同名条目
  // 实现上先写 "<归档>.update.tmp"，成功后原子改名替换原文件。
  // 注意：调用成功后本对象即失效（原文件已被替换），必须重新 Open。
  bool addItems(const std::vector<std::string> &utf8InputPaths,
                const CompressionOptions &options, bool replaceExisting, Callback *cb,
                std::string &error);

  // 从已打开的归档中删除条目（技术方案 §6.4「删除键（更新归档时）」）。
  // arcPaths 为归档内完整路径；删除目录路径时其下所有后代一并删除。
  //
  // 实现说明：不使用 7z update 协议的 anti 条目（实测在 7z handler 上静默失效），
  // 而是走「解压保留项 → 重建 → 原子替换」的可验证路径。因此保留条目会按
  // options 给定的参数重新压缩。
  //
  // 容器格式**始终沿用原归档格式**，options.format 在此方法中被忽略——
  // 删除不应改变容器类型。调用方无需（也不应）自行推导格式。
  // 调用成功后本对象即失效（原文件已被替换），必须重新 Open。
  bool removeItems(const std::vector<std::string> &utf8ArcPaths,
                   const CompressionOptions &options, Callback *cb, std::string &error);

  struct Impl;

private:
  Archive();
  Impl *m_impl;
};

// ---------------------------------------------------------------------------
// 归档创建
// ---------------------------------------------------------------------------

bool create(const std::vector<std::string> &utf8InputPaths, const std::string &utf8DestArchive,
            const CompressionOptions &options, Callback *cb, std::string &error);

// ---------------------------------------------------------------------------
// 引擎能力查询 / 诊断
// ---------------------------------------------------------------------------

struct FormatInfo {
  std::string name;
  std::string extensions;
  bool canUpdate = false;
};

bool listFormats(std::vector<FormatInfo> &out);
std::string engineVersion(); // 返回 lib7z 的版本串

// ---------------------------------------------------------------------------
// 工具：把 st_mode 之类的属性翻译为可读字符串（面板显示用）
// ---------------------------------------------------------------------------

std::string attributeString(uint32_t attrib);
std::string methodDisplayName(const std::string &rawMethod);

} // namespace z7

#endif // SEVEN_ZIP_ENGINE_H
