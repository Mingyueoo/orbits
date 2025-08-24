import 'package:flutter/material.dart';
import 'package:orbits_new/theme/app_theme.dart';

class InteractiveCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final Color color;

  const InteractiveCard({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 140,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: color,
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(0.2),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          children: [
            Icon(icon, size: 28, color: Colors.white),
            const SizedBox(height: 10),
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
