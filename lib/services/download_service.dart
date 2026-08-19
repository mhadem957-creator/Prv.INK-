import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_downloader/flutter_downloader.dart'
    show DownloadTaskStatus;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Reliable in-app downloads with public folder copy + notifications.
class DownloadService extends ChangeNotifier {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  final List<DownloadItem> _items = [];
  bool _initialized = false;
  final Map<String, HttpClient> _clients = {};
  final Map<String, bool> _cancel = {};
  final FlutterLocalNotificationsPlugin _notifs =
      FlutterLocalNotificationsPlugin();
  bool _notifsReady = false;
  int _notifIdSeq = 1000;

  List<DownloadItem> get items => List.unmodifiable(_items);
  List<DownloadItem> get active => _items
      .where((e) =>
          e.status == DownloadTaskStatus.running ||
          e.status == DownloadTaskStatus.enqueued)
      .toList();
  List<DownloadItem> get completed =>
      _items.where((e) => e.status == DownloadTaskStatus.complete).toList();

  static const Set<String> downloadableExtensions = {
    'apk', 'mp3', 'mp4', 'm4a', 'ogg', 'wav', 'flac', 'webm', 'mkv', 'avi',
    'zip', 'rar', '7z', 'tar', 'gz', 'pdf', 'epub', 'mobi', 'doc', 'docx',
    'xls', 'xlsx', 'ppt', 'pptx', 'jpg', 'jpeg', 'png', 'gif', 'webp', 'svg',
    'txt', 'csv', 'json',
  };

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    await _initNotifications();
  }

  Future<void> rebind() async {}

  Future<void> _initNotifications() async {
    if (_notifsReady) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const init = InitializationSettings(android: android);
      await _notifs.initialize(init);
      // Android 13+ notification permission is requested in _ensurePermissions
      final androidPlugin = _notifs.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(
        const AndroidNotificationChannel(
          'ink_downloads',
          'Downloads',
          description: 'INK download progress and completion',
          importance: Importance.low,
        ),
      );
      _notifsReady = true;
    } catch (e) {
      debugPrint('notifications init: $e');
    }
  }

  Future<void> _notify({
    required int id,
    required String title,
    required String body,
    bool ongoing = false,
    int? progress,
    int? maxProgress,
  }) async {
    if (!_notifsReady) return;
    try {
      await _notifs.show(
        id,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            'ink_downloads',
            'Downloads',
            channelDescription: 'INK download progress and completion',
            importance: ongoing ? Importance.low : Importance.defaultImportance,
            priority: ongoing ? Priority.low : Priority.defaultPriority,
            ongoing: ongoing,
            onlyAlertOnce: true,
            showProgress: progress != null,
            maxProgress: maxProgress ?? 100,
            progress: progress ?? 0,
            indeterminate: ongoing && progress == null,
            icon: '@mipmap/ic_launcher',
          ),
        ),
      );
    } catch (e) {
      debugPrint('notify error: $e');
    }
  }

  Future<void> _cancelNotif(int id) async {
    try {
      await _notifs.cancel(id);
    } catch (_) {}
  }

  bool isDownloadableUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path.toLowerCase();
      final last =
          path.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => '');
      final ext =
          last.contains('.') ? last.split('.').last.split('?').first : '';
      if (downloadableExtensions.contains(ext)) return true;
      final q = uri.query.toLowerCase();
      return q.contains('apk') ||
          q.contains('download') ||
          path.contains('/apk/') ||
          path.endsWith('.apk');
    } catch (_) {
      return false;
    }
  }

  static String categoryFor(String filename) {
    final ext = filename.contains('.')
        ? filename.split('.').last.toLowerCase()
        : '';
    if (const {'mp3', 'm4a', 'ogg', 'wav', 'flac'}.contains(ext)) return 'Music';
    if (const {'mp4', 'webm', 'mkv', 'avi'}.contains(ext)) return 'Videos';
    if (ext == 'apk') return 'Apps';
    if (const {'pdf', 'epub', 'mobi', 'doc', 'docx', 'txt'}.contains(ext)) {
      return 'Documents';
    }
    return 'Other';
  }

  Future<void> _ensurePermissions({bool forApk = false}) async {
    if (!Platform.isAndroid) return;
    try {
      if (!(await Permission.notification.isGranted)) {
        await Permission.notification.request();
      }
    } catch (_) {}
    try {
      if (await Permission.storage.isDenied) await Permission.storage.request();
    } catch (_) {}
    try {
      // Helps writing into public Download/ on some OEMs
      if (await Permission.manageExternalStorage.isDenied) {
        // Don't force settings sheet every time — best effort only once later
      }
    } catch (_) {}
    if (forApk) {
      try {
        if (!(await Permission.requestInstallPackages.isGranted)) {
          await Permission.requestInstallPackages.request();
        }
      } catch (_) {}
    }
  }

  /// App-private working directory (always writable).
  Future<String> _privateDir() async {
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final dir = Directory('${ext.path}/Downloads');
        if (!await dir.exists()) await dir.create(recursive: true);
        return dir.path;
      }
    } catch (_) {}
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/Downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// Public folder visible in the system Files app: Download/INK/
  Future<String?> _publicDir() async {
    final candidates = <String>[
      '/storage/emulated/0/Download/INK',
      '/storage/emulated/0/Downloads/INK',
      '/sdcard/Download/INK',
    ];
    for (final path in candidates) {
      try {
        final dir = Directory(path);
        if (!await dir.exists()) await dir.create(recursive: true);
        final probe = File('${dir.path}/.ink_w');
        await probe.writeAsString('ok', flush: true);
        await probe.delete();
        return dir.path;
      } catch (e) {
        debugPrint('public dir fail $path: $e');
      }
    }
    return null;
  }

  Future<String> _uniqueName(String dir, String name) async {
    final base = name.contains('.')
        ? name.substring(0, name.lastIndexOf('.'))
        : name;
    final ext = name.contains('.') ? name.substring(name.lastIndexOf('.')) : '';
    var candidate = name;
    var i = 1;
    while (await File('$dir/$candidate').exists()) {
      candidate = '${base}_$i$ext';
      i++;
      if (i > 200) break;
    }
    return candidate;
  }

  String _safeFileName(String raw) {
    var name = raw.split('?').first.split('#').first;
    if (name.contains('/')) name = name.split('/').last;
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (name.isEmpty || name == '.' || name == '..') {
      name = 'download_${DateTime.now().millisecondsSinceEpoch}';
    }
    if (name.length > 120) {
      final ext = name.contains('.') ? '.${name.split('.').last}' : '';
      name = '${name.substring(0, 120 - ext.length)}$ext';
    }
    return name;
  }

  Future<String?> enqueue({
    required String url,
    String? fileName,
    bool showNotification = true,
  }) async {
    await initialize();

    var name = _safeFileName(
      fileName ??
          () {
            try {
              return Uri.parse(url).pathSegments.lastWhere(
                    (s) => s.isNotEmpty,
                    orElse: () =>
                        'download_${DateTime.now().millisecondsSinceEpoch}',
                  );
            } catch (_) {
              return 'download_${DateTime.now().millisecondsSinceEpoch}';
            }
          }(),
    );

    final lower = url.toLowerCase();
    if ((lower.contains('.apk') || lower.contains('application/vnd.android')) &&
        !name.toLowerCase().endsWith('.apk')) {
      name = '$name.apk';
    }

    await _ensurePermissions(forApk: name.toLowerCase().endsWith('.apk'));
    final privateDir = await _privateDir();
    name = await _uniqueName(privateDir, name);
    final taskId = 'ink_${DateTime.now().microsecondsSinceEpoch}';
    final notifId = ++_notifIdSeq;

    // Soft limit concurrent downloads to keep the UI responsive.
    final running = _items
        .where((e) => e.status == DownloadTaskStatus.running)
        .length;
    if (running >= 3) {
      // Still enqueue — will run; user sees it queued.
    }

    final item = DownloadItem(
      taskId: taskId,
      url: url,
      fileName: name,
      savedDir: privateDir,
      progress: 0,
      status: DownloadTaskStatus.enqueued,
      notifId: notifId,
    );
    _items.insert(0, item);
    notifyListeners();

    await _notify(
      id: notifId,
      title: 'Downloading',
      body: name,
      ongoing: true,
      progress: 0,
      maxProgress: 100,
    );

    unawaited(_download(item));
    return taskId;
  }

  Future<void> _download(DownloadItem item) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 45)
      ..idleTimeout = const Duration(minutes: 5)
      ..autoUncompress = true
      ..badCertificateCallback = (cert, host, port) => true;

    _clients[item.taskId] = client;
    _cancel[item.taskId] = false;

    final dest = '${item.savedDir}/${item.fileName}';
    final part = '$dest.part';

    try {
      item.status = DownloadTaskStatus.running;
      item.error = null;
      item.progress = 0;
      notifyListeners();

      var uri = Uri.parse(item.url);
      HttpClientResponse? response;

      for (var hop = 0; hop < 10; hop++) {
        final req = await client.getUrl(uri);
        req.followRedirects = false;
        req.headers.set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36',
        );
        req.headers.set(HttpHeaders.acceptHeader, '*/*');
        req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        response = await req.close();

        if (response.statusCode >= 300 &&
            response.statusCode < 400 &&
            response.headers.value(HttpHeaders.locationHeader) != null) {
          final loc = response.headers.value(HttpHeaders.locationHeader)!;
          uri = uri.resolve(loc);
          await response.drain<void>();
          continue;
        }
        break;
      }

      if (response == null) throw const HttpException('No response');
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}');
      }

      final cd = response.headers.value('content-disposition');
      if (cd != null) {
        final m =
            RegExp(r'filename\*?=([^;]+)', caseSensitive: false).firstMatch(cd);
        if (m != null) {
          var raw = m.group(1)!.trim();
          if (raw.toLowerCase().startsWith("utf-8''")) {
            raw = raw.substring(7);
          }
          raw = raw.replaceAll('"', '').replaceAll("'", '');
          try {
            raw = Uri.decodeFull(raw);
          } catch (_) {}
          final suggested = _safeFileName(raw);
          if (suggested.isNotEmpty) item.fileName = suggested;
        }
      }

      final total = response.contentLength;
      final file = File(part);
      final sink = file.openWrite();
      var received = 0;
      var lastPct = -1;
      var lastNotifPct = -1;

      await for (final chunk in response) {
        if (_cancel[item.taskId] == true) {
          await sink.close();
          try {
            if (await file.exists()) await file.delete();
          } catch (_) {}
          item.status = DownloadTaskStatus.canceled;
          item.progress = 0;
          notifyListeners();
          await _cancelNotif(item.notifId);
          return;
        }
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          final pct = ((received * 100) / total).floor().clamp(0, 100);
          if (pct != lastPct) {
            lastPct = pct;
            item.progress = pct;
            notifyListeners();
          }
          // Update notification every 5%
          if (pct - lastNotifPct >= 5 || pct == 100) {
            lastNotifPct = pct;
            await _notify(
              id: item.notifId,
              title: 'Downloading',
              body: '${item.fileName} · $pct%',
              ongoing: true,
              progress: pct,
              maxProgress: 100,
            );
          }
        } else if (received % (256 * 1024) < chunk.length) {
          item.progress = (item.progress + 1).clamp(0, 95);
          notifyListeners();
          await _notify(
            id: item.notifId,
            title: 'Downloading',
            body: item.fileName,
            ongoing: true,
          );
        }
      }
      await sink.flush();
      await sink.close();

      final privateOut = File('${item.savedDir}/${item.fileName}');
      if (await privateOut.exists()) await privateOut.delete();
      await file.rename(privateOut.path);

      // Copy into public Download/INK so it appears in the phone Files app.
      final publicDir = await _publicDir();
      if (publicDir != null) {
        try {
          final publicPath = '$publicDir/${item.fileName}';
          await privateOut.copy(publicPath);
          item.publicPath = publicPath;
          item.savedDir = publicDir; // show public path in UI
          debugPrint('Copied to public: $publicPath');
        } catch (e) {
          debugPrint('public copy failed: $e');
          // keep private path — still openable from the app
        }
      }

      item.progress = 100;
      item.status = DownloadTaskStatus.complete;
      item.error = null;
      notifyListeners();

      await _notify(
        id: item.notifId,
        title: 'Download complete',
        body: item.fileName,
        ongoing: false,
        progress: 100,
        maxProgress: 100,
      );
      debugPrint('INK download OK → ${item.filePath} ($received bytes)');
    } catch (e, st) {
      debugPrint('INK download FAIL: $e\n$st');
      item.status = DownloadTaskStatus.failed;
      item.error = e.toString();
      notifyListeners();
      await _notify(
        id: item.notifId,
        title: 'Download failed',
        body: item.fileName,
        ongoing: false,
      );
      try {
        final f = File(part);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    } finally {
      try {
        client.close(force: true);
      } catch (_) {}
      _clients.remove(item.taskId);
      _cancel.remove(item.taskId);
    }
  }

  Future<void> pause(String taskId) async => cancel(taskId);

  Future<void> resume(String taskId) async {
    final item = _find(taskId);
    if (item == null) return;
    if (item.status == DownloadTaskStatus.canceled ||
        item.status == DownloadTaskStatus.failed) {
      item.progress = 0;
      item.status = DownloadTaskStatus.enqueued;
      item.error = null;
      notifyListeners();
      await _notify(
        id: item.notifId,
        title: 'Downloading',
        body: item.fileName,
        ongoing: true,
        progress: 0,
        maxProgress: 100,
      );
      unawaited(_download(item));
    }
  }

  Future<void> cancel(String taskId) async {
    _cancel[taskId] = true;
    try {
      _clients[taskId]?.close(force: true);
    } catch (_) {}
    final item = _find(taskId);
    if (item != null &&
        (item.status == DownloadTaskStatus.running ||
            item.status == DownloadTaskStatus.enqueued)) {
      item.status = DownloadTaskStatus.canceled;
      notifyListeners();
      await _cancelNotif(item.notifId);
    }
  }

  Future<void> remove(String taskId, {bool deleteFile = false}) async {
    await cancel(taskId);
    final item = _find(taskId);
    if (item != null && deleteFile) {
      for (final path in [item.filePath, item.publicPath]) {
        if (path == null) continue;
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    if (item != null) await _cancelNotif(item.notifId);
    _items.removeWhere((e) => e.taskId == taskId);
    notifyListeners();
  }

  Future<void> refresh() async {
    notifyListeners();
  }

  DownloadItem? _find(String id) {
    for (final e in _items) {
      if (e.taskId == id) return e;
    }
    return null;
  }

  Future<OpenResult> openFile(DownloadItem item) async {
    final path = item.publicPath ?? item.filePath;
    if (path == null || !File(path).existsSync()) {
      return OpenResult(
        type: ResultType.error,
        message: 'File not found: $path',
      );
    }
    if (item.fileName.toLowerCase().endsWith('.apk') && Platform.isAndroid) {
      final status = await Permission.requestInstallPackages.request();
      if (!status.isGranted) {
        return OpenResult(
          type: ResultType.permissionDenied,
          message: 'Install packages permission denied',
        );
      }
    }
    return OpenFilex.open(path);
  }
}

class DownloadItem {
  DownloadItem({
    required this.taskId,
    required this.url,
    required this.fileName,
    required this.savedDir,
    required this.progress,
    required this.status,
    this.error,
    this.publicPath,
    this.notifId = 0,
  });

  final String taskId;
  final String url;
  String fileName;
  String savedDir;
  int progress;
  DownloadTaskStatus status;
  String? error;
  String? publicPath;
  final int notifId;

  String? get filePath =>
      savedDir.isNotEmpty ? '$savedDir/$fileName' : null;

  String get category => DownloadService.categoryFor(fileName);
}
