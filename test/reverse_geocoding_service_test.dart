import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/services/reverse_geocoding_service.dart';

const _lat = 4.6015;
const _lon = -74.0661;
const _address = 'Universidad de los Andes, Bogotá, Colombia';

/// The Hive box, in memory.
class _FakeLocal implements LocalDataSource {
  final Map<String, String> addresses = {};

  @override
  String? getAddress(String coordinatesKey) => addresses[coordinatesKey];

  @override
  Future<void> cacheAddress(String coordinatesKey, String address) async =>
      addresses[coordinatesKey] = address;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeLocal local;
  late List<http.Request> requests;
  late bool offline;
  late int statusCode;
  late ReverseGeocodingService service;

  setUp(() {
    local = _FakeLocal();
    requests = [];
    offline = false;
    statusCode = 200;
    service = ReverseGeocodingService(
      localDataSource: local,
      client: MockClient((request) async {
        requests.add(request);
        if (offline) throw http.ClientException('Failed host lookup');
        return http.Response(
          jsonEncode({'display_name': _address}),
          statusCode,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
  });

  test('online: asks Nominatim in Spanish, identified, and keeps the answer', () async {
    expect(await service.addressFor(_lat, _lon), _address);

    final request = requests.single;
    expect(request.url.queryParameters['accept-language'], 'es');
    expect(request.headers['User-Agent'], startsWith('SidequestsApp/'));
    expect(local.addresses.values, [_address]);
  });

  test('seen once online: shown offline too, without another request', () async {
    await service.addressFor(_lat, _lon);
    offline = true;

    expect(await service.addressFor(_lat, _lon), _address);
    expect(requests, hasLength(1));
  });

  test('offline and never seen: hidden, and the failure is not stored', () async {
    offline = true;
    expect(await service.addressFor(_lat, _lon), isNull);
    expect(local.addresses, isEmpty);

    offline = false;
    expect(await service.addressFor(_lat, _lon), _address);
  });

  test('an error answer (rate limit) is not stored either', () async {
    statusCode = 429;

    expect(await service.addressFor(_lat, _lon), isNull);
    expect(local.addresses, isEmpty);
  });

  test('the same point with float noise reuses the stored address', () async {
    await service.addressFor(_lat, _lon);

    expect(await service.addressFor(_lat + 1e-9, _lon - 1e-9), _address);
    expect(requests, hasLength(1));
  });
}
