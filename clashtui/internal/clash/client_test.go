package clash

import (
	"net/http"
	"testing"
)

func TestNewClient_DisablesProxy(t *testing.T) {
	c := NewClient("http://127.0.0.1:9090", "")
	tr, ok := c.http.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("transport type = %T, want *http.Transport", c.http.Transport)
	}
	if tr.Proxy != nil {
		t.Fatalf("transport.Proxy is not nil; expected proxy disabled")
	}
}
