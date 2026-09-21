// MacOsNative.cpp
//
// Implementation of the macOS native semantic helpers declared in
// MacOsNative.h.  The whole body is compiled only on macOS; on other
// platforms this translation unit is empty.

#include "StdAfx.h"

#include "MacOsNative.h"

#if defined(__APPLE__)

#include <sys/xattr.h>
#include <CoreFoundation/CoreFoundation.h>

/* wchar_t is 32 bits wide on macOS and holds raw code points, so a UString
   buffer is UTF-32 in host byte order.  CoreFoundation has no "native"
   UTF-32 selector, therefore pick the byte order explicitly. */
#if defined(__BYTE_ORDER__) && (__BYTE_ORDER__ == __ORDER_BIG_ENDIAN__)
  #define MACOS_UTF32_ENCODING kCFStringEncodingUTF32BE
#else
  #define MACOS_UTF32_ENCODING kCFStringEncodingUTF32LE
#endif

/*
  macOS file systems use Unicode Normalization Form D internally, while
  archives produced on Windows and Linux normally carry Form C.  Extracting
  an NFC name onto macOS yields a name that is byte-different from the one
  the system itself would create for the same text, which shows up as
  look-alike duplicates in tools that compare names byte-wise (git, rsync,
  Node.js, build systems) and on non-normalizing volumes such as exFAT.

  We therefore normalize every path component to Form D, matching what
  macOS itself does.
*/
void MacOs_NormalizeName_NFD(UString &s)
{
  if (s.IsEmpty())
    return;

  /* UString uses wchar_t, which is 32 bits wide on macOS, so the buffer can
     be handed to CoreFoundation directly as native-endian UTF-32. */
  if (sizeof(wchar_t) != 4)
    return;

  const size_t srcSize = static_cast<size_t>(s.Len()) * sizeof(wchar_t);

  CFStringRef src = CFStringCreateWithBytes(
      kCFAllocatorDefault,
      reinterpret_cast<const UInt8 *>(s.Ptr()),
      static_cast<CFIndex>(srcSize),
      MACOS_UTF32_ENCODING,
      false);

  if (!src)
    return;

  CFMutableStringRef norm = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, src);
  CFRelease(src);

  if (!norm)
    return;

  CFStringNormalize(norm, kCFStringNormalizationFormD);

  const unsigned numChars = static_cast<unsigned>(CFStringGetLength(norm));

  UString res;
  wchar_t *dest = res.GetBuf(numChars + 1);

  CFIndex used = 0;
  const CFIndex numConverted = CFStringGetBytes(
      norm,
      CFRangeMake(0, static_cast<CFIndex>(numChars)),
      MACOS_UTF32_ENCODING,
      0,
      false,
      reinterpret_cast<UInt8 *>(dest),
      static_cast<CFIndex>((static_cast<size_t>(numChars) + 1) * sizeof(wchar_t)),
      &used);

  CFRelease(norm);

  if (numConverted > 0)
  {
    res.ReleaseBuf_SetLen(
        static_cast<unsigned>(used) / static_cast<unsigned>(sizeof(wchar_t)));
    s = res;
  }
  else
    res.ReleaseBuf_SetLen(0);
}


bool MacOs_GetXattr(const FString &path, const char *name, CByteBuffer &dest)
{
  dest.Free();

  const char *p = path.Ptr();
  if (!p || !p[0])
    return false;

  const ssize_t size = getxattr(p, name, NULL, 0, 0, 0);
  if (size <= 0)
    return false;

  dest.Alloc(static_cast<size_t>(size));
  if (dest.Size() != static_cast<size_t>(size))
    return false;

  const ssize_t res = getxattr(p, name, dest.NonConstData(), static_cast<size_t>(size), 0, 0);
  if (res != size)
  {
    dest.Free();
    return false;
  }

  return true;
}


bool MacOs_SetXattr(const FString &path, const char *name, const void *data, size_t size)
{
  if (!data || size == 0)
    return false;

  const char *p = path.Ptr();
  if (!p || !p[0])
    return false;

  return setxattr(p, name, data, size, 0, 0) == 0;
}

#endif // __APPLE__
