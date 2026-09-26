// engine_test.cpp
//
// 桥接层验收测试程序（技术方案 §10.3 验收门禁）。
//
// 该程序不依赖 App，直接驱动 z7::Archive / z7::create，用于与官方 7zz
// 命令行产物逐项比对。输出格式保持稳定，便于脚本 diff。

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <sys/stat.h>

#include "SevenZipEngine.h"

using namespace z7;

static bool g_verbose = false;

// 全局密码：由 main() 预处理 --password 得到（见 StripGlobalOptions）。
// 同时用于「打开归档」与「重新压缩」两条路径，因此一个 -p 即可覆盖删除/更新。
static std::string g_openPassword;

class ConsoleCallback : public Callback {
public:
  bool OnProgress(uint64_t completed, uint64_t total, uint32_t, const std::string &path) {
    if (!g_verbose) return true;
    char buf[256];
    if (total > 0)
      sprintf(buf, "\r[progress] %llu/%llu (%.1f%%) %s", (unsigned long long)completed,
              (unsigned long long)total,
              total ? 100.0 * (double)completed / (double)total : 0.0, path.c_str());
    else
      sprintf(buf, "\r[progress] %llu %s", (unsigned long long)completed, path.c_str());
    fputs(buf, stderr);
    fflush(stderr);
    return true;
  }
  bool IsCanceled() { return false; }
  // retry == true 表示上一次提供的密码被拒绝。此时返回空串以中止重试，
  // 否则引擎会拿着同一个错误密码反复询问。正确密码不会走到 retry 分支。
  std::string GetPassword(bool retry) { return retry ? std::string() : g_openPassword; }
  void OnLog(LogLevel level, const std::string &message) {
    const char *tag = "info";
    if (level == LogLevel::Warning) tag = "warn";
    if (level == LogLevel::Error) tag = "error";
    fprintf(stderr, "[%s] %s\n", tag, message.c_str());
  }
};

static void usage() {
  fputs(
      "engine_test — 7-Zip 引擎内嵌桥接层验收工具\n"
      "\n"
      "  engine_test version\n"
      "  engine_test formats\n"
      "  engine_test dumpitems <archive>\n"
      "  engine_test info <archive>\n"
      "  engine_test list <archive>\n"
      "  engine_test test <archive>\n"
      "  engine_test extract <archive> <destdir> [--overwrite]\n"
      "  engine_test extractone <archive> <index> <outfile>\n"
      "  engine_test extractmem <archive> <index> <maxbytes>\n"
      "  engine_test create <format> <dest> <input>... [选项]\n"
      "  engine_test add <archive> <input>... [--replace on|off] [选项]\n"
      "  engine_test remove <archive> <arcPath>... [选项]\n"
      "\n"
      "全局选项（任意子命令可用，位置不限）：\n"
      "  --password P       打开/创建/重新压缩共用的密码\n"
      "  --verbose          打印进度与日志\n"
      "\n"
      "create 选项：\n"
      "  --level N          压缩等级 0-9\n"
      "  --method NAME      方法（LZMA2/LZMA/PPMd/BZip2/Deflate/Copy）\n"
      "  --dict SIZE        字典大小（字节，支持 32m/1g 写法）\n"
      "  --wordlength N     -mlc\n"
      "  --fastbytes N      -mfb\n"
      "  --matchfinder NAME -mmf（bt4/hc4/bt2/hc3）\n"
      "  --solid on|off     -ms\n"
      "  --solidblock SPEC  -ms=… 固实分块（如 100e / 64m）\n"
      "  --fullpaths on|off -spf 保留完整路径\n"
      "  --threads N        -mmt\n"
      "  --volume SIZE      分卷大小（支持 1m/100m）\n"
      "  --encryptmeth NAME -mem\n"
      "  --encryptheader on|off  -mhe\n"
      "  --compressheader on|off -mhc\n"
      "\n"
      "add 选项：--replace on|off（同名条目替换，默认跳过）＋ create 的通用选项\n"
      "remove 选项：--level/--method/--encryptheader\n"
      "  （容器格式恒为原归档格式，无法指定；密码见全局 --password）\n",
      stderr);
}

static uint64_t ParseSize(const std::string &s) {
  if (s.empty()) return 0;
  char *end = NULL;
  const unsigned long long v = strtoull(s.c_str(), &end, 10);
  if (end && *end) {
    const char c = (char)tolower((unsigned char)*end);
    if (c == 'k') return (uint64_t)v * 1024ULL;
    if (c == 'm') return (uint64_t)v * 1024ULL * 1024ULL;
    if (c == 'g') return (uint64_t)v * 1024ULL * 1024ULL * 1024ULL;
  }
  return (uint64_t)v;
}

static const char *YesNo(bool b) { return b ? "1" : "0"; }

static int CmdDumpItems(const std::string &path) {
  ConsoleCallback cb;
  std::string err;
  Archive *a = Archive::Open(path, &cb, err);
  if (!a) {
    fprintf(stderr, "打开失败: %s\n", err.c_str());
    return 1;
  }
  std::vector<ItemInfo> items;
  if (!a->getAllItems(items)) {
    fprintf(stderr, "读取条目失败\n");
    delete a;
    return 1;
  }

  printf("archive\t%s\n", path.c_str());
  printf("format\t%s\n", a->formatName().c_str());
  printf("count\t%u\n", (unsigned)a->itemCount());
  printf("#\tidx\tdir\tsize\tpacked\tcrc\tenc\tmtime\tmethod\tpath\n");
  for (size_t i = 0; i < items.size(); i++) {
    const ItemInfo &it = items[i];
    char sizeBuf[32], packBuf[32], crcBuf[32], mtimeBuf[32];
    if (it.hasSize)
      sprintf(sizeBuf, "%llu", (unsigned long long)it.size);
    else
      strcpy(sizeBuf, "-");
    if (it.hasPackSize)
      sprintf(packBuf, "%llu", (unsigned long long)it.packSize);
    else
      strcpy(packBuf, "-");
    if (it.hasCRC)
      sprintf(crcBuf, "%08X", it.crc);
    else
      strcpy(crcBuf, "-");
    if (it.hasMTime)
      sprintf(mtimeBuf, "%lld", (long long)it.mtime);
    else
      strcpy(mtimeBuf, "-");
    printf("%zu\t%u\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", i, it.index, YesNo(it.isDir),
           sizeBuf, packBuf, crcBuf, YesNo(it.encrypted), mtimeBuf, it.method.c_str(),
           it.path.c_str());
  }
  delete a;
  return 0;
}

static int CmdList(const std::string &path) {
  ConsoleCallback cb;
  std::string err;
  Archive *a = Archive::Open(path, &cb, err);
  if (!a) {
    fprintf(stderr, "打开失败: %s\n", err.c_str());
    return 1;
  }
  printf("格式: %s   条目数: %u\n\n", a->formatName().c_str(), (unsigned)a->itemCount());
  printf("%-12s %-8s %-10s %-9s %-6s %-8s %s\n", "大小", "压缩后", "比率", "CRC", "加密",
         "时间", "路径");
  std::vector<ItemInfo> items;
  a->getAllItems(items);
  for (size_t i = 0; i < items.size(); i++) {
    const ItemInfo &it = items[i];
    char sz[64] = "-", pk[64] = "-", crc[64] = "-", tm[64] = "-";
    if (it.hasSize) sprintf(sz, "%llu", (unsigned long long)it.size);
    if (it.hasPackSize) sprintf(pk, "%llu", (unsigned long long)it.packSize);
    if (it.hasCRC) sprintf(crc, "%08X", it.crc);
    if (it.hasMTime) sprintf(tm, "%lld", (long long)it.mtime);
    if (it.isDir) strcpy(sz, "<DIR>");
    char ratio[16] = "-";
    if (it.hasSize && it.hasPackSize && !it.isDir)
      sprintf(ratio, "%.1f%%", it.compressionRatio());
    printf("%-12s %-8s %-10s %-9s %-6s %-8s %s\n", sz, pk, ratio, crc, YesNo(it.encrypted),
           tm, it.path.c_str());
  }
  delete a;
  return 0;
}

// 机器可读的归档概要，供验收脚本直接断言。
//   engine_test info <archive>
// 输出 key=value 行，顺序稳定。
static int CmdInfo(const std::string &path) {
  ConsoleCallback cb;
  std::string err;
  Archive *a = Archive::Open(path, &cb, err);
  if (!a) {
    fprintf(stderr, "打开失败: %s\n", err.c_str());
    return 1;
  }
  printf("format=%s\n", a->formatName().c_str());
  printf("items=%u\n", (unsigned)a->itemCount());
  printf("header_encrypted=%s\n", YesNo(a->isHeaderEncrypted()));
  delete a;
  return 0;
}

static int CmdTest(const std::string &path) {
  ConsoleCallback cb;
  std::string err;
  Archive *a = Archive::Open(path, &cb, err);
  if (!a) {
    fprintf(stderr, "打开失败: %s\n", err.c_str());
    return 1;
  }
  std::vector<uint32_t> none;
  const bool ok = a->extract(none, std::string(), true, ClashPolicy::Overwrite, &cb, err);
  printf("%s\n", ok ? "OK" : "FAIL");
  if (!ok) fprintf(stderr, "%s\n", err.c_str());
  delete a;
  return ok ? 0 : 1;
}

static int CmdExtract(const std::string &path, const std::string &dest, ClashPolicy clash) {
  ConsoleCallback cb;
  std::string err;
  Archive *a = Archive::Open(path, &cb, err);
  if (!a) {
    fprintf(stderr, "打开失败: %s\n", err.c_str());
    return 1;
  }
  std::vector<uint32_t> none;
  const bool ok = a->extract(none, dest, false, clash, &cb, err);
  if (!ok) fprintf(stderr, "解压失败: %s\n", err.c_str());
  delete a;
  return ok ? 0 : 1;
}

static int CmdExtractOne(const std::string &path, unsigned index, const std::string &out) {
  ConsoleCallback cb;
  std::string err;
  Archive *a = Archive::Open(path, &cb, err);
  if (!a) {
    fprintf(stderr, "打开失败: %s\n", err.c_str());
    return 1;
  }
  const bool ok = a->extractToFile(index, out, &cb, err);
  if (!ok) fprintf(stderr, "提取失败: %s\n", err.c_str());
  delete a;
  return ok ? 0 : 1;
}

static int CmdExtractMem(const std::string &path, unsigned index, uint64_t maxBytes) {
  ConsoleCallback cb;
  std::string err;
  Archive *a = Archive::Open(path, &cb, err);
  if (!a) {
    fprintf(stderr, "打开失败: %s\n", err.c_str());
    return 1;
  }
  std::vector<uint8_t> data;
  bool tooLarge = false;
  const bool ok = a->extractToMemory(index, data, maxBytes, tooLarge, &cb, err);
  if (!ok) {
    fprintf(stderr, "提取失败: %s%s\n", err.c_str(), tooLarge ? "（超限）" : "");
    delete a;
    return 1;
  }
  printf("%zu\n", data.size());
  fwrite(&data[0], 1, data.size(), stdout);
  delete a;
  return 0;
}

static int CmdCreate(int argc, char **argv) {
  if (argc < 5) {
    usage();
    return 1;
  }
  CompressionOptions opt;
  opt.format = argv[2];
  const std::string dest = argv[3];
  std::vector<std::string> inputs;
  inputs.push_back(argv[4]);

  for (int i = 5; i < argc; i++) {
    const std::string a = argv[i];
    const bool hasNext = (i + 1 < argc);
    if (a == "--level" && hasNext) {
      opt.level = atoi(argv[++i]);
    } else if (a == "--method" && hasNext) {
      opt.method = argv[++i];
    } else if (a == "--dict" && hasNext) {
      opt.dictSize = ParseSize(argv[++i]);
      opt.hasDict = true;
    } else if (a == "--wordlength" && hasNext) {
      opt.wordLength = atoi(argv[++i]);
      opt.hasWordLength = true;
    } else if (a == "--fastbytes" && hasNext) {
      opt.fastBytes = atoi(argv[++i]);
      opt.hasFastBytes = true;
    } else if (a == "--matchfinder" && hasNext) {
      opt.matchFinder = argv[++i];
    } else if (a == "--solid" && hasNext) {
      opt.solid = (strcmp(argv[++i], "on") == 0);
      opt.hasSolid = true;
    } else if (a == "--solidblock" && hasNext) {
      opt.solidBlock = argv[++i];
    } else if (a == "--fullpaths" && hasNext) {
      opt.fullPaths = (strcmp(argv[++i], "on") == 0);
    } else if (a == "--threads" && hasNext) {
      opt.threads = atoi(argv[++i]);
      opt.hasThreads = true;
    } else if (a == "--volume" && hasNext) {
      opt.volumeSize = ParseSize(argv[++i]);
      opt.hasVolumeSize = true;
    } else if (a == "--encryptmeth" && hasNext) {
      opt.encryptMethod = argv[++i];
    } else if (a == "--encryptheader" && hasNext) {
      opt.encryptHeader = (strcmp(argv[++i], "on") == 0);
      opt.hasEncryptHeader = true;
    } else if (a == "--compressheader" && hasNext) {
      opt.compressHeader = (strcmp(argv[++i], "on") == 0);
      opt.hasCompressHeader = true;
    } else if (a == "--verbose") {
      g_verbose = true;
    } else {
      inputs.push_back(a);
    }
  }

  opt.password = g_openPassword; // 由 main() 的全局 --password 提供

  ConsoleCallback cb;
  std::string err;
  const bool ok = create(inputs, dest, opt, &cb, err);
  if (!ok) {
    fprintf(stderr, "创建失败: %s\n", err.c_str());
    return 1;
  }
  printf("OK\n");
  return 0;
}

// 更新模式：向已有归档追加条目（技术方案 §5.1「更新模式」）
//   engine_test add <archive> <input>... [--replace on|off] [--level N] [--password P]
static int CmdAdd(int argc, char **argv) {
  if (argc < 4) {
    usage();
    return 1;
  }
  const std::string archivePath = argv[2];
  CompressionOptions opt;
  opt.format = "7z";
  bool replaceExisting = false;
  std::vector<std::string> inputs;

  for (int i = 3; i < argc; i++) {
    const std::string a = argv[i];
    const bool hasNext = (i + 1 < argc);
    if (a == "--replace" && hasNext) {
      replaceExisting = (strcmp(argv[++i], "on") == 0);
    } else if (a == "--level" && hasNext) {
      opt.level = atoi(argv[++i]);
    } else if (a == "--method" && hasNext) {
      opt.method = argv[++i];
    } else if (a == "--encryptheader" && hasNext) {
      opt.encryptHeader = (strcmp(argv[++i], "on") == 0);
      opt.hasEncryptHeader = true;
    } else if (a == "--fullpaths" && hasNext) {
      opt.fullPaths = (strcmp(argv[++i], "on") == 0);
    } else if (a == "--verbose") {
      g_verbose = true;
    } else {
      inputs.push_back(a);
    }
  }

  opt.password = g_openPassword; // 由 main() 的全局 --password 提供

  if (inputs.empty()) {
    usage();
    return 1;
  }

  ConsoleCallback cb;
  std::string err;
  Archive *a = Archive::Open(archivePath, &cb, err);
  if (!a) {
    fprintf(stderr, "打开失败: %s\n", err.c_str());
    return 1;
  }
  const bool ok = a->addItems(inputs, opt, replaceExisting, &cb, err);
  delete a;
  if (!ok) {
    fprintf(stderr, "更新失败: %s\n", err.c_str());
    return 1;
  }
  printf("OK\n");
  return 0;
}

// 删除模式：从已有归档移除条目（技术方案 §6.4）
//   engine_test remove <archive> <arcPath>... [--level N] [--method M] [--encryptheader on|off]
// 说明：删除走「解压保留项 → 重建 → 原子替换」路径，保留条目会按给定参数重新压缩。
//   容器格式**恒为原归档格式**（桥接层强制），故无 --format 选项。
//   密码由全局 --password 提供，同时用于打开与重新压缩。
static int CmdRemove(int argc, char **argv) {
  if (argc < 4) {
    usage();
    return 1;
  }
  const std::string archivePath = argv[2];
  CompressionOptions opt;
  std::vector<std::string> targets;

  for (int i = 3; i < argc; i++) {
    const std::string a = argv[i];
    const bool hasNext = (i + 1 < argc);
    if (a == "--level" && hasNext) {
      opt.level = atoi(argv[++i]);
    } else if (a == "--method" && hasNext) {
      opt.method = argv[++i];
    } else if (a == "--encryptheader" && hasNext) {
      opt.encryptHeader = (strcmp(argv[++i], "on") == 0);
      opt.hasEncryptHeader = true;
    } else if (a == "--verbose") {
      g_verbose = true;
    } else {
      targets.push_back(a);
    }
  }

  if (targets.empty()) {
    usage();
    return 1;
  }

  opt.password = g_openPassword; // 由 main() 的全局 --password 提供

  ConsoleCallback cb;
  std::string err;
  Archive *a = Archive::Open(archivePath, &cb, err);
  if (!a) {
    fprintf(stderr, "打开失败: %s\n", err.c_str());
    return 1;
  }
  const bool ok = a->removeItems(targets, opt, &cb, err);
  delete a;
  if (!ok) {
    fprintf(stderr, "删除失败: %s\n", err.c_str());
    return 1;
  }
  printf("OK\n");
  return 0;
}

static int CmdFormats() {
  std::vector<FormatInfo> formats;
  if (!listFormats(formats)) {
    fprintf(stderr, "无法枚举格式\n");
    return 1;
  }
  printf("%-14s %-8s %s\n", "名称", "可创建", "扩展名");
  for (size_t i = 0; i < formats.size(); i++)
    printf("%-14s %-8s %s\n", formats[i].name.c_str(), YesNo(formats[i].canUpdate),
           formats[i].extensions.c_str());
  printf("\n合计 %zu 种格式\n", formats.size());
  return 0;
}

// 全局选项预处理：把 --password P / --password=P 提取到 g_openPassword 并从 argv 中
// 移除（原地压缩，保持 argv[0] 不变）。这样位置参数式命令（list/test/extract…）
// 与选项式命令（create/add/remove）都能透明地使用同一个密码，
// 也避免了「打开归档」与「重新压缩」各要一个密码的割裂。
static void StripGlobalOptions(int &argc, char **argv) {
  int w = 1;
  for (int i = 1; i < argc; i++) {
    const std::string a = argv[i];
    if (a == "--password" && i + 1 < argc) {
      g_openPassword = argv[++i];
      continue;
    }
    if (a.rfind("--password=", 0) == 0) {
      g_openPassword = a.substr(11);
      continue;
    }
    argv[w++] = argv[i];
  }
  argc = w;
}

int main(int argc, char **argv) {
  StripGlobalOptions(argc, argv);
  if (argc < 2) {
    usage();
    return 1;
  }
  const std::string cmd = argv[1];

  if (cmd == "version") {
    printf("%s\n", engineVersion().c_str());
    return 0;
  }
  if (cmd == "formats") return CmdFormats();

  if (cmd == "dumpitems" && argc >= 3) return CmdDumpItems(argv[2]);
  if (cmd == "info" && argc >= 3) return CmdInfo(argv[2]);
  if (cmd == "list" && argc >= 3) return CmdList(argv[2]);
  if (cmd == "test" && argc >= 3) return CmdTest(argv[2]);
  if (cmd == "extract" && argc >= 4) {
    // 目标已存在时的策略，对应 7-Zip 的 -ao 系列；缺省沿用覆盖（与旧行为一致）。
    ClashPolicy clash = ClashPolicy::Overwrite;
    for (int i = 4; i < argc; i++) {
      if (strcmp(argv[i], "--overwrite") == 0) clash = ClashPolicy::Overwrite;
      else if (strcmp(argv[i], "--skip") == 0) clash = ClashPolicy::Skip;
      else if (strcmp(argv[i], "--rename") == 0) clash = ClashPolicy::Rename;
    }
    return CmdExtract(argv[2], argv[3], clash);
  }
  if (cmd == "extractone" && argc >= 5) return CmdExtractOne(argv[2], (unsigned)atoi(argv[3]), argv[4]);
  if (cmd == "extractmem" && argc >= 5)
    return CmdExtractMem(argv[2], (unsigned)atoi(argv[3]), ParseSize(argv[4]));
  if (cmd == "create") return CmdCreate(argc, argv);
  if (cmd == "add") return CmdAdd(argc, argv);
  if (cmd == "remove") return CmdRemove(argc, argv);

  usage();
  return 1;
}
