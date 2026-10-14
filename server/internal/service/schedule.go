package service

import "time"

// DueBackup reports whether a nightly bundle is due.
func DueBackup(now time.Time, at string, last time.Time) bool {
	hour, min := 3, 0
	if t, err := time.Parse("15:04", at); err == nil {
		hour, min = t.Hour(), t.Minute()
	}
	scheduled := time.Date(now.Year(), now.Month(), now.Day(), hour, min, 0, 0, now.Location())
	if now.Before(scheduled) {
		return false
	}
	if last.IsZero() {
		return true
	}
	return last.Before(scheduled)
}
