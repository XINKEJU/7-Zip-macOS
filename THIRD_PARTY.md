# 第三方组件与许可归属

本文件随本移植的**全部**发行方式一同分发，应用内可通过
**7-Zip → 致谢与许可…** 查看。

| 发行方式 | 归属声明的位置 | 许可正文的位置 |
| --- | --- | --- |
| 集成安装包 `7-Zip-26.03-macOS.pkg` / `.dmg` | `/usr/local/share/doc/7zip/THIRD_PARTY.md` | 同目录（`copying.txt`、`License.txt`、`unRarLicense.txt`、`third-party/`）；应用副本另在 `Contents/Resources/licenses/` |
| 应用包 `7-Zip.app` | `Contents/Resources/THIRD_PARTY.md` | `Contents/Resources/licenses/`（`COPYING`、`License.txt`、`unRarLicense.txt`、`third-party/`） |
| Homebrew 分发包（`package.sh` 产出） | `share/doc/7zip/THIRD_PARTY.md` | `share/doc/7zip/`（`copying.txt`、`License.txt`、`unRarLicense.txt`、`third-party/`） |

三个通道的副本内容一致；打包脚本在归属声明或任一许可正文缺失时会直接失败，
而不是发行一个缺少归属或正文的产物。

`.app` **单独**被拷贝分发时也自带全部许可正文 —— 这是刻意的：用户经常只取
`7-Zip.app` 而不装安装包，若正文只放在安装包的 doc 目录里，那条分发路径就拿不到
LGPL 全文与 unRAR 限制。`make appcheck` 会逐项断言这些文件确实在包内。

本移植（macOS 前端 + 内嵌引擎）以上游 7-Zip 26.03 为基础，整体按
**GNU LGPL-2.1-or-later** 分发，并附带下文的 unRAR 许可限制。
权威的复合声明见源码树 `7z2603-src/DOC/License.txt`，完整 LGPL 文本见
`LICENSE`（等价于 `7z2603-src/DOC/copying.txt`）。

---

## 1. 7-Zip 引擎

| 项目 | 内容 |
| --- | --- |
| 组件 | 7-Zip / 7z 引擎（`lib7z.dylib`、`7zz`） |
| 作者 | Igor Pavlov |
| 来源 | <https://www.7-zip.org/>（源码包 `7z2603-src.tar.xz`，26.03） |
| 许可 | GNU LGPL-2.1-or-later（部分文件见下表） |

引擎由上游源码中 `CPP/7zip/Bundles/Format7zF` 的 Bundle 编译为共享库
`lib7z.dylib`，由应用进程内加载（**不是**独立进程调用）。
命令行工具 `7zz` 由 `CPP/7zip/Bundles/Alone2` 编译，供命令行安装包与
沙盒化的 Quick Look 预览扩展使用。

> ⚠️ **发行出去的 `lib7z.dylib` 是「修改过的 7-Zip」，不是上游原样副本。**
> 仓库内的上游源码树带一份 8 改 2 增、共 10 个文件的 macOS 适配补丁
> （逐字节变更集：`dist/build/upstream-macos.patch`），其中被修改的翻译单元
> 会被编进该动态库。LGPL-2.1 §1 要求就这类修改作出声明，故在此明示；
> 每个被改文件头部也带「已修改 + 日期」提示。

### 1.1 引擎内部的许可构成

| 文件组 | 许可 |
| --- | --- |
| `CPP/7zip/Compress/Rar*` | GNU LGPL + unRAR 限制 |
| `CPP/7zip/Compress/LzfseDecoder.cpp` | BSD 3-clause |
| `C/ZstdDec.c` | BSD 3-clause |
| `C/Xxh64.c` | BSD 2-clause |
| 标注 "public domain" 的文件 | 公有领域 |
| 其余全部文件 | GNU LGPL |

### 1.2 本移植对上游源码的修改（10 个文件）

上游源码树**不是**逐字节原样的上游发布包。以下改动全部由
`dist/build/upstream-macos.patch` 描述，可施加到官方 tarball 上逐字节复现，
也可用 `dist/build/regen_upstream_patch.sh` 重新生成：

| 文件 | 改动 |
| --- | --- |
| `CPP/Common/StringConvert.cpp` | 非 UTF-8 字节串按 GB18030 解码（中文 Windows 压出的 zip 文件名全靠它） |
| `CPP/7zip/UI/Common/ExtractingFilePath.cpp` | 解压时按 Unicode NFD 规范化名字 |
| `CPP/7zip/UI/Common/ArchiveExtractCallback.cpp` | 解压后传播 macOS 隔离属性（quarantine） |
| `CPP/7zip/UI/Common/ArchiveExtractCallback.h` | 上述传播钩子的声明 |
| `CPP/7zip/7zip_gcc.mak` | `MacOsNative.o` 编译规则 |
| `CPP/7zip/Bundles/Alone2/makefile.gcc` | 把 `MacOsNative.o` 加入 `7zz` 目标 |
| `CPP/7zip/var_mac_arm64.mak`、`var_mac_x64.mak` | macOS 原生语义所需的构建变量 |
| `CPP/7zip/UI/Common/MacOsNative.h`、`MacOsNative.cpp` | **新增文件**（非上游），xattr 与名字规范化实现 |

**这些改动不涉及任何压缩、解压、加密或校验算法** —— 全部是 macOS 文件系统语义
适配与构建接线。

BSD 组件的完整文本位于 `7z2603-src/DOC/`。

### 1.3 本移植新增的外部压缩库

上游 7-Zip 26.03 只带 Zstandard **解码器**，且完全没有 LZ4 / Brotli / lzip / Snappy。
本移植在**上游树外**补上了这些格式（五种格式全部**可创建 + 可解压**）：
新增文件全部位于 `dist/engine/`，**不修改上游任何编解码实现**；算法本身调用下列
第三方库，Snappy 没有合适的库，算法为自实现，因此不占外部依赖。

这些库以**静态库**形式链入应用主程序（`7-Zip.app/Contents/MacOS/7-Zip`），
因此发行包不会多出任何动态库依赖，`.app` 与 Quick Look 扩展仍自包含。
链入与否由构建脚本 `dist/engine/ext_codecs.sh` 探测决定：库缺失时对应格式直接
不编译进来（构建照常成功，只是少一种格式），因此下表并非每个构建都包含。

| 库 | 版本（本机构建） | 版权 | 许可 | 随包分发的正文 |
| --- | --- | --- | --- | --- |
| Zstandard（`libzstd.a`） | 1.5.7 | Meta Platforms, Inc. 及贡献者 | BSD 3-clause | `third-party/zstd-BSD-3-Clause.txt` |
| LZ4（`liblz4.a`） | 1.10.0 | Yann Collet | BSD 2-clause | `third-party/lz4-BSD-2-Clause.txt` |
| Brotli（`libbrotli{dec,enc,common}.a`） | 1.2.0 | Google LLC | MIT | `third-party/brotli-MIT.txt` |
| liblzma / XZ Utils（`liblzma.a`） | 5.8.3 | Lasse Collin 及贡献者 | 0BSD（`liblzma` 部分） | `third-party/liblzma-0BSD.txt` |

四者的许可均为宽松许可，允许以二进制形式再分发，条件是**保留版权声明与许可文本**。
BSD 与 MIT 明确要求复现版权声明与许可正文，因此上表末列的正文**随每个发行通道
一并分发** —— 只列出项目主页 URL 并不构成满足。0BSD 不附带任何条件，其正文
随包仅出于透明。正文取自本机构建所用的那份库（`/opt/homebrew/Cellar/<库>/…`），
上游也可见于各自项目主页：

- Zstandard — <https://github.com/facebook/zstd/blob/dev/LICENSE>
- LZ4 — <https://github.com/lz4/lz4/blob/dev/LICENSE>
- Brotli — <https://github.com/google/brotli/blob/master/LICENSE>
- XZ Utils / liblzma — <https://github.com/tukaani-project/xz/blob/master/COPYING>

**`libzstd.a` 内部还编入了 xxHash**（发行二进制中实测有 38 个 `XXH*` 符号）。
xxHash 采用与 zstd 同一份 BSD-style 许可，其文件头另注
`Copyright (c) Yann Collet - Meta Platforms, Inc`，因此 `zstd-BSD-3-Clause.txt`
的正文同时覆盖它。`libzstd.a` 里另有 `divsufsort`（MIT），但实测**未被链接进
发行二进制**（符号与字符串均为 0 处），故不构成额外归属义务。

> **Snappy 不在此表内。** 上游与 Homebrew 都没有可直接静态链入的 snappy 编解码封装，
> 因此裸格式与分帧格式（`.sz`）的编解码由本移植**自行实现**（`Z7ExtCodec.cpp` 内的
> `CSnappyDecoder` / `CSnappyEncoder`），属于本移植自身代码，按第 3 节的
> **LGPL-2.1-or-later** 分发，不引入任何第三方代码。所依据的格式规范
> （`format_description.txt`、`framing_format.txt`）来自 Google 的
> <https://github.com/google/snappy>（BSD 3-clause），实现中未复制其源码。

> 这些库**不属于** 7-Zip 上游源码，也不在 `7z2603-src/` 内；它们由构建者从
> Homebrew（或自行编译）取得。若需要完全自由许可的构建，可不安装这些库，
> 构建会自动降级为「不含上述四种格式」（Snappy 仍可用）。

---

## 2. unRAR 许可限制（重要）

RAR 解压引擎源自 unRAR 程序的源代码，其版权归 Alexander Roshal 所有。
该部分附带的限制为：

> The unRAR sources cannot be used to re-create the RAR compression
> algorithm, which is proprietary. Distribution of modified unRAR sources in
> separate form or as a part of other software is permitted, provided that it
> is clearly stated in the documentation and source comments that the code may
> not be used to develop a RAR (WinRAR) compatible archiver.

**据此：本软件可以解压 RAR 归档，但不得用于开发 RAR（WinRAR）兼容的压缩器。**

完整文本：源码树 `7z2603-src/DOC/unRarLicense.txt`；安装后位于
`/usr/local/share/doc/7zip/unRarLicense.txt`（Homebrew 分发包在
`share/doc/7zip/unRarLicense.txt`），**应用包内也带一份**：
`7-Zip.app/Contents/Resources/licenses/unRarLicense.txt`。上文的限制同样写在
每个发行包的源码注释与文档中，以满足该许可「clearly stated in the documentation
and source comments」的要求。

---

## 3. 本移植自身的代码

| 目录 | 内容 | 许可 |
| --- | --- | --- |
| `dist/app-src/` | 原生 AppKit 前端 | LGPL-2.1-or-later |
| `dist/engine/` | C++ / ObjC++ 桥接层 | LGPL-2.1-or-later |
| `dist/ql-src/` | Quick Look 预览扩展 | LGPL-2.1-or-later |
| `dist/shell/`、`dist/pack/`、`dist/build/` | 补全、手册、打包脚本 | LGPL-2.1-or-later |
| `dist/tests/` | 桥接层与适配层验收测试 | LGPL-2.1-or-later |

Copyright (C) 2026 XINKEJU and contributors.

---

## 4. LGPL 合规：如何替换引擎库

LGPL 要求最终用户能够用自己修改过的版本替换本程序所使用的库。本移植
从一开始就按该要求设计：**引擎被隔离在一个独立的动态库中**，前端只通过
稳定的 C 接口使用它。

### 4.1 库的位置与加载方式

应用包内：

```
7-Zip.app/Contents/Frameworks/lib7z.dylib     ← 可被替换的引擎库
7-Zip.app/Contents/MacOS/7-Zip                ← 前端可执行文件
```

- `lib7z.dylib` 的 `install_name` 为 `@rpath/lib7z.dylib`；
- 前端二进制的 `LC_RPATH` 指向 `@executable_path/../Frameworks`；
- 前端通过 `dlopen` 语义的标准动态链接加载该库，没有静态链接、没有
  代码签名固定校验（ad-hoc 签名下替换后重新签名即可）。

### 4.2 替换步骤

```sh
# 1. 用你自己的构建替换库文件
cp /path/to/your/lib7z.dylib \
   /Applications/7-Zip.app/Contents/Frameworks/lib7z.dylib

# 2. 先给替换进来的库签名，再重新密封外层包
codesign --force --sign - \
   /Applications/7-Zip.app/Contents/Frameworks/lib7z.dylib
codesign --force --sign - /Applications/7-Zip.app

# 3. 验证
codesign --verify --strict --verbose=2 /Applications/7-Zip.app
```

> **不要用 `codesign --deep`。** `--deep` 会用外层的签名身份重新签名嵌套代码，
> 并在此过程中**丢弃 Quick Look 扩展的沙盒授权**（`7ZipQuickLook.appex`），
> 之后 ExtensionKit 会拒绝注册该扩展，归档预览随之失效。这一点与本仓库的
> 构建脚本一致：`dist/app-src/build_app.sh` 之所以先做外层再编译扩展，正是
> 为了避开 `--deep` 的这个副作用（见 `dist/build/BUILD.md` 的坑点记录）。
> 上面两步分开执行的写法等价且安全。

自 `dist/engine/` 重新构建引擎库的方法：

```sh
sh dist/engine/build_dylib.sh     # 由上游源码构建 lib7z.dylib
sh dist/engine/build_engine.sh    # 构建桥接层静态库
```

桥接层只依赖引擎的**公开 C 接口**（`CreateObject`、`GetNumberOfFormats`、
`GetHandlerProperty2` 等，这些符号由 `lib7z.dylib` 导出）。因此任何导出了这组
符号的兼容构建都可以替换进来。

> 注：若你替换的是命令行安装包的 `7zz`，位置为
> `/usr/local/bin/7zz`（或安装时的 `--prefix`）。

---

## 5. 致谢

- **Igor Pavlov** 与 7-Zip 贡献者：7z 引擎及其全部编解码器。
- **Alexander Roshal**：RAR 解压引擎所依据的 unRAR 源码。
- Apple AppKit / Foundation 团队：本前端所依赖的系统框架。

---

## 6. 商标

"7-Zip"、"WinRAR"、"RAR" 分别属于各自的权利人。
本项目是独立的社区移植，与 Igor Pavlov 及 RARLAB 无隶属或背书关系。
