package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"merepoule/gateway/internal/auth"
	"merepoule/gateway/internal/contract"
	"merepoule/gateway/internal/history"
	"merepoule/gateway/internal/readiness"
	"merepoule/gateway/internal/requests"
	"merepoule/gateway/internal/store"
	"merepoule/gateway/internal/watcher"
)

const maxBody = 16 << 10

type Server struct {
	watcher *watcher.Watcher
	store   *store.Store
	tracker *requests.Tracker
	now     func() time.Time
	mux     *http.ServeMux

	diagMu   sync.Mutex
	diagLast readiness.Report
	diagAt   time.Time
}

func New(w *watcher.Watcher, st *store.Store, tr *requests.Tracker) *Server {
	s := &Server{watcher: w, store: st, tracker: tr, now: time.Now, mux: http.NewServeMux()}
	const p = "/api/v1"
	s.mux.HandleFunc("GET "+p+"/health", s.health)
	s.mux.Handle("GET "+p+"/diagnostic", s.authed(s.diagnostic))
	s.mux.HandleFunc("POST "+p+"/devices", s.enroll)
	s.mux.Handle("GET "+p+"/devices", s.authed(s.listDevices))
	s.mux.Handle("DELETE "+p+"/devices/{id}", s.authed(s.revokeDevice))
	s.mux.Handle("GET "+p+"/accounts", s.authed(s.listAccounts))

	a := p + "/accounts/{account}"
	s.mux.Handle("GET "+a+"/status", s.account(s.status))
	s.mux.Handle("GET "+a+"/status/stream", s.account(s.stream))
	s.mux.Handle("GET "+a+"/events", s.account(s.events))
	s.mux.Handle("GET "+a+"/history", s.account(s.history))
	s.mux.Handle("GET "+a+"/config", s.account(s.getConfig))
	s.mux.Handle("PUT "+a+"/config", s.account(s.putConfig))
	s.mux.Handle("PUT "+a+"/robot/params", s.account(s.putRobotParam))
	s.mux.Handle("POST "+a+"/kill", s.account(s.kill))
	s.mux.Handle("POST "+a+"/pause", s.account(s.pause))
	s.mux.Handle("POST "+a+"/relaunch", s.account(s.relaunch))
	s.mux.Handle("POST "+a+"/reset", s.account(s.reset))
	s.mux.Handle("GET "+a+"/requests/{id}", s.account(s.getRequest))
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) { s.mux.ServeHTTP(w, r) }

// ---------------------------------------------------------------------------
// Réponses

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, code int, key, msg string) {
	writeJSON(w, code, map[string]string{"error": key, "message": msg})
}

// decode lit un corps JSON de 16 Ko au plus ; un corps vide laisse v à zéro.
func decode(r *http.Request, v any) error {
	err := json.NewDecoder(io.LimitReader(r.Body, maxBody)).Decode(v)
	if errors.Is(err, io.EOF) {
		return nil
	}
	return err
}

// ---------------------------------------------------------------------------
// Authentification : jeton d'appareil, puis compte autorisé et connu.

type ctxKey int

const (
	keyDevice ctxKey = iota
	keyAccount
)

func deviceOf(r *http.Request) store.Device { return r.Context().Value(keyDevice).(store.Device) }
func accountOf(r *http.Request) int64       { return r.Context().Value(keyAccount).(int64) }
func bearer(r *http.Request) (string, bool) {
	return strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
}
func snapshotOf(s *Server, r *http.Request) watcher.Snapshot {
	snap, _ := s.watcher.Snapshot(accountOf(r))
	return snap
}

func (s *Server) authed(h http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := bearer(r)
		if !ok || token == "" {
			fail(w, http.StatusUnauthorized, "token", "jeton d'appareil absent")
			return
		}
		d, err := s.store.DeviceByToken(auth.Hash(token))
		if err != nil {
			fail(w, http.StatusUnauthorized, "token", "jeton d'appareil invalide ou révoqué")
			return
		}
		h(w, r.WithContext(context.WithValue(r.Context(), keyDevice, d)))
	})
}

func (s *Server) account(h http.HandlerFunc) http.Handler {
	return s.authed(func(w http.ResponseWriter, r *http.Request) {
		account, err := strconv.ParseInt(r.PathValue("account"), 10, 64)
		if err != nil {
			fail(w, http.StatusNotFound, "account", "compte inconnu")
			return
		}
		if !deviceOf(r).Allows(account) {
			fail(w, http.StatusForbidden, "account", "compte non autorisé pour cet appareil")
			return
		}
		if _, ok := s.watcher.Snapshot(account); !ok {
			fail(w, http.StatusNotFound, "account", "aucun Watchdog lu pour ce compte")
			return
		}
		h(w, r.WithContext(context.WithValue(r.Context(), keyAccount, account)))
	})
}

// checkPIN répond lui-même en cas de refus. 5 échecs par heure et par
// appareil bloquent les actions à PIN, succès compris.
func (s *Server) checkPIN(w http.ResponseWriter, d store.Device, pin string) bool {
	now := s.now()
	failures, err := s.store.PINFailures(d.ID, now.Add(-auth.PINWindow))
	if err != nil {
		fail(w, http.StatusInternalServerError, "store", err.Error())
		return false
	}
	if failures >= auth.MaxPINFailures {
		fail(w, http.StatusTooManyRequests, "pin", "trop d'essais de PIN, réessayer dans une heure")
		return false
	}
	if auth.VerifyPIN(d.PINHash, pin) {
		return true
	}
	s.store.AddPINFailure(d.ID, now)
	if failures+1 >= auth.MaxPINFailures {
		fail(w, http.StatusTooManyRequests, "pin", "PIN incorrect ; trop d'essais, réessayer dans une heure")
	} else {
		fail(w, http.StatusForbidden, "pin", fmt.Sprintf("PIN incorrect, %d essai(s) restant(s)", auth.MaxPINFailures-failures-1))
	}
	return false
}

// origin : "app:<nom de l'appareil>", réduit aux caractères que le Watchdog garde.
func origin(d store.Device) string {
	var sb strings.Builder
	for _, c := range d.Name {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '-', c == '_', c == '.':
			sb.WriteRune(c)
		case c == ' ':
			sb.WriteByte('-')
		}
		if sb.Len() >= 48 {
			break
		}
	}
	if sb.Len() == 0 {
		return "app:" + d.ID
	}
	return "app:" + sb.String()
}

// ---------------------------------------------------------------------------
// Passerelle et appareils

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "time": s.now().UTC(), "accounts": len(s.watcher.Accounts())})
}

// diagnostic : « Prêt pour le 24 h », recalculé au plus une fois par minute.
func (s *Server) diagnostic(w http.ResponseWriter, r *http.Request) {
	s.diagMu.Lock()
	if s.diagAt.IsZero() || s.now().Sub(s.diagAt) > time.Minute {
		s.diagLast, s.diagAt = readiness.Run(), s.now()
	}
	rep := s.diagLast
	s.diagMu.Unlock()
	writeJSON(w, http.StatusOK, rep)
}

type enrollBody struct {
	Code      string `json:"code"`
	PIN       string `json:"pin"`
	PushToken string `json:"push_token"`
}

// enroll : premier contact d'un téléphone, avec le code à usage unique
// affiché sur la machine de trading (merepoule-gateway enroll).
func (s *Server) enroll(w http.ResponseWriter, r *http.Request) {
	var b enrollBody
	if err := decode(r, &b); err != nil {
		fail(w, http.StatusBadRequest, "body", err.Error())
		return
	}
	if !auth.ValidPIN(b.PIN) {
		fail(w, http.StatusBadRequest, "pin", "PIN de 6 à 12 chiffres")
		return
	}
	name, accounts, err := s.store.ConsumeEnrollment(auth.Hash(auth.NormalizeCode(b.Code)), s.now())
	if err != nil {
		fail(w, http.StatusForbidden, "code", "code d'enrôlement inconnu, déjà utilisé ou expiré")
		return
	}
	pinHash, err := auth.HashPIN(b.PIN)
	if err != nil {
		fail(w, http.StatusBadRequest, "pin", err.Error())
		return
	}
	token := auth.NewSecret(32)
	d := store.Device{ID: requests.NewID()[:8], Name: name, PINHash: pinHash, Accounts: accounts,
		PushToken: b.PushToken, CreatedAt: s.now().UTC()}
	if err := s.store.AddDevice(d, auth.Hash(token)); err != nil {
		fail(w, http.StatusInternalServerError, "store", err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"device_id": d.ID, "name": d.Name, "token": token, "accounts": d.Accounts})
}

// listDevices : les appareils qui partagent au moins un compte avec l'appelant.
func (s *Server) listDevices(w http.ResponseWriter, r *http.Request) {
	me := deviceOf(r)
	all, err := s.store.Devices()
	if err != nil {
		fail(w, http.StatusInternalServerError, "store", err.Error())
		return
	}
	out := []store.Device{}
	for _, d := range all {
		if me.SharesWith(d) {
			out = append(out, d)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": out, "self": me.ID})
}

// revokeDevice : soi-même sans PIN ; un autre appareil avec le PIN, et
// seulement si l'appelant voit tous ses comptes.
func (s *Server) revokeDevice(w http.ResponseWriter, r *http.Request) {
	me := deviceOf(r)
	id := r.PathValue("id")
	if id != me.ID {
		target, err := s.store.Device(id)
		if err != nil {
			fail(w, http.StatusNotFound, "device", "appareil inconnu")
			return
		}
		if !me.Covers(target) {
			fail(w, http.StatusForbidden, "device", "cet appareil voit des comptes que vous ne voyez pas")
			return
		}
		var b struct {
			PIN string `json:"pin"`
		}
		if err := decode(r, &b); err != nil {
			fail(w, http.StatusBadRequest, "body", err.Error())
			return
		}
		if !s.checkPIN(w, me, b.PIN) {
			return
		}
	}
	if err := s.store.RevokeDevice(id, s.now()); err != nil {
		fail(w, http.StatusNotFound, "device", "appareil inconnu")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------------------------------------------------------------------------
// Comptes et statut

type accountSummary struct {
	Account  int64   `json:"account"`
	Label    string  `json:"label"`
	State    string  `json:"state"`
	Watchdog string  `json:"watchdog"`
	Stale    bool    `json:"stale"`
	AgeS     float64 `json:"age_s"`
}

func (s *Server) listAccounts(w http.ResponseWriter, r *http.Request) {
	me := deviceOf(r)
	now := s.now()
	out := []accountSummary{}
	for _, a := range s.watcher.Accounts() {
		if !me.Allows(a) {
			continue
		}
		snap, _ := s.watcher.Snapshot(a)
		out = append(out, accountSummary{Account: a, Label: snap.Status.Label, State: snap.Status.State,
			Watchdog: snap.Status.Watchdog, Stale: snap.Status.Stale(now), AgeS: age(snap, now)})
	}
	writeJSON(w, http.StatusOK, map[string]any{"accounts": out})
}

func age(snap watcher.Snapshot, now time.Time) float64 {
	return float64(now.Sub(snap.Status.TS).Milliseconds()) / 1000
}

func (s *Server) statusBody(r *http.Request) map[string]any {
	snap := snapshotOf(s, r)
	now := s.now()
	return map[string]any{"account": accountOf(r), "stale": snap.Status.Stale(now), "age_s": age(snap, now), "status": snap.Raw}
}

func (s *Server) status(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.statusBody(r))
}

// stream : statut en direct, un message par seconde (Server-Sent Events).
func (s *Server) stream(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		fail(w, http.StatusInternalServerError, "stream", "flux non pris en charge")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		b, _ := json.Marshal(s.statusBody(r))
		if _, err := fmt.Fprintf(w, "event: status\ndata: %s\n\n", b); err != nil {
			return
		}
		flusher.Flush()
		select {
		case <-r.Context().Done():
			return
		case <-tick.C:
		}
	}
}

func (s *Server) events(w http.ResponseWriter, r *http.Request) {
	since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	limit, err := strconv.Atoi(r.URL.Query().Get("limit"))
	if err != nil || limit <= 0 || limit > 500 {
		limit = 100
	}
	ev, err := s.store.Events(accountOf(r), since, limit)
	if err != nil {
		fail(w, http.StatusInternalServerError, "store", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": ev})
}

func (s *Server) history(w http.ResponseWriter, r *http.Request) {
	period := r.URL.Query().Get("period")
	if period == "" {
		period = "24h"
	}
	if _, ok := history.Periods[period]; !ok {
		fail(w, http.StatusBadRequest, "period", "période : 24h, 7d ou 30d")
		return
	}
	h, err := history.Build(s.store, accountOf(r), period, s.now())
	if err != nil {
		fail(w, http.StatusInternalServerError, "store", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, h)
}

// ---------------------------------------------------------------------------
// Demandes

type accepted struct {
	RequestID     *string `json:"request_id"`
	State         string  `json:"state"`
	WatchdogStale bool    `json:"watchdog_stale"`
}

// submit dépose la demande et répond 202, ou 200 pour une demande déjà connue.
func (s *Server) submit(w http.ResponseWriter, r *http.Request, kind requests.Kind, payload map[string]any) {
	id := r.Header.Get("Idempotency-Key")
	if id != "" && !requests.ValidID(id) {
		fail(w, http.StatusBadRequest, "idempotency_key", "Idempotency-Key doit être un UUID")
		return
	}
	d := deviceOf(r)
	req, created, err := s.tracker.Submit(accountOf(r), kind, id, d.ID, origin(d), payload)
	if errors.Is(err, requests.ErrBusy) {
		fail(w, http.StatusConflict, "busy", err.Error())
		return
	}
	if err != nil {
		log.Printf("httpapi: %v", err)
		fail(w, http.StatusServiceUnavailable, "flag", err.Error())
		return
	}
	code := http.StatusAccepted
	if !created {
		code = http.StatusOK
	}
	writeJSON(w, code, accepted{RequestID: &req.ID, State: req.State, WatchdogStale: snapshotOf(s, r).Status.Stale(s.now())})
}

// already : l'état voulu est déjà atteint, selon un statut frais. Un statut
// périmé ne prouve rien : la demande part quand même.
func (s *Server) already(w http.ResponseWriter, r *http.Request, state string) bool {
	st := snapshotOf(s, r).Status
	if st.Stale(s.now()) || st.State != state {
		return false
	}
	writeJSON(w, http.StatusOK, accepted{State: state})
	return true
}

type commandBody struct {
	Confirm bool   `json:"confirm"`
	Reason  string `json:"reason"`
	PIN     string `json:"pin"`
}

func reason(b commandBody) map[string]any {
	return map[string]any{"reason": b.Reason}
}

func (s *Server) kill(w http.ResponseWriter, r *http.Request) {
	var b commandBody
	if err := decode(r, &b); err != nil {
		fail(w, http.StatusBadRequest, "body", err.Error())
		return
	}
	if !b.Confirm {
		fail(w, http.StatusBadRequest, "confirm", "confirm: true obligatoire")
		return
	}
	if s.already(w, r, "KILL") {
		return
	}
	s.submit(w, r, requests.Kill, reason(b))
}

func (s *Server) pause(w http.ResponseWriter, r *http.Request) {
	var b commandBody
	if err := decode(r, &b); err != nil {
		fail(w, http.StatusBadRequest, "body", err.Error())
		return
	}
	st := snapshotOf(s, r).Status
	if !st.Stale(s.now()) && st.State == "KILL" {
		fail(w, http.StatusConflict, "state", "en KILL : pas de pause, le compte est déjà à plat")
		return
	}
	if s.already(w, r, "PAUSE") {
		return
	}
	s.submit(w, r, requests.Pause, reason(b))
}

func (s *Server) relaunch(w http.ResponseWriter, r *http.Request) {
	var b commandBody
	if err := decode(r, &b); err != nil {
		fail(w, http.StatusBadRequest, "body", err.Error())
		return
	}
	st := snapshotOf(s, r).Status
	if st.Stale(s.now()) {
		fail(w, http.StatusServiceUnavailable, "stale", "Watchdog muet : relance impossible")
		return
	}
	if until := st.PausedUntil(s.now()); !until.IsZero() {
		fail(w, http.StatusConflict, "pause", "pause après l'arrêt d'urgence : relance possible à "+until.UTC().Format("15:04")+" GMT")
		return
	}
	switch {
	case st.State == "KILL":
		fail(w, http.StatusConflict, "state", "en KILL : réarmer d'abord")
		return
	case st.FullyRunning():
		fail(w, http.StatusConflict, "state", "le robot tourne déjà")
		return
	case st.State == "RUN" && st.SavedCharts == 0:
		fail(w, http.StatusConflict, "state", "aucun graphique enregistré : relancer le robot à la main")
		return
	}
	if !s.checkPIN(w, deviceOf(r), b.PIN) {
		return
	}
	s.submit(w, r, requests.Relaunch, reason(b))
}

func (s *Server) reset(w http.ResponseWriter, r *http.Request) {
	var b commandBody
	if err := decode(r, &b); err != nil {
		fail(w, http.StatusBadRequest, "body", err.Error())
		return
	}
	st := snapshotOf(s, r).Status
	if st.Stale(s.now()) {
		fail(w, http.StatusServiceUnavailable, "stale", "Watchdog muet : réarmement impossible")
		return
	}
	switch {
	case st.State != "KILL":
		fail(w, http.StatusConflict, "state", "pas en KILL : rien à réarmer")
		return
	case st.Positions > 0 || st.PendingOrders > 0:
		fail(w, http.StatusConflict, "state", "positions ou ordres encore ouverts")
		return
	}
	if !s.checkPIN(w, deviceOf(r), b.PIN) {
		return
	}
	s.submit(w, r, requests.Reset, reason(b))
}

func (s *Server) getRequest(w http.ResponseWriter, r *http.Request) {
	req, err := s.tracker.Get(r.PathValue("id"))
	if err != nil || req.Account != accountOf(r) {
		fail(w, http.StatusNotFound, "request", "demande inconnue")
		return
	}
	writeJSON(w, http.StatusOK, req)
}

// ---------------------------------------------------------------------------
// Seuils

func (s *Server) getConfig(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, snapshotOf(s, r).Status.Config)
}

type configBody struct {
	PIN             string   `json:"pin"`
	MarginLevelMin  *float64 `json:"margin_level_min"`
	MarginAction    *string  `json:"margin_action"`
	MaxFloatingLoss *float64 `json:"max_floating_loss"`
	MaxDailyDDPct   *float64 `json:"max_daily_dd_pct"`
	MaxGivebackPct  *float64 `json:"max_giveback_pct"`
}

// checkCaps reprend les règles du Watchdog, qui revérifie et reste seul juge.
func checkCaps(b configBody, c contract.Config) []string {
	var errs []string
	atMost := func(key string, v *float64, cap float64) {
		switch {
		case v == nil:
		case cap <= 0:
			errs = append(errs, key+" non modifiable à distance")
		case *v <= 0:
			errs = append(errs, key+" : une règle ne se désactive que dans MT5")
		case *v > cap:
			errs = append(errs, fmt.Sprintf("%s %.2f au-delà du plafond %.2f", key, *v, cap))
		}
	}
	atMost("max_floating_loss", b.MaxFloatingLoss, c.Caps.MaxFloatingLoss)
	atMost("max_daily_dd_pct", b.MaxDailyDDPct, c.Caps.MaxDailyDDPct)
	atMost("max_giveback_pct", b.MaxGivebackPct, c.Caps.MaxGivebackPct)
	if v := b.MarginLevelMin; v != nil {
		switch {
		case c.Caps.MarginLevelMin <= 0:
			errs = append(errs, "margin_level_min non modifiable à distance")
		case *v < c.Caps.MarginLevelMin:
			errs = append(errs, fmt.Sprintf("margin_level_min %.1f sous le plancher %.1f", *v, c.Caps.MarginLevelMin))
		}
	}
	if a := b.MarginAction; a != nil {
		switch {
		case *a != "alert" && *a != "kill":
			errs = append(errs, "margin_action : alert ou kill")
		case *a == "alert" && !c.Caps.MarginActionAlert:
			errs = append(errs, "margin_action alert interdit : l'arrêt sur marge est imposé dans MT5")
		}
	}
	if b.MarginLevelMin == nil && b.MarginAction == nil && b.MaxFloatingLoss == nil &&
		b.MaxDailyDDPct == nil && b.MaxGivebackPct == nil {
		errs = append(errs, "aucun seuil dans la demande")
	}
	return errs
}

func (s *Server) putConfig(w http.ResponseWriter, r *http.Request) {
	var b configBody
	if err := decode(r, &b); err != nil {
		fail(w, http.StatusBadRequest, "body", err.Error())
		return
	}
	st := snapshotOf(s, r).Status
	if st.Stale(s.now()) {
		fail(w, http.StatusServiceUnavailable, "stale", "Watchdog muet : plafonds inconnus")
		return
	}
	if !st.Config.RemoteAllowed {
		fail(w, http.StatusForbidden, "config", "modifications à distance interdites dans MT5")
		return
	}
	if errs := checkCaps(b, st.Config); len(errs) > 0 {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "caps", "errors": errs})
		return
	}
	if !s.checkPIN(w, deviceOf(r), b.PIN) {
		return
	}
	payload := map[string]any{}
	set := func(key string, v any, present bool) {
		if present {
			payload[key] = v
		}
	}
	set("margin_level_min", b.MarginLevelMin, b.MarginLevelMin != nil)
	set("margin_action", b.MarginAction, b.MarginAction != nil)
	set("max_floating_loss", b.MaxFloatingLoss, b.MaxFloatingLoss != nil)
	set("max_daily_dd_pct", b.MaxDailyDDPct, b.MaxDailyDDPct != nil)
	set("max_giveback_pct", b.MaxGivebackPct, b.MaxGivebackPct != nil)
	s.submit(w, r, requests.Config, payload)
}

// ---------------------------------------------------------------------------
// Réglages du robot

type robotParamBody struct {
	PIN    string   `json:"pin"`
	Param  string   `json:"param"`
	Value  *float64 `json:"value"`
	Symbol string   `json:"symbol"` // vide : tous les graphiques du robot
}

// putRobotParam change un réglage du robot. Seuls les réglages listés dans
// MT5 (robot_params du statut) passent, dans leurs bornes ; le Watchdog
// revérifie et reste seul juge. Le robot doit tourner : l'EA redémarre avec
// la nouvelle valeur.
func (s *Server) putRobotParam(w http.ResponseWriter, r *http.Request) {
	var b robotParamBody
	if err := decode(r, &b); err != nil {
		fail(w, http.StatusBadRequest, "body", err.Error())
		return
	}
	st := snapshotOf(s, r).Status
	if st.Stale(s.now()) {
		fail(w, http.StatusServiceUnavailable, "stale", "Watchdog muet : réglage impossible")
		return
	}
	if st.State != "RUN" || st.TargetCharts == 0 {
		fail(w, http.StatusConflict, "state", "le robot doit tourner : relancer d'abord")
		return
	}

	var param *contract.RobotParam
	for i := range st.RobotParams {
		if st.RobotParams[i].Name == b.Param {
			param = &st.RobotParams[i]
		}
	}
	var errs []string
	switch {
	case param == nil:
		errs = append(errs, fmt.Sprintf("%q non modifiable à distance (liste fixée dans MT5)", b.Param))
	case b.Value == nil:
		errs = append(errs, "value obligatoire")
	case *b.Value < param.Min || *b.Value > param.Max:
		errs = append(errs, fmt.Sprintf("%s %g hors de [%g ; %g]", param.Label, *b.Value, param.Min, param.Max))
	}
	if b.Symbol != "" {
		found := false
		for _, t := range st.Targets {
			found = found || t.Symbol == b.Symbol
		}
		if !found {
			errs = append(errs, fmt.Sprintf("aucun graphique du robot sur %s", b.Symbol))
		}
	}
	if len(errs) > 0 {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "robot_params", "errors": errs})
		return
	}
	if !s.checkPIN(w, deviceOf(r), b.PIN) {
		return
	}
	payload := map[string]any{"param": b.Param, "value": *b.Value}
	if b.Symbol != "" {
		payload["symbol"] = b.Symbol
	}
	s.submit(w, r, requests.Robot, payload)
}
