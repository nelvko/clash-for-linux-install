set fn_arr \
clashui \
clashstatus \
clashsecret \
clashtun \
clashmixin \
clashsub \
clashlog \
clashupgrade \
clashhelp

set -gx fish_version $FISH_VERSION

for fn in $fn_arr
    eval "
    function $fn
        bash -i -c '$fn \"\$@\"' -- \$argv
    end
    "
end


function clashctl
    if test -z "$argv"
        clashhelp
        return
    end


    set suffix $argv[1]
    set argv $argv[2..-1]

    switch $suffix
        case on
            clashon $argv
        case off
            clashoff $argv
        case proxy
            clashproxy $argv
        case '*'
            clash"$suffix" $argv
    end
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

    clashproxy on
end

function clashoff
    bash -i -c 'clashoff'
    clashproxy off
end

function clashproxy
    if test (count $argv) -eq 0
        echo "Usage: clashproxy [on|off]"
        return 1
    end
    switch $argv[1]
        case on
            source /var/proxy
            echo '已开启系统代理'
        case off
            set -e \
            http_proxy \
            https_proxy \
            HTTP_PROXY \
            HTTPS_PROXY \
            all_proxy \
            ALL_PROXY \
            no_proxy \
            NO_PROXY
            echo '已关闭系统代理'
    end
end