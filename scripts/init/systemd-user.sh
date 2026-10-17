[Unit]
Description=placeholder_kernel_desc

[Service]
Type=simple
# TUN 需要用户显式授权 sudo，由独立 helper 运行；登录时不启动无权限副本。
ExecCondition=placeholder_yq_path -e '.tun.enable != true' placeholder_config_path
ExecStart=placeholder_cmd_full
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=1s

[Install]
WantedBy=default.target
