package tsmux

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// pacHarness runs the generated PAC the way a browser would, with the four
// helpers a PAC file is entitled to assume. Asserting on the emitted text
// instead would prove nothing about what a browser actually does with it.
const pacHarness = `
const fs = require('fs');
function dnsDomainIs(host, domain) {
  return host.length >= domain.length && host.slice(host.length - domain.length) === domain;
}
function shExpMatch(str, shexp) {
  const re = shexp.replace(/[.^$+(){}\[\]|\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.');
  return new RegExp('^' + re + '$').test(str);
}
function isPlainHostName(host) { return host.indexOf('.') === -1; }
function ip2int(s) { return s.split('.').reduce((a, o) => ((a << 8) + (parseInt(o, 10) & 255)), 0) >>> 0; }
function isInNet(host, pat, mask) {
  if (!/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/.test(host)) return false;
  return ((ip2int(host) & ip2int(mask)) >>> 0) === ((ip2int(pat) & ip2int(mask)) >>> 0);
}
const src = fs.readFileSync(process.argv[2], 'utf8');
const pacFn = eval(src + '\nFindProxyForURL;');
for (const host of process.argv.slice(3)) {
  console.log(pacFn('http://' + host + '/', host));
}
`

func runPAC(t *testing.T, c *Config, hosts []string) []string {
	t.Helper()
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node is not installed; skipping PAC execution test")
	}
	dir := t.TempDir()
	pac := filepath.Join(dir, "proxy.pac")
	if err := os.WriteFile(pac, []byte(c.PAC()), 0o600); err != nil {
		t.Fatal(err)
	}
	harness := filepath.Join(dir, "harness.js")
	if err := os.WriteFile(harness, []byte(pacHarness), 0o600); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command(node, append([]string{harness, pac}, hosts...)...).CombinedOutput()
	if err != nil {
		t.Fatalf("node: %v\n%s\n--- pac ---\n%s", err, out, c.PAC())
	}
	return strings.Split(strings.TrimRight(string(out), "\n"), "\n")
}

func pacCfg(t *testing.T) *Config {
	t.Helper()
	c := Default()
	c.Profiles = map[string]*Profile{
		"corp": {Suffixes: []string{".eng.work.ts.net"}, HTTPPort: 43110, SOCKSPort: 43111},
		"home": {Suffixes: []string{"home.ts.net"}, HTTPPort: 43120, SOCKSPort: 43121},
		"work": {
			Suffixes: []string{"work.ts.net"}, MatchRoot: true,
			IPRoutes: []string{"100.64.0.0/16"}, HTTPPort: 43130, SOCKSPort: 43131,
		},
	}
	if err := c.Normalize(); err != nil {
		t.Fatal(err)
	}
	return c
}

func TestPACRoutesLikeTheRouter(t *testing.T) {
	c := pacCfg(t)
	const (
		corp = "PROXY 127.0.0.1:43110; SOCKS5 127.0.0.1:43111"
		home = "PROXY 127.0.0.1:43120; SOCKS5 127.0.0.1:43121"
		work = "PROXY 127.0.0.1:43130; SOCKS5 127.0.0.1:43131"
	)
	cases := []struct{ host, want string }{
		{"box.work.ts.net", work},
		{"work.ts.net", work},     // bare apex of a claimed suffix
		{"BOX.Work.TS.Net", work}, // browsers do not normalise case for us
		{"nas.home.ts.net", home},
		{"db.eng.work.ts.net", corp}, // the more specific tailnet wins
		{"laptop", work},             // match_root
		{"100.64.1.5", work},         // ip_routes
		{"example.com", "DIRECT"},
		{"1.1.1.1", "DIRECT"},
		{"localhost", "DIRECT"},
		{"127.0.0.1", "DIRECT"},
		{"printer.local", "DIRECT"},
	}
	hosts := make([]string, len(cases))
	for i, tc := range cases {
		hosts[i] = tc.host
	}
	got := runPAC(t, c, hosts)
	if len(got) != len(cases) {
		t.Fatalf("got %d lines for %d hosts: %v", len(got), len(cases), got)
	}
	for i, tc := range cases {
		if got[i] != tc.want {
			t.Errorf("%s -> %q, want %q", tc.host, got[i], tc.want)
		}
		// Anything the PAC hands to a profile the router refuses (or routes
		// elsewhere) is a split brain between the browser and the CLI.
		m, err := c.Route(tc.host)
		if tc.want == "DIRECT" {
			continue
		}
		if err != nil {
			t.Errorf("%s: PAC proxies it but Route refuses: %v", tc.host, err)
			continue
		}
		if p := c.Profiles[m.Profile.Name]; !strings.Contains(tc.want, strconv.Itoa(p.HTTPPort)) {
			t.Errorf("%s: PAC says %q, Route says %s", tc.host, got[i], m.Profile.Name)
		}
	}
}

// No profiles, no suffixes: the PAC must still be valid JavaScript that sends
// everything direct, or a browser pointed at it drops all traffic.
func TestPACEmptyConfigIsDirect(t *testing.T) {
	c := Default()
	if err := c.Normalize(); err != nil {
		t.Fatal(err)
	}
	for i, line := range runPAC(t, c, []string{"example.com", "box.work.ts.net", "1.2.3.4"}) {
		if line != "DIRECT" {
			t.Errorf("host %d -> %q, want DIRECT", i, line)
		}
	}
}

// A suffix learned at runtime has to reach the browser without a restart.
func TestPACPicksUpLearnedSuffix(t *testing.T) {
	c := pacCfg(t)
	c.addSuffix("home", ".tailnet-ab.ts.net")
	got := runPAC(t, c, []string{"nas.tailnet-ab.ts.net"})
	if want := "PROXY 127.0.0.1:43120; SOCKS5 127.0.0.1:43121"; got[0] != want {
		t.Errorf("got %q, want %q", got[0], want)
	}
}
