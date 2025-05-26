set fn_arr \
clash \
clashctl \
mihomo \
mihomoctl \
\
clashon \
clashoff \
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