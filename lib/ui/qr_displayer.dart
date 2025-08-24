import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:orbits_new/theme/app_theme.dart';

// 这是用于显示我的二维码的页面。
// 它接收包含用户UUID和密钥的JSON字符串，并将其渲染为二维码。
class QrCodeDisplayPage extends StatelessWidget {
  final String qrData;
  final String userUuid;

  const QrCodeDisplayPage({
    super.key,
    required this.qrData,
    required this.userUuid,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My QR Code'),
        centerTitle: true,
        backgroundColor: AppTheme.primaryColor.withOpacity(0.9),
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 展示二维码的标题
              const Text(
                'Please scan this QR code',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.primaryColor,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              // QrImageView 小部件，用 RepaintBoundary 封装以便截图分享
              Container(
                width: 280,
                height: 280,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white, // 二维码背景必须是白色
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 10,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: QrImageView(
                  data: qrData,
                  version: QrVersions.auto,
                  size: 250,
                  backgroundColor: Colors.white,
                  errorStateBuilder: (cxt, err) {
                    return const Center(
                      child: Text(
                        'Failed to generate QR code...',
                        textAlign: TextAlign.center,
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 24),

              // 显示用户UUID
              Text(
                'My Device ID:\n$userUuid',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppTheme.primaryColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
