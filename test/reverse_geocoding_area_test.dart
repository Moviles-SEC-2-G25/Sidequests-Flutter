import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/services/reverse_geocoding_service.dart';

class _NoLocal implements LocalDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// "📍 Cerca de: ..." (mirror of the Kotlin app's NominatimAddressProvider).
void main() {
  test('short area: road, neighbourhood, city', () {
    expect(
      ReverseGeocodingService.formatArea({
        'address': {'road': 'Carrera 1', 'suburb': 'La Candelaria', 'city': 'Bogotá'},
        'display_name': 'long, display, name, Colombia',
      }),
      'Carrera 1, La Candelaria, Bogotá',
    );
  });

  test('without address details: the first three parts of display_name', () {
    expect(
      ReverseGeocodingService.formatArea({'display_name': 'Uniandes, Carrera 1, Bogotá, Colombia'}),
      'Uniandes, Carrera 1, Bogotá',
    );
    expect(ReverseGeocodingService.formatArea({}), isNull);
  });

  test('the same area (~100 m) is resolved once; requests are spaced out', () async {
    final requestTimes = <DateTime>[];
    final service = ReverseGeocodingService(
      localDataSource: _NoLocal(),
      minInterval: const Duration(milliseconds: 200),
      client: MockClient((request) async {
        requestTimes.add(DateTime.now());
        expect(request.url.queryParameters['addressdetails'], '1');
        expect(request.headers['User-Agent'], startsWith('SidequestsApp/'));
        return http.Response(
          jsonEncode({
            'address': {'road': 'Calle ${requestTimes.length}', 'city': 'Bogotá'},
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final results = await Future.wait([
      service.areaFor(4.60100, -74.06600),
      service.areaFor(4.60300, -74.06600),
    ]);
    final sameArea = await service.areaFor(4.60104, -74.06604);

    expect(results, ['Calle 1, Bogotá', 'Calle 2, Bogotá']);
    expect(sameArea, 'Calle 1, Bogotá');
    expect(requestTimes, hasLength(2));
    expect(
      requestTimes[1].difference(requestTimes[0]),
      greaterThanOrEqualTo(const Duration(milliseconds: 190)),
    );
  });

  test('a failure returns null and is not cached', () async {
    var offline = true;
    final service = ReverseGeocodingService(
      localDataSource: _NoLocal(),
      minInterval: Duration.zero,
      client: MockClient((request) async {
        if (offline) throw http.ClientException('Failed host lookup');
        return http.Response(jsonEncode({'address': {'road': 'Calle 9'}}), 200);
      }),
    );

    expect(await service.areaFor(4.6, -74.06), isNull);
    offline = false;
    expect(await service.areaFor(4.6, -74.06), 'Calle 9');
  });
}
