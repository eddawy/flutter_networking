import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:network/src/create_refresh_access_token_options.dart';
import 'package:network/src/interceptor/access_token_interceptor.dart';
import 'package:network/src/interceptor/logging_intercepter.dart';
import 'package:network/src/json_parser.dart';
import 'package:network/src/model/network_request.dart';
import 'package:network/src/model/network_response.dart';

import 'interceptor/header_interceptor.dart';
import 'logger.dart';
import 'model/network_error_type.dart';

typedef BaseUrlBuilder = Future<String> Function();
typedef OnHttpClientCreate = HttpClient Function();

/// Configuration for retry behavior
class RetryConfig {
  final int maxAttempts;
  final Duration initialDelay;
  final double backoffMultiplier;
  final Duration maxDelay;
  final Set<NetworkErrorType> retryableErrors;

  const RetryConfig({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(milliseconds: 500),
    this.backoffMultiplier = 2.0,
    this.maxDelay = const Duration(seconds: 5),
    this.retryableErrors = const {
      NetworkErrorType.badConnection,
      NetworkErrorType.server,
      NetworkErrorType.cancel,
    },
  });

  /// Default configuration for critical operations (authentication, user data)
  static const RetryConfig critical = RetryConfig(
    maxAttempts: 3,
    initialDelay: Duration(milliseconds: 300),
    backoffMultiplier: 1.5,
    maxDelay: Duration(seconds: 3),
  );

  /// Configuration for data fetching operations
  static const RetryConfig dataFetch = RetryConfig(
    maxAttempts: 2,
    initialDelay: Duration(milliseconds: 250),
    backoffMultiplier: 1.4,
    maxDelay: Duration(seconds: 2),
  );

  /// Configuration for interactive operations (follow, like, etc.)
  static const RetryConfig interactive = RetryConfig(
    maxAttempts: 2,
    initialDelay: Duration(milliseconds: 200),
    backoffMultiplier: 1.3,
    maxDelay: Duration(seconds: 1),
    retryableErrors: {
      NetworkErrorType.badConnection,
      NetworkErrorType.server,
    },
  );

  /// No retry configuration
  static const RetryConfig none = RetryConfig(
    maxAttempts: 1,
    initialDelay: Duration.zero,
    backoffMultiplier: 1.0,
    maxDelay: Duration.zero,
    retryableErrors: {},
  );

  /// Calculate delay for retry with exponential backoff
  Duration getDelay(int attemptNumber) {
    final delayMs = initialDelay.inMilliseconds *
        pow(backoffMultiplier, attemptNumber).round();
    return Duration(milliseconds: min(delayMs, maxDelay.inMilliseconds));
  }
}

class NetworkService {
  final JsonParser _jsonParser = JsonParser();

  final CreateRefreshAccessTokenOptions? createRefreshAccessTokenOptions;
  late Dio _dio;
  final BaseUrlBuilder baseUrlBuilder;
  final bool enableLogging;

  NetworkService({
    required this.baseUrlBuilder,
    this.createRefreshAccessTokenOptions,
    this.enableLogging = true,
    int connectTimeout = 8000,
    int sendTimeout = 8000,
    int receiveTimeout = 10000,
  }) {
    _dio = Dio();
    _dio.options.connectTimeout = Duration(milliseconds: connectTimeout);
    _dio.options.sendTimeout = Duration(milliseconds: sendTimeout);
    _dio.options.receiveTimeout = Duration(milliseconds: receiveTimeout);
    _initInterceptors();
  }

  void addInterceptor(Interceptor interceptor) {
    _dio.interceptors.add(interceptor);
  }

  void addHeaderInterceptor(HeaderInterceptor interceptor) {
    _dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      interceptor.onHeaderRequest(options);
      handler.next(options);
    }));
  }

  void onHttpClientCreate(OnHttpClientCreate onHttpClientCreate) {
    (_dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient =
        onHttpClientCreate;
  }

  void _initInterceptors() {
    if (enableLogging) {
      addInterceptor(LoggingInterceptor(logger: logger));
    }

    if (createRefreshAccessTokenOptions != null) {
      addInterceptor(AccessTokenInterceptor(
        dio: _dio,
        createAccessTokenOptions: createRefreshAccessTokenOptions!,
      ));
    }
  }

  Future<NetworkResponse<T>> request<T extends Object, K>({
    required NetworkRequest request,
    K Function(Map<String, dynamic>)? fromJson,
    bool? retryOnFailure,
    RetryConfig? retryConfig,
  }) async {
    // Determine if we should retry
    final shouldRetry = retryOnFailure ?? _shouldRetryByDefault(request);

    if (!shouldRetry) {
      return _performSingleRequest<T, K>(
        request: request,
        fromJson: fromJson,
      );
    }

    // Use retry logic
    final config = retryConfig ?? _getDefaultRetryConfig(request);
    return _performRequestWithRetry<T, K>(
      request: request,
      fromJson: fromJson,
      config: config,
    );
  }

  /// Performs a single network request without retry
  Future<NetworkResponse<T>> _performSingleRequest<T extends Object, K>({
    required NetworkRequest request,
    K Function(Map<String, dynamic>)? fromJson,
  }) async {
    _dio.options.baseUrl = await baseUrlBuilder();
    try {
      final response = await _request(request);

      final dataObject = _jsonParser.parse<T, K>(response.data, fromJson);

      if (fromJson == null && dataObject == null) {
        return NetworkResponse.success(
          jsonParser: _jsonParser,
          statusCode: response.statusCode,
          rawData: response.data,
          dataOnSuccess: null,
        );
      }

      if (dataObject != null) {
        return NetworkResponse.success(
          jsonParser: _jsonParser,
          statusCode: response.statusCode,
          rawData: response.data,
          dataOnSuccess: dataObject,
        );
      } else {
        return NetworkResponse.failure(
          jsonParser: _jsonParser,
          statusCode: response.statusCode,
          rawData: response.data,
          errorType: NetworkErrorType.parsing,
        );
      }
    } on DioException catch (dioException) {
      return NetworkResponse.failure(
        jsonParser: _jsonParser,
        statusCode: dioException.response?.statusCode,
        rawData: dioException.response?.data,
        errorType: _getErrorType(dioException),
      );
    } on Error catch (e) {
      logger.e(e);
      logger.e(e.stackTrace);
      return NetworkResponse.failure(
        jsonParser: _jsonParser,
        statusCode: null,
        rawData: null,
        errorType: NetworkErrorType.other,
      );
    }
  }

  /// Performs a network request with retry logic
  Future<NetworkResponse<T>> _performRequestWithRetry<T extends Object, K>({
    required NetworkRequest request,
    K Function(Map<String, dynamic>)? fromJson,
    required RetryConfig config,
  }) async {
    NetworkResponse<T>? lastResponse;
    NetworkErrorType? lastErrorType;

    for (int attempt = 1; attempt <= config.maxAttempts; attempt++) {
      try {
        lastResponse = await _performSingleRequest<T, K>(
          request: request,
          fromJson: fromJson,
        );

        // Check if the response was successful
        final isSuccessful = lastResponse.when(
          success: (data) => true,
          failure: (errorType) {
            lastErrorType = errorType;
            return false;
          },
        );

        if (isSuccessful) {
          return lastResponse;
        }

        // Check if this error type should be retried
        if (lastErrorType != null &&
            !config.retryableErrors.contains(lastErrorType)) {
          logger.d('Non-retryable error: $lastErrorType');
          return lastResponse; // Return immediately for non-retryable errors
        }

        // If not the last attempt, wait before retrying
        if (attempt < config.maxAttempts) {
          final delay = config.getDelay(attempt - 1);
          logger.d(
              'Request failed, retrying in ${delay.inMilliseconds}ms (attempt $attempt/${config.maxAttempts})');
          await Future.delayed(delay);
        }
      } catch (error) {
        logger.e('Request attempt $attempt failed: $error');
        if (attempt == config.maxAttempts) rethrow;

        // Wait before retrying
        final delay = config.getDelay(attempt - 1);
        await Future.delayed(delay);
      }
    }

    // Return the last response if all attempts failed
    return lastResponse!;
  }

  /// Determines if a request should retry by default based on HTTP method
  bool _shouldRetryByDefault(NetworkRequest request) {
    // Default retry behavior: true for GET requests, false for others
    final method = request.method.toUpperCase();
    return method == 'GET';
  }

  /// Get default retry configuration based on request type
  RetryConfig _getDefaultRetryConfig(NetworkRequest request) {
    final method = request.method.toUpperCase();
    switch (method) {
      case 'GET':
        return RetryConfig.dataFetch; // 2 attempts for GET requests
      case 'POST':
      case 'PUT':
      case 'PATCH':
        return RetryConfig.interactive; // 2 attempts for modification requests
      case 'DELETE':
        return RetryConfig.none; // No retries for DELETE requests
      default:
        return RetryConfig.dataFetch;
    }
  }

  Future<Response> _request(NetworkRequest request) {
    final options = Options(
      method: request.method,
      headers: request.headers,
    );

    return _dio.request(
      request.endpoint,
      data: request.body,
      queryParameters: request.queryParameters,
      options: options,
    );
  }

  NetworkErrorType _getErrorType(DioException dioException) {
    switch (dioException.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return NetworkErrorType.badConnection;

      case DioExceptionType.badResponse:
      case DioExceptionType.badCertificate:
        return _getErrorTypeWhenHaveResponse(dioException.response?.statusCode);

      case DioExceptionType.cancel:
        return NetworkErrorType.cancel;

      case DioExceptionType.unknown:
        if (dioException.error is SocketException) {
          return NetworkErrorType.badConnection;
        } else {
          return NetworkErrorType.other;
        }
    }
  }

  NetworkErrorType _getErrorTypeWhenHaveResponse(int? statusCode) {
    if (statusCode == null) {
      return NetworkErrorType.other;
    }

    if (statusCode == 401) {
      return NetworkErrorType.unauthorised;
    } else if (statusCode == 403) {
      return NetworkErrorType.forbidden;
    } else if (statusCode == 404) {
      return NetworkErrorType.noData;
    } else if (statusCode == 422) {
      return NetworkErrorType.unprocessable;
    } else if (statusCode >= 500) {
      return NetworkErrorType.server;
    }

    return NetworkErrorType.other;
  }
}
