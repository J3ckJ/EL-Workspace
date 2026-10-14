package web

import "embed"

// Files is the browser UI copied into the binary.
//
//go:embed all:static
var Files embed.FS
