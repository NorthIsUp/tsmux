package tsmux

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"

	"golang.org/x/net/proxy"
)

// fakeTailnet stands in for a tsnet node: it records the hostname it was
// asked for (proving the proxy never resolves names locally) and connects to
// a local backend instead.
type fakeTailnet struct {
	backend string
	mu      sync.Mutex
	asked   []string
}

func (f *fakeTailnet) Dial(ctx context.Context, network, hostport string) (net.Conn, error) {
	f.mu.Lock()
	f.asked = append(f.asked, hostport)
	f.mu.Unlock()
	if strings.HasPrefix(hostport, "blocked.") {
		return nil, fmt.Errorf("no route")
	}
	var d net.Dialer
	return d.DialContext(ctx, network, f.backend)
}

func (f *fakeTailnet) lastAsked() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.asked) == 0 {
		return ""
	}
	return f.asked[len(f.asked)-1]
}

func setup(t *testing.T) (*fakeTailnet, string, string) {
	t.Helper()
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "hello %s", r.Host)
	}))
	t.Cleanup(backend.Close)
	f := &fakeTailnet{backend: backend.Listener.Addr().String()}

	hl, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hl.Close() })
	hs := &http.Server{Handler: &HTTPProxy{Dial: f.Dial}}
	go hs.Serve(hl)

	sl, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sl.Close() })
	go ServeSOCKS5(sl, f.Dial)

	return f, hl.Addr().String(), sl.Addr().String()
}

func TestHTTPProxyForwards(t *testing.T) {
	f, httpAddr, _ := setup(t)
	pu, _ := url.Parse("http://" + httpAddr)
	c := &http.Client{Transport: &http.Transport{Proxy: http.ProxyURL(pu)}}

	resp, err := c.Get("http://nas.home.ts.net/")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if string(b) != "hello nas.home.ts.net" {
		t.Errorf("body = %q", b)
	}
	if got := f.lastAsked(); got != "nas.home.ts.net:80" {
		t.Errorf("dialed %q, want the unresolved name nas.home.ts.net:80", got)
	}
}

func TestHTTPProxyConnect(t *testing.T) {
	f, httpAddr, _ := setup(t)
	c, err := net.Dial("tcp", httpAddr)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	fmt.Fprint(c, "CONNECT db.work.ts.net:443 HTTP/1.1\r\nHost: db.work.ts.net:443\r\n\r\n")
	br := bufio.NewReader(c)
	line, err := br.ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(line, "200") {
		t.Fatalf("CONNECT reply = %q", line)
	}
	for { // drain headers
		l, err := br.ReadString('\n')
		if err != nil || l == "\r\n" {
			break
		}
	}
	if got := f.lastAsked(); got != "db.work.ts.net:443" {
		t.Errorf("dialed %q, want db.work.ts.net:443", got)
	}
	// The tunnel must be transparent: speak HTTP over it and get the backend.
	fmt.Fprint(c, "GET / HTTP/1.1\r\nHost: db.work.ts.net\r\nConnection: close\r\n\r\n")
	body, _ := io.ReadAll(br)
	if !strings.Contains(string(body), "hello db.work.ts.net") {
		t.Errorf("tunnelled body = %q", body)
	}
}

func TestHTTPProxyReportsDialFailure(t *testing.T) {
	_, httpAddr, _ := setup(t)
	pu, _ := url.Parse("http://" + httpAddr)
	c := &http.Client{Transport: &http.Transport{Proxy: http.ProxyURL(pu)}}
	resp, err := c.Get("http://blocked.home.ts.net/")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadGateway {
		t.Errorf("status = %d, want 502", resp.StatusCode)
	}
}

func TestSOCKS5PassesHostnameThrough(t *testing.T) {
	f, _, socksAddr := setup(t)
	d, err := proxy.SOCKS5("tcp", socksAddr, nil, proxy.Direct)
	if err != nil {
		t.Fatal(err)
	}
	c := &http.Client{Transport: &http.Transport{
		DialContext: d.(proxy.ContextDialer).DialContext,
	}}
	resp, err := c.Get("http://nas.home.ts.net/")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if string(b) != "hello nas.home.ts.net" {
		t.Errorf("body = %q", b)
	}
	// x/net/proxy sends ATYP=3 for names; the server must not have resolved it.
	if got := f.lastAsked(); got != "nas.home.ts.net:80" {
		t.Errorf("dialed %q, want the unresolved name nas.home.ts.net:80", got)
	}
}

func TestSOCKS5RefusesUnreachable(t *testing.T) {
	_, _, socksAddr := setup(t)
	d, _ := proxy.SOCKS5("tcp", socksAddr, nil, proxy.Direct)
	if _, err := d.Dial("tcp", "blocked.home.ts.net:80"); err == nil {
		t.Fatal("expected SOCKS5 failure reply for an unreachable host")
	}
}

func TestTunnelForwards(t *testing.T) {
	f, _, _ := setup(t)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go ServeTunnel(ln, "db.work.ts.net:5432", f.Dial)

	c, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	fmt.Fprint(c, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
	body, _ := io.ReadAll(c)
	if !strings.Contains(string(body), "hello x") {
		t.Errorf("tunnel body = %q", body)
	}
	if got := f.lastAsked(); got != "db.work.ts.net:5432" {
		t.Errorf("tunnel dialed %q", got)
	}
}
