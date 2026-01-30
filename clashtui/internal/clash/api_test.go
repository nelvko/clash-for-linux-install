package clash

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestClient_GetConfigAndSetMode(t *testing.T) {
	mode := "Rule"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/configs":
			_ = json.NewEncoder(w).Encode(map[string]string{"mode": mode})
			return
		case r.Method == http.MethodPatch && r.URL.Path == "/configs":
			var body map[string]string
			_ = json.NewDecoder(r.Body).Decode(&body)
			if got := body["mode"]; got == "" {
				w.WriteHeader(http.StatusBadRequest)
				return
			} else {
				mode = got
			}
			w.WriteHeader(http.StatusNoContent)
			return
		default:
			w.WriteHeader(http.StatusNotFound)
			return
		}
	}))
	defer srv.Close()

	c := NewClient(srv.URL, "")
	cfg, err := c.GetConfig()
	if err != nil {
		t.Fatalf("GetConfig() error: %v", err)
	}
	if cfg.Mode != "Rule" {
		t.Fatalf("GetConfig().Mode = %q, want %q", cfg.Mode, "Rule")
	}

	if err := c.SetMode("Global"); err != nil {
		t.Fatalf("SetMode() error: %v", err)
	}
	cfg2, err := c.GetConfig()
	if err != nil {
		t.Fatalf("GetConfig() after SetMode error: %v", err)
	}
	if cfg2.Mode != "Global" {
		t.Fatalf("GetConfig().Mode after SetMode = %q, want %q", cfg2.Mode, "Global")
	}
}

func TestClient_GetProxyDelay(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if r.URL.Path != "/proxies/ProxyA/delay" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		q := r.URL.Query()
		if q.Get("url") == "" || q.Get("timeout") == "" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]int{"delay": 123})
	}))
	defer srv.Close()

	c := NewClient(srv.URL, "")
	resp, err := c.GetProxyDelay("ProxyA", "https://example.com", 5000)
	if err != nil {
		t.Fatalf("GetProxyDelay() error: %v", err)
	}
	if resp.Delay != 123 {
		t.Fatalf("GetProxyDelay().Delay = %d, want %d", resp.Delay, 123)
	}
}
