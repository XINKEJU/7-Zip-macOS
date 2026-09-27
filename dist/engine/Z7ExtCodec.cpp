// Z7ExtCodec.cpp — 外部编解码器的单流归档处理器（见 Z7ExtCodec.h 的设计说明）
//
// 这些格式都是「单流」：归档里只有一个条目，没有目录、没有元数据表。
// 因此处理器只需实现 Open / Extract / UpdateItems 三件事，其余属性照
// 上游 GzHandler.cpp 的骨架填即可。

#include "Z7ExtCodec.h"

#include <stdlib.h>
#include <string.h>

#include <string>
#include <vector>

#include "Common/ComTry.h"
#include "Common/Defs.h"
#include "Common/MyCom.h"
#include "Common/StringConvert.h"
#include "Windows/PropVariant.h"
#include "Windows/PropVariantConv.h"

#include "7zip/Archive/IArchive.h"
#include "7zip/Common/StreamUtils.h"
#include "7zip/IStream.h"
#include "7zip/PropID.h"

#ifdef Z7_HAVE_ZSTD
#include <zstd.h>
#endif
#ifdef Z7_HAVE_LZ4
#include <lz4frame.h>
#endif
#ifdef Z7_HAVE_BROTLI
#include <brotli/decode.h>
#include <brotli/encode.h>
#endif
// lzip 的后端是 liblzma（xz-utils），只用它的 raw LZMA1 编解码器 + CRC32；
// lzip 的容器本身（头/尾）由本文件自己拼，见 CLzipDecoder / CLzipEncoder。
// 注意 liblzma 内部虽有一个 lzip 解码器（`lzma_lzip_decoder`），但它**没有
// 公开头文件**，不是稳定 ABI，所以不用它。
#ifdef Z7_HAVE_LZIP
#include <lzma.h>
#endif

using namespace NWindows;
using namespace NArchive;

namespace z7 {

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

static std::string LowerAscii(const std::string &s) {
  std::string r = s;
  for (size_t i = 0; i < r.size(); i++)
    r[i] = (char)tolower((unsigned char)r[i]);
  return r;
}

// UTF-8 -> UString（与 SevenZipEngine.cpp 的 ToUString 同一个做法：
// 非 Windows 下 7-Zip 强制 UTF-8，见 Common/StringConvert.cpp 的 g_ForceToUTF8）
static UString ToUString(const std::string &s) {
  UString u;
  if (s.empty()) return u;
  AString a;
  a.SetFrom(s.c_str(), (unsigned)s.size());
  MultiByteToUnicodeString2(u, a, CP_UTF8);
  return u;
}

// 完整写出，处理 Write 只写一部分的情况（ISequentialOutStream 允许短写）。
// 注意 7-Zip 的流接口用 UInt32 计长，不是 size_t。
//
// ⚠️ out 允许为 NULL：测试模式（-t）下 7-Zip 的抽取回调**不给输出流**，数据只要
// 被解出来丢掉即可。这里直接当写成功返回，各格式的解码器就不必各自判空 —— 漏判
// 的后果是解引用空指针直接段错误（`$T test <损坏的归档>` 就是这样崩的）。
// 返回前不改 written：调用方照样统计「解出了多少字节」，CRC/长度校验因此仍然生效。
static HRESULT WriteAll(ISequentialOutStream *out, const void *data, size_t size) {
  const Byte *p = (const Byte *)data;
  if (out == NULL) return S_OK;
  while (size != 0) {
    const UInt32 chunk = (size > (size_t)0xFFFFFFFFu) ? 0xFFFFFFFFu : (UInt32)size;
    UInt32 done = 0;
    RINOK(out->Write(p, chunk, &done))
    if (done == 0) return E_FAIL;
    p += done;
    size -= done;
  }
  return S_OK;
}

// ---------------------------------------------------------------------------
// 流式解压：统一的驱动循环 + 每个格式自己的状态机
// ---------------------------------------------------------------------------

class IExtDecoder {
public:
  virtual ~IExtDecoder() {}
  // 喂入一段压缩数据，把解出的字节写进 out；返回 false 表示数据损坏。
  virtual bool Code(const Byte *inBuf, size_t inSize, ISequentialOutStream *out,
                    UInt64 &written) = 0;
  // 输入读完后冲刷残余输出
  virtual bool Finish(ISequentialOutStream *out, UInt64 &written) = 0;
};

class IExtEncoder {
public:
  virtual ~IExtEncoder() {}
  // 喂入一段原始数据；isLast 表示这是最后一段
  virtual bool Code(const Byte *inBuf, size_t inSize, ISequentialOutStream *out,
                    bool isLast) = 0;
};

static const size_t kExtBufSize = (size_t)1 << 16;

// 从 in 顺序读、解压、写到 out。返回 S_FALSE 表示数据损坏（不是格式不匹配）。
static HRESULT RunDecode(IInStream *in, ISequentialOutStream *out, IExtDecoder *dec,
                         UInt64 *unpackSizeOut) {
  std::vector<Byte> inBuf(kExtBufSize);
  UInt64 total = 0;
  for (;;) {
    UInt32 read = 0;
    RINOK(in->Read(&inBuf[0], (UInt32)kExtBufSize, &read))
    if (read == 0) break;
    UInt64 w = 0;
    if (!dec->Code(&inBuf[0], read, out, w)) return S_FALSE;
    total += w;
  }
  UInt64 w = 0;
  if (!dec->Finish(out, w)) return S_FALSE;
  total += w;
  if (unpackSizeOut) *unpackSizeOut = total;
  return S_OK;
}

// 从 in 顺序读、压缩、写到 out。
static HRESULT RunEncode(ISequentialInStream *in, ISequentialOutStream *out,
                         IExtEncoder *enc) {
  std::vector<Byte> inBuf(kExtBufSize);
  for (;;) {
    UInt32 read = 0;
    RINOK(in->Read(&inBuf[0], (UInt32)kExtBufSize, &read))
    const bool last = (read == 0);
    if (!enc->Code(&inBuf[0], read, out, last)) return E_FAIL;
    if (last) break;
  }
  return S_OK;
}

// ---------------------------------------------------------------------------
// zstd：上游只有解码器，这里补编码器
// ---------------------------------------------------------------------------

#ifdef Z7_HAVE_ZSTD

class CZstdEncoder : public IExtEncoder {
  ZSTD_CCtx *ctx;

public:
  explicit CZstdEncoder(int level) {
    ctx = ZSTD_createCCtx();
    // 我们的等级是 0-9，zstd 原生支持 1-22。0 表示「默认」，直接沿用 zstd 的
    // 默认值 3，其余按 1:1 映射 —— 不做夸张的上调，速度代价太大。
    int zlevel = (level <= 0) ? ZSTD_CLEVEL_DEFAULT : level;
    if (zlevel > ZSTD_maxCLevel()) zlevel = ZSTD_maxCLevel();
    ZSTD_CCtx_setParameter(ctx, ZSTD_c_compressionLevel, zlevel);
  }
  virtual ~CZstdEncoder() { ZSTD_freeCCtx(ctx); }

  virtual bool Code(const Byte *inBuf, size_t inSize, ISequentialOutStream *out,
                    bool isLast) {
    ZSTD_inBuffer ib;
    ib.src = inBuf;
    ib.size = inSize;
    ib.pos = 0;
    std::vector<Byte> obuf(kExtBufSize);
    for (;;) {
      ZSTD_outBuffer ob;
      ob.dst = &obuf[0];
      ob.size = obuf.size();
      ob.pos = 0;
      // 输入为 0 字节且 isLast 时仍需调用一次 e_end 才能收尾（写出 frame 尾）
      const size_t rem =
          ZSTD_compressStream2(ctx, &ob, &ib, isLast ? ZSTD_e_end : ZSTD_e_continue);
      if (ZSTD_isError(rem)) return false;
      if (ob.pos != 0 && WriteAll(out, &obuf[0], ob.pos) != S_OK) return false;
      const bool inputDone = (ib.pos == ib.size);
      if (isLast) {
        // rem == 0 表示整个 frame 已收尾
        if (rem == 0) return true;
        if (inputDone) continue;   // 还有输出要冲刷
      } else {
        if (inputDone) return true;
      }
    }
  }
};

#endif  // Z7_HAVE_ZSTD

// ---------------------------------------------------------------------------
// lz4：上游完全没有，这里补解压（frame 格式，.lz4 的标准容器）
// ---------------------------------------------------------------------------

#ifdef Z7_HAVE_LZ4

class CLz4Decoder : public IExtDecoder {
  LZ4F_dctx *dctx;
  bool failed;

public:
  CLz4Decoder() : failed(false) {
    LZ4F_createDecompressionContext(&dctx, LZ4F_VERSION);
  }
  virtual ~CLz4Decoder() { LZ4F_freeDecompressionContext(dctx); }

  // 帧头里可选地带有原始大小；拿不到就返回 false，界面上显示为空即可。
  bool ReadFrameInfo(const Byte *p, size_t n, UInt64 &contentSizeOut) {
    LZ4F_frameInfo_t fi;
    size_t consumed = n;
    const size_t r = LZ4F_getFrameInfo(dctx, &fi, p, &consumed);
    if (LZ4F_isError(r)) return false;
    if (fi.contentSize == 0) return false;
    contentSizeOut = fi.contentSize;
    return true;
  }

  virtual bool Code(const Byte *inBuf, size_t inSize, ISequentialOutStream *out,
                    UInt64 &written) {
    written = 0;
    size_t inPos = 0;
    std::vector<Byte> obuf(kExtBufSize);
    while (inPos < inSize) {
      size_t dstSize = obuf.size();
      size_t srcSize = inSize - inPos;
      const size_t r = LZ4F_decompress(dctx, &obuf[0], &dstSize, inBuf + inPos,
                                       &srcSize, NULL);
      if (LZ4F_isError(r)) {
        failed = true;
        return false;
      }
      if (dstSize != 0) {
        if (WriteAll(out, &obuf[0], dstSize) != S_OK) return false;
        written += dstSize;
      }
      inPos += srcSize;
      if (r == 0) break;   // 帧已结束
    }
    return true;
  }

  virtual bool Finish(ISequentialOutStream *, UInt64 &written) {
    written = 0;
    return !failed;
  }
};

#endif  // Z7_HAVE_LZ4

// ---------------------------------------------------------------------------
// brotli：上游完全没有，这里补解压。
// 注意 brotli **没有魔数**，无法靠内容可靠识别，所以只能按扩展名认领
// （ExternalCodec.byExtOnly），否则会把任意二进制误判成 brotli。
// ---------------------------------------------------------------------------

#ifdef Z7_HAVE_BROTLI

class CBrotliDecoder : public IExtDecoder {
  BrotliDecoderState *st;
  bool done;
  bool failed;

public:
  CBrotliDecoder() : done(false), failed(false) {
    st = BrotliDecoderCreateInstance(NULL, NULL, NULL);
  }
  virtual ~CBrotliDecoder() { BrotliDecoderDestroyInstance(st); }

  virtual bool Code(const Byte *inBuf, size_t inSize, ISequentialOutStream *out,
                    UInt64 &written) {
    written = 0;
    size_t availIn = inSize;
    const uint8_t *nextIn = inBuf;
    std::vector<Byte> obuf(kExtBufSize);

    while (availIn != 0 && !done) {
      size_t availOut = obuf.size();
      uint8_t *nextOut = &obuf[0];
      const BrotliDecoderResult r =
          BrotliDecoderDecompressStream(st, &availIn, &nextIn, &availOut, &nextOut, 0);
      const size_t produced = obuf.size() - availOut;
      if (produced != 0) {
        if (WriteAll(out, &obuf[0], produced) != S_OK) return false;
        written += produced;
      }
      if (r == BROTLI_DECODER_RESULT_ERROR) {
        failed = true;
        return false;
      }
      if (r == BROTLI_DECODER_RESULT_SUCCESS) {
        done = true;
        break;
      }
      // NEEDS_MORE_INPUT：继续读；NEEDS_MORE_OUTPUT：继续冲刷
    }
    return true;
  }

  virtual bool Finish(ISequentialOutStream *, UInt64 &written) {
    written = 0;
    // 输入结束但解码器还没到 SUCCESS —— 说明数据被截断了
    if (!done && !failed) return false;
    return !failed;
  }
};

#endif  // Z7_HAVE_BROTLI

// ---------------------------------------------------------------------------
// lz4 编码器（解码器见上）。用同一个 lz4frame API 的压缩侧：
// LZ4F_createCompressionContext → compressBegin → compressUpdate → compressEnd。
// 我们在解码侧只认 frame 格式，编码侧也必须产出 frame，否则自己生成的包自己打不开。
// ---------------------------------------------------------------------------

#ifdef Z7_HAVE_LZ4

class CLz4Encoder : public IExtEncoder {
  LZ4F_cctx *ctx;
  LZ4F_preferences_t pref;
  std::vector<Byte> obuf;
  bool begun;
  bool failed;

public:
  explicit CLz4Encoder(int level) : ctx(NULL), begun(false), failed(false) {
    memset(&pref, 0, sizeof(pref));
    // 我们的等级是 0-9，lz4 的压缩等级是 1-12（1 最快）。0 = 库默认。
    // 注意这个版本的头文件里**没有** LZ4F_CLEVEL_* 宏，上限要用函数问。
    int l = (level <= 0) ? 0 : level;
    const int lmax = LZ4F_compressionLevel_max();
    if (l > lmax) l = lmax;
    pref.compressionLevel = (unsigned)l;
    pref.frameInfo.contentSize = 0;   // 流式压缩，长度未知，帧头里不写
    // autoFlush=1：每喂一块就尽量产出，避免长时间不落盘（我们按 64 KiB 喂）
    pref.autoFlush = 1;
    if (LZ4F_isError(LZ4F_createCompressionContext(&ctx, LZ4F_VERSION))) ctx = NULL;
  }
  virtual ~CLz4Encoder() {
    if (ctx) LZ4F_freeCompressionContext(ctx);
  }

  virtual bool Code(const Byte *inBuf, size_t inSize, ISequentialOutStream *out,
                    bool isLast) {
    if (!ctx || failed) return false;
    if (!begun) {
      obuf.resize(LZ4F_HEADER_SIZE_MAX);
      const size_t n = LZ4F_compressBegin(ctx, &obuf[0], obuf.size(), &pref);
      if (LZ4F_isError(n) || WriteAll(out, &obuf[0], n) != S_OK) {
        failed = true;
        return false;
      }
      begun = true;
    }
    // 输出缓冲按 compressBound 预留（+ 头，compressBegin 之外不会再写头，
    // 留出余量是为了 compressEnd 的帧尾）
    obuf.resize(LZ4F_compressBound(inSize, &pref) + LZ4F_HEADER_SIZE_MAX);
    if (inSize != 0) {
      const size_t n = LZ4F_compressUpdate(ctx, &obuf[0], obuf.size(), inBuf, inSize, NULL);
      if (LZ4F_isError(n) || (n != 0 && WriteAll(out, &obuf[0], n) != S_OK)) {
        failed = true;
        return false;
      }
    }
    if (isLast) {
      const size_t n = LZ4F_compressEnd(ctx, &obuf[0], obuf.size(), NULL);
      if (LZ4F_isError(n) || (n != 0 && WriteAll(out, &obuf[0], n) != S_OK)) {
        failed = true;
        return false;
      }
    }
    return true;
  }
};

#endif  // Z7_HAVE_LZ4

// ---------------------------------------------------------------------------
// brotli 编码器（解码器见上）。质量参数 0-11，我们的等级 0-9 直接映射：
// 单调、可预期。不主动往 11 抬 —— 那是 xz -9 级别的耗时，不适合 GUI 默认。
// ---------------------------------------------------------------------------

#ifdef Z7_HAVE_BROTLI

class CBrotliEncoder : public IExtEncoder {
  BrotliEncoderState *st;
  std::vector<Byte> obuf;
  bool failed;

public:
  explicit CBrotliEncoder(int level) : st(NULL), failed(false) {
    st = BrotliEncoderCreateInstance(NULL, NULL, NULL);
    if (!st) {
      failed = true;
      return;
    }
    int q = (level <= 0) ? 0 : level;
    if (q > BROTLI_MAX_QUALITY) q = BROTLI_MAX_QUALITY;
    BrotliEncoderSetParameter(st, BROTLI_PARAM_QUALITY, (uint32_t)q);
    obuf.resize(kExtBufSize);
  }
  virtual ~CBrotliEncoder() {
    if (st) BrotliEncoderDestroyInstance(st);
  }

  virtual bool Code(const Byte *inBuf, size_t inSize, ISequentialOutStream *out,
                    bool isLast) {
    if (!st || failed) return false;
    size_t availIn = inSize;
    const uint8_t *nextIn = inBuf;
    for (;;) {
      size_t availOut = obuf.size();
      uint8_t *nextOut = &obuf[0];
      const BROTLI_BOOL ok = BrotliEncoderCompressStream(
          st, isLast ? BROTLI_OPERATION_FINISH : BROTLI_OPERATION_PROCESS,
          &availIn, &nextIn, &availOut, &nextOut, NULL);
      if (!ok) {
        failed = true;
        return false;
      }
      const size_t produced = obuf.size() - availOut;
      if (produced != 0 && WriteAll(out, &obuf[0], produced) != S_OK) {
        failed = true;
        return false;
      }
      if (isLast) {
        if (BrotliEncoderIsFinished(st)) return true;
      } else if (availIn == 0) {
        return true;
      }
    }
  }
};

#endif  // Z7_HAVE_BROTLI

// ---------------------------------------------------------------------------
// lzip (.lz)：上游完全没有。容器 = 6 字节头 + LZMA1 原始流（带 EOS 标记）+
// 20 字节尾。规范见 lzip manual §5「File format」：
//   header : "LZIP"(4) | version(1, 恒为 1) | DS(1)
//   DS     : 低 5 位 = log2(基准大小)，取值 12..29；高 3 位 = 要减掉的分数分子(0..7)
//            dict_size = 2^(DS&0x1F) - (2^(DS&0x1F)/16) * ((DS>>5)&7)
//   trailer: CRC32(4) | 原始长度(8) | 成员总长(8)   全部小端
// 负载用 liblzma 的 LZMA_FILTER_LZMA1 raw 编解码器：它「编码时总是写 EOS 标记、
// 解码时总按长度未知处理」，恰好就是 lzip 要求的 LZMA-302eos（lc/lp/pb = 3/0/2）。
// ---------------------------------------------------------------------------

#ifdef Z7_HAVE_LZIP

static const unsigned kLzipMinDict = 1u << 12;   // 4 KiB（格式下限）
static const unsigned kLzipMaxDict = 1u << 29;   // 512 MiB（格式上限）

// 所有可表示的字典大小：18 个指数 × 8 个分数。取值不是单调序列
// （2^12 最高只到 4096，而 2^13 最低就到 4608），所以编码时全量比较取最小可行值。
static Byte LzipEncodeDictByte(unsigned want) {
  if (want < kLzipMinDict) want = kLzipMinDict;
  if (want > kLzipMaxDict) want = kLzipMaxDict;
  Byte best = (Byte)((0u << 5) | 29);
  unsigned bestV = 0xFFFFFFFFu;
  for (unsigned ds = 12; ds <= 29; ds++) {
    const unsigned base = 1u << ds;
    for (unsigned frac = 0; frac < 8; frac++) {
      const unsigned v = base - (base / 16) * frac;
      if (v >= want && v < bestV) {
        bestV = v;
        best = (Byte)((frac << 5) | ds);
      }
    }
  }
  return best;
}

// 等级 0-9 → 字典大小。格式允许到 512 MiB，但 GUI 里那个量级的内存占用不合理，
// 上限收到 64 MiB（与压缩面板里的「64 MB」档一致）。
static unsigned LzipDictSizeForLevel(int level) {
  switch (level) {
    case 0:  return 1u << 20;
    case 1:  return 1u << 20;
    case 2:  return 2u << 20;
    case 3:  return 4u << 20;
    case 4:  return 8u << 20;
    case 5:  return 16u << 20;
    case 6:  return 32u << 20;
    case 7:  return 32u << 20;
    case 8:  return 64u << 20;
    default: return 64u << 20;
  }
}

// 装好 LZMA1 raw 编解码器要用的 filter 数组。ds 由调用方给出。
struct LzipFilter {
  lzma_options_lzma opt;
  lzma_filter filt[2];
  explicit LzipFilter(unsigned dictSize) {
    // 预设只用来填 lc/lp/pb 等默认值，字典大小随后按需覆盖
    lzma_lzma_preset(&opt, 6);
    opt.dict_size = dictSize;
    opt.lc = 3;
    opt.lp = 0;
    opt.pb = 2;
    filt[0].id = LZMA_FILTER_LZMA1;
    filt[0].options = &opt;
    filt[1].id = LZMA_VLI_UNKNOWN;
    filt[1].options = NULL;
  }
};

class CLzipDecoder : public IExtDecoder {
  std::vector<Byte> _pending;   // 尚未消费的输入（含头 / 尾 / 下一个成员）
  std::vector<Byte> _obuf;
  lzma_stream _strm;
  bool _active;                 // 当前有成员正在解
  bool _failed;
  bool _any;
  UInt64 _memberOut;            // 本成员已解出的字节数
  UInt32 _crc;                  // 本成员原始数据的 CRC32

  bool StartMember() {
    const Byte *h = &_pending[0];
    if (!(h[0] == 'L' && h[1] == 'Z' && h[2] == 'I' && h[3] == 'P')) {
      _failed = true;
      return false;
    }
    if (h[4] != 1) {            // 版本号，当前恒为 1
      _failed = true;
      return false;
    }
    const unsigned base = 1u << (h[5] & 0x1F);
    const unsigned dict = base - (base / 16) * ((h[5] >> 5) & 7);
    if (dict < kLzipMinDict || dict > kLzipMaxDict) {
      _failed = true;
      return false;
    }
    LzipFilter lf(dict);
    lzma_end(&_strm);
    _strm = LZMA_STREAM_INIT;
    if (lzma_raw_decoder(&_strm, lf.filt) != LZMA_OK) {
      _failed = true;
      return false;
    }
    _pending.erase(_pending.begin(), _pending.begin() + 6);
    _active = true;
    _any = true;
    _memberOut = 0;
    _crc = 0;
    return true;
  }

  // 三个完整性因子（规范里的 3-factor checking）必须全部相符
  bool FinishMember() {
    if (_pending.size() < 20) {   // 尾部不完整
      _failed = true;
      return false;
    }
    const Byte *t = &_pending[0];
    const UInt32 crc = (UInt32)t[0] | ((UInt32)t[1] << 8) |
                       ((UInt32)t[2] << 16) | ((UInt32)t[3] << 24);
    UInt64 dataSize = 0, memberSize = 0;
    for (int i = 0; i < 8; i++) dataSize |= (UInt64)t[4 + i] << (8 * i);
    for (int i = 0; i < 8; i++) memberSize |= (UInt64)t[12 + i] << (8 * i);
    // total_in 从 StartMember 起算（每个成员都重建了流），就是压缩数据长度
    if (crc != _crc || dataSize != _memberOut ||
        memberSize != (UInt64)(6 + _strm.total_in + 20)) {
      _failed = true;
      return false;
    }
    _pending.erase(_pending.begin(), _pending.begin() + 20);
    _active = false;
    lzma_end(&_strm);
    _strm = LZMA_STREAM_INIT;
    return true;
  }

public:
  CLzipDecoder() : _active(false), _failed(false), _any(false),
                   _memberOut(0), _crc(0) {
    _strm = LZMA_STREAM_INIT;
    _obuf.resize(kExtBufSize);
  }
  virtual ~CLzipDecoder() { lzma_end(&_strm); }

  virtual bool Code(const Byte *inBuf, size_t inSize, ISequentialOutStream *out,
                    UInt64 &written) {
    written = 0;
    if (_failed) return false;
    if (inSize != 0) _pending.insert(_pending.end(), inBuf, inBuf + inSize);

    for (;;) {
      if (!_active) {
        if (_pending.size() < 6) return true;   // 头不全，等更多输入
        if (!StartMember()) return false;
      }
      _strm.next_in = _pending.empty() ? NULL : &_pending[0];
      _strm.avail_in = _pending.size();
      _strm.next_out = &_obuf[0];
      _strm.avail_out = _obuf.size();

      const lzma_ret r = lzma_code(&_strm, LZMA_RUN);
      const size_t produced = _obuf.size() - _strm.avail_out;
      const size_t used = _pending.size() - _strm.avail_in;
      if (used != 0) _pending.erase(_pending.begin(), _pending.begin() + used);
      if (produced != 0) {
        _crc = (UInt32)lzma_crc32(&_obuf[0], produced, _crc);
        if (WriteAll(out, &_obuf[0], produced) != S_OK) {
          _failed = true;
          return false;
        }
        written += produced;
        _memberOut += produced;
      }

      if (r == LZMA_STREAM_END) {
        if (!FinishMember()) return false;
        continue;                                // 可能是多成员文件
      }
      if (r == LZMA_OK || r == LZMA_BUF_ERROR) {
        if (produced == 0 && used == 0) return true;   // 需要更多输入
        continue;
      }
      _failed = true;                            // LZMA_DATA_ERROR / 内存不足 / …
      return false;
    }
  }

  virtual bool Finish(ISequentialOutStream *, UInt64 &written) {
    written = 0;
    if (_failed) return false;
    if (_active) return false;          // 成员没解完（被截断）
    if (!_pending.empty()) return false;  // 尾部有无法解释的残余
    return _any;
  }
};

class CLzipEncoder : public IExtEncoder {
  lzma_stream _strm;
  std::vector<Byte> _obuf;
  Byte _dictByte;
  bool _begun;
  bool _failed;
  UInt64 _inTotal;
  UInt32 _crc;

public:
  explicit CLzipEncoder(int level) : _dictByte(0), _begun(false), _failed(false),
                                     _inTotal(0), _crc(0) {
    _strm = LZMA_STREAM_INIT;
    const unsigned dict = LzipDictSizeForLevel(level);
    _dictByte = LzipEncodeDictByte(dict);
    LzipFilter lf(dict);
    if (lzma_raw_encoder(&_strm, lf.filt) != LZMA_OK) _failed = true;
    _obuf.resize(kExtBufSize);
  }
  virtual ~CLzipEncoder() { lzma_end(&_strm); }

  virtual bool Code(const Byte *inBuf, size_t inSize, ISequentialOutStream *out,
                    bool isLast) {
    if (_failed) return false;
    // CRC 算的是**原始**数据，不是压缩流
    if (inSize != 0) {
      _crc = (UInt32)lzma_crc32(inBuf, inSize, _crc);
      _inTotal += inSize;
    }
    if (!_begun) {
      const Byte h[6] = {'L', 'Z', 'I', 'P', 1, _dictByte};
      if (WriteAll(out, h, sizeof(h)) != S_OK) {
        _failed = true;
        return false;
      }
      _begun = true;
    }

    _strm.next_in = inBuf;
    _strm.avail_in = inSize;
    for (;;) {
      _strm.next_out = &_obuf[0];
      _strm.avail_out = _obuf.size();
      const lzma_ret r = lzma_code(&_strm, isLast ? LZMA_FINISH : LZMA_RUN);
      const size_t produced = _obuf.size() - _strm.avail_out;
      if (produced != 0 && WriteAll(out, &_obuf[0], produced) != S_OK) {
        _failed = true;
        return false;
      }
      if (r == LZMA_STREAM_END) {
        // LZMA 流长度由 total_out 给出（从 raw_encoder 建立时起算）
        const UInt64 memberSize = (UInt64)(6 + _strm.total_out + 20);
        Byte t[20];
        t[0] = (Byte)(_crc & 0xFF);
        t[1] = (Byte)((_crc >> 8) & 0xFF);
        t[2] = (Byte)((_crc >> 16) & 0xFF);
        t[3] = (Byte)((_crc >> 24) & 0xFF);
        for (int i = 0; i < 8; i++) t[4 + i] = (Byte)((_inTotal >> (8 * i)) & 0xFF);
        for (int i = 0; i < 8; i++) t[12 + i] = (Byte)((memberSize >> (8 * i)) & 0xFF);
        if (WriteAll(out, t, sizeof(t)) != S_OK) {
          _failed = true;
          return false;
        }
        return true;
      }
      if (r != LZMA_OK) {
        _failed = true;
        return false;
      }
      if (!isLast) {
        if (_strm.avail_in == 0) return true;
      } else if (produced == 0) {
        _failed = true;      // LZMA_FINISH 却再也产不出东西 = 卡住
        return false;
      }
    }
  }
};

#endif  // Z7_HAVE_LZIP

// ---------------------------------------------------------------------------
// snappy：上游完全没有，也不打算引第三方库 —— 裸 snappy 算法本身很小
// （varint 长度 + literal/copy 四种标签），自己实现反而少一层依赖，且能同时
// 支持两种容器：
//   裸格式 (raw)   ：varint 原始长度 + 元素流
//   分帧格式(framed)：10 字节流标识 0xFF 06 00 00 "sNaPpY"，随后每块
//                     [类型(1)] [长度(3,LE)] [masked CRC-32C(4)] [数据]
//                     类型 0x00 = 压缩块（数据里就带 varint 长度）
//                     类型 0x01 = 未压缩块  0xFE = 填充  0x80-0xFD = 可跳过
//                     块内原始数据不超过 65536 字节
// 两种容器都没有可靠区分「裸」和「别的二进制」的办法，所以 snappy 归为
// byExtOnly：只有 .sz / .snappy 才会被认领，进来后再按魔数分流。
// ---------------------------------------------------------------------------

#ifdef Z7_HAVE_SNAPPY

// 裸 snappy 里的 copy 最多可回引 2^32-1 字节，因此解压只能整块缓存。
// 上限是给 GUI 的保险：一个畸形头不该骗出几十 GB 的内存。
static const unsigned long long kSnappyMaxRaw = 1ull << 30;   // 1 GiB

static const size_t kSnappyBlock = 65536;   // 分帧格式规定的块上限

// ---- CRC-32C（Castagnoli，RFC 3720），分帧格式用它 ----
static UInt32 g_Crc32cTable[256];
static bool g_Crc32cReady = false;

static void Crc32cInit() {
  for (UInt32 i = 0; i < 256; i++) {
    UInt32 c = i;
    for (int k = 0; k < 8; k++) c = (c & 1) ? (0x82F63B78u ^ (c >> 1)) : (c >> 1);
    g_Crc32cTable[i] = c;
  }
  g_Crc32cReady = true;
}

static UInt32 Crc32c(const Byte *p, size_t n) {
  if (!g_Crc32cReady) Crc32cInit();
  UInt32 c = 0xFFFFFFFFu;
  for (size_t i = 0; i < n; i++)
    c = g_Crc32cTable[(c ^ p[i]) & 0xFF] ^ (c >> 8);
  return c ^ 0xFFFFFFFFu;
}

// 分帧格式存的不是 CRC 本身，而是「循环右移 15 位再加常数」的掩码值
static UInt32 SnappyMaskCrc(UInt32 x) {
  return ((x >> 15) | (x << 17)) + 0xA282EAD8u;
}

// ---- 裸 snappy 解压 ----
static bool SnappyDecodeRaw(const Byte *in, size_t n, std::vector<Byte> &out) {
  size_t ip = 0;
  unsigned long long total = 0;
  int shift = 0;
  for (;;) {
    if (ip >= n) return false;            // 长度前缀不完整
    const Byte b = in[ip++];
    total |= (unsigned long long)(b & 0x7F) << shift;
    if (!(b & 0x80)) break;
    shift += 7;
    if (shift > 35) return false;         // 前缀过长
  }
  if (total > kSnappyMaxRaw) return false;
  out.clear();
  out.reserve((size_t)total);

  while (ip < n) {
    const Byte tag = in[ip++];
    const unsigned type = tag & 3;
    if (type == 0) {                      // literal
      unsigned long long len = (tag >> 2) + 1;
      if (len > 60) {                     // 61..64 表示「后面跟 1..4 字节的真实长度-1」
        const unsigned extra = (unsigned)(len - 60);
        if (ip + extra > n) return false;
        unsigned long long v = 0;
        for (unsigned i = 0; i < extra; i++)
          v |= (unsigned long long)in[ip + i] << (8 * i);
        ip += extra;
        len = v + 1;
      }
      if (ip + len > n) return false;
      if (out.size() + len > total) return false;
      out.insert(out.end(), in + ip, in + ip + (size_t)len);
      ip += (size_t)len;
      continue;
    }
    unsigned long long len = 0, off = 0;
    if (type == 1) {                      // 1 字节偏移（长度 4-11，偏移 3+8 位）
      if (ip >= n) return false;
      len = 4 + ((tag >> 2) & 7);
      off = ((unsigned long long)(tag >> 5) << 8) | in[ip++];
    } else if (type == 2) {               // 2 字节偏移（长度 1-64）
      if (ip + 2 > n) return false;
      len = 1 + (tag >> 2);
      off = (unsigned long long)in[ip] | ((unsigned long long)in[ip + 1] << 8);
      ip += 2;
    } else {                              // 4 字节偏移
      if (ip + 4 > n) return false;
      len = 1 + (tag >> 2);
      for (unsigned i = 0; i < 4; i++)
        off |= (unsigned long long)in[ip + i] << (8 * i);
      ip += 4;
    }
    if (off == 0 || off > out.size()) return false;
    if (out.size() + len > total) return false;
    const size_t start = out.size() - (size_t)off;
    // 逐字节复制：offset < len 时这就是「重叠复制」，语义要求如此。
    // 上面 reserve 过 total，循环中不会重新分配，索引始终有效。
    for (unsigned long long i = 0; i < len; i++) out.push_back(out[start + (size_t)i]);
  }
  return out.size() == total;
}

// ---- 裸 snappy 压缩 ----
static void SnappyEmitLiteral(std::vector<Byte> &out, const Byte *p, size_t len) {
  if (len == 0) return;
  const size_t n = len - 1;
  if (n < 60) {
    out.push_back((Byte)(n << 2));
  } else {
    size_t bytes = 0;
    for (size_t v = n; v != 0; v >>= 8) bytes++;
    out.push_back((Byte)((59 + bytes) << 2));
    for (size_t i = 0; i < bytes; i++) out.push_back((Byte)((n >> (8 * i)) & 0xFF));
  }
  out.insert(out.end(), p, p + len);
}

// 长度必须 >= 4（类型 1 只能表示 4 以上的长度）
static void SnappyEmitCopyShort(std::vector<Byte> &out, size_t off, size_t len) {
  if (len < 12 && off < 2048) {
    out.push_back((Byte)(0x01 | ((len - 4) << 2) | ((off >> 8) << 5)));
    out.push_back((Byte)(off & 0xFF));
  } else {
    out.push_back((Byte)(0x02 | ((len - 1) << 2)));
    out.push_back((Byte)(off & 0xFF));
    out.push_back((Byte)((off >> 8) & 0xFF));
  }
}

static void SnappyEmitCopy(std::vector<Byte> &out, size_t off, size_t len) {
  while (len >= 68) {                     // 一次最多 64，留出尾部 >= 4
    SnappyEmitCopyShort(out, off, 64);
    len -= 64;
  }
  if (len > 64) {                         // 65..67：拆成 60 + 剩下的 5..7
    SnappyEmitCopyShort(out, off, 60);
    len -= 60;
  }
  SnappyEmitCopyShort(out, off, len);
}

// 单个块（<= 64 KiB）。块内偏移永远 < 64 KiB，与参考实现的 kBlockSize 一致。
static void SnappyCompressFragment(const Byte *in, size_t n, std::vector<Byte> &out) {
  if (n < 4) {
    SnappyEmitLiteral(out, in, n);
    return;
  }
  static const size_t kHashBits = 14;
  std::vector<UInt32> table(1u << kHashBits, 0xFFFFFFFFu);
  const size_t limit = n - 4;
  size_t ip = 0, nextEmit = 0;

  while (ip <= limit) {
    UInt32 cur = 0;
    for (int i = 0; i < 4; i++) cur |= (UInt32)in[ip + i] << (8 * i);
    const UInt32 h = (cur * 0x1E35A7BDu) >> (32 - kHashBits);
    const UInt32 cand = table[h];
    table[h] = (UInt32)ip;

    if (cand != 0xFFFFFFFFu && ip - cand < kSnappyBlock) {
      UInt32 ref = 0;
      for (int i = 0; i < 4; i++) ref |= (UInt32)in[cand + i] << (8 * i);
      if (ref == cur) {
        size_t mlen = 4;
        while (ip + mlen < n && in[cand + mlen] == in[ip + mlen]) mlen++;
        if (nextEmit < ip) SnappyEmitLiteral(out, in + nextEmit, ip - nextEmit);
        SnappyEmitCopy(out, ip - cand, mlen);
        ip += mlen;
        nextEmit = ip;
        continue;
      }
    }
    ip++;
  }
  if (nextEmit < n) SnappyEmitLiteral(out, in + nextEmit, n - nextEmit);
}

static bool SnappyProbeFramed(const Byte *p, size_t n) {
  if (n < 10) return false;
  return p[0] == 0xFF && p[1] == 0x06 && p[2] == 0x00 && p[3] == 0x00 &&
         p[4] == 0x73 && p[5] == 0x4E && p[6] == 0x61 && p[7] == 0x50 &&
         p[8] == 0x70 && p[9] == 0x59;
}

class CSnappyDecoder : public IExtDecoder {
  bool _framed;
  std::vector<Byte> _pending;
  std::vector<Byte> _scratch;
  bool _failed;

  bool EmitFramedChunk(ISequentialOutStream *out, UInt64 &written) {
    if (_pending.size() < 4) return true;
    const Byte type = _pending[0];
    const UInt32 len = (UInt32)_pending[1] | ((UInt32)_pending[2] << 8) |
                       ((UInt32)_pending[3] << 16);
    const size_t need = 4 + (size_t)len;
    if (_pending.size() < need) return true;          // 等整块到齐
    const Byte *payload = &_pending[4];

    if (type == 0xFE || (type >= 0x80 && type <= 0xFD)) {   // 填充 / 可跳过块
      _pending.erase(_pending.begin(), _pending.begin() + need);
      return true;
    }
    if (type != 0x00 && type != 0x01) {               // 0x02-0x7F = 必须报错
      _failed = true;
      return false;
    }
    if (len < 4) {
      _failed = true;
      return false;
    }
    const UInt32 wantCrc = (UInt32)payload[0] | ((UInt32)payload[1] << 8) |
                           ((UInt32)payload[2] << 16) | ((UInt32)payload[3] << 24);
    const Byte *body = payload + 4;
    const size_t bodyLen = (size_t)len - 4;

    const Byte *data = body;
    size_t dataLen = bodyLen;
    if (type == 0x00) {
      if (!SnappyDecodeRaw(body, bodyLen, _scratch)) {
        _failed = true;
        return false;
      }
      data = _scratch.empty() ? NULL : &_scratch[0];
      dataLen = _scratch.size();
    }
    if (dataLen != 0 && SnappyMaskCrc(Crc32c(data, dataLen)) != wantCrc) {
      _failed = true;
      return false;
    }
    if (dataLen != 0) {
      if (WriteAll(out, data, dataLen) != S_OK) {
        _failed = true;
        return false;
      }
      written += dataLen;
    }
    _pending.erase(_pending.begin(), _pending.begin() + need);
    return true;
  }

public:
  CSnappyDecoder() : _framed(false), _failed(false) {}

  // 由 Open 阶段的探测结果告知用哪种容器
  void SetFramed(bool f) { _framed = f; }

  virtual bool Code(const Byte *inBuf, size_t inSize, ISequentialOutStream *out,
                    UInt64 &written) {
    written = 0;
    if (_failed) return false;
    if (inSize != 0) _pending.insert(_pending.end(), inBuf, inBuf + inSize);

    if (!_framed) {
      // 裸格式要整块才能解（copy 可回引任意远），所以这里只缓存，Finish 里统一处理
      if (_pending.size() > kSnappyMaxRaw + (kSnappyMaxRaw / 4)) return false;
      return true;
    }
    for (;;) {
      if (_pending.size() < 4) return true;
      // 流标识可以重复出现（允许文件直接拼接），长度与内容对就忽略
      if (_pending[0] == 0xFF) {
        if (_pending.size() < 10) return true;
        if (!SnappyProbeFramed(&_pending[0], _pending.size())) {
          _failed = true;
          return false;
        }
        _pending.erase(_pending.begin(), _pending.begin() + 10);
        continue;
      }
      const size_t before = _pending.size();
      if (!EmitFramedChunk(out, written)) return false;
      if (_pending.size() == before) return true;      // 块没到齐，等更多输入
    }
  }

  virtual bool Finish(ISequentialOutStream *out, UInt64 &written) {
    written = 0;
    if (_failed) return false;
    if (_framed) return _pending.size() < 4;   // 只允许剩下不足一个块头
    if (_pending.empty()) return false;
    if (!SnappyDecodeRaw(&_pending[0], _pending.size(), _scratch)) return false;
    if (!_scratch.empty()) {
      if (WriteAll(out, &_scratch[0], _scratch.size()) != S_OK) return false;
      written = _scratch.size();
    }
    return true;
  }
};

class CSnappyEncoder : public IExtEncoder {
  std::vector<Byte> _buf;       // 未凑满一块的原始数据（最多 64 KiB）
  std::vector<Byte> _comp;
  bool _begun;
  bool _failed;

  // 把一段（<= 64 KiB）原始数据压成「未压缩块」或「压缩块」写出去
  bool FlushOne(ISequentialOutStream *out, const Byte *src, size_t srcLen) {
    if (srcLen == 0) return true;
    _comp.clear();
    size_t n = srcLen;                       // 裸块以 varint 原始长度开头
    while (n >= 0x80) {
      _comp.push_back((Byte)((n & 0x7F) | 0x80));
      n >>= 7;
    }
    _comp.push_back((Byte)n);
    SnappyCompressFragment(src, srcLen, _comp);

    // 压不动（或压大了）就按规范用未压缩块，省得输出反而膨胀
    const bool useRaw = (_comp.size() >= srcLen);
    const Byte *data = useRaw ? src : &_comp[0];
    const size_t dataLen = useRaw ? srcLen : _comp.size();
    const UInt32 crc = SnappyMaskCrc(Crc32c(src, srcLen));

    Byte head[8];
    head[0] = useRaw ? (Byte)0x01 : (Byte)0x00;
    const UInt32 chunkLen = (UInt32)(dataLen + 4);   // +4 = 掩码 CRC 本身
    head[1] = (Byte)(chunkLen & 0xFF);
    head[2] = (Byte)((chunkLen >> 8) & 0xFF);
    head[3] = (Byte)((chunkLen >> 16) & 0xFF);
    head[4] = (Byte)(crc & 0xFF);
    head[5] = (Byte)((crc >> 8) & 0xFF);
    head[6] = (Byte)((crc >> 16) & 0xFF);
    head[7] = (Byte)((crc >> 24) & 0xFF);
    if (WriteAll(out, head, sizeof(head)) != S_OK) return false;
    return WriteAll(out, data, dataLen) == S_OK;
  }

public:
  CSnappyEncoder() : _begun(false), _failed(false) {}

  virtual bool Code(const Byte *inBuf, size_t inSize, ISequentialOutStream *out,
                    bool isLast) {
    if (_failed) return false;
    if (!_begun) {
      const Byte id[10] = {0xFF, 0x06, 0x00, 0x00, 0x73, 0x4E,
                           0x61, 0x50, 0x70, 0x59};
      if (WriteAll(out, id, sizeof(id)) != S_OK) {
        _failed = true;
        return false;
      }
      _begun = true;
    }
    _buf.insert(_buf.end(), inBuf, inBuf + inSize);

    size_t done = 0;
    while (_buf.size() - done >= kSnappyBlock) {
      if (!FlushOne(out, &_buf[done], kSnappyBlock)) {
        _failed = true;
        return false;
      }
      done += kSnappyBlock;
    }
    if (done != 0) _buf.erase(_buf.begin(), _buf.begin() + (long)done);

    if (isLast && !_buf.empty()) {
      if (!FlushOne(out, &_buf[0], _buf.size())) {
        _failed = true;
        return false;
      }
      _buf.clear();
    }
    return true;
  }
};

#endif  // Z7_HAVE_SNAPPY

// ---------------------------------------------------------------------------
// 编解码器注册表
// ---------------------------------------------------------------------------

// 探测：lz4 frame 的魔数是 0x184D2204（legacy 帧是 0x184C2102）。
static bool ProbeLz4(const Byte *p, size_t n) {
  if (n < 4) return false;
  return (p[0] == 0x04 && p[1] == 0x22 && p[2] == 0x4D && p[3] == 0x18) ||
         (p[0] == 0x02 && p[1] == 0x21 && p[2] == 0x4C && p[3] == 0x18);
}

// lzip：魔数 "LZIP" + 版本号 1。版本号也要一并验，否则任何以 LZIP 开头的
// 文本文件都会被误认成归档。
static bool ProbeLzip(const Byte *p, size_t n) {
  if (n < 6) return false;
  return p[0] == 'L' && p[1] == 'Z' && p[2] == 'I' && p[3] == 'P' && p[4] == 1;
}

// 注册表。字段顺序：name / extensions / byExtOnly / canDecode / canEncode。
// 这套能力是「本移植相对上游的净增」：
//   zstd   上游只有解码器      → 这里补编码器
//   lz4    上游完全没有        → 这里补全套
//   brotli 上游完全没有        → 这里补全套（只能按扩展名认领，见下）
//   lzip   上游完全没有        → 这里补全套（liblzma 的 raw LZMA1 + 自拼容器）
//   snappy 上游完全没有        → 这里补全套（自实现，不依赖第三方库）
static const ExternalCodec g_Codecs[] = {
#ifdef Z7_HAVE_ZSTD
    {"zstd", "zst tzst zstd", false, false, true},
#endif
#ifdef Z7_HAVE_LZ4
    {"lz4", "lz4 tlz4", false, true, true},
#endif
#ifdef Z7_HAVE_BROTLI
    // brotli 没有魔数：只能按扩展名认领
    {"brotli", "br brotli", true, true, true},
#endif
#ifdef Z7_HAVE_LZIP
    {"lzip", "lz tlz", false, true, true},
#endif
#ifdef Z7_HAVE_SNAPPY
    // 裸 snappy 没有魔数、分帧 snappy 的魔数又不是强约束（可能被拼在文件中间），
    // 所以一律按扩展名认领；进来后再按魔数决定用哪种容器解。
    {"snappy", "sz snappy", true, true, true},
#endif
};

static const size_t kNumCodecs = sizeof(g_Codecs) / sizeof(g_Codecs[0]);

const ExternalCodec *FindExternalCodec(const std::string &name) {
  const std::string n = LowerAscii(name);
  for (size_t i = 0; i < kNumCodecs; i++)
    if (n == g_Codecs[i].name) return &g_Codecs[i];
  return NULL;
}

const ExternalCodec *FindExternalCodecForPath(const std::string &path) {
  const size_t slash = path.find_last_of('/');
  const std::string base =
      (slash == std::string::npos) ? path : path.substr(slash + 1);
  const std::string lower = LowerAscii(base);

  const size_t dot = lower.rfind('.');
  if (dot == std::string::npos) return NULL;
  const std::string ext = lower.substr(dot + 1);

  for (size_t i = 0; i < kNumCodecs; i++) {
    // 逐个比对扩展名列表（按空格分隔）
    const std::string exts = g_Codecs[i].extensions;
    std::string cur;
    for (size_t k = 0; k <= exts.size(); k++) {
      const char c = (k < exts.size()) ? exts[k] : ' ';
      if (c == ' ' || c == '.') {
        if (!cur.empty()) {
          if (cur == ext) return &g_Codecs[i];
          cur.clear();
        }
      } else {
        cur += c;
      }
    }
  }
  return NULL;
}

const std::vector<ExternalCodec> &GetExternalCodecs() {
  // 静态向量：保证 ExternalCodec* 在 EnumerateHandlers 返回后依然有效，
  // 否则 HandlerEntry.extCodec 会指向已被销毁的局部数组（悬垂指针）。
  static std::vector<ExternalCodec> s;
  if (s.empty())
    for (size_t i = 0; i < kNumCodecs; i++) s.push_back(g_Codecs[i]);
  return s;
}

// ---------------------------------------------------------------------------
// 处理器本体
// ---------------------------------------------------------------------------

// ⚠️ 名字必须是 kProps / kArcProps：上游宏 IMP_IInArchive_Props /
// IMP_IInArchive_ArcProps 直接按这两个名字展开。
static const Byte kProps[] = {kpidPath, kpidSize, kpidPackSize};

static const Byte kArcProps[] = {kpidNumStreams, kpidUnpackSize};

// ⚠️ 类名必须是 CHandler：上面两个宏与 Z7_CLASS_IMP_CHandler_* 都把类名写死了。
// 本文件是独立编译单元，与 SevenZipEngine.cpp 里的同名类不会冲突。
Z7_CLASS_IMP_CHandler_IInArchive_2(IOutArchive, ISetProperties)
  const ExternalCodec *_codec;
  bool _isArc;
  CMyComPtr<IInStream> _stream;
  UInt64 _packSize;
  UInt64 _unpackSize;   // 仅在能提前得知时有效（lz4 帧头可能带）
  bool _unpackSizeDefined;
  UString _name;        // 归档内那一个条目的名字
  int _level;

public:
  explicit CHandler(const ExternalCodec *c)
      : _codec(c), _isArc(false), _packSize(0), _unpackSize(0),
        _unpackSizeDefined(false), _level(5) {}

  // 条目名由桥接层告知（处理器自己拿不到文件路径）
  void SetArchivePath(const std::string &utf8Path) {
    const size_t slash = utf8Path.find_last_of('/');
    std::string base = (slash == std::string::npos) ? utf8Path : utf8Path.substr(slash + 1);
    const std::string lower = LowerAscii(base);
    // 去掉最后一段已知扩展名：out.lz4 -> out
    const std::string exts = _codec ? _codec->extensions : std::string();
    std::string cur;
    for (size_t k = 0; k <= exts.size(); k++) {
      const char c = (k < exts.size()) ? exts[k] : ' ';
      if (c == ' ' || c == '.') {
        if (!cur.empty()) {
          if (base.size() > cur.size() &&
              LowerAscii(base.substr(base.size() - cur.size())) == cur &&
              base[base.size() - cur.size() - 1] == '.') {
            base.erase(base.size() - cur.size() - 1);
            break;
          }
          cur.clear();
        }
      } else {
        cur += c;
      }
    }
    _name = ToUString(base);
  }
};

IMP_IInArchive_Props
IMP_IInArchive_ArcProps

Z7_COM7F_IMF(CHandler::Open(IInStream *stream, const UInt64 *,
                               IArchiveOpenCallback *)) {
  COM_TRY_BEGIN
  Close();
  if (!_codec || !_codec->canDecode) return S_FALSE;

  UInt64 fileSize = 0;
  stream->Seek(0, STREAM_SEEK_END, &fileSize);
  stream->Seek(0, STREAM_SEEK_SET, NULL);

  Byte head[16];
  UInt32 got = 0;
  stream->Read(head, (UInt32)sizeof(head), &got);
  stream->Seek(0, STREAM_SEEK_SET, NULL);

#ifdef Z7_HAVE_LZ4
  if (strcmp(_codec->name, "lz4") == 0) {
    if (!ProbeLz4(head, got)) return S_FALSE;
    // 帧头里可能带原始大小，顺手取出来（取不到就留空）
    CLz4Decoder probe;
    UInt64 cs = 0;
    if (probe.ReadFrameInfo(head, got, cs)) {
      _unpackSize = cs;
      _unpackSizeDefined = true;
    }
    _isArc = true;
    _packSize = fileSize;
    _stream = stream;
    return S_OK;
  }
#endif

#ifdef Z7_HAVE_LZIP
  if (strcmp(_codec->name, "lzip") == 0) {
    // 有强魔数（"LZIP" + 版本 1），可以放心做内容探测 —— 不看扩展名也能认出来
    if (!ProbeLzip(head, got)) return S_FALSE;
    _isArc = true;
    _packSize = fileSize;
    _stream = stream;
    return S_OK;
  }
#endif

  // brotli / snappy 没有强魔数：它们按扩展名认领（byExtOnly），走到这里说明
  // 调用方已经确认过扩展名，直接接受。
  _isArc = true;
  _packSize = fileSize;
  _stream = stream;
  return S_OK;
  COM_TRY_END
}

Z7_COM7F_IMF(CHandler::Close()) {
  _isArc = false;
  _packSize = 0;
  _unpackSize = 0;
  _unpackSizeDefined = false;
  _stream.Release();
  return S_OK;
}

Z7_COM7F_IMF(CHandler::GetNumberOfItems(UInt32 *numItems)) {
  *numItems = _isArc ? 1 : 0;
  return S_OK;
}

Z7_COM7F_IMF(CHandler::GetProperty(UInt32, PROPID propID, PROPVARIANT *value)) {
  COM_TRY_BEGIN
  NCOM::CPropVariant prop;
  switch (propID) {
    case kpidPath:
      if (!_name.IsEmpty()) prop = _name;
      break;
    case kpidSize:
      if (_unpackSizeDefined) prop = _unpackSize;
      break;
    case kpidPackSize:
      if (_packSize != 0) prop = _packSize;
      break;
    default:
      break;
  }
  prop.Detach(value);
  return S_OK;
  COM_TRY_END
}

Z7_COM7F_IMF(CHandler::GetArchiveProperty(PROPID propID, PROPVARIANT *value)) {
  COM_TRY_BEGIN
  NCOM::CPropVariant prop;
  switch (propID) {
    case kpidPhySize:
      if (_packSize != 0) prop = _packSize;
      break;
    case kpidUnpackSize:
      if (_unpackSizeDefined) prop = _unpackSize;
      break;
    case kpidNumStreams:
      if (_isArc) prop = (UInt64)1;
      break;
    case kpidErrorFlags:
      if (!_isArc) prop = (UInt32)kpv_ErrorFlags_IsNotArc;
      break;
    default:
      break;
  }
  prop.Detach(value);
  return S_OK;
  COM_TRY_END
}

Z7_COM7F_IMF(CHandler::Extract(const UInt32 *indices, UInt32 numItems,
                                  Int32 testMode,
                                  IArchiveExtractCallback *extractCallback)) {
  COM_TRY_BEGIN
  if (numItems == 0) return S_OK;
  if (numItems != (UInt32)(Int32)-1 && (numItems != 1 || indices[0] != 0))
    return E_INVALIDARG;
  if (!_isArc || !_codec || !_codec->canDecode) return E_FAIL;

  if (_packSize != 0) extractCallback->SetTotal(_packSize);

  CMyComPtr<ISequentialOutStream> realOutStream;
  const Int32 askMode =
      testMode ? NExtract::NAskMode::kTest : NExtract::NAskMode::kExtract;
  RINOK(extractCallback->GetStream(0, &realOutStream, askMode))
  if (!testMode && !realOutStream) return S_OK;
  RINOK(extractCallback->PrepareOperation(askMode))

  RINOK(InStream_SeekToBegin(_stream))

  HRESULT res = E_FAIL;
  const char *nm = _codec->name;
#ifdef Z7_HAVE_LZ4
  if (strcmp(nm, "lz4") == 0) {
    CLz4Decoder dec;
    res = RunDecode(_stream, realOutStream, &dec, NULL);
  } else
#endif
#ifdef Z7_HAVE_BROTLI
  if (strcmp(nm, "brotli") == 0) {
    CBrotliDecoder dec;
    res = RunDecode(_stream, realOutStream, &dec, NULL);
  } else
#endif
#ifdef Z7_HAVE_LZIP
  if (strcmp(nm, "lzip") == 0) {
    CLzipDecoder dec;
    res = RunDecode(_stream, realOutStream, &dec, NULL);
  } else
#endif
#ifdef Z7_HAVE_SNAPPY
  if (strcmp(nm, "snappy") == 0) {
    CSnappyDecoder dec;
    // 裸格式没有魔数，读一眼开头就能区分「分帧」与「裸」两种容器
    Byte h[10];
    UInt32 got = 0;
    InStream_SeekToBegin(_stream);
    if (_stream->Read(h, (UInt32)sizeof(h), &got) == S_OK)
      dec.SetFramed(SnappyProbeFramed(h, got));
    InStream_SeekToBegin(_stream);
    res = RunDecode(_stream, realOutStream, &dec, NULL);
  } else
#endif
  {
    res = E_NOTIMPL;
  }

  if (res != S_OK) {
    extractCallback->SetOperationResult(
        res == S_FALSE ? NExtract::NOperationResult::kDataError
                       : NExtract::NOperationResult::kUnavailable);
    return res == S_FALSE ? S_FALSE : res;
  }

  realOutStream.Release();
  return extractCallback->SetOperationResult(NExtract::NOperationResult::kOK);
  COM_TRY_END
}

// 创建（IOutArchive）：所有 canEncode 的外部编解码器都走这条路径。
// CreateExternalOutHandler 已经把 canEncode == false 的挡在外面了，所以这里的
// 分派只需覆盖「本版本链进来的全部编码器」。
Z7_COM7F_IMF(CHandler::UpdateItems(ISequentialOutStream *outStream,
                                      UInt32 numItems,
                                      IArchiveUpdateCallback *callback)) {
  COM_TRY_BEGIN
  if (numItems != 1) return E_INVALIDARG;
  if (!_codec || !_codec->canEncode) return E_NOTIMPL;

  Int32 newData = 0, newProps = 0;
  UInt32 indexInArc = 0;
  RINOK(callback->GetUpdateItemInfo(0, &newData, &newProps, &indexInArc))
  if (newData == 0) return E_NOTIMPL;   // 不支持「沿用旧数据」

  CMyComPtr<ISequentialInStream> inStream;
  RINOK(callback->GetStream(0, &inStream))
  if (!inStream) return E_NOTIMPL;

  HRESULT res = E_NOTIMPL;
  const char *nm = _codec->name;
#ifdef Z7_HAVE_ZSTD
  if (strcmp(nm, "zstd") == 0) {
    CZstdEncoder enc(_level);
    res = RunEncode(inStream, outStream, &enc);
  } else
#endif
#ifdef Z7_HAVE_LZ4
  if (strcmp(nm, "lz4") == 0) {
    CLz4Encoder enc(_level);
    res = RunEncode(inStream, outStream, &enc);
  } else
#endif
#ifdef Z7_HAVE_BROTLI
  if (strcmp(nm, "brotli") == 0) {
    CBrotliEncoder enc(_level);
    res = RunEncode(inStream, outStream, &enc);
  } else
#endif
#ifdef Z7_HAVE_LZIP
  if (strcmp(nm, "lzip") == 0) {
    CLzipEncoder enc(_level);
    res = RunEncode(inStream, outStream, &enc);
  } else
#endif
#ifdef Z7_HAVE_SNAPPY
  if (strcmp(nm, "snappy") == 0) {
    CSnappyEncoder enc;
    res = RunEncode(inStream, outStream, &enc);
  } else
#endif
  {
    res = E_NOTIMPL;
  }
  if (res != S_OK) return res;

  inStream.Release();
  RINOK(callback->SetOperationResult(NUpdate::NOperationResult::kOK))
  return S_OK;
  COM_TRY_END
}

// IOutArchive 的一部分。这些格式不存时间戳，因此按上游 GzHandler.cpp 的做法
// 回 kNotDefined（见 IArchive.h 中 GET_FileTimeType_NotDefined_for_GetFileTimeType
// 的注释：22.00 之后这个值已不再被使用）。
Z7_COM7F_IMF(CHandler::GetFileTimeType(UInt32 *timeType)) {
  *timeType = GET_FileTimeType_NotDefined_for_GetFileTimeType;
  return S_OK;
}

Z7_COM7F_IMF(CHandler::SetProperties(const wchar_t *const *names,
                                        const PROPVARIANT *values,
                                        UInt32 numProps)) {
  COM_TRY_BEGIN
  for (UInt32 i = 0; i < numProps; i++) {
    if (!names[i]) continue;
    // "x" 是压缩等级（与上游 SetProperties 的约定一致）
    if (wcscmp(names[i], L"x") != 0) continue;
    const PROPVARIANT &pv = values[i];
    UInt32 v = 5;
    if (pv.vt == VT_UI4) v = pv.ulVal;
    else if (pv.vt == VT_I4 && pv.lVal >= 0) v = (UInt32)pv.lVal;
    else if (pv.vt == VT_EMPTY || pv.vt == VT_I4) v = 0;
    if (v > 9) v = 9;
    _level = (int)v;
  }
  return S_OK;
  COM_TRY_END
}

// ---------------------------------------------------------------------------
// 对外构造入口
// ---------------------------------------------------------------------------

CMyComPtr<IInArchive> CreateExternalInHandler(const ExternalCodec *codec) {
  CMyComPtr<IInArchive> r;
  if (!codec || !codec->canDecode) return r;
  // 宏生成的类把 AddRef/Release/QueryInterface 设为私有，只能经接口指针用。
  r = new CHandler(codec);
  return r;
}

CMyComPtr<IOutArchive> CreateExternalOutHandler(const ExternalCodec *codec) {
  CMyComPtr<IOutArchive> r;
  if (!codec || !codec->canEncode) return r;
  CMyComPtr<IInArchive> in(new CHandler(codec));
  in->QueryInterface(IID_IOutArchive, (void **)&r);
  return r;
}

// 让桥接层能把文件路径告诉处理器（条目名没有其它来源）
void Z7ExternalHandlerSetPath(IInArchive *h, const std::string &utf8Path) {
  CHandler *c = (CHandler *)h;
  if (c) c->SetArchivePath(utf8Path);
}

}  // namespace z7
