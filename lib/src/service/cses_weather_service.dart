import 'package:cses_document_collab/cses_document_collab.dart' show CollabWeatherData;
import 'package:dio/dio.dart';

/// 文档天气宿主适配器，与桌面使用相同公开数据源和IP粗定位/北京回落。
/// 独立Dio不携带内部认证、Cookie或追踪拦截器，每轮请求结束即关闭。
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/service/cses_weather_service.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final services = CollabHostServices(loadWeather: CsesWeatherService().load);
/// ```
final class CsesWeatherService {
  /// 创建会话内缓存；[createClient]可注入隔离的客户端工厂，null使用无认证Dio。
  /// 工厂每次须返回新客户端并转移关闭所有权；不建立连接，资源在各轮请求内释放。
  CsesWeatherService({Dio Function()? createClient}) : _createClient = createClient ?? _newWeatherClient;

  /// 每轮新建且由本服务关闭的网络客户端，不得返回宿主的认证客户端。
  final Dio Function() _createClient;

  /// 十分钟内相同时间锚的成功快照；随宿主服务释放，不持久化位置。
  final _cache = <String, ({DateTime at, CollabWeatherData data})>{};

  /// 同一时间锚合流；单个调用取消不影响其他卡片。
  final _pending = <String, Future<CollabWeatherData>>{};

  /// [date]为固定YYYY-MM-DD或null实时；[refresh]绕过缓存；[cancelled]隔离迟到交付。
  /// 失败抛错而非生成假天气；Future结束时本轮网络客户端已关闭。
  Future<CollabWeatherData> load({
    String? date,
    required bool refresh,
    required bool Function() cancelled,
  }) async {
    final now = DateTime.now();
    final today =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    if (date != null) {
      final parsed = DateTime.tryParse(date);
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
          parsed == null ||
          parsed.year != int.parse(date.substring(0, 4)) ||
          parsed.month != int.parse(date.substring(5, 7)) ||
          parsed.day != int.parse(date.substring(8)) ||
          date.compareTo(today) > 0) {
        throw const FormatException('天气日期无效或晚于今天');
      }
    }
    final key = date != null && date.compareTo(today) < 0 ? date : 'live';
    if (cancelled()) throw StateError('天气请求已失效');
    final cached = _cache[key];
    if (!refresh && cached != null && now.difference(cached.at) < const Duration(minutes: 10)) {
      return cached.data;
    }
    final Future<CollabWeatherData> pending;
    if (!refresh && _pending[key] != null) {
      pending = _pending[key]!;
    } else {
      pending = _fetch(key == 'live' ? null : key);
      _pending[key] = pending;
    }
    try {
      final data = await pending;
      if (identical(_pending[key], pending)) _cache[key] = (at: DateTime.now(), data: data);
      if (cancelled()) throw StateError('天气请求已失效');
      return data;
    } finally {
      _pending.removeWhere((entryKey, value) => entryKey == key && identical(value, pending));
    }
  }

  /// 查询 [date] 对应的历史或实时天气；null实时，所有出口关闭本轮Dio。
  Future<CollabWeatherData> _fetch(String? date) async {
    final client = _createClient();
    try {
      var latitude = 39.9042;
      var longitude = 116.4074;
      var location = '北京';
      try {
        final ip = (await client.get<Object?>('https://ipwho.is/', queryParameters: {'lang': 'zh-CN'})).data;
        if (ip is Map &&
            ip['success'] == true &&
            ip['latitude'] is num &&
            ip['longitude'] is num &&
            (ip['latitude'] as num).isFinite &&
            (ip['longitude'] as num).isFinite) {
          latitude = (ip['latitude'] as num).toDouble();
          longitude = (ip['longitude'] as num).toDouble();
          location = [
            ip['city'],
            ip['region'],
            ip['country'],
          ].whereType<String>().firstWhere((value) => value.isNotEmpty, orElse: () => '当前位置');
        }
      } catch (_) {
        // IP location is optional. The named Beijing fallback is shared with desktop.
      }
      final response = await client.get<Object?>(
        date == null
            ? 'https://api.open-meteo.com/v1/forecast'
            : 'https://archive-api.open-meteo.com/v1/archive',
        queryParameters: {
          'latitude': latitude,
          'longitude': longitude,
          'timezone': 'auto',
          if (date == null) ...{
            'current': 'temperature_2m,weather_code',
            'daily': 'temperature_2m_max,temperature_2m_min',
            'forecast_days': 1,
          } else ...{
            'start_date': date,
            'end_date': date,
            'daily': 'weather_code,temperature_2m_mean,temperature_2m_max,temperature_2m_min',
          },
        },
      );
      return parseCsesWeather(response.data, location, historical: date != null);
    } finally {
      client.close(force: true);
    }
  }
}

/// 从公开API [raw] 读取真实天气；[location]为城市，[historical]选择历史日汇总。
/// 缺失有限温度时抛FormatException，WMO未知码显示天气而不伪装晴天。
CollabWeatherData parseCsesWeather(Object? raw, String location, {required bool historical}) {
  if (raw is! Map) throw const FormatException('天气响应无效');
  final daily = raw['daily'] is Map ? raw['daily'] as Map : const {};
  final current = raw['current'] is Map ? raw['current'] as Map : const {};

  /// 读取日列表 [key] 的首个有效数值，空数组/null不转换为0。
  double? first(String key) {
    final list = daily[key];
    final value = list is List && list.isNotEmpty ? list.first : null;
    return value is num && value.isFinite ? value.toDouble() : null;
  }

  final high = first('temperature_2m_max');
  final low = first('temperature_2m_min');
  final rawTemp = current['temperature_2m'];
  final temp = historical
      ? first('temperature_2m_mean') ?? (high != null && low != null ? (high + low) / 2 : null)
      : rawTemp is num && rawTemp.isFinite
      ? rawTemp.toDouble()
      : null;
  if (temp == null) throw const FormatException('天气缺少有效温度');
  final code = historical ? first('weather_code') : current['weather_code'];
  final (condition, tone) = switch (code) {
    0 => ('晴', 'sunny'),
    1 || 2 => ('少云', 'sunny'),
    3 => ('多云', 'cloudy'),
    45 || 48 => ('雾', 'foggy'),
    51 || 53 || 55 || 56 || 57 => ('小雨', 'rainy'),
    61 || 63 || 65 || 66 || 67 || 80 || 81 || 82 => ('雨', 'rainy'),
    71 || 73 || 75 || 77 || 85 || 86 => ('雪', 'snowy'),
    95 || 96 || 99 => ('雷雨', 'stormy'),
    _ => ('天气', 'cloudy'),
  };
  return CollabWeatherData(
    temp: temp.roundToDouble(),
    high: (high ?? temp).roundToDouble(),
    low: (low ?? temp).roundToDouble(),
    condition: condition,
    tone: tone,
    location: location,
  );
}

/// 创建无内部认证或追踪头的天气专用客户端；调用方须在请求结束时关闭。
Dio _newWeatherClient() => Dio(
  BaseOptions(connectTimeout: const Duration(seconds: 10), receiveTimeout: const Duration(seconds: 15)),
);
