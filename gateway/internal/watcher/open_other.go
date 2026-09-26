//go:build !windows

package watcher

import "os"

// openShared : hors Windows, ouvrir un fichier n'empêche pas de le remplacer.
func openShared(path string) (*os.File, error) { return os.Open(path) }
