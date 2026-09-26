//go:build windows

package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf16"

	"merepoule/gateway/internal/readiness"
)

// install copie la passerelle dans son dossier de données et crée la tâche
// planifiée qui la lance à l'ouverture de session, sous le compte courant
// (celui de MT5), sans fenêtre. La tâche se redéclenche chaque minute : si la
// passerelle s'est arrêtée, elle repart ; sinon rien ne se passe.
func install(args []string) {
	var o options
	fs := flag.NewFlagSet("install", flag.ExitOnError)
	o.register(fs)
	listen := fs.String("listen", "127.0.0.1:8787", "adresse d'écoute")
	chats := fs.String("telegram-chats", "", "chats Telegram autorisés (voir serve)")
	deadmanURL := fs.String("deadman-url", "", "adresse de signal de vie (Healthchecks.io), rangée dans deadman.url")
	preAlert := fs.Float64("prealert", 300, "pré-alerte (voir serve)")
	fs.Parse(args)

	if err := os.MkdirAll(o.data, 0o700); err != nil {
		log.Fatal(err)
	}
	stopInstalled() // libère l'exécutable s'il tourne déjà

	exe, err := os.Executable()
	if err != nil {
		log.Fatal(err)
	}
	target := filepath.Join(o.data, "merepoule-gateway.exe")
	if !strings.EqualFold(filepath.Clean(exe), filepath.Clean(target)) {
		// Windows libère le fichier un instant après la fin du processus.
		for i := 0; ; i++ {
			if err = copyFile(exe, target); err == nil || i == 20 {
				break
			}
			time.Sleep(250 * time.Millisecond)
		}
		if err != nil {
			log.Fatalf("copie de la passerelle : %v", err)
		}
	}
	if t := strings.TrimSpace(os.Getenv("MEREPOULE_TELEGRAM_TOKEN")); t != "" {
		if err := os.WriteFile(filepath.Join(o.data, "telegram.token"), []byte(t+"\n"), 0o600); err != nil {
			log.Fatal(err)
		}
	}
	if *deadmanURL != "" {
		if err := os.WriteFile(filepath.Join(o.data, "deadman.url"), []byte(strings.TrimSpace(*deadmanURL)+"\n"), 0o600); err != nil {
			log.Fatal(err)
		}
	}
	if *chats != "" && telegramToken(o.data) == "" {
		log.Fatal("-telegram-chats sans jeton : définir MEREPOULE_TELEGRAM_TOKEN pour l'installation")
	}

	logFile := filepath.Join(o.data, "gateway.log")
	cmdArgs := []string{"--headless", quote(target), "serve", "-common", quote(o.common), "-data", quote(o.data),
		"-listen", *listen, "-log", quote(logFile)}
	if *chats != "" {
		cmdArgs = append(cmdArgs, "-telegram-chats", quote(*chats))
	}
	cmdArgs = append(cmdArgs, "-prealert", strconv.FormatFloat(*preAlert, 'f', -1, 64))
	u, err := user.Current()
	if err != nil {
		log.Fatal(err)
	}
	conhost := filepath.Join(os.Getenv("SystemRoot"), "System32", "conhost.exe")
	xmlFile := filepath.Join(o.data, "task.xml")
	if err := writeUTF16(xmlFile, taskXML(u.Username, conhost, strings.Join(cmdArgs, " "), o.data)); err != nil {
		log.Fatal(err)
	}
	if out, err := schtasks("/Create", "/TN", readiness.TaskName, "/XML", xmlFile, "/F"); err != nil {
		log.Fatalf("création de la tâche planifiée : %v\n%s", err, out)
	}
	if out, err := schtasks("/Run", "/TN", readiness.TaskName); err != nil {
		log.Fatalf("lancement de la tâche : %v\n%s", err, out)
	}
	fmt.Printf("Passerelle installée pour %s\n  programme : %s\n  journal   : %s\n  tâche     : « %s », à l'ouverture de session, relancée chaque minute si elle s'arrête\n",
		u.Username, target, logFile, readiness.TaskName)
	if *chats != "" {
		fmt.Printf("  Telegram  : chats %s, jeton dans %s\n", *chats, filepath.Join(o.data, "telegram.token"))
	}
}

// stopInstalled arrête la passerelle lancée par la tâche. Mettre fin à la
// tâche ne ferme que conhost : la passerelle, lancée par lui, est arrêtée à
// part, en épargnant le processus courant (qui porte souvent le même nom).
func stopInstalled() {
	schtasks("/Change", "/TN", readiness.TaskName, "/DISABLE") // pas de relance pendant l'installation
	schtasks("/End", "/TN", readiness.TaskName)
	cmd := exec.Command("taskkill", "/F", "/FI", "IMAGENAME eq merepoule-gateway.exe", "/FI", fmt.Sprintf("PID ne %d", os.Getpid()))
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	cmd.Run()
}

func uninstall() {
	stopInstalled()
	if out, err := schtasks("/Delete", "/TN", readiness.TaskName, "/F"); err != nil {
		log.Fatalf("suppression de la tâche : %v\n%s", err, out)
	}
	fmt.Printf("Tâche « %s » supprimée : la passerelle ne se lance plus à l'ouverture de session.\n", readiness.TaskName)
}

func schtasks(args ...string) (string, error) {
	cmd := exec.Command("schtasks", args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func quote(s string) string { return `"` + s + `"` }

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// writeUTF16 : schtasks attend un XML en UTF-16 avec BOM.
func writeUTF16(path, s string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	units := append([]uint16{0xFEFF}, utf16.Encode([]rune(s))...)
	return binary.Write(f, binary.LittleEndian, units)
}

var xmlEscape = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;", "'", "&apos;")

// taskXML : déclencheur à l'ouverture de session répété chaque minute,
// une seule instance, sans limite de durée, même sur batterie.
func taskXML(userID, command, arguments, workDir string) string {
	return `<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>MerePoule : passerelle API et bot Telegram. Relancée chaque minute si elle s'arrête.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>` + xmlEscape.Replace(userID) + `</UserId>
      <Repetition>
        <Interval>PT1M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>` + xmlEscape.Replace(userID) + `</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>5</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>` + xmlEscape.Replace(command) + `</Command>
      <Arguments>` + xmlEscape.Replace(arguments) + `</Arguments>
      <WorkingDirectory>` + xmlEscape.Replace(workDir) + `</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
`
}
