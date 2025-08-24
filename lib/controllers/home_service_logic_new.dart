import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:rxdart/rxdart.dart';
import 'package:orbits_new/background/ble_work_manager.dart';
import 'package:orbits_new/database/dao/device_dao.dart';
import 'package:orbits_new/database/models/contact_device.dart';
import 'package:orbits_new/plugins/ble_uuid_broadcaster.dart';
import 'package:orbits_new/plugins/ble_scan_service.dart';
import 'package:orbits_new/utils/secure_storage_service.dart';

// 这个文件热启动是没有问题的！
// 定义蓝牙工作模式的枚举，避免硬编码字符串
enum BleWorkMode { highFrequency, lowPower }

// 定义服务状态的枚举，提供更清晰的状态管理
enum ServiceState { initializing, running, stopped, error, permissionDenied }

class HomeServiceLogic with ChangeNotifier {
  // 状态管理
  ServiceState _serviceState = ServiceState.initializing;
  ServiceState get serviceState => _serviceState;

  // 分离的服务状态
  bool _broadcastServiceRunning = false;
  bool _scanServiceRunning = false;

  // 当前工作模式
  BleWorkMode _currentMode = BleWorkMode.highFrequency;
  BleWorkMode get currentMode => _currentMode;

  // 状态同步定时器
  Timer? _stateSyncTimer;

  // 初始化完成标志
  Completer<void>? _initializationCompleter;

  // 重启尝试计数
  int _restartAttempts = 0;
  static const int maxRestartAttempts = 3;

  // 状态信息
  String _serviceStatusMessage = 'Service initializing...';
  String get serviceStatusMessage => _serviceStatusMessage;

  // 依赖项
  final DeviceDao _deviceDao = DeviceDao();
  final SecureStorageService _secureStorageService = SecureStorageService();
  final BluetoothScanService _bluetoothScanService = BluetoothScanService();
  final BleUuidBroadcaster _bleUuidBroadcaster = BleUuidBroadcaster();

  // 构造函数：延迟初始化
  HomeServiceLogic() {
    print("[HomeServiceLogic] Constructor called");
    // 延迟初始化，避免在构造函数中执行异步操作
    WidgetsBinding.instance.addPostFrameCallback((_) {
      initialize();
    });
  }

  // 在应用关闭时释放资源
  @override
  void dispose() {
    _stateSyncTimer?.cancel();
    _bluetoothScanService.dispose();
    _deviceDao.dispose();
    super.dispose();
  }

  /// 异步初始化方法
  Future<void> initialize() async {
    if (_initializationCompleter != null) {
      return _initializationCompleter!.future;
    }

    _initializationCompleter = Completer<void>();

    try {
      print("[HomeServiceLogic] Starting initialization...");

      // 1. 先检查权限
      if (!await _checkPermissions()) {
        _updateServiceState(ServiceState.permissionDenied);
        _initializationCompleter!.complete();
        return;
      }

      // 2. 初始化数据库
      await _deviceDao.initialize();

      // 3. 初始化蓝牙扫描服务
      await _bluetoothScanService.init();

      // 4. 设置服务重启回调
      _bleUuidBroadcaster.setServiceRestartedCallback(() {
        print("[HomeServiceLogic] Service restart callback triggered");
        _restartBroadcastService();
      });

      // 5. 检查现有服务状态
      await _checkExistingServices();

      // 6. 启动服务（如果需要）
      if (_serviceState == ServiceState.stopped) {
        await _startServices();
      }

      // 7. 启动状态同步定时器
      _startStateSyncTimer();

      print("[HomeServiceLogic] Initialization completed successfully");
      _initializationCompleter!.complete();
    } catch (e) {
      print("[HomeServiceLogic] Initialization failed: $e");
      _updateServiceState(ServiceState.error);
      _initializationCompleter!.completeError(e);
    }
  }

  /// 检查现有服务状态
  Future<void> _checkExistingServices() async {
    try {
      final status = await checkAllServicesStatus();
      _broadcastServiceRunning = status['broadcast'] ?? false;
      _scanServiceRunning = status['scan'] ?? false;

      print(
        "[HomeServiceLogic] Existing services - Broadcast: $_broadcastServiceRunning, Scan: $_scanServiceRunning",
      );

      if (_broadcastServiceRunning && _scanServiceRunning) {
        _updateServiceState(ServiceState.running);
      } else {
        _updateServiceState(ServiceState.stopped);
      }
    } catch (e) {
      print("[HomeServiceLogic] Error checking existing services: $e");
      _updateServiceState(ServiceState.error);
    }
  }

  /// 启动状态同步定时器
  void _startStateSyncTimer() {
    _stateSyncTimer?.cancel();
    _stateSyncTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      _syncServiceStates();
    });
    print("[HomeServiceLogic] State sync timer started");
  }

  /// 同步服务状态
  Future<void> _syncServiceStates() async {
    try {
      final status = await checkAllServicesStatus();
      final newBroadcastStatus = status['broadcast'] ?? false;
      final newScanStatus = status['scan'] ?? false;

      // 检测状态变化
      if (_broadcastServiceRunning != newBroadcastStatus ||
          _scanServiceRunning != newScanStatus) {
        print(
          "[HomeServiceLogic] Service state change detected - Broadcast: $newBroadcastStatus, Scan: $newScanStatus",
        );

        _broadcastServiceRunning = newBroadcastStatus;
        _scanServiceRunning = newScanStatus;

        // 根据状态变化决定是否需要重启
        if (!newBroadcastStatus && !newScanStatus) {
          // 两个服务都停止了，需要重启
          await _restartServices();
        } else if (!newBroadcastStatus && newScanStatus) {
          // 只有广播服务停止了
          await _restartBroadcastService();
        } else if (newBroadcastStatus && !newScanStatus) {
          // 只有扫描服务停止了
          await _restartScanService();
        }
      }
    } catch (e) {
      print("[HomeServiceLogic] State sync error: $e");
    }
  }

  /// 重启所有服务
  Future<void> _restartServices() async {
    if (_restartAttempts >= maxRestartAttempts) {
      _updateServiceState(ServiceState.error);
      return;
    }

    _restartAttempts++;
    print("[HomeServiceLogic] Restarting services (attempt $_restartAttempts)");

    try {
      await _startServices();
      _restartAttempts = 0; // 重置计数器
    } catch (e) {
      print("[HomeServiceLogic] Restart failed: $e");
      // 延迟重试
      Future.delayed(Duration(seconds: _restartAttempts * 5), () {
        _restartServices();
      });
    }
  }

  /// 启动所有服务
  Future<void> _startServices() async {
    try {
      _updateServiceState(ServiceState.initializing);

      // 获取必要数据
      final String userUuid = await _secureStorageService.getOrCreateUserUUID();
      final String secretKey = await _secureStorageService
          .getOrCreateSecretKey();
      final List<String> knownUserUUIDs = await getKnownUserUUIDs();

      print(
        "[HomeServiceLogic] Starting services with ${knownUserUUIDs.length} known devices",
      );

      // 并行启动服务
      await Future.wait([
        _startBroadcastService(userUuid, secretKey),
        _startScanService(secretKey, knownUserUUIDs),
        _registerBackgroundTask(userUuid, secretKey, knownUserUUIDs),
      ]);

      _updateServiceState(ServiceState.running);
      print("[HomeServiceLogic] All services started successfully");
    } catch (e) {
      print("[HomeServiceLogic] Failed to start services: $e");
      _updateServiceState(ServiceState.error);
      throw e;
    }
  }

  /// 启动广播服务
  Future<void> _startBroadcastService(String userUuid, String secretKey) async {
    await _bleUuidBroadcaster.startBroadcast(
      secretKey: secretKey,
      userUuid: userUuid,
    );
    _broadcastServiceRunning = true;
    print("[HomeServiceLogic] Broadcast service started");
  }

  /// 启动扫描服务
  Future<void> _startScanService(
    String secretKey,
    List<String> knownUserUUIDs,
  ) async {
    await _bluetoothScanService.startScanningService(
      secretKey: secretKey,
      knownUserUUIDs: knownUserUUIDs,
    );
    _scanServiceRunning = true;
    print("[HomeServiceLogic] Scan service started");
  }

  /// 注册后台任务
  Future<void> _registerBackgroundTask(
    String userUuid,
    String secretKey,
    List<String> knownUserUUIDs,
  ) async {
    await registerBleScanTask(
      secretKey: secretKey,
      userUuid: userUuid,
      knownUserUUIDs: knownUserUUIDs,
    );
    print("[HomeServiceLogic] Background task registered");
  }

  /// 重启广播服务
  Future<void> _restartBroadcastService() async {
    try {
      final String userUuid = await _secureStorageService.getOrCreateUserUUID();
      final String secretKey = await _secureStorageService
          .getOrCreateSecretKey();

      print("[HomeServiceLogic] Restarting broadcast service...");
      await _bleUuidBroadcaster.startBroadcast(
        secretKey: secretKey,
        userUuid: userUuid,
      );
      _broadcastServiceRunning = true;
      print("[HomeServiceLogic] Broadcast service restarted successfully");
    } catch (e) {
      print("[HomeServiceLogic] Error restarting broadcast service: $e");
      _broadcastServiceRunning = false;
    }
  }

  /// 重启扫描服务
  Future<void> _restartScanService() async {
    try {
      final String secretKey = await _secureStorageService
          .getOrCreateSecretKey();
      final List<String> knownUserUUIDs = await getKnownUserUUIDs();

      print("[HomeServiceLogic] Restarting scan service...");
      await _bluetoothScanService.startScanningService(
        secretKey: secretKey,
        knownUserUUIDs: knownUserUUIDs,
      );
      _scanServiceRunning = true;
      print("[HomeServiceLogic] Scan service restarted successfully");
    } catch (e) {
      print("[HomeServiceLogic] Error restarting scan service: $e");
      _scanServiceRunning = false;
    }
  }

  /// 更新服务状态
  void _updateServiceState(ServiceState newState) {
    if (_serviceState != newState) {
      _serviceState = newState;
      _updateServiceStatusDisplay();
      notifyListeners();
    }
  }

  /// 检查权限的辅助方法
  Future<bool> _checkPermissions() async {
    final Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final hasAllPermissions = !statuses.values.any((status) => status.isDenied);
    print("[HomeServiceLogic] Permission check result: $hasAllPermissions");
    return hasAllPermissions;
  }

  /// 检查所有BLE服务的运行状态
  Future<Map<String, bool>> checkAllServicesStatus() async {
    try {
      final bool? broadcastRunning = await _bleUuidBroadcaster
          .isServiceRunning();
      final bool? scanServiceRunning = await _bluetoothScanService
          .isServiceRunning();

      // Handle null values by providing a default (false in this case)
      final bool broadcastStatus = broadcastRunning ?? false;
      final bool scanStatus = scanServiceRunning ?? false;

      print(
        "[HomeServiceLogic] Service status check - Broadcast: $broadcastStatus, Scan: $scanStatus",
      );

      return {
        'broadcast': broadcastStatus,
        'scan': scanStatus,
        'overall': _serviceState == ServiceState.running,
      };
    } catch (e) {
      print("[HomeServiceLogic] Error checking service status: $e");
      return {'broadcast': false, 'scan': false, 'overall': false};
    }
  }

  /// 获取详细的BLE状态信息
  Future<String> getDetailedBleStatus() async {
    final status = await checkAllServicesStatus();
    final modeText = _currentMode == BleWorkMode.highFrequency
        ? 'High Frequency'
        : 'Low Power';

    return '''
BLE Service Status:
- Broadcast Service: ${status['broadcast'] ?? false ? '✅ Running' : '❌ Stopped'}
- Scan Service: ${status['scan'] ?? false ? '✅ Running' : '❌ Stopped'}
- Overall Status: ${status['overall'] ?? false ? '✅ Active' : '❌ Inactive'}
- Service State: $_serviceState
- Current Mode: $modeText
- Status Message: $serviceStatusMessage
''';
  }

  /// 获取已知用户UUID列表
  Future<List<String>> getKnownUserUUIDs() async {
    try {
      final uuids = await _deviceDao.getAllUserUUIDs();
      print("[HomeServiceLogic] Retrieved ${uuids.length} known UUIDs");
      return uuids;
    } catch (e) {
      print("[HomeServiceLogic] Error getting known UUIDs: $e");
      return [];
    }
  }

  /// 刷新扫描服务的UUID列表
  Future<void> refreshScanServiceUUIDs() async {
    try {
      final knownUserUUIDs = await getKnownUserUUIDs();
      // 重启扫描服务以使用新的UUID列表
      await _bluetoothScanService.stopScanningService();

      final String secretKey = await _secureStorageService
          .getOrCreateSecretKey();

      await _bluetoothScanService.startScanningService(
        secretKey: secretKey,
        knownUserUUIDs: knownUserUUIDs,
      );

      print(
        "[HomeServiceLogic] Scan service refreshed with ${knownUserUUIDs.length} known devices",
      );
    } catch (e) {
      print("[HomeServiceLogic] Error refreshing scan service: $e");
    }
  }

  /// 手动启动服务（供UI调用）
  Future<void> startServiceAutomatically() async {
    if (_serviceState == ServiceState.running) {
      print("[HomeServiceLogic] Service already running");
      return;
    }

    try {
      await _startServices();
    } catch (e) {
      print("[HomeServiceLogic] Failed to start service: $e");
      _updateServiceStatusDisplay(error: 'Start failed: $e');
    }
  }

  /// 检查扫描服务是否真正运行并接收数据
  Future<bool> checkScanServiceActive() async {
    try {
      final bool scanRunning = await _bluetoothScanService.isServiceRunning();
      print("[HomeServiceLogic] Scan service running status: $scanRunning");
      return scanRunning;
    } catch (e) {
      print("[HomeServiceLogic] Error checking scan service: $e");
      return false;
    }
  }

  /// 根据应用生命周期切换工作模式
  void setModeForLifecycle(AppLifecycleState state) {
    if (_serviceState != ServiceState.running) return;

    switch (state) {
      case AppLifecycleState.resumed:
        setServiceMode(BleWorkMode.highFrequency);
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        setServiceMode(BleWorkMode.lowPower);
        break;
      default:
        break;
    }
    _updateServiceStatusDisplay();
    notifyListeners();
  }

  /// 设置 BLE 服务的广播和扫描模式
  void setServiceMode(BleWorkMode mode) {
    _currentMode = mode;
    final modeString = mode == BleWorkMode.highFrequency
        ? 'high_frequency'
        : 'low_power';
    _bleUuidBroadcaster.setAdvertisingMode(modeString);
    _bluetoothScanService.setScanMode(modeString);
    _updateServiceStatusDisplay();
    notifyListeners();
  }

  /// 更新 UI 上服务的状态显示
  void _updateServiceStatusDisplay({String? error}) {
    if (error != null) {
      _serviceStatusMessage = 'Bluetooth Detection Service: Error - $error';
    } else {
      final modeText = _currentMode == BleWorkMode.highFrequency
          ? 'Foreground High-Freq'
          : 'Background Low-Power';
      final stateText = _serviceState.toString().split('.').last;
      _serviceStatusMessage =
          'Bluetooth Detection Service: $stateText ($modeText)';
    }
  }

  /// 处理扫描到的二维码数据并更新数据库
  Future<String?> handleScannedData(String qrData) async {
    try {
      final Map<String, dynamic> data = jsonDecode(qrData);
      final otherUserUuid = data['userUuid'] as String?;
      final otherSecretKey = data['secretKey'] as String?;

      if (otherUserUuid != null && otherSecretKey != null) {
        final newContactDevice = ContactDevice(
          uuid: otherUserUuid,
          secretKey: otherSecretKey,
          lastSeen: DateTime.now().toIso8601String(),
          firstSeen: DateTime.now().toIso8601String(),
          rssi: -50,
        );
        await _deviceDao.insertDevice(newContactDevice);
        return null;
      } else {
        return 'Invalid QR code data: UUID or SecretKey is missing.';
      }
    } catch (e) {
      return 'Invalid data format: $e';
    }
  }

  /// 生成二维码数据
  Future<Map<String, String>> getMyQrData() async {
    final userUuid = await _secureStorageService.getOrCreateUserUUID();
    final secretKey = await _secureStorageService.getOrCreateSecretKey();
    return {'userUuid': userUuid, 'secretKey': secretKey};
  }

  // 使用 Stream 直接从 DAO 获取实时统计数据
  Stream<int> get deviceCountStream {
    print("[HomeServiceLogic] deviceCountStream accessed");
    return _deviceDao.getDeviceCountStream();
  }

  Stream<int> get totalMinutesStream {
    print("[HomeServiceLogic] totalMinutesStream accessed");
    return _deviceDao.getTotalContactMinutesStream();
  }
}
