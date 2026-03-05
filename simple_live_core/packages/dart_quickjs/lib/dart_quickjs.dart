class JsRuntime {
  JsRuntime({
    int? memoryLimit,
    int? maxStackSize,
  });

  String eval(String code) {
    throw UnsupportedError(
      'dart_quickjs is disabled in legacy Flutter toolchain build.',
    );
  }

  void dispose() {}
}
