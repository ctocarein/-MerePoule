// Package contract décrit le contrat Watchdog ↔ Passerelle, v2
// (docs/MerePoule_Architecture.md, contract/) : un dossier par compte sous
// Common\Files\MerePoule\, les fichiers échangés et leurs formats.
package contract

import (
	"os"
	"path/filepath"
	"strconv"
	"time"
)

const (
	Root          = "MerePoule"      // sous le dossier commun de MT5
	StatusFile    = "status.json"    // Watchdog → passerelle, chaque seconde
	EventsFile    = "events.jsonl"   // Watchdog → passerelle, ajout seul
	EventsOldFile = "events.1.jsonl" // journal précédent, après rotation
	KillFlag      = "kill.flag"      // passerelle → Watchdog, supprimé par le Watchdog
	ResetFlag     = "reset.flag"     // passerelle → Watchdog, supprimé par le Watchdog
	PauseFlag     = "pause.flag"     // passerelle → Watchdog, supprimé par le Watchdog
	RelaunchFlag  = "relaunch.flag"  // passerelle → Watchdog, supprimé par le Watchdog
	RobotFlag     = "robot.flag"     // passerelle → Watchdog, supprimé par le Watchdog
	ConfigFlag    = "config.flag"    // passerelle → Watchdog, supprimé par le Watchdog
	CutFlag       = "cut.flag"       // passerelle → Watchdog : couper un symbole (Watchdog 1.32)
	RulesFlag     = "rules.flag"     // passerelle → Watchdog : règle choisie pour un symbole (Watchdog 1.34)
	CompareFlag   = "compare.flag"   // passerelle → Lecteur : comparatif des règles, supprimé par le Lecteur
	LecteurFile   = "lecteur.json"   // Lecteur → passerelle : le comparatif
)

// RuleModes : règles au choix par symbole (décision 30). trend : M5, et M30
// ou H1, dans le sens voulu ; jump : pause quand aucun saut depuis
// Config.JumpLateMin ; both : les deux ; none : aucun filtre.
var RuleModes = []string{"trend", "jump", "both", "none"}

const (
	// StaleAfter : au-delà, la passerelle signale « Watchdog muet ».
	StaleAfter = 5 * time.Second
	// RequestTimeout : sans événement portant le request_id, la demande passe en timeout.
	RequestTimeout = 10 * time.Second
)

// CommonFilesDir renvoie le dossier commun de MT5 pour le compte Windows
// courant. La passerelle doit tourner sous le même compte que MT5, sinon ce
// chemin ne désigne pas le dossier où écrit le Watchdog.
func CommonFilesDir() string {
	return filepath.Join(os.Getenv("APPDATA"), "MetaQuotes", "Terminal", "Common", "Files")
}

// AccountDir renvoie le dossier du contrat pour un compte.
func AccountDir(account int64) string {
	return AccountDirUnder(CommonFilesDir(), account)
}

// Accounts liste les comptes dont un Watchdog a créé le dossier.
func Accounts() ([]int64, error) {
	return AccountsUnder(CommonFilesDir())
}

// AccountDirUnder est AccountDir pour un dossier commun donné.
func AccountDirUnder(common string, account int64) string {
	return filepath.Join(common, Root, strconv.FormatInt(account, 10))
}

// AccountsUnder est Accounts pour un dossier commun donné.
func AccountsUnder(common string) ([]int64, error) {
	entries, err := os.ReadDir(filepath.Join(common, Root))
	if err != nil {
		return nil, err
	}
	var accounts []int64
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if n, err := strconv.ParseInt(e.Name(), 10, 64); err == nil && n > 0 {
			accounts = append(accounts, n)
		}
	}
	return accounts, nil
}

// Status est le contenu de status.json.
type Status struct {
	V              int          `json:"v"`
	TS             time.Time    `json:"ts"`
	Account        int64        `json:"account"`
	Label          string       `json:"label"`
	Watchdog       string       `json:"watchdog"`
	State          string       `json:"state"` // RUN, PAUSE ou KILL
	Connected      bool         `json:"connected"`
	AlgoTrading    bool         `json:"algo_trading"`
	Equity         float64      `json:"equity"`
	Balance        float64      `json:"balance"`
	Floating       float64      `json:"floating"`
	MarginLevel    float64      `json:"margin_level"`
	MarginCall     float64      `json:"margin_call_level"`
	StopOutLevel   float64      `json:"stop_out_level"`
	StopOutMode    string       `json:"stop_out_mode"` // percent ou money
	DayOpenBalance float64      `json:"day_open_balance"`
	DailyDDPct     float64      `json:"daily_dd_pct"`
	PeakEquity     float64      `json:"peak_equity"`
	GivebackPct    float64      `json:"giveback_pct"`
	Positions      int          `json:"positions"`
	PendingOrders  int          `json:"pending_orders"`
	Symbols        []Exposure   `json:"symbols"`
	TargetCharts   int          `json:"target_charts"`
	Targets        []Chart      `json:"targets"`
	SavedCharts    int          `json:"saved_charts"`  // graphiques que RELANCER peut rouvrir
	SavedSymbols   []string     `json:"saved_symbols"` // leurs symboles (Watchdog 1.31)
	RobotParams    []RobotParam `json:"robot_params"`  // réglages du robot modifiables à distance
	Market         []Market     `json:"market"`        // contexte de marché des symboles du robot (H1)
	Chameleon      Chameleon    `json:"chameleon"`     // Caméléon en observation (décision 21)
	Shield         Shield       `json:"shield"`
	EventsSeq      int64        `json:"events_seq"`
	News           struct {
		Active bool    `json:"active"`
		Label  *string `json:"label"`
	} `json:"news"`
	LastKill struct {
		At        *time.Time `json:"at"`
		Reason    *string    `json:"reason"`
		RequestID *string    `json:"request_id"`
	} `json:"last_kill"`
	Config Config `json:"config"`
}

// Exposure regroupe les positions surveillées d'un symbole.
type Exposure struct {
	Symbol     string  `json:"symbol"`
	Positions  int     `json:"positions"`
	BuyVolume  float64 `json:"buy_volume"`
	SellVolume float64 `json:"sell_volume"`
	Floating   float64 `json:"floating"`
}

// Chart est un graphique ouvert du robot surveillé.
type Chart struct {
	Expert string            `json:"expert"`
	Symbol string            `json:"symbol"`
	Period string            `json:"period"` // M1, H1…
	Inputs map[string]string `json:"inputs"` // réglages de l'EA lus dans son modèle, valeurs telles quelles
}

// Market décrit un symbole du robot en bougies H1 : variation du prix,
// tendance (hausse, baisse, neutre) et agitation (calme, normal, agite).
// Pour expliquer un arrêt et aider à décider d'une relance, jamais pour décider.
type Market struct {
	Symbol     string  `json:"symbol"`
	Price      float64 `json:"price"`
	Chg1h      float64 `json:"chg_1h_pct"`
	Chg4h      float64 `json:"chg_4h_pct"`
	Chg24h     float64 `json:"chg_24h_pct"`
	Trend      string  `json:"trend"`
	Volatility string  `json:"volatility"`
	RobotSide  string  `json:"robot_side"` // sens habituel du robot sur 7 jours : buy, sell, both ou "" (Watchdog 1.27)

	// Règle du trader (décision 25, Watchdog 1.30), en information : sens
	// voulu, tendance de chaque unité de temps et verdict.
	Want     string `json:"want"` // buy, sell ou "" sans règle
	M5       string `json:"m5"`   // hausse, baisse, neutre
	M30      string `json:"m30"`
	H1       string `json:"h1"`
	Rule     string `json:"rule"`     // autorise, interdit ou ""
	Reversal bool   `json:"reversal"` // dernière bougie M5 : forte, contre le sens voulu

	// Watchdog 1.33 : contre-tendance confirmée (M5 contre le sens voulu, et
	// M30 ou H1 aussi), et le marché sur la dernière heure.
	Counter bool    `json:"counter"`
	Chg60m  float64 `json:"chg_60m_pct"`
	Trend1h string  `json:"trend_1h"` // hausse, baisse, neutre ; "" avant 1.33

	// Watchdog 1.34 (décision 30) : la règle choisie pour ce symbole, le
	// dernier saut, et le verdict de cette règle.
	RuleMode   string `json:"rule_mode"`    // trend, jump, both, none ; "" avant 1.34
	JumpAgeMin int    `json:"jump_age_min"` // minutes depuis le dernier saut, -1 inconnu
	JumpLate   bool   `json:"jump_late"`    // aucun saut depuis Config.JumpLateMin
	Allowed    *bool  `json:"allowed"`      // le robot peut tourner selon la règle choisie ; nil avant 1.34
}

// Go : la règle choisie laisse-t-elle tourner le robot sur ce symbole ?
// Avant 1.34, la règle tendance seule.
func (m Market) Go() bool {
	if m.Allowed != nil {
		return *m.Allowed
	}
	return m.Rule == "autorise"
}

// Chameleon : groupes de positions (symbole et sens) repérés avant l'arrêt,
// à contre-tendance au-delà de Threshold (raison trend), ou en perte lourde
// au-delà de HeavyThreshold quelle que soit la tendance (raison heavy,
// Watchdog 1.28). En observation, rien n'est fermé : chaque cas se solde
// par un bilan, coupe contre réalité.
type Chameleon struct {
	Mode           string                    `json:"mode"` // observe
	Pct            float64                   `json:"pct"`  // part du seuil de perte flottante, %
	Threshold      float64                   `json:"threshold"`
	HeavyPct       float64                   `json:"heavy_pct"`
	HeavyThreshold float64                   `json:"heavy_threshold"`
	Open           []ChameleonCase           `json:"open"`
	Episodes       int                       `json:"episodes"`    // cas soldés
	SavedTotal     float64                   `json:"saved_total"` // somme de (coupe − réel) : positif, la coupe aurait épargné
	ByReason       map[string]ChameleonTally `json:"by_reason"`   // trend, heavy
}

// ChameleonTally : bilan cumulé d'une raison de déclenchement.
type ChameleonTally struct {
	Episodes   int     `json:"episodes"`
	SavedTotal float64 `json:"saved_total"`
}

// ChameleonCase est un groupe à contre-tendance dont le bilan est en attente.
type ChameleonCase struct {
	Symbol    string    `json:"symbol"`
	Side      string    `json:"side"` // buy ou sell
	Since     time.Time `json:"since"`
	CutResult float64   `json:"cut_result"` // résultat du groupe au déclenchement : ce qu'une coupe aurait réalisé
	Positions int       `json:"positions"`
	Reason    string    `json:"reason"` // trend ou heavy
}

// RobotParam est un réglage du robot que la passerelle peut changer, dans
// des bornes fixées dans MT5 (InpRobotParams).
type RobotParam struct {
	Name  string  `json:"name"`  // nom de l'input, ex. InpParamL1
	Label string  `json:"label"` // nom affiché, ex. Lot
	Min   float64 `json:"min"`
	Max   float64 `json:"max"`
}

// Shield résume le Bouclier : stop loss catastrophe côté courtier.
type Shield struct {
	Active      bool    `json:"active"`
	Budget      float64 `json:"budget"`
	Groups      int     `json:"groups"`
	Protected   int     `json:"protected"`
	Unprotected int     `json:"unprotected"` // positions gérées sans stop loss
}

// RelaunchPause : politique de la passerelle (décision 26). Pas de
// redémarrage du robot moins d'une heure après un arrêt d'urgence : le
// 25/09, six relances d'affilée ont été coupées en 9 à 19 min.
const RelaunchPause = time.Hour

// PausedUntil : fin de la pause après le dernier arrêt ; zéro si elle est
// finie ou s'il n'y a jamais eu d'arrêt.
func (s Status) PausedUntil(now time.Time) time.Time {
	if s.LastKill.At == nil {
		return time.Time{}
	}
	until := s.LastKill.At.Add(RelaunchPause)
	if !now.Before(until) {
		return time.Time{}
	}
	return until
}

// Stale dit si le Watchdog doit être considéré comme muet à l'instant now.
func (s Status) Stale(now time.Time) bool {
	return now.Sub(s.TS) > StaleAfter
}

// Config décrit les seuils actifs et les plafonds des modifications à distance.
type Config struct {
	Source          string  `json:"source"` // local ou remote
	RemoteAllowed   bool    `json:"remote_allowed"`
	MarginLevelMin  float64 `json:"margin_level_min"`
	MarginAction    string  `json:"margin_action"` // alert ou kill
	MaxFloatingLoss float64 `json:"max_floating_loss"`
	// Décision 28 (Watchdog 1.32) : à MaxFloatingLoss, le trader décide ;
	// l'arrêt automatique n'a lieu qu'à FloatingLastResort.
	ManualDecision     bool    `json:"manual_decision"`
	FloatingLastResort float64 `json:"floating_last_resort"`
	MaxDailyDDPct      float64 `json:"max_daily_dd_pct"`
	MaxGivebackPct     float64 `json:"max_giveback_pct"`
	NewsCurrencies     string  `json:"news_currencies"`
	Magic              int64   `json:"magic"`
	JumpLateMin        int     `json:"jump_late_min"` // règle saut : pause sans saut depuis ces minutes (Watchdog 1.34)
	Caps               struct {
		MarginLevelMin    float64 `json:"margin_level_min"`
		MarginActionAlert bool    `json:"margin_action_alert"`
		MaxFloatingLoss   float64 `json:"max_floating_loss"`
		MaxDailyDDPct     float64 `json:"max_daily_dd_pct"`
		MaxGivebackPct    float64 `json:"max_giveback_pct"`
	} `json:"caps"`
}

// Event est une ligne de events.jsonl. Les champs propres à un type sont
// absents des autres.
type Event struct {
	V         int       `json:"v"`
	Seq       int64     `json:"seq"`
	TS        time.Time `json:"ts"`
	Account   int64     `json:"account"`
	Type      string    `json:"type"`
	Level     string    `json:"level"`
	Message   string    `json:"message"`
	Origin    *string   `json:"origin,omitempty"`
	RequestID *string   `json:"request_id,omitempty"`

	State   string  `json:"state,omitempty"`   // start
	Version string  `json:"version,omitempty"` // start
	Cause   string  `json:"cause,omitempty"`   // stop
	Code    string  `json:"code,omitempty"`    // alert
	Errors  string  `json:"errors,omitempty"`  // config_refused
	Config  *Config `json:"config,omitempty"`  // config

	Rule            string     `json:"rule,omitempty"`   // kill
	Charts          int        `json:"charts,omitempty"` // kill, pause, relaunch
	ChartsClosed    int        `json:"charts_closed,omitempty"`
	ChartsSaved     int        `json:"charts_saved,omitempty"`    // kill, pause
	ChartsReopened  int        `json:"charts_reopened,omitempty"` // relaunch
	Positions       int        `json:"positions,omitempty"`       // kill, reset_refused
	PositionsClosed int        `json:"positions_closed,omitempty"`
	Orders          int        `json:"orders,omitempty"` // kill, reset_refused
	OrdersDeleted   int        `json:"orders_deleted,omitempty"`
	EquityBefore    float64    `json:"equity_before,omitempty"`
	EquityAfter     float64    `json:"equity_after,omitempty"`
	Balance         float64    `json:"balance,omitempty"`
	Exposure        []Exposure `json:"exposure,omitempty"` // kill : positions par symbole juste avant l'arrêt
	Market          []Market   `json:"market,omitempty"`   // kill : contexte de marché

	Placed  int     `json:"placed,omitempty"` // shield
	Moved   int     `json:"moved,omitempty"`
	Removed int     `json:"removed,omitempty"`
	Budget  float64 `json:"budget,omitempty"`
	Groups  int     `json:"groups,omitempty"`

	Result float64 `json:"result,omitempty"` // alert shield_hit : résultat net des positions fermées

	DowntimeS     int64 `json:"downtime_s,omitempty"` // alert restarted
	MachineReboot bool  `json:"machine_reboot,omitempty"`

	Mode         string  `json:"mode,omitempty"`   // chameleon, chameleon_outcome : observe
	Reason       string  `json:"reason,omitempty"` // trend ou heavy
	Symbol       string  `json:"symbol,omitempty"`
	Side         string  `json:"side,omitempty"` // buy ou sell
	Volume       float64 `json:"volume,omitempty"`
	Floating     float64 `json:"floating,omitempty"`
	Threshold    float64 `json:"threshold,omitempty"`
	Trend        string  `json:"trend,omitempty"`
	Chg4h        float64 `json:"chg_4h_pct,omitempty"`
	Volatility   string  `json:"volatility,omitempty"`
	CutResult    float64 `json:"cut_result,omitempty"`    // chameleon_outcome
	ActualResult float64 `json:"actual_result,omitempty"` // fermetures du groupe depuis le déclenchement
	Saved        float64 `json:"saved,omitempty"`         // coupe − réel
	ClosedBy     string  `json:"closed_by,omitempty"`     // robot ou kill
	DurationS    int64   `json:"duration_s,omitempty"`
	Episodes     int     `json:"episodes,omitempty"`
	SavedTotal   float64 `json:"saved_total,omitempty"`

	Requested []string `json:"requested,omitempty"` // relaunch : symboles demandés, vide = tous (Watchdog 1.31)

	Param         string  `json:"param,omitempty"` // robot_params, robot_params_refused
	Value         float64 `json:"value,omitempty"`
	Previous      string  `json:"previous,omitempty"`
	ChartsChanged int     `json:"charts_changed,omitempty"`
}

// Types d'événements, niveaux, règles d'arrêt et codes d'alerte du contrat v2.
var (
	EventTypes = []string{"start", "stop", "kill", "kill_ignored", "reset", "reset_refused",
		"reset_ignored", "pause", "pause_ignored", "relaunch", "relaunch_refused", "relaunch_ignored",
		"config", "config_refused", "config_cleared", "robot_params", "robot_params_refused", "shield", "alert",
		"chameleon", "chameleon_outcome", "symbol_pause", "symbol_cut", "symbol_cut_refused",
		"rule_mode", "rule_mode_refused"}
	Levels     = []string{"info", "warning", "critical"}
	KillRules  = []string{"floating_loss", "daily_dd", "giveback", "news", "margin", "manual"}
	AlertCodes = []string{"margin", "algo_off", "algo_on", "calendar_down", "target_missing",
		"manual_intervention", "manual_resolved", "reappeared", "robot_relaunched",
		"restarted", "shield_failed", "shield_off", "shield_hit", "decision"}
)

// Request est le contenu d'un drapeau kill, pause, relaunch ou reset.
type Request struct {
	RequestID string   `json:"request_id"`
	Origin    string   `json:"origin"` // app:<appareil>, telegram, script
	Reason    string   `json:"reason,omitempty"`
	Symbols   []string `json:"symbols,omitempty"` // relaunch : seulement ces symboles (Watchdog 1.31)
}

// CutRequest est le contenu d'un drapeau cut : couper un seul symbole.
type CutRequest struct {
	RequestID string `json:"request_id"`
	Origin    string `json:"origin"`
	Reason    string `json:"reason,omitempty"`
	Symbol    string `json:"symbol"`
}

// RulesRequest est le contenu d'un drapeau rules : la règle choisie pour un
// symbole, parmi RuleModes.
type RulesRequest struct {
	Request
	Symbol string `json:"symbol"`
	Mode   string `json:"mode"`
}

// CompareRequest est le contenu d'un drapeau compare, pour le Lecteur.
type CompareRequest struct {
	RequestID   string   `json:"request_id"`
	Origin      string   `json:"origin"`
	Days        int      `json:"days"`
	JumpLateMin int      `json:"jump_late_min"`
	Magic       int64    `json:"magic"`
	Symbols     []string `json:"symbols"`
}

// Lecteur est le contenu de lecteur.json : pour chaque symbole, ce qu'auraient
// donné les 4 règles sur l'historique. Indicatif (décision 30).
type Lecteur struct {
	V           int             `json:"v"`
	Version     string          `json:"lecteur"`
	RequestID   *string         `json:"request_id"`
	TS          time.Time       `json:"ts"`
	Account     int64           `json:"account"`
	Days        int             `json:"days"`
	JumpLateMin int             `json:"jump_late_min"`
	Magic       int64           `json:"magic"`
	DurationMS  int64           `json:"duration_ms"`
	Error       string          `json:"error"`
	Symbols     []LecteurSymbol `json:"symbols"`
}

// LecteurSymbol : le comparatif d'un symbole. Market : une entrée comme le
// robot à chaque clôture M5, tenue jusqu'au saut suivant, au lot Lot ; Robot :
// ses vrais cycles. Best : la règle au meilleur résultat, d'après BestBy
// (robot s'il y a assez de cycles, sinon market).
type LecteurSymbol struct {
	Symbol string                  `json:"symbol"`
	Error  string                  `json:"error,omitempty"`
	Want   string                  `json:"want,omitempty"`
	Lot    float64                 `json:"lot,omitempty"`
	Jumps  int                     `json:"jumps,omitempty"`
	Market map[string]LecteurTally `json:"market,omitempty"`
	Robot  map[string]LecteurTally `json:"robot,omitempty"`
	Best   string                  `json:"best,omitempty"`
	BestBy string                  `json:"best_by,omitempty"`
}

// LecteurTally : entrées (ou cycles) qu'une règle aurait laissé passer.
type LecteurTally struct {
	N     int     `json:"n"`
	Wins  int     `json:"wins"`
	Total float64 `json:"total"`
}

// ConfigRequest est le contenu d'un drapeau config. Un seuil nil reste inchangé.
type ConfigRequest struct {
	Request
	MarginLevelMin  *float64 `json:"margin_level_min,omitempty"`
	MarginAction    *string  `json:"margin_action,omitempty"`
	MaxFloatingLoss *float64 `json:"max_floating_loss,omitempty"`
	MaxDailyDDPct   *float64 `json:"max_daily_dd_pct,omitempty"`
	MaxGivebackPct  *float64 `json:"max_giveback_pct,omitempty"`
}

// RobotRequest est le contenu d'un drapeau robot : un réglage, une valeur,
// et un symbole facultatif (vide : tous les graphiques du robot).
type RobotRequest struct {
	Request
	Param  string  `json:"param"`
	Value  float64 `json:"value"`
	Symbol string  `json:"symbol,omitempty"`
}

// OffSymbols : symboles gardés pour RELANCER dont le graphique est fermé.
func (s Status) OffSymbols() []string {
	open := map[string]bool{}
	for _, t := range s.Targets {
		open[t.Symbol] = true
	}
	var off []string
	for _, sym := range s.SavedSymbols {
		if !open[sym] {
			off = append(off, sym)
		}
	}
	return off
}

// FullyRunning : le robot tourne sur tous ses graphiques gardés (ou, sans
// liste des symboles, sur au moins un graphique).
func (s Status) FullyRunning() bool {
	if len(s.SavedSymbols) == 0 {
		return s.TargetCharts > 0
	}
	return s.TargetCharts > 0 && len(s.OffSymbols()) == 0
}
