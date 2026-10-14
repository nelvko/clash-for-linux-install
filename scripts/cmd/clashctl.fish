if not set -q CLASHCTL_HOME
    # CLASHCTL_HOME is injected at install time (see preflight.sh apply_rc).
    # If absent, the installer did not finish — bail out quietly.
    exit 0
end

function __clashctl_run --description 'invoke a clash* bash function with argv'
    set -l fn $argv[1]
    bash -c '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && "$1" "${@:2}"' -- $fn $argv[2..-1]
end

function __clashctl_state_path
    if set -q XDG_CACHE_HOME
        echo $XDG_CACHE_HOME/clashctl/proxy.fish
    else
        echo $HOME/.cache/clashctl/proxy.fish
    end
end

function clashon --description 'enable terminal proxy, starting the kernel if needed'
    if set -q argv[1]
        __clashctl_run clashon $argv
        return $status
    end

    set -l state (__clashctl_state_path)
    mkdir -p -- (dirname -- $state)
    set -l tmp $state.tmp.$fish_pid

    bash -c '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && clashon "$@" 1>&2 && _dump_proxy_env_fish' -- $argv >$tmp
    set -l rc $status

    if test $rc -ne 0
        rm -f -- $tmp
        return $rc
    end

    mv -f -- $tmp $state
    source $state
end

function clashoff --description 'disable terminal proxy, optionally stopping the kernel'
    if set -q argv[1]
        if test (count $argv) -ne 1; or test "$argv[1]" != --stop
            __clashctl_run clashoff $argv
            return $status
        end
    end

    # 有效的 off 请求始终清理当前终端，即使 --stop 未能停止内核。
    rm -f -- (__clashctl_state_path)
    set -e http_proxy https_proxy HTTP_PROXY HTTPS_PROXY \
        all_proxy ALL_PROXY no_proxy NO_PROXY
    __clashctl_run clashoff $argv
end

function clashctl
    set -l sub help
    if set -q argv[1]
        set sub $argv[1]
        set argv $argv[2..-1]
    end
    switch $sub
        case -h --help help
            set sub help
        case -v --version
            set sub version
        case '-*'
            echo "Unknown option: $sub" >&2
            echo "Use 'clashctl help' for usage information." >&2
            return 1
    end

    set -l target clash$sub
    if not functions -q $target
        echo "Unknown subcommand: $sub" >&2
        echo "Use 'clashctl help' for usage information." >&2
        return 1
    end
    $target $argv
end

# Auto-define clash<name> wrappers for every cmd/*.sh except those we own.
if test -d $CLASHCTL_HOME/scripts/cmd
    for cmd_file in $CLASHCTL_HOME/scripts/cmd/*.sh
        set -l base (basename -- $cmd_file .sh)
        switch $base
            case clashctl on off
                continue
        end
        set -l fn clash$base
        if functions -q $fn
            continue
        end
        function $fn --inherit-variable fn
            __clashctl_run $fn $argv
        end
    end
end
