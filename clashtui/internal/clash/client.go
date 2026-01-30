package clash

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"time"
)

type Client struct {
	baseURL string
	secret  string
	http    *http.Client
}

func NewClient(baseURL, secret string) *Client {
	// Controller is typically a local service; do not route requests through http_proxy.
	defaultTr, _ := http.DefaultTransport.(*http.Transport)
	tr := defaultTr.Clone()
	tr.Proxy = nil

	return &Client{
		baseURL: baseURL,
		secret:  secret,
		http: &http.Client{
			Transport: tr,
			Timeout:   5 * time.Second,
		},
	}
}

func (c *Client) Ping() error {
	// /version exists for both clash and mihomo controller.
	_, err := c.GetVersion()
	return err
}

type Config struct {
	Mode string `json:"mode"`
}

func (c *Client) GetConfig() (Config, error) {
	var out Config
	if err := c.getJSON("/configs", &out); err != nil {
		return Config{}, err
	}
	return out, nil
}

func (c *Client) SetMode(mode string) error {
	body, _ := json.Marshal(map[string]string{"mode": mode})
	return c.patchJSON("/configs", body)
}

type Version struct {
	Version string `json:"version"`
}

func (c *Client) GetVersion() (Version, error) {
	var out Version
	if err := c.getJSON("/version", &out); err != nil {
		return Version{}, err
	}
	return out, nil
}

type ProxiesResp struct {
	Proxies map[string]Proxy `json:"proxies"`
}

type Proxy struct {
	Name string   `json:"name"`
	Type string   `json:"type"`
	Now  string   `json:"now"`
	All  []string `json:"all"`
}

func (c *Client) GetProxies() (ProxiesResp, error) {
	var out ProxiesResp
	if err := c.getJSON("/proxies", &out); err != nil {
		return ProxiesResp{}, err
	}
	return out, nil
}

func (c *Client) SelectProxy(groupName, proxyName string) error {
	body, _ := json.Marshal(map[string]string{"name": proxyName})
	return c.putJSON("/proxies/"+url.PathEscape(groupName), body)
}

type DelayResp struct {
	Delay int `json:"delay"`
}

func (c *Client) GetProxyDelay(proxyName, testURL string, timeoutMS int) (DelayResp, error) {
	q := url.Values{}
	q.Set("url", testURL)
	q.Set("timeout", strconv.Itoa(timeoutMS))

	var out DelayResp
	if err := c.getJSON("/proxies/"+url.PathEscape(proxyName)+"/delay?"+q.Encode(), &out); err != nil {
		return DelayResp{}, err
	}
	return out, nil
}

func (c *Client) getJSON(p string, out any) error {
	req, err := http.NewRequest(http.MethodGet, c.resolve(p), nil)
	if err != nil {
		return err
	}
	c.addAuth(req)
	res, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()

	if res.StatusCode < 200 || res.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(res.Body, 4<<10))
		return fmt.Errorf("GET %s: %s: %s", p, res.Status, string(b))
	}
	return json.NewDecoder(res.Body).Decode(out)
}

func (c *Client) putJSON(p string, body []byte) error {
	req, err := http.NewRequest(http.MethodPut, c.resolve(p), bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	c.addAuth(req)
	res, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(res.Body, 4<<10))
		return fmt.Errorf("PUT %s: %s: %s", p, res.Status, string(b))
	}
	return nil
}

func (c *Client) patchJSON(p string, body []byte) error {
	req, err := http.NewRequest(http.MethodPatch, c.resolve(p), bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	c.addAuth(req)
	res, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(res.Body, 4<<10))
		return fmt.Errorf("PATCH %s: %s: %s", p, res.Status, string(b))
	}
	return nil
}

func (c *Client) resolve(p string) string {
	base, _ := url.Parse(c.baseURL)
	rel, _ := url.Parse(p)
	base.Path = path.Join(base.Path, rel.Path)
	base.RawQuery = rel.RawQuery
	return base.String()
}

func (c *Client) addAuth(req *http.Request) {
	if c.secret != "" {
		req.Header.Set("Authorization", "Bearer "+c.secret)
	}
}
