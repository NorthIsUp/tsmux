# tsmux

**Run every one of your Tailscale tailnets at once.** Work, a client's, your
homelab — all connected simultaneously, with hostnames resolving to the right
one automatically.

Tailscale's own client holds one tailnet at a time; switching accounts tears
the other down. tsmux runs one userspace node per tailnet
([`tsnet`](https://pkg.go.dev/tailscale.com/tsnet)) inside a single process, so
nothing has to be switched off to reach something else. No TUN device, no root,
no admin prompt.

MIT licensed.

## Install

Download `TSMux-<version>-macos.zip` from
[Releases](https://github.com/NorthIsUp/tsmux/releases), unzip, and drag
**TSMux.app** to `/Applications`.

The app is ad-hoc signed, not notarized, so macOS will refuse it on first
launch. Right-click → **Open**, or:

```sh
xattr -dr com.apple.quarantine /Applications/TSMux.app
```

## Getting started

1. Launch TSMux. It lives in the menu bar — the dot grid with an arrow.
2. Click it → **Set up your first tailnet…**
3. Give it a name. That's the only thing you type.
4. Sign in when the browser opens.

That's it. tsmux learns the tailnet's DNS suffix itself, so you never look up
or type `tailnet-abc123.ts.net`. Add another tailnet the same way and both stay
connected.

## What you get

**Names just work.** `https://grafana.your-tailnet.ts.net` resolves in your
browser with nothing configured — tsmux publishes a proxy auto-config file and
points the system at it while a tailnet is up. Traffic to anything else goes
out normally, untouched.

**Every tailnet at once.** Overlapping names are not a problem: each tailnet
owns its own DNS suffix, and tsmux routes by longest match. Two tailnets can
both have a `grafana`.

**A device list per tailnet.** Open a tailnet's submenu → **Devices**, grouped
by owner and by tag. Click to copy the URL; hold <kbd>⌥</kbd> for the IP,
<kbd>⌥⇧</kbd> for the short name — the value you'll get is shown greyed on the
right.

**Per-tailnet settings.** Accept subnet routes, use the tailnet's DNS, allow
incoming connections, pick an exit node — each set independently per tailnet,
in **Settings → Accounts**.

**Nothing hidden.** Features a userspace node genuinely cannot do —
running *as* an exit node, VPN On Demand, Tailnet Lock — still appear in
Settings, disabled, with a note saying why. They need a system VPN device,
which is the same thing tsmux declines to use in order to run unlimited
tailnets at once.

## For the terminal

Browsers pick up the PAC file automatically; command line tools don't read it,
so point them at tsmux explicitly:

```sh
tsmux run curl https://grafana.your-tailnet.ts.net/   # one command
eval "$(tsmux env)"                                    # this whole shell
tsmux ssh admin@box.your-tailnet.ts.net                # ssh through the right tailnet
```

The CLI ships inside the app bundle at
`/Applications/TSMux.app/Contents/Resources/tsmux`. Symlink it onto your
`PATH`, or install it on its own:

```sh
go install github.com/NorthIsUp/tsmux@latest
```

| command | purpose |
|---|---|
| `up` / `down` | run the daemon in the foreground / stop a running one |
| `status` | per-tailnet state, address, peer count |
| `test <host>` | which tailnet owns a hostname, and why |
| `run` / `env` | proxy environment for one command or a whole shell |
| `ssh` / `connect` / `tunnel` | SSH, raw TCP, forwarded local ports |
| `profile add/list/rm/set` | manage tailnets without the GUI |
| `pac print/url/apply/restore` | the browser proxy config |
| `expiry` | days left on each tailnet's node key; exits 1 when one is close |
| `doctor` | config, port and overlap checks |

Every command takes `--json`.

## How it works

```
                  ┌── .work.ts.net  ──► tsnet node "work"  ──► work tailnet
browser ─ PAC ───►│── .acme.ts.net  ──► tsnet node "acme"  ──► client tailnet
                  └── .home.ts.net  ──► tsnet node "home"  ──► homelab tailnet
```

Each tailnet gets its own node, its own state directory, and its own pair of
loopback proxies. A hostname is never resolved on the host: it goes to the
tailnet that owns it and is resolved by that tailnet's DNS, which is why
overlapping names stay separate and why split-DNS domains work without a
system Tailscale installed.

| listener | what it is |
|---|---|
| `127.0.0.1:43100` / `:43101` | router HTTP + SOCKS5 — picks the tailnet from the hostname |
| `127.0.0.1:43110`, `43112`, … | one proxy per tailnet, for pinning a browser profile to one |
| `127.0.0.1:43180/proxy.pac` | the generated PAC file |
| `127.0.0.1:43180/status` | daemon status as JSON |

## Configuration

The GUI writes `~/.config/tsmux/config.yaml` (or `$XDG_CONFIG_HOME`). You only
need to touch it for things the GUI does not expose:

```yaml
version: 1

profiles:
  work:
    display_name: "Work"
    suffixes: [".your-tailnet.ts.net"]   # learned automatically after first login
    match_root: true                     # also claim bare names like `laptop`
    auth_key_env: TSMUX_WORK_AUTHKEY     # optional; skips the browser
  hs:
    suffixes: [".hs.internal"]
    control_url: "https://headscale.example.com"   # Headscale works too

tunnels:                        # for clients that can't speak a proxy
  pg:
    listen: "127.0.0.1:15432"
    profile: work
    target: "db.your-tailnet.ts.net:5432"

security:
  require_loopback_listeners: true     # refuse to bind anything non-loopback
  allow_cross_profile_fallback: false  # unmatched hosts error instead of leaking
  allow_ip_literals: false             # bare IPs must be covered by ip_routes
```

Routing order: longest matching suffix, then `ip_routes` for literal addresses,
then `match_root` for bare names. Anything unmatched is refused rather than
sent to an arbitrary tailnet. `tsmux doctor` reports overlaps and port
conflicts. tsmux owns this file and rewrites it; comments are not preserved.

## Node keys expire

A Tailscale node key lasts 180 days from the browser sign-in that created it.
When one lapses that tailnet stops working until you sign in again, and nothing
about it is automatic: the client can only *shorten* its own expiry, never
extend it, so there is no unattended renewal to build. What tsmux can do is
make sure the date never surprises you.

```sh
tsmux expiry              # a line per tailnet; exits 1 if any is close or lapsed
tsmux expiry --json --warn-days 30
```

**Settings → General → Node keys → Check key expiry weekly** installs a
LaunchAgent (`~/Library/LaunchAgents/dev.northisup.tsmux.expiry.plist`) that
runs `tsmux expiry --notify` every Sunday morning and posts a notification only
when a key is within 21 days. Turning the toggle off unloads and deletes it;
nothing is installed unless you ask. The menu also carries a row for the
soonest-expiring tailnet, which opens the admin console to sign in again.

### Making it moot

Either of these stops the countdown for good, and both are set in the admin
console rather than from the node:

- **Disable key expiry** for the device — Machines → the device → ⋯ → *Disable
  key expiry*. tsmux then reports `never` for it.
- **Register the node under a tag** (an auth key or OAuth client with tags).
  A tagged node has no key expiry at all; Tailscale's client treats a zero
  expiry as exactly that, and tagged nodes are the case it means. Set
  `auth_key_env` on the profile to register with such a key. Note that a tagged
  node is owned by the tailnet, not by you, so ACLs must grant it what it needs.

## Limitations

- macOS only for the app. The CLI builds and runs on Linux; the system-proxy
  integration is macOS-specific, so elsewhere point your browser at the PAC URL.
- Cannot run *as* an exit node, and has no VPN On Demand or Tailnet Lock —
  all three need a system VPN device.
- Adding or removing a tailnet restarts the daemon, a 2–5 second blip.

## Releasing

`VERSION` holds the version; `scripts/build-app.sh` reads it for `-ldflags`.
Bump it with `mise run bump-patch|bump-minor|bump-major`, commit, then:

```sh
mise run release      # tags v<VERSION> and pushes it
```

Pushing that tag is what builds and publishes the release — cross-compiled
binaries, a zipped app, and SHA256 checksums. An ordinary commit to main
publishes nothing.

## Development

```sh
mise run dev       # rebuild + relaunch the app on every source change
mise run test      # go test -race
mise run lint      # gofmt + vet
mise run hk:check  # everything CI runs
```
