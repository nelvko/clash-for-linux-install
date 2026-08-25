# Zsh adapter: keep the implementation in Bash and bridge only parent-shell state.

__clashctl_run() {
    local fn=$1
    shift
    command bash -c '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && "$1" "${@:2}"' \
        -- "$fn" "$@"
}

clashon() {
    if [ "${CLASHCTL_MANAGE_SHELL_PROXY:-1}" = 0 ] && [ "$#" -eq 0 ]; then
        __clashctl_run on_service_only
        return
    fi

    case "${1:-}" in
    -s | --service-only | -h | --help)
        __clashctl_run clashon "$@"
        return
        ;;
    esac

    local env_code
    env_code=$(command bash -c \
        '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && clashon "$@" 1>&2 && _dump_proxy_env_zsh' \
        -- "$@")
    local rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    eval "$env_code"
}

clashoff() {
    if [ "${CLASHCTL_MANAGE_SHELL_PROXY:-1}" = 0 ] && [ "$#" -eq 0 ]; then
        __clashctl_run off_service_only
        return
    fi

    local drop_env=true
    case "${1:-}" in
    -s | --service-only | -h | --help) drop_env=false ;;
    esac

    __clashctl_run clashoff "$@"
    local rc=$?

    if [ "$drop_env" = true ]; then
        unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY \
            all_proxy ALL_PROXY no_proxy NO_PROXY
    fi
    return "$rc"
}

local cmd_file base fn
for cmd_file in "$CLASHCTL_HOME"/scripts/cmd/*.sh(N); do
    base=${cmd_file:t:r}
    case "$base" in
    clashctl | on | off) continue ;;
    esac
    fn="clash${base}"
    (( $+functions[$fn] )) && continue
    eval "${fn}() { __clashctl_run ${fn} \"\$@\"; }"
done
unset cmd_file base fn

clashctl() {
    local sub_cmd=${1:-help}
    [ "$#" -eq 0 ] || shift

    case "$sub_cmd" in
    -h | --help | help) sub_cmd=help ;;
    esac

    local target="clash${sub_cmd}"
    (( $+functions[$target] )) || {
        print -u2 -- "Unknown subcommand: $target"
        print -u2 -- "Use 'clashctl help' for usage information."
        return 1
    }
    "$target" "$@"
}
