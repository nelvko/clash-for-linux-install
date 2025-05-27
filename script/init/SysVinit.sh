### BEGIN INIT INFO
# Provides: placeholder_kernel_name
# Required-Start: $network $local_fs $remote_fs
# Required-Stop: $network $local_fs $remote_fs
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: placeholder_kernel_desc
# Description: placeholder_kernel_desc
### END INIT INFO

case "$1" in
start)
  $0 is-active >&/dev/null && exit 0
  placeholder_cmd_full >placeholder_log_file 2>&1 && echo $! >placeholder_pid_file
  ;;
stop)
  pid=$(cat placeholder_pid_file 2>/dev/null)
  [ -n "$pid" ] && kill -9 "$pid"
  rm -f placeholder_pid_file
  ;;
status)
  echo -n "$(date +"%Y-%m-%d %H:%M:%S") " >>placeholder_log_file
  $0 is-active >>placeholder_log_file
  less placeholder_log_file
  ;;
restart | reload)
  $0 stop
  sleep 0.3
  $0 start
  ;;
is-active)
  pid=$(cat placeholder_pid_file 2>/dev/null)
  [ -n "$pid" ] && {
    echo "😼 placeholder_kernel_name is running with PID: $pid"
    exit 0
  }
  echo "😾 placeholder_kernel_name is not running."
  exit 1
  ;;
enable) ;;
disable) ;;
*)
  echo "Usage: $0 {start|stop|restart}"
  ;;
esac
