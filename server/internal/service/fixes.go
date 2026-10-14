package service

import (
	"regexp"
	"strconv"
	"strings"
)

var (
	adjacentFix = regexp.MustCompile(`(?i)(?:fix(?:e[sd])?|close[sd]?|resolve[sd]?)\s+#(\d+)`)
	subjectFix  = regexp.MustCompile(`(?i)^(?:fix(?:e[sd])?|close[sd]?|resolve[sd]?)\b`)
	anyNumber   = regexp.MustCompile(`#(\d+)`)
)

// IssueNumbersClosedBy returns issue numbers a commit message or pull request
// body would close. "fixes #12" and "fix: сокеты #12" both match.
func IssueNumbersClosedBy(text string) []int {
	seen := map[int]bool{}
	var out []int
	add := func(raw string) {
		n, err := strconv.Atoi(raw)
		if err != nil || n <= 0 || seen[n] {
			return
		}
		seen[n] = true
		out = append(out, n)
	}
	for _, m := range adjacentFix.FindAllStringSubmatch(text, -1) {
		add(m[1])
	}
	for _, block := range strings.Split(text, "\n") {
		line := strings.TrimSpace(block)
		if subjectFix.MatchString(line) {
			for _, m := range anyNumber.FindAllStringSubmatch(line, -1) {
				add(m[1])
			}
		}
	}
	return out
}

// ValidIssueStatus reports whether a kanban column id is known.
func ValidIssueStatus(status string) bool {
	switch status {
	case "backlog", "progress", "review", "done":
		return true
	default:
		return false
	}
}

// ValidMirrorMode reports whether a mirror mode is known.
func ValidMirrorMode(mode string) bool {
	switch mode {
	case "local", "push", "both":
		return true
	default:
		return false
	}
}
