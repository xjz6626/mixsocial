package main

import (
	"context"
	"flag"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/xjz6626/mixsocial/internal/sidecar"
	"github.com/xjz6626/mixsocial/internal/source"
	"github.com/xjz6626/mixsocial/internal/source/demo"
	"github.com/xjz6626/mixsocial/internal/source/tieba"
	"github.com/xjz6626/mixsocial/internal/source/xhs"
	"github.com/xjz6626/mixsocial/internal/tui"
)

func main() {
	var (
		demoMode     = flag.Bool("demo", false, "use offline demo data only")
		useTieba     = flag.Bool("tieba", true, "enable Baidu Tieba")
		useXHS       = flag.Bool("xhs", true, "enable Xiaohongshu")
		forums       = flag.String("tieba-forums", envOr("MIXSOCIAL_TIEBA_FORUMS", ""), "comma-separated Tieba home forums")
		tiebaSession = flag.String("tieba-session", os.Getenv("MIXSOCIAL_TIEBA_SESSION"), "Tieba session file (user config directory by default)")
		browserPath  = flag.String("browser", os.Getenv("MIXSOCIAL_BROWSER"), "Chromium path for embedded login (auto-detected by default)")
		xhsURL       = flag.String("xhs-endpoint", envOr("MIXSOCIAL_XHS_ENDPOINT", "http://127.0.0.1:18060"), "xiaohongshu-mcp HTTP endpoint")
		xhsToken     = flag.String("xhs-token", os.Getenv("MIXSOCIAL_XHS_TOKEN"), "optional sidecar bearer token")
		xhsManaged   = flag.Bool("xhs-managed", true, "automatically start and stop the Xiaohongshu sidecar")
		xhsBinary    = flag.String("xhs-sidecar", os.Getenv("MIXSOCIAL_XHS_SIDECAR"), "path to xiaohongshu-mcp (auto-detected by default)")
		xhsStartup   = flag.Duration("xhs-startup-timeout", 15*time.Minute, "maximum time for first sidecar/browser startup")
		timeout      = flag.Duration("timeout", 45*time.Second, "request timeout")
	)
	flag.Parse()

	var readers []source.Reader
	var managedSidecar *sidecar.Manager
	if *demoMode {
		readers = append(readers, demo.New())
	} else {
		client := &http.Client{Timeout: *timeout}
		if *useTieba {
			sessionPath := strings.TrimSpace(*tiebaSession)
			if sessionPath == "" {
				var pathErr error
				sessionPath, pathErr = statePath("tieba-session.json")
				if pathErr != nil {
					fmt.Fprintf(os.Stderr, "mixsocial: resolve Tieba session path: %v (login will not persist)\n", pathErr)
				}
			}
			readers = append(readers, tieba.New(tieba.Config{
				Client: client, Forums: splitComma(*forums), SessionPath: sessionPath, BrowserPath: *browserPath,
			}))
		}
		if *useXHS {
			if *xhsManaged {
				sessionPath, logPath, managerErr := xhsPaths()
				if managerErr != nil {
					fmt.Fprintf(os.Stderr, "mixsocial: resolve Xiaohongshu session path: %v\n", managerErr)
				} else {
					managedSidecar, managerErr = sidecar.New(sidecar.Config{
						Endpoint: *xhsURL, Binary: *xhsBinary, Token: *xhsToken,
						SessionPath: sessionPath, LogPath: logPath,
					})
					if managerErr != nil {
						fmt.Fprintf(os.Stderr, "mixsocial: configure Xiaohongshu sidecar: %v\n", managerErr)
						managedSidecar = nil
					} else {
						fmt.Fprintf(os.Stderr, "mixsocial: preparing Xiaohongshu sidecar (first run may download a browser; log: %s)\n", logPath)
						startupContext, cancel := context.WithTimeout(context.Background(), *xhsStartup)
						managerErr = managedSidecar.Ensure(startupContext)
						cancel()
						if managerErr != nil {
							fmt.Fprintf(os.Stderr, "mixsocial: %v\n", managerErr)
						} else if managedSidecar.Owned() {
							fmt.Fprintln(os.Stderr, "mixsocial: Xiaohongshu sidecar is ready and managed by this process")
						} else {
							fmt.Fprintln(os.Stderr, "mixsocial: using the Xiaohongshu sidecar already running at "+*xhsURL)
						}
					}
				}
			}
			xhsSessionPath, _, pathErr := xhsPaths()
			if pathErr != nil {
				xhsSessionPath = ""
			}
			readers = append(readers, xhs.New(xhs.Config{
				Client: client, Endpoint: *xhsURL, Token: *xhsToken, SessionPath: xhsSessionPath, GuardSession: *xhsManaged,
			}))
		}
	}
	if len(readers) == 0 {
		fmt.Fprintln(os.Stderr, "mixsocial: no sources enabled")
		os.Exit(2)
	}
	if managedSidecar != nil {
		defer managedSidecar.Close()
	}

	mixed := source.NewMixed(readers...)
	defer mixed.Close()
	model := tui.New(mixed, *timeout)
	program := tea.NewProgram(model, tea.WithAltScreen(), tea.WithMouseCellMotion())
	if _, err := program.Run(); err != nil {
		if managedSidecar != nil {
			_ = managedSidecar.Close()
		}
		fmt.Fprintf(os.Stderr, "mixsocial: %v\n", err)
		os.Exit(1)
	}
}

func xhsPaths() (sessionPath, logPath string, err error) {
	sessionPath, err = statePath("xhs-session.json")
	if err != nil {
		return "", "", err
	}
	defaultLogPath, err := statePath("xhs-sidecar.log")
	if err != nil {
		return "", "", err
	}
	sessionPath = envOr("MIXSOCIAL_XHS_SESSION", sessionPath)
	logPath = envOr("MIXSOCIAL_XHS_LOG", defaultLogPath)
	return sessionPath, logPath, nil
}

func statePath(name string) (string, error) {
	configDir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(configDir, "mixsocial", name), nil
}

func splitComma(value string) []string {
	var result []string
	for _, part := range strings.Split(value, ",") {
		if part = strings.TrimSpace(part); part != "" {
			result = append(result, part)
		}
	}
	return result
}

func envOr(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}
