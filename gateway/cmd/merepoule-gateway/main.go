// Command merepoule-gateway est la passerelle API de MerePoule.
//
//	merepoule-gateway serve               sert l'API (défaut)
//	merepoule-gateway enroll -name "..."  code d'enrôlement à usage unique pour un téléphone
//	merepoule-gateway diag                chaque Watchdog est-il vivant ?
//	merepoule-gateway ready               diagnostic « Prêt pour le 24 h » de la machine
//	merepoule-gateway install             lancement à l'ouverture de session (tâche planifiée)
//	merepoule-gateway uninstall           retire ce lancement
//
// À lancer sous le compte Windows qui fait tourner MT5 : le dossier commun
// de MT5 dépend de %APPDATA%.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"merepoule/gateway/internal/auth"
	"merepoule/gateway/internal/call"
	"merepoule/gateway/internal/contract"
	"merepoule/gateway/internal/deadman"
	"merepoule/gateway/internal/history"
	"merepoule/gateway/internal/httpapi"
	"merepoule/gateway/internal/notify"
	"merepoule/gateway/internal/readiness"
	"merepoule/gateway/internal/requests"
	"merepoule/gateway/internal/store"
	"merepoule/gateway/internal/telegram"
	"merepoule/gateway/internal/watcher"
)

type options struct {
	common string
	data   string
}

func (o *options) register(fs *flag.FlagSet) {
	fs.StringVar(&o.common, "common", contract.CommonFilesDir(), "dossier commun de MT5")
	fs.StringVar(&o.data, "data", filepath.Join(os.Getenv("LOCALAPPDATA"), "MerePoule", "gateway"), "dossier de la base SQLite")
}

func (o *options) openStore() *store.Store {
	if err := os.MkdirAll(o.data, 0o700); err != nil {
		log.Fatal(err)
	}
	st, err := store.Open(filepath.Join(o.data, "merepoule.db"))
	if err != nil {
		log.Fatal(err)
	}
	return st
}

func main() {
	cmd := "serve"
	args := os.Args[1:]
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd, args = args[0], args[1:]
	}
	switch cmd {
	case "serve":
		serve(args)
	case "enroll":
		enroll(args)
	case "diag":
		os.Exit(diag(args))
	case "ready":
		os.Exit(ready())
	case "install":
		install(args)
	case "uninstall":
		uninstall()
	default:
		fmt.Fprintf(os.Stderr, "commande inconnue %q : serve, enroll, diag, ready, install ou uninstall\n", cmd)
		os.Exit(2)
	}
}

func serve(args []string) {
	var o options
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	o.register(fs)
	listen := fs.String("listen", "127.0.0.1:8787", "adresse d'écoute ; locale seulement tant que tsnet n'est pas branché")
	chats := fs.String("telegram-chats", "", "chats Telegram autorisés : 7805445021 ou 7805445021:43204264+123456, séparés par des virgules ; jeton dans MEREPOULE_TELEGRAM_TOKEN ou <data>\\telegram.token")
	logFile := fs.String("log", "", "journal dans ce fichier plutôt que sur la console (lancement sans fenêtre)")
	deadmanURL := fs.String("deadman-url", "", "adresse de signal de vie (Healthchecks.io) ; défaut : <data>\\deadman.url")
	preAlert := fs.Float64("prealert", 300, "pré-alerte : perte en cours qui déclenche l'alerte Telegram puis l'appel ; 0 = coupée")
	fs.Parse(args)
	setupLog(*logFile)

	if host, _, err := net.SplitHostPort(*listen); err != nil || !net.ParseIP(host).IsLoopback() {
		log.Printf("ATTENTION : %s n'est pas une adresse locale ; l'API ne doit être exposée que sur Tailscale", *listen)
	}

	st := o.openStore()
	defer st.Close()
	tracker, err := requests.New(st, o.common)
	if err != nil {
		log.Fatal(err)
	}
	w := watcher.New(o.common, func(account int64, e contract.Event, raw []byte, backlog bool) {
		if _, err := st.AddEvent(account, e.Seq, e.TS, e.Type, raw); err != nil {
			log.Printf("journal du compte %d : %v", account, err)
		}
		tracker.OnEvent(account, e)
	})

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	go w.Run(ctx)
	go tracker.Run(ctx)
	go history.Run(ctx, st, w)
	bot := startTelegram(ctx, *chats, o.data, w, tracker, st, *preAlert)
	go checkReadiness(ctx, bot, o.data)
	var sinks []notify.Sink
	if bot != nil {
		sinks = append(sinks, bot)
	}
	vigil := notify.NewVigil(w, sinks...)
	go vigil.Run(ctx)
	startDeadman(ctx, *deadmanURL, o.data, w, vigil)

	srv := &http.Server{Addr: *listen, Handler: httpapi.New(w, st, tracker), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(shutdown)
	}()
	log.Printf("passerelle sur http://%s, dossier commun %s, base %s", *listen, o.common, o.data)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

// enroll crée un code à usage unique, valable 5 min, à saisir dans l'app.
func enroll(args []string) {
	var o options
	fs := flag.NewFlagSet("enroll", flag.ExitOnError)
	o.register(fs)
	name := fs.String("name", "", "nom du téléphone, ex. \"Pixel Richmond\"")
	list := fs.String("accounts", "*", "comptes autorisés, séparés par des virgules ; * = tous")
	fs.Parse(args)
	if strings.TrimSpace(*name) == "" {
		log.Fatal("-name obligatoire")
	}

	var accounts []int64
	if *list != "*" {
		accounts = []int64{}
		for _, p := range strings.Split(*list, ",") {
			n, err := strconv.ParseInt(strings.TrimSpace(p), 10, 64)
			if err != nil || n <= 0 {
				log.Fatalf("compte invalide : %q", p)
			}
			accounts = append(accounts, n)
		}
	}

	st := o.openStore()
	defer st.Close()
	code := auth.NewEnrollmentCode()
	expires := time.Now().Add(auth.EnrollmentTTL)
	if err := st.CreateEnrollment(auth.Hash(auth.NormalizeCode(code)), *name, accounts, expires); err != nil {
		log.Fatal(err)
	}
	fmt.Printf("Code d'enrôlement pour %q : %s\nValable jusqu'à %s, une seule fois. Comptes : %s\n",
		*name, code, expires.Format("15:04:05"), *list)
}

// diag : pour chaque compte, lit status.json et dit si le Watchdog est vivant.
// Code de sortie : 0 tous vivants, 1 dossier introuvable, 2 un statut absent,
// illisible ou périmé.
func diag(args []string) int {
	var o options
	fs := flag.NewFlagSet("diag", flag.ExitOnError)
	o.register(fs)
	fs.Parse(args)

	accounts, err := contract.AccountsUnder(o.common)
	if err != nil {
		fmt.Fprintf(os.Stderr, "dossier %s introuvable sous %s : lancer sous le compte Windows de MT5, avec un Watchdog 1.20 ou plus posé\n",
			contract.Root, o.common)
		return 1
	}
	if len(accounts) == 0 {
		fmt.Println("aucun compte : Watchdog pas encore posé")
		return 2
	}

	code := 0
	now := time.Now()
	for _, account := range accounts {
		b, err := os.ReadFile(filepath.Join(contract.AccountDirUnder(o.common, account), contract.StatusFile))
		if err != nil {
			fmt.Printf("%d : statut absent\n", account)
			code = 2
			continue
		}
		var s contract.Status
		if err := json.Unmarshal(b, &s); err != nil {
			fmt.Printf("%d : statut illisible (%v)\n", account, err)
			code = 2
			continue
		}
		verdict := "vivant"
		if s.Stale(now) {
			verdict = "MUET"
			code = 2
		}
		fmt.Printf("%d %q : Watchdog %s %s, %s, statut il y a %s, equity %.2f, %d position(s), seuils %s, bouclier %d/%d protégées\n",
			account, s.Label, s.Watchdog, verdict, s.State, now.Sub(s.TS).Round(time.Second), s.Equity, s.Positions,
			s.Config.Source, s.Shield.Protected, s.Shield.Protected+s.Shield.Unprotected)
	}
	return code
}

// telegramToken : variable d'environnement, sinon fichier telegram.token du
// dossier de données (lancement par la tâche planifiée, sans environnement).
func telegramToken(data string) string {
	if t := strings.TrimSpace(os.Getenv("MEREPOULE_TELEGRAM_TOKEN")); t != "" {
		return t
	}
	b, _ := os.ReadFile(filepath.Join(data, "telegram.token"))
	return strings.TrimSpace(string(b))
}

// startTelegram lance le canal de secours si un jeton et des chats sont donnés.
func startTelegram(ctx context.Context, chats, data string, w *watcher.Watcher, tr *requests.Tracker, st *store.Store, preAlert float64) *telegram.Bot {
	token := telegramToken(data)
	switch {
	case token == "" && chats == "":
		log.Printf("Telegram : non configuré (jeton et -telegram-chats)")
		return nil
	case token == "" || chats == "":
		log.Fatal("Telegram : il faut à la fois un jeton (MEREPOULE_TELEGRAM_TOKEN ou telegram.token) et -telegram-chats")
	}
	allowed, err := telegram.ParseChats(chats)
	if err != nil {
		log.Fatal(err)
	}
	bot := telegram.New(telegram.Config{Token: token, Chats: allowed, PreAlert: preAlert, Caller: call.NewCallMeBot()}, w, tr, st)
	go bot.Run(ctx)
	log.Printf("Telegram : /etat, /kill, /relancer, /go, /annuler, /actus et /appel actifs pour %d chat(s) ; pré-alerte à -%.0f", len(allowed), preAlert)
	return bot
}

// startDeadman envoie le signal de vie chaque minute si une adresse est
// donnée : en échec (/fail) quand un Watchdog est muet ou qu'aucun n'est lu.
func startDeadman(ctx context.Context, pingURL, data string, w *watcher.Watcher, vigil *notify.Vigil) {
	if pingURL == "" {
		b, _ := os.ReadFile(filepath.Join(data, "deadman.url"))
		pingURL = strings.TrimSpace(string(b))
	}
	if pingURL == "" {
		log.Printf("Signal de vie : non configuré (-deadman-url ou deadman.url)")
		return
	}
	health := func() (bool, string) {
		accounts := w.Accounts()
		if len(accounts) == 0 {
			return false, "aucun Watchdog lu par la passerelle"
		}
		muted := vigil.Muted()
		var lines []string
		for _, a := range accounts {
			snap, _ := w.Snapshot(a)
			lines = append(lines, fmt.Sprintf("%d %s, statut il y a %s", a, snap.Status.State,
				time.Since(snap.Status.TS).Round(time.Second)))
		}
		return len(muted) == 0, strings.Join(lines, "\n")
	}
	go deadman.New(pingURL, health).Run(ctx)
	log.Printf("Signal de vie : chaque minute")
}

// checkReadiness passe le diagnostic « Prêt pour le 24 h » au démarrage puis
// toutes les heures. Sur Telegram, il ne part que si les points à régler ont
// changé, ou une fois par jour s'ils restent : redémarrer la passerelle ne
// le renvoie pas. Le dernier envoi est noté dans <data>/readiness.last.
func checkReadiness(ctx context.Context, bot *telegram.Bot, data string) {
	stamp := filepath.Join(data, "readiness.last")
	for {
		r := readiness.Run()
		errs, warns := r.Problems()
		log.Printf("Prêt pour le 24 h : %d point(s) à corriger, %d à surveiller\n%s", errs, warns, r.Text())
		if bot != nil && errs+warns > 0 {
			key := r.Fingerprint()
			last, at := readReadinessStamp(stamp)
			if key != last || time.Since(at) >= 24*time.Hour {
				bot.Broadcast(ctx, telegram.ReadinessMessage(r))
				os.WriteFile(stamp, []byte(strconv.FormatInt(time.Now().Unix(), 10)+"\n"+key+"\n"), 0o600)
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Hour):
		}
	}
}

func readReadinessStamp(path string) (key string, at time.Time) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", time.Time{}
	}
	sec, rest, _ := strings.Cut(string(b), "\n")
	n, _ := strconv.ParseInt(strings.TrimSpace(sec), 10, 64)
	return strings.TrimSpace(rest), time.Unix(n, 0)
}

// ready : diagnostic dans la console. Code de sortie 0 si prêt, 2 sinon.
func ready() int {
	r := readiness.Run()
	fmt.Print(r.Text())
	if r.Ready {
		return 0
	}
	return 2
}

// setupLog : sans fenêtre, le journal va dans un fichier, renommé en .1 au-delà de 10 Mo.
func setupLog(path string) {
	if path == "" {
		return
	}
	if fi, err := os.Stat(path); err == nil && fi.Size() > 10<<20 {
		os.Rename(path, path+".1")
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		log.Fatal(err)
	}
	log.SetOutput(f)
}
