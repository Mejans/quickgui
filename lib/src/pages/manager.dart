import 'dart:async';
import 'dart:convert';
import 'dart:core';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:file_picker/file_picker.dart';
import 'dart:io';

import '../globals.dart';
import '../model/vminfo.dart';
import '../mixins/preferences_mixin.dart';
import '../i18n/i18n_ext.dart';

/// VM manager page.
/// Displays a list of available VMs, running state and connection info,
/// with buttons to start and stop VMs.
class Manager extends StatefulWidget {
  const Manager({Key? key}) : super(key: key);

  @override
  State<Manager> createState() => _ManagerState();
}

class _ManagerState extends State<Manager> with PreferencesMixin {
  List<String> _currentVms = [];
  Map<String, VmInfo> _activeVms = {};
  final List<String> _spicyVms = [];
  final List<String> _sshVms = [];
  String? _terminalEmulator;
  Timer? refreshTimer;

  @override
  void initState() {
    super.initState();
    _getTerminalEmulator();
    getPreference<String>(prefWorkingDirectory).then((pref) {
      setState(() {
        if (pref == null) {
          return;
        }
        Directory.current = pref;
      });
      Future.delayed(Duration.zero, () => _getVms(context)); // Reload VM list when we enter the page.
    });
    refreshTimer = Timer.periodic(const Duration(seconds: 5), (Timer t) {
      _getVms(context);
    }); // Reload VM list every 5 seconds.
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    super.dispose();
  }


  void _getTerminalEmulator() async {
    ProcessResult result = Process.runSync('x-terminal-emulator', ['-h']);
    RegExp pattern = RegExp(r"usage:\s+([^\s]+)", multiLine: true, caseSensitive: false);
    RegExpMatch? match = pattern.firstMatch(result.stdout);
    if (match != null) {
      setState(() {
        _terminalEmulator = match.group(1);
      });
    }
  }

  VmInfo _parseVmInfo(name) {
    VmInfo info = VmInfo();
    List<String> lines = File(name + '/' + name + '.ports').readAsLinesSync();
    for (var line in lines) {
      List<String> parts = line.split(',');
      switch (parts[0]) {
        case 'ssh':
          info.sshPort = parts[1];
          break;
        case 'spice':
          info.spicePort = parts[1];
          break;
      }
    }
    return info;
  }

  bool _isValidConf(conf) {
    List<String> lines = File(conf).readAsLinesSync();
    for (var line in lines) {
      List<String> parts = line.split('=');
      if (parts[0] == 'guest_os') {
        return true;
      }
    }
    return false;
  }

  void _getVms(context) async {
    List<String> currentVms = [];
    Map<String, VmInfo> activeVms = {};

    await for (var entity in Directory.current.list(recursive: false, followLinks: true)) {
      if ((entity.path.endsWith('.conf')) && (_isValidConf(entity.path))) {
        String name = path.basenameWithoutExtension(entity.path);
        currentVms.add(name);
        File pidFile = File(name + '/' + name + '.pid');
        if (pidFile.existsSync()) {
          String pid = pidFile.readAsStringSync().trim();
          Directory procDir = Directory('/proc/' + pid);
          if (procDir.existsSync()) {
            if (_activeVms.containsKey(name)) {
              activeVms[name] = _activeVms[name]!;
            } else {
              activeVms[name] = _parseVmInfo(name);
            }
          }
        }
      }
    }
    currentVms.sort();
    setState(() {
      _currentVms = currentVms;
      _activeVms = activeVms;
    });
  }

  Future<bool> _detectSsh(int port) async {
    bool isSSH = false;
    try {
      Socket socket = await Socket.connect('localhost', port);
      isSSH = await socket.any((event) => utf8.decode(event).contains('SSH'));
      socket.close();
      return isSSH;
    } catch (exception) {
      return false;
    }
  }

  Widget _buildVmList() {
    List<Widget> _widgetList = [];
    _widgetList.add(
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            Directory.current.path,
          ),
          const SizedBox(
            width: 8,
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              primary: Theme.of(context).canvasColor,
              onPrimary: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Theme.of(context).colorScheme.primary,
            ),
            onPressed: () async {
              String? result = await FilePicker.platform.getDirectoryPath();
              if (result != null) {
                setState(() {
                  Directory.current = result;
                });

                savePreference(prefWorkingDirectory, Directory.current.path);
                _getVms(context);
              }
            },
            child: const Icon(Icons.more_horiz),
          ),
        ],
      ),
    );
    List<List<Widget>> rows = _currentVms.map((vm) {
      return _buildRow(vm);
    }).toList();
    for (var row in rows) {
      _widgetList.addAll(row);
    }

    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: _widgetList,
    );
  }

  List<Widget> _buildRow(String currentVm) {
    final bool active = _activeVms.containsKey(currentVm);
    final bool spicy = _spicyVms.contains(currentVm);
    final bool sshy = _sshVms.contains(currentVm);
    VmInfo vmInfo = VmInfo();
    String connectInfo = '';
    if (active) {
      vmInfo = _activeVms[currentVm]!;
      if (vmInfo.sshPort != null && _terminalEmulator != null) {
        connectInfo += context.t('SSH port') + ': ' + vmInfo.sshPort! + ' ';
        _detectSsh(int.parse(vmInfo.sshPort!)).then((sshRunning) {
          if (sshRunning && !sshy) {
            setState(() {
              _sshVms.add(currentVm);
            });
          } else if (!sshRunning && sshy) {
            setState(() {
              _sshVms.remove(currentVm);
            });
          }
        });
      }
      if (vmInfo.spicePort != null) {
        connectInfo += context.t('SPICE port') + ': ' + vmInfo.spicePort! + ' ';
      }
    }
    return <Widget>[
      ListTile(
          title: Text(currentVm),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IconButton(
                  icon: Icon(Icons.monitor,
                      color: spicy ? Colors.red : null, semanticLabel: spicy ? context.t('Using SPICE display') : context.t('Click to use SPICE display')),
                  tooltip: spicy ? context.t('Using SPICE display') : context.t('Use SPICE display'),
                  onPressed: () {
                    if (spicy) {
                      setState(() {
                        _spicyVms.remove(currentVm);
                      });
                    } else {
                      setState(() {
                        _spicyVms.add(currentVm);
                      });
                    }
                  }),
              IconButton(
                  icon: Icon(
                    active ? Icons.play_arrow : Icons.play_arrow_outlined,
                    color: active ? Colors.green : null,
                    semanticLabel: active ? 'Running' : 'Run',
                  ),
                  onPressed: () async {
                    if (!active) {
                      Map<String, VmInfo> activeVms = _activeVms;
                      List<String> args = ['--vm', currentVm + '.conf'];
                      if (spicy) {
                        args.addAll(['--display', 'spice']);
                      }
                      await Process.start('quickemu', args);
                      VmInfo info = _parseVmInfo(currentVm);
                      activeVms[currentVm] = info;
                      setState(() {
                        _activeVms = activeVms;
                      });
                    }
                  }),
              IconButton(
                icon: Icon(
                  active ? Icons.stop : Icons.stop_outlined,
                  color: active ? Colors.red : null,
                  semanticLabel: active ? 'Stop' : 'Not running',
                ),
                onPressed: () {
                  if (active) {
                    showDialog<bool>(
                      context: context,
                      builder: (BuildContext context) => AlertDialog(
                        title: Text(context.t('Stop The Virtual Machine?')),
                        content: Text('${context.t('You are about to terminate the virtual machine')} $currentVm'),
                        actions: <Widget>[
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: Text(context.t('Cancel')),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: Text(context.t('OK')),
                          ),
                        ],
                      ),
                    ).then((result) {
                      result = result ?? false;
                      if (result) {
                        Process.run('killall', [currentVm]);
                        setState(() {
                          _activeVms.remove(currentVm);
                        });
                      }
                    });
                  }
                },
              ),
            ],
          )),
      if (connectInfo.isNotEmpty)
        ListTile(
          title: Text(connectInfo),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextButton(
                child: Text('Spice'),
                onPressed: () {
                  Process.start('spicy', ['-p', vmInfo.spicePort!]);
                },
              ),
              TextButton(
                child: Text('SSH'),
                onPressed: !sshy ? null : () {
                  TextEditingController _usernameController = TextEditingController();
                  showDialog<bool>(
                    context: context,
                    builder: (BuildContext context) => AlertDialog(
                      title: Text('Launch SSH connection to $currentVm'),
                      content: TextField(
                        controller: _usernameController,
                        decoration: const InputDecoration(hintText: "SSH username"),
                      ),
                      actions: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Connect'),
                        ),
                      ],
                    ),
                  ).then((result) {
                    result = result ?? false;
                    if (result) {
                      List<String> sshArgs = ['ssh', '-p', vmInfo.sshPort!, _usernameController.text + '@localhost'];
                      switch(_terminalEmulator) {
                        case 'gnome-terminal':
                        case 'mate-terminal':
                          sshArgs.insert(0, '--');
                          break;
                        case 'xterm':
                        case 'konsole':
                          sshArgs.insert(0, '-e');
                          break;
                        case 'terminator':
                        case 'xfce4-terminal':
                          sshArgs.insert(0, '-x');
                          break;
                        case 'guake':
                          String command = sshArgs.join(' ');
                          sshArgs = ['-e', command];
                          break;
                      }
                      Process.start(_terminalEmulator!, sshArgs);
                    }
                  });
                },
              ),
            ]
          )
        ),
      const Divider()
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.t('Manager')),
      ),
      body: _buildVmList(),
    );
  }
}
