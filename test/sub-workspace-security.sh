#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(cd -- "$TEST_DIR/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap '/usr/bin/rm -rf -- "$WORK_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 description=$3
    [ "$expected" = "$actual" ] ||
        fail "$description: expected [$expected], got [$actual]"
}

assert_no_workspace() {
    local artifact
    artifact=$(find "$CLASH_RESOURCES_DIR" -maxdepth 1 -name '.fetch.*' -print -quit)
    [ -z "$artifact" ] || fail "$1: workspace artifact remains at $artifact"
}

wait_for_file() {
    local file=$1 description=$2 attempt
    for ((attempt = 0; attempt < 250; attempt++)); do
        [ -e "$file" ] && return 0
        sleep 0.02
    done
    fail "$description"
}

_errorcat() {
    printf 'ERROR: %s\n' "${*: -1}" >&2
    return 1
}

CLASH_RESOURCES_DIR="$WORK_DIR/resources"
CLASH_CONFIG_DEBUG="$WORK_DIR/last-failed.yaml"
CLASH_CONFIG_DEBUG_RAW="$WORK_DIR/last-failed.raw"
# shellcheck disable=SC2034  # consumed by the sourced subscription module
BIN_SUBCONVERTER_LOG="$WORK_DIR/subconverter.log"
mkdir -p -- "$CLASH_RESOURCES_DIR" "$WORK_DIR/state"
chmod 0755 "$CLASH_RESOURCES_DIR"

# shellcheck source=../scripts/cmd/sub.sh
. "$REPO_DIR/scripts/cmd/sub.sh"

DOWNLOAD_MODE=success
COMMIT_MODE=success
secret_url='https://example.test/sub?token=workspace-secret'

_download_config() {
    local dest=$1 url=$2
    printf 'proxies: [downloaded-node]\n' >"$dest"
    printf 'raw subscription for %s\n' "$url" >"${dest}.raw"
    printf 'utf8 scratch for %s\n' "$url" >"${dest}.utf8"
    printf '%s %s %s %s %s\n' \
        "$(stat -c '%a' "$dest")" \
        "$(stat -c '%a' "${dest}.err")" \
        "$(stat -c '%a' "${dest}.raw")" \
        "$(stat -c '%a' "${dest}.utf8")" \
        "$(umask)" >"$WORK_DIR/state/live-modes"
    printf '%s\n' "$dest" >"$WORK_DIR/state/work-path"
    printf '%s\n' "$BASHPID" >"$WORK_DIR/state/workspace-pid"

    case $DOWNLOAD_MODE in
    hold)
        touch "$WORK_DIR/state/download-ready"
        while :; do sleep 0.02; done
        ;;
    failure)
        printf 'download failed for %s\n' "$url" >&2
        return 28
        ;;
    esac
    return 0
}

_with_profiles_lock() {
    local dl_file=$5
    printf '%s\n' "$dl_file" >"$WORK_DIR/state/commit-candidate"
    [ "$COMMIT_MODE" != failure ] || return 73
    /bin/mv -fT -- "$dl_file" "$WORK_DIR/committed.yaml"
}

parent_umask=$(umask)
umask 022

# A successful download and commit keeps every live artifact private, transfers
# only the committed file, and leaves the caller's umask unchanged.
_sub_with_download_workspace _sub_add_download_and_commit \
    demo "$secret_url" raw false 2>"$WORK_DIR/success.stderr"
assert_eq '600 600 600 600 0077' "$(<"$WORK_DIR/state/live-modes")" \
    'live workspace modes and umask'
assert_eq 600 "$(stat -c '%a' "$WORK_DIR/committed.yaml")" 'committed profile mode'
assert_eq 0022 "$(umask)" 'caller umask after successful transaction'
assert_no_workspace 'successful commit cleanup'

# Once downloading succeeds, a later lock/commit failure must preserve that
# status while the EXIT guard removes the uncommitted candidate and sidecars.
/usr/bin/rm -f -- "$WORK_DIR/committed.yaml"
COMMIT_MODE=failure
set +e
_sub_with_download_workspace _sub_add_download_and_commit \
    demo "$secret_url" raw false 2>"$WORK_DIR/commit-failure.stderr"
commit_rc=$?
set -e
assert_eq 73 "$commit_rc" 'commit failure exit code'
commit_candidate=$(<"$WORK_DIR/state/commit-candidate")
[ ! -e "$commit_candidate" ] || fail 'commit failure left downloaded candidate behind'
assert_eq 0022 "$(umask)" 'caller umask after commit failure'
assert_no_workspace 'commit failure cleanup'

# Failed downloads still retain the existing stable debug artifacts, but those
# files are private and no transient workspace names remain.
DOWNLOAD_MODE=failure
COMMIT_MODE=success
set +e
_sub_with_download_workspace _sub_add_download_and_commit \
    demo "$secret_url" raw false 2>"$WORK_DIR/download-failure.stderr"
download_rc=$?
set -e
assert_eq 1 "$download_rc" 'download failure business exit code'
[ -s "$CLASH_CONFIG_DEBUG" ] || fail 'failed candidate debug file was not retained'
[ -s "$CLASH_CONFIG_DEBUG_RAW" ] || fail 'failed raw debug file was not retained'
assert_eq 600 "$(stat -c '%a' "$CLASH_CONFIG_DEBUG")" 'failed candidate debug mode'
assert_eq 600 "$(stat -c '%a' "$CLASH_CONFIG_DEBUG_RAW")" 'failed raw debug mode'
assert_no_workspace 'download failure cleanup'

# TERM keeps the conventional 143 status and removes the live candidate,
# error log, raw copy, and encoding scratch file.
/usr/bin/rm -f -- "$CLASH_CONFIG_DEBUG" "$CLASH_CONFIG_DEBUG_RAW"
/usr/bin/rm -f -- "$WORK_DIR/state/download-ready"
DOWNLOAD_MODE=hold
set +e
_sub_with_download_workspace _sub_add_download_and_commit \
    demo "$secret_url" raw false 2>"$WORK_DIR/term.stderr" &
term_job=$!
set -e
wait_for_file "$WORK_DIR/state/download-ready" 'TERM download did not enter the workspace'
term_owner=$(<"$WORK_DIR/state/workspace-pid")
kill -TERM "$term_owner" 2>/dev/null || true
set +e
wait "$term_job"
term_rc=$?
set -e
assert_eq 143 "$term_rc" 'TERM workspace exit code'
term_work=$(<"$WORK_DIR/state/work-path")
[ ! -e "$term_work" ] || fail 'TERM left downloaded candidate behind'
assert_eq 0022 "$(umask)" 'caller umask after TERM'
assert_no_workspace 'TERM cleanup'

umask "$parent_umask"
printf 'sub-workspace-security: ok\n'
