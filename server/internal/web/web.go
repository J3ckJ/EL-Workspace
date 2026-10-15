// Package web serves the embedded interface.
package web

import (
	"io/fs"
	"net/http"
)

// Handler returns the static UI. Files live in server/web and are embedded
// from this directory's parent via the go:embed directive in embed.go.
func Handler() http.Handler {
	sub, err := fs.Sub(Files, "static")
	if err != nil {
		panic(err)
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache")
		http.FileServer(http.FS(sub)).ServeHTTP(w, r)
	})
}
