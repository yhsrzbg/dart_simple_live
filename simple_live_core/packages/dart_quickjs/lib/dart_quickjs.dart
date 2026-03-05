import 'package:quickjs/quickjs.dart';

/// Minimal compatibility wrapper used by simple_live_core scripts.
class JsRuntime {
  late final NativeEngineManager _manager;
  late final NativeJsEngine _engine;

  JsRuntime({
    int? memoryLimit,
    int? maxStackSize,
  }) {
    _manager = NativeEngineManager();
    _engine = NativeJsEngine(name: 'simple_live_core');
  }

  String eval(String code) {
    final result = _engine.eval(code);
    if (result.stderr != null && result.stderr!.isNotEmpty) {
      throw Exception(result.stderr);
    }
    return result.value;
  }

  void dispose() {
    _engine.dispose();
    _manager.dispose();
  }
}
