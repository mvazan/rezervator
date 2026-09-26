import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/local_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('parse: known names, anything else is Souboje', () {
    expect(parseMatchDetailView('zapis'), MatchDetailView.zapis);
    expect(parseMatchDetailView('souboje'), MatchDetailView.souboje);
    expect(parseMatchDetailView(null), MatchDetailView.souboje);
    expect(parseMatchDetailView('x'), MatchDetailView.souboje);
  });

  test('defaults to Souboje, loads the saved choice, saves a new one', () async {
    SharedPreferences.setMockInitialValues({'match_detail_view': 'zapis'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(matchDetailViewProvider), MatchDetailView.souboje);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(matchDetailViewProvider), MatchDetailView.zapis);

    await container.read(matchDetailViewProvider.notifier).set(MatchDetailView.souboje);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('match_detail_view'), 'souboje');
  });
}
