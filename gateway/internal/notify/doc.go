// Package notify : alertes émises par la passerelle elle-même. La vigie
// signale un Watchdog muet (MT5 planté ou fermé, qui ne peut rien envoyer)
// et son retour. Les alertes partent vers des Sink : le bot Telegram
// aujourd'hui, le push Firebase ensuite.
package notify
