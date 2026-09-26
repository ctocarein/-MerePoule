package call

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestCallMeBot(t *testing.T) {
	var got map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		got = map[string]string{"path": r.URL.Path, "user": q.Get("user"), "text": q.Get("text"), "lang": q.Get("lang")}
		if q.Get("user") == "@inconnu" {
			w.Write([]byte("<html><body><p>You need to authorize CallMeBot to call you.</p></body></html>"))
			return
		}
		w.Write([]byte("<html><body><b>Call queued</b> to @richmond</body></html>"))
	}))
	defer srv.Close()
	c := NewCallMeBot()
	c.BaseURL = srv.URL

	reply, err := c.Call(context.Background(), "@richmond", "Alerte Mère Poule : la perte en cours atteint 305.")
	if err != nil || reply != "Call queued to @richmond" {
		t.Fatalf("appel : %q %v", reply, err)
	}
	if got["path"] != "/start.php" || got["user"] != "@richmond" || got["lang"] != "fr-FR-Standard-A" ||
		!strings.Contains(got["text"], "Mère Poule") {
		t.Fatalf("requête inattendue : %v", got)
	}

	if _, err := c.Call(context.Background(), "@inconnu", "test"); err == nil || !strings.Contains(err.Error(), "authorize") {
		t.Fatalf("un appel non autorisé doit être une erreur : %v", err)
	}

	c.Call(context.Background(), "@richmond", strings.Repeat("é", 400))
	if n := utf8.RuneCountInString(got["text"]); n != MaxText {
		t.Fatalf("texte de %d caractères, %d au plus", n, MaxText)
	}
}
