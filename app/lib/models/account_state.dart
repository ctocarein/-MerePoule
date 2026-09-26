/// État du compte tenu par le Watchdog (champ `state` du statut).
enum AccountState {
  run('RUN', 'En marche', 'Le robot trade, MerePoule surveille.'),
  pause('PAUSE', 'En pause', 'Robot en pause. Les positions restent ouvertes.'),
  kill('KILL', 'Arrêté', 'Robot arrêté et positions fermées.');

  const AccountState(this.code, this.label, this.meaning);

  /// Valeur écrite par le Watchdog, affichée en grand sur l'Accueil.
  final String code;

  /// Mot court pour une pastille.
  final String label;

  /// Phrase pour un profane.
  final String meaning;

  static AccountState? parse(String? code) {
    for (final state in values) {
      if (state.code == code) return state;
    }
    return null;
  }
}

/// Couleur du bandeau de confiance (spécification, Composant 3).
enum TrustLevel {
  /// Statut de moins de 5 s : vert.
  live('Données à jour', null),

  /// Passerelle joignable, Watchdog muet : orange.
  watchdogSilent(
    'La surveillance ne répond plus',
    'Les chiffres peuvent être dépassés. Ouvrez MT5 sur la machine de trading.',
  ),

  /// Passerelle injoignable : rouge.
  unreachable(
    'Machine de trading injoignable',
    'Vérifiez que Tailscale est connecté sur ce téléphone.',
  );

  const TrustLevel(this.title, this.advice);

  final String title;

  /// Que faire, quand il y a quelque chose à faire.
  final String? advice;
}
