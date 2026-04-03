import 'dart:io';

/// Console UI utilities for LocalSend CLI
class CliUi {
  static const String reset = '\x1B[0m';
  static const String bold = '\x1B[1m';
  static const String dim = '\x1B[2m';
  static const String green = '\x1B[32m';
  static const String yellow = '\x1B[33m';
  static const String blue = '\x1B[34m';
  static const String cyan = '\x1B[36m';
  static const String white = '\x1B[37m';

  /// Print a header message
  static void header(String message) {
    print('');
    print('${bold}${cyan}=== $message ===${reset}');
  }

  /// Print a success message
  static void success(String message) {
    print('${green}[+] $message${reset}');
  }

  /// Print an info message
  static void info(String message) {
    print('${blue}[i] $message${reset}');
  }

  /// Print a warning message
  static void warning(String message) {
    print('${yellow}[!] $message${reset}');
  }

  /// Print an error message
  static void error(String message) {
    print('${bold}${white}[X] $message${reset}');
  }

  /// Print a progress update
  static void progress(String message) {
    print('${dim}[...] $message${reset}');
  }

  /// Print device info
  static void deviceInfo(String alias, String ip, int port, String fingerprint) {
    header('Device Information');
    print('  Alias:      $alias');
    print('  IP:         $ip');
    print('  Port:       $port');
    print('  Fingerprint: ${_shortHash(fingerprint)}');
    print('');
  }

  /// Print discovered devices
  static void printDevices(List<DiscoveredDevice> devices) {
    if (devices.isEmpty) {
      warning('No devices found on the network');
      return;
    }

    header('Discovered Devices');
    print('');
    for (var i = 0; i < devices.length; i++) {
      final device = devices[i];
      print('  ${bold}${i + 1}.${reset} ${device.alias}');
      print('      IP:     ${device.ip}');
      print('      Type:   ${device.deviceType}');
      print('      Files:  ${device.download ? "accepts files" : "not accepting"}');
      print('');
    }
  }

  /// Print transfer progress
  static void printProgress(String filename, int current, int total, double percentage) {
    final barWidth = 40;
    final filled = (barWidth * percentage / 100).round();
    final empty = barWidth - filled;

    final bar = '=' * filled + ' ' * empty;
    final percentStr = percentage.toStringAsFixed(1);

    stdout.write('\r[$bar] $percentStr% ($current/$total) $filename   ');
    if (percentage >= 100) {
      stdout.writeln('');
    }
  }

  /// Print transfer complete
  static void transferComplete(String filename, String destination) {
    success('Sent: $filename -> $destination');
  }

  /// Print received file
  static void receivedFile(String filename, int size, String savePath) {
    success('Received: $filename (${_formatBytes(size)}) -> $savePath');
  }

  static String _shortHash(String hash) {
    if (hash.length <= 16) return hash;
    return '${hash.substring(0, 8)}...${hash.substring(hash.length - 8)}';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Simple device info for display
class DiscoveredDevice {
  final String alias;
  final String ip;
  final int port;
  final String deviceType;
  final bool download;
  final String? fingerprint;

  const DiscoveredDevice({
    required this.alias,
    required this.ip,
    required this.port,
    required this.deviceType,
    required this.download,
    this.fingerprint,
  });
}
