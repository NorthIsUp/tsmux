package tsmux

import "testing"

// The daemon once called StartLoginInteractive while the backend was still in
// "NoState", which regenerates the node key and so forced a browser login on
// every restart. Everything about that decision lives here.
func TestShouldRequestLogin(t *testing.T) {
	for _, tc := range []struct {
		name, state, statusURL, heldURL string
		emptyRuns                       int
		want                            bool
		wantNext                        int
	}{
		{name: "loading, no url", state: "NoState", wantNext: 0},
		// The bug: NoState is the backend re-registering with the stored key.
		{name: "loading forever", state: "NoState", emptyRuns: 99, wantNext: 99},
		{name: "starting", state: "Starting", emptyRuns: 3, wantNext: 3},
		{name: "stopped", state: "Stopped", emptyRuns: 3, wantNext: 3},
		{name: "running resets the count", state: "Running", emptyRuns: 9, wantNext: 0},

		{name: "needs login, url present", state: "NeedsLogin", statusURL: "https://login.tailscale.com/a/1", emptyRuns: 9, wantNext: 0},
		{name: "needs login, first empty poll", state: "NeedsLogin", emptyRuns: 0, wantNext: 1},
		{name: "needs login, one short", state: "NeedsLogin", emptyRuns: loginRequestPolls - 2, wantNext: loginRequestPolls - 1},
		{name: "needs login, threshold", state: "NeedsLogin", emptyRuns: loginRequestPolls - 1, want: true, wantNext: 0},
		// A URL we already showed the user is still good; asking again would
		// invalidate the very link they are about to click.
		{name: "threshold but url already held", state: "NeedsLogin", heldURL: "https://login.tailscale.com/a/1",
			emptyRuns: loginRequestPolls - 1, wantNext: loginRequestPolls},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, next := shouldRequestLogin(tc.state, tc.statusURL, tc.heldURL, tc.emptyRuns)
			if got != tc.want || next != tc.wantNext {
				t.Errorf("got (%v, %d), want (%v, %d)", got, next, tc.want, tc.wantNext)
			}
		})
	}
}

// A restart that sits in NoState and then finds its key is the common case; it
// must never ask for a login, however long the loading takes.
func TestShouldRequestLoginRestartNeverAsks(t *testing.T) {
	runs := 0
	for range 50 {
		req, next := shouldRequestLogin("NoState", "", "", runs)
		if req {
			t.Fatal("asked for a login while the backend was still loading")
		}
		runs = next
	}
	if req, _ := shouldRequestLogin("Running", "", "", runs); req {
		t.Fatal("asked for a login after the node came up")
	}
}

// A genuinely logged-out node with no URL of its own does get one, eventually.
func TestShouldRequestLoginEventuallyAsks(t *testing.T) {
	runs, asked := 0, 0
	for range loginRequestPolls {
		var req bool
		req, runs = shouldRequestLogin("NeedsLogin", "", "", runs)
		if req {
			asked++
		}
	}
	if asked != 1 {
		t.Errorf("asked %d times in %d polls, want exactly 1", asked, loginRequestPolls)
	}
	if runs != 0 {
		t.Errorf("counter = %d after asking, want 0", runs)
	}
}
