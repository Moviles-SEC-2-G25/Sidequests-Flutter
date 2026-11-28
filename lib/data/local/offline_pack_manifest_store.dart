import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local storage of the offline pack: only the ids of the quests the user
/// picked, never their content (that stays in the Hive catalogue and steps
/// cache). Same file name and JSON as Kotlin's OfflinePackManager
/// (`{"selectedQuestIds": [...]}`), so both apps keep the same manifest.
class OfflinePackManifestStore {
  static const fileName = 'offline_pack_manifest.json';
  static const _idsKey = 'selectedQuestIds';

  /// The web has no documents folder (path_provider) nor dart:io files: there
  /// the same JSON lives in SharedPreferences (the browser's localStorage).
  static const _webPrefsKey = 'offline_pack_manifest';

  final Future<Directory> Function() _directory;
  final bool _isWeb;

  OfflinePackManifestStore({Future<Directory> Function()? directory, bool isWeb = kIsWeb})
    : _directory = directory ?? getApplicationDocumentsDirectory,
      _isWeb = isWeb;

  /// The ids saved, without repeats. A missing, unreadable or damaged manifest
  /// reads as empty: the pack starts over instead of breaking the app.
  Future<List<String>> read() async {
    try {
      final String? text;
      if (_isWeb) {
        text = (await SharedPreferences.getInstance()).getString(_webPrefsKey);
      } else {
        final file = await _file();
        text = await file.exists() ? await file.readAsString() : null;
      }
      if (text == null) return const [];
      final decoded = jsonDecode(text);
      final ids = decoded is Map ? decoded[_idsKey] : null;
      if (ids is! List) return const [];
      return ids.whereType<String>().where((id) => id.isNotEmpty).toSet().toList();
    } catch (_) {
      return const [];
    }
  }

  /// Replaces the manifest with [ids]. Atomic like Kotlin's writeManifest:
  /// written whole to a .tmp next to it, flushed, then renamed over it, so a
  /// crash halfway leaves the previous manifest, never half a file.
  Future<void> write(List<String> ids) async {
    final text = jsonEncode({_idsKey: ids});
    if (_isWeb) {
      await (await SharedPreferences.getInstance()).setString(_webPrefsKey, text);
      return;
    }
    final file = await _file();
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  /// Sign-out: the next account starts with an empty pack. Never throws.
  Future<void> clear() async {
    try {
      if (_isWeb) {
        await (await SharedPreferences.getInstance()).remove(_webPrefsKey);
        return;
      }
      final file = await _file();
      for (final leftover in [file, File('${file.path}.tmp')]) {
        if (await leftover.exists()) await leftover.delete();
      }
    } catch (_) {
      // Nothing to delete, or no documents folder on this platform.
    }
  }

  Future<File> _file() async {
    final directory = await _directory();
    if (!await directory.exists()) await directory.create(recursive: true);
    return File('${directory.path}${Platform.pathSeparator}$fileName');
  }
}
