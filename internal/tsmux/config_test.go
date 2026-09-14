package tsmux

import "testing"

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
