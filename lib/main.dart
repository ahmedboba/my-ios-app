import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

const String apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://100.100.59.86:5000',
);
void main() => runApp(const DriverApp());

class DriverApp extends StatefulWidget {
  const DriverApp({super.key});
  @override
  State<DriverApp> createState() => _DriverAppState();
}

class _DriverAppState extends State<DriverApp> {
  String? token;
  String? driverName;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      token = p.getString('token');
      driverName = p.getString('driverName');
    });
  }

  Future<void> _login(String t, String n) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('token', t);
    await p.setString('driverName', n);
    setState(() {
      token = t;
      driverName = n;
    });
  }

  Future<void> _logout() async {
    final p = await SharedPreferences.getInstance();
    await p.clear();
    setState(() {
      token = null;
      driverName = null;
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Ordrat Online',
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFE4002B)),
          scaffoldBackgroundColor: const Color(0xFFF5F5F5),
          appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFFE4002B),
              foregroundColor: Colors.white,
              centerTitle: false)),
      home: token == null
          ? LoginPage(onLogin: _login)
          : HomePage(
              token: token!, driverName: driverName ?? '', onLogout: _logout));
}

class Api {
  final String token;
  Api(this.token);
  Map<String, String> get headers =>
      {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};
  Future<dynamic> get(String path) async {
    final r = await http.get(Uri.parse('$apiBaseUrl$path'), headers: headers);
    return _decode(r);
  }

  Future<dynamic> post(String path, {Map<String, dynamic>? body}) async {
    final payload = body == null ? <String, dynamic>{} : Map<String, dynamic>.from(body);
    final queueable = path.contains('/orders/receive') ||
        path.contains('/delivered') || path.contains('/cancelled') ||
        path.contains('/deferred') || path.contains('/customer-issue') ||
        path.contains('/reopen');
    if (queueable) {
      payload.putIfAbsent('requestId', () =>
          '${DateTime.now().toUtc().microsecondsSinceEpoch}-${payload.hashCode}');
    }
    try {
      return await _sendPost(path, payload);
    } on SocketException {
      if (!queueable) rethrow;
      await _queue(path, payload);
      return {'queuedOffline': true};
    } on TimeoutException {
      if (!queueable) rethrow;
      await _queue(path, payload);
      return {'queuedOffline': true};
    } on http.ClientException {
      if (!queueable) rethrow;
      await _queue(path, payload);
      return {'queuedOffline': true};
    }
  }

  Future<dynamic> _sendPost(String path, Map<String, dynamic> body) async {
    final r = await http
        .post(Uri.parse('$apiBaseUrl$path'), headers: headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
    return _decode(r);
  }

  Future<void> _queue(String path, Map<String, dynamic> body) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getStringList('offline_mutations') ?? <String>[];
    raw.add(jsonEncode({'path': path, 'body': body}));
    await p.setStringList('offline_mutations', raw);
  }

  Future<int> flushOfflineQueue() async {
    final p = await SharedPreferences.getInstance();
    final raw = List<String>.from(p.getStringList('offline_mutations') ?? <String>[]);
    if (raw.isEmpty) return 0;
    var sent = 0;
    final remaining = <String>[];
    for (var index = 0; index < raw.length; index++) {
      final item = raw[index];
      try {
        final value = jsonDecode(item) as Map<String, dynamic>;
        await _sendPost(value['path'] as String,
            Map<String, dynamic>.from(value['body'] as Map));
        sent++;
      } on SocketException {
        remaining.addAll(raw.skip(index));
        break;
      } on TimeoutException {
        remaining.addAll(raw.skip(index));
        break;
      } on http.ClientException {
        remaining.addAll(raw.skip(index));
        break;
      } catch (_) {
        // أخطاء التحقق من الطلب لا تعاد تلقائيًا حتى لا تتكرر المحاولة بلا نهاية.
      }
    }
    await p.setStringList('offline_mutations', remaining);
    return sent;
  }

  dynamic _decode(http.Response r) {
    final data = r.body.isEmpty ? {} : jsonDecode(r.body);
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception(data is Map && data['message'] != null
          ? data['message']
          : 'حدث خطأ في الاتصال');
    }
    return data;
  }
}

String normalizedPhone(dynamic value) {
  var phone = '$value'.replaceAll(RegExp(r'[^0-9+]'), '');
  if (phone.startsWith('00')) phone = '+${phone.substring(2)}';
  if (phone.startsWith('5')) phone = '+965$phone';
  return phone.replaceAll('+', '');
}

Future<void> callClient(dynamic phone) async {
  final n = normalizedPhone(phone);
  if (n.isEmpty) return;
  final uri = Uri.parse('tel:+$n');
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    throw Exception('تعذر فتح الاتصال');
  }
}

Future<void> whatsappClient(dynamic phone) async {
  final n = normalizedPhone(phone);
  if (n.isEmpty) return;
  final uri = Uri.parse('https://wa.me/$n');
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    throw Exception('تعذر فتح واتساب');
  }
}

Widget contactActions(dynamic phone) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
            tooltip: 'واتساب',
            color: const Color(0xFF25D366),
            onPressed: () => whatsappClient(phone),
            icon: const Icon(Icons.chat)),
        IconButton(
            tooltip: 'اتصال',
            color: const Color(0xFFE4002B),
            onPressed: () => callClient(phone),
            icon: const Icon(Icons.phone)),
      ],
    );

Color parseHexColor(String value, Color fallback) {
  final hex = value.replaceAll('#', '').trim();
  if (hex.length != 6) return fallback;
  final number = int.tryParse('FF$hex', radix: 16);
  return number == null ? fallback : Color(number);
}

class PaymentStyle {
  final Color background;
  final Color foreground;
  const PaymentStyle({required this.background, required this.foreground});
}

Widget paymentBadge(String? method, Map<String, PaymentStyle> styles) {
  final name = (method ?? 'غير محدد').trim();
  final style = styles[name] ??
      const PaymentStyle(
          background: Color(0xFFE5E7EB), foreground: Color(0xFF374151));
  return Container(
    constraints: const BoxConstraints(maxWidth: 190),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
        color: style.background, borderRadius: BorderRadius.circular(8)),
    child: Text(name,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            color: style.foreground,
            fontSize: 12,
            fontWeight: FontWeight.bold)),
  );
}

class LoginPage extends StatefulWidget {
  final void Function(String, String) onLogin;
  const LoginPage({super.key, required this.onLogin});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final u = TextEditingController(), p = TextEditingController();
  bool busy = false;
  String? error;
  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final r = await http.post(Uri.parse('$apiBaseUrl/api/auth/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'username': u.text, 'password': p.text}));
      final d = jsonDecode(r.body);
      if (r.statusCode != 200) {
        throw Exception('اسم المستخدم أو كلمة المرور غير صحيحة');
      }
      widget.onLogin(d['token'], d['driverName'] ?? u.text);
    } catch (e) {
      setState(() => error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      body: Center(
          child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Card(
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(children: [
                        const Icon(Icons.local_shipping,
                            size: 70, color: Colors.indigo),
                        const SizedBox(height: 12),
                        const Text('Ordrat Online',
                            style: TextStyle(
                                fontSize: 25, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 24),
                        TextField(
                            controller: u,
                            decoration: const InputDecoration(
                                labelText: 'اسم المستخدم',
                                prefixIcon: Icon(Icons.person))),
                        TextField(
                            controller: p,
                            obscureText: true,
                            decoration: const InputDecoration(
                                labelText: 'كلمة المرور',
                                prefixIcon: Icon(Icons.lock))),
                        if (error != null)
                          Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(error!,
                                  style: const TextStyle(color: Colors.red))),
                        const SizedBox(height: 22),
                        SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                                onPressed: busy ? null : submit,
                                child: busy
                                    ? const CircularProgressIndicator()
                                    : const Text('دخول')))
                      ]))))));
}

class HomePage extends StatefulWidget {
  final String token, driverName;
  final VoidCallback onLogout;
  const HomePage(
      {super.key,
      required this.token,
      required this.driverName,
      required this.onLogout});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;
  late Api api;
  List<dynamic> orders = [];
  final List<Map<String, dynamic>> pendingOrders = [];
  List<String> paymentMethodsFromDb = paymentMethods;
  Map<String, PaymentStyle> paymentStyles = {};
  String companyName = '';
  double? currentLatitude, currentLongitude;
  int? activeOrderId;
  bool loading = false;
  Timer? locationTimer;
  @override
  void initState() {
    super.initState();
    api = Api(widget.token);
    loadOrders();
    loadPaymentMethods();
    loadProfile();
    api.flushOfflineQueue().then((count) {
      if (count > 0 && mounted) _snack('تمت مزامنة $count عملية محفوظة بدون إنترنت');
    });
    locationTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => sendPresenceAndLocation());
    sendPresenceAndLocation();
  }

  Future<void> sendPresenceAndLocation() async {
    try {
      await api.post('/api/driver/presence', body: {});
    } catch (_) {}
    await sendLocation();
  }

  Future<void> sendLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) return;
      final position = await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.high));
      currentLatitude = position.latitude;
      currentLongitude = position.longitude;
      await api.post('/api/driver/location', body: {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        if (activeOrderId != null) 'orderId': activeOrderId,
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    locationTimer?.cancel();
    super.dispose();
  }

  Future<void> loadOrders({bool silent = false}) async {
    if (!silent && mounted) setState(() => loading = true);
    try {
      final d = await api.get('/api/driver/orders');
      final list = List<Map<String, dynamic>>.from(
          d.map((x) => Map<String, dynamic>.from(x as Map)));
      if (currentLatitude != null && currentLongitude != null) {
        list.sort((a, b) => _distanceToOrder(a).compareTo(_distanceToOrder(b)));
      }
      if (mounted) setState(() => orders = list);
    } catch (e) {
      if (!silent) _snack(e.toString());
    } finally {
      if (!silent && mounted) setState(() => loading = false);
    }
  }

  double _distanceToOrder(Map<String, dynamic> order) {
    final text = '${order['FromLocation'] ?? ''} ${order['ToLocation'] ?? ''} ${order['ClientAddress'] ?? ''}';
    final match = RegExp(r'(-?\d{1,3}\.\d+)\s*[,;]\s*(-?\d{1,3}\.\d+)').firstMatch(text);
    if (match == null || currentLatitude == null || currentLongitude == null) {
      return double.maxFinite;
    }
    final lat = double.tryParse(match.group(1)!);
    final lng = double.tryParse(match.group(2)!);
    if (lat == null || lng == null) return double.maxFinite;
    return Geolocator.distanceBetween(currentLatitude!, currentLongitude!, lat, lng);
  }

  Future<void> loadPaymentMethods() async {
    try {
      final d = await api.get('/api/driver/payment-methods');
      final entries = List<Map<String, dynamic>>.from(
          List.from(d).map((e) => Map<String, dynamic>.from(e as Map)));
      final names = entries
          .map((e) => '${e['MethodName'] ?? ''}'.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      final styles = <String, PaymentStyle>{};
      for (final e in entries) {
        final name = '${e['MethodName'] ?? ''}'.trim();
        if (name.isNotEmpty) {
          styles[name] = PaymentStyle(
              background: parseHexColor(
                  '${e['BadgeBackColor'] ?? ''}', const Color(0xFFE5E7EB)),
              foreground: parseHexColor(
                  '${e['BadgeTextColor'] ?? ''}', const Color(0xFF374151)));
        }
      }
      if (names.isNotEmpty && mounted) {
        setState(() {
          paymentMethodsFromDb = names;
          paymentStyles = styles;
        });
      }
    } catch (_) {}
  }

  Future<void> loadProfile() async {
    try {
      final d = await api.get('/api/driver/profile');
      if (mounted) setState(() => companyName = '${d['Company'] ?? ''}');
    } catch (_) {}
  }

  Future<void> lookupAndAdd(String code) async {
    try {
      final d = Map<String, dynamic>.from(await api.get(
          '/api/driver/orders/lookup?code=${Uri.encodeQueryComponent(code)}'));
      if (pendingOrders.any((x) => x['ID'] == d['ID']) ||
          orders.any((x) => x['ID'] == d['ID'])) {
        _snack('الطلب موجود مسبقًا في القائمة');
        return;
      }
      if ('${d['OrderStatus'] ?? ''}' != 'تم التجهيز') {
        _snack(
            'مرفوض: الحالة الحالية ${d['OrderStatus'] ?? ''}، والمطلوب تم التجهيز');
        return;
      }
      setState(() => pendingOrders.add(d));
      SystemSound.play(SystemSoundType.click);
      _snack('تمت إضافة الطلب إلى قائمة الاستلام');
    } catch (e) {
      SystemSound.play(SystemSoundType.alert);
      _snack(e.toString());
    }
  }

  Future<void> receivePending() async {
    if (pendingOrders.isEmpty) return;
    try {
      final r = await api.post('/api/driver/orders/receive', body: {
        'codes': pendingOrders
            .map((x) => '${x['OrderNumber'] ?? x['TrackingNumber']}')
            .toList()
      });
      setState(() => pendingOrders.clear());
      _snack('تم استلام ${r['orderCount']} طلب باسم السائق');
      await loadOrders();
    } catch (e) {
      _snack(e.toString());
    }
  }

  void _snack(String s) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(s.replaceFirst('Exception: ', ''))));

  Future<void> scan() async {
    final code = await Navigator.push<String>(
        context, MaterialPageRoute(builder: (_) => const ScanPage()));
    if (code == null) return;
    try {
      await lookupAndAdd(code);
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> manualEntry() async {
    final c = TextEditingController();
    final code = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('إضافة برقم الطلب'),
              content: TextField(
                  controller: c,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'رقم الطلب أو التتبع')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('إلغاء')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, c.text.trim()),
                    child: const Text('إضافة'))
              ],
            ));
    if (code == null || code.isEmpty) return;
    try {
      await lookupAndAdd(code);
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> delivered(int id, String? currentPaymentMethod) async {
    final choice = await showDialog<PaymentChoice>(
        context: context,
        builder: (_) => PaymentDialog(
            methods: paymentMethodsFromDb,
            initialMethod: currentPaymentMethod));
    if (choice == null) return;
    try {
      await api.post('/api/driver/orders/$id/delivered', body: choice.toJson());
      _snack('تم تسجيل التوصيل');
      loadOrders();
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> quickDelivered(int id, String method) async {
    try {
      await api.post('/api/driver/orders/$id/delivered', body: {
        'paymentMethod': method,
        'paymentNote': 'تم التسليم من الزر السريع'
      });
      _snack('تم تسجيل التسليم ($method)');
      await loadOrders();
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> deferOrder(int id) async {
    final c = TextEditingController();
    final reason = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('تأجيل الطلب'),
              content: TextField(
                  controller: c,
                  maxLines: 3,
                  decoration:
                      const InputDecoration(labelText: 'ملاحظة التأجيل')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('رجوع')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, c.text.trim()),
                    child: const Text('تأجيل'))
              ],
            ));
    if (reason == null) return;
    try {
      await api
          .post('/api/driver/orders/$id/deferred', body: {'reason': reason});
      _snack('تم تأجيل الطلب');
      loadOrders();
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> reportCustomerIssue(int id) async {
    final result = await showDialog<CustomerIssueResult>(
        context: context, builder: (_) => const CustomerIssueDialog());
    if (result == null) return;
    try {
      await api.post('/api/driver/orders/$id/customer-issue', body: {
        'issueType': result.issueType,
        'note': result.note,
        'imageBase64': result.imageBase64,
      });
      _snack('تم توثيق حالة العميل');
      await loadOrders();
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> openClientAddress(Map o) async {
    final id = int.tryParse('${o['ID']}');
    activeOrderId = id;
    final status = '${o['OrderStatus'] ?? ''}';
    if (id != null && status != 'تم التسليم' && status != 'ملغى') {
      try {
        await api.post('/api/driver/orders/$id/in-progress', body: {});
        await loadOrders(silent: true);
      } catch (e) {
        _snack(e.toString());
      }
    }
    final link = '${o['AddressLink'] ?? ''}'.trim();
    final address = '${o['ClientAddress'] ?? ''}'.trim();
    final coordinateText =
        '$address ${o['FromLocation'] ?? ''} ${o['ToLocation'] ?? ''}';
    final match = RegExp(r'(-?\d{1,3}\.\d+)\s*[,;]\s*(-?\d{1,3}\.\d+)')
        .firstMatch(coordinateText);
    if (match != null && mounted) {
      final lat = double.tryParse(match.group(1)!);
      final lng = double.tryParse(match.group(2)!);
      if (lat != null && lng != null) {
        await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => ClientMapPage(
                    latitude: lat,
                    longitude: lng,
                    title: 'موقع العميل - طلب ${o['OrderNumber']}')));
        return;
      }
    }
    final uri = link.isNotEmpty
        ? Uri.tryParse(link)
        : Uri.parse(
            'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address)}');
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      _snack('لا يوجد عنوان صالح للعميل');
    }
  }

  void openOrder(Map<String, dynamic> order) {
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => OrderDetailsPage(
                  order: order,
                  methods: paymentMethodsFromDb,
                  paymentStyles: paymentStyles,
                  onDelivered: delivered,
                  onQuickDelivered: quickDelivered,
                  onCancel: cancel,
                  onDefer: deferOrder,
                  onCustomerIssue: reportCustomerIssue,
                  onOpenAddress: openClientAddress,
                  onReopen: reopenOrder,
                  onReturnRequest: requestReturn,
                ))).then((_) => loadOrders());
  }

  Future<void> reopenOrder(int id) async {
    try {
      await api.post('/api/driver/orders/$id/reopen', body: {});
      _snack('تمت إعادة الطلب إلى قائمة التوصيل');
      await loadOrders();
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> requestReturn(int id) async {
    final c = TextEditingController();
    final reason = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('طلب إرجاع للمراجعة'),
              content: TextField(controller: c, maxLines: 3, decoration: const InputDecoration(labelText: 'سبب الإرجاع')),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
                FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('إرسال'))
              ],
            ));
    if (reason == null || reason.isEmpty) return;
    try {
      await api.post('/api/driver/orders/$id/return-request', body: {'reason': reason});
      _snack('تم إرسال طلب الإرجاع للمراجعة');
      await loadOrders();
    } catch (e) { _snack(e.toString()); }
  }

  Future<void> cancel(int id) async {
    final result = await showDialog<CancelResult>(
        context: context, builder: (_) => const CancelDialog());
    if (result == null) return;
    try {
      await api.post('/api/driver/orders/$id/cancelled',
          body: {'reason': result.reason, 'imageBase64': result.imageBase64});
      _snack('تم إلغاء الطلب');
      loadOrders();
    } catch (e) {
      _snack(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardPage(api: api, onReceive: () => setState(() => tab = 1)),
      ReceivePage(
          pendingOrders: pendingOrders,
          onScan: scan,
          onManual: manualEntry,
          onCode: lookupAndAdd,
          onRemove: (o) => setState(() => pendingOrders.remove(o)),
          onReceive: receivePending),
      OrdersPage(
          orders: orders,
          loading: loading,
          onRefresh: loadOrders,
          onDelivered: delivered,
          onQuickDelivered: quickDelivered,
          onCancel: cancel,
          onDefer: deferOrder,
          onOpen: openOrder,
          onReopen: reopenOrder,
          onReturnRequest: requestReturn,
          paymentStyles: paymentStyles,
          onScan: scan,
          onManual: manualEntry),
      const OperationsPage(),
      ReportPage(api: api),
      PaymentsPage(api: api),
    ];
    return Scaffold(
        appBar: AppBar(
            title: Text(tab == 0
                ? 'الرئيسية'
                : tab == 1
                    ? 'استلام الطلبات'
                    : tab == 2
                        ? 'الطلبات الجاهزة للتسليم'
                        : tab == 3
                            ? 'عمليات التسليم'
                            : tab == 4
                                ? 'التقارير'
                                : 'التسديدات'),
            actions: [
              IconButton(
                  onPressed: widget.onLogout, icon: const Icon(Icons.logout))
            ]),
        drawer: Drawer(
            child: ListView(padding: EdgeInsets.zero, children: [
          UserAccountsDrawerHeader(
              accountName: Text(widget.driverName),
              accountEmail:
                  Text(companyName.isEmpty ? 'Ordrat Online' : companyName),
              currentAccountPicture:
                  const CircleAvatar(child: Icon(Icons.local_shipping))),
          ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('الرئيسية'),
              onTap: () {
                Navigator.pop(context);
                setState(() => tab = 0);
              }),
          ListTile(
              leading: const Icon(Icons.download_done),
              title: const Text('استلام الطلبات'),
              onTap: () {
                Navigator.pop(context);
                setState(() => tab = 1);
              }),
          ListTile(
              leading: const Icon(Icons.list_alt),
              title: const Text('قائمة الطلبات المستلمة'),
              onTap: () {
                Navigator.pop(context);
                setState(() => tab = 2);
              }),
          ListTile(
              leading: const Icon(Icons.assignment),
              title: const Text('عمليات التسليم'),
              onTap: () {
                Navigator.pop(context);
                setState(() => tab = 3);
              }),
          ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('إضافة تسليم بالباركود'),
              onTap: () {
                Navigator.pop(context);
                setState(() => tab = 1);
                scan();
              }),
          ListTile(
              leading: const Icon(Icons.keyboard),
              title: const Text('إضافة تسليم برقم الطلب'),
              onTap: () {
                Navigator.pop(context);
                setState(() => tab = 1);
                manualEntry();
              }),
          ListTile(
              leading: const Icon(Icons.assessment),
              title: const Text('تقرير التوصيل اليومي'),
              onTap: () {
                Navigator.pop(context);
                setState(() => tab = 4);
              }),
          ListTile(
              leading: const Icon(Icons.payments_outlined),
              title: const Text('التسديدات والسندات'),
              onTap: () {
                Navigator.pop(context);
                setState(() => tab = 5);
              }),
          const Divider(),
          ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('تسجيل الخروج'),
              onTap: widget.onLogout)
        ])),
        body: pages[tab],
        bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.home_outlined), label: 'الرئيسية'),
              NavigationDestination(
                  icon: Icon(Icons.download_done), label: 'استلام'),
              NavigationDestination(
                  icon: Icon(Icons.list_alt), label: 'الطلبات'),
              NavigationDestination(
                  icon: Icon(Icons.assignment), label: 'العمليات'),
              NavigationDestination(
                  icon: Icon(Icons.assessment), label: 'التقارير'),
              NavigationDestination(
                  icon: Icon(Icons.payments_outlined), label: 'التسديدات')
            ]));
  }
}

class DashboardPage extends StatefulWidget {
  final Api api;
  final VoidCallback onReceive;
  const DashboardPage({super.key, required this.api, required this.onReceive});
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  Map<String, dynamic> summary = {};
  List<dynamic> operations = [];
  bool loading = true;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => loading = true);
    try {
      final r = await widget.api.get('/api/driver/report');
      final o = await widget.api.get('/api/driver/operations');
      if (mounted) {
        setState(() {
          summary = Map<String, dynamic>.from(r['summary'] ?? {});
          operations = List.from(o);
        });
      }
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  Widget stat(String label, String value, IconData icon, Color color) =>
      Expanded(
          child: Card(
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(children: [
                    Icon(icon, color: color),
                    const SizedBox(height: 5),
                    Text(value,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold)),
                    Text(label, textAlign: TextAlign.center)
                  ]))));
  @override
  Widget build(BuildContext context) => RefreshIndicator(
      onRefresh: load,
      child: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(12), children: [
              Card(
                          color: const Color(0xFFE4002B),
                  child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Row(children: [
                        const Icon(Icons.local_shipping,
                            color: Colors.white, size: 42),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              const Text('Ordrat Online',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 23,
                                      fontWeight: FontWeight.bold)),
                              Text('ملخص عمل السائق اليومي',
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(.9)))
                            ]))
                      ]))),
              Row(children: [
                stat('المستلمة', '${summary['Total'] ?? 0}',
                    Icons.download_done, Colors.blue),
                stat('المسلّمة', '${summary['Delivered'] ?? 0}',
                    Icons.check_circle, Colors.green)
              ]),
              Row(children: [
                stat('ملغي/مؤجل', '${summary['Cancelled'] ?? 0}',
                    Icons.warning_amber, Colors.orange),
                stat('إجمالي المبالغ', '${summary['Amount'] ?? 0}',
                    Icons.payments, Colors.red)
              ]),
              const SizedBox(height: 8),
              SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                      onPressed: widget.onReceive,
                      icon: const Icon(Icons.add_box),
                      label: const Text('بدء عملية استلام جديدة'))),
              const SizedBox(height: 16),
              const Text('آخر عمليات الاستلام',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              if (operations.isEmpty)
                const Card(
                    child: Padding(
                        padding: EdgeInsets.all(22),
                        child: Center(child: Text('لا توجد عمليات اليوم')))),
              ...operations.take(5).map((x) => Card(
                  child: ListTile(
                      leading: const Icon(Icons.assignment,
                          color: Color(0xFFE4002B)),
                      title: Text('${x['OperationNumber'] ?? ''}'),
                      subtitle: Text(
                          '${x['CreatedAt'] ?? ''} | ${x['OrdersCount'] ?? 0} طلب | ${x['ShippingCompany'] ?? ''}'),
                      trailing: Text('${x['Status'] ?? ''}'))))
            ]));
}

class ReceivePage extends StatefulWidget {
  final List<Map<String, dynamic>> pendingOrders;
  final VoidCallback onScan, onManual;
  final Future<void> Function(String) onCode;
  final void Function(Map<String, dynamic>) onRemove;
  final Future<void> Function() onReceive;
  const ReceivePage(
      {super.key,
      required this.pendingOrders,
      required this.onScan,
      required this.onManual,
      required this.onCode,
      required this.onRemove,
      required this.onReceive});
  @override
  State<ReceivePage> createState() => _ReceivePageState();
}

class _ReceivePageState extends State<ReceivePage> {
  final codeController = TextEditingController();

  @override
  void dispose() {
    codeController.dispose();
    super.dispose();
  }

  Future<void> submitCode(String value) async {
    final code = value.trim();
    if (code.isEmpty) return;
    await widget.onCode(code);
    // تفريغ الحقل بعد معالجة الرقم لتسريع المسح والكتابة المتتالية.
    if (mounted) {
      codeController.clear();
      FocusScope.of(context).requestFocus(FocusNode());
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
      onRefresh: () async {},
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
            elevation: 0,
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('عملية استلام جديدة',
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      const Text(
                          'امسح الطلبات أو اكتب أرقامها، ثم راجعها واضغط استلام الطلبات لتسجيل عملية واحدة بتاريخ اليوم.'),
                      const SizedBox(height: 16),
                      TextField(
                          autofocus: true,
                          controller: codeController,
                          textInputAction: TextInputAction.done,
                          onSubmitted: submitCode,
                          decoration: const InputDecoration(
                              filled: true,
                              fillColor: Colors.white,
                              labelText: 'رقم الطلب أو رقم التتبع',
                              hintText: 'امسح الباركود أو اكتب الرقم ثم Enter',
                              prefixIcon: Icon(Icons.qr_code_2))),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(
                            child: FilledButton.icon(
                                onPressed: widget.onScan,
                                icon: const Icon(Icons.qr_code_scanner),
                                label: const Text('مسح باركود'))),
                        const SizedBox(width: 10),
                        Expanded(
                            child: OutlinedButton.icon(
                                onPressed: widget.onManual,
                                icon: const Icon(Icons.keyboard),
                                label: const Text('كتابة رقم')))
                      ])
                    ]))),
        const SizedBox(height: 14),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('الطلبات المراد استلامها (${widget.pendingOrders.length})',
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          if (widget.pendingOrders.isNotEmpty)
            TextButton(
                onPressed: widget.onReceive, child: const Text('استلام الطلبات'))
        ]),
        if (widget.pendingOrders.isEmpty)
          const Card(
              child: Padding(
                  padding: EdgeInsets.all(28),
                  child: Center(child: Text('لم تتم إضافة طلبات بعد')))),
        ...widget.pendingOrders.map((o) => Card(
            child: ListTile(
                leading: CircleAvatar(child: Text('${o['OrderNumber'] ?? ''}')),
                title: Text('${o['ClientName'] ?? 'بدون اسم'}'),
                subtitle: Text(
                    'طلب ${o['OrderNumber']}\n${o['ClientPhone'] ?? ''} | ${o['OrderAmount'] ?? 0}'),
                isThreeLine: true,
                trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'حذف قبل الاستلام',
                    onPressed: () => widget.onRemove(o))))),
        if (widget.pendingOrders.isNotEmpty) ...[
          const SizedBox(height: 10),
          SizedBox(
              height: 52,
              child: FilledButton.icon(
                  onPressed: widget.onReceive,
                  icon: const Icon(Icons.playlist_add_check),
                  label: Text(
                      'استلام ${widget.pendingOrders.length} طلب وتسجيل العملية')))
        ]
      ]));
}

class OrdersPage extends StatefulWidget {
  final List<dynamic> orders;
  final Map<String, PaymentStyle> paymentStyles;
  final bool loading;
  final Future<void> Function() onRefresh;
  final Future<void> Function(int, String?) onDelivered;
  final Future<void> Function(int, String) onQuickDelivered;
  final Future<void> Function(int) onCancel, onDefer;
  final void Function(Map<String, dynamic>) onOpen;
  final Future<void> Function(int) onReopen;
  final Future<void> Function(int) onReturnRequest;
  final VoidCallback onScan, onManual;
  const OrdersPage(
      {super.key,
      required this.orders,
      required this.paymentStyles,
      required this.loading,
      required this.onRefresh,
      required this.onDelivered,
      required this.onQuickDelivered,
      required this.onCancel,
      required this.onDefer,
      required this.onOpen,
      required this.onReopen,
      required this.onReturnRequest,
      required this.onScan,
      required this.onManual});
  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  @override
  Widget build(BuildContext context) {
    final ready = widget.orders
        .where((raw) => '${raw['OrderStatus'] ?? ''}' == 'مع السائق')
        .toList();
    final completed = widget.orders.where((raw) {
      final s = '${raw['OrderStatus'] ?? ''}';
      return s == 'تم التسليم' || s == 'ملغى' || s == 'ملغي' || s == 'مؤجل';
    }).toList();

    Widget orderList(List<dynamic> source, {required bool actions}) {
      return RefreshIndicator(
        onRefresh: widget.onRefresh,
        child: widget.loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  if (actions)
                    Row(children: [
                      Expanded(
                          child: FilledButton.icon(
                              onPressed: widget.onScan,
                              icon: const Icon(Icons.qr_code_scanner),
                              label: const Text('إضافة بالباركود'))),
                      const SizedBox(width: 8),
                      Expanded(
                          child: OutlinedButton.icon(
                              onPressed: widget.onManual,
                              icon: const Icon(Icons.keyboard),
                              label: const Text('برقم الطلب')))
                    ]),
                  if (actions) const SizedBox(height: 8),
                  if (source.isEmpty)
                    const Padding(
                        padding: EdgeInsets.only(top: 160),
                        child: Center(
                            child: Text('لا توجد طلبات في هذه القائمة'))),
                  ...source.map((raw) {
                    final o = Map<String, dynamic>.from(raw as Map);
                    final status = '${o['OrderStatus'] ?? ''}';
                    return Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                            onTap: () => widget.onOpen(o),
                            child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Align(
                                          alignment: Alignment.centerLeft,
                                          child: paymentBadge(
                                              '${o['PaymentMethod'] ?? ''}',
                                              widget.paymentStyles)),
                                      const SizedBox(height: 8),
                                      Text('طلب ${o['OrderNumber']}',
                                          style: const TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.bold)),
                                      Text(
                                          '${o['ClientName'] ?? ''} - ${o['ClientPhone'] ?? ''}'),
                                      contactActions(o['ClientPhone']),
                                      Text('${o['ClientAddress'] ?? ''}'),
                                      Text(
                                          'المبلغ: ${o['OrderAmount'] ?? 0} | الشحن: ${o['ShippingCost'] ?? 0}'),
                                      if ('${o['ReceivedAt'] ?? ''}'.trim().isNotEmpty)
                                        Text('تاريخ ووقت الاستلام: ${o['ReceivedAt']}'),
                                      Text(
                                          'طريقة الدفع: ${o['PaymentMethod'] ?? 'غير محددة'}',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w600)),
                                      if (o['CodAmount'] != null)
                                        Text(
                                            'دفعة عند الاستلام: ${o['CodAmount']} | ${o['OtherMethod'] ?? ''}: ${o['OtherAmount'] ?? ''}',
                                            style: TextStyle(
                                                color: Colors.indigo.shade700)),
                                      Chip(label: Text(status)),
                                      if (actions)
                                        Align(
                                            alignment: Alignment.centerLeft,
                                            child: TextButton(
                                                onPressed: () => widget.onOpen(o),
                                                child: const Text(
                                                    'بدء عملية التسليم')))
                                      else if (status == 'تم التسليم' ||
                                          status == 'ملغى' ||
                                          status == 'ملغي' ||
                                          status == 'مؤجل')
                                        Align(
                                            alignment: Alignment.centerLeft,
                                            child: OutlinedButton.icon(
                                                onPressed: () => widget.onReopen(
                                                    int.parse('${o['ID']}')),
                                                icon: const Icon(Icons.undo),
                                                label: const Text(
                                                    'إعادة إلى عملية التوصيل')))
                                    ]))));
                  })
                ],
              ),
      );
    }

    return DefaultTabController(
        length: 3,
        child: Column(children: [
          const Material(
              color: Colors.transparent,
              child: TabBar(tabs: [
                Tab(icon: Icon(Icons.local_shipping), text: 'مع السائق'),
                Tab(icon: Icon(Icons.check_circle), text: 'تم التسليم'),
                Tab(icon: Icon(Icons.assignment), text: 'عمليات الاستلام')
              ])),
          Expanded(
              child: TabBarView(children: [
            orderList(ready, actions: true),
            orderList(completed, actions: false),
            const OperationsPage(),
          ]))
        ]));
  }
}

class OrderDetailsPage extends StatelessWidget {
  final Map<String, dynamic> order;
  final List<String> methods;
  final Map<String, PaymentStyle> paymentStyles;
  final Future<void> Function(int, String?) onDelivered;
  final Future<void> Function(int, String) onQuickDelivered;
  final Future<void> Function(int) onCancel, onDefer;
  final Future<void> Function(int) onCustomerIssue;
  final Future<void> Function(Map) onOpenAddress;
  final Future<void> Function(int) onReopen;
  final Future<void> Function(int) onReturnRequest;

  const OrderDetailsPage({
    super.key,
    required this.order,
    required this.methods,
    required this.paymentStyles,
    required this.onDelivered,
    required this.onQuickDelivered,
    required this.onCancel,
    required this.onDefer,
    required this.onCustomerIssue,
    required this.onOpenAddress,
    required this.onReopen,
    required this.onReturnRequest,
  });

  @override
  Widget build(BuildContext context) {
    final id = order['ID'] as int;
    final status = '${order['OrderStatus'] ?? ''}';
    final finished = status == 'تم التسليم' || status == 'ملغى';
    return Scaffold(
        appBar: AppBar(title: Text('طلب ${order['OrderNumber']}')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Align(
                            alignment: Alignment.centerLeft,
                            child: paymentBadge(
                                '${order['PaymentMethod'] ?? ''}',
                                paymentStyles)),
                        const SizedBox(height: 8),
                        Text('${order['ClientName'] ?? ''}',
                            style: const TextStyle(
                                fontSize: 22, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Text('الهاتف: ${order['ClientPhone'] ?? ''}'),
                        contactActions(order['ClientPhone']),
                        Text('العنوان: ${order['ClientAddress'] ?? ''}'),
                        Text('المبلغ: ${order['OrderAmount'] ?? 0}'),
                        Text('الشحن: ${order['ShippingCost'] ?? 0}'),
                        Text(
                            'طريقة الدفع: ${order['PaymentMethod'] ?? 'غير محددة'}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        if (order['CodAmount'] != null)
                          Text(
                              'تفاصيل الدفعة: عند الاستلام ${order['CodAmount']} + ${order['OtherMethod'] ?? ''} ${order['OtherAmount'] ?? ''}',
                              style: TextStyle(color: Colors.indigo.shade700)),
                        if ('${order['Notes'] ?? ''}'.trim().isNotEmpty)
                          Text('ملاحظات: ${order['Notes']}',
                              style: const TextStyle(color: Colors.black54)),
                        const SizedBox(height: 8),
                        Chip(label: Text(status))
                      ]))),
          OutlinedButton.icon(
              onPressed: () => onOpenAddress(order),
              icon: const Icon(Icons.location_on),
              label: const Text('فتح موقع العميل')),
          if (!finished) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
                onPressed: () =>
                    onDelivered(id, '${order['PaymentMethod'] ?? ''}'.trim()),
                icon: const Icon(Icons.check_circle),
                label: const Text('بدء عملية التسليم / تم التسليم')),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                  child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFE4002B)),
                      onPressed: () =>
                          onQuickDelivered(id, 'الدفع عند الاستلام'),
                      icon: const Icon(Icons.payments_outlined),
                      label: const Text('تسليم كاش'))),
              const SizedBox(width: 8),
              Expanded(
                  child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF2EBD85)),
                      onPressed: () => onQuickDelivered(id, 'لينك'),
                      icon: const Icon(Icons.link),
                      label: const Text('تسليم لينك')))
            ]),
            OutlinedButton.icon(
                onPressed: () => onDefer(id),
                icon: const Icon(Icons.schedule),
                label: const Text('تأجيل الطلب')),
            OutlinedButton.icon(
                onPressed: () => onCustomerIssue(id),
                icon: const Icon(Icons.report_problem_outlined),
                label: const Text('توثيق حالة العميل')),
            OutlinedButton.icon(
                onPressed: () => onReturnRequest(id),
                icon: const Icon(Icons.assignment_return),
                label: Text('${order['ReturnRequestStatus'] ?? ''}' == 'Pending'
                    ? 'الإرجاع قيد مراجعة الإدارة'
                    : 'طلب إرجاع للمراجعة')),
            TextButton.icon(
                onPressed: () => onCancel(id),
                icon: const Icon(Icons.cancel, color: Colors.red),
                label: const Text('إلغاء الطلب',
                    style: TextStyle(color: Colors.red)))
          ] else
            OutlinedButton.icon(
                onPressed: () => onReopen(id),
                icon: const Icon(Icons.undo),
                label: const Text('إعادة إلى عملية التوصيل'))
        ]));
  }
}

class OperationsPage extends StatefulWidget {
  const OperationsPage({super.key});
  @override
  State<OperationsPage> createState() => _OperationsPageState();
}

class _OperationsPageState extends State<OperationsPage> {
  late final Api api;
  List<dynamic> operations = [];
  bool loading = true;
  @override
  void initState() {
    super.initState();
    final state = context.findAncestorStateOfType<_HomePageState>();
    api = state!.api;
    load();
  }

  Future<void> load() async {
    setState(() => loading = true);
    try {
      final data = await api.get('/api/driver/operations');
      if (mounted) setState(() => operations = List.from(data));
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
      onRefresh: load,
      child: loading
          ? const Center(child: CircularProgressIndicator())
          : operations.isEmpty
              ? ListView(children: const [
                  Padding(
                      padding: EdgeInsets.only(top: 180),
                      child: Center(child: Text('لا توجد عمليات تسليم')))
                ])
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: operations.length,
                  itemBuilder: (_, i) {
                    final o = Map<String, dynamic>.from(operations[i]);
                    final details = List.from(o['Orders'] ?? const []);
                    return Card(
                        child: ExpansionTile(
                            leading: const CircleAvatar(
                                child: Icon(Icons.assignment)),
                            title: Text('${o['OperationNumber'] ?? ''}'),
                            subtitle: Text(
                                '${o['DriverName'] ?? ''} | ${o['ShippingCompany'] ?? ''}\nعدد الطلبات: ${o['OrdersCount'] ?? 0}\nالاستلام: ${o['DeliveryDate'] ?? o['CreatedAt'] ?? ''}'),
                            children: details.isEmpty
                                ? [
                                    const ListTile(
                                        title: Text('لا توجد تفاصيل للطلبات'))
                                  ]
                                : details.map((raw) {
                                    final d = Map<String, dynamic>.from(raw);
                                    return ListTile(
                                      dense: true,
                                      leading: const Icon(Icons.receipt_long),
                                      title: Text(
                                          'طلب ${d['OrderNumber'] ?? ''} - ${d['ClientName'] ?? ''}'),
                                      subtitle: Text(
                                          '${d['ClientPhone'] ?? ''}\n${d['ClientAddress'] ?? ''}'),
                                      trailing:
                                          Text('${d['OrderAmount'] ?? 0}'),
                                    );
                                  }).toList()));
                  }));
}

class ClientMapPage extends StatelessWidget {
  final double latitude;
  final double longitude;
  final String title;
  const ClientMapPage(
      {super.key,
      required this.latitude,
      required this.longitude,
      required this.title});

  @override
  Widget build(BuildContext context) {
    final point = LatLng(latitude, longitude);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: FlutterMap(
        options: MapOptions(initialCenter: point, initialZoom: 16),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.ordrat.online.driver',
          ),
          MarkerLayer(markers: [
            Marker(
              point: point,
              width: 60,
              height: 60,
              child:
                  const Icon(Icons.location_pin, color: Colors.red, size: 52),
            )
          ])
        ],
      ),
    );
  }
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final MobileScannerController controller = MobileScannerController();
  bool handled = false;

  @override
  void dispose() { controller.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('مسح باركود الطلب')),
      body: MobileScanner(
          controller: controller,
          onDetect: (capture) {
            if (handled) return;
            if (capture.barcodes.isNotEmpty) {
              final code = capture.barcodes.first.rawValue;
              if (code != null && code.isNotEmpty) {
                handled = true;
                controller.stop();
                Navigator.pop(context, code.trim());
              }
            }
          },
          overlayBuilder: (context, constraints) => Center(
              child: Container(
                  width: 280,
                  height: 180,
                  decoration: BoxDecoration(
                      border: Border.all(color: Colors.white, width: 3),
                      borderRadius: BorderRadius.circular(12))))));
}

class CancelResult {
  final String reason;
  final String? imageBase64;
  CancelResult(this.reason, this.imageBase64);
}

class PaymentChoice {
  final String method;
  final String? method1;
  final String? method2;
  final double? cashAmount;
  final String? note;
  final String? imageBase64;
  PaymentChoice(this.method,
      {this.method1,
      this.method2,
      this.cashAmount,
      this.note,
      this.imageBase64});
  Map<String, dynamic> toJson() => {
        'paymentMethod': method,
        'paymentMethod1': method1,
        'paymentMethod2': method2,
        'cashAmount': cashAmount,
        'paymentNote': note,
        'paymentImageBase64': imageBase64,
      };
}

const paymentMethods = [
  'الدفع عند الاستلام',
  'مدفوع',
  'كي نت',
  'ومـــــــض',
  'ابل باي',
  'لينك',
  'تبديل',
  'تالي',
  'بطاقة الائتمانية',
  'باي بال',
  'دفعة متعدد',
];

class PaymentDialog extends StatefulWidget {
  final List<String> methods;
  final String? initialMethod;
  const PaymentDialog(
      {super.key, required this.methods, required this.initialMethod});
  @override
  State<PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<PaymentDialog> {
  late String method;
  String? method1, method2;
  final cash = TextEditingController();
  final note = TextEditingController();
  XFile? image;
  final picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    final requested = (widget.initialMethod ?? '').trim();
    method = requested.isNotEmpty && widget.methods.contains(requested)
        ? requested
        : widget.methods.first;
  }

  @override
  Widget build(BuildContext context) {
    final multi = method == 'دفعة متعدد';
    final cashOnDelivery = method == 'الدفع عند الاستلام';
    final prepaid = !multi && !cashOnDelivery;
    final choices = widget.methods.where((x) => x != 'دفعة متعدد');
    return AlertDialog(
      title: const Text('طريقة الدفع عند التوصيل'),
      content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (prepaid)
          Card(
              color: Colors.green.shade50,
              child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.verified, color: Colors.green),
                  title: const Text('الطلب مدفوع مسبقًا'),
                  subtitle: Text('طريقة الدفع: $method')))
        else
          DropdownButtonFormField<String>(
            value: method,
            decoration: const InputDecoration(labelText: 'طريقة الدفع'),
            items: widget.methods
                .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                .toList(),
            onChanged: (x) => setState(() {
              method = x!;
              if (method != 'دفعة متعدد') {
                method1 = null;
                method2 = null;
              }
            }),
          ),
        if (multi) ...[
          DropdownButtonFormField<String>(
            value: method1,
            decoration: const InputDecoration(labelText: 'طريقة الدفع الأولى'),
            items: choices
                .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                .toList(),
            onChanged: (x) => setState(() => method1 = x),
          ),
          DropdownButtonFormField<String>(
            value: method2,
            decoration: const InputDecoration(labelText: 'طريقة الدفع الثانية'),
            items: choices
                .where((x) => x != method1)
                .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                .toList(),
            onChanged: (x) => setState(() => method2 = x),
          ),
          TextField(
              controller: cash,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  const InputDecoration(labelText: 'مبلغ الدفع عند الاستلام')),
        ],
        TextField(
            controller: note,
            maxLines: 2,
            decoration: InputDecoration(
                labelText: prepaid
                    ? 'ملاحظات التسليم (اختياري)'
                    : 'ملاحظة الدفع (اختياري)')),
        if (!prepaid)
          TextButton.icon(
              onPressed: () async {
                final x = await picker.pickImage(source: ImageSource.camera, maxWidth: 1280, maxHeight: 1280, imageQuality: 75);
                if (x != null) setState(() => image = x);
              },
              icon: const Icon(Icons.camera_alt),
              label: Text(image == null
                  ? 'إرفاق صورة الدفع (اختياري)'
                  : 'تم إرفاق صورة الدفع')),
      ])),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('رجوع')),
        FilledButton(
          onPressed: (multi &&
                  (method1 == null ||
                      method2 == null ||
                      double.tryParse(cash.text.trim()) == null))
              ? null
              : () async {
                  final imageBase64 = image == null
                      ? null
                      : base64Encode(await image!.readAsBytes());
                  if (!context.mounted) return;
                  Navigator.pop(
                      context,
                      PaymentChoice(method,
                          method1: method1,
                          method2: method2,
                          cashAmount: double.tryParse(cash.text.trim()),
                          note: note.text.trim().isEmpty
                              ? null
                              : note.text.trim(),
                          imageBase64: prepaid ? null : imageBase64));
                },
          child: const Text('تأكيد'),
        ),
      ],
    );
  }
}

class CustomerIssueResult {
  final String issueType;
  final String? note;
  final String? imageBase64;
  CustomerIssueResult(this.issueType, this.note, this.imageBase64);
}

class CustomerIssueDialog extends StatefulWidget {
  const CustomerIssueDialog({super.key});
  @override
  State<CustomerIssueDialog> createState() => _CustomerIssueDialogState();
}

class _CustomerIssueDialogState extends State<CustomerIssueDialog> {
  static const issueTypes = [
    'لم يرد العميل',
    'العميل ألغى الطلب',
    'العميل رفض الاستلام',
    'العنوان غير صحيح',
    'العميل طلب التأجيل',
    'أخرى',
  ];
  String issueType = issueTypes.first;
  final note = TextEditingController();
  XFile? image;
  final picker = ImagePicker();

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('توثيق حالة العميل'),
        content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<String>(
            value: issueType,
            decoration: const InputDecoration(labelText: 'الحالة'),
            items: issueTypes
                .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                .toList(),
            onChanged: (x) => setState(() => issueType = x!),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: note,
            maxLines: 4,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: issueType == 'أخرى' ? 'التفاصيل *' : 'ملاحظات إضافية (اختياري)'),
          ),
          TextButton.icon(
              onPressed: () async {
                final x = await picker.pickImage(source: ImageSource.camera, maxWidth: 1280, maxHeight: 1280, imageQuality: 75);
                if (x != null) setState(() => image = x);
              },
              icon: const Icon(Icons.camera_alt),
              label: Text(image == null ? 'إرفاق صورة (اختياري)' : 'تم إرفاق الصورة')),
        ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('رجوع')),
          FilledButton(
              onPressed: issueType == 'أخرى' && note.text.trim().isEmpty
                  ? null
                  : () async {
                      final imageBase64 = image == null
                          ? null
                          : base64Encode(await image!.readAsBytes());
                      if (!context.mounted) return;
                      Navigator.pop(
                          context,
                          CustomerIssueResult(
                              issueType,
                              note.text.trim().isEmpty ? null : note.text.trim(),
                              imageBase64));
                    },
              child: const Text('حفظ التوثيق')),
        ],
      );
}

class CancelDialog extends StatefulWidget {
  const CancelDialog({super.key});
  @override
  State<CancelDialog> createState() => _CancelDialogState();
}

class _CancelDialogState extends State<CancelDialog> {
  final c = TextEditingController();
  XFile? image;
  final picker = ImagePicker();
  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('سبب إلغاء الطلب'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: c,
                maxLines: 4,
                onChanged: (_) => setState(() {}),
                decoration:
                    const InputDecoration(hintText: 'اكتب سبب الإلغاء')),
            TextButton.icon(
                onPressed: () async {
                  final x = await picker.pickImage(source: ImageSource.camera, maxWidth: 1280, maxHeight: 1280, imageQuality: 75);
                  if (x != null) setState(() => image = x);
                },
                icon: const Icon(Icons.camera_alt),
                label: Text(image == null ? 'إرفاق صورة' : 'تم إرفاق الصورة'))
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('رجوع')),
            FilledButton(
                onPressed: c.text.trim().isEmpty
                    ? null
                    : () async {
                        final bytes =
                            image == null ? null : await image!.readAsBytes();
                        if (context.mounted) {
                          Navigator.pop(
                              context,
                              CancelResult(c.text.trim(),
                                  bytes == null ? null : base64Encode(bytes)));
                        }
                      },
                child: const Text('تأكيد الإلغاء'))
          ]);
}

class PaymentsPage extends StatefulWidget {
  final Api api;
  const PaymentsPage({super.key, required this.api});
  @override
  State<PaymentsPage> createState() => _PaymentsPageState();
}

class _PaymentsPageState extends State<PaymentsPage> {
  List<dynamic> rows = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (mounted) setState(() => loading = true);
    try {
      final result = await widget.api.get('/api/driver/payments');
      if (mounted) setState(() => rows = List.from(result));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String value(dynamic v) => '${v ?? 0}';

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final raw in rows) {
      final item = Map<String, dynamic>.from(raw as Map);
      final key = '${item['ReceiptID'] ?? item['ReceiptNumber'] ?? ''}';
      grouped.putIfAbsent(key, () => []).add(item);
    }
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Card(
            color: Color(0xFFE4002B),
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Row(children: [
                Icon(Icons.payments, color: Colors.white, size: 34),
                SizedBox(width: 10),
                Text('السندات والتسديدات الخاصة بالسائق',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold))
              ]),
            ),
          ),
          if (rows.isEmpty)
            const Card(
                child: Padding(
                    padding: EdgeInsets.all(28),
                    child: Center(
                        child:
                            Text('لا توجد تسديدات أو سندات مرتبطة بطلباتك')))),
          ...grouped.entries.map((entry) {
            final r = entry.value.first;
            return Card(
              child: InkWell(
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => ReceiptDetailsPage(
                            receipt: r, orders: entry.value))),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                  'سند رقم ${r['ReceiptNumber'] ?? r['ReceiptID'] ?? ''}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 17)),
                              Chip(
                                  label: Text(
                                      '${r['PaymentMethod'] ?? 'غير محدد'}'))
                            ]),
                        const Divider(),
                        Text('عدد الطلبات المرتبطة: ${entry.value.length}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        Text(
                            'تاريخ السند: ${r['ReceiptDate'] ?? r['CreatedDate'] ?? ''}'),
                        Text('قيمة السند: ${value(r['ReceiptAmount'])} د.ك'),
                        const SizedBox(height: 6),
                        const Text('اضغط لعرض الطلبات المرتبطة بالسند',
                            style: TextStyle(color: Colors.indigo))
                      ]),
                ),
              ),
            );
          })
        ],
      ),
    );
  }
}

class ReceiptDetailsPage extends StatelessWidget {
  final Map<String, dynamic> receipt;
  final List<Map<String, dynamic>> orders;
  const ReceiptDetailsPage(
      {super.key, required this.receipt, required this.orders});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text(
                'سند رقم ${receipt['ReceiptNumber'] ?? receipt['ReceiptID'] ?? ''}')),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              'سند رقم ${receipt['ReceiptNumber'] ?? receipt['ReceiptID'] ?? ''}',
                              style: const TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.bold)),
                          Text('الشركة: ${receipt['Company'] ?? ''}'),
                          Text(
                              'تاريخ السند: ${receipt['ReceiptDate'] ?? receipt['CreatedDate'] ?? ''}'),
                          Text(
                              'قيمة السند: ${receipt['ReceiptAmount'] ?? 0} د.ك'),
                          Text(
                              'المدفوع: ${receipt['PaidAmount'] ?? receipt['PaidInstallments'] ?? 0} د.ك'),
                          Text(
                              'المتبقي: ${receipt['RemainingAmount'] ?? 0} د.ك'),
                        ]))),
            const SizedBox(height: 8),
            Text('الطلبات المرتبطة بالسند (${orders.length})',
                style:
                    const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
            ...orders.map((o) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.receipt_long,
                        color: Color(0xFFE4002B)),
                    title: Text('طلب ${o['OrderNumber'] ?? ''}'),
                    subtitle: Text(
                        '${o['ClientName'] ?? ''}\n${o['ClientPhone'] ?? ''}'),
                    isThreeLine: true,
                    trailing: Text('${o['OrderAmount'] ?? 0} د.ك'),
                  ),
                ))
          ],
        ),
      );
}

class ReportPage extends StatefulWidget {
  final Api api;
  const ReportPage({super.key, required this.api});
  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  Map<String, dynamic>? report, statement;
  bool loading = true;
  DateTime fromDate = DateTime.now();
  DateTime toDate = DateTime.now();
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final from = fromDate.toIso8601String().substring(0, 10);
      final to = toDate.toIso8601String().substring(0, 10);
      final query = '?from=$from&to=$to';
      final a = await widget.api.get('/api/driver/report$query');
      final b = await widget.api.get('/api/driver/statement$query');
      setState(() {
        report = Map<String, dynamic>.from(a);
        statement = Map<String, dynamic>.from(b);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> chooseDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: fromDate, end: toDate),
      locale: const Locale('ar'),
    );
    if (picked != null) {
      setState(() {
        fromDate = picked.start;
        toDate = picked.end;
      });
    }
  }

  Widget _summaryTile(String title, dynamic value, Color color,
          {bool money = false}) =>
      Card(
        child: ListTile(
          leading: CircleAvatar(
              backgroundColor: color,
              child: const Icon(Icons.numbers, color: Colors.white)),
          title: Text(title),
          trailing: Text(money ? '$value د.ك' : '$value طلب',
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    final summary = Map<String, dynamic>.from(report?['summary'] ?? {});
    final st = List<Map<String, dynamic>>.from(
        (statement?['rows'] ?? []).map((e) => Map<String, dynamic>.from(e)));
    return RefreshIndicator(
        onRefresh: load,
        child: ListView(padding: const EdgeInsets.all(12), children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('فترة التقرير',
                style: TextStyle(fontWeight: FontWeight.bold)),
            OutlinedButton.icon(
              onPressed: chooseDateRange,
              icon: const Icon(Icons.calendar_month),
              label: Text(
                  '${fromDate.year}/${fromDate.month}/${fromDate.day} - ${toDate.year}/${toDate.month}/${toDate.day}'),
            ),
            FilledButton.icon(
                onPressed: load,
                icon: const Icon(Icons.search),
                label: const Text('بحث')),
          ]),
          const Text('ملخص الطلبات',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          _summaryTile('تم التوصيل', summary['Delivered'] ?? 0, Colors.green),
          _summaryTile('ملغى / مرتجع', summary['Cancelled'] ?? 0, Colors.red),
          _summaryTile(
              'لم يتم التوصيل', summary['NotDelivered'] ?? 0, Colors.orange),
          _summaryTile('إجمالي الطلبات', summary['Total'] ?? 0, Colors.blue),
          const Divider(),
          const Text('كشف الحساب',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          _summaryTile('طلبات الدفع عند الاستلام', summary['CashOrders'] ?? 0,
              Colors.deepOrange),
          _summaryTile('إجمالي الدفع عند الاستلام', summary['CashAmount'] ?? 0,
              Colors.deepOrange,
              money: true),
          _summaryTile('الطلبات المدفوعة مسبقاً', summary['PrepaidOrders'] ?? 0,
              Colors.indigo),
          _summaryTile('إجمالي الشحن', summary['Shipping'] ?? 0, Colors.teal,
              money: true),
          Card(
              color: const Color(0xFFE8F5E9),
              child: ListTile(
                  leading: const Icon(Icons.account_balance_wallet,
                      color: Colors.green),
                  title: const Text('الرصيد النهائي'),
                  subtitle: const Text('الدفع عند الاستلام ناقص قيمة الشحن'),
                  trailing: Text(
                      '${summary['FinalBalance'] ?? statement?['total'] ?? 0} د.ك',
                      style: const TextStyle(
                          color: Colors.green,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)))),
          ...st.map((r) => ListTile(
              title: Text('طلب ${r['OrderNumber']}'),
              subtitle: Text('${r['PaymentMethod']} - ${r['OrderStatus']}'),
              trailing: Text('${r['NetAmount']}')))
        ]));
  }
}
