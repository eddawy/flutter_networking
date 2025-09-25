class FeatureUnavailableException implements Exception {
  final String featureKey;
  final String message;

  FeatureUnavailableException(
      {required this.featureKey, required this.message});

  @override
  String toString() =>
      'FeatureUnavailableException: $message (feature: $featureKey)';
}
