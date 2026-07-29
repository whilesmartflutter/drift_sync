import 'package:drift_sync_core/src/exceptions/exceptions.dart';

/// Classification of a sync operation failure, used to route retry behavior.
enum FailureClass {
  /// Likely to succeed on retry (network blip, server overload).
  transient,

  /// Will never succeed unattended (e.g. a validation rejection); the item
  /// is quarantined and surfaced instead of retried.
  permanent,

  /// Unclassifiable; retried with a bounded budget, then escalated to
  /// [permanent].
  unknown,
}

typedef FailureClassifier = FailureClass Function(Object error);

/// Conservative default: only classifies what the core can prove; never
/// calls an error permanent. Transport-aware consumers should pass a richer
/// classifier (e.g. `restFailureClassifier`) to the synchronizer.
FailureClass defaultFailureClassifier(Object error) {
  if (error is UnavailableException) return FailureClass.transient;
  if (error is DependencyPendingException) return FailureClass.transient;
  if (error is UnmarshalException) return FailureClass.permanent;
  return FailureClass.unknown;
}
