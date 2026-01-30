package config

import "testing"

func TestControllerURL_NormalizesBindAllHostPort(t *testing.T) {
	cfg := Config{ControllerAddr: "0.0.0.0:9090"}
	got := cfg.ControllerURL()
	want := "http://127.0.0.1:9090"
	if got != want {
		t.Fatalf("ControllerURL() = %q, want %q", got, want)
	}
}

func TestControllerURL_NormalizesBindAllURL(t *testing.T) {
	cfg := Config{ControllerAddr: "http://0.0.0.0:9090"}
	got := cfg.ControllerURL()
	want := "http://127.0.0.1:9090"
	if got != want {
		t.Fatalf("ControllerURL() = %q, want %q", got, want)
	}
}
