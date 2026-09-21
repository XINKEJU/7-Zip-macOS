// MacOsNative.h
//
// macOS specific helpers that adapt 7-Zip to native macOS file-system
// semantics.  All declarations are guarded so other platforms are
// unaffected (the corresponding implementation file compiles empty there).

#ifndef ZIP7_INC_MAC_OS_NATIVE_H
#define ZIP7_INC_MAC_OS_NATIVE_H

#include "../../../Common/MyString.h"
#include "../../../Common/MyBuffer.h"

// macOS stores this extended attribute on files that were downloaded by a
// browser or received through a sandboxed application.  It is the macOS
// counterpart of the Mark-of-the-Web stream that 7-Zip propagates on Windows.
#define MACOS_QUARANTINE_XATTR_NAME "com.apple.quarantine"

#if defined(__APPLE__)

/*
  Convert (in place) a single path component to Unicode Normalization Form D.
  The function returns without changes if CoreFoundation cannot convert the
  string, so it is always safe to call.
*/
void MacOs_NormalizeName_NFD(UString &s);

/* Read a named extended attribute into (dest).  Returns false if the
   attribute is absent, empty or unreadable. */
bool MacOs_GetXattr(const FString &path, const char *name, CByteBuffer &dest);

/* Write a named extended attribute.  Returns false on failure. */
bool MacOs_SetXattr(const FString &path, const char *name, const void *data, size_t size);

#endif // __APPLE__

#endif
