package config

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

type LoadOpts struct {
	BaseDir        string
	RuntimeYAML    string
	ControllerAddr string
	Secret         string
}

type Config struct {
	ControllerAddr string
	Secret         string
}

type runtimeYAML struct {
	ExternalController string `yaml:"external-controller"`
	Secret             string `yaml:"secret"`
}

func Load(opts LoadOpts) (Config, error) {
	baseDir := strings.TrimSpace(opts.BaseDir)
	if baseDir == "" {
		baseDir = strings.TrimSpace(os.Getenv("CLASH_BASE_DIR"))
	}
	if baseDir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return Config{}, fmt.Errorf("cannot resolve home dir: %w", err)
		}
		baseDir = filepath.Join(home, "clashctl")
	}

	runtimePath := strings.TrimSpace(opts.RuntimeYAML)
	if runtimePath == "" {
		runtimePath = filepath.Join(baseDir, "resources", "runtime.yaml")
	}

	ry, _ := os.ReadFile(runtimePath)
	var rt runtimeYAML
	if len(ry) > 0 {
		_ = yaml.Unmarshal(ry, &rt)
	}

	cfg := Config{
		ControllerAddr: firstNonEmpty(strings.TrimSpace(opts.ControllerAddr), strings.TrimSpace(rt.ExternalController)),
		Secret:         firstNonEmpty(strings.TrimSpace(opts.Secret), strings.TrimSpace(rt.Secret)),
	}

	if cfg.ControllerAddr == "" {
		return Config{}, errors.New("missing controller address: set -controller or ensure runtime.yaml has external-controller")
	}
	// Secret can be empty (controller may be unauthenticated), but most setups require it.

	return cfg, nil
}

func (c Config) ControllerURL() string {
	addr := strings.TrimSpace(c.ControllerAddr)
	addr = normalizeControllerAddr(addr)
	if strings.HasPrefix(addr, "http://") || strings.HasPrefix(addr, "https://") {
		return addr
	}

	// Accept host:port.
	u := url.URL{Scheme: "http", Host: addr}
	return u.String()
}

func normalizeControllerAddr(addr string) string {
	addr = strings.TrimSpace(addr)
	if addr == "" {
		return addr
	}

	// If user provided a URL, normalize its host too.
	if strings.HasPrefix(addr, "http://") || strings.HasPrefix(addr, "https://") {
		u, err := url.Parse(addr)
		if err != nil {
			return addr
		}
		host := u.Host
		if host == "" {
			return addr
		}
		newHost := normalizeHostPort(host)
		if newHost != host {
			u.Host = newHost
			return u.String()
		}
		return addr
	}

	return normalizeHostPort(addr)
}

func normalizeHostPort(hostport string) string {
	hostport = strings.TrimSpace(hostport)
	if hostport == "" {
		return hostport
	}
	// Handle raw host:port.
	host, port, err := net.SplitHostPort(hostport)
	if err != nil {
		// Not a host:port; treat as host only.
		if hostport == "0.0.0.0" || hostport == "*" {
			return "127.0.0.1"
		}
		return hostport
	}
	// external-controller: 0.0.0.0:9090 means bind-all; clients should connect via loopback.
	if host == "0.0.0.0" || host == "*" || host == "" {
		host = "127.0.0.1"
	}
	return net.JoinHostPort(host, port)
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}
