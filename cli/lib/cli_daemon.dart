import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:common/constants.dart';
import 'package:common/model/device.dart';
import 'package:common/model/dto/multicast_dto.dart';
import 'package:common/model/dto/prepare_upload_request_dto.dart';
import 'package:common/model/dto/register_dto.dart';
import 'package:common/util/network_interfaces.dart';

import 'cli_ui.dart';

/// Device info with friendly name for display
class DeviceEntry {
  final String alias;
  final String ip;
  final int port;
  final String deviceType;
  final bool download;
  final String? fingerprint;

  const DeviceEntry({
    required this.alias,
    required this.ip,
    required this.port,
    required this.deviceType,
    required this.download,
    this.fingerprint,
  });

  @override
  String toString() => '$alias ($deviceType) at $ip';
}

/// Daemon service for receiving and discovering devices
class CliDaemon {
  final int port;
  final String outputDir;
  final String alias;
  final bool autoReceive;

  HttpServer? _server;
  bool _running = false;
  bool _usingHttps = false;
  String _fingerprint = '';
  final Map<String, _PendingTransfer> _pendingTransfers = {};

  CliDaemon({
    required this.port,
    required this.outputDir,
    required this.alias,
    required this.autoReceive,
  });

  bool get isRunning => _running;

  /// List available devices on the network
  static Future<void> listDevices({
    required String alias,
    required int port,
    bool forCompletion = false,
  }) async {
    final discovery = _DeviceDiscovery(alias: alias, port: port);
    final devices = await discovery.scan(timeoutMs: 200);

    if (forCompletion) {
      // Simple format for shell completion: "alias:ip"
      for (final d in devices) {
        print('${d.alias}:${d.ip}');
      }
      return;
    }

    CliUi.header('Scanning for devices...');
    print('');

    if (devices.isEmpty) {
      CliUi.warning('No devices found on the network');
      return;
    }

    CliUi.header('Available Devices');
    print('');
    print('  ${CliUi.bold}ID   Name              Type      IP             Port  Accept${CliUi.reset}');
    print('  ${'-' * 75}');

    for (var i = 0; i < devices.length; i++) {
      final d = devices[i];
      final id = '${i + 1}'.padRight(5);
      final name = d.alias.padRight(18);
      final type = d.deviceType.padRight(10);
      final ip = d.ip.padRight(14);
      final accept = d.download ? '✓' : '✗';
      print('  $id$name$type$ip${d.port}    $accept');
    }

    print('');
    CliUi.info('${devices.length} device(s) found');
    print('');
    CliUi.info('To send files:');
    print('  ${CliUi.bold}localsend send <name> <file>${CliUi.reset}');
    print('');
    print('  Examples:');
    print('    localsend send "My Phone" file.txt');
    print('    localsend send "MacBook" --text "Hello from CLI"');
    print('');
  }

  /// Show this device's information
  static Future<void> showDeviceInfo({
    required String alias,
    required int port,
  }) async {
    final localIp = await _getLocalIp();
    final fingerprint = 'cli_${DateTime.now().millisecondsSinceEpoch}';

    CliUi.header('Device Information');
    print('');
    print('  ${CliUi.bold}Alias:${CliUi.reset}      $alias');
    print('  ${CliUi.bold}Type:${CliUi.reset}       CLI/Headless');
    print('  ${CliUi.bold}IP:${CliUi.reset}         $localIp');
    print('  ${CliUi.bold}Port:${CliUi.reset}       $port');
    print('  ${CliUi.bold}Fingerprint:${CliUi.reset} ${fingerprint.substring(0, 16)}...');
    print('');
  }

  /// Run in interactive mode (foreground)
  static Future<void> runInteractive({
    required int port,
    required String outputDir,
    required String alias,
    required bool autoReceive,
  }) async {
    final daemon = CliDaemon(
      port: port,
      outputDir: outputDir,
      alias: alias,
      autoReceive: autoReceive,
    );

    CliUi.header('LocalSend CLI - Receive Mode');
    if (autoReceive) {
      CliUi.info('Auto-receive mode: files will be saved without confirmation');
    } else {
      CliUi.info('Interactive mode: you will be asked before saving');
    }
    print('');

    await daemon._start();
    await daemon._announcePresence();

    CliUi.info('Listening on port $port...');
    print('');

    if (!daemon.autoReceive) {
      CliUi.info('Incoming transfers will ask for confirmation');
    }

    // Keep running
    await ProcessSignal.sigint.watch().first;
    await daemon.stop();
    CliUi.success('Goodbye!');
  }

  /// Run as daemon (background)
  static Future<void> runDaemon({
    required int port,
    required String outputDir,
    required String alias,
    required bool autoReceive,
  }) async {
    // In a real daemon, we'd fork and exit
    // For now, just run the interactive version
    await runInteractive(
      port: port,
      outputDir: outputDir,
      alias: alias,
      autoReceive: autoReceive,
    );
  }

  Future<void> _start() async {
    // Load SSL certificates
    final certFile = File('certs/cert.pem');
    final keyFile = File('certs/key.pem');

    if (await certFile.exists() && await keyFile.exists()) {
      final securityContext = SecurityContext();
      securityContext.useCertificateChainBytes(await certFile.readAsBytes());
      securityContext.usePrivateKeyBytes(await keyFile.readAsBytes());

      _server = await HttpServer.bindSecure(
        InternetAddress.anyIPv4,
        port,
        securityContext,
        shared: true,
      );
      _usingHttps = true;
      // Use first 16 bytes of MD5 of alias+port as fingerprint
      _fingerprint = _generateFingerprint();
      CliUi.progress('HTTPS server started (fingerprint: ${_fingerprint.substring(0, 8)}...)');
    } else {
      CliUi.warning('SSL certificates not found, using HTTP');
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
      _usingHttps = false;
      _fingerprint = _generateFingerprint();
    }
    _running = true;

    _server!.listen(_handleRequest, onError: (e) {
      CliUi.error('Server error: $e');
    });
  }

  String _generateFingerprint() {
    // Generate a deterministic fingerprint from alias and port
    final input = '$alias:$port:localsend-cli';
    // Simple hash using base64 encoding of the string bytes
    final bytes = utf8.encode(input);
    final hash = base64Encode(bytes).replaceAll(RegExp(r'[/+=]'), 'x');
    return hash;
  }

  Future<void> stop() async {
    if (!_running) return;
    await _server?.close(force: true);
    _server = null;
    _running = false;
  }

  Future<void> _announcePresence() async {
    // Start multicast listener
    _startMulticastListener();

    // Send periodic announcements so other devices can discover us
    _startPeriodicAnnouncement();
  }

  void _startPeriodicAnnouncement() async {
    Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!_running) {
        timer.cancel();
        return;
      }
      _sendMulticastAnnouncement();
    });

    // Send first announcement immediately
    _sendMulticastAnnouncement();
  }

  void _sendMulticastAnnouncement() {
    // We need to create a new socket for each announcement due to UDP socket reuse issues
    RawDatagramSocket.bind(InternetAddress.anyIPv4, 0, reuseAddress: true).then((socket) {
      socket.broadcastEnabled = true;
      try {
        final dto = MulticastDto(
          alias: alias,
          version: protocolVersion,
          deviceModel: 'CLI',
          deviceType: DeviceType.headless,
          fingerprint: _fingerprint,
          port: port,
          protocol: _usingHttps ? ProtocolType.https : ProtocolType.http,
          download: true,
          announcement: true,
          announce: true,
        );

        final data = utf8.encode(jsonEncode(dto.toJson()));
        socket.send(data, InternetAddress(defaultMulticastGroup), defaultPort);
        CliUi.progress('Announced presence to ${defaultMulticastGroup}:${defaultPort}');
      } catch (e) {
        CliUi.warning('Failed to send announcement: $e');
      }
    });
  }

  void _startMulticastListener() async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0, // Use ephemeral port to avoid conflicts
        reuseAddress: true,
        reusePort: true,
      );
      socket.broadcastEnabled = true;

      // Join multicast group - THIS IS REQUIRED for receiving multicast
      try {
        socket.joinMulticast(InternetAddress(defaultMulticastGroup));
      } catch (e) {
        CliUi.warning('Could not join multicast group: $e');
      }

      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (datagram != null) {
            _handleMulticast(datagram);
          }
        }
      });

      CliUi.progress('Multicast listener started on port ${socket.port}');
    } catch (e) {
      CliUi.warning('Could not start multicast listener: $e');
    }
  }

  void _handleMulticast(Datagram datagram) {
    try {
      final data = utf8.decode(datagram.data);
      final json = jsonDecode(data) as Map<String, dynamic>;
      final dto = MulticastDto.fromJson(json);
      CliUi.progress('Heard from: ${dto.alias} at ${datagram.address.address}');
    } catch (_) {}
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;

    try {
      if (request.method == 'OPTIONS') {
        _addCorsHeaders(request.response);
        request.response.statusCode = 204;
        await request.response.close();
        return;
      }

      switch (path) {
        case '/api/localsend/v2/info':
          await _handleInfo(request);
          break;
        case '/api/localsend/v2/register':
          await _handleRegister(request);
          break;
        case '/api/localsend/v2/prepare-upload':
          await _handlePrepareUpload(request);
          break;
        default:
          if (path.startsWith('/api/localsend/v2/upload')) {
            await _handleUpload(request);
          } else if (path.startsWith('/api/localsend/v2/cancel')) {
            await _handleCancel(request);
          } else {
            _addCorsHeaders(request.response);
            request.response.statusCode = 404;
            await request.response.close();
          }
      }
    } catch (e) {
      CliUi.error('Request error: $e');
      _addCorsHeaders(request.response);
      request.response.statusCode = 500;
      request.response.write(jsonEncode({'error': e.toString()}));
      await request.response.close();
    }
  }

  void _addCorsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', '*');
  }

  Future<void> _handleInfo(HttpRequest request) async {
    _addCorsHeaders(request.response);

    request.response.write(jsonEncode({
      'alias': alias,
      'version': protocolVersion,
      'deviceModel': 'CLI',
      'deviceType': 'headless',
      'fingerprint': _fingerprint,
      'port': port,
      'protocol': _usingHttps ? 'https' : 'http',
      'download': true,
    }));
    await request.response.close();
  }

  Future<void> _handleRegister(HttpRequest request) async {
    _addCorsHeaders(request.response);
    try {
      final body = await _readJsonBody(request);
      final dto = RegisterDto.fromJson(body);
      CliUi.success('Registered: ${dto.alias}');
      request.response.statusCode = 200;
    } catch (_) {
      request.response.statusCode = 400;
    }
    await request.response.close();
  }

  Future<void> _handlePrepareUpload(HttpRequest request) async {
    _addCorsHeaders(request.response);

    try {
      final body = await _readJsonBody(request);
      final prepareRequest = PrepareUploadRequestDto.fromJson(body);

      final senderAlias = prepareRequest.info.alias;
      final files = prepareRequest.files.values.map((f) => f.fileName).join(', ');

      CliUi.header('Incoming Transfer');
      CliUi.info('From: $senderAlias');
      CliUi.info('Files: $files');
      print('');

      final sessionId = _generateSessionId();
      bool accepted = autoReceive;

      if (!autoReceive) {
        // Ask for confirmation
        stdout.write('Accept? [Y/n]: ');
        final line = stdin.readLineSync()?.trim().toLowerCase();
        accepted = line == '' || line == 'y' || line == 'yes';
      }

      if (accepted) {
        _pendingTransfers[sessionId] = _PendingTransfer(
          senderAlias: senderAlias,
          files: prepareRequest.files,
        );

        CliUi.success('Accepted');

        final files = <String, dynamic>{};
        for (final entry in prepareRequest.files.entries) {
          files[entry.key] = {
            'id': entry.value.id,
            'fileName': entry.value.fileName,
            'size': entry.value.size,
          };
        }

        request.response.write(jsonEncode({
          'sessionId': sessionId,
          'files': files,
        }));
      } else {
        CliUi.warning('Declined');
        request.response.statusCode = 403;
        request.response.write(jsonEncode({'error': 'Rejected by user'}));
      }
    } catch (e) {
      CliUi.error('Prepare upload error: $e');
      request.response.statusCode = 400;
      request.response.write(jsonEncode({'error': e.toString()}));
    }
    await request.response.close();
  }

  Future<void> _handleUpload(HttpRequest request) async {
    _addCorsHeaders(request.response);

    final sessionId = request.uri.queryParameters['sessionId'];
    final fileId = request.uri.queryParameters['fileId'];

    if (sessionId == null || !_pendingTransfers.containsKey(sessionId)) {
      request.response.statusCode = 400;
      request.response.write(jsonEncode({'error': 'Invalid session'}));
      await request.response.close();
      return;
    }

    try {
      final chunks = <int>[];
      await for (final chunk in request) {
        chunks.addAll(chunk);
      }

      final transfer = _pendingTransfers[sessionId]!;
      final fileInfo = transfer.files[fileId];
      final filename = fileInfo?.fileName ?? 'unknown_$fileId';
      final savePath = '$outputDir/$filename';

      final file = File(savePath);
      await file.writeAsBytes(Uint8List.fromList(chunks));

      CliUi.receivedFile(filename, chunks.length, savePath);

      request.response.statusCode = 200;
      request.response.write(jsonEncode({'success': true}));
    } catch (e) {
      request.response.statusCode = 500;
      request.response.write(jsonEncode({'error': e.toString()}));
    }
    await request.response.close();
  }

  Future<void> _handleCancel(HttpRequest request) async {
    _addCorsHeaders(request.response);
    try {
      final body = await _readJsonBody(request);
      final sessionId = body['sessionId'] as String?;
      if (sessionId != null) {
        _pendingTransfers.remove(sessionId);
      }
    } catch (_) {}
    request.response.statusCode = 200;
    await request.response.close();
  }

  Future<Map<String, dynamic>> _readJsonBody(HttpRequest request) async {
    final bodyBytes = await request.fold<List<int>>(
      <int>[],
      (prev, element) => prev..addAll(element),
    );
    final body = utf8.decode(bodyBytes);
    return jsonDecode(body) as Map<String, dynamic>;
  }

  String _generateSessionId() => DateTime.now().millisecondsSinceEpoch.toString();
}

class _PendingTransfer {
  final String senderAlias;
  final Map<String, dynamic> files;

  _PendingTransfer({required this.senderAlias, required this.files});
}

/// Device discovery service
class _DeviceDiscovery {
  final String alias;
  final int port;

  _DeviceDiscovery({required this.alias, required this.port});

  Future<List<DeviceEntry>> scan({int timeoutMs = 200}) async {
    final devices = <DeviceEntry>[];

    // UDP multicast scan
    await _scanMulticast(devices, timeoutMs);

    // HTTP scan on local subnets
    await _scanHttp(devices, timeoutMs);

    return devices;
  }

  Future<void> _scanMulticast(List<DeviceEntry> devices, int timeoutMs) async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
        reusePort: true,
      );
      socket.broadcastEnabled = true;

      // Join multicast group
      try {
        socket.joinMulticast(InternetAddress(defaultMulticastGroup));
      } catch (e) {
        CliUi.warning('Could not join multicast group: $e');
      }

      final dto = MulticastDto(
        alias: alias,
        version: protocolVersion,
        deviceModel: 'CLI',
        deviceType: null,
        fingerprint: 'cli_${DateTime.now().millisecondsSinceEpoch}',
        port: port,
        protocol: ProtocolType.https, // CLI supports HTTPS now
        download: true,
        announcement: true,
        announce: true,
      );

      final dtoJson = jsonEncode(dto.toJson());
      CliUi.progress('Sending multicast to ${defaultMulticastGroup}:${defaultPort}');

      final sent = socket.send(
        utf8.encode(dtoJson),
        InternetAddress(defaultMulticastGroup),
        defaultPort,
      );
      CliUi.progress('Multicast sent: $sent bytes');

      final completer = Completer<void>();
      Timer(Duration(milliseconds: timeoutMs), () => completer.complete());

      final foundIps = <String>{};

      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (datagram != null) {
            CliUi.progress('Received multicast from ${datagram.address.address}');
            try {
              final dto = MulticastDto.fromJson(jsonDecode(utf8.decode(datagram.data)));
              final ip = datagram.address.address;
              // Avoid duplicates
              if (!foundIps.contains(ip)) {
                foundIps.add(ip);
                devices.add(DeviceEntry(
                  alias: dto.alias,
                  ip: ip,
                  port: dto.port ?? defaultPort,
                  deviceType: _deviceTypeName(dto.deviceType?.name),
                  download: dto.download ?? false,
                  fingerprint: dto.fingerprint,
                ));
              }
            } catch (e) {
              CliUi.warning('Failed to parse multicast: $e');
            }
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
      final interfaces = await getNetworkInterfaces(whitelist: null, blacklist: null);

      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.type != InternetAddressType.IPv4 || addr.isLoopback) continue;

          // Skip benchmark ranges (RFC 2544)
          final parts = addr.address.split('.');
          final firstOctet = int.tryParse(parts[0]) ?? 0;
          if (firstOctet == 198 && (int.tryParse(parts[1]) ?? 0) >= 18) continue;

          CliUi.progress('Scanning subnet: ${addr.address}/24');

          final subnetPrefix = '${parts[0]}.${parts[1]}.${parts[2]}';

          // Scan subnet concurrently
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

      CliUi.progress('Found device at $ip: ${json['alias']}');

      final device = DeviceEntry(
        alias: json['alias'] as String? ?? 'Unknown',
        ip: ip,
        port: json['port'] as int? ?? defaultPort,
        deviceType: _deviceTypeName(json['deviceType'] as String?),
        download: json['download'] as bool? ?? true,
        fingerprint: json['fingerprint'] as String?,
      );

      // Avoid duplicates
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

Future<String> _getLocalIp() async {
  try {
    final interfaces = await NetworkInterface.list();
    for (final interface in interfaces) {
      for (final addr in interface.addresses) {
        if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
          return addr.address;
        }
      }
    }
  } catch (_) {}
  return '127.0.0.1';
}
