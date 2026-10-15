// Package config holds runtime paths and the fixed author identity used for
// every commit EL Workspace creates.
package config

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

const (
	AuthorName  = "Evgenii Lyubkin"
	AuthorEmail = "80674830+J3ckJ@users.noreply.github.com"
)

// Options is the process configuration for `el serve`.
type Options struct {
	DataDir       string
	HTTPAddr      string
	SSHAddr       string
	AdvertiseHost string
	Demo          bool
	Open          bool
	MirrorEvery   int // seconds, 0 = default
}

// DefaultDataDir is the per-user directory for repositories, keys and SQLite.
func DefaultDataDir() (string, error) {
	if v := os.Getenv("EL_DATA"); v != "" {
		return v, nil
	}
	if runtime.GOOS == "windows" {
		base := os.Getenv("LOCALAPPDATA")
		if base == "" {
			home, err := os.UserHomeDir()
			if err != nil {
				return "", err
			}
			base = filepath.Join(home, "AppData", "Local")
		}
		return filepath.Join(base, "EL-System-Tools", "Git"), nil
	}
	if xdg := os.Getenv("XDG_DATA_HOME"); xdg != "" {
		return filepath.Join(xdg, "el-workspace"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".local", "share", "el-workspace"), nil
}

// Prepare creates the data directory and a private gitconfig so server-side
// commits never pick up a user template, hook path or commit trailer.
func Prepare(dataDir string) error {
	for _, sub := range []string{"repos", "backups", "assets", "ci", "ssh", "mirrors"} {
		if err := os.MkdirAll(filepath.Join(dataDir, sub), 0o755); err != nil {
			return err
		}
	}
	cfg := filepath.Join(dataDir, "gitconfig")
	content := fmt.Sprintf(`[user]
	name = %s
	email = %s
[init]
	defaultBranch = main
[commit]
	gpgsign = false
[tag]
	gpgsign = false
[safe]
	directory = *
[advice]
	detachedHead = false
[receive]
	denyCurrentBranch = ignore
`, AuthorName, AuthorEmail)
	return os.WriteFile(cfg, []byte(content), 0o644)
}

// GitEnv is the environment for every git subprocess the server starts.
func GitEnv(dataDir string) []string {
	return []string{
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + dataDir,
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_CONFIG_GLOBAL=" + filepath.Join(dataDir, "gitconfig"),
		"GIT_AUTHOR_NAME=" + AuthorName,
		"GIT_AUTHOR_EMAIL=" + AuthorEmail,
		"GIT_COMMITTER_NAME=" + AuthorName,
		"GIT_COMMITTER_EMAIL=" + AuthorEmail,
		"GIT_TERMINAL_PROMPT=0",
	}
}
