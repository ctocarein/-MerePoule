package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"slices"
	"strconv"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

var (
	ErrNotFound = errors.New("introuvable")
	ErrExpired  = errors.New("expiré")
)

const schema = `
CREATE TABLE IF NOT EXISTS devices (
	id         TEXT PRIMARY KEY,
	name       TEXT NOT NULL,
	token_hash TEXT NOT NULL UNIQUE,
	pin_hash   TEXT NOT NULL,
	accounts   TEXT NOT NULL,             -- "*" ou numéros séparés par des virgules
	push_token TEXT NOT NULL DEFAULT '',
	created_at INTEGER NOT NULL,
	revoked_at INTEGER
);
CREATE TABLE IF NOT EXISTS enrollments (
	code_hash  TEXT PRIMARY KEY,
	name       TEXT NOT NULL,
	accounts   TEXT NOT NULL,
	expires_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS pin_failures (
	device_id TEXT NOT NULL,
	at        INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS events (
	account INTEGER NOT NULL,
	seq     INTEGER NOT NULL,
	ts      INTEGER NOT NULL,
	type    TEXT NOT NULL,
	raw     TEXT NOT NULL,
	PRIMARY KEY (account, seq)
);
CREATE TABLE IF NOT EXISTS requests (
	id          TEXT PRIMARY KEY,
	account     INTEGER NOT NULL,
	kind        TEXT NOT NULL,
	device_id   TEXT NOT NULL,
	created_at  INTEGER NOT NULL,
	state       TEXT NOT NULL,
	resolved_at INTEGER,
	event_seq   INTEGER,
	detail      TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS samples (
	account INTEGER NOT NULL,
	ts      INTEGER NOT NULL,
	balance REAL NOT NULL,
	equity  REAL NOT NULL,
	PRIMARY KEY (account, ts)
);
CREATE TABLE IF NOT EXISTS watches (
	account         INTEGER PRIMARY KEY,
	chat            INTEGER NOT NULL,
	since           INTEGER NOT NULL,
	favorable_since INTEGER NOT NULL DEFAULT 0, -- 0 : marché pas favorable
	proposed_at     INTEGER NOT NULL DEFAULT 0, -- dernier go-to-market proposé
	bulletin_at     INTEGER NOT NULL DEFAULT 0  -- dernier point sur le marché
);
CREATE TABLE IF NOT EXISTS chat_prefs (
	chat  INTEGER NOT NULL,
	key   TEXT NOT NULL,
	value TEXT NOT NULL,
	PRIMARY KEY (chat, key)
);
`

// Store enveloppe la base. Une seule connexion : SQLite sérialise de toute
// façon les écritures, et la charge d'une passerelle est faible.
type Store struct{ db *sql.DB }

func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path+"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

// ---------------------------------------------------------------------------
// Comptes autorisés : nil = tous.

func encodeAccounts(accounts []int64) string {
	if accounts == nil {
		return "*"
	}
	parts := make([]string, len(accounts))
	for i, a := range accounts {
		parts[i] = strconv.FormatInt(a, 10)
	}
	return strings.Join(parts, ",")
}

func decodeAccounts(s string) []int64 {
	if s == "*" {
		return nil
	}
	accounts := []int64{}
	for _, p := range strings.Split(s, ",") {
		if n, err := strconv.ParseInt(strings.TrimSpace(p), 10, 64); err == nil {
			accounts = append(accounts, n)
		}
	}
	return accounts
}

// ---------------------------------------------------------------------------
// Appareils

type Device struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	PINHash   string    `json:"-"`
	Accounts  []int64   `json:"accounts"` // nil = tous les comptes de la passerelle
	PushToken string    `json:"-"`
	CreatedAt time.Time `json:"created_at"`
}

// Allows dit si l'appareil voit ce compte.
func (d Device) Allows(account int64) bool {
	return d.Accounts == nil || slices.Contains(d.Accounts, account)
}

// Covers dit si l'appareil voit tous les comptes de other.
func (d Device) Covers(other Device) bool {
	if d.Accounts == nil {
		return true
	}
	if other.Accounts == nil {
		return false
	}
	for _, a := range other.Accounts {
		if !d.Allows(a) {
			return false
		}
	}
	return true
}

// SharesWith dit si les deux appareils ont au moins un compte en commun.
func (d Device) SharesWith(other Device) bool {
	if d.Accounts == nil || other.Accounts == nil {
		return true
	}
	for _, a := range other.Accounts {
		if d.Allows(a) {
			return true
		}
	}
	return false
}

func (s *Store) CreateEnrollment(codeHash, name string, accounts []int64, expires time.Time) error {
	_, err := s.db.Exec(`INSERT INTO enrollments (code_hash, name, accounts, expires_at) VALUES (?, ?, ?, ?)`,
		codeHash, name, encodeAccounts(accounts), expires.Unix())
	return err
}

// ConsumeEnrollment supprime le code, qu'il soit valable ou expiré : un code ne sert qu'une fois.
func (s *Store) ConsumeEnrollment(codeHash string, now time.Time) (name string, accounts []int64, err error) {
	var enc string
	var expires int64
	err = s.db.QueryRow(`DELETE FROM enrollments WHERE code_hash = ? RETURNING name, accounts, expires_at`, codeHash).
		Scan(&name, &enc, &expires)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil, ErrNotFound
	}
	if err != nil {
		return "", nil, err
	}
	if now.Unix() > expires {
		return "", nil, ErrExpired
	}
	return name, decodeAccounts(enc), nil
}

func (s *Store) AddDevice(d Device, tokenHash string) error {
	_, err := s.db.Exec(`INSERT INTO devices (id, name, token_hash, pin_hash, accounts, push_token, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		d.ID, d.Name, tokenHash, d.PINHash, encodeAccounts(d.Accounts), d.PushToken, d.CreatedAt.Unix())
	return err
}

const deviceColumns = `id, name, pin_hash, accounts, push_token, created_at`

func scanDevice(row interface{ Scan(...any) error }) (Device, error) {
	var d Device
	var enc string
	var created int64
	if err := row.Scan(&d.ID, &d.Name, &d.PINHash, &enc, &d.PushToken, &created); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return d, ErrNotFound
		}
		return d, err
	}
	d.Accounts = decodeAccounts(enc)
	d.CreatedAt = time.Unix(created, 0).UTC()
	return d, nil
}

// DeviceByToken ne renvoie que les appareils non révoqués.
func (s *Store) DeviceByToken(tokenHash string) (Device, error) {
	return scanDevice(s.db.QueryRow(`SELECT `+deviceColumns+` FROM devices WHERE token_hash = ? AND revoked_at IS NULL`, tokenHash))
}

func (s *Store) Device(id string) (Device, error) {
	return scanDevice(s.db.QueryRow(`SELECT `+deviceColumns+` FROM devices WHERE id = ? AND revoked_at IS NULL`, id))
}

func (s *Store) Devices() ([]Device, error) {
	rows, err := s.db.Query(`SELECT ` + deviceColumns + ` FROM devices WHERE revoked_at IS NULL ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Device
	for rows.Next() {
		d, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

func (s *Store) RevokeDevice(id string, now time.Time) error {
	res, err := s.db.Exec(`UPDATE devices SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`, now.Unix(), id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Store) AddPINFailure(deviceID string, at time.Time) error {
	_, err := s.db.Exec(`INSERT INTO pin_failures (device_id, at) VALUES (?, ?)`, deviceID, at.Unix())
	return err
}

func (s *Store) PINFailures(deviceID string, since time.Time) (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM pin_failures WHERE device_id = ? AND at >= ?`, deviceID, since.Unix()).Scan(&n)
	return n, err
}

// ---------------------------------------------------------------------------
// Journal des Watchdogs

// AddEvent copie une ligne du journal ; false si ce seq était déjà connu.
func (s *Store) AddEvent(account, seq int64, ts time.Time, typ string, raw []byte) (bool, error) {
	res, err := s.db.Exec(`INSERT OR IGNORE INTO events (account, seq, ts, type, raw) VALUES (?, ?, ?, ?, ?)`,
		account, seq, ts.Unix(), typ, string(raw))
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n == 1, nil
}

// Events renvoie les lignes brutes de seq > since, dans l'ordre.
func (s *Store) Events(account, since int64, limit int) ([]json.RawMessage, error) {
	rows, err := s.db.Query(`SELECT raw FROM events WHERE account = ? AND seq > ? ORDER BY seq LIMIT ?`, account, since, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []json.RawMessage{}
	for rows.Next() {
		var raw string
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		out = append(out, json.RawMessage(raw))
	}
	return out, rows.Err()
}

// Marker est un arrêt, une pause, une relance ou un réarmement, pour les courbes.
type Marker struct {
	TS   time.Time `json:"ts"`
	Type string    `json:"type"`
	Seq  int64     `json:"seq"`
}

func (s *Store) Markers(account int64, from time.Time) ([]Marker, error) {
	rows, err := s.db.Query(`SELECT ts, type, seq FROM events
		WHERE account = ? AND ts >= ? AND type IN ('kill', 'pause', 'relaunch', 'reset') ORDER BY seq`, account, from.Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Marker{}
	for rows.Next() {
		var m Marker
		var ts int64
		if err := rows.Scan(&ts, &m.Type, &m.Seq); err != nil {
			return nil, err
		}
		m.TS = time.Unix(ts, 0).UTC()
		out = append(out, m)
	}
	return out, rows.Err()
}

// ---------------------------------------------------------------------------
// Demandes : état courant et journal d'audit à la fois.

type Request struct {
	ID         string     `json:"request_id"`
	Account    int64      `json:"account"`
	Kind       string     `json:"kind"`
	DeviceID   string     `json:"device_id"`
	CreatedAt  time.Time  `json:"created_at"`
	State      string     `json:"state"` // pending, executed, refused, timeout
	ResolvedAt *time.Time `json:"resolved_at"`
	EventSeq   int64      `json:"event_seq,omitempty"`
	Detail     string     `json:"detail,omitempty"`
}

func (s *Store) SaveRequest(r Request) error {
	var resolved sql.NullInt64
	if r.ResolvedAt != nil {
		resolved = sql.NullInt64{Int64: r.ResolvedAt.Unix(), Valid: true}
	}
	_, err := s.db.Exec(`INSERT INTO requests (id, account, kind, device_id, created_at, state, resolved_at, event_seq, detail)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (id) DO UPDATE SET state = excluded.state, resolved_at = excluded.resolved_at,
			event_seq = excluded.event_seq, detail = excluded.detail`,
		r.ID, r.Account, r.Kind, r.DeviceID, r.CreatedAt.Unix(), r.State, resolved, r.EventSeq, r.Detail)
	return err
}

const requestColumns = `id, account, kind, device_id, created_at, state, resolved_at, event_seq, detail`

func scanRequest(row interface{ Scan(...any) error }) (Request, error) {
	var r Request
	var created int64
	var resolved, seq sql.NullInt64
	if err := row.Scan(&r.ID, &r.Account, &r.Kind, &r.DeviceID, &created, &r.State, &resolved, &seq, &r.Detail); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return r, ErrNotFound
		}
		return r, err
	}
	r.CreatedAt = time.Unix(created, 0).UTC()
	if resolved.Valid {
		t := time.Unix(resolved.Int64, 0).UTC()
		r.ResolvedAt = &t
	}
	r.EventSeq = seq.Int64
	return r, nil
}

func (s *Store) Request(id string) (Request, error) {
	return scanRequest(s.db.QueryRow(`SELECT `+requestColumns+` FROM requests WHERE id = ?`, id))
}

// PendingRequests : demandes encore sans réponse, relues au démarrage.
func (s *Store) PendingRequests() ([]Request, error) {
	rows, err := s.db.Query(`SELECT ` + requestColumns + ` FROM requests WHERE state = 'pending'`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Request
	for rows.Next() {
		r, err := scanRequest(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// ---------------------------------------------------------------------------
// Échantillons de solde et d'equity

type Sample struct {
	TS      time.Time `json:"ts"`
	Balance float64   `json:"balance"`
	Equity  float64   `json:"equity"`
}

func (s *Store) AddSample(account int64, at time.Time, balance, equity float64) error {
	_, err := s.db.Exec(`INSERT OR REPLACE INTO samples (account, ts, balance, equity) VALUES (?, ?, ?, ?)`,
		account, at.Unix(), balance, equity)
	return err
}

// Samples renvoie, pour chaque tranche de bucket depuis from, le dernier
// échantillon de la tranche. SQLite prend les colonnes nues de la ligne
// qui porte le MAX.
func (s *Store) Samples(account int64, from time.Time, bucket time.Duration) ([]Sample, error) {
	b := int64(bucket / time.Second)
	if b < 1 {
		b = 1
	}
	rows, err := s.db.Query(`SELECT MAX(ts), balance, equity FROM samples
		WHERE account = ? AND ts >= ? GROUP BY ts / ? ORDER BY 1`, account, from.Unix(), b)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Sample{}
	for rows.Next() {
		var smp Sample
		var ts int64
		if err := rows.Scan(&ts, &smp.Balance, &smp.Equity); err != nil {
			return nil, err
		}
		smp.TS = time.Unix(ts, 0).UTC()
		out = append(out, smp)
	}
	return out, rows.Err()
}

// Prune oublie les échantillons et les échecs de PIN plus anciens que before.
func (s *Store) Prune(before time.Time) error {
	if _, err := s.db.Exec(`DELETE FROM samples WHERE ts < ?`, before.Unix()); err != nil {
		return err
	}
	_, err := s.db.Exec(`DELETE FROM pin_failures WHERE at < ?`, before.Unix())
	return err
}

// ---------------------------------------------------------------------------
// Attentes du marché : compte réarmé, robot éteint, go-to-market proposé
// quand le marché est favorable. Relues au démarrage de la passerelle.

type Watch struct {
	Account        int64
	Chat           int64 // chat Telegram qui a demandé l'attente
	Since          time.Time
	FavorableSince time.Time // zéro : marché pas favorable
	ProposedAt     time.Time // zéro : aucun go-to-market proposé
	BulletinAt     time.Time
}

func unix(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.Unix()
}

func fromUnix(n int64) time.Time {
	if n == 0 {
		return time.Time{}
	}
	return time.Unix(n, 0).UTC()
}

func (s *Store) SaveWatch(w Watch) error {
	_, err := s.db.Exec(`INSERT OR REPLACE INTO watches (account, chat, since, favorable_since, proposed_at, bulletin_at)
		VALUES (?, ?, ?, ?, ?, ?)`,
		w.Account, w.Chat, unix(w.Since), unix(w.FavorableSince), unix(w.ProposedAt), unix(w.BulletinAt))
	return err
}

func (s *Store) DeleteWatch(account int64) error {
	_, err := s.db.Exec(`DELETE FROM watches WHERE account = ?`, account)
	return err
}

func (s *Store) Watches() ([]Watch, error) {
	rows, err := s.db.Query(`SELECT account, chat, since, favorable_since, proposed_at, bulletin_at FROM watches ORDER BY account`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Watch
	for rows.Next() {
		var w Watch
		var since, fav, prop, bull int64
		if err := rows.Scan(&w.Account, &w.Chat, &since, &fav, &prop, &bull); err != nil {
			return nil, err
		}
		w.Since, w.FavorableSince, w.ProposedAt, w.BulletinAt = fromUnix(since), fromUnix(fav), fromUnix(prop), fromUnix(bull)
		out = append(out, w)
	}
	return out, rows.Err()
}

// ---------------------------------------------------------------------------
// Préférences d'un chat Telegram (ex. actus du marché coupée)

func (s *Store) SetChatPref(chat int64, key, value string) error {
	_, err := s.db.Exec(`INSERT OR REPLACE INTO chat_prefs (chat, key, value) VALUES (?, ?, ?)`, chat, key, value)
	return err
}

// ChatPref renvoie "" si la préférence n'a jamais été posée.
func (s *Store) ChatPref(chat int64, key string) (string, error) {
	var v string
	err := s.db.QueryRow(`SELECT value FROM chat_prefs WHERE chat = ? AND key = ?`, chat, key).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return v, err
}

// EventsSince : événements d'un compte de ces types depuis since, dans l'ordre.
func (s *Store) EventsSince(account int64, since time.Time, types ...string) ([]json.RawMessage, error) {
	if len(types) == 0 {
		return nil, nil
	}
	args := []any{account, since.Unix()}
	marks := make([]string, len(types))
	for i, t := range types {
		marks[i] = "?"
		args = append(args, t)
	}
	rows, err := s.db.Query(`SELECT raw FROM events WHERE account = ? AND ts >= ? AND type IN (`+strings.Join(marks, ",")+`) ORDER BY seq`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []json.RawMessage
	for rows.Next() {
		var raw string
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		out = append(out, json.RawMessage(raw))
	}
	return out, rows.Err()
}

// FirstSample : premier échantillon de solde et d'equity depuis since.
func (s *Store) FirstSample(account int64, since time.Time) (Sample, bool, error) {
	var smp Sample
	var ts int64
	err := s.db.QueryRow(`SELECT ts, balance, equity FROM samples WHERE account = ? AND ts >= ? ORDER BY ts LIMIT 1`,
		account, since.Unix()).Scan(&ts, &smp.Balance, &smp.Equity)
	if errors.Is(err, sql.ErrNoRows) {
		return smp, false, nil
	}
	if err != nil {
		return smp, false, err
	}
	smp.TS = time.Unix(ts, 0).UTC()
	return smp, true, nil
}
