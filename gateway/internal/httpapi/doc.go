// Package httpapi : l'API /api/v1 de la passerelle (architecture,
// « Endpoints »). Jeton d'appareil sur chaque route sauf /health et
// l'enrôlement ; comptes filtrés par appareil ; PIN pour la relance, le
// réarmement, les seuils et la révocation d'un autre appareil.
//
// Module « http » de l'architecture, renommé pour ne pas masquer net/http.
// Écoute en local tant que tsnet n'est pas branché.
package httpapi
