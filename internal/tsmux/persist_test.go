package tsmux

import (
	"context"
	"errors"
	"testing"

	"tailscale.com/ipn"
)

type fakeEditor struct {
	calls []*ipn.MaskedPrefs
	err   error
}

func (f *fakeEditor) EditPrefs(_ context.Context, mp *ipn.MaskedPrefs) (*ipn.Prefs, error) {
	f.calls = append(f.calls, mp)
	return &mp.Prefs, f.err
}

// A login held only in memory is lost on the next restart, so reaching Running
// has to write the profile. This guards the commit, not the transport.
func TestPersistLoginCommitsProfile(t *testing.T) {
	f := &fakeEditor{}
	if err := persistLogin(context.Background(), f); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 1 {
		t.Fatalf("EditPrefs called %d times, want 1", len(f.calls))
	}
	mp := f.calls[0]
	if !mp.WantRunningSet {
		t.Error("WantRunningSet is false; an unmasked edit changes nothing and never commits")
	}
	if !mp.Prefs.WantRunning {
		t.Error("WantRunning is false; the commit must not stop the node it just brought up")
	}
}

func TestPersistLoginReportsFailure(t *testing.T) {
	want := errors.New("backend down")
	f := &fakeEditor{err: want}
	if err := persistLogin(context.Background(), f); !errors.Is(err, want) {
		t.Fatalf("got %v, want %v", err, want)
	}
}
