// Z7IsoWriter.cpp — 自研 ISO9660 (Level 2) + Joliet (Level 3) 镜像写入器
//
// 完整按 ECMA-119 写二进制镜像，不依赖任何第三方库，也不派生子进程。
// 详见 Z7IsoWriter.h 的设计说明。

#include "Z7IsoWriter.h"

#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cstdlib>
#include <ctime>
#include <string>
#include <vector>
#include <map>
#include <algorithm>

#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <unistd.h>

#include "SevenZipEngine.h"  // z7::Callback / LogLevel

namespace z7 {
namespace iso {

static const uint32_t SECTOR = 2048;

// ---------------------------------------------------------------------------
// 目录树节点
// ---------------------------------------------------------------------------
struct Node {
  std::string rawName;    // 原始（UTF-8）名字，仅用于确定性的排序/去重
  std::string joliet;     // UTF-16BE 文件名（≤64 字符，无版本号），仅存这个名字
  bool isDir = false;
  bool skipped = false;   // 符号链接/设备等不写入 ISO 的条目
  std::string src;        // 源文件路径（文件用）
  uint64_t size = 0;      // 文件大小
  uint32_t extent = 0;    // 起始扇区（目录记录 / 文件数据）
  uint32_t dirBytes = 0;  // 目录记录块字节数（仅目录）
  int dirNo = 0;          // 路径表中的目录编号（根=1）
  std::vector<Node> children;
};

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------
static void putLE(uint8_t *b, uint32_t off, uint64_t v, int n) {
  for (int i = 0; i < n; i++) b[off + i] = (uint8_t)((v >> (8 * i)) & 0xFF);
}
static void putBE(uint8_t *b, uint32_t off, uint64_t v, int n) {
  for (int i = 0; i < n; i++) b[off + n - 1 - i] = (uint8_t)((v >> (8 * i)) & 0xFF);
}

// UTF-8 -> UTF-16BE。非法序列按 U+FFFD 处理（简化：跳过或替换）。
static std::string utf8ToUtf16BE(const std::string &s) {
  std::string out;
  size_t i = 0, n = s.size();
  while (i < n) {
    uint32_t cp = 0;
    int extra = 0;
    unsigned char c = (unsigned char)s[i];
    if (c < 0x80) { cp = c; extra = 0; }
    else if ((c & 0xE0) == 0xC0) { cp = c & 0x1F; extra = 1; }
    else if ((c & 0xF0) == 0xE0) { cp = c & 0x0F; extra = 2; }
    else if ((c & 0xF8) == 0xF0) { cp = c & 0x07; extra = 3; }
    else { i++; continue; }  // 非法首字节，跳过
    i++;
    bool ok = true;
    for (int k = 0; k < extra; k++) {
      if (i >= n) { ok = false; break; }
      unsigned char d = (unsigned char)s[i++];
      if ((d & 0xC0) != 0x80) { ok = false; break; }
      cp = (cp << 6) | (d & 0x3F);
    }
    if (!ok) continue;
    if (cp > 0xFFFF) cp = 0xFFFD;  // Joliet 仅 BMP
    out.push_back((char)(cp >> 8));
    out.push_back((char)(cp & 0xFF));
  }
  return out;
}

// 卷标：大写 ASCII，非 [A-Z0-9 _] 换成 '_'，截断到 maxBytes 字节。
static std::string isoVolumeId(const std::string &s, size_t maxBytes) {
  std::string out;
  for (size_t i = 0; i < s.size() && out.size() < maxBytes; i++) {
    unsigned char c = (unsigned char)s[i];
    if (c >= 'a' && c <= 'z') c = (unsigned char)(c - 'a' + 'A');
    if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == ' ' || c == '_')
      out.push_back((char)c);
    else
      out.push_back('_');
  }
  while (out.size() < maxBytes) out.push_back(' ');
  out.resize(maxBytes);
  return out;
}

// 文件名（不含路径）抽取末段
static std::string basenameOf(const std::string &p) {
  size_t s = p.find_last_of('/');
  return (s == std::string::npos) ? p : p.substr(s + 1);
}

static bool isMacJunk(const std::string &name) {
  if (name == ".DS_Store" || name == "__MACOSX" || name == ".VolumeIcon.icns")
    return true;
  if (name.size() >= 2 && name[0] == '.' && name[1] == '_') return true;  // ._xxx
  return false;
}

// ---------------------------------------------------------------------------
// 收集文件系统树
// ---------------------------------------------------------------------------
static bool collect(const std::string &realPath, Node &node, bool excludeMacJunk,
                    std::string &error) {
  struct stat st;
  if (lstat(realPath.c_str(), &st) != 0) {
    error = "无法访问：" + realPath;
    return false;
  }
  if (S_ISLNK(st.st_mode)) {
    // 符号链接：不做成 ISO 条目（基础 ISO9660 无链接语义），跳过
    node.skipped = true;
    return true;
  }
  if (S_ISDIR(st.st_mode)) {
    node.isDir = true;
    DIR *d = opendir(realPath.c_str());
    if (!d) { error = "无法打开目录：" + realPath; return false; }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
      std::string nm = e->d_name;
      if (nm == "." || nm == "..") continue;
      if (excludeMacJunk && isMacJunk(nm)) continue;
      Node child;
      child.rawName = nm;
      std::string full = realPath + "/" + nm;
      if (!collect(full, child, excludeMacJunk, error)) { closedir(d); return false; }
      if (child.skipped) continue;
      node.children.push_back(std::move(child));
    }
    closedir(d);
  } else if (S_ISREG(st.st_mode)) {
    node.isDir = false;
    node.src = realPath;
    node.size = (uint64_t)st.st_size;
  } else {
    // 设备/管道等：忽略
    node.skipped = true;
  }
  return true;
}

// ---------------------------------------------------------------------------
// 命名：在每个父目录下分配不冲突的 Joliet 名（UTF-16，≤64 字符）
// ---------------------------------------------------------------------------
static std::string makeJolietName(const std::string &utf8Name) {
  std::string u = utf8ToUtf16BE(utf8Name);
  // 截断到 ≤64 字符 = 128 字节
  if (u.size() > 128) u.resize(128);
  return u;
}

static bool byRawName(const Node &a, const Node &b) { return a.rawName < b.rawName; }
static bool byJoliet(const Node &a, const Node &b) { return a.joliet < b.joliet; }

static void assignNames(Node &node) {
  // 先按「原始名」排序：readdir 顺序随机，而重名去重的后缀（_2/_3…）按遍历顺序
  // 分配，不排序会导致同一输入每次产出不同的 ISO 字节。
  std::sort(node.children.begin(), node.children.end(), byRawName);

  std::map<std::string, int> used;  // joliet 字节串 -> 已占用
  for (size_t i = 0; i < node.children.size(); i++) {
    Node &c = node.children[i];
    std::string base = makeJolietName(c.rawName);
    if (base.empty()) base = makeJolietName("file");
    std::string cand = base;
    int suffix = 2;
    while (used.find(cand) != used.end()) {
      // 在截断预算内追加 "_N"
      std::string num = "_" + std::to_string(suffix++);
      std::string numU = utf8ToUtf16BE(num);
      size_t keep = cand.size();
      if (keep + numU.size() > 128) keep = (keep > numU.size()) ? keep - numU.size() : 0;
      cand = cand.substr(0, keep) + numU;
    }
    used[cand] = 1;
    c.joliet = cand;
  }

  // ECMA-119 9.3：同一目录内的目录记录须按文件标识符升序排列（"." 与 ".." 由
  // 写入方固定置于最前，不参与排序）。UTF-16BE 的逐字节比较对 BMP 等价于按码位
  // 比较；ASCII 名则退化为普通 ASCII 序。严格读取器（如 Windows CDFS）会做二分
  // 查找，顺序不对可能查不到文件。
  std::sort(node.children.begin(), node.children.end(), byJoliet);

  for (size_t i = 0; i < node.children.size(); i++) assignNames(node.children[i]);
}

// ---------------------------------------------------------------------------
// 计算目录记录块大小（33 + 名字字节，每条补齐到偶数字节；"."=34, ".."=36）
// ---------------------------------------------------------------------------
static uint32_t recordLen(uint32_t nameBytes) {
  uint32_t len = 33 + nameBytes;
  if (len & 1) len++;
  return len;
}

// 目录记录不允许跨越扇区边界；若一条记录会跨界，先用 0 填满当前扇区。
// 返回放下该记录后的新偏移。
static uint32_t placeRecord(uint32_t off, uint32_t recLen) {
  if ((off % SECTOR) + recLen > SECTOR) off = ((off / SECTOR) + 1) * SECTOR;
  return off + recLen;
}

static void computeSizes(Node &node) {
  for (size_t i = 0; i < node.children.size(); i++)
    if (node.children[i].isDir) computeSizes(node.children[i]);
  // "." 与 ".." 是**单字节**标识符：ECMA-119 规定当前目录用 0x00、父目录用
  // 0x01（不是 UTF-16 的 "."/".."）。7-Zip 的 IsSystemItem() 正是靠
  // 「长度==1 且字节<2」识别它们；写成 UTF-16 会让 7-Zip 把 "." 当成真目录去
  // 递归，从而报「Self-linked directory」。这里必须与实际写入一致。
  uint32_t off = 0;
  off = placeRecord(off, recordLen(1));  // "."  -> 0x00
  off = placeRecord(off, recordLen(1));  // ".." -> 0x01
  for (size_t i = 0; i < node.children.size(); i++)
    off = placeRecord(off, recordLen((uint32_t)node.children[i].joliet.size()));
  node.dirBytes = off;
}

// ---------------------------------------------------------------------------
// 布局：目录顺序与扇区分配
//   ECMA-119 6.9.1 要求路径表条目按「目录层级 -> 父目录编号 -> 目录标识符」升序；
//   这里用真 BFS 得到层序，再在每一层内按 (父目录号, 名字) 排序并重新编号。
//   父目录总在更小的层，因此处理到第 L 层时其父编号已是最终值。
// ---------------------------------------------------------------------------
static void orderDirs(const Node &root, std::vector<const Node *> &out,
                      std::map<const Node *, const Node *> &parentOf,
                      std::vector<int> &level) {
  out.clear(); parentOf.clear(); level.clear();
  out.push_back(&root);
  level.push_back(1);
  for (size_t h = 0; h < out.size(); h++) {
    const Node *d = out[h];
    for (size_t i = 0; i < d->children.size(); i++) {
      const Node &c = d->children[i];
      if (!c.isDir) continue;
      parentOf[&c] = d;
      out.push_back(&c);
      level.push_back(level[h] + 1);
    }
  }
  size_t k = 0;
  int no = 1;
  while (k < out.size()) {
    size_t end = k;
    while (end < out.size() && level[end] == level[k]) end++;
    // 层内排序不会改变该区间的层级值，故并行的 level 数组仍然有效
    std::sort(out.begin() + k, out.begin() + end,
              [&](const Node *a, const Node *b) {
                std::map<const Node *, const Node *>::const_iterator ia = parentOf.find(a);
                int na = (ia == parentOf.end()) ? 0 : ia->second->dirNo;
                std::map<const Node *, const Node *>::const_iterator ib = parentOf.find(b);
                int nb = (ib == parentOf.end()) ? 0 : ib->second->dirNo;
                if (na != nb) return na < nb;
                return a->joliet < b->joliet;
              });
    for (size_t j = k; j < end; j++) const_cast<Node *>(out[j])->dirNo = no++;
    k = end;
  }
}

static void collectFilesBFS(const Node &node, std::vector<const Node *> &out) {
  for (size_t i = 0; i < node.children.size(); i++) {
    const Node &c = node.children[i];
    if (c.isDir) collectFilesBFS(c, out);
    else out.push_back(&c);
  }
}

// 写一条目录记录到 buf（从 *off 起，返回后 *off 推进）。name 为 UTF-16 字节。
static void writeDirRecord(uint8_t *buf, uint32_t &off, const std::string &name,
                          uint32_t extent, uint32_t size, bool isDir) {
  uint32_t nb = (uint32_t)name.size();
  uint32_t len = recordLen(nb);
  if ((off % SECTOR) + len > SECTOR) {
    uint32_t pad = SECTOR - (off % SECTOR);
    memset(buf + off, 0, pad);
    off += pad;
  }
  uint32_t start = off;
  buf[off++] = (uint8_t)len;
  buf[off++] = 0;  // extended attribute length
  putLE(buf, off, extent, 4); off += 4;
  putBE(buf, off, extent, 4); off += 4;
  putLE(buf, off, size, 4); off += 4;
  putBE(buf, off, size, 4); off += 4;
  memset(buf + off, 0, 7); off += 7;          // recording date/time（含时区，共 7 字节）
  buf[off++] = isDir ? 0x02 : 0x00;             // file flags
  buf[off++] = 0;                               // file unit size
  buf[off++] = 0;                               // interleave gap size
  putLE(buf, off, 1, 2); off += 2;             // volume sequence (LE)
  putBE(buf, off, 1, 2); off += 2;             // volume sequence (BE)
  buf[off++] = (uint8_t)nb;                     // file identifier length
  for (uint32_t k = 0; k < nb; k++) buf[off++] = (uint8_t)name[k];
  if ((off - start) & 1) buf[off++] = 0;        // 补齐到偶数
}

// 路径表条目字节长度（不含 buf 写操作，供布局预计算用）
static uint32_t pathEntryLen(const std::string &name) {
  uint32_t nb = (uint32_t)name.size();
  uint32_t len = 1 + 1 + 4 + 2 + (nb == 0 ? 1 : nb);
  if (len & 1) len++;
  return len;
}

// 写一条路径表条目（dir 的 UTF-16 名，parent 为目录编号）
static void writePathEntry(uint8_t *buf, uint32_t &off, const std::string &name,
                           uint32_t extent, uint16_t parent, bool bigEndian) {
  uint32_t nb = (uint32_t)name.size();
  buf[off++] = (uint8_t)(nb == 0 ? 1 : nb);  // 根目录标识符长度（空 -> 1 + 0x00）
  buf[off++] = 0;                             // extended attribute length
  if (bigEndian) { putBE(buf, off, extent, 4); off += 4; putBE(buf, off, parent, 2); off += 2; }
  else          { putLE(buf, off, extent, 4); off += 4; putLE(buf, off, parent, 2); off += 2; }
  if (nb == 0) buf[off++] = 0;                // 根：一个 0x00 标识符（len=1）
  else for (uint32_t k = 0; k < nb; k++) buf[off++] = (uint8_t)name[k];
  if ((off & 1) == 1) buf[off++] = 0;         // 补齐到偶数
}

// 写 34 字节的卷描述符内嵌根目录记录（名字为单字节 "."）
static void writeRootRecord(uint8_t *vd, uint32_t extent, uint32_t size) {
  uint32_t off = 156;
  vd[off++] = 34;
  vd[off++] = 0;
  putLE(vd, off, extent, 4); off += 4;
  putBE(vd, off, extent, 4); off += 4;
  putLE(vd, off, size, 4); off += 4;
  putBE(vd, off, size, 4); off += 4;
  memset(vd + off, 0, 7); off += 7;  // date/time（含时区）
  vd[off++] = 0x02;  // directory flag
  vd[off++] = 0;
  vd[off++] = 0;
  putLE(vd, off, 1, 2); off += 2;
  putBE(vd, off, 1, 2); off += 2;
  vd[off++] = 1;     // identifier length
  vd[off++] = 0x00;  // 根目录记录标识符为单字节 0x00（同 "."）
}

// 写卷描述符头部公共部分
static void writeVDHead(uint8_t *vd, uint8_t type, bool joliet,
                       const std::string &volId, uint32_t volSpace,
                       uint32_t pathTableSize, uint32_t lPath, uint32_t mPath,
                       uint32_t rootExtent, uint32_t rootSize) {
  memset(vd, 0, SECTOR);
  vd[0] = type;
  memcpy(vd + 1, "CD001", 5);
  vd[6] = 1;  // version
  // 8-39 system identifier（留空）
  // 40-71 volume identifier
  if (joliet) {
    std::string u = utf8ToUtf16BE(volId);
    if (u.size() > 32) u.resize(32);
    for (size_t k = 0; k < 32; k++)
      vd[40 + k] = (k < u.size()) ? (uint8_t)u[k] : (k % 2 == 0 ? 0x20 : 0x00);
  } else {
    std::string a = isoVolumeId(volId, 32);
    memcpy(vd + 40, a.c_str(), 32);
  }
  // 80-87 volume space size
  putLE(vd, 80, volSpace, 4); putBE(vd, 84, volSpace, 4);
  if (joliet) { vd[88] = 0x25; vd[89] = 0x2F; vd[90] = 0x45; }  // Joliet level 3 escape
  // 120-123 volume set size（=1）
  putLE(vd, 120, 1, 2); putBE(vd, 122, 1, 2);
  // 124-127 volume sequence number（=1）
  putLE(vd, 124, 1, 2); putBE(vd, 126, 1, 2);
  // 128-131 logical block size（=2048）
  putLE(vd, 128, SECTOR, 2); putBE(vd, 130, SECTOR, 2);
  // 132-139 path table size
  putLE(vd, 132, pathTableSize, 4); putBE(vd, 136, pathTableSize, 4);
  // 140-143 type L path table（LE）；144-147 可选 L（LE，置 0）
  putLE(vd, 140, lPath, 4);
  putLE(vd, 144, 0, 4);
  // 148-151 type M path table（BE）；152-155 可选 M（BE，置 0）
  // 注意顺序是 L / L-opt / M / M-opt —— 写错位置 7-Zip 会把 M 当 L-opt 读成
  // 一个越界扇区号，直接判「Cannot open the file as archive」。
  putBE(vd, 148, mPath, 4);
  putBE(vd, 152, 0, 4);
  // 156-189 根目录记录
  writeRootRecord(vd, rootExtent, rootSize);
  // 813-829 / 830-846 创建/修改日期（17 字节 "YYYYMMDDHHMMSS00\0"）
  time_t t = time(NULL);
  struct tm tm;
#if defined(__APPLE__)
  localtime_r(&t, &tm);
#else
  localtime_s(&tm, &t);
#endif
  char dateStr[18];
  snprintf(dateStr, sizeof(dateStr), "%04d%02d%02d%02d%02d%02d00",
           tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
           tm.tm_hour, tm.tm_min, tm.tm_sec);
  memcpy(vd + 813, dateStr, 16);  // 16 位 ASCII + 末尾 1 字节 tz(0)
  memcpy(vd + 830, dateStr, 16);
}

// ---------------------------------------------------------------------------
// 主入口
// ---------------------------------------------------------------------------
bool CreateIso(const std::vector<std::string> &utf8InputPaths,
               const std::string &utf8DestArchive, const std::string &volumeName,
               bool excludeMacJunk, Callback *cb, std::string &error) {
  error.clear();
  if (utf8InputPaths.empty()) { error = "没有待打包的输入"; return false; }

  // 1. 收集目录树（根节点）
  Node root;
  root.isDir = true;
  root.joliet = "";  // 根无名字
  for (size_t i = 0; i < utf8InputPaths.size(); i++) {
    Node child;
    child.rawName = basenameOf(utf8InputPaths[i]);
    if (!collect(utf8InputPaths[i], child, excludeMacJunk, error)) return false;
    if (child.skipped) continue;
    root.children.push_back(std::move(child));
  }
  if (root.children.empty()) { error = "没有可打包的条目"; return false; }

  // 2. 命名（Joliet）——顺带把每个目录的子项排成规范序
  assignNames(root);

  // 3. 目录大小
  computeSizes(root);

  // 4. 布局（目录按规范序编号；再依次分配扇区）
  std::vector<const Node *> dirs;
  std::map<const Node *, const Node *> parentOf;
  std::vector<int> level;
  orderDirs(root, dirs, parentOf, level);
  std::vector<const Node *> files;
  collectFilesBFS(root, files);

  uint32_t sec = 19;  // 0-15 系统区, 16 PVD, 17 SVD, 18 terminator
  // 路径表（先算大小，再定扇区）
  uint32_t pathTableSize = 0;
  {
    for (size_t i = 0; i < dirs.size(); i++) {
      std::string nm = (i == 0) ? std::string() : dirs[i]->joliet;
      pathTableSize += pathEntryLen(nm);
    }
  }
  uint32_t lPath = sec; sec += (pathTableSize + SECTOR - 1) / SECTOR;
  uint32_t mPath = sec; sec += (pathTableSize + SECTOR - 1) / SECTOR;
  // 目录
  for (size_t i = 0; i < dirs.size(); i++) {
    const_cast<Node *>(dirs[i])->extent = sec;
    sec += (dirs[i]->dirBytes + SECTOR - 1) / SECTOR;
  }
  // 文件
  for (size_t i = 0; i < files.size(); i++) {
    const_cast<Node *>(files[i])->extent = sec;
    sec += (files[i]->size + SECTOR - 1) / SECTOR;
  }
  uint32_t totalSectors = sec;

  // 5. 写文件
  FILE *f = fopen(utf8DestArchive.c_str(), "wb");
  if (!f) { error = "无法创建 ISO 文件：" + utf8DestArchive; return false; }

  uint8_t zero[SECTOR];
  memset(zero, 0, SECTOR);

  // 系统区（16 扇区）
  for (int i = 0; i < 16; i++) fwrite(zero, 1, SECTOR, f);

  // 卷标
  std::string volId = volumeName;
  if (volId.empty()) {
    std::string b = basenameOf(utf8DestArchive);
    size_t dot = b.find_last_of('.');
    if (dot != std::string::npos) b = b.substr(0, dot);
    volId = b;
  }

  // PVD
  uint8_t pvd[SECTOR];
  writeVDHead(pvd, 1, false, volId, totalSectors, pathTableSize, lPath, mPath,
              root.extent, root.dirBytes);
  fwrite(pvd, 1, SECTOR, f);

  // SVD（Joliet）
  uint8_t svd[SECTOR];
  writeVDHead(svd, 2, true, volId, totalSectors, pathTableSize, lPath, mPath,
              root.extent, root.dirBytes);
  fwrite(svd, 1, SECTOR, f);

  // 卷描述符集终结符
  uint8_t term[SECTOR];
  memset(term, 0, SECTOR);
  term[0] = 255; memcpy(term + 1, "CD001", 5); term[6] = 1;
  fwrite(term, 1, SECTOR, f);

  // 路径表中「父目录编号」：根指向自身（1），其余指向上一层目录的编号。
  // 注意不能写自身编号 —— 那会让每个目录在路径表里自指，破坏层级重建。
  auto parentNoOf = [&](const Node *d) -> uint16_t {
    if (d == &root) return 1;
    std::map<const Node *, const Node *>::const_iterator it = parentOf.find(d);
    return (it == parentOf.end()) ? (uint16_t)1 : (uint16_t)it->second->dirNo;
  };

  // 路径表 L
  {
    uint8_t *pt = new uint8_t[pathTableSize];
    uint32_t off = 0;
    for (size_t i = 0; i < dirs.size(); i++) {
      std::string nm = (i == 0) ? std::string() : dirs[i]->joliet;
      writePathEntry(pt, off, nm, dirs[i]->extent, parentNoOf(dirs[i]), false);
    }
    fwrite(pt, 1, pathTableSize, f);
    delete[] pt;
    // 补齐到扇区
    uint32_t pad = SECTOR - (pathTableSize % SECTOR);
    if (pad != SECTOR) fwrite(zero, 1, pad, f);
  }
  // 路径表 M
  {
    uint8_t *pt = new uint8_t[pathTableSize];
    uint32_t off = 0;
    for (size_t i = 0; i < dirs.size(); i++) {
      std::string nm = (i == 0) ? std::string() : dirs[i]->joliet;
      writePathEntry(pt, off, nm, dirs[i]->extent, parentNoOf(dirs[i]), true);
    }
    fwrite(pt, 1, pathTableSize, f);
    delete[] pt;
    uint32_t pad = SECTOR - (pathTableSize % SECTOR);
    if (pad != SECTOR) fwrite(zero, 1, pad, f);
  }

  // 目录数据（按 BFS 顺序，与 extent 一致）
  for (size_t i = 0; i < dirs.size(); i++) {
    const Node *d = dirs[i];
    uint32_t cap = ((d->dirBytes + SECTOR - 1) / SECTOR) * SECTOR;
    uint8_t *buf = new uint8_t[cap];
    memset(buf, 0, cap);
    uint32_t off = 0;
    // "." 指向自身（单字节 0x00）
    writeDirRecord(buf, off, std::string("\x00", 1), d->extent, d->dirBytes, true);
    // ".." 指向父（根指向自身），单字节 0x01
    uint32_t parentExtent = root.extent, parentSize = root.dirBytes;
    if (d != &root) {
      bool found = false;
      for (size_t k = 0; k < dirs.size() && !found; k++)
        for (size_t c = 0; c < dirs[k]->children.size(); c++)
          if (&dirs[k]->children[c] == d) {
            parentExtent = dirs[k]->extent; parentSize = dirs[k]->dirBytes; found = true; break;
          }
    }
    writeDirRecord(buf, off, std::string("\x01", 1), parentExtent, parentSize, true);
    for (size_t c = 0; c < d->children.size(); c++) {
      const Node &ch = d->children[c];
      writeDirRecord(buf, off, ch.joliet, ch.extent,
                     ch.isDir ? ch.dirBytes : (uint32_t)ch.size, ch.isDir);
    }
    fwrite(buf, 1, cap, f);
    delete[] buf;
  }

  // 文件数据（按 BFS 顺序）
  for (size_t i = 0; i < files.size(); i++) {
    const Node *fl = files[i];
    uint32_t cap = ((fl->size + SECTOR - 1) / SECTOR) * SECTOR;
    if (fl->size > 0) {
      FILE *sf = fopen(fl->src.c_str(), "rb");
      if (!sf) {
        fclose(f);
        error = "无法读取输入文件：" + fl->src;
        return false;
      }
      const size_t BUF = 1 << 16;
      uint8_t *buf = new uint8_t[BUF];
      uint64_t remaining = fl->size;
      while (remaining > 0) {
        size_t want = (size_t)std::min<uint64_t>(remaining, BUF);
        size_t got = fread(buf, 1, want, sf);
        if (got == 0) break;
        fwrite(buf, 1, got, f);
        remaining -= got;
      }
      delete[] buf;
      fclose(sf);
      uint64_t written = fl->size - remaining;
      uint64_t pad = cap - written;
      if (pad > 0 && pad < SECTOR) fwrite(zero, 1, pad, f);
    }
    // 零长度文件：cap=0，不写
  }

  fclose(f);

  if (cb) cb->OnLog(LogLevel::Info,
                    std::string("ISO 创建完成：") + std::to_string(totalSectors) + " 扇区");
  return true;
}

}  // namespace iso
}  // namespace z7
