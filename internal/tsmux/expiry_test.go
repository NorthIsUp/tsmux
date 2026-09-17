package tsmux

import (
	"strings"
	"testing"
	"time"
)

var expiryNow = time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)

func at(d time.Duration) *time.Time {
	t := expiryNow.Add(d)
	return &t
}

func TestClassifyExpiry(t *testing.T) {
	day := 24 * time.Hour
	for _, tc := range []struct {
		name   string
		state  string
		expiry *time.Time
		warn   time.Duration
		want   ExpiryLevel
	}{
		{"stopped node says nothing", "Stopped", nil, 21 * day, ExpiryUnknown},
		{"stopped node with a stale date still says nothing", "Stopped", at(100 * day), 21 * day, ExpiryUnknown},
		{"needs login is not a verdict", "NeedsLogin", nil, 21 * day, ExpiryUnknown},
		{"running with no expiry is a tagged node", "Running", nil, 21 * day, ExpiryNever},
		{"running with a zero time is also never", "Running", &time.Time{}, 21 * day, ExpiryNever},
		{"far future is fine", "Running", at(180 * day), 21 * day, ExpiryOK},
		{"just outside the window is fine", "Running", at(21*day + time.Minute), 21 * day, ExpiryOK},
		{"exactly on the window warns", "Running", at(21 * day), 21 * day, ExpirySoon},
		{"inside the window warns", "Running", at(3 * day), 21 * day, ExpirySoon},
		{"now counts as expired", "Running", at(0), 21 * day, ExpiryExpired},
		{"past is expired", "Running", at(-time.Second), 21 * day, ExpiryExpired},
		{"a zero window still catches an expired key", "Running", at(-day), 0, ExpiryExpired},
		{"a zero window lets a live key through", "Running", at(time.Minute), 0, ExpiryOK},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := classifyExpiry(tc.state, tc.expiry, expiryNow, tc.warn); got != tc.want {
				t.Fatalf("classifyExpiry(%q, %v) = %q, want %q", tc.state, tc.expiry, got, tc.want)
			}
		})
	}
}

func TestExpiryReportsOrdersWorstFirst(t *testing.T) {
	day := 24 * time.Hour
	sts := []Status{
		{Profile: "fine", State: "Running", KeyExpiry: at(90 * day)},
		{Profile: "tagged", State: "Running"},
		{Profile: "stopped", State: "Stopped"},
		{Profile: "soon", State: "Running", KeyExpiry: at(5 * day)},
		{Profile: "dead", State: "Running", KeyExpiry: at(-day)},
	}
	got := ExpiryReports(sts, expiryNow, DefaultExpiryWarn)
	want := []string{"dead", "soon", "stopped", "fine", "tagged"}
	for i, name := range want {
		if got[i].Profile != name {
			t.Fatalf("report %d = %q, want %q (order: %v)", i, got[i].Profile, name, want)
		}
	}
	if !ExpiryNeedsAttention(got) {
		t.Fatal("an expired key must need attention")
	}
	if d := got[1].DaysLeft; d == nil || *d != 5 {
		t.Fatalf("days left for soon = %v, want 5", d)
	}
	// Levels without a date must not invent one, or the UI renders 1970.
	for _, r := range got {
		if r.Level == ExpiryUnknown || r.Level == ExpiryNever {
			if r.Expires != nil || r.DaysLeft != nil {
				t.Fatalf("%s (%s) carries a date it does not have", r.Profile, r.Level)
			}
		}
	}
}

func TestExpiryNeedsAttentionIgnoresHealthyProfiles(t *testing.T) {
	rs := ExpiryReports([]Status{
		{Profile: "fine", State: "Running", KeyExpiry: at(90 * 24 * time.Hour)},
		{Profile: "tagged", State: "Running"},
		{Profile: "stopped", State: "Stopped"},
	}, expiryNow, DefaultExpiryWarn)
	if ExpiryNeedsAttention(rs) {
		t.Fatal("nothing is expiring; exit status must stay zero")
	}
	if s := ExpirySummary(rs); s != "" {
		t.Fatalf("summary = %q, want empty", s)
	}
}

func TestExpirySummary(t *testing.T) {
	day := 24 * time.Hour
	rs := ExpiryReports([]Status{
		{Profile: "work", Display: "Work", State: "Running", KeyExpiry: at(day + time.Hour)},
		{Profile: "home", State: "Running", KeyExpiry: at(-day)},
		{Profile: "fine", State: "Running", KeyExpiry: at(90 * day)},
	}, expiryNow, DefaultExpiryWarn)
	got := ExpirySummary(rs)
	if !strings.HasPrefix(got, "home: key expired; Work: key expires in 1 day") {
		t.Fatalf("summary = %q", got)
	}
	if strings.Contains(got, "fine") {
		t.Fatalf("summary names a healthy profile: %q", got)
	}
}
