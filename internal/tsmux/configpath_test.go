package tsmux

import (
	"os"
	"path/filepath"
	"testing"
)

// macOS's os.UserConfigDir is ~/Library/Application Support, which is the
// wrong home for a CLI config, so XDG has to win ahead of it.
func TestDefaultPathPrecedence(t *testing.T) {
	home := t.TempDir()

	set := func(xdg string, mkdirs ...string) {
		t.Helper()
		for _, d := range mkdirs {
			if err := os.MkdirAll(filepath.Join(home, d), 0o700); err != nil {
				t.Fatal(err)
			}
		}
		t.Setenv("HOME", home)
		t.Setenv("TSMUX_CONFIG", "")
		t.Setenv("XDG_CONFIG_HOME", xdg)
	}
	clean := func() { os.RemoveAll(home); os.MkdirAll(home, 0o700) }

	clean()
	set("")
	if got, want := DefaultPath(), filepath.Join(home, ".config/tsmux/config.yaml"); got != want {
		t.Errorf("no dirs: got %s, want %s", got, want)
	}

	clean()
	set("", ".config")
	if got, want := DefaultPath(), filepath.Join(home, ".config/tsmux/config.yaml"); got != want {
		t.Errorf("~/.config exists: got %s, want %s", got, want)
	}

	// An explicitly set XDG_CONFIG_HOME wins even before its dir is created.
	clean()
	set(filepath.Join(home, "xdg"), ".config")
	if got, want := DefaultPath(), filepath.Join(home, "xdg/tsmux/config.yaml"); got != want {
		t.Errorf("XDG set: got %s, want %s", got, want)
	}

	// An existing config is reused wherever it already lives, so upgrading
	// does not orphan a config written under the old macOS default.
	clean()
	legacy := filepath.Join(home, "Library/Application Support/tsmux/config.yaml")
	if err := os.MkdirAll(filepath.Dir(legacy), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(legacy, []byte("version: 1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	set("", ".config")
	if got := DefaultPath(); got != legacy {
		t.Errorf("existing config: got %s, want %s", got, legacy)
	}

	clean()
	set("")
	t.Setenv("TSMUX_CONFIG", "/tmp/explicit.yaml")
	if got := DefaultPath(); got != "/tmp/explicit.yaml" {
		t.Errorf("TSMUX_CONFIG: got %s", got)
	}
}

func TestStateDirFollowsXDG(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	t.Setenv("XDG_STATE_HOME", filepath.Join(home, "xstate"))
	if got, want := stateDirDefault(), filepath.Join(home, "xstate/tsmux"); got != want {
		t.Errorf("got %s, want %s", got, want)
	}

	t.Setenv("XDG_STATE_HOME", "")
	if got, want := stateDirDefault(), filepath.Join(home, ".local/state/tsmux"); got != want {
		t.Errorf("got %s, want %s", got, want)
	}
}
