7-Zip 26.03 for macOS — Apple Silicon build (arm64)
==================================================

Built from the unmodified official 7-Zip 26.03 source release
(released 2026-09-03) by Igor Pavlov.

Source: https://www.7-zip.org/download.html
        https://github.com/ip7z/7zip/releases/tag/26.03


CONTENTS OF THIS DISK IMAGE
---------------------------

  7-Zip-26.03-macOS.pkg ...... the installer. Double-click to install.
  uninstall.sh ............... removes every file the installer placed.
  README-macos.txt ........... this file.

The upstream 7-Zip "readme.txt" (which describes the sources) is installed
alongside this file as /usr/local/share/doc/7zip/readme.txt; it is a
different document and is not replaced by this one.


WHAT THE INSTALLER PUTS ON DISK
-------------------------------

The installer offers two components. Both are selected by default.

  Command line tools
    /usr/local/bin/7zz                              the archiver (arm64)
    /usr/local/bin/7z                               symlink to 7zz
    /usr/local/share/man/man1/7zz.1                 manual page
    /usr/local/share/man/man1/7z.1                  same page, for the alias
    /usr/local/share/zsh/site-functions/_7zz        zsh completion
    /usr/local/share/bash-completion/completions/7zz  bash completion
    /usr/local/share/fish/vendor_completions.d/7zz.fish  fish completion
    /usr/local/share/doc/7zip/                      documentation (see below)

  7-Zip application
    /Applications/7-Zip.app                         native GUI application
    /Applications/7-Zip.app/Contents/PlugIns/
        7ZipQuickLook.appex                        Quick Look preview extension

The application supplies the Finder integration: a context menu with
"Compress with 7-Zip" and "Extract with 7-Zip", plus archive previews in
Quick Look (press Space on an archive in Finder).

The installer writes into /usr/local and /Applications, so it asks for an
administrator password.


USING THE APPLICATION
---------------------

The application is a native AppKit front end. The compression engine runs
inside the application process: it is loaded as an embedded library
(Contents/Frameworks/lib7z.dylib) and never spawns a helper process. The one
deliberate exception is DMG creation, which calls the system hdiutil (see
"Additional formats" above).

  Browsing
    Drag an archive onto the window, or open one from Finder. The list shows
    name, size, packed size, ratio, modified time, CRC, method and
    attributes; Finder-style columns appear by default and the rest can be
    enabled from the column header menu. Press Space - or double-click a
    file - for a Quick Look preview, and double-click a folder to expand it.
    Drag entries out to extract them into Finder. The search field filters
    the list as you type.

  Extracting
    "Extract to..." asks for a destination folder and offers a strategy for
    names that already exist: overwrite, skip, or keep both (automatic
    rename). The choice is remembered for next time. Note that macOS 26
    keeps this control behind the "Show Options" button of the system panel.

  Encrypted archives
    The password prompt offers "Remember this archive's password on this
    Mac". If enabled, the password is stored in your login keychain (service
    "org.7-zip.macos", account = the archive's standardized path) and reused
    silently the next time you open that archive. A remembered password that
    is rejected is deleted immediately, so it is never retried in a loop.
    Because this build is ad-hoc signed, macOS may ask once for keychain
    access after a rebuild; "Always Allow" stops further prompts.

  Large archives
    Building the file tree runs on a background queue, so the window stays
    responsive. Entries are read from the engine one at a time and released
    as they are consumed, which halves the peak memory (measurements for a
    100,000-entry archive are in BUILD.md). Column sorting is likewise
    computed off the main thread.


DOCUMENTATION INSTALLED WITH THE COMMAND LINE TOOLS
---------------------------------------------------

  /usr/local/share/doc/7zip/License.txt         upstream licence (LGPL)
  /usr/local/share/doc/7zip/copying.txt         GNU LGPL text
  /usr/local/share/doc/7zip/unRarLicense.txt    unRAR restriction
  /usr/local/share/doc/7zip/readme.txt          upstream source readme
  /usr/local/share/doc/7zip/7zFormat.txt        .7z container specification
  /usr/local/share/doc/7zip/README-macos.txt    this file
  /usr/local/share/doc/7zip/BUILD.md            how this port was built
  /usr/local/share/doc/7zip/uninstall.sh        removal script


VERIFYING THE INSTALLATION
--------------------------

After installing, open Terminal and run:

  /usr/local/bin/7zz

You should see:

  7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03

The "(arm64)" tag confirms you are running the native Apple Silicon code.
This build contains no Intel slice; see "ARCHITECTURE SUPPORT" below.

Quick functional test:

  7zz a -mx=9 test.7z /etc/hosts      # create a compressed archive
  7zz t test.7z                       # verify its integrity
  7zz x test.7z -o/tmp/out -y         # extract it

Read the manual with:  man 7zz

Shell completion is active in a new shell. In zsh it also works for the
"7z" alias, because the completion function is registered for both names.


REMOVING
--------

  sudo sh /usr/local/share/doc/7zip/uninstall.sh

The script removes the binary, the alias, the manual pages, the shell
completions, the documentation directory, the application bundle and its
Quick Look extension, then forgets both package receipts. It does not touch
any archive or file you created.


ARCHITECTURE SUPPORT
--------------------

Every executable in this distribution contains a single native Mach-O
slice:

  arm64   — Apple Silicon (M1 and later)

**There is no x86_64 slice, so this build does not run on Intel Macs.** The
Intel slice was dropped on 2026-09-24: it accounted for nearly half of the
size of every executable in the package, while no Intel Macs remain on sale.
An Intel Mac will refuse to launch these binaries ("bad CPU type in
executable"); Rosetta 2 translates x86_64 code to arm64, not the other way
around, so it cannot help here either.

On Apple Silicon no Rosetta 2 is used — everything runs natively.

Minimum system version is macOS 11.0 (Big Sur), the first release to support
Apple Silicon. The build sets an explicit deployment target rather than
inheriting the build host's SDK default, so the binary is not restricted to
the newest macOS.

Codecs compiled into this build:

  LZMA, LZMA2, PPMd, BZip2, Deflate, Deflate64, Zstd, XZ, LZFSE
  RAR 1/2/3/5 (extraction only)
  AES-256-CBC, ZipCrypto, ZipStrong, PBKDF2-HMAC-SHA1
  Hashers: CRC32, CRC64, MD5, SHA1, SHA256, SHA384, SHA512,
           SHA3-256, XXH64, BLAKE2sp
  Filters: BCJ, BCJ2, ARM, ARM64, ARMT, PPC, IA64, SPARC, RISCV,
           Delta, Swap2, Swap4

Additional formats added by this port (the GUI application only — see the
note below):

  zstd      creation + extraction (upstream 26.03 ships a decoder only)
  lz4       creation + extraction (LZ4 frame format)
  brotli    creation + extraction (no magic number: recognised by extension)
  lzip      creation + extraction (LZMA1 stream in a lzip container)
  snappy    creation + extraction (raw and framed ".sz"; self-implemented)
  ISO 9660  creation, with Joliet (UCS-2) long file names
  DMG       creation (UDZO), delegated to the system hdiutil

Four notes on these:

  * zstd / lz4 / brotli / lzip are provided by statically linked third-party
    libraries (libzstd, liblz4, libbrotli, liblzma). If a library was not
    present when this package was built, the corresponding format was simply
    left out of the binary - the build still succeeds. snappy has no external
    dependency and is always available. Attribution is in THIRD_PARTY.md.

  * gz, bz2, xz, zstd, lz4, br, lz and sz are single-stream formats: they can
    hold one file at a time. Compressing several files into one of them is
    rejected with a clear message instead of silently keeping only the
    first.

  * The format menu shows the format name, but the suggested file name uses
    the conventional extension: zstd -> .zst, lzip -> .lz, snappy -> .sz.
    Both spellings open fine, because the engine normalises the format name.

  * The bundled 7zz command-line tool is a stock upstream build and does
    NOT have these formats. "7zz a -tzstd" / "-tiso" fails by design; the
    new formats are reachable from the application (and from the engine API
    in lib7zbridge.a). Keeping the CLI pristine is what makes upstream
    upgrades a no-op.

  * Creating a DMG runs the system /usr/bin/hdiutil as a child process. This
    is the single deliberate exception to the "no helper process" rule
    (DMG is an Apple-proprietary format with no in-process equivalent);
    everything else, including ISO creation, runs in-process.


ARCHIVE PREVIEW (QUICK LOOK)
----------------------------

Pressing Space on an archive in Finder opens a preview panel that lists the
archive contents. The extension links the bundled 7-Zip engine
(lib7z.dylib) and enumerates entries inside its own process — it never
launches a helper process, and no copy of `7zz` is shipped for it.

Because the engine does the reading, the preview gives a complete file
listing for every format the engine supports:

  all engine formats                  complete file listing, with sizes,
  (7z, ZIP/ZIP64, TAR variants,       packed sizes, timestamps, attributes,
  GZ, BZip2, XZ, Zstd, RAR, CAB,      plus file and folder totals
  ISO 9660, DMG, WIM, …)

If the engine rejects a file, the extension falls back to a built-in
lightweight parser that reads ZIP / TAR / GZIP tables and merely identifies
other containers. Truncated or damaged archives produce an explicit error
(for example "ZIP end-of-central-directory record (EOCD) missing") rather
than a blank panel.


SIGNING STATUS — PLEASE READ
----------------------------

This package is NOT signed with an Apple Developer ID and is NOT
notarized. It was built locally from official source, and the executables
inside carry an ad-hoc signature only, which is what the linker produces by
default on macOS.

Consequences:

  1. macOS Gatekeeper may show "cannot be opened because the developer
     cannot be verified" when you double-click the .pkg. To proceed,
     right-click the .pkg, choose "Open", then confirm.

  2. If an installed executable is ever blocked, clear the quarantine flag:

       xattr -dr com.apple.quarantine /usr/local/bin/7zz
       xattr -dr com.apple.quarantine /Applications/7-Zip.app

  3. Because the Quick Look extension is only ad-hoc signed, it cannot
     launch helper processes (the sandbox requires a real team identity for
     inherited entitlements). This is why the extension links the engine and
     reads archives in-process. See "ARCHIVE PREVIEW" above.

For distribution to other people you should sign with a Developer ID
Installer certificate and notarize with Apple:

  productsign --sign "Developer ID Installer: Your Name (TEAMID)" \
              7-Zip-26.03-macOS.pkg 7-Zip-26.03-macOS-signed.pkg
  xcrun notarytool submit 7-Zip-26.03-macOS-signed.pkg \
        --apple-id <id> --team-id <TEAMID> --password <app-password> --wait
  xcrun stapler staple 7-Zip-26.03-macOS-signed.pkg

The application bundle additionally needs to be signed with a Developer ID
Application certificate before the installer is built, so that the nested
Quick Look extension inherits a team identity.


LICENSE
-------

7-Zip Copyright (C) 1999-2026 Igor Pavlov.

Distributed under the GNU LGPL, with these exceptions:

  - CPP/7zip/Compress/Rar* and the RAR handlers: GNU LGPL together with
    the unRAR license restriction.
  - CPP/7zip/Compress/LzfseDecoder.cpp: BSD 3-clause license.
  - C/ZstdDec.c: BSD 3-clause license.
  - The LZMA SDK: placed in the public domain.

The unRAR sources may be used in any software to handle RAR archives
free of charge, but may NOT be used to re-create a RAR (WinRAR)
compatible archiver.

Full texts are in /usr/local/share/doc/7zip/ after installation.
