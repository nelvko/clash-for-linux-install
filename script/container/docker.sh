




# _start_convert() {
#     _is_already_in_use $BIN_SUBCONVERTER_PORT 'subconverter' && {
#         local newPort=$(_get_random_port)
#         _failcat '🎯' "端口占用：$BIN_SUBCONVERTER_PORT 🎲 随机分配：$newPort"
#         [ ! -e "$BIN_SUBCONVERTER_CONFIG" ] && {
#             sudo /bin/cp -f "$BIN_SUBCONVERTER_DIR/pref.example.yml" "$BIN_SUBCONVERTER_CONFIG"
#         }
#         sudo "$BIN_YQ" -i ".server.port = $newPort" "$BIN_SUBCONVERTER_CONFIG"
#         BIN_SUBCONVERTER_PORT=$newPort
#     }
#     local start=$(date +%s)
#     # 子shell运行，屏蔽kill时的输出
#     (sudo "$BIN_SUBCONVERTER" 2>&1 | sudo tee "$BIN_SUBCONVERTER_LOG" >/dev/null &)
#     while ! _is_bind "$BIN_SUBCONVERTER_PORT" >&/dev/null; do
#         sleep 1s
#         local now=$(date +%s)
#         [ $((now - start)) -gt 1 ] && _error_quit "订阅转换服务未启动，请检查日志：$BIN_SUBCONVERTER_LOG"
#     done
# }
# _stop_convert() {
#     docker stop  "$BIN_SUBCONVERTER" >&/dev/null
# }

# CONTAINER_ID_SUBCONVERTER=$(docker run -d --restart=always -p "${BIN_SUBCONVERTER_PORT}":25500 tindy2013/subconverter:latest)
# yq() {
#   docker run --rm -i -v "${PWD}":/workdir "${URL_CR_PROXY}"mikefarah/yq "$@"
# }
# _stop_convert() {
#     docker stop subconverter
# }
