part of janus_client;

class JanusStreamingPlugin extends JanusPlugin {
  JanusStreamingPlugin({handleId, context, transport, session})
      : super(context: context, handleId: handleId, plugin: JanusPlugins.STREAMING, session: session, transport: transport);

  /// Returns the list of all streaming mount points available on the server.
  Future<List<StreamingMountPoint>> listStreams() async {
    var payload = {"request": "list"};
    var response = await this.send(data: payload);
    if (response['janus'] == 'success' && response['plugindata'] != null && response['plugindata']['data'] != null && response['plugindata']['data']['list'] != null) {
      return (response['plugindata']['data']['list'] as List<dynamic>).map((e) => StreamingMountPoint.fromJson(e)).toList();
    }
    return [];
  }

  /// Retrieves detailed information for the mount point with [id].
  Future<StreamingMountPointInfo?> getStreamInfo(int id, {String? secret}) async {
    var payload = {"request": "info", "id": id, if (secret != null) "secret": secret};
    var response = await this.send(data: payload);
    if (response['info'] != null) {
      return StreamingMountPointInfo.fromJson(response['info']);
    }
    return null;
  }

  /// Creates a new streaming mount point on the Janus server.
  ///
  /// [type] must be one of `rtp`, `live`, `ondemand`, or `rtsp`:
  /// - `rtp`: External source pushes RTP (e.g. GStreamer, FFmpeg).
  /// - `live`: Local file streamed live to multiple viewers.
  /// - `ondemand`: Local file served on-demand per viewer.
  /// - `rtsp`: External RTSP feed (requires libcurl support).
  Future<StreamingMount?> createStream(String type,
      {String? name,
      String? description,
      String? metadata,
      dynamic id,
      String? pin,
      List<CreateMediaItem>? media,
      String? secret,
      bool? isPrivate,
      bool? permanent,
      String? adminKey}) async {
    var payload = {
      "request": "create",
      "type": type,
      if (adminKey != null) "admin_key": adminKey,
      if (id != null) "id": id,
      if (name != null) "name": name,
      if (description != null) "description": description,
      if (metadata != null) "metadata": metadata,
      if (secret != null) "secret": secret,
      if (pin != null) "pin": pin,
      if (isPrivate != null) "is_private": isPrivate,
      if (permanent != null) "permanent": permanent,
      if (media != null) "media": media,
    };
    var response = await this.send(data: payload);
    if (response['streaming'] == 'created') {
      return StreamingMount.fromJson(response);
    }
    return null;
  }

  /// Updates metadata or access control for an existing mount point.
  Future<StreamingMountEdited?> editStream(int id,
      {String? secret, String? description, String? metadata, String? newSecret, bool? newIsPrivate, bool? permanent, String? newPin}) async {
    var payload = {
      "request": "edit",
      "id": id,
      if (secret != null) "secret": secret,
      if (description != null) "new_description": description,
      if (metadata != null) "new_metadata": metadata,
      if (newSecret != null) "new_secret": newSecret,
      if (newPin != null) "new_pin": newPin,
      if (newIsPrivate != null) "new_is_private": newIsPrivate,
      if (permanent != null) "permanent": permanent
    };
    var response = await this.send(data: payload);
    if (response['streaming'] == 'edited') {
      return StreamingMountEdited.fromJson(response);
    }
    return null;
  }

  /// Destroys the specified mount point, optionally removing it from config when [permanent] is `true`.
  Future<bool> destroyStream(int id, {String? secret, bool? permanent}) async {
    var payload = {"request": "destroy", "id": id, if (secret != null) "secret": secret, if (permanent != null) "permanent": permanent};
    var response = await this.send(data: payload);
    if (response['streaming'] == 'destroyed') {
      return true;
    }
    return false;
  }

  /// Subscribes to the mount point identified by [id].
  ///
  /// Parameters:
  /// - [media]: Media items to request (overrides legacy boolean flags).
  /// - [pin]: Access pin when the mount point is protected.
  /// - [offerAudio]/[offerVideo]/[offerData]: Legacy flags preserved for compatibility.
  Future<void> watchStream(
    int id, {
    List<CreateMediaItem>? media,
    String? pin,
    @Deprecated('It is legacy option,you should use media for fine grade control') bool? offerAudio,
    @Deprecated('It is legacy option,you should use media for fine grade control') bool? offerVideo,
    @Deprecated('It is legacy option,you should use media for fine grade control') bool? offerData,
  }) async {
    var payload = {
      "request": "watch",
      "id": id,
      if (pin != null) "pin": pin,
      if (media != null) "media": media,
      if (offerAudio != null) "offer_audio": true,
      if (offerVideo != null) "offer_video": true,
      if (offerData != null) "offer_data": offerData
    };
    await this.send(data: payload);
  }

  /// Starts playback after a successful [watchStream] negotiation.
  Future<void> startStream() async {
    if (webRTCHandle?.peerConnection?.iceConnectionState == RTCIceConnectionState.RTCIceConnectionStateConnected) {
      await send(data: {"request": "start"});
    } else {
      RTCSessionDescription answer = await createAnswer();
      await send(data: {"request": "start"}, jsep: answer);
    }
  }

  /// Temporarily pauses media delivery while keeping the session alive.
  Future<void> pauseStream() async {
    await send(data: {"request": "pause"});
  }

  /// Stops the media flow and tears down the streaming session.
  Future<void> stopStream() async {
    await send(data: {"request": "stop"});
  }

  /// Switches the current subscription to another mount point.
  Future<void> switchStream(int id) async {
    await send(data: {"request": "switch", "id": id});
  }

  bool _onCreated = false;

  /// Registers typed event helpers for streaming-specific events.
  @override
  void onCreate() {
    super.onCreate();
    if (_onCreated) {
      return;
    }
    _onCreated = true;
    messages?.listen((event) {
      TypedEvent<JanusEvent> typedEvent = TypedEvent<JanusEvent>(event: JanusEvent.fromJson(event.event), jsep: event.jsep);
      var data = typedEvent.event.plugindata?.data;
      if (data == null) return;
      if (data["streaming"] == "event" && data["result"] != null && data["result"]['status'] == 'preparing') {
        typedEvent.event.plugindata?.data = StreamingPluginPreparingEvent();
        _typedMessagesSink?.add(typedEvent);
      } else if (data["streaming"] == "event" && data["result"] != null && data["result"]['status'] == 'stopping') {
        typedEvent.event.plugindata?.data = StreamingPluginStoppingEvent();
        _typedMessagesSink?.add(typedEvent);
      } else if (data['streaming'] == 'event' && (data['error_code'] != null || data['result']?['code'] != null)) {
        _typedMessagesSink?.addError(JanusError.fromMap(data));
      }
    });
  }
}
