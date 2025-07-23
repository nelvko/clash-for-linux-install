set fn_arr \
clash \
clashctl \
mihomo \
mihomoctl \
\
clashui \
clashstatus \
clashsecret \
clashtun \
clashmixin \
clashupdate

set -gx fish_version $FISH_VERSION

for fn in $fn_arr
    eval \
    "function $fn
        bash -i -c '$fn \$@;exec fish -i' -- \$argv
    end"
end

function clashon
    bash -i -c 'clashon; sudo tee /var/proxy >/dev/null <<EOF
export http_proxy=$http_proxy
export https_proxy=$http_proxy
export HTTP_PROXY=$http_proxy
export HTTPS_PROXY=$http_proxy

export all_proxy=$all_proxy
export ALL_PROXY=$all_proxy

export no_proxy=$no_proxy
export NO_PROXY=$no_proxy
EOF'

    source /var/proxy
end

function clashoff
    bash -i -c 'clashoff'

    set -e \
    http_proxy \
    https_proxy \
    HTTP_PROXY \
    HTTPS_PROXY \
    all_proxy \
    ALL_PROXY \
    no_proxy \
    NO_PROXY
end