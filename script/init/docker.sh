# shellcheck disable=SC2148
# shellcheck disable=SC2034
# shellcheck disable=SC2016

start='docker start $CONTAINER_ID_KERNEL'
is_active='docker inspect -f {{.State.Running}} $CONTAINER_ID_KERNEL'
stop="docker stop $KERNEL_NAME"
status='docker stats $CONTAINER_ID_KERNEL'
CONTAINER_ID_SUBCONVERTER=$(docker run -d --restart=always -p "${BIN_SUBCONVERTER_PORT}":25500 tindy2013/subconverter:latest)
yq() {
  docker run --rm -i -v "${PWD}":/workdir mikefarah/yq "$@"
}
_stop_convert() {
    docker stop "$CONTAINER_ID_SUBCONVERTER"
}
