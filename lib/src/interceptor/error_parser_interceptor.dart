import 'package:dio/dio.dart';
import '../feature_unavailable_exception.dart';

/// Intercepts Dio errors to check for a specific 'feature_unavailable' error code
/// from the backend. If found, it wraps the error in a [FeatureUnavailableException]
/// and throws it, allowing UI-level interceptors to catch it.
class ErrorParserInterceptor extends Interceptor {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.response?.data is Map<String, dynamic>) {
      final data = err.response!.data as Map<String, dynamic>;

      if (data['error_code'] == 'feature_unavailable') {
        final featureKey = data['feature'] as String? ?? 'unknown';
        final message = data['message'] as String? ??
            'Feature is not available on your current plan.';

        // Throw a specific, typed exception that can be caught by another interceptor.
        final featureException = FeatureUnavailableException(
          featureKey: featureKey,
          message: message,
        );

        // Create a new error to pass down the chain.
        final newError = DioException(
          requestOptions: err.requestOptions,
          response: err.response,
          error: featureException, // Embed our custom exception here
          type: err.type,
        );

        return handler.reject(newError);
      }
    }

    super.onError(err, handler);
  }
}
