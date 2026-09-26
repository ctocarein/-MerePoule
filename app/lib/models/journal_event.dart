enum JournalKind { stop, alert, shield, restart, command }

/// Onglets du Journal.
enum JournalFilter {
  all('Tout'),
  stops('Arrêts'),
  alerts('Alertes'),
  commands('Commandes');

  const JournalFilter(this.label);

  final String label;

  bool accepts(JournalKind kind) => switch (this) {
    JournalFilter.all => true,
    JournalFilter.stops => kind == JournalKind.stop,
    JournalFilter.alerts =>
      kind == JournalKind.alert ||
          kind == JournalKind.shield ||
          kind == JournalKind.restart,
    JournalFilter.commands => kind == JournalKind.command,
  };
}

class JournalEvent {
  const JournalEvent({
    required this.kind,
    required this.title,
    required this.detail,
    required this.time,
  });

  final JournalKind kind;
  final String title;
  final String detail;
  final DateTime time;
}
