package tsmux

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"strconv"
	"time"
)

// DialFunc opens a TCP connection to hostport inside some tailnet.
type DialFunc func(ctx context.Context, network, hostport string) (net.Conn, error)

// HTTPProxy is a loopback HTTP proxy. CONNECT is tunnelled verbatim so TLS
// stays end-to-end; plain HTTP is forwarded.
type HTTPProxy struct {
	Dial  DialFunc
	Label string
}

func (p *HTTPProxy) transport() *http.Transport {
	return &http.Transport{DialContext: p.Dial, DisableKeepAlives: true}
}

func (p *HTTPProxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodConnect {
		p.connect(w, r)
		return
	}
	if !r.URL.IsAbs() {
		http.Error(w, "tsmux: not a proxy request", http.StatusBadRequest)
		return
	}
	outreq := r.Clone(r.Context())
	outreq.RequestURI = ""
	resp, err := p.transport().RoundTrip(outreq)
	if err != nil {
		http.Error(w, "tsmux: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	for k, vs := range resp.Header {
		for _, v := range vs {
			w.Header().Add(k, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

func (p *HTTPProxy) connect(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	up, err := p.Dial(ctx, "tcp", r.Host)
	if err != nil {
		http.Error(w, "tsmux: "+err.Error(), http.StatusBadGateway)
		return
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		up.Close()
		http.Error(w, "tsmux: hijack unsupported", http.StatusInternalServerError)
		return
	}
	down, buf, err := hj.Hijack()
	if err != nil {
		up.Close()
		return
	}
	if _, err := down.Write([]byte("HTTP/1.1 200 Connection established\r\n\r\n")); err != nil {
		up.Close()
		down.Close()
		return
	}
	// Anything the client pipelined after CONNECT is already buffered.
	if n := buf.Reader.Buffered(); n > 0 {
		if b, err := buf.Reader.Peek(n); err == nil {
			up.Write(b)
		}
	}
	pipe(down, up)
}

// ServeSOCKS5 runs a minimal SOCKS5 CONNECT server (no auth, loopback only).
// Hostnames are passed through unresolved so routing sees the real name.
func ServeSOCKS5(ln net.Listener, dial DialFunc) error {
	for {
		c, err := ln.Accept()
		if err != nil {
			return err
		}
		go func() {
			if err := socksHandle(c, dial); err != nil && err != io.EOF {
				log.Printf("socks5: %v", err)
			}
		}()
	}
}

const (
	socksVer   = 0x05
	cmdConnect = 0x01
	atypIPv4   = 0x01
	atypHost   = 0x03
	atypIPv6   = 0x04
)

func socksHandle(c net.Conn, dial DialFunc) error {
	defer c.Close()
	c.SetDeadline(time.Now().Add(30 * time.Second))

	hdr := make([]byte, 2)
	if _, err := io.ReadFull(c, hdr); err != nil {
		return err
	}
	if hdr[0] != socksVer {
		return fmt.Errorf("unsupported socks version %d", hdr[0])
	}
	methods := make([]byte, hdr[1])
	if _, err := io.ReadFull(c, methods); err != nil {
		return err
	}
	if _, err := c.Write([]byte{socksVer, 0x00}); err != nil { // no auth
		return err
	}

	req := make([]byte, 4)
	if _, err := io.ReadFull(c, req); err != nil {
		return err
	}
	if req[1] != cmdConnect {
		socksReply(c, 0x07, netip.AddrPort{}) // command not supported
		return fmt.Errorf("unsupported socks command %d", req[1])
	}

	var host string
	switch req[3] {
	case atypIPv4, atypIPv6:
		n := 4
		if req[3] == atypIPv6 {
			n = 16
		}
		b := make([]byte, n)
		if _, err := io.ReadFull(c, b); err != nil {
			return err
		}
		a, _ := netip.AddrFromSlice(b)
		host = a.String()
	case atypHost:
		l := make([]byte, 1)
		if _, err := io.ReadFull(c, l); err != nil {
			return err
		}
		b := make([]byte, l[0])
		if _, err := io.ReadFull(c, b); err != nil {
			return err
		}
		host = string(b)
	default:
		socksReply(c, 0x08, netip.AddrPort{}) // address type not supported
		return fmt.Errorf("unsupported socks atyp %d", req[3])
	}
	pb := make([]byte, 2)
	if _, err := io.ReadFull(c, pb); err != nil {
		return err
	}
	target := net.JoinHostPort(host, strconv.Itoa(int(binary.BigEndian.Uint16(pb))))

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	up, err := dial(ctx, "tcp", target)
	if err != nil {
		socksReply(c, 0x05, netip.AddrPort{}) // connection refused
		return fmt.Errorf("%s: %w", target, err)
	}
	defer up.Close()
	if err := socksReply(c, 0x00, netip.AddrPort{}); err != nil {
		return err
	}
	c.SetDeadline(time.Time{})
	pipe(c, up)
	return nil
}

func socksReply(c net.Conn, code byte, bind netip.AddrPort) error {
	_, err := c.Write([]byte{socksVer, code, 0x00, atypIPv4, 0, 0, 0, 0, 0, 0})
	return err
}

// ServeTunnel forwards every connection on ln to target through dial.
func ServeTunnel(ln net.Listener, target string, dial DialFunc) error {
	for {
		c, err := ln.Accept()
		if err != nil {
			return err
		}
		go func() {
			defer c.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			up, err := dial(ctx, "tcp", target)
			if err != nil {
				log.Printf("tunnel %s: %v", target, err)
				return
			}
			pipe(c, up)
		}()
	}
}

// PipeStdio joins a connection to this process's stdin/stdout, for use as an
// ssh ProxyCommand.
func PipeStdio(conn net.Conn) error {
	done := make(chan error, 2)
	go func() { _, err := io.Copy(conn, os.Stdin); done <- err }()
	go func() { _, err := io.Copy(os.Stdout, conn); done <- err }()
	return <-done
}
