import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'geolocation_service.dart';
import 'location_guard_service.dart';
import 'preferences.dart';

/// Connection to Hipersign ERP (ERPNext): login, phone setup and Check In / Check Out.
///
/// After login the ERP tells the app this phone's tracker identifier, the server to report to and the
/// duty / GPS-alarm settings (HiperTracker Settings). With "track only between check in and check out"
/// on, tracking and the GPS-off alarm start at Check In and stop at Check Out. Check-ins are saved in
/// the ERP as Employee Checkin with the phone's location.
class ErpService {
  static const String defaultUrl = 'https://nexus365.hipersignerp.cloud';
  static const _passwordKey = 'erp_password';
  static const _storage = FlutterSecureStorage();

  /// Notifies the UI when login state or duty state changes.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  static bool get isConnected =>
      (Preferences.instance.getString(Preferences.erpSid) ?? '').isNotEmpty &&
      (Preferences.instance.getString(Preferences.erpUrl) ?? '').isNotEmpty;
  static bool get onDuty => Preferences.instance.getBool(Preferences.onDuty) ?? false;
  static bool get dutyMode => Preferences.instance.getBool(Preferences.dutyMode) ?? true;
  static String? get employeeName => Preferences.instance.getString(Preferences.erpEmployeeName);
  static String? get user => Preferences.instance.getString(Preferences.erpUser);
  static String? get url => Preferences.instance.getString(Preferences.erpUrl);
  static DateTime? get dutySince {
    final raw = Preferences.instance.getString(Preferences.dutySince);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  static String normalizeUrl(String input) {
    var u = input.trim();
    if (u.isEmpty) return u;
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'https://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  // ---------------------------------------------------------------------------------------------
  // Login
  // ---------------------------------------------------------------------------------------------

  /// Logs in with the worker's ERP username and password, then downloads their phone settings.
  static Future<void> login(String erpUrl, String username, String password) async {
    final base = normalizeUrl(erpUrl);
    if (base.isEmpty || username.trim().isEmpty || password.isEmpty) {
      throw const ErpException('Enter the ERP address, your username and your password.');
    }
    final sid = await _login(base, username.trim(), password);
    await Preferences.instance.setString(Preferences.erpUrl, base);
    await Preferences.instance.setString(Preferences.erpUser, username.trim());
    await Preferences.instance.setString(Preferences.erpSid, sid);
    await _storage.write(key: _passwordKey, value: password);
    try {
      await refreshConfig();
    } catch (e) {
      // logged in, but not usable (e.g. no Employee linked): don't keep a half-connected state
      await logout();
      rethrow;
    }
  }

  static Future<void> logout() async {
    if (onDuty) {
      try {
        await GeolocationService.tracker.stop();
      } catch (_) {}
    }
    for (final key in [
      Preferences.erpSid,
      Preferences.erpEmployee,
      Preferences.erpEmployeeName,
      Preferences.onDuty,
      Preferences.dutySince,
    ]) {
      await Preferences.instance.remove(key);
    }
    await _storage.delete(key: _passwordKey);
    await LocationGuardService.setDuty(dutyMode: false, onDuty: false, alarmInterval: 30, escalateAfter: 1);
    changes.value++;
  }

  static Future<String> _login(String base, String username, String password) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.postUrl(Uri.parse('$base/api/method/login'));
      request.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      // device=mobile gives a long-lived session that doesn't need a CSRF token
      request.write(Uri(queryParameters: {'usr': username, 'pwd': password, 'device': 'mobile'}).query);
      final response = await request.close().timeout(const Duration(seconds: 30));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const ErpException('Wrong username or password.');
      }
      if (response.statusCode != 200) {
        throw ErpException(_errorText(body) ?? 'Login failed (HTTP ${response.statusCode}). Check the ERP address.');
      }
      // read the raw header: Dart's cookie parser rejects some cookies Frappe sends (e.g. names with spaces)
      String? sid;
      for (final header in response.headers[HttpHeaders.setCookieHeader] ?? const <String>[]) {
        final match = RegExp(r'(?:^|[;,]\s*)sid=([^;,\s]+)').firstMatch(header);
        if (match != null) sid = match.group(1);
      }
      if (sid == null || sid.isEmpty || sid == 'Guest') {
        throw const ErpException('Login failed. Check your username and password.');
      }
      return sid;
    } on SocketException {
      throw const ErpException('Could not reach the ERP. Check the address and the internet connection.');
    } on TimeoutException {
      throw const ErpException('The ERP did not answer in time. Try again.');
    } on HandshakeException {
      throw const ErpException('Secure connection to the ERP failed. Check the address.');
    } finally {
      client.close(force: true);
    }
  }

  // ---------------------------------------------------------------------------------------------
  // API calls
  // ---------------------------------------------------------------------------------------------

  static Future<dynamic> _call(String method, Map<String, String> args, {bool retried = false}) async {
    final base = url;
    final sid = Preferences.instance.getString(Preferences.erpSid);
    if (base == null || sid == null || sid.isEmpty) throw const ErpException('Log in to the ERP first.');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.postUrl(Uri.parse('$base/api/method/$method'));
      request.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.cookies.add(Cookie('sid', sid));
      request.write(Uri(queryParameters: args).query);
      final response = await request.close().timeout(const Duration(seconds: 30));
      final body = await response.transform(utf8.decoder).join();
      if ((response.statusCode == 401 || response.statusCode == 403) && !retried && await _relogin()) {
        return _call(method, args, retried: true);
      }
      if (response.statusCode != 200) {
        throw ErpException(_errorText(body) ?? 'ERP error (HTTP ${response.statusCode}).');
      }
      final json = jsonDecode(body);
      return json is Map ? json['message'] : null;
    } on SocketException {
      throw const ErpException('No internet connection to the ERP. Try again.');
    } on TimeoutException {
      throw const ErpException('The ERP did not answer in time. Try again.');
    } finally {
      client.close(force: true);
    }
  }

  /// The session expired: log in again with the saved password.
  static Future<bool> _relogin() async {
    final base = url;
    final username = user;
    final password = await _storage.read(key: _passwordKey);
    if (base == null || username == null || password == null) return false;
    try {
      final sid = await _login(base, username, password);
      await Preferences.instance.setString(Preferences.erpSid, sid);
      return true;
    } catch (e) {
      developer.log('ERP re-login failed', error: e);
      return false;
    }
  }

  /// Pulls this worker's phone settings from the ERP and applies them.
  static Future<void> refreshConfig() async {
    final config = await _call('hipertracker_mobile_config', const {}) as Map<String, dynamic>?;
    if (config == null) throw const ErpException('The ERP did not send the phone settings.');
    final p = Preferences.instance;
    await p.setString(Preferences.erpEmployee, '${config['employee'] ?? ''}');
    await p.setString(Preferences.erpEmployeeName, '${config['employee_name'] ?? config['full_name'] ?? ''}');
    final identifier = '${config['identifier'] ?? ''}';
    if (identifier.isNotEmpty) await p.setString(Preferences.id, identifier);
    final reportUrl = '${config['report_url'] ?? ''}';
    if (reportUrl.isNotEmpty) await p.setString(Preferences.url, reportUrl);
    await p.setString(Preferences.accuracy, 'high');
    await p.setInt(Preferences.interval, _int(config['interval'], 60));
    await p.setInt(Preferences.distance, _int(config['distance'], 50));
    await p.setInt(Preferences.heartbeat, 300);
    await p.setBool(Preferences.buffer, true);
    await p.setBool(Preferences.stopDetection, true);
    await p.setBool(Preferences.dutyMode, _int(config['duty_mode'], 1) == 1);
    await p.setBool(Preferences.requireLocation, _int(config['require_location'], 1) == 1);
    await p.setInt(Preferences.alarmInterval, _int(config['alarm_interval'], 30));
    await p.setInt(Preferences.escalateAfter, _int(config['escalate_after'], 1));
    final wasOnDuty = onDuty;
    final nowOnDuty = _int(config['on_duty'], 0) == 1;
    await p.setBool(Preferences.onDuty, nowOnDuty);
    if (config['last_log_time'] != null) {
      await p.setString(Preferences.dutySince, '${config['last_log_time']}'.replaceFirst(' ', 'T'));
    }
    await GeolocationService.tracker.setConfig(Preferences.buildConfig());
    await _applyDuty(startStopTracking: wasOnDuty != nowOnDuty || !dutyMode);
    changes.value++;
  }

  /// Check In (IN) or Check Out (OUT) with the phone's current location.
  static Future<String> checkInOut(bool checkIn) async {
    Map<String, dynamic>? fix;
    try {
      fix = await LocationGuardService.getLocation();
    } on LocationFixException {
      if (Preferences.instance.getBool(Preferences.requireLocation) ?? true) rethrow;
    }
    if (checkIn) {
      // start tracking first so permissions are asked for before the ERP records the check-in
      try {
        await GeolocationService.tracker.start();
      } on PlatformException {
        throw const ErpException('Allow HiperTracker to use your location (Allow all the time), then check in again.');
      }
    }
    final args = <String, String>{'log_type': checkIn ? 'IN' : 'OUT'};
    if (fix != null) {
      args['latitude'] = '${fix['latitude']}';
      args['longitude'] = '${fix['longitude']}';
      if (fix['accuracy'] != null) args['accuracy'] = '${fix['accuracy']}';
    }
    Map<String, dynamic>? result;
    try {
      result = await _call('hipertracker_checkin', args) as Map<String, dynamic>?;
    } catch (e) {
      if (checkIn && !onDuty) {
        try {
          await GeolocationService.tracker.stop();
        } catch (_) {}
      }
      rethrow;
    }
    final nowOnDuty = _int(result?['on_duty'], checkIn ? 1 : 0) == 1;
    await Preferences.instance.setBool(Preferences.onDuty, nowOnDuty);
    await Preferences.instance.setString(
      Preferences.dutySince,
      '${result?['time'] ?? DateTime.now().toIso8601String()}'.replaceFirst(' ', 'T'),
    );
    await _applyDuty(startStopTracking: true);
    if (fix != null) {
      // send a position straight away so the map updates now, not at the next interval
      unawaited(GeolocationService.tracker.requestPosition().then((_) {}, onError: (_) {}));
    }
    changes.value++;
    final already = _int(result?['already'], 0) == 1;
    if (checkIn) return already ? 'You were already checked in.' : 'Checked in. Have a good day!';
    return already ? 'You were already checked out.' : 'Checked out. Tracking has stopped.';
  }

  /// Starts/stops tracking and the GPS alarm to match the duty state.
  static Future<void> _applyDuty({required bool startStopTracking}) async {
    final p = Preferences.instance;
    if (startStopTracking && dutyMode) {
      try {
        if (onDuty) {
          await GeolocationService.tracker.start();
        } else {
          await GeolocationService.tracker.stop();
        }
      } on PlatformException catch (e) {
        developer.log('Tracking start/stop failed', error: e);
      }
    }
    await LocationGuardService.setDuty(
      dutyMode: dutyMode,
      onDuty: onDuty,
      alarmInterval: p.getInt(Preferences.alarmInterval) ?? 30,
      escalateAfter: p.getInt(Preferences.escalateAfter) ?? 1,
    );
  }

  static int _int(dynamic v, int fallback) {
    if (v is int) return v;
    if (v is double) return v.round();
    if (v is bool) return v ? 1 : 0;
    return int.tryParse('${v ?? ''}') ?? fallback;
  }

  /// Pulls the human-readable message out of a Frappe error response.
  static String? _errorText(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map) return null;
      final server = json['_server_messages'];
      if (server is String) {
        final list = jsonDecode(server);
        if (list is List && list.isNotEmpty) {
          final first = list.first;
          final msg = first is String ? jsonDecode(first) : first;
          if (msg is Map && msg['message'] != null) return _stripHtml('${msg['message']}');
        }
      }
      if (json['message'] is String) return _stripHtml(json['message'] as String);
      final exc = json['exception'];
      if (exc is String && exc.isNotEmpty) return _stripHtml(exc.split(':').skip(1).join(':').trim());
    } catch (_) {}
    return null;
  }

  static String _stripHtml(String s) => s.replaceAll(RegExp(r'<[^>]*>'), '').trim();
}

class ErpException implements Exception {
  final String message;
  const ErpException(this.message);

  @override
  String toString() => message;
}
