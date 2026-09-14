import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class DifferentialMix {
  const DifferentialMix({required this.left, required this.right});

  final double left;
  final double right;
}

double _deadZone(double value) => value.abs() < 0.06 ? 0.0 : value;

DifferentialMix differentialMix({
  required double throttle,
  required double steering,
}) {
  final cleanThrottle = _deadZone(throttle.clamp(-1.0, 1.0).toDouble());
  final cleanSteering = _deadZone(steering.clamp(-1.0, 1.0).toDouble());
  final rawLeft = cleanThrottle + cleanSteering;
  final rawRight = cleanThrottle - cleanSteering;
  final scale = math.max(1.0, math.max(rawLeft.abs(), rawRight.abs()));
  return DifferentialMix(left: rawLeft / scale, right: rawRight / scale);
}

// Chassis calibration measured from the real vehicle: raw upper-left is
// forward, upper-right turns left, lower-left turns right, and lower-right
// reverses. Rotate that measured frame so the visible pad has normal axes.
DifferentialMix carJoystickMix({required double x, required double y}) {
  final calibratedX = y - x;
  final calibratedY = x + y;
  return differentialMix(throttle: -calibratedY, steering: calibratedX);
}

void main() {
  runApp(const CarControllerApp());
}

class CarControllerApp extends StatelessWidget {
  const CarControllerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '烟台car-go',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        scaffoldBackgroundColor: const Color(0xfff5f7fb),
      ),
      home: const ConnectPage(),
    );
  }
}

class CarConnection extends ChangeNotifier {
  WebSocketChannel? _channel;
  RawDatagramSocket? _udpSocket;
  InternetAddress? _udpAddress;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  final Map<int, DateTime> _pendingCommands = <int, DateTime>{};

  String _host = '192.168.4.1';
  String? _lastError;
  int? _latencyMs;
  int _sequence = 0;
  int _reconnectAttempt = 0;
  bool _shouldReconnect = false;
  bool _isConnecting = false;
  bool _isConnected = false;

  static const int _controlUdpPort = 4210;

  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  String get host => _host;
  String? get lastError => _lastError;
  int? get latencyMs => _latencyMs;

  Future<void> connect(String host) async {
    final normalizedHost = host.trim().replaceFirst(RegExp(r'^ws://'), '');
    if (normalizedHost.isEmpty) {
      _lastError = '请输入 ESP32 的 IP 地址';
      notifyListeners();
      return;
    }

    await disconnect(silent: true);
    _host = normalizedHost.replaceFirst(RegExp(r':81$'), '');
    _shouldReconnect = true;
    _reconnectAttempt = 0;
    await _connectOnce();
  }

  Future<void> _connectOnce() async {
    if (_isConnecting || !_shouldReconnect) {
      return;
    }

    _isConnecting = true;
    _lastError = null;
    notifyListeners();

    try {
      final channel = WebSocketChannel.connect(Uri.parse('ws://$_host:81'));
      await channel.ready;
      if (!_shouldReconnect) {
        await channel.sink.close();
        return;
      }

      _channel = channel;
      _udpAddress = InternetAddress.tryParse(_host);
      if (_udpAddress != null) {
        try {
          final socket = await RawDatagramSocket.bind(
            InternetAddress.anyIPv4,
            0,
          );
          _udpSocket = socket;
          socket.listen(_onUdpEvent, onError: (_) {});
        } catch (_) {
          _udpSocket = null;
        }
      }
      _isConnected = true;
      _isConnecting = false;
      _reconnectAttempt = 0;
      _lastError = null;
      _subscription = channel.stream.listen(
        _onMessage,
        onError: (Object error) => _handleClosed('连接错误：$error'),
        onDone: () => _handleClosed('连接已断开'),
        cancelOnError: false,
      );
      notifyListeners();
    } catch (error) {
      _isConnecting = false;
      _isConnected = false;
      _lastError = '连接失败：$error';
      notifyListeners();
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic rawMessage) {
    _handleMessage(rawMessage);
  }

  void _onUdpEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) {
      return;
    }
    final socket = _udpSocket;
    if (socket == null) {
      return;
    }
    Datagram? datagram;
    while ((datagram = socket.receive()) != null) {
      _handleMessage(utf8.decode(datagram!.data, allowMalformed: true));
    }
  }

  void _handleMessage(dynamic rawMessage) {
    try {
      final text = rawMessage is String
          ? rawMessage
          : utf8.decode(rawMessage as List<int>, allowMalformed: true);
      final data = jsonDecode(text) as Map<String, dynamic>;
      if (data['type'] == 'ack') {
        final sequence = data['seq'];
        final sentAt = sequence is int
            ? _pendingCommands.remove(sequence)
            : null;
        if (sentAt != null) {
          final sample = DateTime.now().difference(sentAt).inMilliseconds;
          _latencyMs = _latencyMs == null
              ? sample
              : ((_latencyMs! * 0.65) + (sample * 0.35)).round();
          notifyListeners();
        }
      }
    } catch (_) {
      // Ignore malformed telemetry; the firmware still has its own watchdog.
    }
  }

  void _handleClosed(String reason) {
    if (_channel == null && !_isConnected) {
      return;
    }
    _subscription = null;
    _channel = null;
    _udpSocket?.close();
    _udpSocket = null;
    _udpAddress = null;
    _isConnected = false;
    _isConnecting = false;
    _lastError = reason;
    notifyListeners();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_shouldReconnect || _reconnectTimer != null) {
      return;
    }
    final seconds = math.min(8, 1 << _reconnectAttempt);
    _reconnectAttempt = math.min(_reconnectAttempt + 1, 3);
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      _reconnectTimer = null;
      unawaited(_connectOnce());
    });
  }

  void sendControl(double left, double right) {
    final channel = _channel;
    if (channel == null || !_isConnected) {
      return;
    }

    final sequence = _sequence++;
    _pendingCommands[sequence] = DateTime.now();
    while (_pendingCommands.length > 64) {
      _pendingCommands.remove(_pendingCommands.keys.first);
    }

    final sentAt = DateTime.now();
    final payload = jsonEncode(<String, dynamic>{
      'type': 'control',
      'seq': sequence,
      'clientMs': sentAt.millisecondsSinceEpoch,
      'left': left.clamp(-1.0, 1.0),
      'right': right.clamp(-1.0, 1.0),
    });

    try {
      final udpSocket = _udpSocket;
      final udpAddress = _udpAddress;
      if (udpSocket != null && udpAddress != null) {
        udpSocket.send(
          Uint8List.fromList(utf8.encode(payload)),
          udpAddress,
          _controlUdpPort,
        );
      } else {
        channel.sink.add(payload);
      }
    } catch (error) {
      _handleClosed('发送失败：$error');
    }
  }

  Future<void> disconnect({bool silent = false}) async {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final subscription = _subscription;
    final channel = _channel;
    _subscription = null;
    _channel = null;
    _udpSocket?.close();
    _udpSocket = null;
    _udpAddress = null;
    _isConnected = false;
    _isConnecting = false;
    _pendingCommands.clear();

    await subscription?.cancel();
    await channel?.sink.close();
    if (!silent) {
      _lastError = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(disconnect(silent: true));
    super.dispose();
  }
}

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final CarConnection _connection = CarConnection();
  final TextEditingController _hostController = TextEditingController(
    text: '192.168.4.1',
  );

  @override
  void initState() {
    super.initState();
    _connection.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _connect() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (!_connection.isConnected) {
      await _connection.connect(_hostController.text);
    }
    if (!mounted || !_connection.isConnected) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ControlPage(connection: _connection),
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _connection.removeListener(_refresh);
    _hostController.dispose();
    _connection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _connection.isConnected;
    return Scaffold(
      appBar: AppBar(title: const Text('ESP32 小车')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '连接小车',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text('先在手机 Wi-Fi 设置中连接 ESP32 创建的网络，然后在这里建立控制连接。'),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _hostController,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'ESP32 IP 地址',
                      hintText: '192.168.4.1',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.router_outlined),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _connection.isConnecting ? null : _connect,
                      icon: _connection.isConnecting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(connected ? Icons.sports_esports : Icons.link),
                      label: Text(
                        _connection.isConnecting
                            ? '连接中…'
                            : connected
                            ? '进入控制页面'
                            : '连接',
                      ),
                    ),
                  ),
                  if (_connection.lastError != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      _connection.lastError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const <Widget>[
                  Text('连接步骤', style: TextStyle(fontWeight: FontWeight.bold)),
                  SizedBox(height: 10),
                  Text('1. 给 ESP32 上电。'),
                  Text('2. 手机加入 Wi-Fi：Yantai-Car。'),
                  Text('3. 密码：car123456。'),
                  Text('4. IP 保持 192.168.4.1，点击连接。'),
                  SizedBox(height: 10),
                  Text('控制使用低延迟 UDP，WebSocket 负责连接保持；固件 500 ms 没有控制包会自动停车。'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ControlPage extends StatefulWidget {
  const ControlPage({required this.connection, super.key});

  final CarConnection connection;

  @override
  State<ControlPage> createState() => _ControlPageState();
}

class _ControlPageState extends State<ControlPage> {
  Timer? _controlTimer;
  SharedPreferences? _preferences;
  Offset _joystick = Offset.zero;
  double _left = 0;
  double _right = 0;
  double _testLeft = 0;
  double _testRight = 0;
  bool _isTestingMotor = false;
  bool _invertLeftMotor = false;
  bool _invertRightMotor = false;

  static const _leftInvertedKey = 'left_motor_inverted';
  static const _rightInvertedKey = 'right_motor_inverted';
  static const _calibrationRevisionKey = 'calibration_revision';
  static const _calibrationRevision = 2;

  CarConnection get connection => widget.connection;

  @override
  void initState() {
    super.initState();
    connection.addListener(_refresh);
    unawaited(_loadMotorCalibration());
    _controlTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _sendCurrentCommand();
    });
  }

  Future<void> _loadMotorCalibration() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) {
      return;
    }

    var invertLeft = preferences.getBool(_leftInvertedKey) ?? false;
    var invertRight = preferences.getBool(_rightInvertedKey) ?? false;
    final revision = preferences.getInt(_calibrationRevisionKey) ?? 0;
    // The previous test accidentally saved both directions as reversed. The
    // chassis was measured working with left inverted and right normal.
    if (revision < _calibrationRevision && invertLeft && invertRight) {
      invertLeft = true;
      invertRight = false;
      await preferences.setBool(_leftInvertedKey, invertLeft);
      await preferences.setBool(_rightInvertedKey, invertRight);
    }
    await preferences.setInt(_calibrationRevisionKey, _calibrationRevision);
    if (!mounted) {
      return;
    }
    setState(() {
      _preferences = preferences;
      _invertLeftMotor = invertLeft;
      _invertRightMotor = invertRight;
    });
    _setJoystick(_joystick);
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  void _setJoystick(Offset value) {
    final x = value.dx.clamp(-1.0, 1.0).toDouble();
    final y = value.dy.clamp(-1.0, 1.0).toDouble();
    final mix = carJoystickMix(x: x, y: y);
    setState(() {
      _joystick = Offset(x, y);
      _left = _invertLeftMotor ? -mix.left : mix.left;
      _right = _invertRightMotor ? -mix.right : mix.right;
    });
  }

  void _sendCurrentCommand() {
    connection.sendControl(
      _isTestingMotor ? _testLeft : _left,
      _isTestingMotor ? _testRight : _right,
    );
  }

  void _setMotorInversion({bool? left, bool? right}) {
    setState(() {
      if (left != null) {
        _invertLeftMotor = left;
        unawaited(_preferences?.setBool(_leftInvertedKey, left));
      }
      if (right != null) {
        _invertRightMotor = right;
        unawaited(_preferences?.setBool(_rightInvertedKey, right));
      }
    });
    _setJoystick(_joystick);
  }

  void _startMotorTest({required double left, required double right}) {
    setState(() {
      _isTestingMotor = true;
      _testLeft = left;
      _testRight = right;
    });
    _sendCurrentCommand();
  }

  void _stopMotorTest() {
    if (!_isTestingMotor) {
      return;
    }
    setState(() {
      _isTestingMotor = false;
      _testLeft = 0;
      _testRight = 0;
    });
    _sendCurrentCommand();
  }

  void _startForwardMotorTest(bool isLeft) {
    _startMotorTest(
      left: isLeft ? (_invertLeftMotor ? -0.35 : 0.35) : 0,
      right: isLeft ? 0 : (_invertRightMotor ? -0.35 : 0.35),
    );
  }

  Future<void> _openMotorCalibration() async {
    _stop();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '电机方向校准',
                      style: Theme.of(sheetContext).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    const Text('车轮架空后，按住测试按钮。若该轮向后转，就打开对应的“反向”开关。设置会自动保存。'),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('左电机反向'),
                      value: _invertLeftMotor,
                      onChanged: (value) {
                        _setMotorInversion(left: value);
                        setSheetState(() {});
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('右电机反向'),
                      value: _invertRightMotor,
                      onChanged: (value) {
                        _setMotorInversion(right: value);
                        setSheetState(() {});
                      },
                    ),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: _HoldMotorTestButton(
                            label: '按住测试左轮前进',
                            onStart: () => _startForwardMotorTest(true),
                            onStop: _stopMotorTest,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _HoldMotorTestButton(
                            label: '按住测试右轮前进',
                            onStart: () => _startForwardMotorTest(false),
                            onStop: _stopMotorTest,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    _stopMotorTest();
  }

  void _stop() {
    _stopMotorTest();
    _setJoystick(Offset.zero);
    connection.sendControl(0, 0);
  }

  int _toPulse(double value) => (1500 + value * 500).round();

  @override
  void dispose() {
    _controlTimer?.cancel();
    connection.removeListener(_refresh);
    connection.sendControl(0, 0);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = connection.isConnected ? Colors.green : Colors.red;
    final latency = connection.latencyMs;
    return Scaffold(
      appBar: AppBar(
        title: const Text('摇杆控制'),
        actions: <Widget>[
          IconButton(
            tooltip: '电机校准',
            onPressed: _openMotorCalibration,
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            tooltip: '停止',
            onPressed: _stop,
            icon: const Icon(Icons.stop_circle_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            children: <Widget>[
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.circle, size: 12, color: statusColor),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          connection.isConnected
                              ? '已连接 ${connection.host}'
                              : '连接已断开',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Chip(
                        avatar: const Icon(Icons.speed, size: 18),
                        label: Text(
                          latency == null ? '延迟 --' : '延迟 $latency ms',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '上推前进，下拉后退，左右推动转向；松手自动回中。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Expanded(
                child: Center(
                  child: JoystickPad(
                    value: _joystick,
                    onChanged: _setJoystick,
                    onReleased: () => _setJoystick(Offset.zero),
                  ),
                ),
              ),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _PwmCard(title: '左轮 PWM', value: _toPulse(_left)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _PwmCard(title: '右轮 PWM', value: _toPulse(_right)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                height: 42,
                child: FilledButton.tonalIcon(
                  onPressed: _stop,
                  icon: const Icon(Icons.pause_circle_outline),
                  label: const Text('立即停止'),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                height: 42,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    _stop();
                    await connection.disconnect();
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                  },
                  icon: const Icon(Icons.link_off),
                  label: const Text('断开连接'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HoldMotorTestButton extends StatelessWidget {
  const _HoldMotorTestButton({
    required this.label,
    required this.onStart,
    required this.onStop,
  });

  final String label;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => onStart(),
      onPointerUp: (_) => onStop(),
      onPointerCancel: (_) => onStop(),
      child: FilledButton.tonal(
        onPressed: () {},
        child: Text(label, textAlign: TextAlign.center),
      ),
    );
  }
}

class _PwmCard extends StatelessWidget {
  const _PwmCard({required this.title, required this.value});

  final String title;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          children: <Widget>[
            Text(title),
            const SizedBox(height: 4),
            Text('$value µs', style: Theme.of(context).textTheme.titleLarge),
          ],
        ),
      ),
    );
  }
}

class JoystickPad extends StatelessWidget {
  const JoystickPad({
    required this.value,
    required this.onChanged,
    required this.onReleased,
    super.key,
  });

  final Offset value;
  final ValueChanged<Offset> onChanged;
  final VoidCallback onReleased;

  void _update(Offset localPosition, double side) {
    final center = side / 2;
    final radius = side * 0.36;
    final dx = ((localPosition.dx - center) / radius).clamp(-1.0, 1.0);
    final dy = ((localPosition.dy - center) / radius).clamp(-1.0, 1.0);
    onChanged(Offset(dx.toDouble(), dy.toDouble()));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : 330.0;
        final side = math
            .min(math.min(constraints.maxWidth, 330.0), availableHeight)
            .toDouble();
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) => _update(details.localPosition, side),
          onPanUpdate: (details) => _update(details.localPosition, side),
          onPanEnd: (_) => onReleased(),
          onPanCancel: onReleased,
          child: CustomPaint(
            size: Size.square(side),
            painter: _JoystickPainter(
              value: value,
              color: Theme.of(context).colorScheme,
            ),
          ),
        );
      },
    );
  }
}

class _JoystickPainter extends CustomPainter {
  const _JoystickPainter({required this.value, required this.color});

  final Offset value;
  final ColorScheme color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = size.shortestSide * 0.43;
    final stickRadius = size.shortestSide * 0.13;
    final travel = size.shortestSide * 0.27;

    final basePaint = Paint()..color = color.primaryContainer;
    canvas.drawCircle(center, baseRadius, basePaint);

    final guidePaint = Paint()
      ..color = color.onPrimaryContainer.withValues(alpha: 0.18)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, baseRadius * 0.65, guidePaint);
    canvas.drawLine(
      Offset(center.dx - baseRadius, center.dy),
      Offset(center.dx + baseRadius, center.dy),
      guidePaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - baseRadius),
      Offset(center.dx, center.dy + baseRadius),
      guidePaint,
    );

    final knobCenter = center + Offset(value.dx * travel, value.dy * travel);
    final knobPaint = Paint()..color = color.primary;
    canvas.drawCircle(knobCenter, stickRadius, knobPaint);
    final highlightPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.25);
    canvas.drawCircle(
      knobCenter - Offset(stickRadius * 0.25, stickRadius * 0.25),
      stickRadius * 0.25,
      highlightPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _JoystickPainter oldDelegate) {
    return oldDelegate.value != value || oldDelegate.color != color;
  }
}
