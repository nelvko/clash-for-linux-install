### BEGIN INIT INFO
# Provides: placeholder_kernel_name
# Required-Start: $network $local_fs $remote_fs
# Required-Stop: $network $local_fs $remote_fs
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: placeholder_kernel_desc
# Description: placeholder_kernel_desc
### END INIT INFO

pidfile="placeholder_pid_file"
logfile="placeholder_log_file"
cmd="placeholder_cmd_full"

case "$1" in
start)
  $0 status >&/dev/null && exit 0
  $cmd >&$logfile &
  echo $! >$pidfile
  ;;
stop)
  pid=$(cat $pidfile 2>/dev/null)
  [ -n "$pid" ] && kill -9 "$pid"
  rm -f $pidfile
  ;;
restart | reload)
  $0 stop
  sleep 0.5
  $0 start
  ;;
status)
  pid=$(cat $pidfile 2>/dev/null)
  isStart=$(ps ax | awk '{ print $1 }' | grep -e "^${pid}$")
  [ -n "$isStart" ] && {
    echo "placeholder_kernel_name is running with PID: $pid"
    exit 0
  }
  echo "placeholder_kernel_name is not running."
  exit 1
  ;;
*)
  echo "Usage: $0 {start|stop|restart|status}"
  ;;
esac
