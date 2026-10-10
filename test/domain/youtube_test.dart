import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/youtube.dart';

void main() {
  const id = 'wOq9EODb8w8';

  group('youtubeVideoId', () {
    for (final (url, why) in [
      ('https://www.youtube.com/watch?v=$id', 'the watch link the site hands out'),
      ('https://youtube.com/watch?t=42&v=$id&feature=share', 'other parameters around v'),
      ('https://m.youtube.com/watch?v=$id', 'the mobile host'),
      ('https://youtu.be/$id?t=10', 'the short host'),
      ('https://www.youtube.com/live/$id?feature=share', 'a live link'),
      ('https://www.youtube.com/embed/$id', 'an embed link'),
      ('https://www.youtube.com/shorts/$id', 'a short'),
      ('youtube.com/watch?v=$id', 'no scheme'),
      ('  https://www.youtube.com/watch?v=$id  ', 'surrounding whitespace'),
    ]) {
      test('finds the id in $why', () {
        expect(youtubeVideoId(url), id);
      });
    }

    for (final (url, why) in [
      ('https://www.youtube.com/watch?v=short', 'an id shorter than 11'),
      ('https://www.youtube.com/watch?v=${id}X', 'an id longer than 11'),
      ('https://www.youtube.com/watch', 'no v at all'),
      ('https://www.youtube.com/channel/UC12345678901', 'a channel'),
      ('https://www.youtube.com/', 'the home page'),
      ('https://vimeo.com/123456789', 'another site'),
      ('https://example.com/watch?v=$id', 'a watch link elsewhere'),
      ('', 'nothing'),
      ('not a link', 'no link'),
    ]) {
      test('has no id for $why', () {
        expect(youtubeVideoId(url), isNull);
      });
    }
  });

  test('the embed address: privacy domain, muted autoplay, no fullscreen, '
      'no related videos', () {
    expect(
      youtubeEmbedUrl(id),
      'https://www.youtube-nocookie.com/embed/$id'
      '?autoplay=1&mute=1&playsinline=1&controls=1&fs=0&rel=0&modestbranding=1',
    );
  });

  test('the host page embeds the address, lets it autoplay and sandboxes '
      'its links', () {
    final page = kioskStreamHostPage(youtubeEmbedUrl(id));
    expect(page, contains('src="${youtubeEmbedUrl(id)}"'));
    expect(page, contains('allow="autoplay;'));
    expect(page, contains('sandbox="allow-scripts allow-same-origin'));
    expect(page, isNot(contains('allow-popups')));
    expect(page, isNot(contains('allow-top-navigation')));
    expect(kioskStreamHostOrigin, startsWith('https://'));
  });
}
