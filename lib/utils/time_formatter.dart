class TimeFormatter {
  /// 将分钟转换为 "小时:分钟" 格式
  static String formatMinutesToHoursMinutes(int totalMinutes) {
    if (totalMinutes < 0) return "0:00";

    final hours = totalMinutes ~/ 60; // 整数除法获取小时
    final minutes = totalMinutes % 60; // 取余获取剩余分钟

    // 格式化：小时:分钟（分钟始终显示两位数）
    return "$hours:${minutes.toString().padLeft(2, '0')}";
  }
}
