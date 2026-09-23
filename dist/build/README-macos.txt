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


ARCHIVE PREVIEW (QUICK LOOK)
----------------------------

Pressing Space on an archive in Finder opens a preview panel that lists the
archive contents. The extension reads the container directly, inside its own
sandbox, and never launches a helper process.

Contents are reported for these containers:

  ZIP / ZIP64, TAR, TAR.GZ, GZ        complete file listing, with sizes,
                                      packed sizes, timestamps and methods
  7z, XZ, BZip2, Zstd, RAR, CAB,      container identification, format and
  cpio, ISO 9660, DMG, .Z, lzip       compression method, plus a note when
                                      the entry list requires decompression

For containers whose directory cannot be read without decompressing, the
panel shows the detected format and parameters instead of an entry table.
This is a deliberate limitation: reading a 7z entry list would require
running the archiver outside the sandbox.


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
     inherited entitlements). This is why the preview reader is implemented
     in-process. See "ARCHIVE PREVIEW" above.

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
