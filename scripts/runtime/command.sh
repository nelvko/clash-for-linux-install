#!/usr/bin/env bash

CLASHCTL_HOME="${CLASHCTL_HOME:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
[ -f "$CLASHCTL_HOME/.env" ] && . "$CLASHCTL_HOME/.env"
CLASHCTL_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export CLASHCTL_HOME


. "$CLASHCTL_HOME"/scripts/runtime/common.sh
. "$CLASHCTL_HOME"/scripts/runtime/convert.sh
. "$CLASHCTL_HOME"/scripts/runtime/env.sh
. "$CLASHCTL_HOME"/scripts/runtime/kernel.sh
. "$CLASHCTL_HOME"/scripts/runtime/service.sh

for cmd_file in "$CLASHCTL_HOME"/scripts/cmd/*.sh; do
    [ -f "$cmd_file" ] || continue
    . "$cmd_file"
done

clashctl() {
    local subcommand=${1:-help}
    [ $# -gt 0 ] && shift

    case "$subcommand" in
    on)
        clashon "$@"
        ;;
    off)
        clashoff "$@"
        ;;
    status)
        clashstatus "$@"
        ;;
    ui)
        clashui "$@"
        ;;
    sub)
        clashsub "$@"
        ;;
    log)
        clashlog "$@"
        ;;
    tun)
        clashtun "$@"
        ;;
    mixin)
        clashmixin "$@"
        ;;
    secret)
        clashsecret "$@"
        ;;
    upgrade)
        clashupgrade "$@"
        ;;
    help | -h | --help)
        clashhelp "$@"
        ;;
    *)
        clashhelp >&2
        return 1
        ;;
    esac
}
