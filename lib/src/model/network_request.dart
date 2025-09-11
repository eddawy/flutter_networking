import 'package:dio/dio.dart';

class NetworkRequest {
  final String method;

  final String endpoint;
  final String endpointVersion;

  final Map<String, dynamic>? body;
  final FormData? formData;

  final Map<String, String> _queryParameters = {};
  final Map<String, String> _headers = {};

  NetworkRequest.get({
    required this.endpoint,
    this.endpointVersion = '',
    this.body,
    this.formData,
  }) : method = 'GET';

  NetworkRequest.patch({
    required this.endpoint,
    this.endpointVersion = '',
    this.body,
    this.formData,
  }) : method = 'PATCH';

  NetworkRequest.post({
    required this.endpoint,
    this.endpointVersion = '',
    this.body,
    this.formData,
  }) : method = 'POST';

  NetworkRequest.put({
    required this.endpoint,
    this.endpointVersion = '',
    this.body,
    this.formData,
  }) : method = 'PUT';

  NetworkRequest.options({
    required this.endpoint,
    this.endpointVersion = '',
    this.body,
    this.formData,
  }) : method = 'OPTIONS';

  NetworkRequest.delete({
    required this.endpoint,
    this.endpointVersion = '',
    this.body,
    this.formData,
  }) : method = 'DELETE';

  NetworkRequest({
    required this.method,
    required this.endpoint,
    this.endpointVersion = '',
    this.body,
    this.formData,
  });

  void addQueryParameter(String key, String value) {
    _queryParameters[key] = value;
  }

  void addHeader(String key, String value) {
    _headers[key] = value;
  }

  Map<String, dynamic> get queryParameters => _queryParameters;

  Map<String, String> get headers => _headers;

  /// Returns the data to be sent in the request body
  /// Prioritizes formData over body if both are provided
  dynamic get requestData => formData ?? body;
}
