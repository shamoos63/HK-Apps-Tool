import 'package:flutter/material.dart';

import 'widgets/branded_app_bar.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: BrandedAppBar(title: const Text('About')),
      body: Align(
        alignment: Alignment.topLeft,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'HK Apps Tool',
                  style: t.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
              const SizedBox(height: 8),
              Text(
                'أداة صممت بحب ❤️ لتسهيل العمل على جميع الفنيين، لإدارة ملفات التثبيت الخاصة بتطبيقات الأندرويد وتحديثها \n'
                'مهداة إلى جميع أعضاء موقع حلب تك بشكل مجاني',
                style: t.bodyLarge?.copyWith(height: 1.45, color: Colors.black87),
              ),
              const SizedBox(height: 24),
              Text('Developer', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                'Coded and designed By Eng. Hisham Khateeb. You can check more of my works at my website https://hishamkhateeb.com',
                style: t.bodyMedium?.copyWith(height: 1.45),
              ),
              const SizedBox(height: 24),
              Text('Notes', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                '• Enable USB debugging on your Android device.\n'
                '• You can download the apps from the Tool itself or copying your pre-downloaded app into the folder of the library\n'
                '• You can manage pre-installed apps on the device.\n'
                '• You can update the apps in your library by clicking on Check for update button next to the app you want to update',
                style: t.bodyMedium?.copyWith(height: 1.5),
              ),
            ],
            ),
          ),
        ),
      ),
    );
  }
}
