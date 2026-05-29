import 'dart:convert';

class CoreError extends Error {
  final int statusCode;
  final String message;
  final String? method;
  final String? url;
  final Map<String, dynamic>? queryParameters;
  final dynamic requestData;
  final dynamic responseData;
  final Map<String, dynamic>? headers;

  CoreError(
    this.message, {
    this.statusCode = 0,
    this.method,
    this.url,
    this.queryParameters,
    this.requestData,
    this.responseData,
    this.headers,
  });

  String get summary {
    if (statusCode != 0) {
      return statusCodeToString(statusCode);
    }
    return message;
  }

  String get detail {
    final lines = <String>[summary, '', 'Exception: $message'];
    if (statusCode != 0) {
      lines.add('Status Code: $statusCode');
    }
    if (method != null) {
      lines.add('Method: $method');
    }
    if (url != null) {
      lines.add('URL: $url');
    }
    if (queryParameters != null) {
      lines.add('Query Parameters: ${_format(queryParameters)}');
    }
    if (requestData != null) {
      lines.add('Request Body: ${_format(requestData)}');
    }
    if (headers != null) {
      lines.add('Request Headers: ${_format(headers)}');
    }
    if (responseData != null) {
      lines.add('Response Body: ${_format(responseData)}');
    }
    return lines.join('\n');
  }

  @override
  String toString() {
    return detail;
  }

  String statusCodeToString(int statusCode) {
    switch (statusCode) {
      case 400:
        return '错误的请求(400)';
      case 401:
        return '无权限访问资源(401)';
      case 403:
        return '无权限访问资源(403)';
      case 404:
        return '服务器找不到请求的资源(404)';
      case 500:
        return '服务器出现错误(500)';
      case 502:
        return '服务器出现错误(502)';
      case 503:
        return '服务器出现错误(503)';
      default:
        return '连接服务器失败，请稍后再试($statusCode)';
    }
  }

  String _format(dynamic data) {
    try {
      return const JsonEncoder.withIndent('  ').convert(data);
    } catch (_) {
      return data.toString();
    }
  }
}
