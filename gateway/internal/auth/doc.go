// Package auth : jetons d'appareil, codes d'enrôlement et PIN.
//
// Les jetons et les codes ne sont jamais stockés en clair : seule leur
// empreinte SHA-256 est en base. Le PIN, choisi par le trader à
// l'enrôlement, est haché avec Argon2id ; 5 échecs par heure et par appareil
// bloquent les actions qui l'exigent (relance, réarmement, seuils).
//
// L'identité Tailscale de l'appelant s'ajoutera avec tsnet.
package auth
