// Z7ExtCodec.h — 外部编解码器（zstd / lz4 / brotli / lzip / snappy）的单流归档处理器
//
// 为什么放在本目录、而不是改上游：
//   上游 7-Zip 26.03 只有 ZstdDecoder（没有编码器），并且完全没有 lz4 / brotli /
//   lzip / snappy —— 实测 `7zz a -tzstd` 直接返回 E_NOTIMPL，格式表里 zstd 的
//   「可创建」也是 0。
//   本项目约定「上游源码原样保留、升级零成本」，所以新格式一律实现在 dist/engine
//   下，作为**独立于上游注册表**的处理器，由桥接层直接实例化。升级上游时
//   两边不会互相冲突。
//
// 依赖如何处理：
//   有成熟库的就链库，且只链**静态库**（libzstd.a / liblz4.a / libbrotli*-static.a /
//   liblzma.a），因此发行包不会多出动态库依赖，.app 与 Quick Look 扩展仍然是
//   自包含的。没有合适库的（snappy）就自己实现 —— 裸 snappy 算法很小，不值得
//   为一个格式再拉一条依赖。
//   库缺失时对应格式被编译出去（见 ext_codecs.sh 的 Z7_HAVE_* 宏），构建照常成功，
//   只是少一种格式 —— CI 上没有装 Homebrew 也不会整条链路失败。
//
// 支持矩阵（与上游的差异即本文件的价值）：
//   zstd    上游只能解   → 本模块补「创建」
//   lz4     上游完全没有 → 本模块补「解压 + 创建」
//   brotli  上游完全没有 → 本模块补「解压 + 创建」
//   lzip    上游完全没有 → 本模块补「解压 + 创建」（liblzma raw LZMA1 + 自拼容器）
//   snappy  上游完全没有 → 本模块补「解压 + 创建」（自实现，支持裸格式与分帧格式）

#ifndef Z7_EXT_CODEC_H
#define Z7_EXT_CODEC_H

#include <string>
#include <vector>

#include "Common/MyCom.h"
#include "7zip/Archive/IArchive.h"

namespace z7 {

// 一个外部编解码器的能力描述。
struct ExternalCodec {
  const char *name;        // 注册名：界面徽标/日志用，也是 create 的格式名
  const char *extensions;  // 空格分隔的扩展名（不带点），用于按名匹配
  bool byExtOnly;          // 无魔数、只能靠扩展名认领（brotli / snappy 属于此类）
  bool canDecode;
  bool canEncode;
};

// 按格式名查找（"zstd" / "lz4" / "brotli"，大小写不敏感）。没有则返回 NULL ——
// 库没链进来时会是 NULL，调用方须按「不支持」处理，而不是假设一定存在。
const ExternalCodec *FindExternalCodec(const std::string &name);

// 按文件名（可以是完整路径）查找，用于打开时的兜底探测。
// byExtOnly 的编解码器**只有**在这里才会被认领。
const ExternalCodec *FindExternalCodecForPath(const std::string &path);

// 打开用的处理器（IInArchive）。codec->canDecode 为假时返回空指针。
CMyComPtr<IInArchive> CreateExternalInHandler(const ExternalCodec *codec);

// 创建用的处理器（IOutArchive / ISetProperties）。codec->canEncode 为假时返回空。
CMyComPtr<IOutArchive> CreateExternalOutHandler(const ExternalCodec *codec);

// 当前编译进来的所有外部编解码器（完整能力描述，含是否已链入库）。
// 返回**静态**向量的引用，调用方拿到的 ExternalCodec* 不会悬垂。
const std::vector<ExternalCodec> &GetExternalCodecs();

// 把归档路径告诉处理器：单流归档里那唯一条目的名字只能由路径推导
// （lz4/brotli 的容器里不存文件名），处理器自己拿不到。
// h 必须是由 CreateExternalInHandler 返回的实例。
void Z7ExternalHandlerSetPath(IInArchive *h, const std::string &utf8Path);

}  // namespace z7

#endif  // Z7_EXT_CODEC_H
