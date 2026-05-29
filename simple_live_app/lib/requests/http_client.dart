import 'package:dio/dio.dart';
import 'package:simple_live_app/requests/custom_log_interceptor.dart';
import 'package:simple_live_app/requests/http_error.dart';

class HttpClient {
  static HttpClient? _httpUtil;

  static HttpClient get instance {
    _httpUtil ??= HttpClient();
    return _httpUtil!;
  }

  late Dio dio;
  HttpClient() {
    dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(seconds: 20),
      ),
    );
    dio.interceptors.add(CustomLogInterceptor());
  }

  Future<String> getText(
    String url, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? header,
    CancelToken? cancel,
  }) async {
    try {
      queryParameters ??= {};
      header ??= {};
      var result = await dio.get(
        url,
        queryParameters: queryParameters,
        options: Options(responseType: ResponseType.plain, headers: header),
        cancelToken: cancel,
      );
      return result.data;
    } catch (e) {
      if (e is DioException) {
        throw _buildHttpError(e, '发送GET请求失败');
      }
      throw HttpError('发送GET请求失败');
    }
  }

  Future<dynamic> getJson(
    String url, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? header,
    CancelToken? cancel,
  }) async {
    try {
      queryParameters ??= {};
      header ??= {};
      var result = await dio.get(
        url,
        queryParameters: queryParameters,
        options: Options(responseType: ResponseType.json, headers: header),
        cancelToken: cancel,
      );
      return result.data;
    } catch (e) {
      if (e is DioException) {
        throw _buildHttpError(e, '发送GET请求失败');
      }
      throw HttpError('发送GET请求失败');
    }
  }

  Future<Response<dynamic>> get(
    String url, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? header,
    CancelToken? cancel,
  }) async {
    try {
      queryParameters ??= {};
      header ??= {};
      var result = await dio.get(
        url,
        queryParameters: queryParameters,
        options: Options(responseType: ResponseType.json, headers: header),
        cancelToken: cancel,
      );
      return result;
    } catch (e) {
      if (e is DioException) {
        throw _buildHttpError(e, '发送GET请求失败');
      }
      throw HttpError('发送GET请求失败');
    }
  }

  Future<dynamic> postJson(
    String url, {
    Map<String, dynamic>? queryParameters,
    dynamic data,
    Map<String, dynamic>? header,
    bool formUrlEncoded = false,
    CancelToken? cancel,
  }) async {
    try {
      queryParameters ??= {};
      header ??= {};
      data ??= {};
      var result = await dio.post(
        url,
        queryParameters: queryParameters,
        data: data,
        options: Options(
          responseType: ResponseType.json,
          headers: header,
          contentType:
              formUrlEncoded ? Headers.formUrlEncodedContentType : null,
        ),
        cancelToken: cancel,
      );
      return result.data;
    } catch (e) {
      if (e is DioException) {
        throw _buildHttpError(e, '发送POST请求失败');
      }
      throw HttpError('发送POST请求失败');
    }
  }

  Future<Response> head(
    String url, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? header,
    CancelToken? cancel,
  }) async {
    try {
      queryParameters ??= {};
      header ??= {};
      var result = await dio.head(
        url,
        queryParameters: queryParameters,
        options: Options(headers: header, receiveDataWhenStatusError: true),
        cancelToken: cancel,
      );
      return result;
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.badResponse) {
        return e.response!;
      }
      if (e is DioException) {
        throw _buildHttpError(e, '发送HEAD请求失败');
      }
      throw HttpError('发送HEAD请求失败');
    }
  }

  HttpError _buildHttpError(DioException e, String fallbackMessage) {
    final request = e.requestOptions;
    return HttpError(
      e.message ?? fallbackMessage,
      statusCode: e.response?.statusCode ?? 0,
      method: request.method,
      url: request.uri.toString(),
      queryParameters: Map<String, dynamic>.from(request.queryParameters),
      requestData: request.data,
      responseData: e.response?.data,
      headers: Map<String, dynamic>.from(request.headers),
    );
  }
}
