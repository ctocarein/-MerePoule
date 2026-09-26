package flags

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// Le Watchdog lit un drapeau pendant quelques millisecondes ; Windows refuse
// alors de le remplacer. On réessaie pendant une demi-seconde.
const (
	renameTries = 20
	renameDelay = 25 * time.Millisecond
)

// Write dépose v, en JSON sur une ligne, sous le nom name dans dir. Le
// fichier temporaire porte un suffixe propre à la passerelle, pour ne pas
// croiser celui du script MerePouleCommand.
func Write(dir, name string, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	b = append(b, '\n')

	final := filepath.Join(dir, name)
	tmp := final + ".gw.tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	for i := 0; i < renameTries; i++ {
		if err = os.Rename(tmp, final); err == nil {
			return nil
		}
		time.Sleep(renameDelay)
	}
	os.Remove(tmp)
	return err
}

// Pending dit si un drapeau attend encore le Watchdog.
func Pending(dir, name string) bool {
	_, err := os.Stat(filepath.Join(dir, name))
	return err == nil
}
