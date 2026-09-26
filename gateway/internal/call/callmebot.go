// Package call passe l'appel d'alerte (décision 24) : un appel vocal
// Telegram par le service gratuit CallMeBot, qui lit le texte à voix haute
// (https://www.callmebot.com/telegram-call-api/). Le destinataire doit
// l'avoir autorisé une fois : /start à @CallMeBot_txtbot. Le texte de
// l'appel passe par les serveurs de CallMeBot.
package call

import (
	"context"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// MaxText : CallMeBot coupe le texte au-delà de 256 caractères.
const MaxText = 256

type CallMeBot struct {
	BaseURL string // https://api.callmebot.com ; autre valeur pour les tests
	Lang    string // voix Google « Standard », ex. fr-FR-Standard-A
	Client  *http.Client
}

func NewCallMeBot() *CallMeBot {
	return &CallMeBot{BaseURL: "https://api.callmebot.com", Lang: "fr-FR-Standard-A",
		Client: &http.Client{Timeout: 30 * time.Second}}
}

var tags = regexp.MustCompile(`<[^>]*>`)

// refusals : mots d'une réponse qui n'a pas lancé l'appel.
var refusals = []string{"authoriz", "authoris", "not allowed", "invalid", "error:"}

// Call lance l'appel vers user (@nom Telegram ou numéro international) et
// renvoie la réponse du service en texte simple, pour la montrer.
func (c *CallMeBot) Call(ctx context.Context, user, text string) (string, error) {
	if r := []rune(text); len(r) > MaxText {
		text = string(r[:MaxText])
	}
	q := url.Values{}
	q.Set("user", user)
	q.Set("text", text)
	q.Set("lang", c.Lang)
	q.Set("rpt", "2")
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.BaseURL+"/start.php?"+q.Encode(), nil)
	if err != nil {
		return "", err
	}
	res, err := c.Client.Do(req)
	if err != nil {
		if ue, ok := err.(*url.Error); ok {
			err = ue.Err
		}
		return "", fmt.Errorf("service d'appel injoignable : %v", err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(res.Body, 16<<10))
	reply := strings.Join(strings.Fields(html.UnescapeString(tags.ReplaceAllString(string(body), " "))), " ")
	if r := []rune(reply); len(r) > 300 {
		reply = string(r[:300]) + "…"
	}
	if res.StatusCode != http.StatusOK {
		return reply, fmt.Errorf("service d'appel : réponse HTTP %d", res.StatusCode)
	}
	low := strings.ToLower(reply)
	for _, w := range refusals {
		if strings.Contains(low, w) {
			return reply, fmt.Errorf("CallMeBot n'a pas lancé l'appel : %s", reply)
		}
	}
	return reply, nil
}
