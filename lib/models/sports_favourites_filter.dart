/// Result scope is independent of saved favourites and sport/date filters.
enum SportsFavouritesFilter {
  all,
  favourites,
  leagues,
  teams;

  bool get isFiltered => this != all;
  bool get includesLeagues => this == favourites || this == leagues;
  bool get includesTeams => this == favourites || this == teams;

  String get label => switch (this) {
        all => 'All',
        favourites => 'Favourites',
        leagues => 'Favourite leagues',
        teams => 'Favourite teams & athletes',
      };

  String get description => switch (this) {
        all => 'All results, whether saved as favourites or not',
        favourites => 'Your leagues, teams and athletes together',
        leagues => 'All results from your favourite leagues',
        teams => 'Only your favourite teams and athletes, in any league',
      };

  String get shortLabel => switch (this) {
        all => 'All',
        favourites => 'Favourites',
        leagues => 'Leagues',
        teams => 'Teams',
      };

  String? emptySelectionMessage(
      {required bool hasLeagues, required bool hasTeams}) {
    if (!isFiltered ||
        (includesLeagues && hasLeagues) ||
        (includesTeams && hasTeams)) {
      return null;
    }
    return switch (this) {
      leagues => 'No favourite leagues yet',
      teams => 'No favourite teams or athletes yet',
      _ => 'No favourites yet',
    };
  }
}
