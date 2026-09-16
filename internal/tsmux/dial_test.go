package tsmux

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"testing"
)

// dialRecorder answers a scripted set of addresses and remembers the order it
// was asked, which is the whole point of the IPv4 fallback.
type dialRecorder struct {
	ok    map[string]bool
	asked []string
}

func (d *dialRecorder) dial(_ context.Context, addr string) (net.Conn, error) {
	d.asked = append(d.asked, addr)
	if d.ok[addr] {
		// A conn we never read from; the caller only checks that it got one.
		c, _ := net.Pipe()
		return c, nil
	}
	return nil, errTailnetDial
}

var errTailnetDial = errors.New("tailnet dial failed")

func addrs(ss ...string) []netip.Addr {
	out := make([]netip.Addr, len(ss))
	for i, s := range ss {
		out[i] = netip.MustParseAddr(s)
	}
	return out
}

func lookup(a []netip.Addr, err error) func(context.Context, string) ([]netip.Addr, error) {
	return func(context.Context, string) ([]netip.Addr, error) { return a, err }
}

func TestDialV4Fallback(t *testing.T) {
	errDNS := errors.New("no resolver")
	for _, tc := range []struct {
		name     string
		hostport string
		ok       []string
		a        []netip.Addr
		aErr     error
		wantConn bool
		wantAsk  []string
	}{
		{
			name: "tsnet dial wins outright, DNS is never consulted",
			// A lookup here would be a second name resolution for a name the
			// tailnet already resolved its own way.
			hostport: "nas.home.ts.net:80", ok: []string{"nas.home.ts.net:80"},
			a: addrs("100.64.0.9"), wantConn: true,
			wantAsk: []string{"nas.home.ts.net:80"},
		},
		{
			name:     "peer advertises a dead v6 first, v4 answers",
			hostport: "nas.home.ts.net:80", ok: []string{"100.64.0.9:80"},
			a: addrs("100.64.0.9"), wantConn: true,
			wantAsk: []string{"nas.home.ts.net:80", "100.64.0.9:80"},
		},
		{
			name:     "A records are tried in order until one connects",
			hostport: "nas.home.ts.net:80", ok: []string{"100.64.0.9:80"},
			a: addrs("100.64.0.7", "100.64.0.8", "100.64.0.9"), wantConn: true,
			wantAsk: []string{"nas.home.ts.net:80", "100.64.0.7:80", "100.64.0.8:80", "100.64.0.9:80"},
		},
		{
			name:     "an IP literal has nothing left to resolve",
			hostport: "100.64.0.9:80",
			a:        addrs("100.64.0.1"),
			wantAsk:  []string{"100.64.0.9:80"},
		},
		{
			name:     "no port to reattach, so no retry",
			hostport: "nas.home.ts.net",
			a:        addrs("100.64.0.9"),
			wantAsk:  []string{"nas.home.ts.net"},
		},
		{
			name:     "resolver failure leaves the dial error standing",
			hostport: "nas.home.ts.net:80", aErr: errDNS,
			wantAsk: []string{"nas.home.ts.net:80"},
		},
		{
			name:     "no A records",
			hostport: "nas.home.ts.net:80",
			wantAsk:  []string{"nas.home.ts.net:80"},
		},
		{
			name:     "every address refused",
			hostport: "nas.home.ts.net:80",
			a:        addrs("100.64.0.7", "100.64.0.8"),
			wantAsk:  []string{"nas.home.ts.net:80", "100.64.0.7:80", "100.64.0.8:80"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d := &dialRecorder{ok: map[string]bool{}}
			for _, a := range tc.ok {
				d.ok[a] = true
			}
			conn, err := dialV4Fallback(context.Background(), tc.hostport, d.dial, lookup(tc.a, tc.aErr))
			switch {
			case tc.wantConn && err != nil:
				t.Fatalf("got error %v, want a conn", err)
			case !tc.wantConn && err == nil:
				conn.Close()
				t.Fatal("got a conn, want an error")
			}
			if conn != nil {
				conn.Close()
			}
			// The tailnet's own error is what the user needs to see, not a
			// complaint from the fallback path.
			if !tc.wantConn && !errors.Is(err, errTailnetDial) {
				t.Errorf("error = %v, want the original tsnet dial error", err)
			}
			if len(d.asked) != len(tc.wantAsk) {
				t.Fatalf("dialed %v, want %v", d.asked, tc.wantAsk)
			}
			for i := range d.asked {
				if d.asked[i] != tc.wantAsk[i] {
					t.Fatalf("dialed %v, want %v", d.asked, tc.wantAsk)
				}
			}
		})
	}
}

// A cancelled context stops the fallback rather than working through every
// remaining address.
func TestDialV4FallbackStopsOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	d := &dialRecorder{ok: map[string]bool{}}
	cancel()
	if _, err := dialV4Fallback(ctx, "nas.home.ts.net:80", d.dial,
		lookup(addrs("100.64.0.7", "100.64.0.8", "100.64.0.9"), nil)); err == nil {
		t.Fatal("expected failure")
	}
	if len(d.asked) != 2 { // the name, then one address before the cancel is seen
		t.Errorf("dialed %v, want to stop after the first address", d.asked)
	}
}
