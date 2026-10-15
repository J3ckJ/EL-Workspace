// Package names validates owner and repository identifiers used in paths,
// SSH commands and clone URLs.
package names

import (
	"regexp"
	"strings"
)

var nameRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

// Valid reports whether s is safe to use as a single path segment.
func Valid(s string) bool {
	if !nameRe.MatchString(s) {
		return false
	}
	if strings.HasSuffix(strings.ToLower(s), ".git") {
		return false
	}
	switch strings.ToLower(s) {
	case ".", "..", "git", "api", "assets", "info":
		return false
	default:
		return true
	}
}
