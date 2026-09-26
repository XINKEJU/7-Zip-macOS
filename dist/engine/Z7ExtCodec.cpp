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
static HRESULT WriteAll(ISequentialOutStream *out, const void *data, size_t size) {
  const Byte *p = (const Byte *)data;
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
// 编解码器注册表
// ---------------------------------------------------------------------------

// 探测：lz4 frame 的魔数是 0x184D2204（legacy 帧是 0x184C2102）。
static bool ProbeLz4(const Byte *p, size_t n) {
  if (n < 4) return false;
  return (p[0] == 0x04 && p[1] == 0x22 && p[2] == 0x4D && p[3] == 0x18) ||
         (p[0] == 0x02 && p[1] == 0x21 && p[2] == 0x4C && p[3] == 0x18);
}

static const ExternalCodec g_Codecs[] = {
#ifdef Z7_HAVE_ZSTD
    {"zstd", "zst tzst zstd", false, false, true},
#endif
#ifdef Z7_HAVE_LZ4
    {"lz4", "lz4 tlz4", false, true, false},
#endif
#ifdef Z7_HAVE_BROTLI
    // brotli 没有魔数：只能按扩展名认领
    {"brotli", "br brotli", true, true, false},
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

  // brotli 没有魔数，不做内容探测：byExtOnly 的编解码器只按扩展名认领，
  // 走到这里说明调用方已经确认过扩展名，直接接受。
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
#ifdef Z7_HAVE_LZ4
  if (strcmp(_codec->name, "lz4") == 0) {
    CLz4Decoder dec;
    res = RunDecode(_stream, realOutStream, &dec, NULL);
  }
#endif
#ifdef Z7_HAVE_BROTLI
  if (res != S_OK && strcmp(_codec->name, "brotli") == 0) {
    CBrotliDecoder dec;
    res = RunDecode(_stream, realOutStream, &dec, NULL);
  }
#endif
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

// 创建：只有 zstd 走这条路径（lz4 / brotli 的 canEncode 为 false，
// CreateExternalOutHandler 会直接拒绝）。
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
#ifdef Z7_HAVE_ZSTD
  if (strcmp(_codec->name, "zstd") == 0) {
    CZstdEncoder enc(_level);
    res = RunEncode(inStream, outStream, &enc);
  }
#endif
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
