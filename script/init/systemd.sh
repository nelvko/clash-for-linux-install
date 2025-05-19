[Unit]
Description=placeholder_kernel_desc

[Service]
Type=simple
Restart=always
ExecStart=placeholder_cmd_full

[Install]
WantedBy=multi-user.target
