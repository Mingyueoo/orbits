import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:orbits_new/theme/app_theme.dart';

class QRScannerPage extends StatefulWidget {
  const QRScannerPage({super.key});

  @override
  State<QRScannerPage> createState() => _QRScannerPageState();
}

class _QRScannerPageState extends State<QRScannerPage> {
  late final MobileScannerController controller;
  // 添加一个标志位，防止重复处理扫描结果
  bool isScanned = false;

  @override
  void initState() {
    super.initState();
    controller = MobileScannerController(detectionSpeed: DetectionSpeed.normal);
  }

  @override
  void dispose() {
    // 确保 controller 被释放
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan QR Code'),
        backgroundColor: AppTheme.primaryColor,
      ),
      body: MobileScanner(
        controller: controller,
        onDetect: (capture) async {
          // 检查是否已经处理过扫描结果
          if (isScanned) {
            return;
          }

          final barcodes = capture.barcodes;
          if (barcodes.isNotEmpty) {
            // 设置标志位，防止后续帧再次触发
            isScanned = true;

            // 扫描到结果后，立即停止摄像头
            // 这能确保在页面卸载前，底层摄像头资源已经被正确释放
            await controller.stop();

            final scannedValue = barcodes.first.rawValue;
            if (scannedValue != null && scannedValue.isNotEmpty) {
              // 确保页面仍然挂载，然后返回结果
              if (mounted) {
                Navigator.of(context).pop(scannedValue);
              }
            }
          }
        },
        errorBuilder: (context, error) {
          // Fixed signature
          return Center(child: Text('Camera Error: ${error.toString()}'));
        },
      ),
    );
  }
}
