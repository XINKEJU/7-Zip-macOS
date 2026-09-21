# 第三方组件与许可归属

本文件随本移植的**全部**发行方式一同分发，应用内可通过
**7-Zip → 致谢与许可…** 查看。

| 发行方式 | 本文件的位置 |
| --- | --- |
| 集成安装包 `7-Zip-26.03-macOS.pkg` / `.dmg` | `/usr/local/share/doc/7zip/THIRD_PARTY.md` |
| 应用包 `7-Zip.app` | `Contents/Resources/THIRD_PARTY.md` |
| Homebrew 分发包（`package.sh` 产出） | `share/doc/7zip/THIRD_PARTY.md` |

三个通道的副本内容一致；打包脚本在文件缺失时会直接失败，而不是发行一个
缺少归属声明的产物。

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

### 1.1 引擎内部的许可构成

| 文件组 | 许可 |
| --- | --- |
| `CPP/7zip/Compress/Rar*` | GNU LGPL + unRAR 限制 |
| `CPP/7zip/Compress/LzfseDecoder.cpp` | BSD 3-clause |
| `C/ZstdDec.c` | BSD 3-clause |
| `C/Xxh64.c` | BSD 2-clause |
| 标注 "public domain" 的文件 | 公有领域 |
| 其余全部文件 | GNU LGPL |

BSD 组件的完整文本位于 `7z2603-src/DOC/`。

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

完整文本：`7z2603-src/DOC/unRarLicense.txt`，安装后位于
`/usr/local/share/doc/7zip/unRarLicense.txt`。

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
