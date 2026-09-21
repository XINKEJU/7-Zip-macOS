//
//  ArchiveReader.c
//  In-process archive listing for the 7-Zip Quick Look extension.
//
//  Pure C, no Foundation, no subprocess. The file is mapped read-only and the
//  container metadata is parsed directly. See ArchiveReader.h for rationale.
//

#include "ArchiveReader.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>

/* ------------------------------------------------------------------ util -- */

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

static uint32_t rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t rd64(const uint8_t *p)
{
    return (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32);
}

static char *xstrndup(const char *s, size_t n)
{
    char *r = (char *)malloc(n + 1);
    if (!r) return NULL;
    memcpy(r, s, n);
    r[n] = '\0';
    return r;
}

static char *xstrdup(const char *s) { return s ? xstrndup(s, strlen(s)) : NULL; }

static int ends_with(const char *s, const char *suffix)
{
    size_t ls = strlen(s), lf = strlen(suffix);
    return ls >= lf && strcasecmp(s + ls - lf, suffix) == 0;
}

/* Parse a fixed-width octal field; 0 on failure. GNU base-256 is supported
   because large tar members are encoded that way. */
static uint64_t parse_octal(const char *f, size_t n)
{
    if (n == 0) return 0;
    if ((uint8_t)f[0] & 0x80) {          /* base-256 */
        uint64_t v = (uint64_t)((uint8_t)f[0] & 0x7F);
        for (size_t i = 1; i < n; i++)
            v = (v << 8) | (uint8_t)f[i];
        return v;
    }
    uint64_t v = 0;
    for (size_t i = 0; i < n; i++) {
        char c = f[i];
        if (c == '\0' || c == ' ') break;
        if (c < '0' || c > '7') continue;
        v = v * 8 + (uint64_t)(c - '0');
    }
    return v;
}

/* MS-DOS packed timestamp -> Unix seconds. */
static int64_t dos_to_unix(uint16_t date, uint16_t time)
{
    if (date == 0) return -1;
    struct tm tmv;
    memset(&tmv, 0, sizeof(tmv));
    tmv.tm_year = ((date >> 9) & 0x7F) + 1980 - 1900;
    tmv.tm_mon  = ((date >> 5) & 0x0F) - 1;
    tmv.tm_mday = (date & 0x1F);
    tmv.tm_hour = (time >> 11) & 0x1F;
    tmv.tm_min  = (time >> 5) & 0x3F;
    tmv.tm_sec  = (time & 0x1F) * 2;
    tmv.tm_isdst = -1;
    time_t epoch = mktime(&tmv);
    return epoch == (time_t)-1 ? -1 : (int64_t)epoch;
}

static void listing_push(QlListing *l, const char *name, uint64_t size, uint64_t packed,
                         int64_t mtime, int is_dir, const char *attr)
{
    if (l->count == l->cap) {
        size_t nc = l->cap ? l->cap * 2 : 64;
        QlEntry *ni = (QlEntry *)realloc(l->items, nc * sizeof(QlEntry));
        if (!ni) return;
        l->items = ni;
        l->cap = nc;
    }
    QlEntry *e = &l->items[l->count++];
    memset(e, 0, sizeof(*e));
    e->name = xstrdup(name ? name : "");
    e->size = size;
    e->packed = packed;
    e->mtime = mtime;
    e->is_dir = is_dir;
    if (attr) snprintf(e->attr, sizeof(e->attr), "%s", attr);
    /* Directories should still be recognisable even if the caller forgot. */
    if (!is_dir && e->name && ends_with(e->name, "/")) e->is_dir = 1;
}

void QlListingFree(QlListing *l)
{
    if (!l) return;
    for (size_t i = 0; i < l->count; i++) free(l->items[i].name);
    free(l->items);
    free(l->error);
    l->items = NULL;
    l->count = l->cap = 0;
    l->error = NULL;
}

static void set_error(QlListing *l, const char *msg) { free(l->error); l->error = xstrdup(msg); }

/* ------------------------------------------------------------------- ZIP -- */

static const uint8_t kZipCD   [4] = { 'P', 'K', 1, 2 };
static const uint8_t kZipEOCD [4] = { 'P', 'K', 5, 6 };
static const uint8_t kZip64Loc[4] = { 'P', 'K', 6, 7 };
static const uint8_t kZip64EOCD[4] = { 'P', 'K', 6, 6 };

static int zip_list(const uint8_t *d, size_t n, QlListing *out)
{
    if (n < 22) return 0;

    /* Locate the End Of Central Directory record, scanning backwards over the
       optional archive comment (max 65535 bytes). */
    size_t maxBack = n < 65557 ? n : 65557;
    size_t eocd = 0;
    int found = 0;
    for (size_t i = 0; i + 22 <= maxBack; i++) {
        size_t p = n - 22 - i;
        if (memcmp(d + p, kZipEOCD, 4) == 0) { eocd = p; found = 1; break; }
    }
    if (!found) {
        /* A ZIP that begins with a local-file or central-directory signature
           but has no end-of-central-directory record is truncated, not some
           unknown format — say so explicitly. */
        if (n >= 4 && d[0] == 'P' && d[1] == 'K' &&
            ((d[2] == 3 && d[3] == 4) || (d[2] == 1 && d[3] == 2) || (d[2] == 5 && d[3] == 6))) {
            snprintf(out->format, sizeof(out->format), "ZIP");
            out->complete = 0;
            set_error(out, "ZIP 结束记录（EOCD）缺失，文件可能不完整或被截断。");
            return 1;
        }
        return 0;
    }

    uint64_t entries = rd16(d + eocd + 10);
    uint64_t cdSize  = rd32(d + eocd + 12);
    uint64_t cdOff   = rd32(d + eocd + 16);
    int isZip64 = 0;

    /* ZIP64: the 32-bit fields saturate and the real values live in the
       ZIP64 EOCD record referenced by the locator just before the EOCD. */
    if ((entries == 0xFFFF || cdSize == 0xFFFFFFFFULL || cdOff == 0xFFFFFFFFULL) && eocd >= 20) {
        size_t loc = eocd - 20;
        if (memcmp(d + loc, kZip64Loc, 4) == 0) {
            uint64_t z64 = rd64(d + loc + 8);
            if (z64 + 56 <= n && memcmp(d + z64, kZip64EOCD, 4) == 0) {
                entries = rd64(d + z64 + 32);
                cdSize  = rd64(d + z64 + 40);
                cdOff   = rd64(d + z64 + 48);
                isZip64 = 1;
            }
        }
    }

    /* Archives with prepended data (self-extracting stubs, APK-style) report a
       central-directory offset relative to the start of the ZIP payload, so
       correct by the delta between the two. */
    uint64_t delta = 0;
    if (cdOff + cdSize <= eocd)
        delta = (uint64_t)eocd - (cdOff + cdSize);
    uint64_t cdStart = cdOff + delta;

    if (cdStart > n) { set_error(out, "中央目录偏移超出文件范围，ZIP 结构可能已损坏。"); return 1; }

    snprintf(out->format, sizeof(out->format), "ZIP%s", isZip64 ? "64" : "");
    out->complete = 1;

    size_t p = (size_t)cdStart;
    uint64_t parsed = 0;
    while (p + 46 <= n && parsed < entries) {
        if (memcmp(d + p, kZipCD, 4) != 0) break;

        uint16_t flags    = rd16(d + p + 8);
        uint16_t method   = rd16(d + p + 10);
        uint16_t mtime    = rd16(d + p + 12);
        uint16_t mdate    = rd16(d + p + 14);
        uint64_t csize    = rd32(d + p + 20);
        uint64_t usize    = rd32(d + p + 24);
        uint16_t fnlen    = rd16(d + p + 28);
        uint16_t extralen = rd16(d + p + 30);
        uint16_t cmtlen   = rd16(d + p + 32);
        uint32_t extAttr  = rd32(d + p + 38);
        uint64_t lho      = rd32(d + p + 42);

        if (p + 46 + fnlen > n) break;
        char *name = xstrndup((const char *)(d + p + 46), fnlen);

        /* ZIP64 extended information extra field (id 0x0001) supplies any of
           uncompressed size, compressed size and local header offset that were
           stored as 0xFFFFFFFF in the fixed record, in that order. */
        size_t ex = p + 46 + fnlen;
        size_t exEnd = ex + extralen;
        if (exEnd > n) exEnd = n;
        while (ex + 4 <= exEnd) {
            uint16_t id  = rd16(d + ex);
            uint16_t len = rd16(d + ex + 2);
            size_t body = ex + 4;
            if (body + len > exEnd) break;
            if (id == 0x0001) {
                size_t q = body;
                if (usize == 0xFFFFFFFFULL && q + 8 <= body + len) { usize = rd64(d + q); q += 8; }
                if (csize == 0xFFFFFFFFULL && q + 8 <= body + len) { csize = rd64(d + q); q += 8; }
                if (lho   == 0xFFFFFFFFULL && q + 8 <= body + len) { lho   = rd64(d + q); q += 8; }
            }
            ex = body + len;
        }

        int isDir = (extAttr >> 16) & 0xF000;
        isDir = (isDir == 0x4000) || (name && ends_with(name, "/"));

        char attr[10] = "";
        if (!isDir) {
            /* Match 7-Zip's vocabulary so the column looks familiar. */
            const char *a = (flags & 1) ? "A E" : "A";
            snprintf(attr, sizeof(attr), "%s", a);
        }

        /* Rows can mix methods, so report the first file entry's method rather
           than letting the last one parsed win arbitrarily. */
        if (!isDir && out->method[0] == '\0') {
            snprintf(out->method, sizeof(out->method), "%s",
                     method == 0 ? "Store" :
                     method == 8 ? "Deflate" :
                     method == 12 ? "BZip2" :
                     method == 14 ? "LZMA" :
                     method == 93 ? "Zstd" :
                     method == 95 ? "XZ" : "Deflate64/Other");
        }
        listing_push(out, name, usize, csize, dos_to_unix(mdate, mtime), isDir, attr);
        free(name);

        p += 46 + fnlen + extralen + cmtlen;
        parsed++;
    }

    if (out->count == 0)
        set_error(out, "ZIP 中央目录为空，或条目记录无法解析。");
    return 1;
}

/* ------------------------------------------------------------------- TAR -- */

static int tar_list(const uint8_t *d, size_t n, QlListing *out)
{
    /* A tar header block: 100-byte name followed by "ustar" magic at 257. */
    if (n < 512) return 0;
    if (memcmp(d + 257, "ustar", 5) != 0) return 0;

    snprintf(out->format, sizeof(out->format), "TAR");
    out->complete = 1;

    char *longName = NULL;      /* pending GNU 'L' long name    */
    char *paxPath  = NULL;      /* pending pax path override    */
    uint64_t paxSize = 0;
    int hasPaxSize = 0;

    size_t off = 0;
    while (off + 512 <= n) {
        const uint8_t *h = d + off;
        if (h[0] == '\0') break;                       /* end-of-archive */

        const char *name = (const char *)h;
        uint64_t size = parse_octal((const char *)h + 124, 12);
        int64_t mtime = (int64_t)parse_octal((const char *)h + 136, 12);
        char type = (char)h[156];
        const char *prefix = (const char *)h + 345;

        size_t nameLen = strnlen(name, 100);
        size_t dataBlocks = (size_t)((size + 511) / 512);
        const uint8_t *payload = h + 512;

        if (type == 'L') {                              /* GNU long name */
            free(longName);
            longName = xstrndup((const char *)payload, (size_t)size);
            off += 512 + dataBlocks * 512;
            continue;
        }
        if (type == 'x' || type == 'g') {                /* pax extended header */
            size_t lim = (size_t)size;
            for (size_t i = 0; i + 4 < lim; i++) {
                /* records look like: "<len> <key>=<value>\n" */
                size_t recLen = 0;
                size_t j = i;
                while (j < lim && payload[j] >= '0' && payload[j] <= '9')
                    recLen = recLen * 10 + (size_t)(payload[j++] - '0');
                if (recLen == 0 || i + recLen > lim) break;
                size_t k = j + 1;
                size_t keyEnd = k;
                while (keyEnd < i + recLen && payload[keyEnd] != '=') keyEnd++;
                size_t valEnd = keyEnd;
                while (valEnd < i + recLen && payload[valEnd] != '\n') valEnd++;
                size_t keyLen = keyEnd - k;
                size_t valLen = valEnd > keyEnd ? valEnd - keyEnd - 1 : 0;
                if (keyLen == 4 && memcmp(payload + k, "path", 4) == 0) {
                    free(paxPath);
                    paxPath = xstrndup((const char *)payload + keyEnd + 1, valLen);
                } else if (keyLen == 4 && memcmp(payload + k, "size", 4) == 0) {
                    char tmp[32];
                    size_t c = valLen < sizeof(tmp) - 1 ? valLen : sizeof(tmp) - 1;
                    memcpy(tmp, payload + keyEnd + 1, c);
                    tmp[c] = '\0';
                    paxSize = strtoull(tmp, NULL, 10);
                    hasPaxSize = 1;
                }
                i += recLen - 1;
            }
            off += 512 + dataBlocks * 512;
            continue;
        }

        char full[512];
        full[0] = '\0';
        size_t prefixLen = strnlen(prefix, 155);
        if (prefixLen > 0) {
            snprintf(full, sizeof(full), "%.*s/%.*s", (int)prefixLen, prefix, (int)nameLen, name);
        } else {
            snprintf(full, sizeof(full), "%.*s", (int)nameLen, name);
        }

        const char *finalName = paxPath ? paxPath : longName ? longName : full;
        if (hasPaxSize) size = paxSize;

        int isDir = (type == '5') || ends_with(finalName, "/");
        if (type != 'x' && type != 'g' && type != 'L') {
            listing_push(out, finalName, size, size, mtime, isDir, isDir ? "D" : "A");
        }

        free(longName); longName = NULL;
        free(paxPath);  paxPath  = NULL;
        hasPaxSize = 0;

        off += 512 + dataBlocks * 512;
    }

    free(longName);
    free(paxPath);
    return 1;
}

/* --------------------------------------------------- stream containers --- */

/* Read a NUL-terminated string from `d` starting at `*pos`; advances `*pos`. */
static char *read_cstr(const uint8_t *d, size_t n, size_t *pos)
{
    size_t start = *pos;
    while (*pos < n && d[*pos] != '\0') (*pos)++;
    char *s = xstrndup((const char *)d + start, *pos - start);
    if (*pos < n) (*pos)++;
    return s;
}

static int gzip_list(const uint8_t *d, size_t n, QlListing *out)
{
    if (n < 18 || d[0] != 0x1F || d[1] != 0x8B || d[2] != 8) return 0;

    uint8_t flg = d[3];
    size_t pos = 10;                                   /* fixed header */
    if (pos > n) return 1;

    if (flg & 0x04) {                                  /* FEXTRA */
        if (pos + 2 > n) return 1;
        uint16_t xlen = rd16(d + pos);
        pos += 2 + xlen;
    }
    char *origName = NULL;
    if (flg & 0x08) origName = read_cstr(d, n, &pos);  /* FNAME  */
    if (flg & 0x10) { char *c = read_cstr(d, n, &pos); free(c); }  /* FCOMMENT */

    /* ISIZE is the uncompressed size modulo 2^32, stored in the trailer. */
    uint64_t usize = rd32(d + n - 4);

    snprintf(out->format, sizeof(out->format), "GZIP");
    snprintf(out->method, sizeof(out->method), "Deflate");
    out->complete = 1;

    const char *display = origName;
    if (!display || !*display) display = "(未记录原始文件名)";
    listing_push(out, display, usize, n, -1, 0, "A");
    if (!origName || !*origName)
        snprintf(out->detail, sizeof(out->detail),
                 "gzip 流未包含原始文件名；解压后大小取自 ISIZE 字段。");
    free(origName);
    return 1;
}

/* --------------------------------------------------------- detection ----- */

struct Magic { const char *label; const char *detail; size_t len; const char *sig; };

static const struct Magic kMagics[] = {
    { "BZIP2", "bzip2 流式压缩（无内嵌文件名）",        3, "BZh"                  },
    { "XZ",    "xz 流式压缩（无内嵌文件名）",           6, "\xFD""7zXZ\x00"       },
    { "ZSTD",  "zstd 流式压缩（无内嵌文件名）",         4, "\x28\xB5\x2F\xFD"     },
    { "RAR",   "RAR 归档，需要 7-Zip 引擎读取内容列表",  7, "Rar!\x1A\x07\x00"     },
    { "CAB",   "Microsoft Cabinet 归档",                4, "MSCF"                 },
    { "LZMA",  "LZMA 裸流",                             0, NULL                   },
};

static int detect_and_summarise(const uint8_t *d, size_t n, QlListing *out)
{
    /* 7z: the 32-byte signature header is stored uncompressed, so the format
       version and the compressed header size can be read without a decoder. */
    static const uint8_t k7zMagic[6] = { '7', 'z', 0xBC, 0xAF, 0x27, 0x1C };
    if (n >= 32 && memcmp(d, k7zMagic, 6) == 0) {
        uint8_t major = d[6], minor = d[7];
        uint64_t nextOff = rd64(d + 12);
        uint64_t nextSize = rd64(d + 20);
        int plausiblyValid = 1;
        if (nextOff > n || nextSize > n || nextOff + nextSize > n) plausiblyValid = 0;

        snprintf(out->format, sizeof(out->format), "7z");
        snprintf(out->method, sizeof(out->method), "LZMA/LZMA2 等");
        /* These bytes describe the 7z *container* format version (0.4 since
           the format was frozen), not the encoder release. */
        snprintf(out->detail, sizeof(out->detail),
                 "7z 容器格式版本 %u.%u · 压缩头部 %llu 字节%s",
                 major, minor, (unsigned long long)nextSize,
                 plausiblyValid ? "" : "（头部越界，文件可能已截断）");
        out->complete = 0;
        return 1;
    }

    for (size_t i = 0; i < sizeof(kMagics) / sizeof(kMagics[0]); i++) {
        const struct Magic *m = &kMagics[i];
        if (m->len && n >= m->len && memcmp(d, m->sig, m->len) == 0) {
            snprintf(out->format, sizeof(out->format), "%s", m->label);
            snprintf(out->detail, sizeof(out->detail), "%s", m->detail);
            out->complete = 0;
            return 1;
        }
    }

    /* ISO 9660: the primary volume descriptor sits at sector 16. */
    if (n > 32769 + 5 && memcmp(d + 32769, "CD001", 5) == 0) {
        snprintf(out->format, sizeof(out->format), "ISO");
        snprintf(out->detail, sizeof(out->detail), "ISO 9660 光盘映像");
        out->complete = 0;
        return 1;
    }

    /* Apple disk images and PAX streams are recognised but not enumerated. */
    if (n >= 8 && memcmp(d, "koly", 4) == 0) {
        snprintf(out->format, sizeof(out->format), "DMG");
        snprintf(out->detail, sizeof(out->detail), "Apple 磁盘映像");
        out->complete = 0;
        return 1;
    }

    return 0;
}

/* ------------------------------------------------------------------ API -- */

int QlReadListing(const char *path, QlListing *out)
{
    memset(out, 0, sizeof(*out));
    snprintf(out->format, sizeof(out->format), "未知");

    int fd = open(path, O_RDONLY);
    if (fd < 0) { set_error(out, "无法打开文件。"); return 0; }

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        close(fd);
        set_error(out, "文件为空或无法读取其大小。");
        return 0;
    }

    size_t n = (size_t)st.st_size;
    void *map = mmap(NULL, n, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) { set_error(out, "内存映射失败。"); return 0; }

    const uint8_t *d = (const uint8_t *)map;
    int recognised = 0;

    if (zip_list(d, n, out))              recognised = 1;
    else if (tar_list(d, n, out))         recognised = 1;
    else if (gzip_list(d, n, out))        recognised = 1;
    else if (detect_and_summarise(d, n, out)) recognised = 1;

    if (!recognised) {
        set_error(out, "无法识别的归档格式，或文件已损坏。");
        snprintf(out->format, sizeof(out->format), "未知");
    }

    munmap(map, n);
    return recognised;
}
