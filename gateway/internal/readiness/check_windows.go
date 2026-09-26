//go:build windows

package readiness

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// Run passe en revue ce qui empêche une machine de tenir 24 h : veille,
// alimentation, Windows Update, connexion automatique, lancement de MT5 et
// de la passerelle à l'ouverture de session.
func Run() Report {
	return newReport([]Check{
		checkSleep("sleep", "Mise en veille", "en veille", "STANDBYIDLE", "standby-timeout"),
		checkSleep("hibernate", "Veille prolongée", "en veille prolongée", "HIBERNATEIDLE", "hibernate-timeout"),
		checkPower(),
		checkWindowsUpdate(),
		checkAutoLogon(),
		checkMT5Startup(),
		checkGatewayStartup(),
	})
}

var hexValue = regexp.MustCompile(`0x[0-9a-fA-F]+`)

// powercfgSeconds lit les délais secteur et batterie d'un réglage de veille,
// en secondes. Les deux dernières valeurs de la sortie sont les réglages
// actuels (secteur puis batterie), quelle que soit la langue de Windows.
func powercfgSeconds(setting string) (ac, dc int64, err error) {
	cmd := exec.Command("powercfg", "/query", "SCHEME_CURRENT", "SUB_SLEEP", setting)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	out, err := cmd.Output()
	if err != nil {
		return 0, 0, err
	}
	vals := hexValue.FindAllString(string(out), -1)
	if len(vals) < 2 {
		return 0, 0, fmt.Errorf("sortie de powercfg illisible")
	}
	ac, _ = strconv.ParseInt(vals[len(vals)-2][2:], 16, 64)
	dc, _ = strconv.ParseInt(vals[len(vals)-1][2:], 16, 64)
	return ac, dc, nil
}

// checkSleep : noun dit l'état en clair, « en veille » ou « en veille prolongée ».
func checkSleep(id, label, noun, setting, alias string) Check {
	c := Check{ID: id, Label: label}
	ac, dc, err := powercfgSeconds(setting)
	switch {
	case err != nil:
		c.Level, c.Detail, c.Tech = Warning, "MerePoule n'a pas pu lire ce réglage de l'ordinateur.", err.Error()
	case ac != 0:
		c.Level = Error
		c.Detail = fmt.Sprintf("L'ordinateur se met %s au bout de %d min, même branché. "+
			"Pendant ce temps, MT5 et la Mère dorment aussi : plus aucune surveillance.", noun, ac/60)
		c.Fix = "Paramètres › Système › Alimentation : choisir « Jamais » quand l'ordinateur est branché."
		c.Tech = fmt.Sprintf("powercfg /change %s-ac 0", alias)
	case dc != 0:
		c.Level = Warning
		c.Detail = fmt.Sprintf("Branché, l'ordinateur ne se met jamais %s : très bien. "+
			"Mais sur batterie, il s'y met au bout de %d min, et la Mère s'endort avec lui.", noun, dc/60)
		c.Fix = "Laisser l'ordinateur branché en permanence."
		c.Tech = fmt.Sprintf("powercfg /change %s-dc 0", alias)
	default:
		c.Level, c.Detail = OK, "L'ordinateur ne se met jamais "+noun+"."
	}
	return c
}

type systemPowerStatus struct {
	ACLineStatus        byte
	BatteryFlag         byte
	BatteryLifePercent  byte
	SystemStatusFlag    byte
	BatteryLifeTime     uint32
	BatteryFullLifeTime uint32
}

var procGetSystemPowerStatus = windows.NewLazySystemDLL("kernel32.dll").NewProc("GetSystemPowerStatus")

func checkPower() Check {
	c := Check{ID: "power", Label: "Branchement"}
	var s systemPowerStatus
	if r, _, err := procGetSystemPowerStatus.Call(uintptr(unsafe.Pointer(&s))); r == 0 {
		c.Level, c.Detail, c.Tech = Warning, "MerePoule n'a pas pu savoir si l'ordinateur est branché.", err.Error()
		return c
	}
	switch s.ACLineStatus {
	case 1:
		c.Level, c.Detail = OK, "L'ordinateur est branché sur le secteur."
	case 0:
		c.Level = Warning
		c.Detail = fmt.Sprintf("L'ordinateur tourne sur sa batterie (%d %%). Quand elle sera vide, il s'éteindra, et la Mère avec lui.",
			s.BatteryLifePercent)
		c.Fix = "Le brancher. À la maison, un onduleur (batterie de secours) le garde allumé pendant une coupure de courant."
	default:
		c.Level, c.Detail = OK, "Ordinateur sans batterie, alimenté par le secteur."
	}
	return c
}

func regString(root registry.Key, path, name string) (string, bool) {
	k, err := registry.OpenKey(root, path, registry.QUERY_VALUE)
	if err != nil {
		return "", false
	}
	defer k.Close()
	if s, _, err := k.GetStringValue(name); err == nil {
		return s, true
	}
	if n, _, err := k.GetIntegerValue(name); err == nil {
		return strconv.FormatUint(n, 10), true
	}
	return "", false
}

func regKeyExists(root registry.Key, path string) bool {
	k, err := registry.OpenKey(root, path, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	k.Close()
	return true
}

func checkWindowsUpdate() Check {
	c := Check{ID: "windows_update", Label: "Mises à jour de Windows"}
	if regKeyExists(registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired`) {
		c.Level = Warning
		c.Detail = "Une mise à jour attend un redémarrage. Windows risque de le faire tout seul, au mauvais moment."
		c.Fix = "Redémarrer soi-même à un moment calme, de préférence sans position ouverte."
		return c
	}
	if v, _ := regString(registry.LOCAL_MACHINE, `SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU`, "NoAutoRebootWithLoggedOnUsers"); v == "1" {
		c.Level, c.Detail = OK, "Windows ne redémarre jamais tout seul quand la session est ouverte."
		return c
	}
	start, ok1 := regString(registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\WindowsUpdate\UX\Settings`, "ActiveHoursStart")
	end, ok2 := regString(registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\WindowsUpdate\UX\Settings`, "ActiveHoursEnd")
	c.Level = Warning
	when := "la nuit"
	if ok1 && ok2 {
		when = fmt.Sprintf("en dehors de %sh-%sh", start, end)
	}
	c.Detail = "Windows peut redémarrer tout seul pour une mise à jour, " + when +
		". Pendant le redémarrage, MT5 et la Mère sont éteints : plus de surveillance."
	c.Fix = "Paramètres › Windows Update › Options avancées › Heures d'activité : choisir la plage la plus large. " +
		"Puis faire les redémarrages soi-même, à un moment calme."
	c.Tech = "gpedit.msc : « Pas de redémarrage automatique avec des utilisateurs connectés » activé"
	return c
}

func checkAutoLogon() Check {
	c := Check{ID: "autologon", Label: "Redémarrage sans mot de passe"}
	if v, _ := regString(registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`, "AutoAdminLogon"); v == "1" {
		user, _ := regString(registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`, "DefaultUserName")
		c.Level, c.Detail = OK, "Après un redémarrage, la session "+user+" s'ouvre toute seule."
		return c
	}
	c.Level = Error
	c.Detail = "Après une coupure de courant ou une mise à jour, l'ordinateur redémarre puis attend le mot de passe. " +
		"MT5 et la Mère restent éteints tant que personne ne le tape."
	c.Fix = "Installer l'outil gratuit Autologon de Microsoft, puis y entrer le mot de passe du compte Windows qui fait tourner MT5 : " +
		"https://learn.microsoft.com/sysinternals/downloads/autologon"
	c.Tech = `Autologon64.exe, ou HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon : AutoAdminLogon = 1`
	return c
}

// containsTerminal cherche terminal64.exe en ASCII ou en UTF-16 (raccourcis .lnk).
func containsTerminal(b []byte) bool {
	for _, name := range []string{"terminal64.exe", "Terminal64.exe", "TERMINAL64.EXE"} {
		if bytes.Contains(b, []byte(name)) {
			return true
		}
		wide := make([]byte, 0, 2*len(name))
		for i := 0; i < len(name); i++ {
			wide = append(wide, name[i], 0)
		}
		if bytes.Contains(b, wide) {
			return true
		}
	}
	return false
}

func checkMT5Startup() Check {
	c := Check{ID: "mt5_startup", Label: "MT5 au démarrage"}
	dirs := []string{
		filepath.Join(os.Getenv("APPDATA"), `Microsoft\Windows\Start Menu\Programs\Startup`),
		filepath.Join(os.Getenv("PROGRAMDATA"), `Microsoft\Windows\Start Menu\Programs\StartUp`),
	}
	for _, dir := range dirs {
		entries, _ := os.ReadDir(dir)
		for _, e := range entries {
			if b, err := os.ReadFile(filepath.Join(dir, e.Name())); err == nil && containsTerminal(b) {
				c.Level, c.Detail = OK, "MT5 se lance tout seul à l'ouverture de la session ("+e.Name()+")."
				return c
			}
		}
	}
	for _, root := range []registry.Key{registry.CURRENT_USER, registry.LOCAL_MACHINE} {
		k, err := registry.OpenKey(root, `Software\Microsoft\Windows\CurrentVersion\Run`, registry.QUERY_VALUE)
		if err != nil {
			continue
		}
		names, _ := k.ReadValueNames(-1)
		for _, n := range names {
			if v, _, err := k.GetStringValue(n); err == nil && strings.Contains(strings.ToLower(v), "terminal64.exe") {
				k.Close()
				c.Level, c.Detail = OK, "MT5 se lance tout seul à l'ouverture de la session ("+n+")."
				return c
			}
		}
		k.Close()
	}
	c.Level = Error
	c.Detail = "Après un redémarrage, MT5 ne se relance pas tout seul : le robot et la Mère restent éteints."
	c.Fix = "Appuyer sur les touches Windows + R, taper shell:startup puis Entrée, et copier le raccourci de MT5 dans le dossier qui s'ouvre."
	return c
}

func checkGatewayStartup() Check {
	c := Check{ID: "gateway_startup", Label: "MerePoule au démarrage"}
	cmd := exec.Command("schtasks", "/Query", "/TN", TaskName)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if err := cmd.Run(); err == nil {
		c.Level, c.Detail = OK, "MerePoule se relance tout seul à l'ouverture de la session."
		return c
	}
	c.Level = Error
	c.Detail = "Après un redémarrage, MerePoule ne se relance pas : plus de commandes Telegram (/kill, /relancer…) ni d'app."
	c.Fix = "Réinstaller MerePoule sur cet ordinateur."
	c.Tech = "merepoule-gateway install -telegram-chats <chat>"
	return c
}
