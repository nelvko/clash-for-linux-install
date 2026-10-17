#!/usr/bin/env bash

clashlog() {
    if ! _clashctl_in_bash; then
        _clashctl_run_in_bash clashlog "$@"
        return
    fi
    service_log "$@"
}
