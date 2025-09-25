enum NetworkErrorType {
  cancel,
  parsing,
  badRequest, //400
  unauthorised, //401
  forbidden, //403
  noData, //404
  unprocessable, //422
  featureUnavailable,
  badConnection,
  server, //500
  other,
}
