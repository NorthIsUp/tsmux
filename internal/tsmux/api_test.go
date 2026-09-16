package tsmux

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"
)

func post(t *testing.T, h http.Handler, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(http.MethodPost, "http://127.0.0.1:43180"+path, strings.NewReader(body))
	r.Host = "127.0.0.1:43180"
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func get(t *testing.T, h http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:43180"+path, nil)
	r.Host = "127.0.0.1:43180"
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func TestStatusEndpoint(t *testing.T) {
	cfg := tempConfig(t, twoProfiles)
	w := get(t, cfg.LocalHandler(NewManager(cfg, false)), "/status")
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d", w.Code)
	}
	if ct := w.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("content-type = %q", ct)
	}
	// A daemon with nothing up yet must answer with an empty array, not null:
	// the GUI decodes [Status] and a null is a decode failure, not "no nodes".
	var out []Status
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatalf("%v: %s", err, w.Body)
	}
	if strings.TrimSpace(w.Body.String()) != "[]" {
		t.Errorf("body = %s, want []", w.Body)
	}
}

func TestShutdownEndpoint(t *testing.T) {
	cfg := tempConfig(t, twoProfiles)

	// A daemon nobody wired a stop into (the CLI's one-shot commands) has to
	// say so rather than pretend it is going away.
	m := NewManager(cfg, false)
	w := post(t, cfg.LocalHandler(m), "/shutdown", "")
	if w.Code != http.StatusServiceUnavailable {
		t.Errorf("no stop hook: status = %d, want 503", w.Code)
	}
	if got := decodeField(t, w.Body.Bytes(), "error"); got == "" {
		t.Error("no stop hook: want an error field")
	}

	stopped := make(chan struct{})
	m.OnStop(func() { close(stopped) })
	w = post(t, cfg.LocalHandler(m), "/shutdown", "")
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
	if got := decodeField(t, w.Body.Bytes(), "status"); got != "stopping" {
		t.Errorf("body = %s", w.Body)
	}
	select {
	case <-stopped:
	case <-time.After(5 * time.Second):
		t.Fatal("the stop hook never ran")
	}
}

func TestPrefsEndpointErrors(t *testing.T) {
	cfg := tempConfig(t, twoProfiles)
	h := cfg.LocalHandler(NewManager(cfg, false))
	for _, tc := range []struct {
		name, path, body string
		want             int
	}{
		{name: "malformed json", path: "/prefs", body: "{", want: http.StatusBadRequest},
		{name: "profile is not running", path: "/prefs", body: `{"profile":"work","connected":true}`, want: http.StatusBadRequest},
		{name: "unknown profile", path: "/prefs", body: `{"profile":"ghost"}`, want: http.StatusBadRequest},
		{name: "logout malformed json", path: "/logout", body: "]", want: http.StatusBadRequest},
		{name: "logout profile is not running", path: "/logout", body: `{"profile":"work"}`, want: http.StatusBadRequest},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w := post(t, h, tc.path, tc.body)
			if w.Code != tc.want {
				t.Fatalf("status = %d, want %d (%s)", w.Code, tc.want, w.Body)
			}
			// Every failure is a JSON {"error": ...}; the GUI shows that string.
			if got := decodeField(t, w.Body.Bytes(), "error"); got == "" {
				t.Errorf("body = %s, want an error field", w.Body)
			}
		})
	}
}

func TestGuardRejectsCrossSiteWrites(t *testing.T) {
	cfg := tempConfig(t, twoProfiles)
	h := cfg.LocalHandler(NewManager(cfg, false))
	for _, tc := range []struct {
		name, ctype, fetchSite string
		want                   int
	}{
		{name: "form post dodges preflight", ctype: "application/x-www-form-urlencoded", want: http.StatusUnsupportedMediaType},
		{name: "no content type", want: http.StatusUnsupportedMediaType},
		{name: "charset is fine", ctype: "application/json; charset=utf-8", want: http.StatusBadRequest},
		{name: "cross-site", ctype: "application/json", fetchSite: "cross-site", want: http.StatusForbidden},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodPost, "http://127.0.0.1:43180/prefs", strings.NewReader("{"))
			r.Host = "127.0.0.1:43180"
			if tc.ctype != "" {
				r.Header.Set("Content-Type", tc.ctype)
			}
			if tc.fetchSite != "" {
				r.Header.Set("Sec-Fetch-Site", tc.fetchSite)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.want {
				t.Errorf("status = %d, want %d", w.Code, tc.want)
			}
		})
	}
}

func decodeField(t *testing.T, b []byte, key string) string {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("%v: %s", err, b)
	}
	s, _ := m[key].(string)
	return s
}

// The Swift menu bar app decodes these by name, so a rename here breaks the
// GUI with no compiler anywhere to notice. Freeze the wire contract.
func TestStatusJSONFieldNames(t *testing.T) {
	now := time.Now()
	st := Status{
		Profile: "work", Display: "Work", State: "Running", Self: "tsmux-work.work.ts.net",
		DeviceName: "tsmux-work", IPs: []string{"100.64.0.1"}, Peers: 2,
		AuthURL: "https://login.tailscale.com/a/1", Suffixes: []string{".work.ts.net"},
		HTTPProxy: "127.0.0.1:43110", SOCKS5: "127.0.0.1:43111", Err: "boom",
		Tailnet: "example.com", MagicDNSSuffix: "work.ts.net", SuffixConflict: "home",
		User:      &StatusUser{LoginName: "a@b.c", DisplayName: "A", AvatarURL: "https://x/y.png"},
		KeyExpiry: &now, Health: []string{"unhealthy"}, ConnectedSince: &now,
		AdminURL:  "https://login.tailscale.com/admin/machines",
		Prefs:     &StatusPrefs{Connected: true},
		ExitNodes: []ExitNodeOption{{ID: "n1", Name: "exit", Hostname: "exit", Online: true, Current: true}},
		Devices:   []Device{{Name: "nas", Hostname: "nas", IPs: []string{"100.64.0.2"}, OS: "linux", Owner: "a@b.c", Tags: []string{"tag:srv"}, Online: true, ExitNode: true}},
	}
	var got map[string]any
	b, err := json.Marshal(st)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	wantKeys(t, "status", got, "profile", "display_name", "state", "self", "device_name",
		"ips", "peers", "auth_url", "suffixes", "http_proxy", "socks5_proxy", "error",
		"tailnet", "magic_dns_suffix", "suffix_conflict", "user", "key_expiry", "health",
		"connected_since", "admin_url", "prefs", "exit_node_options", "devices")
	wantKeys(t, "user", got["user"], "login_name", "display_name", "avatar_url")
	wantKeys(t, "prefs", got["prefs"], "connected", "accept_routes", "accept_dns",
		"shields_up", "exit_node", "exit_node_allow_lan")
	wantKeys(t, "exit_node_options[0]", got["exit_node_options"].([]any)[0],
		"id", "name", "hostname", "online", "current")
	wantKeys(t, "devices[0]", got["devices"].([]any)[0],
		"name", "hostname", "ips", "os", "owner", "tags", "online", "exit_node")
}

func wantKeys(t *testing.T, what string, v any, want ...string) {
	t.Helper()
	m, ok := v.(map[string]any)
	if !ok {
		t.Fatalf("%s: not an object: %#v", what, v)
	}
	got := make([]string, 0, len(m))
	for k := range m {
		got = append(got, k)
	}
	slices.Sort(got)
	slices.Sort(want)
	if !slices.Equal(got, want) {
		t.Errorf("%s keys = %v, want %v", what, got, want)
	}
}

// The GUI's toggles arrive as this JSON; an absent field must leave the pref
// alone rather than silently writing a zero value over it.
func TestPrefsRequestMask(t *testing.T) {
	var empty PrefsRequest
	if err := json.Unmarshal([]byte(`{"profile":"work"}`), &empty); err != nil {
		t.Fatal(err)
	}
	mp := empty.masked()
	if mp.WantRunningSet || mp.RouteAllSet || mp.CorpDNSSet || mp.ShieldsUpSet ||
		mp.ExitNodeIDSet || mp.ExitNodeAllowLANAccessSet {
		t.Errorf("an empty request set a mask bit: %+v", mp)
	}

	var full PrefsRequest
	body := `{"profile":"work","connected":false,"accept_routes":true,"accept_dns":false,
	          "shields_up":true,"exit_node":"n1","exit_node_allow_lan":true}`
	if err := json.Unmarshal([]byte(body), &full); err != nil {
		t.Fatal(err)
	}
	mp = full.masked()
	switch {
	case !mp.WantRunningSet || mp.WantRunning:
		t.Error("connected:false must disconnect this one tailnet")
	case !mp.RouteAllSet || !mp.RouteAll:
		t.Error("accept_routes")
	case !mp.CorpDNSSet || mp.CorpDNS:
		t.Error("accept_dns")
	case !mp.ShieldsUpSet || !mp.ShieldsUp:
		t.Error("shields_up")
	case !mp.ExitNodeIDSet || string(mp.ExitNodeID) != "n1":
		t.Error("exit_node")
	case !mp.ExitNodeAllowLANAccessSet || !mp.ExitNodeAllowLANAccess:
		t.Error("exit_node_allow_lan")
	}
}
