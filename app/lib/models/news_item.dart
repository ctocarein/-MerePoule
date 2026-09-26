enum NewsCategory { forex, indices, macro }

/// Onglets de l'Actualité.
enum NewsFilter {
  all('Toutes', null),
  forex('Forex', NewsCategory.forex),
  indices('Indices', NewsCategory.indices),
  macro('Macro', NewsCategory.macro);

  const NewsFilter(this.label, this.category);

  final String label;
  final NewsCategory? category;

  bool accepts(NewsItem item) => category == null || item.category == category;
}

enum NewsKind { market, calendar, volatility }

class NewsItem {
  const NewsItem({
    required this.category,
    required this.kind,
    required this.title,
    required this.text,
  });

  final NewsCategory category;
  final NewsKind kind;
  final String title;
  final String text;
}
