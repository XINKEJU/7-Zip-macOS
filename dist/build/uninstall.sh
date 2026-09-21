#!/bin/sh
#
# Uninstall script for the 7-Zip 26.03 macOS package.
#
# Removes everything that 7-Zip-26.03-macOS.pkg installed:
#
#   the command line engine and its "7z" alias
#   the manual pages
#   the zsh / bash / fish shell completions
#   the documentation directory (including this script)
#   the application bundle and its Quick Look extension
#   both package receipts
#
# It removes nothing else. Archives, directories and files that you created
# are never touched, and unrelated content inside a shared directory is left
# alone: the completion directories and the "7z" alias are only cleaned up
# when the entry really belongs to this package.
#
# Usage:  sudo sh uninstall.sh
#

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Try:  sudo sh $0" >&2
    exit 1
fi

PREFIX="/usr/local"
BIN="${PREFIX}/bin"
MAN="${PREFIX}/share/man/man1"
DOC="${PREFIX}/share/doc/7zip"
ZSHC="${PREFIX}/share/zsh/site-functions"
BASHC="${PREFIX}/share/bash-completion/completions"
FISHC="${PREFIX}/share/fish/vendor_completions.d"
APP="/Applications/7-Zip.app"
APPEX="${APP}/Contents/PlugIns/7ZipQuickLook.appex"

REMOVED=0

remove_file() {
    # remove_file <path> <description>
    if [ -f "$1" ] || [ -L "$1" ]; then
        rm -f "$1"
        echo "  removed $2"
        REMOVED=$((REMOVED + 1))
    fi
}

echo "Removing 7-Zip 26.03 ..."

# --- command line engine ---------------------------------------------------
remove_file "${BIN}/7zz" "bin/7zz"

# The "7z" entry is only removed when it really is our alias.
if [ -L "${BIN}/7z" ]; then
    target=$(readlink "${BIN}/7z")
    case "${target}" in
        *7zz)
            rm -f "${BIN}/7z"
            echo "  removed bin/7z"
            REMOVED=$((REMOVED + 1))
            ;;
        *)
            echo "  kept bin/7z (points at '${target}', not managed by this package)"
            ;;
    esac
elif [ -f "${BIN}/7z" ]; then
    echo "  kept bin/7z (regular file, not the symlink this package installs)"
fi

# --- manual pages ----------------------------------------------------------
remove_file "${MAN}/7zz.1" "man1/7zz.1"
remove_file "${MAN}/7z.1"  "man1/7z.1"

# --- shell completions -----------------------------------------------------
remove_file "${ZSHC}/_7zz"               "zsh completion _7zz"
remove_file "${BASHC}/7zz"               "bash completion 7zz"
remove_file "${FISHC}/7zz.fish"          "fish completion 7zz.fish"

# --- documentation (and this script) ---------------------------------------
# The files are removed one by one and the directory is then removed only if it
# turned out to be empty. Using "rm -rf" on the directory would also delete
# anything a user happened to save inside it.
if [ -d "${DOC}" ]; then
    for f in License.txt copying.txt unRarLicense.txt readme.txt 7zFormat.txt \
             README-macos.txt BUILD.md uninstall.sh; do
        remove_file "${DOC}/${f}" "share/doc/7zip/${f}"
    done
    if rmdir "${DOC}" 2>/dev/null; then
        echo "  removed share/doc/7zip/"
        REMOVED=$((REMOVED + 1))
    else
        echo "  kept share/doc/7zip/ (still contains files this package did not install)"
    fi
fi

# --- application and Quick Look extension ----------------------------------
# Unregister the extension first so the running system stops offering it.
if [ -d "${APPEX}" ]; then
    pluginkit -r "${APPEX}" >/dev/null 2>&1 || true
fi
if [ -d "${APP}" ]; then
    # Ask LaunchServices to forget the bundle before deleting it.
    LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    [ -x "${LSREG}" ] && "${LSREG}" -u "${APP}" >/dev/null 2>&1 || true
    rm -rf "${APP}"
    echo "  removed /Applications/7-Zip.app"
    REMOVED=$((REMOVED + 1))
fi

# --- package receipts ------------------------------------------------------
for id in com.7-zip.7zz com.7-zip.7zip; do
    if pkgutil --pkg-info "$id" >/dev/null 2>&1; then
        pkgutil --forget "$id" >/dev/null 2>&1
        echo "  forgot package receipt $id"
        REMOVED=$((REMOVED + 1))
    fi
done

echo
if [ "$REMOVED" -eq 0 ]; then
    echo "Nothing to remove: 7-Zip 26.03 does not appear to be installed."
else
    echo "Done. 7-Zip 26.03 has been uninstalled."
fi
