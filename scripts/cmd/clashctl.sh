for lib_file in "$CLASHCTL_HOME"/scripts/lib/*.sh; do
    [ -f "$lib_file" ] || continue
    . "$lib_file"
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
        _fail_cat "Unknown subcommand: $cmd"
        _fail_cat "Use 'clashctl help' for usage information."
        ;;
    esac

}
