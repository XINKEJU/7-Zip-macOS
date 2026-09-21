# fish completion for the 7-Zip command line tool (7zz).
#
# Install as /usr/local/share/fish/vendor_completions.d/7zz.fish, or copy to
# ~/.config/fish/completions/7zz.fish for a per-user setup.

# ---------------------------------------------------------------- commands --

set -l __7zz_commands a b d e h i l rn t u x

complete -c 7zz -f
complete -c 7z  -f

complete -c 7zz -n "not __fish_seen_subcommand_from $__7zz_commands" \
    -a a  -d "Add files to archive"
complete -c 7zz -n "not __fish_seen_subcommand_from $__7zz_commands" \
    -a b  -d "Benchmark CPU and compression speed"
complete -c 7zz -n "not __fish_seen_subcommand_from $__7zz_commands" \
    -a d  -d "Delete files from archive"
complete -c 7zz -n "not __fish_seen_subcommand_from $__7zz_commands" \
    -a e  -d "Extract files without directory names"
complete -c 7zz -n "not __fish_seen_subcommand_from $__7zz_commands" \
    -a h  -d "Calculate hash values for files"
complete -c 7zz -n "not __fish_seen_subcommand_from $__7zz_commands" \
    -a i  -d "Show information about supported formats"
complete -c 7zz -n "not __fish_seen_subcommand_from $__7zz_commands" \
    -a l  -d "List contents of archive"
complete -c 7zz -n "not __fish_seen_subcommand_from $__7zz_commands" \
    -a rn -d "Rename files inside archive"
complete -c 7zz -n "not __fish_seen_subcommand_from $__7zz_commands" \
    -a t  -d "Test integrity of archive"
complete -c 7zz -n "not __fish_seen_subcommand_from $__7zz_commands" \
    -a u  -d "Update files to archive"
complete -c 7zz -n "not __fish_seen_subcommand_from $__7zz_commands" \
    -a x  -d "Extract files with full paths"

# ---------------------------------------------------- switches: all commands --

complete -c 7zz -s p -d "Set password" -r
complete -c 7zz -s t -d "Set archive type" \
    -x -a "7z xz bzip2 gzip tar zip wim zstd"
complete -c 7zz -s r -d "Recurse subdirectories"
complete -c 7zz -s x -d "Exclude filenames or wildcards" -r
complete -c 7zz -s i -d "Include filenames or wildcards" -r
complete -c 7zz -s w -d "Set working directory" -x -a "(__fish_complete_directories)"
complete -c 7zz -s y -d "Assume Yes on all queries"
complete -c 7zz -o bb -d "Set output log level" -x -a "0 1 2 3"
complete -c 7zz -o ba -d "Disable progress indicator"
complete -c 7zz -o bd -d "Disable progress indicator"
complete -c 7zz -o bs -d "Set output stream" -x -a "o e 1 2"
complete -c 7zz -o bt -d "Show execution time statistics"
complete -c 7zz -o scc -d "Set console charset" -x -a "UTF-8 UTF-16LE"
complete -c 7zz -o scs -d "Set list file charset" -x -a "UTF-8 UTF-16LE"
complete -c 7zz -o slp -d "Set Large Pages mode"
complete -c 7zz -o slt -d "Show technical information in list output"
complete -c 7zz -o sni -d "Store NT security information"
complete -c 7zz -o snl -d "Store symbolic links as links"
complete -c 7zz -o snh -d "Store hard links as links"
complete -c 7zz -o snr -d "Store macOS resource forks"
complete -c 7zz -o stl -d "Set archive timestamp from newest file"
complete -c 7zz -o stm -d "Set hash value for the archive" -r
complete -c 7zz -o stx -d "Exclude archive type" -x -a "7z xz bzip2 gzip tar zip wim zstd"
complete -c 7zz -o spd -d "Disable wildcard matching for file names"
complete -c 7zz -o spe -d "Disable parsing of wildcards after -r"
complete -c 7zz -o ssw -d "Synchronize files for solid blocks"
complete -c 7zz -o sse -d "Stop if an input file cannot be opened"

# ------------------------------------------------ switches: create / update --

set -l __7zz_write a u
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_write" \
    -s m -d "Set compression method" -x \
    -a "Copy LZMA2 LZMA Deflate Deflate64 BZip2 Zstd PPMd Delta BCJ BCJ2 ARM64 LZ4"
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_write" \
    -o mx -d "Set compression level" -x -a "0 1 3 5 7 9"
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_write" \
    -o mmt -d "Set number of CPU threads" -r
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_write" \
    -o ms -d "Set solid mode" -x -a "on off 4m 8m 16m e"
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_write" \
    -o md -d "Set dictionary size" -r
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_write" \
    -o mfb -d "Set number of fast bytes" -r
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_write" \
    -s v -d "Create volumes" -r
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_write" \
    -s u -d "Set update options" -r
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_write" \
    -o sdel -d "Delete files after compression"
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_write" \
    -o sfx -d "Create SFX archive" -r

# ------------------------------------------------------ switches: read only --

set -l __7zz_read d e l rn t x
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_read" \
    -o so -d "Write data to stdout"
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_read" \
    -o si -d "Read data from stdin"
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_read" \
    -s o -d "Set output directory" -x -a "(__fish_complete_directories)"
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_read" \
    -o aoa -d "Overwrite all existing files"
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_read" \
    -o aos -d "Skip extracting of existing files"
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_read" \
    -o aou -d "Rename extracted files if they already exist"
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_read" \
    -o aot -d "Rename existing files before extracting"
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_read" \
    -o an -d "Disable parsing of the archive name"
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_read" \
    -o ai -d "Include archive names" -r
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_read" \
    -o ax -d "Exclude archive names" -r
complete -c 7zz -n "__fish_seen_subcommand_from $__7zz_read" \
    -o ap -d "Set path inside archive" -r

# ------------------------------------------------------- switches: hashing --

complete -c 7zz -n "__fish_seen_subcommand_from h" \
    -o scrc -d "Set hash method" -x \
    -a "CRC32 CRC64 SHA1 SHA256 SHA384 SHA512 BLAKE2sp MD5 XXH64"
complete -c 7zz -n "__fish_seen_subcommand_from h" \
    -o scr -d "Set hash method" -x \
    -a "CRC32 CRC64 SHA1 SHA256 SHA384 SHA512 BLAKE2sp MD5 XXH64"

# ------------------------------------------------------------- file names --

complete -c 7zz -n "__fish_seen_subcommand_from a u d e l rn t x" \
    -F -d "Archive or file"

# Mirror every completion onto the `7z` alias.
complete -c 7z -w 7zz
