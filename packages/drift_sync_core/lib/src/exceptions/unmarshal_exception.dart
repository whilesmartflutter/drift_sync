/// A queued payload failed to deserialize. The payload is immutable, so
/// this can never succeed on retry; classified permanent.
class UnmarshalException implements Exception {
  UnmarshalException(this.entityType, this.cause);

  final String entityType;
  final Object cause;

  @override
  String toString() => 'UnmarshalException($entityType): $cause';
}
