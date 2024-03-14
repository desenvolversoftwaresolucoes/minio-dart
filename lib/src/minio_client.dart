import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart';
import 'package:minio/minio.dart';
import 'package:minio/src/minio_helpers.dart';
import 'package:minio/src/minio_s3.dart';
import 'package:minio/src/minio_sign.dart';
import 'package:minio/src/utils.dart';

class MinioRequest extends BaseRequest {
  MinioRequest(String method, Uri url, {this.onProgress}) : super(method, url);

  dynamic body;

  final void Function(int)? onProgress;

  @override
  ByteStream finalize() {
    super.finalize();

    if (body == null) {
      return const ByteStream(Stream.empty());
    }

    late Stream<Uint8List> stream;

    if (body is Stream<Uint8List>) {
      stream = body;
    } else if (body is String) {
      final data = Utf8Encoder().convert(body);
      headers['content-length'] = data.length.toString();
      stream = Stream<Uint8List>.value(data);
    } else if (body is Uint8List) {
      stream = Stream<Uint8List>.value(body);
      headers['content-length'] = body.length.toString();
    } else {
      throw UnsupportedError('Unsupported body type: ${body.runtimeType}');
    }

    if (onProgress == null) {
      return ByteStream(stream);
    }

    var bytesRead = 0;

    stream = stream.transform(MaxChunkSize(1 << 16));

    return ByteStream(
      stream.transform(
        StreamTransformer.fromHandlers(
          handleData: (data, sink) {
            sink.add(data);
            bytesRead += data.length;
            onProgress!(bytesRead);
          },
        ),
      ),
    );
  }

  MinioRequest replace({
    String? method,
    Uri? url,
    Map<String, String>? headers,
    body,
  }) {
    final result = MinioRequest(method ?? this.method, url ?? this.url);
    result.body = body ?? this.body;
    result.headers.addAll(headers ?? this.headers);
    return result;
  }
}

/// An HTTP response where the entire response body is known in advance.
class MinioResponse extends BaseResponse {
  /// The bytes comprising the body of this response.
  final Uint8List bodyBytes;

  /// Body of s3 response is always encoded as UTF-8.
  String get body => utf8.decode(bodyBytes);

  /// Create a new HTTP response with a byte array body.
  MinioResponse.bytes(
    this.bodyBytes,
    int statusCode, {
    BaseRequest? request,
    Map<String, String> headers = const {},
    bool isRedirect = false,
    bool persistentConnection = true,
    String? reasonPhrase,
  }) : super(statusCode,
            contentLength: bodyBytes.length,
            request: request,
            headers: headers,
            isRedirect: isRedirect,
            persistentConnection: persistentConnection,
            reasonPhrase: reasonPhrase);

  static Future<MinioResponse> fromStream(StreamedResponse response) async {
    final body = await response.stream.toBytes();
    return MinioResponse.bytes(body, response.statusCode,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase);
  }
}

class MinioClient {
  MinioClient(this.minio) {
    anonymous = minio.accessKey.isEmpty && minio.secretKey.isEmpty;
    enableSHA256 = !anonymous && !minio.useSSL;
    port = minio.port;
  }

  final Minio minio;
  final String userAgent = 'MinIO (Unknown; Unknown) minio-dart/2.0.0';

  late bool enableSHA256;
  late bool anonymous;
  late final int port;

  Future<StreamedResponse> _request({
    required String method, // Método HTTP da requisição (GET, POST, etc.)
    String? bucket, // Nome do bucket do Amazon S3
    String? object, // Objeto do Amazon S3
    String? region, // Região do Amazon S3
    String? tag, // Tags do Amazon S3
    String? resource, // Recurso
    dynamic payload = '', // Corpo da requisição
    Map<String, dynamic>? queries, // Parâmetros da consulta
    Map<String, String>? headers, // Cabeçalhos da requisição
    void Function(int)? onProgress, // Função de callback de progresso
  }) async {
    // Verifica se o bucket foi fornecido e, se sim, tenta obter a região do bucket
    if (bucket != null) {
      region ??= await minio.getBucketRegion(bucket);
    }
    // Define a região padrão como 'us-east-1' se não foi fornecida
    region ??= 'us-east-1';

    // Cria uma requisição base com os parâmetros fornecidos
    final request = getBaseRequest(method, bucket, object, region, resource,
        queries, headers, onProgress, tag);
    // Define o corpo da requisição como o payload fornecido
    request.body = payload;

    // Gera a data atual em UTC
    final date = DateTime.now().toUtc();
    // Calcula o hash SHA256 do payload, se ativado, caso contrário, define como 'UNSIGNED-PAYLOAD'
    final sha256sum = enableSHA256 ? sha256Hex(payload) : 'UNSIGNED-PAYLOAD';
    // Obtém as tags do Amazon S3, se fornecidas

    // Adiciona os cabeçalhos necessários para autenticação da requisição
    request.headers.addAll({
      'user-agent': userAgent,
      'x-amz-date': makeDateLong(date),
      'x-amz-content-sha256': sha256sum,
    });

    // Adiciona o token de sessão aos cabeçalhos, se disponível
    if (minio.sessionToken != null) {
      request.headers['x-amz-security-token'] = minio.sessionToken!;
    }
    // Gera a autorização da requisição usando o método de autenticação AWS Signature Version 4
    final authorization = signV4(minio, request, date, region);
    // Adiciona o cabeçalho 'authorization' à requisição
    request.headers['authorization'] = authorization;

    // Registra a requisição
    logRequest(request);
    // Envia a requisição assíncrona e aguarda a resposta
    final response = await request.send();
    // Retorna a resposta da requisição
    return response;
  }

  Future<MinioResponse> request({
    required String method,
    String? bucket,
    String? object,
    String? region,
    String? resource,
    String? tag,
    dynamic payload = '',
    Map<String, dynamic>? queries,
    Map<String, String>? headers,
    void Function(int)? onProgress,
  }) async {
    final stream = await _request(
      method: method,
      bucket: bucket,
      object: object,
      region: region,
      payload: payload,
      tag: tag,
      resource: resource,
      queries: queries,
      headers: headers,
      onProgress: onProgress,
    );

    final response = await MinioResponse.fromStream(stream);
    logResponse(response);

    return response;
  }

  Future<StreamedResponse> requestStream({
    required String method,
    String? bucket,
    String? object,
    String? region,
    String? resource,
    dynamic payload = '',
    Map<String, dynamic>? queries,
    Map<String, String>? headers,
  }) async {
    final response = await _request(
      method: method,
      bucket: bucket,
      object: object,
      region: region,
      payload: payload,
      resource: resource,
      queries: queries,
      headers: headers,
    );

    logResponse(response);
    return response;
  }

  MinioRequest getBaseRequest(
      String method, // Método HTTP da requisição (GET, POST, etc.)
      String? bucket, // Nome do bucket do Amazon S3
      String? object, // Objeto do Amazon S3
      String region, // Região do Amazon S3
      String? resource, // Recurso
      Map<String, dynamic>? queries, // Parâmetros da consulta
      Map<String, String>? headers, // Cabeçalhos da requisição
      void Function(int)? onProgress, // Função de callback de progresso
      String? tag) {
    // Obtém a URL da requisição com base nos parâmetros fornecidos
    final url = getRequestUrl(bucket, object, resource, queries, tag);
    // Cria uma nova instância de MinioRequest com o método e a URL fornecidos
    final request = MinioRequest(method, url, onProgress: onProgress);
    // Define o cabeçalho 'host' como a autoridade da URL
    request.headers['host'] = url.authority;

    // Se cabeçalhos adicionais foram fornecidos, adiciona-os à requisição
    if (headers != null) {
      request.headers.addAll(headers);
    }

    // Retorna a instância de MinioRequest
    return request;
  }

  Uri getRequestUrl(
    String? bucket, // Nome do bucket do Amazon S3
    String? object, // Objeto do Amazon S3
    String? resource, // Recurso
    Map<String, dynamic>? queries, // Parâmetros da consulta
    String? tag, // Tags do Amazon S3
  ) {
    var host = minio.endPoint
        .toLowerCase(); // Obtém o endpoint do MinIO e converte para minúsculas
    var path = '/'; // Inicializa o caminho como '/'

    // Se o endpoint for da Amazon, substitui pelo endpoint do S3 correspondente à região do MinIO
    if (isAmazonEndpoint(host)) {
      host = getS3Endpoint(minio.region!);
    }

    // Verifica se o estilo de host é virtual e constrói a URL de acordo com isso
    if (isVirtualHostStyle(host, minio.useSSL, bucket)) {
      if (bucket != null) {
        host = '$bucket.$host'; // Adiciona o nome do bucket ao host
      }
      if (object != null) path = '/$object'; // Adiciona o objeto ao caminho
    } else {
      if (bucket != null) {
        path = '/$bucket'; // Adiciona o nome do bucket ao caminho
      }
      if (object != null) {
        path = '/$bucket/$object'; // Adiciona o objeto ao caminho
      }
    }

    // Constrói a string de consulta
    final query = StringBuffer();
    if (resource != null) {
      query.write(resource);
    }
    if (queries != null) {
      if (query.isNotEmpty) {
        query.write('&'); // Adiciona um '&' se já houver uma parte da consulta
      }
      query.write(encodeQueries(
          queries)); // Codifica os parâmetros da consulta e os adiciona
    }
    if (tag != null) {
      if (query.isNotEmpty) {
        query.write('&'); // Adiciona um '&' se já houver uma parte da consulta
      }
      query.write('tag=$tag'); // Adiciona a tag à consulta
    }

    // Retorna a URI construída com o esquema, host, porta, caminho e consulta
    return Uri(
      scheme:
          minio.useSSL ? 'https' : 'http', // Usa HTTPS se o SSL estiver ativado
      host: host,
      port: minio.port, // Usa a porta configurada no MinIO
      pathSegments: path.split('/'), // Divide o caminho em segmentos
      query: query.toString(), // Adiciona a string de consulta à URI
    );
  }

  void logRequest(MinioRequest request) {
    if (!minio.enableTrace) return;

    final buffer = StringBuffer();
    buffer.writeln('REQUEST: ${request.method} ${request.url}');
    for (var header in request.headers.entries) {
      buffer.writeln('${header.key}: ${header.value}');
    }

    if (request.body is List<int>) {
      buffer.writeln('List<int> of size ${request.body.length}');
    } else {
      buffer.writeln(request.body);
    }

    print(buffer.toString());
  }

  void logResponse(BaseResponse response) {
    if (!minio.enableTrace) return;

    final buffer = StringBuffer();
    buffer.writeln('RESPONSE: ${response.statusCode} ${response.reasonPhrase}');
    for (var header in response.headers.entries) {
      buffer.writeln('${header.key}: ${header.value}');
    }

    if (response is Response) {
      buffer.writeln(response.body);
    } else if (response is StreamedResponse) {
      buffer.writeln('STREAMED BODY');
    }

    print(buffer.toString());
  }
}
