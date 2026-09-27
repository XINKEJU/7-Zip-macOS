// Z7DmgWriter.h — DMG 磁盘映像创建（内嵌助手调 hdiutil）
//
// 为什么必须派生 hdiutil：
//   DMG 是 Apple 专有格式（UDIF + HFS+/APFS 文件系统），没有进程内的、可在
//   本项目 license（LGPL）下重写的等价实现；连 System Integrity Protection 都
//   要求由系统 hdiutil 来产出可被 Finder 识别的 .dmg。因此这里破例派生一次
//   /usr/bin/hdiutil——这是刻意、且唯一被 make appcheck 白名单允许的子进程
//   （详见 BUILD.md 的「DMG 与零子进程原则」一节）。它替换的是「外部死载荷」
//   hdiutil 不存在于包内，包仍然完全自包含。
//
// 对比 ISO 创建（见 Z7IsoWriter）：ISO 走的是通用的 ECMA-119 公开标准，可以、
//   也确实被本项目在进程内自研实现；DMG 则是封闭私有格式，必须借系统工具。
//
// 实现：把输入暂存进临时目录（C++ 递归拷贝，不再产生额外子进程），再交给
//   hdiutil create -srcfolder 生成 UDZO（zlib 压缩、只读）磁盘映像。

#ifndef Z7_DMG_WRITER_H
#define Z7_DMG_WRITER_H

#include <string>
#include <vector>

namespace z7 {
class Callback;
namespace dmg {

// 把 utf8InputPaths（文件与目录）打包成一个 .dmg 磁盘映像。
//   volumeName 为空时从目标文件名推导。
// 返回 false 时 error 填入原因（UTF-8）。
bool CreateDmg(const std::vector<std::string> &utf8InputPaths,
               const std::string &utf8DestArchive, const std::string &volumeName,
               Callback *cb, std::string &error);

}  // namespace dmg
}  // namespace z7

#endif  // Z7_DMG_WRITER_H
