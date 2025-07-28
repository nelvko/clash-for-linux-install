del_arch_branch() {
    for branch in $(git for-each-ref --format='%(refname:short)' refs/remotes/origin/arch*); do 
        short_branch="${branch#origin/}"
        # git branch -D "$short_branch"
        git push origin --delete "$short_branch"
    done
}
https://github.com/MetaCubeX/mihomo/releases/download/v1.19.12/mihomo-linux-arm64-v1.19.12.gz

https://github.com/mikefarah/yq/releases/download/v4.47.1/yq_linux_arm64.tar.gz

https://github.com/tindy2013/subconverter/releases/download/v0.9.0/subconverter_linux32.tar.gz

https://github.com/mikefarah/yq/releases/download/v4.47.1/yq_linux_amd64.tar.gz