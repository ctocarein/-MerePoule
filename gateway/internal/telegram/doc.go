// Package telegram : canal de secours de la passerelle, par le bot Telegram.
//
// La passerelle interroge Telegram en sortie (getUpdates) : aucun port ouvert.
// Seuls les chats autorisés sont servis, chacun pour ses comptes :
//
//	/etat           état de chaque compte (lecture seule)
//	/kill [compte]  arrêt d'urgence, après un bouton « Confirmer » valable 60 s
//	/aide           rappel des commandes
//
// Aucun réarmement, aucune relance ni aucun changement de seuil ne passe par
// Telegram. Un /kill envoyé pendant un arrêt de la passerelle est écarté au
// démarrage. Un bot par passerelle : Telegram n'accepte qu'un lecteur
// getUpdates par bot ; les Watchdogs, qui ne font qu'envoyer, peuvent
// partager ce bot.
package telegram
