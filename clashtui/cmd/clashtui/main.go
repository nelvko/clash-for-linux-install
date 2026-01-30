package main

import (
	"flag"
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/nelvko/clash-for-linux-install/clashtui/internal/clash"
	"github.com/nelvko/clash-for-linux-install/clashtui/internal/config"
	"github.com/nelvko/clash-for-linux-install/clashtui/internal/ui"
)

func main() {
	controllerAddr := flag.String("controller", "", "Clash external controller address (host:port or URL)")
	secret := flag.String("secret", "", "Controller secret (Bearer token)")
	baseDir := flag.String("base-dir", "", "Install base dir (defaults to $CLASH_BASE_DIR or ~/clashctl)")
	runtimePath := flag.String("runtime", "", "Path to runtime.yaml (defaults to <base-dir>/resources/runtime.yaml)")
	flag.Parse()

	cfg, err := config.Load(config.LoadOpts{
		BaseDir:        *baseDir,
		RuntimeYAML:    *runtimePath,
		ControllerAddr: *controllerAddr,
		Secret:         *secret,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}

	client := clash.NewClient(cfg.ControllerURL(), cfg.Secret)
	if err := client.Ping(); err != nil {
		fmt.Fprintf(os.Stderr, "clash controller unreachable (%s): %v\n", cfg.ControllerURL(), err)
		fmt.Fprintln(os.Stderr, "Please start the kernel first (e.g. run: clashon)")
		os.Exit(1)
	}

	m := ui.New(ui.Opts{Client: client, Controller: cfg.ControllerURL()})
	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}
}
