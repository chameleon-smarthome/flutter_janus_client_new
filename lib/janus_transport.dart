part of janus_client;

abstract class JanusTransport {
  String? url;
  int? sessionId;

  JanusTransport({this.url});

  Future<dynamic> getInfo();

  /// this is called internally whenever [JanusSession] or [JanusPlugin] is disposed for cleaning up of active connections either polling or websocket connection.
  void dispose();
}

///
/// This transport class is provided to [JanusClient] instances in transport property in order to <br>
/// inform the plugin that we need to use Rest as a transport mechanism for communicating with Janus Server.<br>
/// therefore for events sent by Janus server is received with the help of polling.
class RestJanusTransport extends JanusTransport {
  RestJanusTransport({String? url}) : super(url: url);

  /*
  * method for posting data to janus by using http client
  * */
  Future<dynamic> post(body, {int? handleId}) async {
    var suffixUrl = '';
    if (sessionId != null && handleId == null) {
      suffixUrl = suffixUrl + "/$sessionId";
    } else if (sessionId != null && handleId != null) {
      suffixUrl = suffixUrl + "/$sessionId/$handleId";
    }
    try {
      var response = (await http.post(Uri.parse(url! + suffixUrl), body: stringify(body))).body;
      return parse(response);
    } on JsonCyclicError {
      return null;
    } on JsonUnsupportedObjectError {
      return null;
    } catch (e) {
      return null;
    }
  }

  /*
  * private method for get data to janus by using http client
  * */
  Future<dynamic> get({handleId}) async {
    var suffixUrl = '';
    if (sessionId != null && handleId == null) {
      suffixUrl = suffixUrl + "/$sessionId";
    } else if (sessionId != null && handleId != null) {
      suffixUrl = suffixUrl + "/$sessionId/$handleId";
    }
    return parse((await http.get(Uri.parse(url! + suffixUrl))).body);
  }

  @override
  void dispose() {}

  @override
  Future<dynamic> getInfo() async {
    return parse((await http.get(Uri.parse(url! + "/info"))).body);
  }
}

///
/// This transport class is provided to [JanusClient] instances in transport property in order to <br>
/// inform the plugin that we need to use WebSockets as a transport mechanism for communicating with Janus Server.<br>
/// sendCompleterTimeout is used to set timeout duration for each send request to Janus server resolving against transaction.
class WebSocketJanusTransport extends JanusTransport {
  WebSocketJanusTransport({String? url, this.sendCompleterTimeout = const Duration(seconds: 20)}) : super(url: url);
  WebSocketChannel? channel;

  /// Controls how long a transaction waits for a Janus response before timing out.
  Duration sendCompleterTimeout;
  WebSocketSink? sink;
  late Stream stream;
  bool isConnected = false;
  final Map<String, Completer<dynamic>> _pendingTransactions = {};

  void dispose() {
    if (channel != null && sink != null) {
      sink?.close();
      isConnected = false;
    }
  }

  /// this method is used to send json payload to Janus Server for communicating the intent.
  Future<dynamic> send(Map<String, dynamic> data, {int? handleId}) {
    final transaction = data['transaction'];

    if (transaction == null) {
      throw Exception("transaction key missing in body");
    }

    data['session_id'] = sessionId;
    if (handleId != null) {
      data['handle_id'] = handleId;
    }

    final completer = Completer<dynamic>();
    _pendingTransactions[transaction] = completer;

    sink!.add(stringify(data));

    return completer.future.timeout(this.sendCompleterTimeout, onTimeout: () {
      _pendingTransactions.remove(transaction);
      throw TimeoutException('Timed out waiting for transaction $transaction');
    });
  }

  @override
  Future<dynamic> getInfo() async {
    if (!isConnected) {
      connect();
    }
    Map<String, dynamic> payload = {};
    String transaction = getUuid().v4();
    payload['transaction'] = transaction;
    payload['janus'] = 'info';
    return send(payload);
  }

  /// this method is internally called by plugin to establish connection with provided websocket uri.
  void connect() {
    try {
      isConnected = true;
      channel = WebSocketChannel.connect(Uri.parse(url!), protocols: ['janus-protocol']);
    } catch (e) {
      print(e.toString());
      print('something went wrong');
      isConnected = false;
      dispose();
    }
    sink = channel!.sink;
    stream = channel!.stream.asBroadcastStream();
    stream.listen((event) {
      final msg = parse(event);
      final transaction = msg['transaction'];
      if (transaction != null && _pendingTransactions.containsKey(transaction)) {
        _pendingTransactions[transaction]!.complete(msg);
        _pendingTransactions.remove(transaction);
      }
    });
  }
}

class MqttJanusTransport extends JanusTransport {
  MqttJanusTransport({
    required String url,
    required this.publishTopic,
    required this.subscribeTopic,
    this.clientIdentifier,
  })  : assert(publishTopic.isNotEmpty, 'requestTopic is empty'),
        assert(subscribeTopic.isNotEmpty, 'responseTopic is empty'),
        assert(Uri.tryParse(url) != null, 'uri is invalid'),
        super(url: url);

  final String publishTopic, subscribeTopic;
  final String? clientIdentifier;

  bool get isConnected =>
      _client.connectionStatus?.state == MqttConnectionState.connected;

  StreamSubscription? _subs;

  late final StreamController<Map<String, dynamic>> sink = () {
    final controller = StreamController<Map<String, dynamic>>();

    _subs = controller.stream.where((_) => isConnected).listen((event) {
      try {
        final builder = MqttClientPayloadBuilder()
          ..addString(jsonEncode(event));

        _client.publishMessage(
          publishTopic,
          MqttQos.exactlyOnce,
          builder.payload!,
        );
      } catch (e) {
        print("MQTT publish error: $e");
      }
    });

    return controller;
  }();

  Stream<String> get stream =>
      _client.updates!
          .expand((e) => e)
          .where((m) => m.topic == subscribeTopic)
          .map((m) => m.payload)
          .cast<MqttPublishMessage>()
          .map((m) {
        try {
          return utf8.decode(m.payload.message);
        } catch (_) {
          return String.fromCharCodes(m.payload.message);
        }
      });

  late final MqttClient _client = () {
    final uri = Uri.parse(url!);

    final host = uri.scheme.startsWith('ws')
        ? '${uri.scheme}://${uri.host}'
        : uri.host;

    final id = clientIdentifier ??
        (uri.userInfo.isEmpty ? getUuid().v4() : uri.userInfo.split(':').first);

    final client = MqttPlatformClient(host, id)
      ..port = uri.hasPort ? uri.port : 1883
      ..setProtocolV311()
      ..autoReconnect = true
      ..keepAlivePeriod = 4000
      ..connectionMessage = MqttConnectMessage()
          .withClientIdentifier(id)
          .startClean()
      ..onConnected = (() => print('Mqtt Server Connected'))
      ..onDisconnected = (() => print('Mqtt Server Disconected'))
      ..websocketProtocols = MqttClientConstants.protocolsSingleDefault;

    return client;
  }();

  Future<void> connect() async {
    if (isConnected) return;

    try {
      final uri = Uri.parse(url!);
      final username = uri.userInfo.isEmpty ? null : uri.userInfo.split(':').first;
      final password = uri.userInfo.contains(':')
          ? uri.userInfo.split(':').last
          : null;

      final status = await _client.connect(username, password);

      if (status?.state != MqttConnectionState.connected) {
        throw Exception(
          "Not connected: ${status?.state.name}:${status?.returnCode?.name}",
        );
      }

      _client.subscribe(subscribeTopic, MqttQos.exactlyOnce);
    } catch (e) {
      print("MQTT connect error: $e");
      await dispose();
      rethrow;
    }
  }

  Future<dynamic> send(Map<String, dynamic> data, {int? handleId}) async {
    final transaction = data['transaction'];

    if (transaction == null || transaction is! String || transaction.isEmpty) {
      throw "transaction key missing in body";
    }

    if (sessionId != null) data['session_id'] = sessionId;
    if (handleId != null) data['handle_id'] = handleId;

    sink.add(data);

    try {
      final result = await stream
          .map(parse)
          .where((event) => event['transaction'] == transaction)
          .timeout(const Duration(seconds: 20))
          .first;

      return result;
    } catch (e) {
      throw "MQTT send timeout or error: $e";
    }
  }

  Future<void> dispose() async {
    try {
      await _subs?.cancel();
      await sink.close();
    } catch (_) {}

    try {
      _client.disconnect();
    } catch (_) {}
  }

  @override
  Future<dynamic> getInfo() async {
    if (!isConnected) await connect();

    final t = getUuid().v4();

    return send({
      "transaction": t,
      "janus": "info",
    });
  }
}

