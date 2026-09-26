package contract

import (
	"bufio"
	"bytes"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

// Les exemples de contract/ sont la référence partagée avec le Watchdog :
// ils doivent se lire sans perte avec les types Go.
const examples = "../../../contract/examples"

func readExample(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(examples, name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// decodeStrict refuse tout champ que les types Go ne connaissent pas.
func decodeStrict(t *testing.T, data []byte, v any) {
	t.Helper()
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		t.Fatal(err)
	}
}

func TestStatusExample(t *testing.T) {
	var s Status
	decodeStrict(t, readExample(t, "status.json"), &s)

	if s.V != 2 || s.Account != 123456 || s.State != "RUN" {
		t.Fatalf("en-tête inattendu : v=%d account=%d state=%s", s.V, s.Account, s.State)
	}
	if s.Config.MaxFloatingLoss != 440 || s.Config.Caps.MaxFloatingLoss != 880 {
		t.Fatalf("seuils inattendus : %+v", s.Config)
	}
	if s.LastKill.At != nil || s.News.Label != nil {
		t.Fatal("les null doivent rester nil")
	}
	if len(s.Symbols) != 1 || s.Symbols[0].SellVolume != 0.6 || len(s.Targets) != s.TargetCharts {
		t.Fatalf("exposition ou graphiques incohérents : %+v %+v", s.Symbols, s.Targets)
	}
	if s.Chameleon.Mode != "observe" || s.Chameleon.Threshold != 110 || s.Chameleon.HeavyThreshold != 220 || len(s.Chameleon.Open) != 1 ||
		s.Chameleon.Open[0].Side != "sell" || s.Chameleon.Open[0].Reason != "trend" || s.Chameleon.ByReason["heavy"].Episodes != 1 {
		t.Fatalf("Caméléon inattendu : %+v", s.Chameleon)
	}
	if len(s.Market) != 1 || s.Market[0].Trend != "hausse" || s.Market[0].Volatility == "" || s.Market[0].RobotSide != "sell" ||
		s.Market[0].Rule != "interdit" || s.Market[0].Want != "sell" || s.Market[0].M5 != "hausse" {
		t.Fatalf("marché inattendu : %+v", s.Market)
	}
	if s.Targets[0].Inputs["InpParamL1"] != "0.2" || len(s.RobotParams) != 1 || s.RobotParams[0].Max != 0.5 {
		t.Fatalf("réglages du robot inattendus : %+v %+v", s.Targets, s.RobotParams)
	}
	m := s.Market[0]
	if m.RuleMode != "trend" || m.JumpAgeMin != 12 || m.JumpLate || m.Allowed == nil || m.Go() || s.Config.JumpLateMin != 40 {
		t.Fatalf("règle choisie (1.34) inattendue : %+v %d", m, s.Config.JumpLateMin)
	}
	if !s.Shield.Active || s.Shield.Budget != 2*s.Config.MaxFloatingLoss {
		t.Fatalf("Bouclier : budget par défaut attendu à 2 fois la perte flottante, %+v", s.Shield)
	}
	if s.Stale(s.TS.Add(StaleAfter)) {
		t.Fatal("statut périmé trop tôt")
	}
	if !s.Stale(s.TS.Add(StaleAfter + time.Second)) {
		t.Fatal("statut non périmé après 6 s")
	}
}

func TestEventsExample(t *testing.T) {
	sc := bufio.NewScanner(bytes.NewReader(readExample(t, "events.jsonl")))
	var prev int64
	n := 0
	for sc.Scan() {
		var e Event
		decodeStrict(t, sc.Bytes(), &e)
		n++

		if e.V != 2 || e.Account != 123456 {
			t.Fatalf("seq %d : en-tête inattendu", e.Seq)
		}
		if prev != 0 && e.Seq != prev+1 {
			t.Fatalf("seq %d après %d : le journal doit croître de 1", e.Seq, prev)
		}
		prev = e.Seq
		if !slices.Contains(EventTypes, e.Type) || !slices.Contains(Levels, e.Level) {
			t.Fatalf("seq %d : type %q ou niveau %q hors contrat", e.Seq, e.Type, e.Level)
		}
		switch e.Type {
		case "chameleon":
			if e.Mode != "observe" || e.Symbol == "" || (e.Side != "buy" && e.Side != "sell") || e.Floating >= 0 || e.Trend == "" ||
				(e.Reason != "trend" && e.Reason != "heavy") {
				t.Fatalf("seq %d : Caméléon incomplet", e.Seq)
			}
		case "chameleon_outcome":
			if e.Symbol == "" || (e.Reason != "trend" && e.Reason != "heavy") || (e.ClosedBy != "robot" && e.ClosedBy != "kill") || math.Abs(e.Saved-(e.CutResult-e.ActualResult)) > 0.011 {
				t.Fatalf("seq %d : bilan du Caméléon incohérent", e.Seq)
			}
		case "kill":
			if !slices.Contains(KillRules, e.Rule) || e.RequestID == nil {
				t.Fatalf("seq %d : kill sans règle connue ou sans request_id", e.Seq)
			}
			if len(e.Exposure) == 0 || len(e.Market) == 0 {
				t.Fatalf("seq %d : kill sans exposition ni marché", e.Seq)
			}
		case "alert":
			if !slices.Contains(AlertCodes, e.Code) {
				t.Fatalf("seq %d : code d'alerte %q hors contrat", e.Seq, e.Code)
			}
			if e.Code == "restarted" && e.DowntimeS <= 0 {
				t.Fatalf("seq %d : redémarrage sans durée d'arrêt", e.Seq)
			}
			if e.Code == "shield_hit" && (e.Positions == 0 || e.Result == 0) {
				t.Fatalf("seq %d : stop loss du Bouclier sans positions ni résultat", e.Seq)
			}
		case "pause", "relaunch":
			if e.RequestID == nil || e.Charts == 0 {
				t.Fatalf("seq %d : %s sans request_id ou sans graphiques", e.Seq, e.Type)
			}
		case "robot_params":
			if e.Param == "" || e.Previous == "" || e.ChartsChanged == 0 || e.RequestID == nil {
				t.Fatalf("seq %d : réglage du robot incomplet", e.Seq)
			}
		case "shield":
			if e.Placed+e.Removed == 0 || e.Budget <= 0 || e.Groups == 0 {
				t.Fatalf("seq %d : bilan du Bouclier incomplet", e.Seq)
			}
		case "rule_mode":
			if e.Symbol == "" || !slices.Contains(RuleModes, e.Mode) || !slices.Contains(RuleModes, e.Previous) || e.RequestID == nil {
				t.Fatalf("seq %d : choix de règle incomplet", e.Seq)
			}
		case "config":
			if e.Config == nil || e.Config.Source != "remote" {
				t.Fatalf("seq %d : config sans seuils actifs", e.Seq)
			}
		}
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	if n == 0 {
		t.Fatal("aucun événement lu")
	}
}

func TestFlagExamples(t *testing.T) {
	for _, name := range []string{"kill.flag", "pause.flag", "relaunch.flag", "reset.flag"} {
		var r Request
		decodeStrict(t, readExample(t, name), &r)
		if r.RequestID == "" || r.Origin == "" {
			t.Fatalf("%s : request_id et origin obligatoires", name)
		}
	}

	var cr CutRequest
	decodeStrict(t, readExample(t, "cut.flag"), &cr)
	if cr.Symbol != "MAX GainX 2000" || cr.RequestID == "" {
		t.Fatalf("cut.flag inattendu : %+v", cr)
	}

	var rr RobotRequest
	decodeStrict(t, readExample(t, "robot.flag"), &rr)
	if rr.Param != "InpParamL1" || rr.Value != 0.3 || rr.RequestID == "" {
		t.Fatalf("robot.flag inattendu : %+v", rr)
	}

	var c ConfigRequest
	decodeStrict(t, readExample(t, "config.flag"), &c)
	if c.MaxFloatingLoss == nil || *c.MaxFloatingLoss != 300 || c.MaxDailyDDPct != nil {
		t.Fatalf("config.flag : seuils inattendus %+v", c)
	}
}

func TestRulesAndLecteurExamples(t *testing.T) {
	var rr RulesRequest
	decodeStrict(t, readExample(t, "rules.flag"), &rr)
	if rr.Symbol != "MAX PainX 1000" || !slices.Contains(RuleModes, rr.Mode) || rr.RequestID == "" {
		t.Fatalf("rules.flag inattendu : %+v", rr)
	}
	var cr CompareRequest
	decodeStrict(t, readExample(t, "compare.flag"), &cr)
	if cr.Days != 30 || cr.JumpLateMin != 40 || len(cr.Symbols) != 2 || cr.RequestID == "" {
		t.Fatalf("compare.flag inattendu : %+v", cr)
	}
	var l Lecteur
	decodeStrict(t, readExample(t, "lecteur.json"), &l)
	if l.RequestID == nil || *l.RequestID != cr.RequestID || len(l.Symbols) != 3 || l.Error != "" {
		t.Fatalf("lecteur.json inattendu : %+v", l)
	}
	for _, s := range l.Symbols {
		if s.Error != "" {
			continue
		}
		if !slices.Contains(RuleModes, s.Best) || (s.BestBy != "market" && s.BestBy != "robot") || len(s.Market) != 4 || len(s.Robot) != 4 {
			t.Fatalf("%s : comparatif incomplet %+v", s.Symbol, s)
		}
		for _, mode := range RuleModes {
			if s.Market[mode].N > s.Market["none"].N || s.Robot[mode].N > s.Robot["none"].N {
				t.Fatalf("%s : %s ne peut garder plus d'entrées qu'aucune règle", s.Symbol, mode)
			}
		}
	}
}

// Avant 1.34, le verdict est celui de la règle tendance.
func TestMarketGoFallsBackToTrend(t *testing.T) {
	yes, no := true, false
	cases := []struct {
		m    Market
		want bool
	}{
		{Market{Rule: "autorise"}, true},
		{Market{Rule: "interdit"}, false},
		{Market{Rule: "interdit", Allowed: &yes}, true},
		{Market{Rule: "autorise", Allowed: &no}, false},
	}
	for _, c := range cases {
		if c.m.Go() != c.want {
			t.Fatalf("%+v : Go() = %v", c.m, !c.want)
		}
	}
}
