#!/usr/bin/env bash

. "$CLASHCTL_HOME"/.env

for lib_file in "$CLASHCTL_HOME"/scripts/lib/*.sh; do
    . "$lib_file"
done

for cmd_file in "$CLASHCTL_HOME"/scripts/cmd/*.sh; do
    case "$cmd_file" in *clashctl*) continue ;; esac
    . "$cmd_file"
done

clashctl() {
    local cmd
    cmd=${1:-help}
    shift

    case $cmd in
    -h | --help | help)
        clashhelp "$@"
        ;;
    on)
        clashon "$@"
        ;;
    off)
        clashoff "$@"
        ;;
    ui)
        clashui "$@"
        ;;
    status)
        clashstatus "$@"
        ;;
    log)
        clashlog "$@"
        ;;
    proxy)
        clashproxy "$@"
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
    sub)
        clashsub "$@"
        ;;
    upgrade)
        clashupgrade "$@"
        ;;
    *)
        _failcat "Unknown subcommand: $cmd"
        _failcat "Use 'clashctl help' for usage information."
        ;;
    esac

}
