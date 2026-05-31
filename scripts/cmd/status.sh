#!/usr/bin/env bash

function clashstatus() {
    service_status "$@"
    service_is_active >&/dev/null
}
