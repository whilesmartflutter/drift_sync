/// Upload deferred because a dependency has not synced yet (e.g. a
/// transfer waiting for its legs' server ids). Transient by definition.
class DependencyPendingException implements Exception {
  DependencyPendingException(this.message);

  final String message;

  @override
  String toString() => 'Waiting for dependencies: $message';
}
