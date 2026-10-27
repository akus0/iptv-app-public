// Local diagnostic client for a profile-mode TV APK's forwarded VM service.
// Pass the websocket URI on stdin and seconds/output JSON as arguments.
import 'dart:convert';
import 'dart:io';
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  final uri = stdin.readLineSync()!;
  final service = await vmServiceConnectUri(uri);
  try {
    final vm = await service.getVM();
    final isolate = vm.isolates!.firstWhere((i) => i.name == 'main');
    await service.setFlag('profiler', 'true');
    await service.clearCpuSamples(isolate.id!);
    // ignore: avoid_print
    print('CPU capture ready');
    await Future<void>.delayed(Duration(seconds: int.parse(args[0])));
    final samples = await service.getCpuSamples(isolate.id!, 0, 1 << 62);
    await File(args[1]).writeAsString(jsonEncode(samples.toJson()));
    // ignore: avoid_print
    print('CPU samples saved: ${samples.sampleCount}');
  } finally {
    await service.dispose();
  }
}
