package tsmux

import (
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
)

// Node is one userspace Tailscale node. Each profile gets its own tsnet
// server with its own state dir, so N tailnets coexist in one process with
// no TUN device and no root.
type Node struct {
	Profile *Profile
	srv     *tsnet.Server
	lock    *os.File

	// The control server hands out the interactive login URL once and
	// clears it from later status reads, so hold onto it until we are up.
	authMu   sync.Mutex
	authURL  string
	suffix   string // learned MagicDNS suffix, no leading dot
	conflict string // profile already claiming that suffix, if any
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

func (n *Node) setSuffix(s, conflict string) {
	n.authMu.Lock()
	n.suffix, n.conflict = s, conflict
	n.authMu.Unlock()
}

func (n *Node) learned() (suffix, conflict string) {
	n.authMu.Lock()
	defer n.authMu.Unlock()
	return n.suffix, n.conflict
}

type Manager struct {
	// stop asks the daemon's own process to shut down; set by `tsmux up` so
	// the GUI can stop a daemon it did not spawn instead of refusing to act.
	stop    func()
	cfg     *Config
	verbose bool

	mu    sync.RWMutex
	nodes map[string]*Node
}

func NewManager(cfg *Config, verbose bool) *Manager {
	return &Manager{cfg: cfg, verbose: verbose, nodes: map[string]*Node{}}
}

func (m *Manager) Config() *Config { return m.cfg }

func (m *Manager) OnStop(f func()) { m.stop = f }

// RequestStop triggers a graceful shutdown of the daemon process.
func (m *Manager) RequestStop() bool {
	if m.stop == nil {
		return false
	}
	go m.stop()
	return true
}

// Start brings up every profile. Nodes start concurrently; a profile that
// still needs interactive login does not block the others.
func (m *Manager) Start(ctx context.Context) error {
	profiles := m.cfg.Ordered()
	if len(profiles) == 0 {
		return fmt.Errorf("no profiles configured; run `tsmux profile add <name>`")
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
	// accept_routes in YAML is a first-run seed only; after that the state dir
	// owns the pref, so a GUI toggle is not stomped on the next restart.
	_, seeded := os.Stat(dir)
	firstRun := seeded != nil
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	// Two tsnet servers on one state dir clobber each other's credentials: the
	// second writes prefs with an empty Persist over the first's node key, and
	// the profile silently reverts to needing a login. Hold the dir exclusively.
	lock, err := lockStateDir(dir)
	if err != nil {
		return fmt.Errorf("profile %s: %w", p.Name, err)
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
		lock.Close()
		return fmt.Errorf("profile %s: %w", p.Name, err)
	}
	m.mu.Lock()
	m.nodes[p.Name] = &Node{Profile: p, srv: srv, lock: lock}
	m.mu.Unlock()

	if p.AcceptRoutes && firstRun {
		if lc, err := srv.LocalClient(); err == nil {
			_, _ = lc.EditPrefs(ctx, &ipn.MaskedPrefs{
				Prefs:       ipn.Prefs{RouteAll: true},
				RouteAllSet: true,
			})
		}
	}
	go m.watch(ctx, p.Name, srv)
	return nil
}

// watch runs for the node's lifetime: it surfaces the interactive auth URL
// instead of burying it in logs, and learns the tailnet's DNS suffix once the
// node is up. It must not return at Running, or a logout from the GUI would
// never re-surface a login URL.
func (m *Manager) watch(ctx context.Context, name string, srv *tsnet.Server) {
	lc, err := srv.LocalClient()
	if err != nil {
		return
	}
	n, err := m.Node(name)
	if err != nil {
		return
	}
	announced, learned, emptyRuns := "", "", 0
	for ctx.Err() == nil {
		tick := time.Second
		if st, err := lc.StatusWithoutPeers(ctx); err == nil {
			switch st.BackendState {
			case "Running":
				if announced != "" {
					log.Printf("[%s] authenticated", name)
					announced = ""
				}
				n.setAuthURL("")
				emptyRuns = 0
				if want := magicSuffix(st); want != "" && want != learned {
					learned = want
					m.learnSuffix(n, want)
				}
				tick = 5 * time.Second
			case "NeedsLogin", "NoState":
				learned = ""
				switch {
				case st.AuthURL != "":
					emptyRuns = 0
					if st.AuthURL != announced {
						announced = st.AuthURL
						log.Printf("[%s] needs login: %s", name, st.AuthURL)
					}
					n.setAuthURL(st.AuthURL)
				default:
					// The control server hands the URL out once; ask again if
					// we have seen two empty polls in a row.
					if emptyRuns++; emptyRuns >= 2 && n.AuthURL() == "" {
						emptyRuns = 0
						_ = lc.StartLoginInteractive(ctx)
					}
				}
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(tick):
		}
	}
}

// magicSuffix reads the tailnet's MagicDNS suffix (no leading dot), falling
// back to stripping the first label off our own FQDN.
func magicSuffix(st *ipnstate.Status) string {
	suffix := st.MagicDNSSuffix
	if st.CurrentTailnet != nil && st.CurrentTailnet.MagicDNSSuffix != "" {
		suffix = st.CurrentTailnet.MagicDNSSuffix
	}
	if suffix == "" && st.Self != nil {
		_, suffix, _ = strings.Cut(strings.TrimSuffix(st.Self.DNSName, "."), ".")
	}
	return strings.ToLower(strings.Trim(suffix, "."))
}

func (m *Manager) learnSuffix(n *Node, suffix string) {
	conflict, err := m.persistSuffix(n.Profile.Name, "."+suffix)
	if err != nil {
		log.Printf("[%s] could not record suffix %s: %v", n.Profile.Name, suffix, err)
	}
	if conflict != "" {
		log.Printf("[%s] tailnet suffix %s is already routed to %s; reach this profile on 127.0.0.1:%d",
			n.Profile.Name, suffix, conflict, n.Profile.HTTPPort)
	}
	n.setSuffix(suffix, conflict)
}

// persistSuffix records a learned suffix in config.yaml. It re-reads from disk
// rather than marshalling the daemon's in-memory config, which may be stale:
// a `tsmux profile add` since startup would otherwise be silently deleted.
//
// ponytail: no flock; reload-then-atomic-rename. Add a lockfile if config
// edits ever get frequent enough to actually collide.
func (m *Manager) persistSuffix(profile, want string) (conflict string, err error) {
	disk, err := Load(m.cfg.Path())
	if err != nil {
		return "", err
	}
	p, ok := disk.Profiles[profile]
	if !ok {
		return "", nil // removed since the daemon started; do not resurrect it
	}
	for _, other := range disk.Ordered() {
		if other.Name != profile && slices.Contains(other.Suffixes, want) {
			return other.Name, nil
		}
	}
	if slices.Contains(p.Suffixes, want) {
		m.cfg.addSuffix(profile, want)
		return "", nil
	}
	p.Suffixes = append(p.Suffixes, want)
	if err := disk.Normalize(); err != nil {
		return "", err
	}
	if err := disk.Save(disk.Path()); err != nil {
		return "", err
	}
	// Route and PAC read the live config, so the session that learned the
	// suffix can use it without a restart.
	m.cfg.addSuffix(profile, want)
	return "", nil
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
	return n.Dial(ctx, network, hostport)
}

// Dial reaches hostport inside this node's tailnet, trying every address the
// tailnet resolves, IPv4 first. tsnet otherwise commits to one address, and a
// peer that advertises an unreachable IPv6 address fails outright even though
// its IPv4 address works.
func (n *Node) Dial(ctx context.Context, network, hostport string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(hostport)
	if err != nil {
		return n.srv.Dial(ctx, network, hostport)
	}
	if _, err := netip.ParseAddr(host); err == nil {
		return n.srv.Dial(ctx, network, hostport)
	}
	ips, err := n.Resolve(ctx, host)
	if err != nil || len(ips) == 0 {
		return n.srv.Dial(ctx, network, hostport)
	}
	sort.SliceStable(ips, func(i, j int) bool {
		return ips[i].IP.To4() != nil && ips[j].IP.To4() == nil
	})
	var errs []string
	for _, ip := range ips {
		c, err := n.srv.Dial(ctx, network, net.JoinHostPort(ip.IP.String(), port))
		if err == nil {
			return c, nil
		}
		errs = append(errs, fmt.Sprintf("%s: %v", ip.IP, err))
		if ctx.Err() != nil {
			break
		}
	}
	return nil, fmt.Errorf("%s: %s", host, strings.Join(errs, "; "))
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
	Profile string `json:"profile"`
	Display string `json:"display_name"`
	State   string `json:"state"`
	Self    string `json:"self,omitempty"`
	// DeviceName is the configured hostname this profile registers under; the
	// editable half of Self, which the control server owns the rest of.
	DeviceName string   `json:"device_name,omitempty"`
	IPs        []string `json:"ips,omitempty"`
	Peers      int      `json:"peers"`
	AuthURL    string   `json:"auth_url,omitempty"`
	Suffixes   []string `json:"suffixes,omitempty"`
	HTTPProxy  string   `json:"http_proxy"`
	SOCKS5     string   `json:"socks5_proxy"`
	Err        string   `json:"error,omitempty"`

	Tailnet        string           `json:"tailnet,omitempty"`
	MagicDNSSuffix string           `json:"magic_dns_suffix,omitempty"`
	SuffixConflict string           `json:"suffix_conflict,omitempty"`
	User           *StatusUser      `json:"user,omitempty"`
	KeyExpiry      *time.Time       `json:"key_expiry,omitempty"`
	Health         []string         `json:"health,omitempty"`
	AdminURL       string           `json:"admin_url,omitempty"`
	Prefs          *StatusPrefs     `json:"prefs,omitempty"`
	ExitNodes      []ExitNodeOption `json:"exit_node_options,omitempty"`
	Devices        []Device         `json:"devices,omitempty"`
}

// Device is one peer in the tailnet, for the GUI's device list. Owner and
// Tags are what the UI groups by: a tagged node has no meaningful owner.
type Device struct {
	Name     string   `json:"name"`
	Hostname string   `json:"hostname"`
	IPs      []string `json:"ips,omitempty"`
	OS       string   `json:"os,omitempty"`
	Owner    string   `json:"owner,omitempty"`
	Tags     []string `json:"tags,omitempty"`
	Online   bool     `json:"online"`
	ExitNode bool     `json:"exit_node,omitempty"`
}

type StatusUser struct {
	LoginName   string `json:"login_name"`
	DisplayName string `json:"display_name,omitempty"`
	AvatarURL   string `json:"avatar_url,omitempty"`
}

type StatusPrefs struct {
	AcceptRoutes     bool   `json:"accept_routes"`
	AcceptDNS        bool   `json:"accept_dns"`
	ShieldsUp        bool   `json:"shields_up"`
	ExitNode         string `json:"exit_node"`
	ExitNodeAllowLAN bool   `json:"exit_node_allow_lan"`
}

type ExitNodeOption struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Hostname string `json:"hostname"`
	Online   bool   `json:"online"`
	Current  bool   `json:"current"`
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
		out = append(out, m.statusOf(ctx, n))
	}
	return out
}

// StatusOf reports one profile's status, for the commands that change a
// single profile and re-render from the result.
func (m *Manager) StatusOf(ctx context.Context, profile string) (Status, error) {
	n, err := m.Node(profile)
	if err != nil {
		return Status{}, err
	}
	return m.statusOf(ctx, n), nil
}

func (m *Manager) statusOf(ctx context.Context, n *Node) Status {
	p := n.Profile
	suffix, conflict := n.learned()
	s := Status{
		Profile: p.Name, Display: p.DisplayName, State: "Stopped",
		DeviceName:     p.Hostname,
		Suffixes:       m.cfg.SuffixesOf(p.Name),
		HTTPProxy:      fmt.Sprintf("127.0.0.1:%d", p.HTTPPort),
		SOCKS5:         fmt.Sprintf("127.0.0.1:%d", p.SOCKSPort),
		MagicDNSSuffix: suffix,
		SuffixConflict: conflict,
		AdminURL:       adminURL(p.ControlURL),
	}
	lc, err := n.srv.LocalClient()
	if err != nil {
		s.Err = err.Error()
		return s
	}
	st, err := lc.Status(ctx)
	if err != nil {
		s.Err = err.Error()
		return s
	}
	s.State, s.AuthURL, s.Peers, s.Health = st.BackendState, st.AuthURL, len(st.Peer), st.Health
	if s.AuthURL == "" {
		s.AuthURL = n.AuthURL()
	}
	if st.CurrentTailnet != nil {
		s.Tailnet = st.CurrentTailnet.Name
	}
	if st.Self != nil {
		s.Self = st.Self.DNSName
		s.KeyExpiry = st.Self.KeyExpiry
		for _, ip := range st.Self.TailscaleIPs {
			s.IPs = append(s.IPs, ip.String())
		}
		if u, ok := st.User[st.Self.UserID]; ok && u.LoginName != "" {
			s.User = &StatusUser{LoginName: u.LoginName, DisplayName: u.DisplayName, AvatarURL: u.ProfilePicURL}
		}
	}
	for _, ps := range st.Peer {
		d := Device{
			Name:     strings.TrimSuffix(ps.DNSName, "."),
			Hostname: ps.HostName,
			OS:       ps.OS,
			Online:   ps.Online,
			ExitNode: ps.ExitNode,
		}
		for _, ip := range ps.TailscaleIPs {
			d.IPs = append(d.IPs, ip.String())
		}
		if ps.Tags != nil {
			for i := range ps.Tags.Len() {
				d.Tags = append(d.Tags, ps.Tags.At(i))
			}
		}
		if len(d.Tags) == 0 {
			if u, ok := st.User[ps.UserID]; ok {
				d.Owner = u.LoginName
			}
		}
		s.Devices = append(s.Devices, d)

		if !ps.ExitNodeOption {
			continue
		}
		s.ExitNodes = append(s.ExitNodes, ExitNodeOption{
			ID:       string(ps.ID),
			Name:     strings.TrimSuffix(ps.DNSName, "."),
			Hostname: ps.HostName,
			Online:   ps.Online,
			Current:  ps.ExitNode,
		})
	}
	sort.Slice(s.ExitNodes, func(i, j int) bool { return s.ExitNodes[i].Name < s.ExitNodes[j].Name })
	sort.Slice(s.Devices, func(i, j int) bool { return s.Devices[i].Name < s.Devices[j].Name })
	if pr, err := lc.GetPrefs(ctx); err == nil {
		s.Prefs = &StatusPrefs{
			AcceptRoutes:     pr.RouteAll,
			AcceptDNS:        pr.CorpDNS,
			ShieldsUp:        pr.ShieldsUp,
			ExitNode:         string(pr.ExitNodeID),
			ExitNodeAllowLAN: pr.ExitNodeAllowLANAccess,
		}
	} else if s.Err == "" {
		s.Err = err.Error()
	}
	return s
}

// adminURL is empty for Headscale and other custom control servers, which
// have no admin console we can guess a URL for.
func adminURL(controlURL string) string {
	if controlURL != "" {
		u, err := url.Parse(controlURL)
		if err != nil || (u.Hostname() != "tailscale.com" && !strings.HasSuffix(u.Hostname(), ".tailscale.com")) {
			return ""
		}
	}
	return "https://login.tailscale.com/admin/machines"
}

func (m *Manager) client(profile string) (*local.Client, error) {
	n, err := m.Node(profile)
	if err != nil {
		return nil, err
	}
	return n.srv.LocalClient()
}

// SetPrefs applies a partial prefs edit to one profile.
func (m *Manager) SetPrefs(ctx context.Context, profile string, mp *ipn.MaskedPrefs) (Status, error) {
	lc, err := m.client(profile)
	if err != nil {
		return Status{}, err
	}
	if mp.ExitNodeIDSet && mp.ExitNodeID != "" {
		st, err := lc.Status(ctx)
		if err != nil {
			return Status{}, err
		}
		ok := false
		for _, ps := range st.Peer {
			if ps.ID == mp.ExitNodeID && ps.ExitNodeOption {
				ok = true
				break
			}
		}
		if !ok {
			return Status{}, fmt.Errorf("unknown exit node %q", mp.ExitNodeID)
		}
	}
	if _, err := lc.EditPrefs(ctx, mp); err != nil {
		return Status{}, err
	}
	return m.StatusOf(ctx, profile)
}

// Logout drops the tailnet credentials but keeps the node and its listeners
// alive; watch then re-issues an interactive login for the next status read.
func (m *Manager) Logout(ctx context.Context, profile string) (Status, error) {
	lc, err := m.client(profile)
	if err != nil {
		return Status{}, err
	}
	if err := lc.Logout(ctx); err != nil {
		return Status{}, err
	}
	return m.StatusOf(ctx, profile)
}

func (m *Manager) Close() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	var err error
	for _, n := range m.nodes {
		if e := n.srv.Close(); e != nil {
			err = e
		}
		if n.lock != nil {
			n.lock.Close()
		}
	}
	m.nodes = map[string]*Node{}
	return err
}

// lockStateDir takes an exclusive advisory lock on a profile's state
// directory, held for the process lifetime. The lock is released by the
// kernel if we are killed, so a crash does not strand it.
func lockStateDir(dir string) (*os.File, error) {
	f, err := os.OpenFile(filepath.Join(dir, "tsmux.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("another tsmux is already running for this profile (state dir %s)", dir)
	}
	return f, nil
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
