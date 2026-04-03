# LocalSend CLI

A command-line interface for LocalSend - send and receive files over LAN from your terminal.

## Features

- **Receive Mode**: Start a server to receive files (interactive or auto-receive)
- **Device Discovery**: List devices with friendly names
- **Send Mode**: Send files, text, or clipboard content to devices
- **Tab Completion**: Device name completion (with shell completion setup)

## Installation

```bash
cd cli
dart pub get
dart compile exe bin/cli.dart -o localsend
```

Or run directly:

```bash
dart run bin/cli.dart --help
```

## Commands

### Receive Files

```bash
# Interactive receive mode (ask before saving each file)
localsend --receive

# Auto-receive mode (save files without confirmation)
localsend --receive --auto

# Specify output directory
localsend --receive -o ./downloads

# Run as daemon (background)
localsend --receive --daemon
```

### List Devices

```bash
# Discover and list available devices
localsend list

# Custom alias and port
localsend list -a "My CLI" -p 53317
```

Output example:
```
=== Scanning for devices... ===

=== Available Devices ===

  ID   Name              Type      IP             Port  Accept
  ---------------------------------------------------------------------------
  1    My Phone          Phone     192.168.1.100  53317 ✓
  2    MacBook Pro       Desktop   192.168.1.101  53317 ✓

  2 device(s) found

  To send files:
    localsend send <name> <file>
```

### Send Files

```bash
# Send file by device name
localsend send "My Phone" file.txt

# Send file by device ID (from list)
localsend send 1 file.txt

# Send multiple files
localsend send "My Phone" file1.txt file2.txt image.png

# Send text content
localsend send "My Phone" --text "Hello from CLI"

# Send clipboard content
localsend send "My Phone" --clipboard
```

### Device Information

```bash
# Show this device's info
localsend info
```

## Global Options

| Option | Short | Description | Default |
|--------|-------|-------------|---------|
| `--alias` | `-a` | Device alias/name | `CLI Device` |
| `--port` | `-p` | Port to use | `53317` |
| `--help` | `-h` | Show help | - |

## Receive Mode Options

| Option | Description |
|--------|-------------|
| `--receive` | Start receive mode |
| `--auto` | Auto-receive without confirmation |
| `--daemon` | Run as background daemon |
| `--output` | Output directory for received files |

## Tab Completion

For bash/zsh tab completion of device names, add to your shell config:

```bash
# bash (~/.bashrc)
source <(localsend completion bash)

# zsh (~/.zshrc)
source <(localsend completion zsh)
```

## Protocol

This CLI implements the LocalSend protocol v2.1:

- **Discovery**: UDP multicast on `224.0.0.167:53317` + HTTP scanning
- **Transfer**: HTTP POST-based file transfer with session management
- **Security**: Token-based session validation

## Architecture

```
lib/
├── main.dart          # Entry point with subcommands
├── cli_daemon.dart   # Receive server and device discovery
├── cli_send.dart      # File/text/clipboard sending
└── cli_ui.dart       # Console UI utilities
```

## Dependencies

- `common` - Shared models and protocol code from LocalSend
- `args` - Command-line argument parsing
- `http` - HTTP client for file transfer
