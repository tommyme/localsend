import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:io' as io;

import 'package:common/api_route_builder.dart';
import 'package:common/constants.dart';
import 'package:common/model/device.dart';
import 'package:common/model/dto/file_dto.dart';
import 'package:common/model/dto/info_register_dto.dart';
import 'package:common/model/dto/multicast_dto.dart';
import 'package:common/model/dto/prepare_upload_request_dto.dart';
import 'package:common/model/dto/register_dto.dart';
import 'package:common/model/file_type.dart';
import 'package:mime/mime.dart';

import 'cli_daemon.dart';
import 'cli_ui.dart';

/// Send service for sending files/text/clipboard to devices
class CliSend {
  /// Execute send command with arguments
  static Future<void> execute(List<String> args) async {
    if (args.isEmpty) {
      CliUi.error('Usage: localsend send <device> [files...] [--text "text"] [--clipboard]');
      print('');
      print('Options:');
      print('  <device>       Device name or ID from list command');
      print('  [files...]     Files to send');
      print('  --text "text"  Send text content');
      print('  --clipboard    Send current clipboard content');
      io.exit(1);
    }

    // Parse arguments
    String? deviceSelector;
    final files = <String>[];
    String? textContent;
    bool sendClipboard = false;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--text' && i + 1 < args.length) {
        textContent = args[++i];
      } else if (arg == '--clipboard') {
        sendClipboard = true;
      } else if (!arg.startsWith('--') && deviceSelector == null) {
        deviceSelector = arg;
      } else if (!arg.startsWith('--')) {
        files.add(arg);
      }
    }

    if (deviceSelector == null) {
      CliUi.error('No device specified');
      CliUi.info('Use "localsend list" to see available devices');
      io.exit(1);
    }

    // Discover devices
    final discovery = _SendDiscovery(alias: 'CLI Device', port: 53317);
    final devices = await discovery.scan(timeoutMs: 3000);

    if (devices.isEmpty) {
      CliUi.error('No devices found');
      CliUi.info('Make sure the receiving device is on the same network');
      io.exit(1);
    }

    // Find matching device by name or ID
    DeviceEntry? target;

    // Try as ID (number)
    final id = int.tryParse(deviceSelector);
    if (id != null && id > 0 && id <= devices.length) {
      target = devices[id - 1];
    }

    // Try as name (fuzzy match)
    if (target == null) {
      final lower = deviceSelector.toLowerCase();
      final matches = devices.where((d) =>
        d.alias.toLowerCase().contains(lower) ||
        d.alias.toLowerCase() == lower
      ).toList();

      if (matches.isEmpty) {
        CliUi.error('Device not found: $deviceSelector');
        print('');
        CliUi.info('Available devices:');
        for (var i = 0; i < devices.length; i++) {
          CliUi.info('  ${i + 1}. ${devices[i].alias} (${devices[i].deviceType})');
        }
        io.exit(1);
      } else if (matches.length > 1) {
        CliUi.error('Ambiguous device: $deviceSelector');
        CliUi.info('More than one device matches:');
        for (final m in matches) {
          CliUi.info('  - ${m.alias}');
        }
        io.exit(1);
      } else {
        target = matches.first;
      }
    }

    CliUi.info('Sending to: ${target.alias} (${target.ip})');

    // Handle content
    if (textContent != null) {
      await _sendText(target, textContent);
    } else if (sendClipboard) {
      await _sendClipboard(target);
    } else if (files.isNotEmpty) {
      await _sendFiles(target, files);
    } else {
      CliUi.error('No content to send (no files, --text, or --clipboard)');
      io.exit(1);
    }
  }

  static Future<void> _sendFiles(DeviceEntry target, List<String> filePaths) async {
    // Validate files
    final validFiles = <File>[];
    for (final path in filePaths) {
      final file = File(path);
      if (await file.exists()) {
        validFiles.add(file);
      } else {
        CliUi.warning('File not found: $path');
      }
    }

    if (validFiles.isEmpty) {
      CliUi.error('No valid files to send');
      io.exit(1);
    }

    CliUi.info('Sending ${validFiles.length} file(s)...');

    try {
      // Register with target
      await _registerWith(target);

      // Prepare upload
      final fileTokens = await _prepareUpload(target, validFiles);
      final sessionId = fileTokens['sessionId']!;

      // Upload files
      for (var i = 0; i < validFiles.length; i++) {
        final file = validFiles[i];
        final fileId = 'file_$i';
        final token = fileTokens[fileId]!;

        CliUi.progress('Uploading ${file.path}...');
        await _uploadFile(target, file, sessionId, fileId, token);
        CliUi.success('Sent: ${file.path}');
      }

      CliUi.success('All files sent successfully!');
    } catch (e) {
      CliUi.error('Transfer failed: $e');
      io.exit(1);
    }
  }

  static Future<void> _sendText(DeviceEntry target, String text) async {
    CliUi.info('Sending text...');

    try {
      await _registerWith(target);

      // Create a temporary file for text
      final tempDir = Directory.systemTemp;
      final tempFile = File('${tempDir.path}/localsend_text_${DateTime.now().millisecondsSinceEpoch}.txt');
      await tempFile.writeAsString(text);

      final files = [tempFile];
      final fileTokens = await _prepareUpload(target, files);
      final sessionId = fileTokens['sessionId']!;

      for (var i = 0; i < files.length; i++) {
        await _uploadFile(target, files[i], sessionId, 'file_$i', fileTokens['file_$i']!);
      }

      // Cleanup
      await tempFile.delete();

      CliUi.success('Text sent successfully!');
    } catch (e) {
      CliUi.error('Failed to send text: $e');
      io.exit(1);
    }
  }

  static Future<String?> _readClipboard() async {
    try {
      io.ProcessResult result;

      if (Platform.isMacOS) {
        result = await io.Process.run('/bin/bash', ['-c', 'pbpaste']);
      } else if (Platform.isLinux) {
        // Try xclip first, then xsel
        result = await io.Process.run('/bin/bash', ['-c', 'xclip -selection clipboard -o']);
        if (result.exitCode != 0) {
          result = await io.Process.run('/bin/bash', ['-c', 'xsel --clipboard']);
        }
      } else if (Platform.isWindows) {
        result = await io.Process.run('powershell', ['-command', 'Get-Clipboard']);
      } else {
        return null;
      }

      if (result.exitCode == 0 && result.stdout.toString().isNotEmpty) {
        return result.stdout.toString();
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _sendClipboard(DeviceEntry target) async {
    CliUi.info('Reading clipboard...');

    final clipboardContent = await _readClipboard();
    if (clipboardContent == null || clipboardContent.isEmpty) {
      CliUi.error('Failed to read clipboard or clipboard is empty');
      io.exit(1);
    }

    CliUi.info('Sending clipboard content (${clipboardContent.length} chars)...');

    try {
      await _registerWith(target);

      // Create a temporary file for clipboard content
      final tempDir = Directory.systemTemp;
      final tempFile = File('${tempDir.path}/localsend_clipboard_${DateTime.now().millisecondsSinceEpoch}.txt');
      await tempFile.writeAsString(clipboardContent);

      final files = [tempFile];
      final fileTokens = await _prepareUpload(target, files);
      final sessionId = fileTokens['sessionId']!;

      for (var i = 0; i < files.length; i++) {
        await _uploadFile(target, files[i], sessionId, 'file_$i', fileTokens['file_$i']!);
      }

      // Cleanup
      await tempFile.delete();

      CliUi.success('Clipboard sent successfully!');
    } catch (e) {
      CliUi.error('Failed to send clipboard: $e');
      io.exit(1);
    }
  }

  static Future<Map<String, dynamic>> _makeHttpsRequest(
    String ip,
    int port,
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    final socket = await SecureSocket.connect(
      ip,
      port,
      onBadCertificate: (cert) => true,
      timeout: const Duration(seconds: 10),
    );

    final jsonBody = body != null ? jsonEncode(body) : '';
    final request = '$method $path HTTP/1.1\r\n'
        'Host: $ip:$port\r\n'
        'Content-Type: application/json\r\n'
        'Content-Length: ${jsonBody.length}\r\n'
        'Connection: close\r\n'
        '\r\n'
        '$jsonBody';

    socket.write(request);
    await socket.flush();

    // Read all response data until socket closes
    final responseBytes = <int>[];
    await for (final chunk in socket) {
      responseBytes.addAll(chunk);
    }
    final response = String.fromCharCodes(responseBytes);
    await socket.close();

    // Parse HTTP response
    final bodyStart = response.indexOf('\r\n\r\n');
    if (bodyStart == -1) throw Exception('Invalid HTTP response');

    final statusLine = response.substring(0, bodyStart).split('\r\n').first;
    final statusCode = int.tryParse(statusLine.split(' ')[1]) ?? 0;

    final responseBody = response.substring(bodyStart + 4);
    if (statusCode != 200) throw Exception('HTTP $statusCode');

    return jsonDecode(responseBody) as Map<String, dynamic>;
  }

  static Future<void> _registerWith(DeviceEntry target) async {
    final body = {
      'alias': 'CLI Device',
      'version': protocolVersion,
      'deviceModel': 'CLI',
      'deviceType': 'headless',
      'fingerprint': 'cli_${DateTime.now().millisecondsSinceEpoch}',
      'port': 53317,
      'protocol': 'https',
      'download': true,
    };

    await _makeHttpsRequest(
      target.ip,
      target.port,
      'POST',
      ApiRoute.register.v2,
      body,
    );
  }

  static Future<Map<String, String>> _prepareUpload(DeviceEntry target, List<File> files) async {
    // Build file entries manually to avoid dart_mappable serialization issues
    final filesJson = <String, dynamic>{};
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final stat = await file.stat();
      final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';

      filesJson['file_$i'] = {
        'id': 'file_$i',
        'fileName': file.uri.pathSegments.last,
        'size': stat.size,
        'fileType': mimeType,
      };
    }

    final requestBody = {
      'info': {
        'alias': 'CLI Device',
        'version': protocolVersion,
        'deviceModel': 'CLI',
        'deviceType': 'headless',
        'fingerprint': 'cli_${DateTime.now().millisecondsSinceEpoch}',
        'port': 53317,
        'protocol': 'https',
        'download': true,
      },
      'files': filesJson,
    };

    final json = await _makeHttpsRequest(
      target.ip,
      target.port,
      'POST',
      ApiRoute.prepareUpload.v2,
      requestBody,
    );

    // Return both sessionId and files map (fileId -> token)
    final sessionId = json['sessionId'] as String;
    final filesMap = json['files'] as Map<String, dynamic>;
    return {
      'sessionId': sessionId,
      for (final entry in filesMap.entries) entry.key: entry.value.toString(),
    };
  }

  static void _showProgressBar(int current, int total, String filename) {
    const barWidth = 30;
    final progress = total > 0 ? current / total : 0.0;
    final filled = (progress * barWidth).round();
    final bar = List.filled(barWidth, ' ').asMap().entries.map((e) {
      return e.key < filled ? '=' : (e.key == filled ? '>' : ' ');
    }).join();

    final percent = (progress * 100).toStringAsFixed(1);
    final currentStr = _formatBytes(current);
    final totalStr = _formatBytes(total);

    // \r moves cursor to beginning of line
    io.stderr.write('\r[$bar] $percent% ($currentStr / $totalStr) $filename   ');
    if (current >= total) {
      io.stderr.writeln();
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  static Future<void> _uploadFile(
    DeviceEntry target,
    File file,
    String sessionId,
    String fileId,
    String token,
  ) async {
    final stat = await file.stat();
    final totalSize = stat.size;
    final filename = file.uri.pathSegments.last;
    final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
    final path = '${ApiRoute.upload.v2}?sessionId=$sessionId&fileId=$fileId&token=$token';

    final socket = await SecureSocket.connect(
      target.ip,
      target.port,
      onBadCertificate: (cert) => true,
      timeout: const Duration(seconds: 30),
    );

    final request = 'POST $path HTTP/1.1\r\n'
        'Host: ${target.ip}:${target.port}\r\n'
        'Content-Type: $mimeType\r\n'
        'Content-Length: $totalSize\r\n'
        'Connection: close\r\n'
        '\r\n';

    socket.write(request);

    // Send file in chunks and show progress
    final fileStream = file.openRead();
    int sent = 0;
    final chunkSize = 64 * 1024; // 64KB chunks

    await for (final chunk in fileStream) {
      socket.add(chunk);
      await socket.flush();
      sent += chunk.length;
      _showProgressBar(sent, totalSize, filename);
    }

    // Read response
    final responseBytes = await socket.timeout(const Duration(seconds: 30)).first;
    final response = String.fromCharCodes(responseBytes);
    await socket.close();

    final bodyStart = response.indexOf('\r\n\r\n');
    if (bodyStart == -1) throw Exception('Invalid response');

    final statusLine = response.substring(0, bodyStart).split('\r\n').first;
    final statusCode = int.tryParse(statusLine.split(' ')[1]) ?? 0;

    if (statusCode != 200) throw Exception('Upload failed: $statusCode');
  }

  static FileType _getFileType(String path) {
    final mimeType = lookupMimeType(path) ?? '';
    if (mimeType.startsWith('image/')) return FileType.image;
    if (mimeType.startsWith('video/')) return FileType.video;
    if (mimeType == 'application/pdf') return FileType.pdf;
    if (mimeType.startsWith('text/')) return FileType.text;
    if (mimeType == 'application/vnd.android.package-archive') return FileType.apk;
    return FileType.other;
  }
}

/// Discovery for send operation
class _SendDiscovery {
  final String alias;
  final int port;

  _SendDiscovery({required this.alias, required this.port});

  Future<List<DeviceEntry>> scan({int timeoutMs = 200}) async {
    final devices = <DeviceEntry>[];

    // Multicast scan
    await _scanMulticast(devices, timeoutMs);

    // HTTP scan
    await _scanHttp(devices, timeoutMs);

    // Remove duplicates
    final unique = <String, DeviceEntry>{};
    for (final d in devices) {
      unique[d.ip] = d;
    }

    return unique.values.toList();
  }

  Future<void> _scanMulticast(List<DeviceEntry> devices, int timeoutMs) async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;

      final dto = MulticastDto(
        alias: alias,
        version: protocolVersion,
        deviceModel: 'CLI',
        deviceType: null,
        fingerprint: 'cli_${DateTime.now().millisecondsSinceEpoch}',
        port: port,
        protocol: ProtocolType.http,
        download: true,
        announcement: true,
        announce: true,
      );

      socket.send(
        utf8.encode(jsonEncode(dto.toJson())),
        InternetAddress(defaultMulticastGroup),
        defaultPort,
      );

      final completer = Completer<void>();
      Timer(Duration(milliseconds: timeoutMs), () => completer.complete());

      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (datagram != null) {
            try {
              final dto = MulticastDto.fromJson(jsonDecode(utf8.decode(datagram.data)));
              devices.add(DeviceEntry(
                alias: dto.alias,
                ip: datagram.address.address,
                port: dto.port ?? defaultPort,
                deviceType: _deviceTypeName(dto.deviceType?.name),
                download: dto.download ?? false,
                fingerprint: dto.fingerprint,
              ));
            } catch (_) {}
          }
        }
      });

      await completer.future;
      socket.close();
    } catch (e) {
      CliUi.warning('Multicast scan failed: $e');
    }
  }

  Future<void> _scanHttp(List<DeviceEntry> devices, int timeoutMs) async {
    try {
      final interfaces = await NetworkInterface.list();

      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.type != InternetAddressType.IPv4 || addr.isLoopback) continue;

          // Skip benchmark ranges (RFC 2544)
          final parts = addr.address.split('.');
          final firstOctet = int.tryParse(parts[0]) ?? 0;
          if (firstOctet == 198 && (int.tryParse(parts[1]) ?? 0) >= 18) continue;

          final subnetPrefix = '${parts[0]}.${parts[1]}.${parts[2]}';

          final futures = <Future>[];
          for (var i = 2; i < 255; i++) {
            futures.add(_checkDevice('$subnetPrefix.$i', devices, timeoutMs));
          }
          await Future.wait(futures);
        }
      }
    } catch (e) {
      CliUi.warning('HTTP scan failed: $e');
    }
  }

  Future<void> _checkDevice(String ip, List<DeviceEntry> devices, int timeoutMs) async {
    try {
      // Use SecureSocket to handle self-signed certificates
      final socket = await SecureSocket.connect(
        ip,
        defaultPort,
        onBadCertificate: (cert) => true,
        timeout: Duration(milliseconds: timeoutMs),
      );

      final request = 'GET /api/localsend/v2/info HTTP/1.1\r\n'
          'Host: $ip:$defaultPort\r\n'
          'Connection: close\r\n'
          '\r\n';

      socket.write(request);
      await socket.flush();

      final responseBytes = await socket.timeout(Duration(milliseconds: timeoutMs)).first;
      final response = String.fromCharCodes(responseBytes);

      await socket.close();

      // Parse HTTP response
      final lines = response.split('\r\n');
      if (lines.isEmpty) return;

      final statusLine = lines.first;
      if (!statusLine.contains('200')) return;

      // Find JSON body
      final bodyStart = response.indexOf('\r\n\r\n');
      if (bodyStart == -1) return;
      final body = response.substring(bodyStart + 4);
      final json = jsonDecode(body) as Map<String, dynamic>;

      final device = DeviceEntry(
        alias: json['alias'] as String? ?? 'Unknown',
        ip: ip,
        port: json['port'] as int? ?? defaultPort,
        deviceType: _deviceTypeName(json['deviceType'] as String?),
        download: json['download'] as bool? ?? true,
        fingerprint: json['fingerprint'] as String?,
      );

      if (!devices.any((d) => d.ip == ip)) {
        devices.add(device);
      }
    } catch (_) {}
  }

  String _deviceTypeName(String? type) {
    switch (type) {
      case 'mobile': return 'Phone';
      case 'desktop': return 'Desktop';
      case 'web': return 'Web';
      case 'headless': return 'CLI';
      case 'server': return 'Server';
      default: return 'Unknown';
    }
  }
}
