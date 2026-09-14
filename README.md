# tsmux

Run **any number of Tailscale tailnets at once** and route traffic to the right
one automatically.

Tailscale's own client holds one tailnet at a time — switching profiles tears
down the other. tsmux instead runs one userspace node per tailnet
([`tsnet`](https://pkg.go.dev/tailscale.com/tsnet)) inside a single process, so
your work tailnet, a client's tailnet, and your homelab are all reachable
simultaneously. No TUN device, no root, no profile switching.

MIT licensed. A free-software alternative to TailMux.

## How it works

```
                  ┌── suffix .work.ts.net  ──► tsnet node "work"  ──► work tailnet
browser / curl ──►│── suffix .acme.ts.net  ──► tsnet node "acme"  ──► client tailnet
  (PAC or proxy)  └── suffix .home.ts.net  ──► tsnet node "home"  ──► homelab tailnet
```

`tsmux up` starts every node plus loopback listeners:

| listener | what it is |
|---|---|
| `127.0.0.1:43100` / `:43101` | router HTTP + SOCKS5 proxy — picks the tailnet from the hostname |
| `127.0.0.1:43110`, `43112`, … | one HTTP proxy per profile, for pinning a browser profile to one tailnet |
| `127.0.0.1:43180/proxy.pac` | generated PAC file so browsers route every tailnet correctly |

Hostnames are never resolved on the host OS. They are passed to the owning
tailnet and resolved by its MagicDNS, so identical names in different tailnets
stay separate.

## Install

```sh
go install github.com/NorthIsUp/tsmux@latest
```

## Quick start

```sh
tsmux init                                          # write ~/.config/tsmux/config.yaml
tsmux profile add work --suffix .your-tailnet.ts.net --match-root
tsmux profile add acme --suffix .acme-corp.ts.net
tsmux up                                            # prints a login URL per tailnet
```

Then, in another shell:

```sh
tsmux status                        # per-tailnet state, addresses, peers
tsmux test nas.acme-corp.ts.net     # which profile owns a name, and why
tsmux run curl https://nas.acme-corp.ts.net/
eval "$(tsmux env)"                 # point this shell at the router
tsmux ssh admin@box.your-tailnet.ts.net
```

For browsers, either run `tsmux up --system-proxy` (macOS; restores your
previous settings on exit) or paste the PAC URL from `tsmux pac url` into your
browser's proxy settings. Per-profile ports let you pin one browser profile to
one tailnet: point it at `127.0.0.1:43110` and it only ever sees that tailnet.

## Configuration

`~/.config/tsmux/config.yaml`. tsmux owns this file and rewrites it (when you
add a profile, or when it learns a tailnet's DNS suffix at first login), so
comments are not preserved. `suffixes` is optional: leave it out and tsmux
fills it in once the profile logs in.

```yaml
version: 1

profiles:
  work:
    display_name: "Work"
    suffixes: [".your-tailnet.ts.net"]
    match_root: true            # also claim bare names like `laptop`
    auth_key_env: TSMUX_WORK_AUTHKEY   # optional; otherwise log in via URL
  acme:
    suffixes: [".acme-corp.ts.net"]
    ip_routes: ["100.64.0.0/10"]       # route these CIDRs here too
    accept_routes: true                # use this tailnet's subnet routers
  hs:
    suffixes: [".hs.internal"]
    control_url: "https://headscale.example.com"   # Headscale works too

tunnels:                        # for clients that can't speak a proxy
  pg:
    listen: "127.0.0.1:15432"
    profile: acme
    target: "db.acme-corp.ts.net:5432"

security:
  require_loopback_listeners: true    # refuse to bind anything non-loopback
  allow_cross_profile_fallback: false # unmatched hosts error instead of leaking
  allow_ip_literals: false            # bare IPs must be covered by ip_routes
```

Routing rules, in order: longest matching `suffixes` entry wins; then
`ip_routes` for literal addresses; then `match_root` for bare single-label
names. Anything unmatched is refused rather than sent to an arbitrary tailnet.
`tsmux doctor` reports overlapping claims and port conflicts.

Ports are derived from each profile's sorted position, so they stay stable when
you edit unrelated parts of the config. Override with `http_proxy_port` /
`socks5_proxy_port` on a profile.

## Commands

| command | purpose |
|---|---|
| `up` | start every tailnet, the router, PAC server and tunnels |
| `status` | per-profile backend state, tailnet address, peer count |
| `test <host>` | show which profile owns a hostname, and why |
| `profile add/list/rm/logout` | manage profiles |
| `pac print/url/apply/restore/status` | browser proxy auto-config |
| `env` / `run` | proxy environment for a shell or one command |
| `connect` / `tunnel` / `ssh` | raw TCP, forwarded ports, SSH |
| `dns query` | resolve a name inside its owning tailnet |
| `doctor` | config, port and overlap checks |

Every command takes `--json`.

## Status

Working: multi-tailnet routing, HTTP + SOCKS5 proxies, PAC generation and
macOS system-proxy apply/restore, tunnels, SSH, profile-scoped DNS, doctor.

Not built: a menu-bar GUI, Linux/Windows system-proxy integration (use the PAC
URL directly), and a background service wrapper.

## Releasing

`VERSION` at the repo root is the single source of truth. Both
`scripts/build-app.sh` (via `-ldflags -X main.version=…`) and
`.github/workflows/release.yml` read it; nothing else stores the version.

```sh
mise run bump-patch   # or bump-minor / bump-major
```

Land the bump on `main` and the release workflow tags `v<version>`, builds
`tsmux` for darwin/linux × arm64/amd64 plus a zipped `TSMux.app`, and publishes
a GitHub release with SHA256 checksums. If `VERSION` is unchanged the workflow
is a no-op, so ordinary commits to `main` do not release.

`TSMux.app` in the release is ad-hoc signed and **not notarized** — clear the
quarantine flag after installing:

```sh
xattr -dr com.apple.quarantine /Applications/TSMux.app
```
