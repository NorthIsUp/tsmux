package tsmux

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func tempConfig(t *testing.T, body string) *Config {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

const twoProfiles = `version: 1
profiles:
  work: {}
  personal:
    suffixes: [".tailnet-ab.ts.net"]
`

func TestPersistSuffix(t *testing.T) {
	for _, tc := range []struct {
		name, profile, want, conflict string
		writes                        bool
	}{
		{name: "fresh append", profile: "work", want: ".tailnet-cd.ts.net", writes: true},
		{name: "already claimed by another profile", profile: "work", want: ".tailnet-ab.ts.net", conflict: "personal"},
		{name: "profile deleted since startup", profile: "ghost", want: ".tailnet-cd.ts.net"},
		{name: "idempotent re-run", profile: "personal", want: ".tailnet-ab.ts.net"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := tempConfig(t, twoProfiles)
			before, err := os.ReadFile(cfg.Path())
			if err != nil {
				t.Fatal(err)
			}
			m := NewManager(cfg, false)

			conflict, err := m.persistSuffix(tc.profile, tc.want)
			if err != nil {
				t.Fatal(err)
			}
			if conflict != tc.conflict {
				t.Fatalf("conflict = %q, want %q", conflict, tc.conflict)
			}
			after, err := os.ReadFile(cfg.Path())
			if err != nil {
				t.Fatal(err)
			}
			if !tc.writes {
				if string(after) != string(before) {
					t.Errorf("config was rewritten:\n%s", after)
				}
				return
			}
			if strings.Count(string(after), tc.want) != 1 {
				t.Errorf("want exactly one %s in:\n%s", tc.want, after)
			}
			// The live config must route on the new suffix without a restart.
			match, err := cfg.Route("box" + tc.want)
			if err != nil || match.Profile.Name != tc.profile {
				t.Errorf("live route: %v %v", match, err)
			}
			// Re-running is a no-op, so every daemon start is safe.
			if _, err := m.persistSuffix(tc.profile, tc.want); err != nil {
				t.Fatal(err)
			}
			again, _ := os.ReadFile(cfg.Path())
			if strings.Count(string(again), tc.want) != 1 {
				t.Errorf("second run duplicated the suffix:\n%s", again)
			}
		})
	}
}

func TestGuard(t *testing.T) {
	h := tempConfig(t, twoProfiles).LocalHandler(NewManager(Default(), false))
	for _, tc := range []struct {
		name, method, path, host, origin string
		want                             int
	}{
		{name: "pac from loopback", method: "GET", path: "/proxy.pac", host: "127.0.0.1:43180", want: 200},
		{name: "origin header", method: "GET", path: "/proxy.pac", host: "127.0.0.1:43180", origin: "http://evil.test", want: 403},
		{name: "rebound host", method: "GET", path: "/proxy.pac", host: "tsmux.evil.test", want: 403},
		{name: "GET /prefs", method: "GET", path: "/prefs", host: "127.0.0.1:43180", want: 405},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(tc.method, "http://"+tc.host+tc.path, nil)
			r.Host = tc.host
			if tc.origin != "" {
				r.Header.Set("Origin", tc.origin)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.want {
				t.Errorf("%s %s: got %d, want %d", tc.method, tc.path, w.Code, tc.want)
			}
		})
	}
}
