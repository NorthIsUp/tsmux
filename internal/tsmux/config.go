package tsmux

import (
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config mirrors the on-disk YAML. Field names match TailMux's schema so an
// existing config.yaml can be used unchanged.
type Config struct {
	Version  int                 `yaml:"version"`
	Router   Router              `yaml:"router"`
	Paths    Paths               `yaml:"paths"`
	Security Security            `yaml:"security"`
	Profiles map[string]*Profile `yaml:"profiles"`
	Tunnels  map[string]*Tunnel  `yaml:"tunnels,omitempty"`

	path    string
	sorted  []*Profile
	tunnels []*Tunnel
}

type Router struct {
	HTTPProxy           string `yaml:"http_proxy"`
	SOCKS5Proxy         string `yaml:"socks5_proxy"`
	PACListen           string `yaml:"pac_listen"`
	ProfileHTTPBase     int    `yaml:"profile_http_proxy_base"`
	ProfileSOCKSBase    int    `yaml:"profile_socks5_proxy_base"`
	ProfileHostnameBase string `yaml:"profile_hostname_base"`
}

type Paths struct {
	StateDir string `yaml:"state_dir"`
}

type Security struct {
	RequireLoopbackListeners  bool `yaml:"require_loopback_listeners"`
	AllowCrossProfileFallback bool `yaml:"allow_cross_profile_fallback"`
	AllowIPLiterals           bool `yaml:"allow_ip_literals"`
}

// Tunnel exposes a loopback port that forwards into one tailnet, for
// clients that cannot speak a proxy (database GUIs, RDP, git over SSH).
type Tunnel struct {
	Name    string `yaml:"-"`
	Listen  string `yaml:"listen"`
	Profile string `yaml:"profile"`
	Target  string `yaml:"target"`
}

type Profile struct {
	Name         string   `yaml:"-"`
	DisplayName  string   `yaml:"display_name"`
	Hostname     string   `yaml:"hostname"`
	AuthKeyEnv   string   `yaml:"auth_key_env"`
	ControlURL   string   `yaml:"control_url"`
	AcceptRoutes bool     `yaml:"accept_routes"`
	Suffixes     []string `yaml:"suffixes"`
	MatchRoot    bool     `yaml:"match_root"`
	IPRoutes     []string `yaml:"ip_routes"`
	HTTPPort     int      `yaml:"http_proxy_port"`
	SOCKSPort    int      `yaml:"socks5_proxy_port"`

	routes []netip.Prefix
}

// Fallback is the profile used when nothing matches and cross-profile
// fallback is enabled. Kept as a method so routing has one entry point.
var nameRE = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$`)

func Default() *Config {
	return &Config{
		Version: 1,
		Router: Router{
			HTTPProxy:           "127.0.0.1:43100",
			SOCKS5Proxy:         "127.0.0.1:43101",
			PACListen:           "127.0.0.1:43180",
			ProfileHTTPBase:     43110,
			ProfileSOCKSBase:    43111,
			ProfileHostnameBase: "tsmux",
		},
		Paths:    Paths{StateDir: stateDirDefault()},
		Security: Security{RequireLoopbackListeners: true},
		Profiles: map[string]*Profile{},
	}
}

// configCandidates lists config locations in precedence order: an explicit
// override, then XDG, then the platform default. macOS's UserConfigDir is
// ~/Library/Application Support, which is the wrong home for a CLI's config,
// so XDG wins here even on Darwin.
func configCandidates() []string {
	if v := os.Getenv("TSMUX_CONFIG"); v != "" {
		return []string{v}
	}
	var out []string
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		out = append(out, filepath.Join(xdg, "tsmux", "config.yaml"))
	}
	if home := os.Getenv("HOME"); home != "" {
		out = append(out, filepath.Join(home, ".config", "tsmux", "config.yaml"))
	}
	if dir, err := os.UserConfigDir(); err == nil {
		p := filepath.Join(dir, "tsmux", "config.yaml")
		if !slices.Contains(out, p) {
			out = append(out, p)
		}
	}
	return out
}

// DefaultPath is where a new config is written. It skips ~/.config only when
// that directory does not exist at all.
func DefaultPath() string {
	c := configCandidates()
	if len(c) == 1 {
		return c[0]
	}
	for _, p := range c {
		// Reuse a config that is already there, wherever it lives.
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	// An explicitly set XDG_CONFIG_HOME is an instruction, not a hint: honour
	// it even when the directory has not been created yet.
	if os.Getenv("XDG_CONFIG_HOME") != "" {
		return c[0]
	}
	for _, p := range c {
		if _, err := os.Stat(filepath.Dir(filepath.Dir(p))); err == nil {
			return p
		}
	}
	return c[0]
}

// stateDirDefault follows XDG_STATE_HOME, falling back to ~/.local/state.
func stateDirDefault() string {
	if v := os.Getenv("XDG_STATE_HOME"); v != "" {
		return filepath.Join(v, "tsmux")
	}
	return filepath.Join(os.Getenv("HOME"), ".local", "state", "tsmux")
}

func Load(path string) (*Config, error) {
	if path == "" {
		path = DefaultPath()
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	cfg := Default()
	if err := yaml.Unmarshal(b, cfg); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	cfg.path = path
	return cfg, cfg.Normalize()
}

func (c *Config) Path() string { return c.path }

// Normalize fills defaults, allocates stable per-profile ports and validates.
func (c *Config) Normalize() error {
	d := Default()
	if c.Router.HTTPProxy == "" {
		c.Router.HTTPProxy = d.Router.HTTPProxy
	}
	if c.Router.SOCKS5Proxy == "" {
		c.Router.SOCKS5Proxy = d.Router.SOCKS5Proxy
	}
	if c.Router.PACListen == "" {
		c.Router.PACListen = d.Router.PACListen
	}
	if c.Router.ProfileHTTPBase == 0 {
		c.Router.ProfileHTTPBase = d.Router.ProfileHTTPBase
	}
	if c.Router.ProfileSOCKSBase == 0 {
		c.Router.ProfileSOCKSBase = d.Router.ProfileSOCKSBase
	}
	if c.Router.ProfileHostnameBase == "" {
		c.Router.ProfileHostnameBase = d.Router.ProfileHostnameBase
	}
	if c.Paths.StateDir == "" {
		c.Paths.StateDir = d.Paths.StateDir
	}
	c.Paths.StateDir = expand(c.Paths.StateDir)

	for _, l := range []string{c.Router.HTTPProxy, c.Router.SOCKS5Proxy, c.Router.PACListen} {
		if err := c.checkListen(l); err != nil {
			return err
		}
	}

	names := make([]string, 0, len(c.Profiles))
	for n := range c.Profiles {
		names = append(names, n)
	}
	sort.Strings(names)

	c.sorted, c.tunnels = c.sorted[:0], c.tunnels[:0]
	for i, n := range names {
		p := c.Profiles[n]
		if p == nil {
			p = &Profile{}
			c.Profiles[n] = p
		}
		p.Name = n
		if !nameRE.MatchString(n) {
			return fmt.Errorf("profile %q: name must be lowercase alphanumeric with dashes", n)
		}
		if p.DisplayName == "" {
			p.DisplayName = n
		}
		if p.Hostname == "" {
			p.Hostname = c.Router.ProfileHostnameBase + "-" + n
		}
		// Stable allocation: ports track sorted position, so PAC output and
		// per-profile browser settings survive unrelated config edits.
		if p.HTTPPort == 0 {
			p.HTTPPort = c.Router.ProfileHTTPBase + 2*i
		}
		if p.SOCKSPort == 0 {
			p.SOCKSPort = c.Router.ProfileSOCKSBase + 2*i
		}
		if p.ControlURL != "" {
			u, err := url.Parse(p.ControlURL)
			if err != nil || u.Scheme != "https" && u.Scheme != "http" {
				return fmt.Errorf("profile %q: bad control_url %q", n, p.ControlURL)
			}
		}
		clean := p.Suffixes[:0]
		for _, s := range p.Suffixes {
			s = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(s), "."))
			if s == "" {
				continue
			}
			if !strings.HasPrefix(s, ".") {
				s = "." + s
			}
			clean = append(clean, s)
		}
		p.Suffixes = clean
		p.routes = nil
		for _, r := range p.IPRoutes {
			pfx, err := netip.ParsePrefix(strings.TrimSpace(r))
			if err != nil {
				return fmt.Errorf("profile %q: bad ip_route %q: %w", n, r, err)
			}
			p.routes = append(p.routes, pfx)
		}
		c.sorted = append(c.sorted, p)
	}

	tnames := make([]string, 0, len(c.Tunnels))
	for n := range c.Tunnels {
		tnames = append(tnames, n)
	}
	sort.Strings(tnames)
	for _, n := range tnames {
		t := c.Tunnels[n]
		t.Name = n
		if err := c.checkListen(t.Listen); err != nil {
			return fmt.Errorf("tunnel %q: %w", n, err)
		}
		if _, _, err := net.SplitHostPort(t.Target); err != nil {
			return fmt.Errorf("tunnel %q: target must be host:port, got %q", n, t.Target)
		}
		if t.Profile != "" {
			if _, ok := c.Profiles[t.Profile]; !ok {
				return fmt.Errorf("tunnel %q: unknown profile %q", n, t.Profile)
			}
		}
		c.tunnels = append(c.tunnels, t)
	}
	return nil
}

func (c *Config) OrderedTunnels() []*Tunnel { return c.tunnels }

func (c *Config) checkListen(addr string) error {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("bad listen address %q: %w", addr, err)
	}
	if !c.Security.RequireLoopbackListeners {
		return nil
	}
	ip, err := netip.ParseAddr(host)
	if err != nil || !ip.IsLoopback() {
		return fmt.Errorf("listener %q is not loopback (set security.require_loopback_listeners: false to allow)", addr)
	}
	return nil
}

// Ordered returns profiles in stable (sorted) order.
func (c *Config) Ordered() []*Profile { return c.sorted }

func (c *Config) StateDir(profile string) string {
	return filepath.Join(c.Paths.StateDir, "profiles", profile)
}

func (p *Profile) AuthKey() string {
	if p.AuthKeyEnv == "" {
		return ""
	}
	return os.Getenv(p.AuthKeyEnv)
}

func expand(p string) string {
	if strings.HasPrefix(p, "~/") {
		return filepath.Join(os.Getenv("HOME"), p[2:])
	}
	return p
}

func (c *Config) Save(path string) error {
	if path == "" {
		path = c.path
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, err := yaml.Marshal(c)
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o600)
}
