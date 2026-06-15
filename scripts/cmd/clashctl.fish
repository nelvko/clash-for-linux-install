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

function clashon --description 'start clash service and/or enable proxy env'
    set -l capture 1
    if set -q argv[1]
        switch $argv[1]
            case -s --service-only -h --help
                set capture 0
        end
    end

    if test $capture -eq 0
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

function clashoff --description 'stop clash service and/or disable proxy env'
    set -l drop_env 1
    if set -q argv[1]
        switch $argv[1]
            case -s --service-only -h --help
                set drop_env 0
        end
    end

    __clashctl_run clashoff $argv
    set -l rc $status

    if test $drop_env -eq 1
        rm -f -- (__clashctl_state_path)
        set -e http_proxy https_proxy HTTP_PROXY HTTPS_PROXY \
            all_proxy ALL_PROXY no_proxy NO_PROXY
    end
    return $rc
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
    end

    set -l target clash$sub
    if not functions -q $target
        echo "Unknown subcommand: $target"
        echo "Use 'clashctl help' for usage information."
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
