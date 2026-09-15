import 'dart:io';
import 'package:args/args.dart';
import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:path/path.dart' as p;

/// Утилита сборки графа дорог из OSM PBF.
///
/// Использование:
///   dart run build_graph.dart \
///     --input extracts/russia_west.osm.pbf \
///     --graph-id russia_west \
///     --profile car \
///     --output ../output
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('input', abbr: 'i', help: 'Путь к .osm.pbf файлу', mandatory: true)
    ..addOption('graph-id', abbr: 'g', help: 'ID графа (например: russia_west)', mandatory: true)
    ..addOption('profile', abbr: 'p', help: 'Профиль: car / bicycle / motorcycle', defaultsTo: 'car')
    ..addOption('output', abbr: 'o', help: 'Директория для выходных файлов', defaultsTo: 'output')
    ..addFlag('compress', help: 'Сжимать граф (chain compression)', defaultsTo: true)
    ..addFlag('help', abbr: 'h', negatable: false);

  final results = parser.parse(args);

  if (results['help'] as bool) {
    print('Сборка графа дорог из OSM PBF\n');
    print('Использование: dart run build_graph.dart [опции]');
    print(parser.usage);
    exit(0);
  }

  final inputPath = results['input'] as String;
  final graphId = results['graph-id'] as String;
  final profileName = results['profile'] as String;
  final outputDir = results['output'] as String;
  final compress = results['compress'] as bool;

  // Проверяем входной файл
  final inputFile = File(inputPath);
  if (!await inputFile.exists()) {
    stderr.writeln('❌ Файл не найден: $inputPath');
    exit(1);
  }

  final inputSizeMB = (await inputFile.length()) / 1024 / 1024;
  print('═══════════════════════════════════════');
  print('🗺️  Сборка графа дорог');
  print('═══════════════════════════════════════');
  print('  Вход:    $inputPath (${inputSizeMB.toStringAsFixed(1)} МБ)');
  print('  ID:      $graphId');
  print('  Профиль: $profileName');
  print('  Сжатие:  ${compress ? "включено" : "выключено"}');
  print('  Выход:   $outputDir/');
  print('═══════════════════════════════════════\n');

  // Создаём выходную директорию
  final outDir = Directory(outputDir);
  if (!await outDir.exists()) {
    await outDir.create(recursive: true);
  }

  // Выбираем профиль
  final profile = switch (profileName) {
    'bicycle' => VehicleProfile.bicycle,
    'motorcycle' => VehicleProfile.motorcycle,
    _ => VehicleProfile.car,
  };

  final sw = Stopwatch()..start();

  try {
    // 1. Парсим OSM PBF → GeoGraph
    print('📖 Шаг 1/4: Парсинг OSM PBF...');
    final converter = OsmConverter(
      profile: profile,
      compress: compress,
    );
    final geoGraph = await converter.toGeoGraph(inputPath);
    print('   ✅ Узлов: ${geoGraph.nodeCount}, рёбер: ${geoGraph.edgeCount}');

    // 2. Компилируем → RoutingGraph (CSR)
    print('🔨 Шаг 2/4: Компиляция в CSR-граф...');
    final compiled = await converter.compile(inputPath);
    final graph = compiled.graph;
    print('   ✅ После сжатия: ${graph.nodeCount} узлов, ${graph.edgeCount} рёбер');
    if (converter.compressor.lastStats != null) {
      final stats = converter.compressor.lastStats!;
      print('   📊 Сжатие: ${stats.nodeReduction * 100}% узлов, '
          '${stats.edgeReduction * 100}% рёбер');
    }

    // 3. Сохраняем в файлы
    print('💾 Шаг 3/4: Сохранение файлов...');
    final storage = LocalFileStorage(directory: outputDir);

    // Записываем .graph, .index, .meta
    await storage.saveGraph(graphId, geoGraph, profile: profile);

    // Также сохраняем скомпилированный граф напрямую
    if (storage is CompiledGraphStorage) {
      await storage.saveCompiled(graphId, compiled, profile: profile);
    }

    // 4. Проверяем результат
    print('🔍 Шаг 4/4: Проверка файлов...');
    final filePrefix = '${graphId}_$profileName'; // 🆕 Учитываем суффикс профиля
    for (final ext in ['.graph', '.index', '.meta']) {
      final f = File(p.join(outputDir, '$filePrefix$ext'));
      if (await f.exists()) {
        final sizeMB = (await f.length()) / 1024 / 1024;
        print('   ✅ $filePrefix$ext — ${sizeMB.toStringAsFixed(2)} МБ');
      } else {
        print('   ⚠️  $filePrefix$ext — не создан');
      }
    }

    sw.stop();
    print('\n═══════════════════════════════════════');
    print('🎉 Готово за ${sw.elapsed.inSeconds} сек!');
    print('   Граф: $graphId ($profileName)');
    print('   Размер: ${graph.nodeCount} узлов, ${graph.edgeCount} рёбер');
    print('═══════════════════════════════════════');
  } catch (e, st) {
    sw.stop();
    stderr.writeln('\n❌ Ошибка сборки графа: $e');
    stderr.writeln('Время работы: ${sw.elapsed.inSeconds} сек');
    stderr.writeln(st);
    exit(1);
  }
}
