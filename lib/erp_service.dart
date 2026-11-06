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
        return await _call(method, args, retried: true);
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
    if (reportUrl.isNotEmpty) await p.setString(Preferences.url, Preferences.normalizeServerUrl(reportUrl));
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

  /// The worker's check ins / outs for the last [days] days and today's travel, for the My Day tab.
  static Future<MyDay> myDay({int days = 14}) async {
    final data = await _call('hipertracker_my_day', {'days': '$days'}) as Map<String, dynamic>?;
    if (data == null) throw const ErpException('The ERP did not send your day.');
    return MyDay.fromJson(data);
  }

  /// Road route from [from] through [stops] (each [lat, lon]) in order, with turn-by-turn steps.
  static Future<RoutePlan> route(List<double> from, List<List<double>> stops) async {
    final points = [from, ...stops].map((p) => '${p[0].toStringAsFixed(6)},${p[1].toStringAsFixed(6)}').join(';');
    final data = await _call('hipertracker_route', {'points': points}) as Map<String, dynamic>?;
    if (data == null) throw const ErpException('No route found.');
    return RoutePlan.fromJson(data);
  }

  /// Everything the worker did on [day]: check in / out, trips, stops, location off, places reached.
  static Future<DayLog> myLog(DateTime day) async {
    final d = '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    final data = await _call('hipertracker_my_log', {'date': d}) as Map<String, dynamic>?;
    if (data == null) throw const ErpException('The ERP did not send the log.');
    return DayLog.fromJson(data);
  }

  /// Customers, leads, deals, suppliers ... that have a location, nearest to [lat], [lon] first.
  static Future<List<VisitPlace>> visitPlaces({double? lat, double? lon, String q = ''}) async {
    final data = await _call('hipertracker_visit_places', {
      if (lat != null) 'lat': '$lat',
      if (lon != null) 'lon': '$lon',
      if (q.isNotEmpty) 'q': q,
    }) as List?;
    return [for (final p in data ?? const []) VisitPlace.fromJson(p as Map<String, dynamic>)];
  }

  /// The best order to visit [places] (each [lat, lon]) starting at [from]: indexes into [places].
  static Future<List<int>> bestOrder(List<double> from, List<List<double>> places) async {
    final points = [from, ...places].map((p) => '${p[0].toStringAsFixed(6)},${p[1].toStringAsFixed(6)}').join(';');
    final data = await _call('hipertracker_best_order', {'points': points}) as Map<String, dynamic>?;
    final order = [for (final i in (data?['order'] as List? ?? const [])) (int.tryParse('$i') ?? 0) - 1]
        .where((i) => i >= 0 && i < places.length)
        .toList();
    if (order.length != places.length) return [for (var i = 0; i < places.length; i++) i];
    return order;
  }

  /// Saves the worker's own trip plan for today with [places] in visiting order; returns the plan name.
  static Future<String> saveMyTrip(List<VisitPlace> places, {String? title}) async {
    final stops = jsonEncode([for (final p in places) {'type': p.type, 'name': p.name}]);
    final data = await _call('hipertracker_save_my_trip', {'stops': stops, if (title != null && title.isNotEmpty) 'title': title})
        as Map<String, dynamic>?;
    final name = data?['name'];
    if (name == null) throw const ErpException('The trip could not be saved.');
    changes.value++;
    return '$name';
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

class AttendanceLog {
  final bool isIn;
  final DateTime time;
  final double? lat;
  final double? lon;
  const AttendanceLog(this.isIn, this.time, this.lat, this.lon);
}

/// One trip (movement between stops) or one stop of today, from the ERP.
class DaySegment {
  final bool isTrip;
  final String start; // HH:MM
  final String end;
  final int minutes;
  final double distanceKm;
  final int avgSpeed;
  final int maxSpeed;
  final bool ongoing;
  const DaySegment(this.isTrip, this.start, this.end, this.minutes, this.distanceKm, this.avgSpeed, this.maxSpeed, this.ongoing);
}

/// One stop of a trip plan set in the ERP, with how far the worker has got.
class PlanStop {
  final int idx;
  final String name;
  final String? task;
  final double? lat;
  final double? lon;
  final String? planned; // HH:MM
  final String status; // Pending / Reached / Left / Skipped
  final String? arrived;
  final String? left;
  final String? phone;
  final String? address;
  final String? type; // Customer, Lead, CRM Deal, ...
  const PlanStop(this.idx, this.name, this.task, this.lat, this.lon, this.planned, this.status, this.arrived, this.left,
      {this.phone, this.address, this.type});

  bool get hasLocation => lat != null && lon != null && lat != 0 && lon != 0;
  bool get pending => status == 'Pending';
}

/// A trip plan for today: the stops to visit, in order.
class TripPlan {
  final String name;
  final String title;
  final String status;
  final List<PlanStop> stops;
  const TripPlan(this.name, this.title, this.status, this.stops);

  PlanStop? get next {
    for (final s in stops) {
      if (s.status == 'Pending') return s;
    }
    return null;
  }

  int get done => stops.where((s) => s.status != 'Pending').length;

  /// Google Maps directions from where the phone is now through the stops still to visit, in plan order.
  /// The Maps app takes up to 9 stops on the way plus the destination.
  Uri? directions() {
    final left = stops.where((s) => s.pending && s.hasLocation).take(10).toList();
    if (left.isEmpty) return null;
    String ll(PlanStop s) => '${s.lat},${s.lon}';
    final q = <String, String>{'api': '1', 'destination': ll(left.last), 'travelmode': 'driving'};
    if (left.length > 1) q['waypoints'] = left.sublist(0, left.length - 1).map(ll).join('|');
    return Uri.https('www.google.com', '/maps/dir/', q);
  }
}

class MyDay {
  final List<List<double>> track; // today's route so far, [lat, lon]
  final List<TripPlan> plans; // today's trip plans
  final List<DaySegment> segments; // today's trips and stops, in time order
  final List<AttendanceLog> logs; // newest first
  final double distanceKm;
  final int points;
  final int gpsOff;
  final DateTime? first;
  final DateTime? last;
  const MyDay(this.logs, this.distanceKm, this.points, this.gpsOff, this.first, this.last, this.segments,
      [this.plans = const [], this.track = const []]);

  static DateTime? _time(dynamic v) => v == null ? null : DateTime.tryParse('$v'.replaceFirst(' ', 'T'));
  static double? _num(dynamic v) => v == null ? null : double.tryParse('$v');

  factory MyDay.fromJson(Map<String, dynamic> j) {
    final logs = <AttendanceLog>[];
    for (final l in (j['logs'] as List? ?? const [])) {
      final m = l as Map<String, dynamic>;
      final t = _time(m['time']);
      if (t == null) continue;
      logs.add(AttendanceLog(m['log_type'] == 'IN', t, _num(m['lat']), _num(m['lon'])));
    }
    final today = (j['today'] as Map<String, dynamic>?) ?? const {};
    int i(dynamic v) => (_num(v) ?? 0).round();
    final segments = <DaySegment>[
      for (final t in (today['trips'] as List? ?? const []))
        DaySegment(true, '${t['start']}', '${t['end']}', i(t['minutes']), _num(t['distance_km']) ?? 0,
            i(t['avg_speed']), i(t['max_speed']), false),
      for (final st in (today['stops'] as List? ?? const []))
        DaySegment(false, '${st['start']}', '${st['end']}', i(st['minutes']), 0, 0, 0, st['ongoing'] == true),
    ]..sort((a, b) => a.start.compareTo(b.start));
    String? str(dynamic v) => v == null || '$v'.isEmpty ? null : '$v';
    final plans = <TripPlan>[
      for (final p in (j['plans'] as List? ?? const []))
        TripPlan('${p['name']}', '${p['title'] ?? p['name']}', '${p['status'] ?? ''}', [
          for (final st in (p['stops'] as List? ?? const []))
            PlanStop(i(st['idx']), '${st['name'] ?? 'Stop ${st['idx']}'}', str(st['task']), _num(st['lat']),
                _num(st['lon']), str(st['planned']), '${st['status'] ?? 'Pending'}', str(st['arrived']), str(st['left']),
                phone: str(st['phone']), address: str(st['address']), type: str(st['type'])),
        ]),
    ];
    return MyDay(
      logs,
      _num(today['distance_km']) ?? 0,
      int.tryParse('${today['points'] ?? 0}') ?? 0,
      int.tryParse('${today['gps_off'] ?? 0}') ?? 0,
      _time(today['first']),
      _time(today['last']),
      segments,
      plans,
      [
        for (final p in (today['track'] as List? ?? const []))
          if (p is List && p.length >= 2 && _num(p[0]) != null && _num(p[1]) != null) [_num(p[0])!, _num(p[1])!],
      ],
    );
  }
}

/// One turn-by-turn instruction of a road route.
class RouteStep {
  final double lat;
  final double lon;
  final String text;
  final String type; // depart, turn, roundabout, arrive, ...
  final String modifier; // left, slight right, straight, uturn, ...
  final int distance; // metres until the next instruction
  final int leg; // 0 = on the way to the first remaining stop
  const RouteStep(this.lat, this.lon, this.text, this.type, this.modifier, this.distance, this.leg);
}

/// A road route through the remaining stops (line as [lat, lon] points).
class RoutePlan {
  final List<List<double>> line;
  final int distance; // metres
  final int duration; // seconds
  final List<List<int>> legs; // [metres, seconds] per stop
  final List<RouteStep> steps;
  const RoutePlan(this.line, this.distance, this.duration, this.legs, this.steps);

  factory RoutePlan.fromJson(Map<String, dynamic> j) {
    double d(dynamic v) => double.tryParse('$v') ?? 0;
    int n(dynamic v) => (double.tryParse('$v') ?? 0).round();
    return RoutePlan(
      [for (final p in (j['line'] as List? ?? const [])) if (p is List && p.length >= 2) [d(p[0]), d(p[1])]],
      n(j['distance']),
      n(j['duration']),
      [for (final l in (j['legs'] as List? ?? const [])) [n(l['distance']), n(l['duration'])]],
      [
        for (final s in (j['steps'] as List? ?? const []))
          RouteStep(d(s['lat']), d(s['lon']), '${s['text'] ?? ''}', '${s['type'] ?? ''}', '${s['modifier'] ?? ''}',
              n(s['distance']), n(s['leg'])),
      ],
    );
  }
}

/// A customer, lead, deal ... with a location, for planning a trip.
class VisitPlace {
  final String type;
  final String name;
  final String title;
  final double lat;
  final double lon;
  final double? km; // straight-line distance from the phone
  const VisitPlace(this.type, this.name, this.title, this.lat, this.lon, this.km);

  factory VisitPlace.fromJson(Map<String, dynamic> j) => VisitPlace(
        '${j['type']}',
        '${j['name']}',
        '${j['title'] ?? j['name']}',
        double.tryParse('${j['lat']}') ?? 0,
        double.tryParse('${j['lon']}') ?? 0,
        j['km'] == null ? null : double.tryParse('${j['km']}'),
      );

  String get key => '$type/$name';
}

/// One line of the activity log.
class LogItem {
  final DateTime at;
  final String kind; // in, out, trip, stop, gps_off, visit
  final String title;
  final String detail;
  final double? lat;
  final double? lon;
  const LogItem(this.at, this.kind, this.title, this.detail, this.lat, this.lon);
}

/// A day of activity: totals and the timeline.
class DayLog {
  final double distanceKm;
  final int movingMinutes;
  final int stoppedMinutes;
  final int trips;
  final int stops;
  final int gpsOff;
  final int gpsOffMinutes;
  final List<LogItem> items;
  const DayLog(this.distanceKm, this.movingMinutes, this.stoppedMinutes, this.trips, this.stops, this.gpsOff,
      this.gpsOffMinutes, this.items);

  factory DayLog.fromJson(Map<String, dynamic> j) {
    final s = (j['summary'] as Map<String, dynamic>?) ?? const {};
    int i(dynamic v) => (double.tryParse('$v') ?? 0).round();
    double? d(dynamic v) => v == null ? null : double.tryParse('$v');
    return DayLog(
      d(s['distance_km']) ?? 0,
      i(s['moving_minutes']),
      i(s['stopped_minutes']),
      i(s['trips']),
      i(s['stops']),
      i(s['gps_off']),
      i(s['gps_off_minutes']),
      [
        for (final it in (j['items'] as List? ?? const []))
          if (DateTime.tryParse('${it['at']}'.replaceFirst(' ', 'T')) != null)
            LogItem(DateTime.parse('${it['at']}'.replaceFirst(' ', 'T')), '${it['kind']}', '${it['title'] ?? ''}',
                '${it['detail'] ?? ''}', d(it['lat']), d(it['lon'])),
      ],
    );
  }
}
