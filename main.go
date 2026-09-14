// Command tsmux routes developer traffic across any number of isolated
// Tailscale tailnets at once.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"

	"github.com/NorthIsUp/tsmux/internal/tsmux"
)

var (
	cfgPath    string
	outputJSON bool
	verbose    bool
	version    = "dev"
)

func main() {
	log.SetFlags(0)
	log.SetPrefix("tsmux: ")
	if err := root().Execute(); err != nil {
		log.Fatal(err)
	}
}

func root() *cobra.Command {
	c := &cobra.Command{
		Use:           "tsmux",
		Short:         "Route developer traffic across isolated Tailscale tailnets",
		SilenceUsage:  true,
		SilenceErrors: false,
	}
	c.PersistentFlags().StringVar(&cfgPath, "config", "", "config file path")
	c.PersistentFlags().BoolVarP(&outputJSON, "json", "j", false, "emit JSON")
	c.PersistentFlags().BoolVarP(&verbose, "verbose", "v", false, "enable debug logging")
	c.AddCommand(cmdInit(), cmdUp(), cmdStatus(), cmdTest(), cmdProfile(), cmdPAC(),
		cmdEnv(), cmdRun(), cmdConnect(), cmdTunnel(), cmdDNS(), cmdSSH(), cmdDoctor(), cmdVersion())
	return c
}

func load() (*tsmux.Config, error) { return tsmux.Load(cfgPath) }

// loadOrDefault treats "no config file yet" as an empty config, so the GUI's
// launch probe and the first `profile add` do not have to special-case it.
func loadOrDefault() (*tsmux.Config, error) {
	cfg, err := load()
	if errors.Is(err, os.ErrNotExist) {
		return tsmux.Default(), nil
	}
	return cfg, err
}

func emit(v any, plain func()) {
	if outputJSON {
		e := json.NewEncoder(os.Stdout)
		e.SetIndent("", "  ")
		e.Encode(v)
		return
	}
	plain()
}

// --- init -------------------------------------------------------------------

func cmdInit() *cobra.Command {
	var force bool
	c := &cobra.Command{
		Use:   "init",
		Short: "Write a starter config",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path := cfgPath
			if path == "" {
				path = tsmux.DefaultPath()
			}
			if _, err := os.Stat(path); err == nil && !force {
				return fmt.Errorf("%s already exists (use --force)", path)
			}
			cfg := tsmux.Default()
			cfg.Profiles["example"] = &tsmux.Profile{
				DisplayName: "Example tailnet",
				Suffixes:    []string{".example.ts.net"},
				MatchRoot:   true,
				AuthKeyEnv:  "TSMUX_EXAMPLE_AUTHKEY",
			}
			if err := cfg.Normalize(); err != nil {
				return err
			}
			if err := cfg.Save(path); err != nil {
				return err
			}
			fmt.Printf("wrote %s\n", path)
			return nil
		},
	}
	c.Flags().BoolVar(&force, "force", false, "overwrite existing config")
	return c
}

// --- up ---------------------------------------------------------------------

func cmdUp() *cobra.Command {
	var applyProxy bool
	c := &cobra.Command{
		Use:   "up",
		Short: "Start every tailnet profile, the router, and the PAC server",
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := load()
			if err != nil {
				return err
			}
			ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
			defer stop()

			m := tsmux.NewManager(cfg, verbose)
			if err := m.Start(ctx); err != nil {
				return err
			}
			defer m.Close()

			var closers []func()
			defer func() {
				for _, f := range closers {
					f()
				}
			}()

			serveProxies := func(label string, httpAddr, socksAddr string, dial tsmux.DialFunc) error {
				hl, err := net.Listen("tcp", httpAddr)
				if err != nil {
					return fmt.Errorf("%s http proxy: %w", label, err)
				}
				sl, err := net.Listen("tcp", socksAddr)
				if err != nil {
					hl.Close()
					return fmt.Errorf("%s socks proxy: %w", label, err)
				}
				closers = append(closers, func() { hl.Close(); sl.Close() })
				srv := &http.Server{Handler: &tsmux.HTTPProxy{Dial: dial, Label: label}}
				go srv.Serve(hl)
				go tsmux.ServeSOCKS5(sl, dial)
				log.Printf("%-12s http %s  socks5 %s", label, httpAddr, socksAddr)
				return nil
			}

			if err := serveProxies("router", cfg.Router.HTTPProxy, cfg.Router.SOCKS5Proxy, m.Dial); err != nil {
				return err
			}
			for _, p := range cfg.Ordered() {
				n, err := m.Node(p.Name)
				if err != nil {
					return err
				}
				if err := serveProxies(p.Name,
					fmt.Sprintf("127.0.0.1:%d", p.HTTPPort),
					fmt.Sprintf("127.0.0.1:%d", p.SOCKSPort), n.Dial); err != nil {
					return err
				}
			}

			pl, err := net.Listen("tcp", cfg.Router.PACListen)
			if err != nil {
				return fmt.Errorf("pac server: %w", err)
			}
			closers = append(closers, func() { pl.Close() })
			go (&http.Server{Handler: cfg.LocalHandler(m)}).Serve(pl)
			log.Printf("%-12s %s", "pac", cfg.PACURL())
			log.Printf("%-12s %s", "status", cfg.StatusURL())

			for _, t := range cfg.OrderedTunnels() {
				dial := m.Dial
				if t.Profile != "" {
					n, err := m.Node(t.Profile)
					if err != nil {
						return err
					}
					dial = n.Dial
				}
				tl, err := net.Listen("tcp", t.Listen)
				if err != nil {
					return fmt.Errorf("tunnel %s: %w", t.Name, err)
				}
				closers = append(closers, func() { tl.Close() })
				go tsmux.ServeTunnel(tl, t.Target, dial)
				log.Printf("%-12s %s -> %s", "tunnel:"+t.Name, t.Listen, t.Target)
			}

			if applyProxy {
				if err := cfg.ApplySystemProxy(); err != nil {
					return err
				}
				log.Printf("system proxy -> %s", cfg.PACURL())
				defer func() {
					if err := cfg.RestoreSystemProxy(); err != nil {
						log.Printf("restore system proxy: %v", err)
					} else {
						log.Print("system proxy restored")
					}
				}()
			}

			log.Print("ready; ctrl-c to stop")
			<-ctx.Done()
			log.Print("shutting down")
			return nil
		},
	}
	c.Flags().BoolVar(&applyProxy, "system-proxy", false, "point the system proxy at the PAC file, and restore it on exit")
	return c
}

// --- status / test ----------------------------------------------------------

func cmdStatus() *cobra.Command {
	var standalone bool
	c := &cobra.Command{
		Use:   "status",
		Short: "Show every profile's tailnet status",
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := load()
			if err != nil {
				return err
			}
			// Ask the running daemon first; starting our own nodes here would
			// contend for the same state directories.
			st, err := cfg.FetchStatus()
			if err != nil {
				if !standalone {
					return err
				}
				ctx, cancel := context.WithTimeout(cmd.Context(), 30*time.Second)
				defer cancel()
				m := tsmux.NewManager(cfg, verbose)
				if err := m.Start(ctx); err != nil {
					return err
				}
				defer m.Close()
				st = m.Status(ctx)
			}
			emit(st, func() {
				w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
				fmt.Fprintln(w, "PROFILE\tSTATE\tADDRESS\tPEERS\tHTTP PROXY\tSUFFIXES")
				for _, s := range st {
					note := s.Self
					if s.AuthURL != "" {
						note = "login: " + s.AuthURL
					}
					fmt.Fprintf(w, "%s\t%s\t%s\t%d\t%s\t%s\n",
						s.Profile, s.State, note, s.Peers, s.HTTPProxy, strings.Join(s.Suffixes, " "))
				}
				w.Flush()
			})
			return nil
		},
	}
	c.Flags().BoolVar(&standalone, "standalone", false, "start nodes locally if no daemon is running")
	return c
}

func cmdTest() *cobra.Command {
	return &cobra.Command{
		Use:   "test <host>",
		Short: "Show which profile owns a hostname",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			cfg, err := load()
			if err != nil {
				return err
			}
			m, err := cfg.Route(args[0])
			if err != nil {
				return err
			}
			emit(map[string]string{
				"host": args[0], "profile": m.Profile.Name, "reason": m.Reason,
				"http_proxy": fmt.Sprintf("127.0.0.1:%d", m.Profile.HTTPPort),
			}, func() {
				fmt.Printf("%s -> %s (%s) via 127.0.0.1:%d\n", args[0], m.Profile.Name, m.Reason, m.Profile.HTTPPort)
			})
			return nil
		},
	}
}

// --- profile ----------------------------------------------------------------

func cmdProfile() *cobra.Command {
	c := &cobra.Command{Use: "profile", Short: "Manage tailnet profiles"}

	c.AddCommand(&cobra.Command{
		Use: "list", Short: "List configured profiles",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := loadOrDefault()
			if err != nil {
				return err
			}
			// Always a JSON array, never null: the GUI's launch probe reads
			// [] as "first run".
			list := append([]*tsmux.Profile{}, cfg.Ordered()...)
			emit(list, func() {
				w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
				fmt.Fprintln(w, "PROFILE\tHOSTNAME\tHTTP\tSOCKS5\tSUFFIXES")
				for _, p := range cfg.Ordered() {
					fmt.Fprintf(w, "%s\t%s\t%d\t%d\t%s\n", p.Name, p.Hostname, p.HTTPPort, p.SOCKSPort, strings.Join(p.Suffixes, " "))
				}
				w.Flush()
			})
			return nil
		},
	})

	var suffixes []string
	var control, authEnv, displayName string
	var matchRoot bool
	add := &cobra.Command{
		Use: "add <name>", Short: "Add a profile to the config", Args: cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			cfg, err := loadOrDefault()
			if err != nil {
				return err
			}
			if _, ok := cfg.Profiles[args[0]]; ok {
				return fmt.Errorf("profile %q already exists", args[0])
			}
			cfg.Profiles[args[0]] = &tsmux.Profile{
				DisplayName: displayName, Suffixes: suffixes,
				ControlURL: control, AuthKeyEnv: authEnv, MatchRoot: matchRoot,
			}
			if err := cfg.Normalize(); err != nil {
				return err
			}
			path := cfg.Path()
			if path == "" {
				path = tsmux.DefaultPath()
			}
			if err := cfg.Save(path); err != nil {
				return err
			}
			p := cfg.Profiles[args[0]]
			emit(p, func() {
				fmt.Printf("added %s (http 127.0.0.1:%d, socks5 127.0.0.1:%d) to %s\n", args[0], p.HTTPPort, p.SOCKSPort, path)
			})
			return nil
		},
	}
	add.Flags().StringVar(&displayName, "display-name", "", "human-readable name for the GUI")
	add.Flags().StringSliceVar(&suffixes, "suffix", nil, "DNS suffix this tailnet owns, repeatable; omit it and tsmux learns it at first login")
	add.Flags().StringVar(&control, "control-url", "", "custom control server (Headscale)")
	add.Flags().StringVar(&authEnv, "auth-key-env", "", "env var holding an auth key")
	add.Flags().BoolVar(&matchRoot, "match-root", false, "claim bare single-label hostnames")
	c.AddCommand(add)

	var purge bool
	rm := &cobra.Command{
		Use: "rm <name>", Short: "Remove a profile from the config", Args: cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			cfg, err := load()
			if err != nil {
				return err
			}
			if _, ok := cfg.Profiles[args[0]]; !ok {
				return fmt.Errorf("no profile %q", args[0])
			}
			// The daemon holds the state dir open; removing it underneath a
			// live node leaves a node with nowhere to write.
			if live, err := cfg.FetchStatus(); err == nil {
				for _, s := range live {
					if s.Profile == args[0] {
						return fmt.Errorf("profile %q is running; stop the daemon first (tsmux up is holding it)", args[0])
					}
				}
			}
			dir := cfg.StateDir(args[0])
			delete(cfg.Profiles, args[0])
			if err := cfg.Normalize(); err != nil {
				return err
			}
			if err := cfg.Save(cfg.Path()); err != nil {
				return err
			}
			if purge {
				if err := os.RemoveAll(dir); err != nil {
					return err
				}
			}
			emit(map[string]any{"removed": args[0], "state_dir": dir, "purged": purge}, func() {
				if purge {
					fmt.Printf("removed %s (state dir %s deleted)\n", args[0], dir)
					return
				}
				fmt.Printf("removed %s (state dir %s left in place)\n", args[0], dir)
			})
			return nil
		},
	}
	rm.Flags().BoolVar(&purge, "purge", false, "also delete the profile's saved tailnet credentials")
	c.AddCommand(rm)

	c.AddCommand(cmdProfileSet())

	c.AddCommand(&cobra.Command{
		Use: "logout <name>", Short: "Forget a profile's tailnet credentials", Args: cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			cfg, err := load()
			if err != nil {
				return err
			}
			p, ok := cfg.Profiles[args[0]]
			if !ok {
				return fmt.Errorf("no profile %q", args[0])
			}
			st, err := cfg.PostLogout(args[0])
			if err != nil {
				// No daemon to ask: clearing the state dir is the same thing,
				// minus the node that would have re-asked for a login URL.
				dir := cfg.StateDir(args[0])
				if rmErr := os.RemoveAll(dir); rmErr != nil {
					return rmErr
				}
				st = tsmux.Status{
					Profile: args[0], Display: p.DisplayName, State: "Stopped",
					HTTPProxy: fmt.Sprintf("127.0.0.1:%d", p.HTTPPort),
					SOCKS5:    fmt.Sprintf("127.0.0.1:%d", p.SOCKSPort),
				}
			}
			emit(st, func() { fmt.Printf("logged %s out; it will ask for a new login\n", args[0]) })
			return nil
		},
	})
	return c
}

func cmdProfileSet() *cobra.Command {
	var req tsmux.PrefsRequest
	var acceptRoutes, acceptDNS, shieldsUp, exitNodeLAN bool
	var exitNode string
	c := &cobra.Command{
		Use: "set <name>", Short: "Change one profile's Tailscale preferences", Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := load()
			if err != nil {
				return err
			}
			if _, ok := cfg.Profiles[args[0]]; !ok {
				return fmt.Errorf("no profile %q", args[0])
			}
			req.Profile = args[0]
			// Only flags the user actually passed are sent; the rest stay put.
			for name, set := range map[string]func(){
				"accept-routes": func() { req.AcceptRoutes = &acceptRoutes },
				"accept-dns":    func() { req.AcceptDNS = &acceptDNS },
				"shields-up":    func() { req.ShieldsUp = &shieldsUp },
				"exit-node":     func() { req.ExitNode = &exitNode },
				"exit-node-lan": func() { req.ExitNodeAllowLAN = &exitNodeLAN },
			} {
				if cmd.Flags().Changed(name) {
					set()
				}
			}
			st, err := cfg.PostPrefs(req)
			if err != nil {
				return err
			}
			emit(st, func() { fmt.Printf("%s: %s\n", st.Profile, st.State) })
			return nil
		},
	}
	c.Flags().BoolVar(&acceptRoutes, "accept-routes", false, "accept subnet routes advertised by the tailnet")
	c.Flags().BoolVar(&acceptDNS, "accept-dns", false, "use the tailnet's DNS settings")
	c.Flags().BoolVar(&shieldsUp, "shields-up", false, "block incoming connections")
	c.Flags().StringVar(&exitNode, "exit-node", "", "stable node ID of an exit node, or \"\" to clear")
	c.Flags().BoolVar(&exitNodeLAN, "exit-node-lan", false, "allow local network access while using an exit node")
	return c
}

// --- pac --------------------------------------------------------------------

func cmdPAC() *cobra.Command {
	c := &cobra.Command{Use: "pac", Short: "Browser proxy auto-config"}
	c.AddCommand(&cobra.Command{
		Use: "print", Short: "Print the PAC JavaScript",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := load()
			if err != nil {
				return err
			}
			fmt.Print(cfg.PAC())
			return nil
		},
	})
	c.AddCommand(&cobra.Command{
		Use: "url", Short: "Print the PAC URL to paste into a browser",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := load()
			if err != nil {
				return err
			}
			fmt.Println(cfg.PACURL())
			return nil
		},
	})
	c.AddCommand(&cobra.Command{
		Use: "apply", Short: "Point the system proxy at the PAC file",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := load()
			if err != nil {
				return err
			}
			if err := cfg.ApplySystemProxy(); err != nil {
				return err
			}
			fmt.Printf("system proxy -> %s\n", cfg.PACURL())
			return nil
		},
	})
	c.AddCommand(&cobra.Command{
		Use: "restore", Short: "Restore the system proxy settings tsmux changed",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := load()
			if err != nil {
				return err
			}
			return cfg.RestoreSystemProxy()
		},
	})
	c.AddCommand(&cobra.Command{
		Use: "status", Short: "Show the current system proxy settings",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := load()
			if err != nil {
				return err
			}
			st, err := cfg.SystemProxyStatus()
			if err != nil {
				return err
			}
			emit(st, func() {
				w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
				fmt.Fprintln(w, "SERVICE\tENABLED\tURL")
				for _, s := range st {
					fmt.Fprintf(w, "%s\t%t\t%s\n", s.Service, s.Enabled, s.URL)
				}
				w.Flush()
			})
			return nil
		},
	})
	return c
}

// --- env / run --------------------------------------------------------------

func proxyEnv(cfg *tsmux.Config) []string {
	http := "http://" + cfg.Router.HTTPProxy
	// socks5h keeps name resolution inside the tailnet rather than on the host.
	socks := "socks5h://" + cfg.Router.SOCKS5Proxy
	return []string{
		"HTTP_PROXY=" + http, "http_proxy=" + http,
		"HTTPS_PROXY=" + http, "https_proxy=" + http,
		"ALL_PROXY=" + socks, "all_proxy=" + socks,
		"NO_PROXY=localhost,127.0.0.1,::1", "no_proxy=localhost,127.0.0.1,::1",
	}
}

func cmdEnv() *cobra.Command {
	return &cobra.Command{
		Use: "env", Short: "Print shell exports pointing at the tsmux router",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := load()
			if err != nil {
				return err
			}
			for _, kv := range proxyEnv(cfg) {
				fmt.Printf("export %s\n", kv)
			}
			return nil
		},
	}
}

func cmdRun() *cobra.Command {
	var profile string
	c := &cobra.Command{
		Use: "run <command> [args...]", Short: "Run a command with tsmux proxy env applied",
		Args: cobra.MinimumNArgs(1), DisableFlagsInUseLine: true,
		RunE: func(_ *cobra.Command, args []string) error {
			cfg, err := load()
			if err != nil {
				return err
			}
			if profile != "" {
				p, ok := cfg.Profiles[profile]
				if !ok {
					return fmt.Errorf("no profile %q", profile)
				}
				// Pin the child to one tailnet by aiming it at that profile's ports.
				cfg.Router.HTTPProxy = fmt.Sprintf("127.0.0.1:%d", p.HTTPPort)
				cfg.Router.SOCKS5Proxy = fmt.Sprintf("127.0.0.1:%d", p.SOCKSPort)
			}
			cmd := exec.Command(args[0], args[1:]...)
			cmd.Env = append(os.Environ(), proxyEnv(cfg)...)
			cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
			if err := cmd.Run(); err != nil {
				var ee *exec.ExitError
				if errors.As(err, &ee) {
					os.Exit(ee.ExitCode())
				}
				return err
			}
			return nil
		},
	}
	c.Flags().StringVar(&profile, "profile", "", "pin the command to one profile's proxy")
	return c
}

// --- connect / tunnel / dns / ssh -------------------------------------------

// withManager starts the tailnets, runs fn, and tears everything down. Used by
// the one-shot commands so they work without a running `tsmux up`.
func withManager(ctx context.Context, fn func(context.Context, *tsmux.Manager, *tsmux.Config) error) error {
	cfg, err := load()
	if err != nil {
		return err
	}
	m := tsmux.NewManager(cfg, verbose)
	if err := m.Start(ctx); err != nil {
		return err
	}
	defer m.Close()
	return fn(ctx, m, cfg)
}

func cmdConnect() *cobra.Command {
	return &cobra.Command{
		Use: "connect <host> <port>", Short: "Pipe stdin/stdout to a tailnet host (ssh ProxyCommand)",
		Args: cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			return withManager(cmd.Context(), func(ctx context.Context, m *tsmux.Manager, _ *tsmux.Config) error {
				target := net.JoinHostPort(args[0], args[1])
				conn, err := m.Dial(ctx, "tcp", target)
				if err != nil {
					return err
				}
				defer conn.Close()
				return tsmux.PipeStdio(conn)
			})
		},
	}
}

func cmdTunnel() *cobra.Command {
	var listen, profile string
	c := &cobra.Command{
		Use: "tunnel <target-host:port>", Short: "Forward a loopback port into one tailnet",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return withManager(cmd.Context(), func(ctx context.Context, m *tsmux.Manager, cfg *tsmux.Config) error {
				dial := m.Dial
				if profile != "" {
					n, err := m.Node(profile)
					if err != nil {
						return err
					}
					dial = n.Dial
				}
				ln, err := net.Listen("tcp", listen)
				if err != nil {
					return err
				}
				defer ln.Close()
				log.Printf("tunnel %s -> %s", listen, args[0])
				go func() { <-ctx.Done(); ln.Close() }()
				err = tsmux.ServeTunnel(ln, args[0], dial)
				if ctx.Err() != nil {
					return nil
				}
				return err
			})
		},
	}
	c.Flags().StringVar(&listen, "listen", "127.0.0.1:0", "loopback listener, e.g. 127.0.0.1:13389")
	c.Flags().StringVar(&profile, "profile", "", "explicit profile (required for raw IP targets)")
	c.MarkFlagRequired("listen")
	return c
}

func cmdDNS() *cobra.Command {
	c := &cobra.Command{Use: "dns", Short: "Profile-scoped DNS"}
	c.AddCommand(&cobra.Command{
		Use: "query <host>", Short: "Resolve a name inside its owning tailnet", Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return withManager(cmd.Context(), func(ctx context.Context, m *tsmux.Manager, _ *tsmux.Config) error {
				n, match, err := m.Pick(args[0])
				if err != nil {
					return err
				}
				ips, err := n.Resolve(ctx, tsmux.SplitHost(args[0]))
				if err != nil {
					return err
				}
				addrs := make([]string, len(ips))
				for i, ip := range ips {
					addrs[i] = ip.String()
				}
				emit(map[string]any{"host": args[0], "profile": match.Profile.Name, "addrs": addrs}, func() {
					fmt.Printf("%s [%s] -> %s\n", args[0], match.Profile.Name, strings.Join(addrs, " "))
				})
				return nil
			})
		},
	})
	return c
}

func cmdSSH() *cobra.Command {
	c := &cobra.Command{
		Use: "ssh <[user@]host> [ssh args...]", Short: "SSH to a tailnet host through the owning profile",
		Args: cobra.MinimumNArgs(1), DisableFlagsInUseLine: true,
		RunE: func(_ *cobra.Command, args []string) error {
			self, err := os.Executable()
			if err != nil {
				return err
			}
			pc := fmt.Sprintf("%s connect %%h %%p", self)
			if cfgPath != "" {
				pc = fmt.Sprintf("%s --config %s connect %%h %%p", self, cfgPath)
			}
			sshArgs := append([]string{"-o", "ProxyCommand=" + pc}, args...)
			cmd := exec.Command("ssh", sshArgs...)
			cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
			if err := cmd.Run(); err != nil {
				var ee *exec.ExitError
				if errors.As(err, &ee) {
					os.Exit(ee.ExitCode())
				}
				return err
			}
			return nil
		},
	}
	return c
}

// --- doctor / version -------------------------------------------------------

func cmdDoctor() *cobra.Command {
	return &cobra.Command{
		Use: "doctor", Short: "Check config, ports, and routing overlaps",
		RunE: func(_ *cobra.Command, _ []string) error {
			cfg, err := load()
			if err != nil {
				return err
			}
			var problems []string
			claim := map[string]string{}
			for _, p := range cfg.Ordered() {
				for _, s := range p.Suffixes {
					if prev, ok := claim[s]; ok {
						problems = append(problems, fmt.Sprintf("suffix %s claimed by both %s and %s", s, prev, p.Name))
					}
					claim[s] = p.Name
				}
			}
			roots := 0
			for _, p := range cfg.Ordered() {
				if p.MatchRoot {
					roots++
				}
			}
			if roots > 1 {
				problems = append(problems, fmt.Sprintf("%d profiles set match_root; bare hostnames will be ambiguous", roots))
			}
			for _, addr := range append([]string{cfg.Router.HTTPProxy, cfg.Router.SOCKS5Proxy, cfg.Router.PACListen}, portsOf(cfg)...) {
				if ln, err := net.Listen("tcp", addr); err != nil {
					problems = append(problems, fmt.Sprintf("port %s is already in use", addr))
				} else {
					ln.Close()
				}
			}
			if len(cfg.Ordered()) == 0 {
				problems = append(problems, "no profiles configured")
			}
			if live, err := cfg.FetchStatus(); err == nil {
				for _, s := range live {
					if s.SuffixConflict != "" {
						problems = append(problems, fmt.Sprintf("%s learned suffix %s but %s already claims it; %s is reachable only on %s",
							s.Profile, s.MagicDNSSuffix, s.SuffixConflict, s.Profile, s.HTTPProxy))
					}
				}
			}
			emit(map[string]any{"config": cfg.Path(), "problems": problems}, func() {
				fmt.Printf("config: %s\nprofiles: %d\n", cfg.Path(), len(cfg.Ordered()))
				if len(problems) == 0 {
					fmt.Println("no problems found")
					return
				}
				for _, p := range problems {
					fmt.Println("problem: " + p)
				}
			})
			if len(problems) > 0 {
				os.Exit(1)
			}
			return nil
		},
	}
}

func portsOf(cfg *tsmux.Config) []string {
	var out []string
	for _, p := range cfg.Ordered() {
		out = append(out, fmt.Sprintf("127.0.0.1:%d", p.HTTPPort), fmt.Sprintf("127.0.0.1:%d", p.SOCKSPort))
	}
	return out
}

func cmdVersion() *cobra.Command {
	return &cobra.Command{
		Use: "version", Short: "Print version information",
		Run: func(_ *cobra.Command, _ []string) {
			emit(map[string]string{"version": version}, func() { fmt.Println(version) })
		},
	}
}
