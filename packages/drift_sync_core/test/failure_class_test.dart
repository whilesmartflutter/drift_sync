import 'package:dio/dio.dart';
import 'package:drift_sync_core/drift_sync_core.dart';
import 'package:test/test.dart';

DioException _dio(int? statusCode, {DioExceptionType? type}) {
  final options = RequestOptions(path: '/x');
  return DioException(
    requestOptions: options,
    type: type ?? DioExceptionType.badResponse,
    response: statusCode == null
        ? null
        : Response(requestOptions: options, statusCode: statusCode),
  );
}

void main() {
  group('defaultFailureClassifier', () {
    test('UnavailableException is transient', () {
      expect(defaultFailureClassifier(const UnavailableException()),
          FailureClass.transient);
    });

    test('anything else is unknown, never permanent', () {
      expect(defaultFailureClassifier(Exception('boom')), FailureClass.unknown);
      expect(defaultFailureClassifier(_dio(422)), FailureClass.unknown);
    });
  });

  group('restFailureClassifier', () {
    test('server errors and throttling are transient', () {
      expect(restFailureClassifier(_dio(500)), FailureClass.transient);
      expect(restFailureClassifier(_dio(503)), FailureClass.transient);
      expect(restFailureClassifier(_dio(408)), FailureClass.transient);
      expect(restFailureClassifier(_dio(429)), FailureClass.transient);
    });

    test('connection-level failures are transient', () {
      expect(
          restFailureClassifier(
              _dio(null, type: DioExceptionType.connectionError)),
          FailureClass.transient);
      expect(restFailureClassifier(const UnavailableException()),
          FailureClass.transient);
    });

    test('other 4xx are permanent', () {
      expect(restFailureClassifier(_dio(422)), FailureClass.permanent);
      expect(restFailureClassifier(_dio(400)), FailureClass.permanent);
      expect(restFailureClassifier(_dio(404)), FailureClass.permanent);
      expect(restFailureClassifier(_dio(409)), FailureClass.permanent);
    });

    test('non-HTTP errors fall back to unknown', () {
      expect(restFailureClassifier(Exception('boom')), FailureClass.unknown);
    });
  });
}
