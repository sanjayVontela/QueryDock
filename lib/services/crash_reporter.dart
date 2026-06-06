import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class CrashReporter {
  static void install() {
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      unawaited(record(details.exception, details.stack));
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(record(error, stack));
      return true;
    };
  }

  static Future<void> record(Object error, StackTrace? stack) async {
    try {
      final directory = await getApplicationSupportDirectory();
      final logDirectory = Directory(
        '${directory.path}${Platform.pathSeparator}logs',
      );
      await logDirectory.create(recursive: true);
      final file = File(
        '${logDirectory.path}${Platform.pathSeparator}crash.log',
      );
      final timestamp = DateTime.now().toUtc().toIso8601String();
      await file.writeAsString(
        '[$timestamp] $error\n${stack ?? ''}\n\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Crash reporting must never cause another application failure.
    }
  }
}
