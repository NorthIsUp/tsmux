package tsmux

import (
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"sort"
	"sync"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

// Node is one userspace Tailscale node. Each profile gets its own tsnet
// server with its own state dir, so N tailnets coexist in one process with
// no TUN device and no root.
type Node struct {
	Profile *Profile
	srv     *tsnet.Server

	// The control server hands out the interactive login URL once and
	// clears it from later status reads, so hold onto it until we are up.
	authMu  sync.Mutex
	authURL string
}

func (n *Node) setAuthURL(u string) {
	n.authMu.Lock()
	n.authURL = u
	n.authMu.Unlock()
}

func (n *Node) AuthURL() string {
	n.authMu.Lock()
	defer n.authMu.Unlock()
	return n.authURL
}

type Manager struct {
	cfg     *Config
	verbose bool

	mu    sync.RWMutex
	nodes map[string]*Node
}

func NewManager(cfg *Config, verbose bool) *Manager {
	return &Manager{cfg: cfg, verbose: verbose, nodes: map[string]*Node{}}
}

func (m *Manager) Config() *Config { return m.cfg }

// Start brings up every profile. Nodes start concurrently; a profile that
// still needs interactive login does not block the others.
func (m *Manager) Start(ctx context.Context) error {
	profiles := m.cfg.Ordered()
	if len(profiles) == 0 {
		return fmt.Errorf("no profiles configured; run `tsmux profile add <name> --suffix .your-tailnet.ts.net`")
	}
	var wg sync.WaitGroup
	errs := make([]error, len(profiles))
	for i, p := range profiles {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs[i] = m.startOne(ctx, p)
		}()
	}
	wg.Wait()
	for _, err := range errs {
		if err != nil {
			return err
		}
	}
	return nil
}

func (m *Manager) startOne(ctx context.Context, p *Profile) error {
	dir := m.cfg.StateDir(p.Name)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	srv := &tsnet.Server{
		Dir:        dir,
		Hostname:   p.Hostname,
		AuthKey:    p.AuthKey(),
		ControlURL: p.ControlURL,
		Logf:       func(string, ...any) {},
		UserLogf:   func(f string, a ...any) { log.Printf("["+p.Name+"] "+f, a...) },
	}
	if m.verbose {
		srv.Logf = srv.UserLogf
	}
	if err := srv.Start(); err != nil {
		return fmt.Errorf("profile %s: %w", p.Name, err)
	}
	m.mu.Lock()
	m.nodes[p.Name] = &Node{Profile: p, srv: srv}
	m.mu.Unlock()

	if p.AcceptRoutes {
		if lc, err := srv.LocalClient(); err == nil {
			_, _ = lc.EditPrefs(ctx, &ipn.MaskedPrefs{
				Prefs:       ipn.Prefs{RouteAll: true},
				RouteAllSet: true,
			})
		}
	}
	go m.watchLogin(ctx, p.Name, srv)
	return nil
}

// watchLogin surfaces the interactive auth URL instead of burying it in logs.
func (m *Manager) watchLogin(ctx context.Context, name string, srv *tsnet.Server) {
	lc, err := srv.LocalClient()
	if err != nil {
		return
	}
	n, err := m.Node(name)
	if err != nil {
		return
	}
	announced := ""
	for ctx.Err() == nil {
		st, err := lc.StatusWithoutPeers(ctx)
		if err == nil {
			if st.BackendState == "Running" {
				n.setAuthURL("")
				if announced != "" {
					log.Printf("[%s] authenticated", name)
				}
				return
			}
			if st.AuthURL != "" && st.AuthURL != announced {
				announced = st.AuthURL
				n.setAuthURL(st.AuthURL)
				log.Printf("[%s] needs login: %s", name, st.AuthURL)
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Second):
		}
	}
}

func (m *Manager) Node(name string) (*Node, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	n, ok := m.nodes[name]
	if !ok {
		return nil, fmt.Errorf("profile %q is not running", name)
	}
	return n, nil
}

// Pick resolves a host to the node that owns it.
func (m *Manager) Pick(hostport string) (*Node, *Match, error) {
	match, err := m.cfg.Route(hostport)
	if err != nil {
		return nil, nil, err
	}
	n, err := m.Node(match.Profile.Name)
	return n, match, err
}

// Dial opens a connection to hostport inside the owning tailnet. Name
// resolution happens in that tailnet's MagicDNS, never on the host OS.
func (m *Manager) Dial(ctx context.Context, network, hostport string) (net.Conn, error) {
	n, _, err := m.Pick(hostport)
	if err != nil {
		return nil, err
	}
	return n.srv.Dial(ctx, network, hostport)
}

func (n *Node) Dial(ctx context.Context, network, hostport string) (net.Conn, error) {
	return n.srv.Dial(ctx, network, hostport)
}

// Resolve looks up a name using only this profile's tailnet DNS.
func (n *Node) Resolve(ctx context.Context, host string) ([]net.IPAddr, error) {
	r := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return n.srv.Dial(ctx, network, addr)
		},
	}
	return r.LookupIPAddr(ctx, host)
}

type Status struct {
	Profile   string   `json:"profile"`
	Display   string   `json:"display_name"`
	State     string   `json:"state"`
	Self      string   `json:"self,omitempty"`
	IPs       []string `json:"ips,omitempty"`
	Peers     int      `json:"peers"`
	AuthURL   string   `json:"auth_url,omitempty"`
	Suffixes  []string `json:"suffixes,omitempty"`
	HTTPProxy string   `json:"http_proxy"`
	SOCKS5    string   `json:"socks5_proxy"`
	Err       string   `json:"error,omitempty"`
}

func (m *Manager) Status(ctx context.Context) []Status {
	m.mu.RLock()
	nodes := make([]*Node, 0, len(m.nodes))
	for _, n := range m.nodes {
		nodes = append(nodes, n)
	}
	m.mu.RUnlock()
	sort.Slice(nodes, func(i, j int) bool { return nodes[i].Profile.Name < nodes[j].Profile.Name })

	out := make([]Status, 0, len(nodes))
	for _, n := range nodes {
		p := n.Profile
		s := Status{
			Profile: p.Name, Display: p.DisplayName, State: "Stopped",
			Suffixes:  p.Suffixes,
			HTTPProxy: fmt.Sprintf("127.0.0.1:%d", p.HTTPPort),
			SOCKS5:    fmt.Sprintf("127.0.0.1:%d", p.SOCKSPort),
		}
		if lc, err := n.srv.LocalClient(); err == nil {
			if st, err := lc.Status(ctx); err == nil {
				s.State, s.AuthURL, s.Peers = st.BackendState, st.AuthURL, len(st.Peer)
				if s.AuthURL == "" {
					s.AuthURL = n.AuthURL()
				}
				if st.Self != nil {
					s.Self = st.Self.DNSName
					for _, ip := range st.Self.TailscaleIPs {
						s.IPs = append(s.IPs, ip.String())
					}
				}
			} else {
				s.Err = err.Error()
			}
		}
		out = append(out, s)
	}
	return out
}

func (m *Manager) Close() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	var err error
	for _, n := range m.nodes {
		if e := n.srv.Close(); e != nil {
			err = e
		}
	}
	m.nodes = map[string]*Node{}
	return err
}

// pipe joins two conns and returns when either direction closes.
func pipe(a, b net.Conn) {
	done := make(chan struct{}, 2)
	go func() { io.Copy(a, b); done <- struct{}{} }()
	go func() { io.Copy(b, a); done <- struct{}{} }()
	<-done
	a.Close()
	b.Close()
}
