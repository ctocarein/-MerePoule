package telegram

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestNextRetrait(t *testing.T) {
	for in, want := range map[string]string{
		"2026-09-26 12:00": "2026-09-27 18:00", // samedi
		"2026-09-27 17:59": "2026-09-27 18:00", // dimanche avant l'heure
		"2026-09-27 18:00": "2026-10-04 18:00", // pile : la semaine suivante
		"2026-09-28 09:00": "2026-10-04 18:00", // lundi
	} {
		now, _ := time.Parse("2006-01-02 15:04", in)
		if got := nextRetrait(now).Format("2006-01-02 15:04"); got != want {
			t.Fatalf("après %s : %s, %s attendu", in, got, want)
		}
	}
}

// Sans capital de travail, la Mère propose de le fixer ; une fois fixé,
// elle dit ce qui dépasse, en partant des fonds propres si une perte est en
// cours, et prévient que des positions sont ouvertes.
func TestRetraitCommand(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, func(s map[string]any) {
		s["balance"], s["equity"], s["positions"], s["margin_level"] = 10480.0, 10250.4, 3, 812.5
	})
	f.say(t, me, "/retrait")
	if f.fake.said("Capital de travail pas encore fixé") == nil {
		t.Fatal("sans capital, /retrait doit proposer de le fixer")
	}

	f.say(t, me, "/retrait capital 10 000")
	if f.fake.said("Montant invalide") != nil {
		// « 10 » puis « 000 » pris pour un compte : refusé comme compte inconnu.
		t.Fatal("le montant 10 est valide ; c'est le compte « 000 » qui doit être refusé")
	}
	if f.fake.said("Compte inconnu") == nil {
		t.Fatal("« 000 » n'est pas un compte : refus attendu")
	}

	f.say(t, me, "/retrait capital 10000")
	if f.fake.said("Capital de travail : 10000,00") == nil {
		t.Fatal("le capital doit être confirmé")
	}
	if v, _ := f.st.ChatPref(me, capitalKey(account)); v != "10000.00" {
		t.Fatalf("capital non enregistré : %q", v)
	}

	f.say(t, me, "/retrait")
	body := f.fake.said("Retrait de la semaine")
	text, _ := body["text"].(string)
	// 10250,40 de fonds propres (perte en cours) - 10000 = 250,40.
	for _, want := range []string{"À retirer : 250,40", "3 position(s) ouverte(s)", "de 812 % à 793 %", "TRC20"} {
		if !strings.Contains(text, want) {
			t.Fatalf("manque %q :\n%s", want, text)
		}
	}
}

func TestRetraitBelowCapitalAndTooSmall(t *testing.T) {
	f := newFixture(t)
	f.setStatus(t, func(s map[string]any) {
		s["balance"], s["equity"], s["positions"] = 9800.0, 9800.0, 0
	})
	f.say(t, me, "/retrait capital 10000")
	f.say(t, me, "/retrait")
	if f.fake.said("Rien à retirer</b> : le compte est 200,00 sous") == nil {
		t.Fatal("sous le capital : rien à retirer")
	}
	f.setStatus(t, func(s map[string]any) {
		s["balance"], s["equity"], s["positions"] = 10005.0, 10005.0, 0
	})
	f.say(t, me, "/retrait")
	if f.fake.said("Excédent 5,00</b> : trop petit") == nil {
		t.Fatal("un excédent de 5 est trop petit pour un retrait")
	}
	f.setStatus(t, func(s map[string]any) {
		s["balance"], s["equity"], s["positions"] = 10300.0, 10300.0, 0
	})
	f.say(t, me, "/retrait")
	body := f.fake.said("À retirer : 300,00")
	if body == nil {
		t.Fatal("excédent de 300 attendu")
	}
	if text, _ := body["text"].(string); strings.Contains(text, "position(s) ouverte(s)") {
		t.Fatal("pas d'avertissement sans position ouverte")
	}
}

func TestRetraitPublishAndOff(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	f.bot.publishRetrait(ctx)
	if f.fake.count("Retrait de la semaine") != 1 {
		t.Fatal("le point du dimanche doit partir par défaut")
	}
	f.say(t, me, "/retrait off")
	f.bot.publishRetrait(ctx)
	if n := f.fake.count("Retrait de la semaine"); n != 1 {
		t.Fatalf("%d points après /retrait off, 1 attendu", n)
	}
	f.say(t, me, "/retrait on")
	f.bot.publishRetrait(ctx)
	if n := f.fake.count("Retrait de la semaine"); n != 2 {
		t.Fatalf("%d points après /retrait on, 2 attendus", n)
	}
}
