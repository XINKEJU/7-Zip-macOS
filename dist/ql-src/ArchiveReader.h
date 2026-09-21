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
//  Coverage:
//    - ZIP / ZIP64 : full central-directory listing
//    - TAR (ustar, pax, GNU long name) : full listing
//    - GZIP        : single-stream header (original name + uncompressed size)
//    - BZIP2 / XZ / ZSTD / 7z / RAR / CAB / ISO : container detection + summary
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
    char    *error;        /* owned; NULL when the read succeeded    */
} QlListing;

/* Returns 1 when the container was recognised (check `complete` for whether
   a full listing is available), 0 when the format is unknown. */
int  QlReadListing(const char *path, QlListing *out);
void QlListingFree(QlListing *l);

#endif /* ARCHIVE_READER_H */
