### BEGIN INIT INFO

# Provides: placeholder_kernel_name
# Required-Start: $network $local_fs $remote_fs
# Required-Stop: $network $local_fs $remote_fs
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: placeholder_kernel_desc
# Description: placeholder_kernel_desc
### END INIT INFO

start() {
  placeholder_cmd_full >>placeholder_log_file 2>&1 &
  echo $! >placeholder_pid_file
}

stop() {
  kill -9 "$(cat placeholder_pid_file)" && rm -f placeholder_pid_file
}

status() {
  less placeholder_log_file
}

case "$1" in
start)
  start
  ;;
stop)
  stop
  ;;
status)
  status
  ;;
restart | reload)
  stop
  sleep 0.3
  start
  ;;
*)
  echo "Usage: $0 {start|stop|restart}"
  ;;
esac
