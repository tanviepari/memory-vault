import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';

// ============ THEME / CONSTANTS ============
const bgDark = Color(0xFF2A1F1D), bgCard = Color(0xFF3D2E2B), bgShelf = Color(0xFF1F1614);
const borderWarm = Color(0xFF5C453D), textMain = Color(0xFFF4ECE1), textMuted = Color(0xFFBDA899);
const accent = Color(0xFFF7D0A1);
const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

enum Emo { joy, sadness, anger, fear, disgust }
const emoColor = {
  Emo.joy: Color(0xFFFFD700), Emo.sadness: Color(0xFF4A90E2), Emo.anger: Color(0xFFE74C3C),
  Emo.fear: Color(0xFF9B59B6), Emo.disgust: Color(0xFF2ECC71),
};
const emoTag = {
  Emo.joy: 'a golden, sparkly little moment',
  Emo.sadness: 'a quiet blue ache, but it matters',
  Emo.anger: 'hot, loud, and very real',
  Emo.fear: 'heart-pounding and wide-eyed',
  Emo.disgust: 'yuck. unforgettable, though',
};
String cap(String s) => s[0].toUpperCase() + s.substring(1);
String fmt(DateTime d) => '${months[d.month - 1]} ${d.day}, ${d.year}';
void snack(BuildContext c, String t) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(t)));

// ============ MODELS ============
class Memory {
  final String id, title, text;
  final Emo emo;
  final String? image; // base64
  final Uint8List? bytes;
  final bool core;
  final DateTime date;
  Memory({required this.id, required this.title, required this.text, required this.emo,
      this.image, this.core = false, required this.date})
      : bytes = image == null ? null : base64Decode(image);
  Memory copyWith({bool? core}) => Memory(id: id, title: title, text: text, emo: emo, image: image, core: core ?? this.core, date: date);
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'text': text, 'emo': emo.name,
        'image': image, 'core': core, 'date': date.toIso8601String()};
  factory Memory.fromJson(Map j) => Memory(id: j['id'], title: j['title'], text: j['text'],
      emo: Emo.values.byName(j['emo']), image: j['image'], core: j['core'] ?? false, date: DateTime.parse(j['date']));
}

class AppUser {
  final String uid, username, name;
  final String? avatar; // base64
  final Uint8List? bytes;
  final DateTime joined;
  AppUser({required this.uid, required this.username, required this.name, this.avatar, required this.joined})
      : bytes = avatar == null ? null : base64Decode(avatar);
  AppUser copyWith({String? name, String? avatar}) =>
      AppUser(uid: uid, username: username, name: name ?? this.name, avatar: avatar ?? this.avatar, joined: joined);
  Map<String, dynamic> toJson() => {'uid': uid, 'username': username, 'name': name, 'avatar': avatar, 'joined': joined.toIso8601String()};
  factory AppUser.fromJson(Map j) => AppUser(uid: j['uid'], username: j['username'], name: j['name'],
      avatar: j['avatar'], joined: DateTime.parse(j['joined']));
}

// ============ SERVICES (swap these for Firebase later) ============
class AuthError implements Exception {
  final String msg;
  AuthError(this.msg);
}

abstract class AuthSvc {
  Future<AppUser?> current();
  Future<AppUser> signUp(String name, String username, String pass);
  Future<AppUser> signIn(String username, String pass);
  Future<void> updateProfile(AppUser u);
  Future<void> signOut();
}

abstract class Repo {
  Future<List<Memory>> load(String uid);
  Future<void> save(String uid, Memory m);
  Future<void> remove(String uid, String id);
}

class LocalAuth implements AuthSvc {
  Map<String, dynamic> _users(SharedPreferences p) => Map<String, dynamic>.from(jsonDecode(p.getString('users') ?? '{}'));

  @override
  Future<AppUser?> current() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString('session');
    final u = s == null ? null : _users(p)[s];
    return u == null ? null : AppUser.fromJson(u['profile']);
  }

  @override
  Future<AppUser> signUp(String name, String username, String pass) async {
    final p = await SharedPreferences.getInstance();
    final users = _users(p);
    if (users.containsKey(username)) throw AuthError('That username is taken');
    final u = AppUser(uid: DateTime.now().millisecondsSinceEpoch.toString(), username: username, name: name, joined: DateTime.now());
    users[username] = {'pass': pass, 'profile': u.toJson()}; // placeholder: Firebase Auth replaces this
    await p.setString('users', jsonEncode(users));
    await p.setString('session', username);
    return u;
  }

  @override
  Future<AppUser> signIn(String username, String pass) async {
    final p = await SharedPreferences.getInstance();
    final u = _users(p)[username];
    if (u == null || u['pass'] != pass) throw AuthError('Wrong username or password');
    await p.setString('session', username);
    return AppUser.fromJson(u['profile']);
  }

  @override
  Future<void> updateProfile(AppUser u) async {
    final p = await SharedPreferences.getInstance();
    final users = _users(p);
    users[u.username]['profile'] = u.toJson();
    await p.setString('users', jsonEncode(users));
  }

  @override
  Future<void> signOut() async => (await SharedPreferences.getInstance()).remove('session');
}

class LocalRepo implements Repo {
  final _c = <String, List<Memory>>{};
  Future<void> _w(String uid) async => (await SharedPreferences.getInstance())
      .setString('mem_$uid', jsonEncode(_c[uid]!.map((m) => m.toJson()).toList()));

  @override
  Future<List<Memory>> load(String uid) async {
    final s = (await SharedPreferences.getInstance()).getString('mem_$uid');
    return _c[uid] = s == null ? <Memory>[] : (jsonDecode(s) as List).map((e) => Memory.fromJson(e)).toList();
  }

  @override
  Future<void> save(String uid, Memory m) async {
    final l = _c[uid] ??= [];
    final i = l.indexWhere((e) => e.id == m.id);
    if (i < 0) { l.add(m); } else { l[i] = m; }
    await _w(uid);
  }

  @override
  Future<void> remove(String uid, String id) async {
    _c[uid]?.removeWhere((e) => e.id == id);
    await _w(uid);
  }
}

final AuthSvc authSvc = FirebaseAuthSvc();
final Repo repoSvc = FirestoreRepo();

// ============ APP STATE ============
class App extends ChangeNotifier {
  AppUser? user;
  List<Memory> all = [];
  int? fy, fm;

  Future<void> boot() async {
    try {
      user = await authSvc.current();
      if (user != null) all = await repoSvc.load(user!.uid);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> signIn(String u, String p) async {
    user = await authSvc.signIn(u, p);
    all = await repoSvc.load(user!.uid);
    fy = fm = null;
    notifyListeners();
  }

  Future<void> signUp(String n, String u, String p) async {
    user = await authSvc.signUp(n, u, p);
    all = [];
    fy = fm = null;
    notifyListeners();
  }

  Future<void> signOut() async {
    await authSvc.signOut();
    user = null;
    all = [];
    notifyListeners();
  }

  Future<void> updateUser(AppUser u) async {
    user = u;
    notifyListeners();
    await authSvc.updateProfile(u);
  }

  List<Memory> get filtered => all
      .where((m) => (fy == null || m.date.year == fy) && (fm == null || m.date.month == fm! + 1))
      .toList()
    ..sort((a, b) => a.date.compareTo(b.date));

  List<Memory> get core => all.where((m) => m.core).toList()..sort((a, b) => a.date.compareTo(b.date));

  void setFilter(int? y, int? m) { fy = y; fm = m; notifyListeners(); }

  void put(Memory m) {
    final i = all.indexWhere((e) => e.id == m.id);
    if (i < 0) { all.add(m); } else { all[i] = m; }
    notifyListeners();
    repoSvc.save(user!.uid, m);
  }

  bool toggleCore(Memory m) {
    if (!m.core && core.length >= 5) return false;
    put(m.copyWith(core: !m.core));
    return true;
  }

  void remove(Memory m) {
    all.removeWhere((e) => e.id == m.id);
    notifyListeners();
    repoSvc.remove(user!.uid, m.id);
  }
}

final app = App();

// ============ MAIN ============
void main() async{
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Memory Vault',
    theme: ThemeData(
      brightness: Brightness.dark,
      fontFamily: 'serif',
      scaffoldBackgroundColor: bgDark,
      colorScheme: const ColorScheme.dark(primary: accent, surface: bgCard),
      appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, elevation: 0, centerTitle: true),
      navigationBarTheme: NavigationBarThemeData(backgroundColor: bgShelf, indicatorColor: accent.withOpacity(.18)),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: bgCard,
          contentTextStyle: TextStyle(color: textMain)),
    ),
    home: const Root(),
  ));
}

class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  bool splash = true;
  @override
  void initState() {
    super.initState();
    Future.wait([app.boot(), Future.delayed(const Duration(milliseconds: 2600))])
        .then((_) { if (mounted) setState(() => splash = false); });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (_, __) => AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
          child: splash
              ? const Splash(key: ValueKey('splash'))
              : app.user == null
                  ? const AuthPage(key: ValueKey('auth'))
                  : const Home(key: ValueKey('home')),
        ),
      );
}

// ============ ORB ============
class Orb extends StatefulWidget {
  final Color color;
  final Uint8List? image;
  final double size;
  final VoidCallback? onTap;
  const Orb({super.key, required this.color, this.image, this.size = 70, this.onTap});
  @override
  State<Orb> createState() => _OrbState();
}

class _OrbState extends State<Orb> with SingleTickerProviderStateMixin {
  late final c = AnimationController(vsync: this, duration: Duration(milliseconds: 2600 + Random().nextInt(1400)))
    ..repeat(reverse: true);
  @override
  void initState() { super.initState(); c.value = Random().nextDouble(); }
  @override
  void dispose() { c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final col = widget.color, s = widget.size;
    const ctr = Alignment(-.3, -.3);
    final shine = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(center: ctr, radius: .92, stops: const [0, .6],
            colors: [Colors.white.withOpacity(.8), Colors.white.withOpacity(0)]),
      ),
    );
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: c,
        builder: (_, __) {
          final t = Curves.easeInOut.transform(c.value);
          return Transform.translate(
            offset: Offset(0, -3 * t),
            child: Container(
              width: s, height: s,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: widget.image == null
                    ? RadialGradient(center: ctr, radius: .92, colors: [Colors.white, col, Colors.black], stops: const [0, .7, 1])
                    : null,
                boxShadow: [BoxShadow(color: col.withOpacity(.4 + .3 * t), blurRadius: s * (.3 + .15 * t), spreadRadius: s * .02)],
              ),
              child: widget.image == null
                  ? shine
                  : ClipOval(
                      child: Stack(fit: StackFit.expand, children: [
                        Image.memory(widget.image!, fit: BoxFit.cover, cacheWidth: (s * 3).round(), gaplessPlayback: true),
                        DecoratedBox(decoration: BoxDecoration(
                            gradient: RadialGradient(radius: .75, colors: [Colors.black.withOpacity(.2), Colors.black.withOpacity(.6)]))),
                        DecoratedBox(decoration: BoxDecoration(
                            gradient: RadialGradient(stops: const [.6, 1], colors: [Colors.transparent, col.withOpacity(.85)]))),
                        shine,
                      ]),
                    ),
            ),
          );
        },
      ),
    );
  }
}

// ============ DUST ============
class Dust extends StatefulWidget {
  const Dust({super.key});
  @override
  State<Dust> createState() => _DustState();
}

class _DustState extends State<Dust> with SingleTickerProviderStateMixin {
  late final c = AnimationController(vsync: this, duration: const Duration(seconds: 24))..repeat();
  final r = Random();
  late final ps = List.generate(30, (_) => [r.nextDouble(), r.nextDouble(), 1.0 + r.nextInt(2), 1 + r.nextDouble() * 1.8]);
  @override
  void dispose() { c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: AnimatedBuilder(animation: c, builder: (_, __) => CustomPaint(painter: _DustPainter(ps, c.value), size: Size.infinite)),
      );
}

class _DustPainter extends CustomPainter {
  final List<List<double>> ps;
  final double v;
  _DustPainter(this.ps, this.v);
  @override
  void paint(Canvas canvas, Size size) {
    for (final p in ps) {
      final t = (v * p[2] + p[1]) % 1;
      canvas.drawCircle(Offset(size.width * p[0] + sin(t * 12) * 18, size.height * (1 - t)), p[3],
          Paint()..color = const Color(0xFFFFD700).withOpacity(sin(t * pi) * .55));
    }
  }
  @override
  bool shouldRepaint(_) => true;
}

BoxDecoration warmBg() => const BoxDecoration(
    gradient: RadialGradient(center: Alignment(0, -.6), radius: 1.3, colors: [Color(0xFF3F2E28), bgDark]));

// ============ SPLASH ============
class Splash extends StatefulWidget {
  const Splash({super.key});
  @override
  State<Splash> createState() => _SplashState();
}

class _SplashState extends State<Splash> with SingleTickerProviderStateMixin {
  late final c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..forward();
  @override
  void dispose() { c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: warmBg(),
        child: Stack(children: [
          const Dust(),
          Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                for (int i = 0; i < 5; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: FadeTransition(
                      opacity: c.drive(CurveTween(curve: Interval(i * .1, .3 + i * .1))),
                      child: ScaleTransition(
                        scale: c.drive(CurveTween(curve: Interval(i * .1, .5 + i * .1, curve: Curves.easeOutBack))),
                        child: Orb(color: emoColor[Emo.values[i]]!, size: 46),
                      ),
                    ),
                  ),
              ]),
              const SizedBox(height: 36),
              FadeTransition(
                opacity: c.drive(CurveTween(curve: const Interval(.6, 1))),
                child: const Column(children: [
                  Text('Memory Vault', style: TextStyle(color: accent, fontSize: 34, letterSpacing: 2, shadows: [Shadow(color: Color(0x88F7D0A1), blurRadius: 16)])),
                  SizedBox(height: 6),
                  Text('where feelings glow', style: TextStyle(color: textMuted, fontStyle: FontStyle.italic)),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ============ AUTH ============
InputDecoration deco(String l, IconData i, {Widget? suffix}) {
  OutlineInputBorder b(Color c) => OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: c));
  return InputDecoration(
    labelText: l, labelStyle: const TextStyle(color: textMuted), filled: true, fillColor: bgCard,
    prefixIcon: Icon(i, color: textMuted, size: 20), suffixIcon: suffix,
    border: b(borderWarm), enabledBorder: b(borderWarm), focusedBorder: b(accent),
  );
}

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});
  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  bool signup = false, busy = false, hide = true;
  String? err;
  final name = TextEditingController(), user = TextEditingController(), pass = TextEditingController();

  Future<void> submit() async {
    final u = user.text.trim().toLowerCase(), p = pass.text;
    String? e;
    if (signup && name.text.trim().isEmpty) {
      e = 'Tell us what to call you';
    } else if (!RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(u)) {
      e = 'Username: 3-20 letters, numbers or _';
    } else if (p.length < 6) {
      e = 'Password needs at least 6 characters';
    }
    if (e != null) { setState(() => err = e); return; }
    setState(() { busy = true; err = null; });
    try {
      if (signup) { await app.signUp(name.text.trim(), u, p); } else { await app.signIn(u, p); }
    } on AuthError catch (x) {
      if (mounted) setState(() => err = x.msg);
    } catch (_) {
      if (mounted) setState(() => err = 'Something went wrong. Try again.');
    }
    if (mounted) setState(() => busy = false);
  }

  Widget tab(String l, bool on) => Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() { signup = l == 'Sign up'; err = null; }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200), padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(color: on ? bgCard : Colors.transparent, borderRadius: BorderRadius.circular(12),
                border: Border.all(color: on ? accent.withOpacity(.6) : Colors.transparent)),
            child: Center(child: Text(l, style: TextStyle(color: on ? accent : textMuted))),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: warmBg(),
        child: Stack(children: [
          const Dust(),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Column(children: [
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      for (final e in Emo.values) Padding(padding: const EdgeInsets.all(7), child: Orb(color: emoColor[e]!, size: 28)),
                    ]),
                    const SizedBox(height: 18),
                    const Text('Memory Vault', style: TextStyle(color: accent, fontSize: 30, letterSpacing: 1.5)),
                    const SizedBox(height: 4),
                    Text(signup ? 'start your own shelf of feelings' : 'welcome back, your memories kept the lights on',
                        textAlign: TextAlign.center, style: const TextStyle(color: textMuted, fontStyle: FontStyle.italic)),
                    const SizedBox(height: 28),
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(color: bgShelf, borderRadius: BorderRadius.circular(14)),
                      child: Row(children: [tab('Log in', !signup), tab('Sign up', signup)]),
                    ),
                    const SizedBox(height: 20),
                    if (signup) ...[
                      TextField(controller: name, textCapitalization: TextCapitalization.words, decoration: deco('Your name', Icons.face_rounded)),
                      const SizedBox(height: 14),
                    ],
                    TextField(controller: user, autocorrect: false, decoration: deco('Username', Icons.alternate_email_rounded)),
                    const SizedBox(height: 14),
                    TextField(
                      controller: pass, obscureText: hide, onSubmitted: (_) => submit(),
                      decoration: deco('Password', Icons.lock_outline_rounded,
                          suffix: IconButton(icon: Icon(hide ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20, color: textMuted),
                              onPressed: () => setState(() => hide = !hide))),
                    ),
                    if (err != null)
                      Padding(padding: const EdgeInsets.only(top: 14), child: Text(err!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFFF8A80)))),
                    const SizedBox(height: 22),
                    FilledButton(
                      onPressed: busy ? null : submit,
                      style: FilledButton.styleFrom(backgroundColor: accent, foregroundColor: bgShelf,
                          minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                      child: busy
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: bgShelf))
                          : Text(signup ? 'Create my vault' : 'Open my vault', style: const TextStyle(fontSize: 16)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ============ HOME ============
class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (_, __) => Scaffold(
        appBar: AppBar(
          title: const Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Memory Vault', style: TextStyle(color: accent, fontSize: 22, letterSpacing: 1.5, shadows: [Shadow(color: Color(0x66F7D0A1), blurRadius: 12)])),
            Text('where feelings glow', style: TextStyle(color: textMuted, fontSize: 11, fontStyle: FontStyle.italic)),
          ]),
          actions: [
            if (tab == 0)
              IconButton(
                icon: Badge(isLabelVisible: app.fy != null || app.fm != null, smallSize: 8, child: const Icon(Icons.tune_rounded, color: accent)),
                onPressed: () => showModalBottomSheet(context: context, backgroundColor: bgCard, builder: (_) => const FilterSheet()),
              ),
          ],
        ),
        body: Container(
          decoration: warmBg(),
          child: Stack(children: [
            const Dust(),
            SafeArea(child: [const VaultPage(), const CorePage(), const ProfilePage()][tab]),
          ]),
        ),
        floatingActionButton: tab == 2
            ? null
            : FloatingActionButton.extended(
                backgroundColor: accent, foregroundColor: bgShelf,
                icon: const Icon(Icons.add_rounded), label: const Text('New memory'),
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AddPage())),
              ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.blur_circular_rounded), label: 'Vault'),
            NavigationDestination(icon: Icon(Icons.auto_awesome_rounded), label: 'Core'),
            NavigationDestination(icon: Icon(Icons.person_rounded), label: 'Profile'),
          ],
        ),
      ),
    );
  }
}

// ============ VAULT ============
class VaultPage extends StatelessWidget {
  const VaultPage({super.key});
  static const perRack = Rack.rows * Rack.cols;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (_, __) {
        final list = app.filtered;
        final racks = list.isEmpty ? 1 : (list.length / perRack).ceil();
        final h = DateTime.now().hour;
        final g = h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening';
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
            child: Row(children: [
              Expanded(child: Text('$g, ${app.user!.name.split(' ').first} ✦', style: const TextStyle(color: textMain, fontSize: 16), overflow: TextOverflow.ellipsis)),
              Text('${app.all.length} ${app.all.length == 1 ? 'memory' : 'memories'}', style: const TextStyle(color: textMuted, fontSize: 12)),
            ]),
          ),
          if (app.fy != null || app.fm != null)
            Chip(
              backgroundColor: bgCard, side: const BorderSide(color: borderWarm),
              label: Text('${app.fm != null ? months[app.fm!] : 'All months'} ${app.fy ?? ''}', style: const TextStyle(color: accent)),
              deleteIcon: const Icon(Icons.close, size: 16), onDeleted: () => app.setFilter(null, null),
            ),
          Expanded(child: RackPager(key: ValueKey('${app.fy}-${app.fm}-${list.length}'), list: list, racks: racks)),
          const SizedBox(height: 56),
        ]);
      },
    );
  }
}

class RackPager extends StatefulWidget {
  final List<Memory> list;
  final int racks;
  const RackPager({super.key, required this.list, required this.racks});
  @override
  State<RackPager> createState() => _RackPagerState();
}

class _RackPagerState extends State<RackPager> {
  late final pc = PageController(initialPage: widget.racks - 1);
  late int page = widget.racks - 1;
  @override
  void dispose() { pc.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: PageView.builder(
          controller: pc, itemCount: widget.racks,
          onPageChanged: (i) => setState(() => page = i),
          itemBuilder: (_, r) => Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
            child: Rack(items: widget.list.skip(r * VaultPage.perRack).take(VaultPage.perRack).toList()),
          ),
        ),
      ),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (int i = 0; i < widget.racks; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 250), margin: const EdgeInsets.all(3),
            width: i == page ? 18 : 6, height: 6,
            decoration: BoxDecoration(color: i == page ? accent : borderWarm, borderRadius: BorderRadius.circular(3)),
          ),
      ]),
      Text('Rack ${page + 1} of ${widget.racks}', style: const TextStyle(color: textMuted, fontSize: 12, fontStyle: FontStyle.italic)),
    ]);
  }
}

class Rack extends StatelessWidget {
  final List<Memory> items;
  static const rows = 6, cols = 4;
  const Rack({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: bgShelf, borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderWarm, width: 2),
        boxShadow: [const BoxShadow(color: Colors.black54, blurRadius: 20, offset: Offset(0, 8)), BoxShadow(color: accent.withOpacity(.06), blurRadius: 30)],
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(builder: (_, c) {
        final shelfH = c.maxHeight / rows;
        final size = min(70.0, max(28.0, min(c.maxWidth / cols * .78, shelfH - 26)));
        return Stack(children: [
          Column(children: [
            for (int s = 0; s < rows; s++)
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: const Border(bottom: BorderSide(color: Color(0xFF140E0D), width: 6)),
                    gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
                        colors: [Colors.transparent, accent.withOpacity(.06)]),
                  ),
                  child: Row(children: [
                    for (int i = 0; i < cols; i++)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: s * cols + i < items.length
                                ? Orb(color: emoColor[items[s * cols + i].emo]!, image: items[s * cols + i].bytes, size: size,
                                    onTap: () => openMemory(context, items[s * cols + i].id))
                                : Container(width: size * .55, height: size * .55,
                                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: borderWarm.withOpacity(.35)))),
                          ),
                        ),
                      ),
                  ]),
                ),
              ),
          ]),
          if (items.isEmpty)
            Center(
              child: Text(app.all.isEmpty ? 'A quiet shelf, waiting for\nits first glowing memory ✦' : 'Nothing glows here yet.\nTry another month ✦',
                  textAlign: TextAlign.center, style: const TextStyle(color: textMuted, fontStyle: FontStyle.italic, height: 1.5)),
            ),
        ]);
      }),
    );
  }
}

class FilterSheet extends StatelessWidget {
  const FilterSheet({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (_, __) {
        final years = {DateTime.now().year, ...app.all.map((m) => m.date.year)}.toList()..sort((a, b) => b.compareTo(a));
        Widget chip(String l, bool sel, VoidCallback f) => ChoiceChip(
              label: Text(l), selected: sel, onSelected: (_) => f(), selectedColor: accent, backgroundColor: bgShelf,
              labelStyle: TextStyle(color: sel ? bgShelf : textMain), showCheckmark: false,
            );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Year', style: TextStyle(color: accent, fontSize: 16)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                chip('All', app.fy == null, () => app.setFilter(null, app.fm)),
                for (final y in years) chip('$y', app.fy == y, () => app.setFilter(y, app.fm)),
              ]),
              const SizedBox(height: 16),
              const Text('Month', style: TextStyle(color: accent, fontSize: 16)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                chip('All', app.fm == null, () => app.setFilter(app.fy, null)),
                for (int i = 0; i < 12; i++) chip(months[i], app.fm == i, () => app.setFilter(app.fy, i)),
              ]),
            ]),
          ),
        );
      },
    );
  }
}

// ============ CORE ============
class CorePage extends StatelessWidget {
  const CorePage({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (_, __) {
        final core = app.core;
        final w = (MediaQuery.of(context).size.width - 56) / 2;
        return ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 100), children: [
          const Center(child: Text('✦ Core Memories ✦', style: TextStyle(color: accent, fontSize: 26))),
          const SizedBox(height: 4),
          Center(child: Text('${core.length}/5 pedestals glowing', style: const TextStyle(color: textMuted, fontStyle: FontStyle.italic))),
          const SizedBox(height: 24),
          Wrap(spacing: 16, runSpacing: 16, alignment: WrapAlignment.center, children: [
            for (int i = 0; i < 5; i++)
              GestureDetector(
                onTap: i < core.length ? null : () => snack(context, 'Open a memory and tap Pin to place it here'),
                child: Container(
                  width: w, padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 10),
                  decoration: BoxDecoration(
                    color: bgCard, borderRadius: BorderRadius.circular(16), border: Border.all(color: borderWarm),
                    boxShadow: [BoxShadow(color: (i < core.length ? emoColor[core[i].emo]! : Colors.black).withOpacity(.28), blurRadius: 24, offset: const Offset(0, 6))],
                  ),
                  child: Column(children: [
                    if (i < core.length)
                      Orb(color: emoColor[core[i].emo]!, image: core[i].bytes, size: 84, onTap: () => openMemory(context, core[i].id))
                    else
                      Container(width: 84, height: 84, decoration: BoxDecoration(shape: BoxShape.circle, color: bgDark, border: Border.all(color: borderWarm, width: 2))),
                    const SizedBox(height: 14),
                    Text(i < core.length ? core[i].title : 'Empty slot', maxLines: 2, overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center, style: const TextStyle(color: textMuted, fontSize: 12, letterSpacing: 1)),
                  ]),
                ),
              ),
          ]),
        ]);
      },
    );
  }
}

// ============ MEMORY POPUP ============
void openMemory(BuildContext context, String id) => showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'close',
      barrierColor: const Color(0xD90F0A09),
      transitionDuration: const Duration(milliseconds: 250),
      transitionBuilder: (_, a, __, child) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 5 * a.value, sigmaY: 5 * a.value),
        child: FadeTransition(
          opacity: a,
          child: ScaleTransition(scale: Tween(begin: .92, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOut)), child: child),
        ),
      ),
      pageBuilder: (_, __, ___) => DetailCard(id: id),
    );

class DetailCard extends StatelessWidget {
  final String id;
  const DetailCard({super.key, required this.id});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (ctx, _) {
        final m = app.all.where((e) => e.id == id).firstOrNull;
        if (m == null) return const SizedBox();
        final col = emoColor[m.emo]!;
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Material(
              color: bgCard,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: borderWarm, width: 2)),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 420, maxHeight: MediaQuery.of(ctx).size.height * .8),
                child: Stack(children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(22, 28, 22, 14),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Orb(color: col, image: m.bytes, size: 84),
                      const SizedBox(height: 18),
                      Text(m.title, textAlign: TextAlign.center, style: const TextStyle(color: accent, fontSize: 22)),
                      const SizedBox(height: 6),
                      Text('${fmt(m.date)} • ${m.emo.name.toUpperCase()}${m.core ? ' • CORE MEMORY' : ''}',
                          textAlign: TextAlign.center, style: TextStyle(color: col, fontSize: 11, letterSpacing: 1)),
                      if (m.text.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(m.text, style: const TextStyle(color: textMain, fontSize: 15, height: 1.6)),
                      ],
                      if (m.bytes != null) ...[
                        const SizedBox(height: 16),
                        ClipRRect(borderRadius: BorderRadius.circular(14), child: Image.memory(m.bytes!, fit: BoxFit.cover)),
                      ],
                      const SizedBox(height: 10),
                      Wrap(alignment: WrapAlignment.center, children: [
                        TextButton.icon(
                          icon: Icon(m.core ? Icons.star_rounded : Icons.star_border_rounded, color: accent),
                          label: Text(m.core ? 'Unpin' : 'Pin', style: const TextStyle(color: accent)),
                          onPressed: () { if (!app.toggleCore(m)) snack(ctx, 'Core shelf is full (5/5). Unpin one first.'); },
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.edit_outlined, color: textMuted),
                          label: const Text('Edit', style: TextStyle(color: textMuted)),
                          onPressed: () {
                            final nav = Navigator.of(ctx);
                            nav.pop();
                            nav.push(MaterialPageRoute(builder: (_) => AddPage(edit: m)));
                          },
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.delete_outline_rounded, color: textMuted),
                          label: const Text('Delete', style: TextStyle(color: textMuted)),
                          onPressed: () async {
                            final ok = await showDialog<bool>(
                              context: ctx,
                              builder: (d) => AlertDialog(
                                backgroundColor: bgCard, title: const Text('Let this memory go?'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Keep')),
                                  TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
                                ],
                              ),
                            );
                            if (ok == true && ctx.mounted) { Navigator.pop(ctx); app.remove(m); }
                          },
                        ),
                      ]),
                    ]),
                  ),
                  Positioned(top: 4, right: 4, child: IconButton(icon: const Icon(Icons.close_rounded, color: textMuted), onPressed: () => Navigator.pop(ctx))),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ============ ADD / EDIT ============
class AddPage extends StatefulWidget {
  final Memory? edit;
  const AddPage({super.key, this.edit});
  @override
  State<AddPage> createState() => _AddPageState();
}

class _AddPageState extends State<AddPage> {
  late final title = TextEditingController(text: widget.edit?.title == 'Untitled memory' ? '' : widget.edit?.title ?? '');
  late final diary = TextEditingController(text: widget.edit?.text ?? '');
  late Emo emo = widget.edit?.emo ?? Emo.joy;
  late DateTime date = widget.edit?.date ?? DateTime.now();
  late bool core = widget.edit?.core ?? false;
  late String? b64 = widget.edit?.image;
  late Uint8List? bytes = widget.edit?.bytes;

  Future<void> pick() async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 900, imageQuality: 70);
    if (f == null) return;
    final b = await f.readAsBytes();
    if (mounted) setState(() { bytes = b; b64 = base64Encode(b); });
  }

  Future<void> pickDate() async {
    final d = await showDatePicker(context: context, initialDate: date, firstDate: DateTime(2000), lastDate: DateTime.now());
    if (d != null) setState(() => date = d);
  }

  void save() {
    if (title.text.trim().isEmpty && diary.text.trim().isEmpty && b64 == null) {
      snack(context, 'Add a photo or write something first ✦');
      return;
    }
    app.put(Memory(
      id: widget.edit?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      title: title.text.trim().isEmpty ? 'Untitled memory' : title.text.trim(),
      text: diary.text.trim(), emo: emo, image: b64, core: core, date: date,
    ));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context)),
        title: TextButton.icon(
          onPressed: pickDate,
          icon: const Icon(Icons.calendar_today_rounded, size: 14, color: textMuted),
          label: Text(fmt(date), style: const TextStyle(color: textMuted, fontSize: 14)),
        ),
        actions: [TextButton(onPressed: save, child: const Text('Save', style: TextStyle(color: accent, fontSize: 16)))],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 40), children: [
        GestureDetector(
          onTap: pick,
          child: Container(
            height: 240, clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: bgCard, borderRadius: BorderRadius.circular(20), border: Border.all(color: borderWarm)),
            child: bytes == null
                ? const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.add_photo_alternate_outlined, color: accent, size: 40),
                    SizedBox(height: 8),
                    Text('Add a photo', style: TextStyle(color: textMuted)),
                  ])
                : Stack(fit: StackFit.expand, children: [
                    Image.memory(bytes!, fit: BoxFit.cover),
                    Positioned(
                      top: 8, right: 8,
                      child: GestureDetector(
                        onTap: () => setState(() { bytes = null; b64 = null; }),
                        child: const CircleAvatar(radius: 15, backgroundColor: Colors.black54, child: Icon(Icons.close, size: 16, color: Colors.white)),
                      ),
                    ),
                  ]),
          ),
        ),
        const SizedBox(height: 24),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          for (final e in Emo.values)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => emo = e),
              child: AnimatedScale(
                scale: emo == e ? 1.15 : .85, duration: const Duration(milliseconds: 200),
                child: Opacity(
                  opacity: emo == e ? 1 : .55,
                  child: Column(children: [
                    IgnorePointer(child: Orb(color: emoColor[e]!, size: 48)),
                    const SizedBox(height: 8),
                    Text(cap(e.name), style: TextStyle(fontSize: 11, color: emo == e ? emoColor[e] : textMuted)),
                  ]),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 14),
        Center(child: Text(emoTag[emo]!, style: TextStyle(color: emoColor[emo], fontStyle: FontStyle.italic, fontSize: 13))),
        const SizedBox(height: 18),
        TextField(
          controller: title, textCapitalization: TextCapitalization.sentences,
          style: const TextStyle(fontSize: 24, color: accent),
          decoration: const InputDecoration(hintText: 'Title', hintStyle: TextStyle(color: borderWarm), border: InputBorder.none),
        ),
        const Divider(color: borderWarm),
        TextField(
          controller: diary, minLines: 8, maxLines: null, textCapitalization: TextCapitalization.sentences,
          style: const TextStyle(fontSize: 16, height: 1.6, color: textMain),
          decoration: const InputDecoration(hintText: 'What happened? How did it feel...', hintStyle: TextStyle(color: borderWarm), border: InputBorder.none),
        ),
        const Divider(color: borderWarm),
        SwitchListTile(
          contentPadding: EdgeInsets.zero, value: core,
          title: const Text('Core memory'),
          subtitle: Text('${app.core.length}/5 pedestals used', style: const TextStyle(color: textMuted, fontSize: 12)),
          onChanged: (v) {
            if (v && !(widget.edit?.core ?? false) && app.core.length >= 5) {
              snack(context, 'Core shelf is full (5/5). Unpin one first.');
              return;
            }
            setState(() => core = v);
          },
        ),
      ]),
    );
  }
}

// ============ PROFILE ============
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  Future<void> pickAvatar() async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 400, imageQuality: 70);
    if (f != null) app.updateUser(app.user!.copyWith(avatar: base64Encode(await f.readAsBytes())));
  }

  Future<void> editName(BuildContext ctx) async {
    final c = TextEditingController(text: app.user!.name);
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (d) => AlertDialog(
        backgroundColor: bgCard, title: const Text('Your name'),
        content: TextField(controller: c, autofocus: true, textCapitalization: TextCapitalization.words, decoration: deco('Name', Icons.face_rounded)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true && c.text.trim().isNotEmpty) app.updateUser(app.user!.copyWith(name: c.text.trim()));
  }

  Future<void> confirmOut(BuildContext ctx) async {
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (d) => AlertDialog(
        backgroundColor: bgCard, title: const Text('Sign out?'),
        content: const Text('Your memories stay safe in the vault.', style: TextStyle(color: textMuted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Stay')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (ok == true) app.signOut();
  }

  Widget stat(String v, String l) => Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4), padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(color: bgCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: borderWarm)),
          child: Column(children: [
            Text(v, style: const TextStyle(color: accent, fontSize: 24)),
            Text(l, style: const TextStyle(color: textMuted, fontSize: 11)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (ctx, _) {
        final u = app.user;
        if (u == null) return const SizedBox();
        final counts = {for (final e in Emo.values) e: app.all.where((m) => m.emo == e).length};
        final maxC = max(1, counts.values.reduce(max));
        return ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 40), children: [
          Center(
            child: SizedBox(
              width: 120, height: 120,
              child: Stack(alignment: Alignment.center, children: [
                Orb(color: accent, image: u.bytes, size: 104, onTap: pickAvatar),
                if (u.bytes == null)
                  IgnorePointer(child: Text(u.name[0].toUpperCase(), style: const TextStyle(fontSize: 42, color: bgShelf, fontWeight: FontWeight.bold))),
                Positioned(
                  bottom: 4, right: 4,
                  child: GestureDetector(
                    onTap: pickAvatar,
                    child: const CircleAvatar(radius: 16, backgroundColor: bgCard, child: Icon(Icons.camera_alt_rounded, size: 16, color: accent)),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Flexible(child: Text(u.name, style: const TextStyle(color: accent, fontSize: 24), overflow: TextOverflow.ellipsis)),
            IconButton(icon: const Icon(Icons.edit_outlined, size: 18, color: textMuted), onPressed: () => editName(ctx)),
          ]),
          Center(child: Text('@${u.username} • joined ${months[u.joined.month - 1]} ${u.joined.year}', style: const TextStyle(color: textMuted, fontSize: 12))),
          const SizedBox(height: 22),
          Row(children: [
            stat('${app.all.length}', 'Memories'),
            stat('${app.core.length}/5', 'Core'),
            stat('${max(1, (app.all.length / VaultPage.perRack).ceil())}', 'Racks'),
          ]),
          const SizedBox(height: 26),
          const Text('Your emotional mix', style: TextStyle(color: accent, fontSize: 16)),
          const SizedBox(height: 12),
          for (final e in Emo.values)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Orb(color: emoColor[e]!, size: 22),
                const SizedBox(width: 12),
                SizedBox(width: 62, child: Text(cap(e.name), style: const TextStyle(color: textMuted, fontSize: 13))),
                Expanded(
                  child: LinearProgressIndicator(
                    value: counts[e]! / maxC, minHeight: 8, borderRadius: BorderRadius.circular(4),
                    color: emoColor[e], backgroundColor: bgShelf,
                  ),
                ),
                SizedBox(width: 34, child: Text('${counts[e]}', textAlign: TextAlign.end, style: const TextStyle(color: textMain))),
              ]),
            ),
          const SizedBox(height: 30),
          OutlinedButton.icon(
            onPressed: () => confirmOut(ctx),
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('Sign out'),
            style: OutlinedButton.styleFrom(foregroundColor: accent, side: const BorderSide(color: borderWarm),
                minimumSize: const Size.fromHeight(50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          ),
          const SizedBox(height: 18),
          const Center(child: Text('made with feelings ✦ v1.0', style: TextStyle(color: borderWarm, fontSize: 11))),
        ]);
      },
    );
  }
}

class FirebaseAuthSvc implements AuthSvc {
  final _a = FirebaseAuth.instance, _db = FirebaseFirestore.instance;
  String _mail(String u) => '$u@memoryvault.app';

  Future<AppUser> _profile(String uid) async =>
      AppUser.fromJson((await _db.collection('users').doc(uid).get()).data()!);

  @override
  Future<AppUser?> current() async {
    final u = _a.currentUser;
    return u == null ? null : _profile(u.uid);
  }

  @override
  Future<AppUser> signUp(String name, String username, String pass) async {
    try {
      final c = await _a.createUserWithEmailAndPassword(email: _mail(username), password: pass);
      final u = AppUser(uid: c.user!.uid, username: username, name: name, joined: DateTime.now());
      await _db.collection('users').doc(u.uid).set(u.toJson());
      return u;
    } on FirebaseAuthException catch (e) {
      throw AuthError(e.code == 'email-already-in-use' ? 'That username is taken' : 'Could not sign up (${e.code})');
    }
  }

  @override
  Future<AppUser> signIn(String username, String pass) async {
    try {
      final c = await _a.signInWithEmailAndPassword(email: _mail(username), password: pass);
      return _profile(c.user!.uid);
    } on FirebaseAuthException {
      throw AuthError('Wrong username or password');
    }
  }

  @override
  Future<void> updateProfile(AppUser u) => _db.collection('users').doc(u.uid).set(u.toJson());
  @override
  Future<void> signOut() => _a.signOut();
}

class FirestoreRepo implements Repo {
  CollectionReference<Map<String, dynamic>> _c(String uid) =>
      FirebaseFirestore.instance.collection('users/$uid/memories');
  @override
  Future<List<Memory>> load(String uid) async =>
      (await _c(uid).get()).docs.map((d) => Memory.fromJson(d.data())).toList();
  @override
  Future<void> save(String uid, Memory m) => _c(uid).doc(m.id).set(m.toJson());
  @override
  Future<void> remove(String uid, String id) => _c(uid).doc(id).delete();
}