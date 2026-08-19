import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Top-level callback required by flutter_downloader (runs in background isolate).
/// Must stay top-level + @pragma so it is not tree-shaken in release builds.
@pragma('vm:entry-point')
void inkDownloadCallback(String id, int status, int progress) {
  final SendPort? send =
      IsolateNameServer.lookupPortByName('ink_downloader_send_port');
  send?.send([id, status, progress]);
}

/// Background downloads via flutter_downloader.
class DownloadService extends ChangeNotifier {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  final List<DownloadItem> _items = [];
  bool _initialized = false;
  ReceivePort? _port;

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

    // 1) Bind isolate port FIRST (before registerCallback)
    _bindPort();

    // 2) Register background callback
    try {
      FlutterDownloader.registerCallback(inkDownloadCallback);
    } catch (e) {
      debugPrint('registerCallback: $e');
    }

    _initialized = true;
    await _loadExistingTasks();
  }

  void _bindPort() {
    try {
      IsolateNameServer.removePortNameMapping('ink_downloader_send_port');
    } catch (_) {}
    _port?.close();
    _port = ReceivePort();
    IsolateNameServer.registerPortWithName(
      _port!.sendPort,
      'ink_downloader_send_port',
    );
    _port!.listen(_onBackgroundUpdate);
  }

  Future<void> rebind() async {
    if (!_initialized) {
      await initialize();
      return;
    }
    _bindPort();
    try {
      FlutterDownloader.registerCallback(inkDownloadCallback);
    } catch (_) {}
    await _loadExistingTasks();
  }

  void _onBackgroundUpdate(dynamic data) {
    if (data is! List || data.length < 3) return;
    final taskId = data[0] as String;
    DownloadTaskStatus status;
    try {
      status = DownloadTaskStatus.fromInt(data[1] as int);
    } catch (_) {
      final idx = data[1] as int;
      status = (idx >= 0 && idx < DownloadTaskStatus.values.length)
          ? DownloadTaskStatus.values[idx]
          : DownloadTaskStatus.undefined;
    }
    final progress = data[2] as int;

    final item = _find(taskId);
    if (item == null) return;

    item.status = status;
    item.progress = progress.clamp(0, 100);

    if (status == DownloadTaskStatus.complete) {
      item.progress = 100;
      item.error = null;
      unawaited(_refreshTaskPath(item));
    } else if (status == DownloadTaskStatus.failed) {
      item.error ??= 'Download failed';
    }
    notifyListeners();
  }

  Future<void> _loadExistingTasks() async {
    try {
      final tasks = await FlutterDownloader.loadTasks();
      if (tasks == null) return;

      for (final t in tasks) {
        final existing = _find(t.taskId);
        if (existing != null) {
          existing.progress = t.progress;
          existing.status = t.status;
          existing.savedDir = t.savedDir;
          if (t.filename != null && t.filename!.isNotEmpty) {
            existing.fileName = t.filename!;
          }
          continue;
        }

        if (t.status == DownloadTaskStatus.complete ||
            t.status == DownloadTaskStatus.running ||
            t.status == DownloadTaskStatus.enqueued ||
            t.status == DownloadTaskStatus.paused ||
            t.status == DownloadTaskStatus.failed) {
          _items.add(DownloadItem(
            taskId: t.taskId,
            url: t.url,
            fileName: t.filename ?? 'download',
            savedDir: t.savedDir,
            progress: t.progress,
            status: t.status,
          ));
        }
      }
      _items.sort((a, b) => b.taskId.compareTo(a.taskId));
      notifyListeners();
    } catch (e) {
      debugPrint('loadTasks error: $e');
    }
  }

  Future<void> _refreshTaskPath(DownloadItem item) async {
    try {
      final tasks = await FlutterDownloader.loadTasksWithRawQuery(
        query: "SELECT * FROM task WHERE task_id='${item.taskId}'",
      );
      if (tasks != null && tasks.isNotEmpty) {
        final t = tasks.first;
        item.savedDir = t.savedDir;
        if (t.filename != null && t.filename!.isNotEmpty) {
          item.fileName = t.filename!;
        }
        notifyListeners();
      }
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

    // Notifications (Android 13+)
    try {
      final n = await Permission.notification.status;
      if (!n.isGranted) await Permission.notification.request();
    } catch (_) {}

    // Storage — try several permission types depending on OS version
    try {
      final s = await Permission.storage.status;
      if (!s.isGranted) await Permission.storage.request();
    } catch (_) {}

    try {
      // Photos / videos / audio on Android 13+
      await Permission.photos.request();
      await Permission.videos.request();
      await Permission.audio.request();
    } catch (_) {}

    // Optional "all files" — helps writing to public Download/
    try {
      final m = await Permission.manageExternalStorage.status;
      if (!m.isGranted) {
        // Don't block if user denies — we have app-private fallback
        await Permission.manageExternalStorage.request();
      }
    } catch (_) {}

    if (forApk) {
      try {
        final i = await Permission.requestInstallPackages.status;
        if (!i.isGranted) await Permission.requestInstallPackages.request();
      } catch (_) {}
    }
  }

  /// Always returns a writable directory.
  /// Prefer public Downloads; fall back to app external / documents.
  Future<String> _saveDir() async {
    // 1) Public Downloads (visible in system Files app)
    for (final path in const [
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Downloads',
      '/sdcard/Download',
      '/sdcard/Downloads',
    ]) {
      try {
        final dir = Directory(path);
        if (!await dir.exists()) await dir.create(recursive: true);
        final probe = File('${dir.path}/.ink_write_test');
        await probe.writeAsString('ok', flush: true);
        await probe.delete();
        debugPrint('INK dl dir (public): $path');
        return dir.path;
      } catch (e) {
        debugPrint('public dir fail $path: $e');
      }
    }

    // 2) App-specific external storage (works without special permission on API 29+)
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final dir = Directory('${ext.path}/Download');
        if (!await dir.exists()) await dir.create(recursive: true);
        debugPrint('INK dl dir (app external): ${dir.path}');
        return dir.path;
      }
    } catch (e) {
      debugPrint('getExternalStorageDirectory: $e');
    }

    // 3) Application documents
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/Download');
    if (!await dir.exists()) await dir.create(recursive: true);
    debugPrint('INK dl dir (docs): ${dir.path}');
    return dir.path;
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

  Future<String?> enqueue({
    required String url,
    String? fileName,
    bool showNotification = true,
  }) async {
    await initialize();

    if (url.isEmpty ||
        url.startsWith('blob:') ||
        url.startsWith('data:') ||
        url.startsWith('about:')) {
      debugPrint('enqueue: unsupported url scheme: $url');
      return null;
    }

    var name = _safeFileName(
      fileName ??
          () {
            try {
              final segs = Uri.parse(url).pathSegments;
              return segs.isNotEmpty
                  ? segs.last
                  : 'download_${DateTime.now().millisecondsSinceEpoch}';
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

    final savedDir = await _saveDir();
    name = await _uniqueName(savedDir, name);

    final isPublic = savedDir.contains('/storage/emulated') ||
        savedDir.startsWith('/sdcard');

    debugPrint('INK enqueue url=$url name=$name dir=$savedDir public=$isPublic');

    // Attempt 1
    try {
      final taskId = await FlutterDownloader.enqueue(
        url: url,
        savedDir: savedDir,
        fileName: name,
        showNotification: showNotification,
        openFileFromNotification: true,
        allowCellular: true,
        saveInPublicStorage: isPublic,
        requiresStorageNotLow: false,
      );
      if (taskId != null) {
        _addItem(taskId, url, name, savedDir);
        return taskId;
      }
      debugPrint('enqueue returned null (public=$isPublic)');
    } catch (e, st) {
      debugPrint('enqueue error: $e\n$st');
    }

    // Attempt 2 — force private storage
    try {
      final taskId = await FlutterDownloader.enqueue(
        url: url,
        savedDir: savedDir,
        fileName: name,
        showNotification: showNotification,
        openFileFromNotification: true,
        allowCellular: true,
        saveInPublicStorage: false,
        requiresStorageNotLow: false,
      );
      if (taskId != null) {
        _addItem(taskId, url, name, savedDir);
        return taskId;
      }
      debugPrint('enqueue returned null (private)');
    } catch (e, st) {
      debugPrint('enqueue private error: $e\n$st');
    }

    return null;
  }

  void _addItem(String taskId, String url, String name, String savedDir) {
    _items.insert(
      0,
      DownloadItem(
        taskId: taskId,
        url: url,
        fileName: name,
        savedDir: savedDir,
        progress: 0,
        status: DownloadTaskStatus.enqueued,
      ),
    );
    notifyListeners();
  }

  Future<void> pause(String taskId) async {
    try {
      await FlutterDownloader.pause(taskId: taskId);
      final item = _find(taskId);
      if (item != null) {
        item.status = DownloadTaskStatus.paused;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('pause error: $e');
    }
  }

  Future<void> resume(String taskId) async {
    try {
      final newId = await FlutterDownloader.resume(taskId: taskId);
      if (newId != null) {
        final item = _find(taskId);
        if (item != null) {
          item.taskId = newId;
          item.status = DownloadTaskStatus.running;
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('resume error: $e');
      final item = _find(taskId);
      if (item != null) {
        final url = item.url;
        final name = item.fileName;
        await remove(taskId, deleteFile: false);
        await enqueue(url: url, fileName: name);
      }
    }
  }

  Future<void> cancel(String taskId) async {
    try {
      await FlutterDownloader.cancel(taskId: taskId);
    } catch (_) {}
    final item = _find(taskId);
    if (item != null) {
      item.status = DownloadTaskStatus.canceled;
      notifyListeners();
    }
  }

  Future<void> remove(String taskId, {bool deleteFile = false}) async {
    try {
      await FlutterDownloader.remove(
        taskId: taskId,
        shouldDeleteContent: deleteFile,
      );
    } catch (_) {}
    _items.removeWhere((e) => e.taskId == taskId);
    notifyListeners();
  }

  Future<void> refresh() async {
    await _loadExistingTasks();
  }

  DownloadItem? _find(String id) {
    for (final e in _items) {
      if (e.taskId == id) return e;
    }
    return null;
  }

  Future<OpenResult> openFile(DownloadItem item) async {
    final path = item.filePath;
    if (path == null || !File(path).existsSync()) {
      try {
        await FlutterDownloader.open(taskId: item.taskId);
        return OpenResult(type: ResultType.done, message: 'opened');
      } catch (_) {}
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

  String taskId;
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
