import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:orbits_new/background/ble_work_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orbits_new/database/dao/device_dao.dart';
import 'package:orbits_new/plugins/ble_uuid_broadcaster.dart';
import 'package:orbits_new/plugins/ble_scan_service.dart';
import 'package:orbits_new/utils/secure_storage_service.dart';

// 定义蓝牙工作模式的枚举，避免硬编码字符串
enum BleWorkMode { highFrequency, lowPower }

// 【修改】重新添加stopping状态
enum ServiceState {
  initializing,
  running,
  stopped,
  error,
  permissionDenied,
  stopping,
}

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

    // 修改：立即开始初始化，而不是等待postFrameCallback
    _initializeImmediately();
  }

  // 在应用关闭时释放资源
  @override
  void dispose() {
    _stateSyncTimer?.cancel();
    _bluetoothScanService.dispose();
    _deviceDao.dispose();
    super.dispose();
  }

  /// 立即初始化方法
  Future<void> _initializeImmediately() async {
    if (_initializationCompleter != null) {
      return _initializationCompleter!.future;
    }

    _initializationCompleter = Completer<void>();

    try {
      print("[HomeServiceLogic] Starting immediate initialization...");

      // 【修改】添加WorkManager初始化
      await _initializeWorkManager();

      // 1. 先检查并请求权限，如果权限被拒绝则等待重试
      bool permissionsGranted = false;
      int permissionRetryCount = 0;
      const maxRetries = 3;

      while (!permissionsGranted && permissionRetryCount < maxRetries) {
        permissionsGranted = await _checkPermissions();

        if (!permissionsGranted) {
          permissionRetryCount++;
          print(
            "[HomeServiceLogic] Permissions not granted, retry $permissionRetryCount/$maxRetries",
          );

          if (permissionRetryCount < maxRetries) {
            // 等待一段时间后重试，给用户时间考虑
            await Future.delayed(const Duration(seconds: 2));
          }
        }
      }

      if (!permissionsGranted) {
        print(
          "[HomeServiceLogic] Permissions denied after $maxRetries attempts",
        );
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
        await startServices(); // 【修改】改为public方法
      }

      // 7. 启动状态同步定时器
      _startStateSyncTimer();

      print(
        "[HomeServiceLogic] Immediate initialization completed successfully",
      );
      _initializationCompleter!.complete();
    } catch (e) {
      print("[HomeServiceLogic] Immediate initialization failed: $e");
      _updateServiceState(ServiceState.error);
      _initializationCompleter!.completeError(e);
    }
  }

  /// 【新增】初始化WorkManager
  Future<void> _initializeWorkManager() async {
    try {
      // 初始化WorkManager
      await BleWorkManager.initialize();

      // 注册周期性任务
      await BleWorkManager.registerPeriodicTask();

      print("[HomeServiceLogic] WorkManager initialized and registered");
    } catch (e) {
      print("[HomeServiceLogic] Failed to initialize WorkManager: $e");
      // WorkManager初始化失败不应该阻止整个应用启动
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

        // 关键修改：即使服务在运行，也要确保Flutter层监听器正确设置
        await _ensureScanServiceListenerSetup();
      } else {
        _updateServiceState(ServiceState.stopped);
      }
    } catch (e) {
      print("[HomeServiceLogic] Error checking existing services: $e");
      _updateServiceState(ServiceState.error);
    }
  }

  /// 确保扫描服务监听器正确设置
  Future<void> _ensureScanServiceListenerSetup() async {
    try {
      print(
        "[HomeServiceLogic] Ensuring scan service listener is properly set up...",
      );

      // 获取必要数据
      final String secretKey = await _secureStorageService
          .getOrCreateSecretKey();
      final List<String> knownUserUUIDs = await getKnownUserUUIDs();

      // 重新设置扫描服务监听器，但不重启原生服务
      await _bluetoothScanService.refreshKnownUserUUIDs();

      // 强制重新设置监听器
      await _bluetoothScanService.forceSetupListener();

      print("[HomeServiceLogic] Scan service listener setup ensured");
    } catch (e) {
      print("[HomeServiceLogic] Error ensuring scan service listener: $e");
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
      await startServices(); // 【修改】改为public方法
      _restartAttempts = 0; // 重置计数器
    } catch (e) {
      print("[HomeServiceLogic] Restart failed: $e");
      // 延迟重试
      Future.delayed(Duration(seconds: _restartAttempts * 5), () {
        _restartServices();
      });
    }
  }

  /// 【修改】启动所有服务（包括WorkManager）- 改为public方法
  Future<void> startServices() async {
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

      // 【新增】存储服务参数到SharedPreferences供WorkManager使用
      await _storeServiceParameters(secretKey, knownUserUUIDs, userUuid);

      // 并行启动服务
      await Future.wait([
        _startBroadcastService(userUuid, secretKey),
        _startScanService(secretKey, knownUserUUIDs),
        _initializeWorkManager(), // 【新增】初始化WorkManager
      ]);

      _updateServiceState(ServiceState.running);
      print("[HomeServiceLogic] All services started successfully");
    } catch (e) {
      print("[HomeServiceLogic] Failed to start services: $e");
      _updateServiceState(ServiceState.error);
      throw e;
    }
  }

  /// 存储服务参数供WorkManager使用
  Future<void> _storeServiceParameters(
    String secretKey,
    List<String> knownUserUUIDs,
    String userUuid,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // 存储扫描服务参数
      await prefs.setString('stored_secret_key', secretKey);
      await prefs.setString('stored_user_uuids', jsonEncode(knownUserUUIDs));
      await prefs.setBool('has_secret_key', true);
      await prefs.setBool('has_user_uuids', true);
      await prefs.setBool('ble_service_should_run', true);

      // 存储广播服务参数
      await prefs.setString('stored_broadcast_user_uuid', userUuid);
      await prefs.setString('stored_broadcast_secret_key', secretKey);
      await prefs.setBool('has_broadcast_user_uuid', true);
      await prefs.setBool('has_broadcast_secret_key', true);
      await prefs.setBool('ble_broadcast_service_should_run', true);

      print("[HomeServiceLogic] Service parameters stored for WorkManager");
    } catch (e) {
      print("[HomeServiceLogic] Failed to store service parameters: $e");
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
    try {
      await _bluetoothScanService.startScanningService(
        secretKey: secretKey,
        knownUserUUIDs: knownUserUUIDs,
      );
      _scanServiceRunning = true;
      print("[HomeServiceLogic] Scan service started");

      // 添加：确保监听器设置完成
      await Future.delayed(const Duration(milliseconds: 500));
      print("[HomeServiceLogic] Scan service listener setup completed");
    } catch (e) {
      print("[HomeServiceLogic] Error starting scan service: $e");
      _scanServiceRunning = false;
      throw e;
    }
  }

  /// 停止所有服务（包括WorkManager）
  Future<void> stopServices() async {
    try {
      _updateServiceState(ServiceState.stopping);

      // 更新服务状态
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('ble_service_should_run', false);
      await prefs.setBool('ble_broadcast_service_should_run', false);

      // 并行停止服务
      await Future.wait([
        _stopBroadcastService(),
        _stopScanService(),
        _stopWorkManager(), //
      ]);

      _updateServiceState(ServiceState.stopped);
      print("[HomeServiceLogic] All services stopped successfully");
    } catch (e) {
      print("[HomeServiceLogic] Failed to stop services: $e");
      _updateServiceState(ServiceState.error);
      throw e;
    }
  }

  /// 停止广播服务
  Future<void> _stopBroadcastService() async {
    try {
      await _bleUuidBroadcaster.stopBroadcast();
      _broadcastServiceRunning = false;
      print("[HomeServiceLogic] Broadcast service stopped");
    } catch (e) {
      print("[HomeServiceLogic] Failed to stop broadcast service: $e");
    }
  }

  /// 停止扫描服务
  Future<void> _stopScanService() async {
    try {
      await _bluetoothScanService.stopScanningService();
      _scanServiceRunning = false;
      print("[HomeServiceLogic] Scan service stopped");
    } catch (e) {
      print("[HomeServiceLogic] Failed to stop scan service: $e");
    }
  }

  /// 停止WorkManager
  Future<void> _stopWorkManager() async {
    try {
      await BleWorkManager.cancelAllTasks();
      print("[HomeServiceLogic] WorkManager stopped");
    } catch (e) {
      print("[HomeServiceLogic] Failed to stop WorkManager: $e");
    }
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
  /// 检查权限的辅助方法（优化版本）
  Future<bool> _checkPermissions() async {
    try {
      // 先检查基础权限
      final List<Permission> basicPermissions = [
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
        Permission.notification,
        Permission.ignoreBatteryOptimizations, // 忽略电池优化
      ];

      // 请求基础权限
      final Map<Permission, PermissionStatus> basicStatuses =
          await basicPermissions.request();

      // 检查基础权限是否都授予
      final basicGranted = !basicStatuses.values.any(
        (status) =>
            status.isDenied ||
            status.isRestricted ||
            status.isPermanentlyDenied,
      );

      if (!basicGranted) {
        print("[HomeServiceLogic] Basic permissions not granted");
        return false;
      }

      // 基础权限授予后，再请求后台位置权限
      final backgroundLocationStatus = await Permission.locationAlways
          .request();

      if (backgroundLocationStatus.isGranted) {
        print(
          "[HomeServiceLogic] All permissions granted including background location",
        );
        return true;
      } else {
        print("[HomeServiceLogic] Background location permission denied");
        // 可以在这里显示说明对话框，解释为什么需要后台位置权限
        return false;
      }
    } catch (e) {
      print("[HomeServiceLogic] Error checking permissions: $e");
      return false;
    }
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
      await startServices(); // 【修改】改为public方法
    } catch (e) {
      print("[HomeServiceLogic] Failed to start service: $e");
      _updateServiceStatusDisplay(error: 'Start failed: $e');
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

  // 使用 Stream 直接从 DAO 获取实时统计数据
  Stream<int> get deviceCountStream {
    print("[HomeServiceLogic] deviceCountStream accessed");
    return _deviceDao.getDeviceCountStream();
  }

  Stream<int> get totalMinutesStream {
    print("[HomeServiceLogic] totalMinutesStream accessed");
    return _deviceDao.getTotalContactMinutesStream();
  }

  /// 【新增】设置开机自启动
  Future<void> setAutoStartEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('auto_start_enabled', enabled);

      print(
        "[HomeServiceLogic] Auto-start ${enabled ? 'enabled' : 'disabled'}",
      );
    } catch (e) {
      print("[HomeServiceLogic] Error setting auto-start: $e");
    }
  }

  /// 【新增】检查开机自启动状态
  Future<bool> isAutoStartEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('auto_start_enabled') ?? false;
    } catch (e) {
      print("[HomeServiceLogic] Error checking auto-start: $e");
      return false;
    }
  }
}
