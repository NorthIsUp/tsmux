package tsmux

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// Ports are pinned in the file once allocated, so a profile added later that
// sorts earlier must not be handed a port another profile already holds.
func TestNormalizePortsOutOfOrderInsert(t *testing.T) {
	c := Default()
	c.Profiles = map[string]*Profile{"work": {}}
	if err := c.Normalize(); err != nil {
		t.Fatal(err)
	}
	work := *c.Profiles["work"]

	c.Profiles["alpha"] = &Profile{}
	if err := c.Normalize(); err != nil {
		t.Fatal(err)
	}
	alpha := c.Profiles["alpha"]
	if got := c.Profiles["work"]; got.HTTPPort != work.HTTPPort || got.SOCKSPort != work.SOCKSPort {
		t.Errorf("work moved: %d/%d, want %d/%d", got.HTTPPort, got.SOCKSPort, work.HTTPPort, work.SOCKSPort)
	}
	if alpha.HTTPPort == work.HTTPPort || alpha.SOCKSPort == work.SOCKSPort {
		t.Errorf("alpha collides with work on %d/%d", alpha.HTTPPort, alpha.SOCKSPort)
	}
}

// Two profiles owning one suffix would make routing a coin flip, so a claim
// that collides reports the owner instead of taking it.
func TestClaimSuffix(t *testing.T) {
	newCfg := func(t *testing.T) *Config {
		t.Helper()
		c := Default()
		c.Profiles = map[string]*Profile{
			"work": {Suffixes: []string{".work.ts.net"}},
			"home": {},
		}
		if err := c.Normalize(); err != nil {
			t.Fatal(err)
		}
		return c
	}

	c := newCfg(t)
	if owner, err := c.ClaimSuffix("home", "home.ts.net"); err != nil || owner != "" {
		t.Fatalf("owner %q, err %v", owner, err)
	}
	// Stored with the leading dot the routing table matches on, whatever the
	// user typed.
	if got := c.SuffixesOf("home"); len(got) != 1 || got[0] != ".home.ts.net" {
		t.Fatalf("suffixes = %v", got)
	}

	// Trailing dots and case are the same claim, not three.
	for _, s := range []string{".home.ts.net", "HOME.TS.NET", "home.ts.net."} {
		if owner, err := c.ClaimSuffix("home", s); err != nil || owner != "" {
			t.Errorf("%s: owner %q, err %v", s, owner, err)
		}
	}
	if got := c.SuffixesOf("home"); len(got) != 1 {
		t.Errorf("suffixes = %v, want one entry", got)
	}

	if owner, err := c.ClaimSuffix("home", "work.ts.net"); err != nil || owner != "work" {
		t.Errorf("collision: owner %q, err %v", owner, err)
	}
	if slices.Contains(c.SuffixesOf("home"), ".work.ts.net") {
		t.Error("a colliding claim was taken anyway")
	}
	// Re-claiming your own suffix is not a collision with yourself.
	if owner, err := c.ClaimSuffix("work", ".work.ts.net"); err != nil || owner != "" {
		t.Errorf("self-claim: owner %q, err %v", owner, err)
	}

	if _, err := c.ClaimSuffix("ghost", "a.ts.net"); err == nil {
		t.Error("claimed a suffix for a profile that does not exist")
	}
	for _, s := range []string{"", ".", "  "} {
		if _, err := c.ClaimSuffix("home", s); err == nil {
			t.Errorf("%q was accepted as a DNS suffix", s)
		}
	}
}

func TestReleaseSuffix(t *testing.T) {
	c := Default()
	c.Profiles = map[string]*Profile{"work": {Suffixes: []string{".work.ts.net", ".eng.work.ts.net"}}}
	if err := c.Normalize(); err != nil {
		t.Fatal(err)
	}
	if !c.ReleaseSuffix("work", "WORK.ts.net.") { // same normalisation as a claim
		t.Fatal("release of a held suffix reported false")
	}
	if got := c.SuffixesOf("work"); len(got) != 1 || got[0] != ".eng.work.ts.net" {
		t.Errorf("suffixes = %v", got)
	}
	if c.ReleaseSuffix("work", ".work.ts.net") {
		t.Error("releasing twice reported a second removal")
	}
	if c.ReleaseSuffix("ghost", ".work.ts.net") {
		t.Error("released from a profile that does not exist")
	}
	// The released suffix stops routing immediately.
	if m, err := c.Route("box.work.ts.net"); err == nil {
		t.Errorf("still routed to %s", m.Profile.Name)
	}
}

func TestNormalizeDefaults(t *testing.T) {
	c := &Config{Profiles: map[string]*Profile{"work": {Suffixes: []string{"WORK.TS.NET.", " ", "."}}}}
	if err := c.Normalize(); err != nil {
		t.Fatal(err)
	}
	p := c.Profiles["work"]
	switch {
	case p.Name != "work":
		t.Errorf("name = %q", p.Name)
	case p.DisplayName != "work":
		t.Errorf("display name = %q", p.DisplayName)
	case p.Hostname != "tsmux-work":
		t.Errorf("hostname = %q, want the profile-hostname-base prefix", p.Hostname)
	case p.HTTPPort != 43110 || p.SOCKSPort != 43111:
		t.Errorf("ports = %d/%d", p.HTTPPort, p.SOCKSPort)
	}
	// Blank and bare-dot suffixes are dropped, the rest normalised.
	if got := p.Suffixes; len(got) != 1 || got[0] != ".work.ts.net" {
		t.Errorf("suffixes = %v", got)
	}
	// Non-nil so the JSON the GUI decodes is always an array.
	if p.IPRoutes == nil {
		t.Error("ip_routes is nil; the GUI decodes an array")
	}
	if c.Router.HTTPProxy == "" || c.Router.PACListen == "" || c.Paths.StateDir == "" {
		t.Errorf("router/paths defaults were not filled: %+v %+v", c.Router, c.Paths)
	}
}

func TestNormalizeRejects(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func(*Config)
	}{
		{"profile name with capitals", func(c *Config) { c.Profiles["Work"] = &Profile{} }},
		{"profile name with a dot", func(c *Config) { c.Profiles["a.b"] = &Profile{} }},
		{"control url is not http", func(c *Config) { c.Profiles["work"].ControlURL = "ftp://example.com" }},
		{"ip route is not a cidr", func(c *Config) { c.Profiles["work"].IPRoutes = []string{"100.64.0.1"} }},
		{"listener is not loopback", func(c *Config) { c.Router.PACListen = "0.0.0.0:43180" }},
		{"listener has no port", func(c *Config) { c.Router.HTTPProxy = "127.0.0.1" }},
		{"tunnel names an unknown profile", func(c *Config) {
			c.Tunnels = map[string]*Tunnel{"db": {Listen: "127.0.0.1:5432", Profile: "ghost", Target: "db:5432"}}
		}},
		{"tunnel target has no port", func(c *Config) {
			c.Tunnels = map[string]*Tunnel{"db": {Listen: "127.0.0.1:5432", Profile: "work", Target: "db"}}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := Default()
			c.Profiles = map[string]*Profile{"work": {}}
			tc.edit(c)
			if err := c.Normalize(); err == nil {
				t.Error("accepted")
			}
		})
	}

	// The loopback rule is a default, not a law: it can be turned off.
	c := Default()
	c.Profiles = map[string]*Profile{"work": {}}
	c.Security.RequireLoopbackListeners = false
	c.Router.PACListen = "0.0.0.0:43180"
	if err := c.Normalize(); err != nil {
		t.Errorf("opt-out was refused: %v", err)
	}
}

// Ports and learned suffixes have to survive a write, or the next start hands
// the profile different ports and asks the browser for a different PAC.
func TestSaveLoadRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	c := Default()
	c.Paths.StateDir = filepath.Join(dir, "state")
	c.Profiles = map[string]*Profile{
		"work": {Suffixes: []string{"work.ts.net"}, MatchRoot: true, IPRoutes: []string{"100.64.0.0/16"}},
		"home": {ControlURL: "https://controlplane.example.com", AcceptRoutes: true},
	}
	if err := c.Normalize(); err != nil {
		t.Fatal(err)
	}
	c.addSuffix("home", ".learned.ts.net")
	if err := c.Save(path); err != nil {
		t.Fatal(err)
	}

	got, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if got.Path() != path {
		t.Errorf("path = %q", got.Path())
	}
	for name, want := range c.Profiles {
		g, ok := got.Profiles[name]
		if !ok {
			t.Fatalf("profile %s did not survive the round trip", name)
		}
		switch {
		case g.HTTPPort != want.HTTPPort || g.SOCKSPort != want.SOCKSPort:
			t.Errorf("%s ports = %d/%d, want %d/%d", name, g.HTTPPort, g.SOCKSPort, want.HTTPPort, want.SOCKSPort)
		case g.Hostname != want.Hostname:
			t.Errorf("%s hostname = %q, want %q", name, g.Hostname, want.Hostname)
		case !slices.Equal(g.Suffixes, want.Suffixes):
			t.Errorf("%s suffixes = %v, want %v", name, g.Suffixes, want.Suffixes)
		case g.MatchRoot != want.MatchRoot || g.AcceptRoutes != want.AcceptRoutes:
			t.Errorf("%s flags = %v/%v", name, g.MatchRoot, g.AcceptRoutes)
		case g.ControlURL != want.ControlURL:
			t.Errorf("%s control_url = %q", name, g.ControlURL)
		}
	}
	if got.Paths.StateDir != c.Paths.StateDir {
		t.Errorf("state dir = %q, want %q", got.Paths.StateDir, c.Paths.StateDir)
	}
	// A learned suffix routes after the restart that reloads it.
	if m, err := got.Route("box.learned.ts.net"); err != nil || m.Profile.Name != "home" {
		t.Errorf("learned suffix did not survive: %v %v", m, err)
	}
	// Saving with no path reuses the one it was loaded from.
	if err := got.Save(""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path + ".tmp"); err == nil {
		t.Error("the atomic write left its temp file behind")
	}
}

func TestValidateHostname(t *testing.T) {
	for _, h := range []string{"tsmux-work", "a", "A1", strings.Repeat("a", 63)} {
		if err := ValidateHostname(h); err != nil {
			t.Errorf("%q: %v", h, err)
		}
	}
	for _, h := range []string{"", "-lead", "trail-", "has.dot", "has_underscore", strings.Repeat("a", 64)} {
		if err := ValidateHostname(h); err == nil {
			t.Errorf("%q was accepted", h)
		}
	}
}
