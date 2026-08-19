import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';

/// Top-level callback required by flutter_downloader (runs in background isolate).
@pragma('vm:entry-point')
void inkDownloadCallback(String id, int status, int progress) {
  final SendPort? send =
      IsolateNameServer.lookupPortByName('ink_downloader_send_port');
  send?.send([id, status, progress]);
}

/// Reliable background downloads powered by flutter_downloader.
/// Survives app backgrounding / leaving the app.
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
    _initialized = true;

    // Register the background isolate callback once.
    FlutterDownloader.registerCallback(inkDownloadCallback);

    // Listen for progress updates coming from the background isolate.
    _port = ReceivePort();
    IsolateNameServer.removePortNameMapping('ink_downloader_send_port');
    IsolateNameServer.registerPortWithName(
      _port!.sendPort,
      'ink_downloader_send_port',
    );
    _port!.listen(_onBackgroundUpdate);

    // Restore any tasks that were running when the app was last closed.
    await _loadExistingTasks();
  }

  /// Called when the app returns to the foreground.
  Future<void> rebind() async {
    if (!_initialized) {
      await initialize();
      return;
    }
    // Re-register the port in case the isolate was recycled.
    IsolateNameServer.removePortNameMapping('ink_downloader_send_port');
    if (_port != null) {
      IsolateNameServer.registerPortWithName(
        _port!.sendPort,
        'ink_downloader_send_port',
      );
    }
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
      // Best-effort: try to surface the final path.
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
          existing.status = t.status;
          existing.progress = t.progress;
          existing.fileName = t.filename ?? existing.fileName;
          existing.savedDir = t.savedDir;
          continue;
        }

        // Only keep recent / interesting tasks in the UI list.
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
      // Newest first
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
    try {
      if (!(await Permission.notification.isGranted)) {
        await Permission.notification.request();
      }
    } catch (_) {}
    try {
      if (await Permission.storage.isDenied) await Permission.storage.request();
    } catch (_) {}
    // Android 11+ : needed to write into public Download folder on some devices
    try {
      if (await Permission.manageExternalStorage.isDenied) {
        await Permission.manageExternalStorage.request();
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

  /// Public phone Downloads folder ONLY — never the app-private directory.
  /// Files appear in the system Files / Downloads app.
  Future<String> _saveDir() async {
    final candidates = <String>[
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Downloads',
      '/sdcard/Download',
      '/sdcard/Downloads',
    ];
    for (final path in candidates) {
      try {
        final dir = Directory(path);
        if (!await dir.exists()) await dir.create(recursive: true);
        final probe = File('${dir.path}/.ink_write_test');
        await probe.writeAsString('ok', flush: true);
        await probe.delete();
        return dir.path;
      } catch (e) {
        debugPrint('public dir fail $path: $e');
      }
    }
    // Last resort still public (no app-private path).
    throw StateError(
      'Cannot write to public Download folder. '
      'Grant "All files access" / storage permission.',
    );
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
    final savedDir = await _saveDir();
    name = await _uniqueName(savedDir, name);

    try {
      final taskId = await FlutterDownloader.enqueue(
        url: url,
        savedDir: savedDir,
        fileName: name,
        showNotification: showNotification,
        openFileFromNotification: true,
        allowCellular: true,
        saveInPublicStorage: true,
      );

      if (taskId == null) {
        debugPrint('FlutterDownloader.enqueue returned null');
        return null;
      }

      final item = DownloadItem(
        taskId: taskId,
        url: url,
        fileName: name,
        savedDir: savedDir,
        progress: 0,
        status: DownloadTaskStatus.enqueued,
      );
      _items.insert(0, item);
      notifyListeners();
      return taskId;
    } catch (e, st) {
      debugPrint('enqueue failed: $e\n$st');
      return null;
    }
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
    final item = _find(taskId);
    if (item == null) return;

    try {
      if (item.status == DownloadTaskStatus.paused) {
        final newId = await FlutterDownloader.resume(taskId: taskId);
        if (newId != null && newId != taskId) {
          // Plugin sometimes returns a new task id on resume.
          item.taskId = newId;
        }
        item.status = DownloadTaskStatus.running;
        notifyListeners();
        return;
      }

      // Failed / canceled → re-enqueue
      if (item.status == DownloadTaskStatus.failed ||
          item.status == DownloadTaskStatus.canceled) {
        final url = item.url;
        final name = item.fileName;
        await remove(taskId, deleteFile: false);
        await enqueue(url: url, fileName: name);
      }
    } catch (e) {
      debugPrint('resume error: $e');
      // Fallback: re-enqueue
      final url = item.url;
      final name = item.fileName;
      await remove(taskId, deleteFile: false);
      await enqueue(url: url, fileName: name);
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
      // Try asking the plugin for the path
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
