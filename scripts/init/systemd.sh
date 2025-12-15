[Unit]
Description=placeholder_kernel_desc

[Service]
Type=simple
Restart=always
ExecStartPre=/usr/bin/sleep 1s
ExecStart=placeholder_cmd_full
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=multi-user.target
