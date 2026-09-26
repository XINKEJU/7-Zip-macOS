//
//  ArchiveReader.h
//  In-process archive listing for the 7-Zip Quick Look extension.
//
//  The Quick Look extension runs inside the App Sandbox. Spawning the bundled
//  `7zz` engine is only permitted when the helper carries a valid
//  `com.apple.security.inherit` entitlement, which the kernel grants only to
//  helpers signed with a real team identity. For ad-hoc signed builds the
//  spawn is refused with EPERM, so this reader provides archive inspection
//  without a subprocess.
//
//  Coverage of the built-in reader (used only when the engine declines a file):
//    - ZIP / ZIP64 : full central-directory listing
//    - TAR (ustar, pax, GNU long name) : full listing
//    - GZIP        : single-stream header (original name + uncompressed size)
//    - BZIP2 / XZ / ZSTD / 7z / RAR / CAB / ISO : container detection + summary
//
//  Coverage of the engine-backed path (EngineListing.mm): every handler the
//  7-Zip engine registers — 7z, ZIP, TAR, GZIP, BZIP2, XZ, ZSTD, WIM, ISO,
//  DMG, RAR, CAB, APFS, HFS, NTFS, SquashFS, QCOW2, VHD/VHDX, XAR and the
//  rest. QlReadListing prefers it and falls back to the readers above.
//

#ifndef ARCHIVE_READER_H
#define ARCHIVE_READER_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    char    *name;      /* UTF-8, owned; directories end with '/' */
    uint64_t size;      /* uncompressed size in bytes        */
    uint64_t packed;    /* compressed size in bytes          */
    int64_t  mtime;     /* Unix seconds, or -1 when unknown  */
    int      is_dir;
    char     attr[10];  /* "D" / "A" style attribute letters */
} QlEntry;

typedef struct {
    QlEntry *items;
    size_t   count;
    size_t   cap;
    char     format[32];   /* detected container name, e.g. "ZIP"   */
    char     method[48];   /* compression method when known         */
    char     detail[128];  /* extra one-line fact for the header     */
    int      complete;     /* 1 = full entry listing, 0 = summary only */
    int      via_engine;   /* 1 = listed by the linked 7-Zip engine   */
    char    *error;        /* owned; NULL when the read succeeded    */
} QlListing;

/* Every entry point in this header is C. The header is also included by
   EngineListing.mm (Objective-C++, because it needs the engine's C++ headers),
   so the declarations must state C linkage explicitly — without this the C++
   compiler mangles the names and linking fails with "declaration possibly
   missing extern \"C\"". */
#ifdef __cplusplus
extern "C" {
#endif

/* Returns 1 when the container was recognised (check `complete` for whether
   a full listing is available), 0 when the format is unknown. */
int  QlReadListing(const char *path, QlListing *out);
void QlListingFree(QlListing *l);

/* Lists `utf8Path` with the linked 7-Zip engine, filling the QlListing
   allocation contract: *itemsOut is malloc'd, each entry name is strdup'd, and
   the caller owns all of it. Returns 1 on success and 0 when the engine could
   not open the file — in which case nothing is allocated and *errorOut (also
   strdup'd, may stay NULL) carries the reason. Implemented in EngineListing.mm */
int Z7EngineListArchive(const char *utf8Path,
                        QlEntry **itemsOut, size_t *countOut, size_t *capOut,
                        int *completeOut,
                        char *format, size_t formatCap,
                        char *method, size_t methodCap,
                        char *detail, size_t detailCap,
                        char **errorOut);

/* Engine version string from lib7z, for the preview footer. Static storage. */
const char *Z7EngineVersionString(void);

#ifdef __cplusplus
}
#endif

#endif /* ARCHIVE_READER_H */
