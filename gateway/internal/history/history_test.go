package history

import (
	"testing"
	"time"

	"merepoule/gateway/internal/store"
)

func TestResults(t *testing.T) {
	day := func(d, h int) time.Time { return time.Date(2026, 9, d, h, 0, 0, 0, time.UTC) }
	points := []store.Sample{
		{TS: day(21, 8), Balance: 1000}, // lundi
		{TS: day(21, 20), Balance: 1100},
		{TS: day(22, 9), Balance: 1050},
		{TS: day(28, 9), Balance: 1200}, // lundi suivant
	}
	days := results(points, func(t time.Time) time.Time { return t.Truncate(24 * time.Hour) })
	if len(days) != 3 || days[0].Result != 100 || days[1].Result != -50 || days[2].Result != 150 {
		t.Fatalf("résultats par jour inattendus : %+v", days)
	}
	weeks := results(points, weekStart)
	if len(weeks) != 2 || weeks[0].Result != 50 || weeks[1].Result != 150 || !weeks[0].Start.Equal(day(21, 0)) {
		t.Fatalf("résultats par semaine inattendus : %+v", weeks)
	}
}
