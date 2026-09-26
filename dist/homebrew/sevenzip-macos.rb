# Homebrew formula for the native macOS build of 7-Zip.
#
# This installs the command line engine (`7zz`) together with its manual pages,
# shell completions and upstream documentation. The native GUI application and
# the Finder / Quick Look integration are distributed separately as an
# installer package, because Homebrew does not manage .app bundles or app
# extensions.
#
# ---------------------------------------------------------------------------
# Why the formula is called sevenzip-macos and not 7zip-macos
# ---------------------------------------------------------------------------
# Homebrew derives the expected Ruby class name from the formula file name via
# Formulary.class_s. For "7zip-macos" that yields "7zipMacos", which begins with
# a digit and is therefore not a legal Ruby constant -- the formula cannot be
# loaded at all. "sevenzip-macos" yields "SevenzipMacos", which is valid.
#
# The name is deliberately not plain "sevenzip" either, because that formula
# already exists in homebrew-core; using it here would collide with (and
# shadow) the core formula.
#
# ---------------------------------------------------------------------------
# Publishing
# ---------------------------------------------------------------------------
# Place this file in a tap (for example XINKEJU/homebrew-tap as
# Formula/sevenzip-macos.rb) and upload the tarball referenced by `url`.
#
# ---------------------------------------------------------------------------
# Installing without a tap
# ---------------------------------------------------------------------------
# Homebrew can install straight from a local formula file, which is the quickest
# way to verify the formula before publishing:
#
#     brew install --formula ./sevenzip-macos.rb
#
# For that to work the `url` must be reachable. To test the packaging locally,
# point it at the tarball produced by dist/build/package.sh:
#
#     url "file:///path/to/7zip-macos-26.03-macos-arm64.tar.gz"
#
# The checksum below is the authoritative hash of the published artefact. The
# payload is arm64-only, so a single download serves every supported machine
# and no per-architecture bottle is required.
#
class SevenzipMacos < Formula
  desc "File archiver with a high compression ratio (native macOS build)"
  homepage "https://www.7-zip.org/"
  # The release tag carries the port's revision suffix (v26.03.1) while the
  # artefact filenames keep the upstream version (26.03) -- `version` below must
  # stay 26.03 because the formula's test block asserts that `7zz i` prints it.
  url "https://github.com/XINKEJU/7-Zip-macOS/releases/download/v26.03.1/7zip-macos-26.03-macos-arm64.tar.gz"
  sha256 "be645638742fa44a45a8e4fad226fe755b5dbd3645132c9b263616902c18d6bc"
  version "26.03"
  license "LGPL-2.1-or-later"

  # The command line engine is built with a deployment target of macOS 11.
  depends_on macos: ">= :big_sur"

  # Apple Silicon only: the x86_64 slice was dropped on 2026-09-24 (it accounted
  # for nearly half of every executable's size). Declaring it here turns an
  # otherwise baffling "bad CPU type in executable" at run time into an upfront,
  # explicit refusal at install time.
  depends_on arch: :arm64

  def install
    bin.install "bin/7zz"

    # 7z.1 is a `.so` include of 7zz.1, so `man 7z` resolves for users who
    # alias the command.
    man1.install "share/man/man1/7zz.1"
    man1.install "share/man/man1/7z.1"

    zsh_completion.install  "share/zsh/site-functions/_7zz"
    bash_completion.install "share/bash-completion/completions/7zz"
    fish_completion.install "share/fish/vendor_completions.d/7zz.fish"

    doc.install Dir["share/doc/7zip/*"]
  end

  def caveats
    <<~EOS
      This formula installs the command line engine only.

      The native GUI application, the Finder context menu items and the Quick
      Look archive preview are app-extension based and are therefore shipped in
      the installer package instead:

        7-Zip-26.03-macOS.pkg

      The manual page is installed as `man 7zz` (and `man 7z`).
    EOS
  end

  test do
    # The engine must report its own version and a populated format list.
    assert_match version.to_s, shell_output("#{bin}/7zz i")

    (testpath/"hello.txt").write "hello from 7-Zip\n"

    # Round trip: create, verify, list and extract.
    system bin/"7zz", "a", "-t7z", "round.7z", "hello.txt"
    assert_path_exists testpath/"round.7z"

    assert_match "Everything is Ok", shell_output("#{bin}/7zz", "t", "round.7z")

    listing = shell_output("#{bin}/7zz", "l", "round.7z")
    assert_match "hello.txt", listing

    system bin/"7zz", "x", "-y", "round.7z", "-o#{testpath}/out"
    assert_equal "hello from 7-Zip\n", (testpath/"out/hello.txt").read
  end
end
