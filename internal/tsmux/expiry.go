package tsmux

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

// DefaultExpiryWarn is the lead time the expiry check warns at. Tailscale's
// default node key lifetime is 180 days, so three weeks is several chances to
// notice a weekly check before anything stops working.
const DefaultExpiryWarn = 21 * 24 * time.Hour

// ExpiryLevel is one profile's key-expiry verdict.
type ExpiryLevel string

const (
	// ExpiryOK: the key expires, but not soon.
	ExpiryOK ExpiryLevel = "ok"
	// ExpiryNever: control reports no expiry at all — a tagged node, or a
	// device with key expiry disabled in the admin console.
	ExpiryNever ExpiryLevel = "never"
	// ExpirySoon: inside the warning window.
	ExpirySoon ExpiryLevel = "soon"
	// ExpiryExpired: already lapsed; that tailnet needs a browser login.
	ExpiryExpired ExpiryLevel = "expired"
	// ExpiryUnknown: the node is not running, so it has told us nothing. A
	// stopped node and a never-expiring one both report no expiry date, and
	// calling the stopped one "never" would hide a real deadline.
	ExpiryUnknown ExpiryLevel = "unknown"
)

// ExpiryReport is one profile's line in `tsmux expiry`.
type ExpiryReport struct {
	Profile  string      `json:"profile"`
	Display  string      `json:"display_name,omitempty"`
	State    string      `json:"state"`
	Level    ExpiryLevel `json:"level"`
	Expires  *time.Time  `json:"expires,omitempty"`
	DaysLeft *int        `json:"days_left,omitempty"`
	AdminURL string      `json:"admin_url,omitempty"`
}

// NeedsAttention is whether this profile is why the command exits non-zero.
func (r ExpiryReport) NeedsAttention() bool {
	return r.Level == ExpirySoon || r.Level == ExpiryExpired
}

// classifyExpiry is the whole threshold rule, kept apart from the wire types so
// it can be tested without a daemon.
func classifyExpiry(state string, expiry *time.Time, now time.Time, warn time.Duration) ExpiryLevel {
	if state != "Running" {
		return ExpiryUnknown
	}
	if expiry == nil || expiry.IsZero() {
		return ExpiryNever
	}
	switch {
	case !expiry.After(now):
		return ExpiryExpired
	case expiry.Sub(now) <= warn:
		return ExpirySoon
	default:
		return ExpiryOK
	}
}

// ExpiryReports turns daemon status into one report per profile, worst first so
// the thing to act on is the first line of output.
func ExpiryReports(sts []Status, now time.Time, warn time.Duration) []ExpiryReport {
	out := make([]ExpiryReport, 0, len(sts))
	for _, s := range sts {
		r := ExpiryReport{
			Profile:  s.Profile,
			Display:  s.Display,
			State:    s.State,
			Level:    classifyExpiry(s.State, s.KeyExpiry, now, warn),
			AdminURL: s.AdminURL,
		}
		if r.Level == ExpirySoon || r.Level == ExpiryExpired || r.Level == ExpiryOK {
			r.Expires = s.KeyExpiry
			d := int(s.KeyExpiry.Sub(now) / (24 * time.Hour))
			r.DaysLeft = &d
		}
		out = append(out, r)
	}
	sort.SliceStable(out, func(i, j int) bool {
		return expiryRank(out[i].Level) < expiryRank(out[j].Level)
	})
	return out
}

func expiryRank(l ExpiryLevel) int {
	switch l {
	case ExpiryExpired:
		return 0
	case ExpirySoon:
		return 1
	case ExpiryUnknown:
		return 2
	case ExpiryOK:
		return 3
	default:
		return 4
	}
}

// ExpiryNeedsAttention is the command's exit status: true when anything has
// expired or is about to.
func ExpiryNeedsAttention(rs []ExpiryReport) bool {
	for _, r := range rs {
		if r.NeedsAttention() {
			return true
		}
	}
	return false
}

// ExpirySummary is the one-line form, for a notification body or the last line
// of the command. Empty when nothing needs attention.
func ExpirySummary(rs []ExpiryReport) string {
	var parts []string
	for _, r := range rs {
		if !r.NeedsAttention() {
			continue
		}
		name := r.Display
		if name == "" {
			name = r.Profile
		}
		switch {
		case r.Level == ExpiryExpired:
			parts = append(parts, name+": key expired")
		case r.DaysLeft != nil && *r.DaysLeft <= 0:
			parts = append(parts, name+": key expires today")
		case r.DaysLeft != nil && *r.DaysLeft == 1:
			parts = append(parts, name+": key expires in 1 day")
		case r.DaysLeft != nil:
			parts = append(parts, fmt.Sprintf("%s: key expires in %d days", name, *r.DaysLeft))
		}
	}
	if len(parts) == 0 {
		return ""
	}
	return strings.Join(parts, "; ") + ". Sign in again to renew it."
}
