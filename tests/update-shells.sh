#!/usr/bin/env bash
# 真实 Bash/Zsh 加载器与 Git/压缩包更新；只有下载来源替换成本地 fixture。
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v zsh >/dev/null || fail 'zsh is required'
export REAL_GIT SOURCE_REPO="$WORK_DIR/source" SOURCE_ARCHIVE="$WORK_DIR/source.tar.gz"
REAL_GIT=$(command -v git)
mkdir -p "$SOURCE_REPO" "$WORK_DIR/bin"
cp -a "$REPO_DIR/scripts" "$SOURCE_REPO/"
cp "$REPO_DIR/"{install.sh,uninstall.sh,.env.example,.gitignore} "$SOURCE_REPO/"
printf 'CLASHCTL_TEST_VERSION=old\n' >"$SOURCE_REPO/scripts/cmd/version.sh"
"$REAL_GIT" -C "$SOURCE_REPO" init -q -b master
"$REAL_GIT" -C "$SOURCE_REPO" config user.email test@example.invalid
"$REAL_GIT" -C "$SOURCE_REPO" config user.name test
"$REAL_GIT" -C "$SOURCE_REPO" add .
"$REAL_GIT" -C "$SOURCE_REPO" commit -qm initial
. "$REPO_DIR/install.sh"
for shell in bash zsh; do
    for method in git archive; do
        home_dir="$WORK_DIR/$shell-$method"
        if [ "$method" = git ]; then
            "$REAL_GIT" clone -q "$SOURCE_REPO" "$home_dir"
        else
            mkdir "$home_dir"
            "$REAL_GIT" -C "$SOURCE_REPO" archive HEAD | tar -x -C "$home_dir"
            _source_manifest "$home_dir" >"$home_dir/.clashctl-files"
        fi
        printf '%s\n%s\n' "$home_dir" "$method" >"$home_dir/.clashctl-install"
        printf 'CLASHCTL_KERNEL=mihomo\nCLASHCTL_UPDATE_BRANCH=master\nGH_PROXY=\n' >"$home_dir/.env"
    done
done
printf 'CLASHCTL_TEST_VERSION=new\n' >"$SOURCE_REPO/scripts/cmd/version.sh"
"$REAL_GIT" -C "$SOURCE_REPO" commit -qam update
"$REAL_GIT" -C "$SOURCE_REPO" archive --prefix=source/ HEAD | gzip >"$SOURCE_ARCHIVE"
cat >"$WORK_DIR/bin/git" <<'STUB'
#!/usr/bin/env bash
args=()
for arg in "$@"; do
    case "$arg" in *github.com/nelvko/clash-for-linux-install.git) arg=$SOURCE_REPO ;; esac
    args+=("$arg")
done
exec "$REAL_GIT" "${args[@]}"
STUB
cat >"$WORK_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
    case "$1" in -o) destination=$2; shift ;; esac
    shift
done
cp "$SOURCE_ARCHIVE" "$destination"
STUB
chmod +x "$WORK_DIR/bin/"*
for shell in bash zsh; do
    shell_args=(-c)
    [ "$shell" != zsh ] || shell_args=(-f -c)
    for method in git archive; do
        # shellcheck disable=SC2016  # 变量由被测 Shell 展开。
        PATH="$WORK_DIR/bin:$PATH" CLASHCTL_HOME="$WORK_DIR/$shell-$method" "$shell" "${shell_args[@]}" '
            . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || exit 1
            [ "$CLASHCTL_TEST_VERSION" = old ] || exit 1
            clashctl update || exit 1
            [ "$CLASHCTL_TEST_VERSION" = new ] || exit 1
        ' >"$WORK_DIR/output" 2>&1 || { cat "$WORK_DIR/output"; fail "$shell $method update failed"; }
    done
done
printf 'update-shells: ok\n'
