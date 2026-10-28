# Shared helpers for hfd-aria2.sh and hfd-aria2-rpc.sh.
#
# load_env_file reads KEY=VALUE pairs (with or without an "export " prefix) and
# exports them ONLY when the variable is not already set. That keeps an explicit
# `export FOO=bar` on the command line or in the container environment
# authoritative, while the file still supplies every default.

load_env_file() {
    local file="$1" line key value

    [ -f "$file" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"

        case "$line" in
            ''|'#'*) continue ;;
        esac

        case "$line" in
            export[[:space:]]*) line="${line#export }" ;;
        esac

        case "$line" in
            *=*) ;;
            *) continue ;;
        esac

        key="${line%%=*}"
        value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"

        case "$key" in
            [A-Za-z_]*) ;;
            *) continue ;;
        esac

        case "$value" in
            '"'*'"') value="${value#\"}"; value="${value%\"}" ;;
            "'"*"'") value="${value#\'}"; value="${value%\'}" ;;
        esac

        eval "[ -n \"\${$key+set}\" ]" && continue
        export "$key=$value"
    done < "$file"

    return 0
}
