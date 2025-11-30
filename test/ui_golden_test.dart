import 'dart:io';

import 'package:color_design_tool/main.dart';
import 'package:color_design_tool/services/persistence.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golden_toolkit/golden_toolkit.dart';
import 'package:path/path.dart' as p;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const cameraChannel = MethodChannel('color_camera');

  late Directory tempDir;
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    await loadAppFonts();
    tempDir = await Directory.systemTemp.createTemp('cdt_golden_test');

    String ensureDir(String name) {
      final dir = Directory(p.join(tempDir.path, name));
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      return dir.path;
    }

    messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
      switch (call.method) {
        case 'getTemporaryDirectory':
          return ensureDir('tmp');
        case 'getApplicationDocumentsDirectory':
          return ensureDir('app_docs');
        case 'getApplicationSupportDirectory':
          return ensureDir('app_support');
        case 'getLibraryDirectory':
          return ensureDir('library');
        case 'getExternalStorageDirectory':
          return ensureDir('external');
        case 'getExternalCacheDirectories':
          return <String>[ensureDir('external_cache')];
        case 'getExternalStorageDirectories':
          return <String>[ensureDir('external_storage')];
        case 'getDownloadsDirectory':
          return ensureDir('downloads');
        default:
          return ensureDir('fallback');
      }
    });

    messenger.setMockMethodCallHandler(cameraChannel, (call) async {
      switch (call.method) {
        case 'startCapture':
          final jpegPath = p.join(tempDir.path, 'mock_capture.jpg');
          final jpegFile = File(jpegPath);
          if (!jpegFile.existsSync()) {
            jpegFile.writeAsBytesSync(List<int>.filled(10, 0));
          }
          return {
            'jpegPath': jpegPath,
            'dngPath': p.join(tempDir.path, 'mock_capture.dng'),
            'rawBufferPath': p.join(tempDir.path, 'mock_capture.raw'),
            'metadata': const <String, dynamic>{},
          };
        case 'processRoi':
          return {
            'xyz': List<double>.filled(3, 0.5),
            'linearRgb': List<double>.filled(3, 0.5),
            'rawRgb': List<double>.filled(3, 0.5),
            'whiteBalanceGains': List<double>.filled(3, 1.0),
            'jpegSrgb': List<double>.filled(3, 0.6),
            'jpegLinearRgb': List<double>.filled(3, 0.6),
            'jpegXyz': List<double>.filled(3, 0.6),
            'camToXyzMatrix': List<double>.filled(9, 0.0),
            'xyzToCamMatrix': List<double>.filled(9, 0.0),
            'colorMatrixSource': 'mock',
            'rawRect': const {'left': 0, 'top': 0, 'right': 1, 'bottom': 1},
          };
        case 'setFixedBrightness':
          return null;
        default:
          return null;
      }
    });
  });

  tearDownAll(() async {
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    messenger.setMockMethodCallHandler(cameraChannel, null);
    await PaletteStorage.instance.dispose();
    await tempDir.delete(recursive: true);
  });

  testWidgets('Capture golden snapshots for main screens', (tester) async {
    binding.window.physicalSizeTestValue = const Size(1080, 1920);
    binding.window.devicePixelRatioTestValue = 1.0;
    addTearDown(() {
      binding.window.clearPhysicalSizeTestValue();
      binding.window.clearDevicePixelRatioTestValue();
    });

    await tester.pumpWidget(const CDTApp());
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/01_palette_screen.png'),
    );

    final colorwayButton = find.byIcon(Icons.palette_outlined);
    expect(colorwayButton, findsOneWidget);
    await tester.tap(colorwayButton);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/02_colorway_screen.png'),
    );
    await tester.pageBack();
    await tester.pumpAndSettle();

    final productButton = find.byIcon(Icons.design_services_outlined);
    expect(productButton, findsOneWidget);
    await tester.tap(productButton);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/03_product_design_screen.png'),
    );
    await tester.pageBack();
    await tester.pumpAndSettle();

    final cameraButton = find.byIcon(Icons.camera_alt_outlined);
    expect(cameraButton, findsOneWidget);
    await tester.tap(cameraButton);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/04_camera_screen.png'),
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
  });
}
