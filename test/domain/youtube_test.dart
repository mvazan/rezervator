import 'dart:convert';

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
      'no related videos, talking to the page that embeds it', () {
    expect(
      youtubeEmbedUrl(id, origin: 'https://rezervator.online'),
      'https://www.youtube-nocookie.com/embed/$id'
      '?autoplay=1&mute=1&playsinline=1&controls=1&fs=0&rel=0&modestbranding=1'
      '&enablejsapi=1&origin=https%3A%2F%2Frezervator.online',
    );
    expect(youtubeEmbedUrl(id, origin: 'x').startsWith(youtubeEmbedOrigin),
        isTrue);
  });

  test('the host page embeds the address, lets it autoplay and sandboxes '
      'its links', () {
    final url = youtubeEmbedUrl(id, origin: kioskStreamHostOrigin);
    final page = kioskStreamHostPage(url);
    expect(page, contains('src="$url"'));
    expect(page, contains('allow="autoplay;'));
    expect(page, contains('sandbox="allow-scripts allow-same-origin'));
    expect(page, isNot(contains('allow-popups')));
    expect(page, isNot(contains('allow-top-navigation')));
    expect(kioskStreamHostOrigin, startsWith('https://'));
  });

  test('the host page says hello to the player and passes its state '
      'changes to the app', () {
    final page = kioskStreamHostPage(
      youtubeEmbedUrl(id, origin: kioskStreamHostOrigin),
    );
    for (final hello in youtubeHello('1')) {
      // As a JS string literal inside the page's hello list.
      expect(page, contains(jsonEncode(hello)));
    }
    expect(page, contains("'$youtubeEmbedOrigin'"));
    expect(page, contains('$kioskStreamChannel.postMessage'));
  });

  group('the player talking back', () {
    String msg(Map<String, Object?> m) => jsonEncode(m);

    test('hello: listening, then a subscription to state changes, both '
        'carrying the id', () {
      final hello = [for (final h in youtubeHello('7')) jsonDecode(h)];
      expect(hello, [
        {'event': 'listening', 'id': '7', 'channel': 'widget'},
        {
          'event': 'command',
          'func': 'addEventListener',
          'args': ['onStateChange'],
          'id': '7',
          'channel': 'widget',
        },
      ]);
    });

    test('ended: a state change to 0, or a delivery of player state 0', () {
      expect(
        youtubeEndedId(msg({'event': 'onStateChange', 'info': 0, 'id': '7'})),
        '7',
      );
      expect(
        youtubeEndedId(
          msg({
            'event': 'infoDelivery',
            'info': {'playerState': 0, 'currentTime': 5400.2},
            'id': 3,
            'channel': 'widget',
          }),
        ),
        '3',
      );
    });

    test('any message with an id says the player heard the hello', () {
      expect(youtubePlayerId(msg({'event': 'onReady', 'id': '7'})), '7');
      expect(youtubePlayerId(msg({'event': 'initialDelivery', 'id': 2})), '2');
      expect(youtubePlayerId(msg({'event': 'onReady'})), isNull);
      expect(youtubePlayerId('nope'), isNull);
      expect(youtubePlayerId(null), isNull);
    });

    test('anything else is not an end', () {
      for (final data in <Object?>[
        msg({'event': 'onStateChange', 'info': 1, 'id': '7'}),
        msg({'event': 'onStateChange', 'info': 2, 'id': '7'}),
        msg({
          'event': 'infoDelivery',
          'info': {'currentTime': 12.5},
          'id': '7',
        }),
        msg({'event': 'onReady', 'id': '7'}),
        msg({'event': 'onStateChange', 'info': 0}),
        msg({
          'event': 'infoDelivery',
          'info': {'playerState': '0'},
          'id': '7',
        }),
        '[0]',
        'not json',
        null,
        42,
      ]) {
        expect(youtubeEndedId(data), isNull, reason: '$data');
      }
    });
  });
}
