// mini_rar.h — 测试用最小 RAR4 归档（store 方法）合成器
//
// 为什么要在测试里合成 RAR 而不用现成样本：
//   `IInArchive::Extract` 的索引数组必须按升序排列。各归档处理器里只有 RAR 把
//   这一前提写成了硬依赖 —— RarHandler::Extract / Rar5Handler::Extract 用
//   `lastIndex` 把相邻条目合并成固实块（`for (j = lastIndex; j <= index; j++)`，
//   之后 `lastIndex = index + 1`）；一旦传入的索引递减，区间为空循环，条目被
//   **静默跳过**，函数仍返回 S_OK。症状是「解压成功、无任何错误，磁盘上只剩
//   目录」。
//   而 7z / zip / tar 处理器对顺序不敏感（实测倒序也全量落盘），所以拿它们当
//   夹具的门禁**永远不会红**，等于没测。RAR 又是本机唯一无法生成的格式
//   （7-Zip 不含 RAR 编码器），因此这里直接在测试进程里合成字节流。
//
// 布局刻意复刻真机归档（如 WinRAR 产物）的形态：**文件条目在前、目录条目在后**，
// 这样「从条目树做后进先出遍历」得到的索引序列天然是倒序，最能命中该缺陷。
//
// 归档内容（索引即写入顺序）：
//   0  Audio/Alarms/one.bin      文件  4 字节 "one\n"
//   1  Audio/Ringtones/two.bin   文件  4 字节 "two\n"
//   2  Audio/root.bin            文件  5 字节 "root\n"
//   3  Audio/Alarms              目录
//   4  Audio/Ringtones           目录
//   5  Audio                     目录
//
// 字节布局取自 RAR 4.x 规范，并与 7-Zip 的 Archive/Rar/RarHeader.h 逐字段核对：
//   标记块   7 字节  52 61 72 21 1A 07 00
//   主头     13 字节 CRC(2) TYPE(1)=0x73 FLAGS(2) SIZE(2)=13 RESERVED(6)
//   文件头   32+NAME  CRC(2) TYPE(1)=0x74 FLAGS(2) SIZE(2)
//                     PACK_SIZE(4) UNP_SIZE(4) HOST_OS(1) FILE_CRC(4) MTIME(4)
//                     UNP_VER(1) METHOD(1) NAME_SIZE(2) ATTR(4) NAME(...)
//   结束块   7 字节  TYPE(1)=0x7B
// HEAD_CRC 是「自 HEAD_TYPE 起至块尾」的 CRC32 低 16 位（与 CInArchive::CheckHeaderCrc
// 的 `Get16(header) == CrcCalc(header + 2, headerSize - 2) & 0xFFFF` 一致）。
// 目录用 kHostWin32(2) + FILE_ATTRIBUTE_DIRECTORY(0x10) 标记，文件用 0x20（档案位），
// 与真实归档的 `D....` / `....A` 属性显示一致。

#ifndef Z7_TEST_MINI_RAR_H
#define Z7_TEST_MINI_RAR_H

#include <stdio.h>
#include <string.h>
#include <stdint.h>

// 夹具内容：3 个文件 + 3 个目录 = 6 个条目
#define Z7TEST_RAR_ITEM_COUNT 6
#define Z7TEST_RAR_FILE_COUNT 3

// 期望落盘的相对路径与内容（下标一一对应）
static const char *const Z7TestRarFilePaths[Z7TEST_RAR_FILE_COUNT] = {
  "Audio/Alarms/one.bin",
  "Audio/Ringtones/two.bin",
  "Audio/root.bin",
};
static const char *const Z7TestRarFileData[Z7TEST_RAR_FILE_COUNT] = {
  "one\n",
  "two\n",
  "root\n",
};

// 桥接层条目表里的索引：0..5。倒序遍历即 5,4,3,2,1,0
// （真机上表现为「只剩目录、文件全丢」）。
#define Z7TEST_RAR_NUM_ITEMS 6

static uint32_t Z7TestRarCrc32(const uint8_t *p, size_t n) {
  uint32_t crc = 0xFFFFFFFFu;
  for (size_t i = 0; i < n; i++) {
    crc ^= p[i];
    for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
  }
  return ~crc;
}

// 把块体（自 HEAD_TYPE 起）补上 HEAD_CRC 写到 out，返回写入的字节数。
static size_t Z7TestRarEmitBlock(FILE *f, const uint8_t *body, size_t bodyLen) {
  const uint16_t crc = (uint16_t)(Z7TestRarCrc32(body, bodyLen) & 0xFFFFu);
  const uint8_t lo = (uint8_t)(crc & 0xFFu), hi = (uint8_t)(crc >> 8);
  fwrite(&lo, 1, 1, f);
  fwrite(&hi, 1, 1, f);
  fwrite(body, 1, bodyLen, f);
  return bodyLen + 2;
}

static void Z7TestRarPut16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void Z7TestRarPut32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8);
  p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

static void Z7TestRarMainHeader(uint8_t *b) {
  b[0] = 0x73;                  // TYPE = kArchiveHeader
  Z7TestRarPut16(b + 1, 0);     // FLAGS
  Z7TestRarPut16(b + 3, 13);    // SIZE
  Z7TestRarPut16(b + 5, 0);     // RESERVED1
  Z7TestRarPut32(b + 7, 0);     // RESERVED2
}

// name：归档内路径（不含前导斜杠）。dir 为真时只写头不写数据。
static size_t Z7TestRarFileHeader(uint8_t *b, const char *name, const char *data, int isDir) {
  const size_t nameLen = strlen(name);
  const uint32_t dataLen = isDir ? 0u : (uint32_t)strlen(data);
  const size_t bodyLen = 30 + nameLen;   // 自 TYPE 起（含 TYPE，不含 HEAD_CRC 两字节）
  const size_t headSize = bodyLen + 2;   // 块总长含 HEAD_CRC

  b[0] = 0x74;                            // TYPE = kFileHeader
  Z7TestRarPut16(b + 1, 0);               // FLAGS（不置固实位）
  Z7TestRarPut16(b + 3, (uint16_t)headSize);  // SIZE
  Z7TestRarPut32(b + 5, dataLen);         // PACK_SIZE
  Z7TestRarPut32(b + 9, dataLen);         // UNP_SIZE
  b[13] = 2;                              // HOST_OS = kHostWin32
  Z7TestRarPut32(b + 14, isDir ? 0u : Z7TestRarCrc32((const uint8_t *)data, dataLen));
  // 2013-06-14 03:22:52 的 DOS 时间戳（(.CE1ADA)）
  Z7TestRarPut32(b + 18, 0x42CE1ADAu);
  b[22] = 29;                             // UNP_VER（>=20 走 item.IsSolid()）
  b[23] = 0x30;                           // METHOD = '0' store
  Z7TestRarPut16(b + 24, (uint16_t)nameLen);
  Z7TestRarPut32(b + 26, isDir ? 0x10u : 0x20u);
  memcpy(b + 30, name, nameLen);
  return bodyLen;
}

static void Z7TestRarEndArc(uint8_t *b) {
  b[0] = 0x7B;                  // TYPE = kEndOfArchive
  Z7TestRarPut16(b + 1, 0);     // FLAGS
  Z7TestRarPut16(b + 3, 7);     // SIZE
}

// 写出夹具。成功返回 0，失败返回 -1。
static int Z7TestWriteMiniRar(const char *path) {
  static const uint8_t kMarker[7] = { 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00 };
  FILE *f = fopen(path, "wb");
  if (!f) return -1;
  fwrite(kMarker, 1, sizeof(kMarker), f);

  uint8_t body[64];
  Z7TestRarMainHeader(body);
  Z7TestRarEmitBlock(f, body, 11);

  // 文件在前、目录在后：与真机归档一致，保证树遍历序是倒序
  uint8_t fh[512];
  size_t n;
  n = Z7TestRarFileHeader(fh, "Audio/Alarms/one.bin", "one\n", 0);
  Z7TestRarEmitBlock(f, fh, n);
  fwrite("one\n", 1, 4, f);

  n = Z7TestRarFileHeader(fh, "Audio/Ringtones/two.bin", "two\n", 0);
  Z7TestRarEmitBlock(f, fh, n);
  fwrite("two\n", 1, 4, f);

  n = Z7TestRarFileHeader(fh, "Audio/root.bin", "root\n", 0);
  Z7TestRarEmitBlock(f, fh, n);
  fwrite("root\n", 1, 5, f);

  n = Z7TestRarFileHeader(fh, "Audio/Alarms", "", 1);
  Z7TestRarEmitBlock(f, fh, n);

  n = Z7TestRarFileHeader(fh, "Audio/Ringtones", "", 1);
  Z7TestRarEmitBlock(f, fh, n);

  n = Z7TestRarFileHeader(fh, "Audio", "", 1);
  Z7TestRarEmitBlock(f, fh, n);

  Z7TestRarEndArc(body);
  Z7TestRarEmitBlock(f, body, 5);

  return fclose(f) == 0 ? 0 : -1;
}

#endif  // Z7_TEST_MINI_RAR_H
