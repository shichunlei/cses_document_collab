import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cses_mobile_collab_demo/src/service/cses_weather_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实源协议转换、请求隔离、缓存合流、刷新绕过与失败资源释放。
void main() {
  test('current/historical data use finite real temperatures and WMO tones', () {
    expect(
      parseCsesWeather(
        {
          'current': {'temperature_2m': 22.4, 'weather_code': 95},
        },
        '北京',
        historical: false,
      ).tone,
      'stormy',
    );
    final historical = parseCsesWeather(
      {
        'daily': {
          'temperature_2m_max': [26],
          'temperature_2m_min': [10],
          'weather_code': [71],
        },
      },
      '北京',
      historical: true,
    );
    expect(historical.temp, 18);
    expect(historical.tone, 'snowy');
    for (final value in [
      null,
      {},
      {
        'current': {'temperature_2m': double.nan},
      },
    ]) {
      expect(() => parseCsesWeather(value, '北京', historical: false), throwsFormatException);
    }
  });

  test('same anchor coalesces, success caches, refresh bypasses and each client closes', () async {
    final clients = <_WeatherTransport>[];
    final ready = Completer<void>();
    final service = CsesWeatherService(
      createClient: () {
        final transport = _WeatherTransport(wait: clients.isEmpty ? ready.future : null);
        clients.add(transport);
        return Dio()..httpClientAdapter = transport;
      },
    );
    final first = service.load(refresh: false, cancelled: () => false);
    final second = service.load(refresh: false, cancelled: () => false);
    expect(clients, hasLength(1));
    ready.complete();
    final values = await Future.wait([first, second]);
    expect(values.first.temp, 22);
    expect(clients.single.calls, 2);
    expect(clients.single.closed, isTrue);
    await service.load(refresh: false, cancelled: () => false);
    expect(clients, hasLength(1));
    await service.load(refresh: true, cancelled: () => false);
    expect(clients, hasLength(2));
    expect(clients.last.closed, isTrue);
    expect(
      clients
          .expand((c) => c.headers)
          .every((h) => !h.keys.any((k) => {'cookie', 'authorization', 'baggage'}.contains(k.toLowerCase()))),
      isTrue,
    );
  });

  test('failed weather never caches fake data and cancelled caller cannot receive result', () async {
    final transports = <_WeatherTransport>[];
    final service = CsesWeatherService(
      createClient: () {
        final transport = _WeatherTransport(fail: true);
        transports.add(transport);
        return Dio()..httpClientAdapter = transport;
      },
    );
    for (var i = 0; i < 2; i++) {
      await expectLater(service.load(refresh: false, cancelled: () => false), throwsFormatException);
    }
    expect(transports, hasLength(2));
    expect(transports.every((c) => c.closed), isTrue);
    await expectLater(
      service.load(date: '2026-02-31', refresh: false, cancelled: () => false),
      throwsFormatException,
    );
    await expectLater(
      service.load(date: '2999-01-01', refresh: false, cancelled: () => false),
      throwsFormatException,
    );
    await expectLater(service.load(refresh: false, cancelled: () => true), throwsStateError);
    expect(transports, hasLength(2));
  });
}

/// 确定性公开接口传输层；不替换解析与服务缓存逻辑。
class _WeatherTransport implements HttpClientAdapter {
  /// [wait]控制首轮在途合流，[fail]让天气响应缺少温度。
  _WeatherTransport({this.wait, this.fail = false});

  /// 测试持有的完成信号，不由传输层释放。
  final Future<void>? wait;

  /// 是否返回缺少天气数据的响应。
  final bool fail;

  /// 实际请求次数。
  int calls = 0;

  /// 是否被服务明确关闭。
  bool closed = false;

  /// 每次实际请求的头部快照。
  final headers = <Map<String, dynamic>>[];

  /// 读取 [options] 目标；[requestStream]/[cancelFuture]沿用Dio契约，本夹具没有上传。
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    headers.add(Map.of(options.headers));
    if (wait != null) await wait;
    final body = options.uri.host == 'ipwho.is'
        ? {'success': true, 'latitude': 39.9, 'longitude': 116.4, 'city': '北京'}
        : fail
        ? {}
        : {
            'current': {'temperature_2m': 22.4, 'weather_code': 0},
          };
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  /// [force]为true时标记本轮客户端已释放，不影响其他请求实例。
  @override
  void close({bool force = false}) => closed = true;
}
