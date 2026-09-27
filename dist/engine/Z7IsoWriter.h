// Z7IsoWriter.h — 自研 ISO9660 光盘镜像写入器（含 Joliet 补充卷描述符）
//
// 为什么自己写而不是调系统工具：
//   本项目硬性约束是「主程序不派生子进程」（make appcheck 双向断言），
//   而 macOS 上没有进程内的 ISO 生成库。dmgsm 这类只能做 DMG，做不了 ISO。
//   因此 ISO 创建必须自己按 ECMA-119 写二进制镜像——这是唯一能在进程内完成、
//   且不破坏零子进程原则的做法。DMG 因为 Apple 专有、无进程内等价物，才破例
//   调 hdiutil（见 Z7DmgWriter）。
//
// 能力范围（与上游 7-Zip 的差异即本文件价值）：
//   * 上游 7-Zip 26.03 完全没有「创建 ISO」的能力——它只能读 ISO（作为磁盘
//     映像 handler）。这里补上创建。
//   * 输出同时带 Primary Volume Descriptor（ISO9660 Level 2）与 Supplemental
//     Volume Descriptor（Joliet Level 3，UTF-16 长文件名），macOS / Windows /
//     现代 Linux 均按 Joliet 读取，文件名保留原始大小写与 Unicode。
//   * 不含 Rock Ridge（macOS 的 ISO 驱动不依赖它），文件名权限按只读默认值处理。
//
// 实现要点：
//   * 目录记录与路径表统一存 UTF-16BE（Joliet 风格）；Primary VD 的卷标用
//     大写 ASCII（≤32 字节），Supplemental VD 的卷标用 UTF-16（≤16 字符）。
//   * 这是 mkisofs -J 的标准做法：两套 VD 指向同一份目录/路径表，文件名以
//     UTF-16 存储，Primary 视角下会显得「双字节」，但挂载方一律走 Joliet。
//   * 单流、无压缩、无分卷——ISO 是文件系统镜像，不是压缩归档。

#ifndef Z7_ISO_WRITER_H
#define Z7_ISO_WRITER_H

#include <string>
#include <vector>

namespace z7 {
class Callback;
namespace iso {

// 把 utf8InputPaths（文件与目录）打包成一个 ISO9660 光盘镜像。
//   volumeName 为空时从目标文件名推导（去扩展名，大写，截断到 32 字符）。
//   excludeMacJunk 为 true 时跳过 .DS_Store / ._xxx / __MACOSX。
// 返回 false 时 error 填入原因（UTF-8）。
bool CreateIso(const std::vector<std::string> &utf8InputPaths,
               const std::string &utf8DestArchive, const std::string &volumeName,
               bool excludeMacJunk, Callback *cb, std::string &error);

}  // namespace iso
}  // namespace z7

#endif  // Z7_ISO_WRITER_H
