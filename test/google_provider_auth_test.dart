import 'package:flutter_test/flutter_test.dart';

import 'package:cubiclm/services/cloud/providers/google_provider.dart';

void main() {
  group('GoogleProvider API key handling', () {
    final provider = GoogleProvider();

    test('sends API key through the Google auth header', () {
      expect(
        provider.buildAuthHeaders('AQ.example-key'),
        {'x-goog-api-key': 'AQ.example-key'},
      );
    });

    test('model-list URL does not expose API key in query string', () {
      final urls = provider.getModelListCandidates('AQ.example-key');
      expect(urls, [
        'https://generativelanguage.googleapis.com/v1beta/models',
      ]);
      expect(urls.join(), isNot(contains('AQ.example-key')));
      expect(urls.join(), isNot(contains('?key=')));
    });
  });
}
