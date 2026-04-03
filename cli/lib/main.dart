import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as path;

import 'cli_daemon.dart';
import 'cli_send.dart';
import 'cli_ui.dart';

Future<void> main(List<String> arguments) async {
  // Check for send subcommand first to handle its specific flags
  if (arguments.isNotEmpty && arguments.first == 'send') {
    await handleSendDirect(arguments.sublist(1));
    return;
  }

  final parser = ArgParser();

  parser.addFlag('help', abbr: 'h', negatable: false, help: 'Show help');
  parser.addFlag('receive', abbr: 'r', negatable: false, help: 'Receive files (default mode)');
  parser.addFlag('daemon', abbr: 'd', negatable: false, help: 'Run as daemon (background)');
  parser.addFlag('auto', negatable: false, help: 'Auto-receive without confirmation');
  parser.addFlag('list-devices', negatable: false, help: 'List devices for shell completion');
  parser.addOption('output', abbr: 'o', help: 'Output directory for received files', defaultsTo: '.');
  parser.addOption('alias', abbr: 'a', help: 'Device alias/name', defaultsTo: 'CLI Device');
  parser.addOption('port', abbr: 'p', help: 'Port to use', defaultsTo: '53317');

  final results = parser.parse(arguments);

  if (results['help']) {
    _printUsage(parser);
    return;
  }

  // List devices for shell completion
  if (results['list-devices'] as bool) {
    await listDevices(results, forCompletion: true);
    return;
  }

  // Check for subcommands
  if (results.rest.isNotEmpty) {
    final subcommand = results.rest[0];

    switch (subcommand) {
      case 'list':
        await listDevices(results);
        return;

      case 'send':
        await handleSend(results);
        return;

      case 'info':
        await showInfo(results);
        return;

      default:
        CliUi.error('Unknown command: $subcommand');
        _printUsage(parser);
        exit(1);
    }
  }

  // Default: receive mode
  final port = int.tryParse(results['port'] ?? '53317') ?? 53317;
  final outputDir = results['output'] ?? '.';
  final alias = results['alias'] ?? 'CLI Device';
  final autoReceive = results['auto'] as bool;
  final daemon = results['daemon'] as bool;

  await startReceive(
    port: port,
    outputDir: outputDir,
    alias: alias,
    autoReceive: autoReceive,
    daemon: daemon,
  );
}

Future<void> listDevices(ArgResults results, {bool forCompletion = false}) async {
  final port = int.tryParse(results['port'] ?? '53317') ?? 53317;
  final alias = results['alias'] ?? 'CLI Device';

  await CliDaemon.listDevices(alias: alias, port: port, forCompletion: forCompletion);
}

Future<void> handleSend(ArgResults results) async {
  final sendArgs = results.rest.sublist(1); // remove 'send'
  await CliSend.execute(sendArgs);
}

/// Handle send command directly (bypasses main argparser)
Future<void> handleSendDirect(List<String> args) async {
  await CliSend.execute(args);
}

Future<void> showInfo(ArgResults results) async {
  final port = int.tryParse(results['port'] ?? '53317') ?? 53317;
  final alias = results['alias'] ?? 'CLI Device';

  await CliDaemon.showDeviceInfo(alias: alias, port: port);
}

Future<void> startReceive({
  required int port,
  required String outputDir,
  required String alias,
  required bool autoReceive,
  required bool daemon,
}) async {
  if (daemon) {
    // Fork to create daemon process
    await _runAsDaemon(
      port: port,
      outputDir: outputDir,
      alias: alias,
      autoReceive: autoReceive,
    );
  } else {
    // Interactive receive mode
    await CliDaemon.runInteractive(
      port: port,
      outputDir: outputDir,
      alias: alias,
      autoReceive: autoReceive,
    );
  }
}

void _printUsage(ArgParser parser) {
  print('''
LocalSend CLI - Send and receive files over LAN

Usage:
  ${_exeName} [options] [command]

Commands:
  list              List available devices on the network
  send <device>     Send files/text to a device
  info              Show this device's information

Options:
${parser.usage}

Examples:
  ${_exeName} --receive              # Receive files (ask before saving)
  ${_exeName} --receive --auto     # Auto-receive without confirmation
  ${_exeName} --receive -o ./dl   # Save to ./dl directory
  ${_exeName} list                 # Show available devices
  ${_exeName} send my-phone file.txt  # Send file to device "my-phone"
  ${_exeName} send my-phone --text "Hello"  # Send text
''');
}

Future<void> _runAsDaemon({
  required int port,
  required String outputDir,
  required String alias,
  required bool autoReceive,
}) async {
  if (Platform.isWindows) {
    // Windows doesn't support fork - just run in foreground with a warning
    CliUi.warning('Daemon mode not supported on Windows, running in foreground');
    await CliDaemon.runInteractive(
      port: port,
      outputDir: outputDir,
      alias: alias,
      autoReceive: autoReceive,
    );
    return;
  }

  // Fork the process
  final pid = await Process.start(
    Platform.resolvedExecutable,
    ['--receive', '--port', port.toString(), '--output', outputDir, '--alias', alias],
    environment: Platform.environment,
  );

  // Parent process exits
  print('Daemon started with PID ${pid.pid}');
  print('Output directory: $outputDir');
  print('Port: $port');
  exit(0);
}

String get _exeName => path.basename(Platform.executable);
