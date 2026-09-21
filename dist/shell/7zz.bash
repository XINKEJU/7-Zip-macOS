# bash completion for the 7-Zip command line tool (7zz).
#
# Install as /usr/local/etc/bash_completion.d/7zz (bash-completion v1) or
# /usr/local/share/bash-completion/completions/7zz (bash-completion v2).
# For a manual setup, source this file from ~/.bashrc.

_7zz() {
    local cur prev command i
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    # COMP_CWORD is 0 when the command name itself is being completed; indexing
    # backwards from there is an error in bash 3.2.
    prev=""
    (( COMP_CWORD > 0 )) && prev="${COMP_WORDS[COMP_CWORD-1]}"

    local commands="a b d e h i l rn t u x"
    local archive_types="7z xz bzip2 gzip tar zip wim zstd"
    local hash_types="CRC32 CRC64 SHA1 SHA256 SHA384 SHA512 BLAKE2sp MD5 XXH64"
    local methods="Copy LZMA2 LZMA Deflate Deflate64 BZip2 Zstd PPMd Delta BCJ BCJ2 ARM64 LZ4"

    local common_switches=" \
        -p -t -r -x -i -w -y -bb -ba -bd -bs -bt -scc -scs -slp -slt \
        -sni -snl -snh -snr -stl -stm -stx -spd -spe -ssw -sse"
    local write_switches=" \
        -m -mx -mmt -ms -md -mfb -mtm -v -u -sdel -sfx"
    local read_switches=" \
        -so -si -o -aoa -aos -aou -aot -an -ai -ax -ap"

    # Locate the command word: the first argument that is not a switch value.
    command=""
    for (( i = 1; i < COMP_CWORD; i++ )); do
        case "${COMP_WORDS[i]}" in
            -p*|-t*|-o*|-w*|-m*|-v*|-ai*|-ax*|-ap*|-bb*|-bs*|-scc*|-scs*|-stm*|-stx*) continue ;;
            -*) continue ;;
            *) command="${COMP_WORDS[i]}"; break ;;
        esac
    done

    # Switch value completion, driven by the previous word.
    case "$prev" in
        -t|-stx)
            COMPREPLY=( $(compgen -W "$archive_types" -- "$cur") ); return 0 ;;
        -scrc|-scr)
            COMPREPLY=( $(compgen -W "$hash_types" -- "$cur") ); return 0 ;;
        -m)
            COMPREPLY=( $(compgen -W "$methods" -- "$cur") ); return 0 ;;
        -mx)
            COMPREPLY=( $(compgen -W "0 1 3 5 7 9" -- "$cur") ); return 0 ;;
        -o|-w)
            COMPREPLY=( $(compgen -d -- "$cur") ); return 0 ;;
        -p)
            return 0 ;;
    esac

    # A bare `-o` prefix carries its value in the same word.
    case "$cur" in
        -o*)
            local dir="${cur#-o}"
            COMPREPLY=( $(compgen -d -- "$dir") )
            for (( i = 0; i < ${#COMPREPLY[@]}; i++ )); do
                COMPREPLY[i]="-o${COMPREPLY[i]}"
            done
            return 0 ;;
        -t*) COMPREPLY=( $(compgen -W "$archive_types" -- "${cur#-t}") ); return 0 ;;
        -p*) return 0 ;;
    esac

    if [[ -z "$command" ]]; then
        if [[ "$cur" == -* ]]; then
            COMPREPLY=( $(compgen -W "$common_switches" -- "$cur") )
        else
            COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
        fi
        return 0
    fi

    if [[ "$cur" == -* ]]; then
        local switches="$common_switches"
        case "$command" in
            a|u) switches="$switches $write_switches" ;;
            h)   switches="$switches -scrc -scr" ;;
            *)   switches="$switches $read_switches" ;;
        esac
        COMPREPLY=( $(compgen -W "$switches" -- "$cur") )
        return 0
    fi

    # Positional arguments are archive and file names.
    COMPREPLY=( $(compgen -f -- "$cur") )
    # Directories must keep their trailing slash to stay usable.
    for (( i = 0; i < ${#COMPREPLY[@]}; i++ )); do
        [[ -d "${COMPREPLY[i]}" ]] && COMPREPLY[i]="${COMPREPLY[i]}/"
    done
    return 0
}

complete -o filenames -F _7zz 7zz
complete -o filenames -F _7zz 7z
