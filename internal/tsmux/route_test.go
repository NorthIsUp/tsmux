package tsmux

import (
	"fmt"
	"testing"
)

func cfg(t *testing.T) *Config {
	t.Helper()
	c := Default()
	c.Profiles = map[string]*Profile{
		"work": {Suffixes: []string{"work.ts.net"}, MatchRoot: true, IPRoutes: []string{"100.64.0.0/16"}},
		"corp": {Suffixes: []string{".eng.work.ts.net"}},
		"home": {Suffixes: []string{"home.ts.net"}},
	}
	if err := c.Normalize(); err != nil {
		t.Fatal(err)
	}
	return c
}

func TestRoute(t *testing.T) {
	c := cfg(t)
	for _, tc := range []struct{ host, want string }{
		{"box.work.ts.net", "work"},
		{"work.ts.net", "work"},      // bare apex of a claimed suffix
		{"BOX.Work.TS.Net.", "work"}, // case + trailing dot
		{"box.work.ts.net:8080", "work"},
		{"db.eng.work.ts.net", "corp"}, // longest suffix wins over "work"
		{"nas.home.ts.net", "home"},
		{"laptop", "work"},     // single match_root profile
		{"100.64.1.5", "work"}, // ip_route
	} {
		m, err := c.Route(tc.host)
		if err != nil {
			t.Fatalf("%s: %v", tc.host, err)
		}
		if m.Profile.Name != tc.want {
			t.Errorf("%s: got %s (%s), want %s", tc.host, m.Profile.Name, m.Reason, tc.want)
		}
	}
}

func TestRouteRejects(t *testing.T) {
	c := cfg(t)
	for _, host := range []string{"example.com", "1.1.1.1", ""} {
		if m, err := c.Route(host); err == nil {
			t.Errorf("%s: expected refusal, got %s", host, m.Profile.Name)
		}
	}
}

func TestRouteAmbiguousBareName(t *testing.T) {
	c := cfg(t)
	c.Profiles["home"].MatchRoot = true
	if err := c.Normalize(); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Route("laptop"); err == nil {
		t.Fatal("expected ambiguity error when two profiles claim bare names")
	}
}

func TestStablePorts(t *testing.T) {
	c := cfg(t)
	// corp, home, work sorted -> 43110/43112/43114
	if got := c.Profiles["corp"].HTTPPort; got != 43110 {
		t.Errorf("corp http port = %d, want 43110", got)
	}
	if got := c.Profiles["work"].HTTPPort; got != 43114 {
		t.Errorf("work http port = %d, want 43114", got)
	}
	if got := c.Profiles["work"].SOCKSPort; got != 43115 {
		t.Errorf("work socks port = %d, want 43115", got)
	}
}

// D4: Route ranges over Suffixes while the watch goroutine appends to them.
func TestRouteConcurrentSuffixLearn(t *testing.T) {
	c := cfg(t)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := range 200 {
			c.addSuffix("home", fmt.Sprintf(".learned%d.ts.net", i))
		}
	}()
	for range 200 {
		if _, err := c.Route("box.work.ts.net"); err != nil {
			t.Fatal(err)
		}
	}
	<-done
}
