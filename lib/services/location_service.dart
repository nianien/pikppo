import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';

/// Authorization / availability state for the device location.
enum LocationStatus {
  unknown,         // 尚未尝试获取
  serviceDisabled, // 系统定位服务关闭
  denied,          // 用户拒绝授权
  deniedForever,   // 用户永久拒绝（仅 Android/iOS）
  ready,           // 已拿到位置
  error,           // 获取过程中出错
}

/// Immutable snapshot of "what we know about the user's location right now".
@immutable
class LocationFix {
  final double latitude;
  final double longitude;
  final double? accuracyMeters;

  /// 反向解析后的地名（country / admin1 / locality / sublocality）。可能为 null
  /// 若反解失败但坐标可用，仍然 ready 状态。
  final String? country;
  final String? administrativeArea;
  final String? locality;
  final String? subLocality;

  /// 该 fix 取得的时间戳，便于上层判断陈旧度。
  final DateTime fetchedAt;

  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.fetchedAt,
    this.accuracyMeters,
    this.country,
    this.administrativeArea,
    this.locality,
    this.subLocality,
  });

  /// 用于注入 system prompt 的紧凑可读形式。优先用人话（"上海市 浦东新区"），
  /// 反解失败时回退到坐标。
  String get displayLabel {
    final parts = <String>[
      if (country != null && country!.isNotEmpty) country!,
      if (administrativeArea != null && administrativeArea!.isNotEmpty)
        administrativeArea!,
      if (locality != null &&
          locality!.isNotEmpty &&
          locality != administrativeArea)
        locality!,
      if (subLocality != null && subLocality!.isNotEmpty) subLocality!,
    ];
    if (parts.isNotEmpty) return parts.join(' ');
    return '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}';
  }
}

/// Wraps geolocator + geocoding behind a single, app-friendly surface.
///
/// **Design notes** for production use:
/// - 永远不在 UI hot path 同步等待 GPS（GPS 首次 fix 可能数秒）。调用方读
///   [lastKnown] 拿缓存即可；后台 [refresh] 异步更新。
/// - 缓存命中策略：[refresh] 在 [maxAge] 内直接返回当前 fix，不重新请求 GPS。
/// - 反向地理编码失败不会让整体 ready 失败——坐标依然可用，displayLabel 退化为
///   "lat, lon"。
/// - 平台差异（serviceDisabled / deniedForever）通过 [status] 暴露，调用方据此
///   决定要不要提示用户去开权限。
class LocationService {
  LocationService({
    Duration maxAge = const Duration(minutes: 10),
    Duration timeout = const Duration(seconds: 8),
  })  : _maxAge = maxAge,
        _timeout = timeout;

  final Duration _maxAge;
  final Duration _timeout;

  LocationStatus _status = LocationStatus.unknown;
  LocationFix? _lastKnown;
  String? _lastError;

  /// 同时进行的 refresh 共享同一个 Future，避免并发 GPS 请求。
  Future<LocationFix?>? _inflight;

  LocationStatus get status => _status;
  LocationFix? get lastKnown => _lastKnown;
  String? get lastError => _lastError;

  /// 取一个"足够新"的位置。命中缓存直接返回；否则发起一次定位 + 反解。
  ///
  /// - [force]: 忽略 [maxAge]，强制重新拉一次 GPS（例如设置页"手动刷新"）。
  /// - 返回 null 表示无法获取（未授权、关闭服务、超时等）；具体原因看 [status]。
  Future<LocationFix?> refresh({bool force = false}) {
    if (!force) {
      final cached = _lastKnown;
      if (cached != null &&
          DateTime.now().difference(cached.fetchedAt) < _maxAge) {
        return Future.value(cached);
      }
    }
    return _inflight ??= _doRefresh().whenComplete(() => _inflight = null);
  }

  Future<LocationFix?> _doRefresh() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _status = LocationStatus.serviceDisabled;
        _lastError = '系统定位服务未开启';
        return _lastKnown;
      }

      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever) {
        _status = LocationStatus.deniedForever;
        _lastError = '位置权限被永久拒绝，请到系统设置中开启';
        return _lastKnown;
      }
      if (perm == LocationPermission.denied) {
        _status = LocationStatus.denied;
        _lastError = '位置权限被拒绝';
        return _lastKnown;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: _timeout,
        ),
      );

      final fix = await _reverseGeocode(position);
      _lastKnown = fix;
      _status = LocationStatus.ready;
      _lastError = null;
      return fix;
    } on TimeoutException catch (e) {
      _status = LocationStatus.error;
      _lastError = 'GPS 超时：${e.message ?? ''}'.trim();
      return _lastKnown;
    } catch (e) {
      _status = LocationStatus.error;
      _lastError = e.toString();
      debugPrint('LocationService refresh failed: $e');
      return _lastKnown;
    }
  }

  /// 反解失败不抛——返回仅含坐标的 fix。
  Future<LocationFix> _reverseGeocode(Position p) async {
    Placemark? mark;
    try {
      final list = await placemarkFromCoordinates(p.latitude, p.longitude);
      if (list.isNotEmpty) mark = list.first;
    } catch (e) {
      debugPrint('reverse geocode failed: $e');
    }
    return LocationFix(
      latitude: p.latitude,
      longitude: p.longitude,
      accuracyMeters: p.accuracy,
      fetchedAt: DateTime.now(),
      country: mark?.country,
      administrativeArea: mark?.administrativeArea,
      locality: mark?.locality,
      subLocality: mark?.subLocality,
    );
  }
}
