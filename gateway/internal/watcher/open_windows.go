//go:build windows

package watcher

import (
	"os"

	"golang.org/x/sys/windows"
)

// openShared ouvre en lecture sans empêcher le Watchdog de remplacer ou de
// renommer le fichier. os.Open ne partage pas la suppression sous Windows :
// le renommage atomique du statut échouait alors côté MT5 (err 5004), comme
// la rotation du journal.
func openShared(path string) (*os.File, error) {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	h, err := windows.CreateFile(p, windows.GENERIC_READ,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil, windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	return os.NewFile(uintptr(h), path), nil
}
