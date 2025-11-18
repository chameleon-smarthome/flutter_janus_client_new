part of janus_client;

abstract class JanusPlugins {
  static const VIDEO_ROOM = "janus.plugin.videoroom";
  static const AUDIO_BRIDGE = "janus.plugin.audiobridge";
  static const STREAMING = "janus.plugin.streaming";
  static const VIDEO_CALL = "janus.plugin.videocall";
  static const TEXT_ROOM = "janus.plugin.textroom";
  static const ECHO_TEST = "janus.plugin.echotest";
  static const SIP = "janus.plugin.sip";
}

class JanusPlugin {
  void onCreate() {}
  int? handleId;
  late JanusClient _context;
  late JanusTransport? _transport;
  late JanusSession? _session;
  String? plugin;
  bool _initialized = false;

  // internal method which takes care of type of roomId which is normally int but can be string if set in janus config for room
  _handleRoomIdTypeDifference(dynamic payload) {
    if (payload["room"] != null) {
      payload["room"] = _context._stringIds == false ? payload["room"] : payload["room"].toString();
    }
  }

  late Stream<dynamic> _events;
  Stream<EventMessage>? messages;
  Stream<TypedEvent<JanusEvent>>? typedMessages;
  Stream<RTCDataChannelMessage>? data;
  Stream<RTCDataChannelState>? onData;
  Stream<RemoteTrack>? remoteTrack;
  Stream<dynamic>? renegotiationNeeded;
  Stream<MediaStream>? remoteStream;
  Stream<MediaStream?>? localStream;
  StreamController<dynamic>? _renegotiationNeededController;
  StreamController<MediaStream?>? _localStreamController;
  StreamController<RemoteTrack>? _remoteTrackStreamController;
  StreamController<MediaStream>? _remoteStreamController;
  StreamController<dynamic>? _streamController;
  StreamController<EventMessage>? _messagesStreamController;
  StreamController<TypedEvent>? _typedMessagesStreamController;
  StreamController<RTCDataChannelMessage>? _dataStreamController;
  StreamController<RTCDataChannelState>? _onDataStreamController;

  StreamSink? get _typedMessagesSink => _typedMessagesStreamController?.sink;

  int _pollingRetries = 0;
  Timer? _pollingTimer;
  JanusWebRTCHandle? webRTCHandle;
  Map<String, dynamic>? _webRtcConfiguration;

  //temporary variables
  StreamSubscription? _wsStreamSubscription;
  late bool pollingActive;

  // Bitrate calculation variables - separate history per mid
  Map<String, int> _lastBytesReceivedMap = {};
  Map<String, int> _lastTimestampMap = {};

  RTCPeerConnection? get peerConnection {
    return webRTCHandle?.peerConnection;
  }

  JanusPlugin({this.handleId, required JanusClient context, required JanusTransport transport, required JanusSession session, this.plugin}) {
    _context = context;
    _session = session;
    _transport = transport;
  }

  /// Initializes or re-initializes the internal WebRTC stack for this plugin.
  ///
  /// The method expects `_webRtcConfiguration` to be populated via [_init] and
  /// creates a fresh `RTCPeerConnection`, wiring renegotiation, track, and ICE
  /// callbacks before storing the resulting [JanusWebRTCHandle].
  Future<void> initializeWebRTCStack() async {
    if (_webRtcConfiguration == null) {
      _context._logger.shout('initializeWebRTCStack:-configuration is null call init before calling me');
      return;
    }
    _context._logger.finest('webRTC stack intialized');
    RTCPeerConnection peerConnection = await createPeerConnection(_webRtcConfiguration!, {});
    peerConnection.onRenegotiationNeeded = () {
      _renegotiationNeededController?.sink.add(true);
    };
    //unified plan webrtc tracks emitter
    _handleUnifiedWebRTCTracksEmitter(peerConnection);
    //send ice candidates to janus server on this specific handle
    _handleIceCandidatesSending(peerConnection);
    webRTCHandle = JanusWebRTCHandle(peerConnection: peerConnection);
  }

  /// Internal helper invoked by [JanusSession.attach] to finish plugin setup.
  ///
  /// The method configures the peer connection, prepares event streams, and
  /// activates transport-specific listeners. External code should rely on
  /// [JanusSession.attach] instead of calling this directly.
  Future<void> _init() async {
    if (!_initialized) {
      _initialized = true;
      _context._logger.info("Plugin Initialized");
      if (webRTCHandle != null) {
        return;
      }
      // initializing WebRTC Handle
      _webRtcConfiguration = {"iceServers": _context._iceServers != null ? _context._iceServers!.map((e) => e.toMap()).toList() : []};
      if (_context._isUnifiedPlan && !_context._usePlanB) {
        _webRtcConfiguration?.putIfAbsent('sdpSemantics', () => 'unified-plan');
      } else {
        _webRtcConfiguration?.putIfAbsent('sdpSemantics', () => 'plan-b');
      }
      _context._logger.fine('peer connection configuration');
      _context._logger.fine(_webRtcConfiguration);
      await initializeWebRTCStack();
      //initialize stream controllers and streams
      _initStreamControllersAndStreams();
      //add Event emitter logic
      _handleEventMessageEmitter();
      this.pollingActive = true;
      // Warning no code should be placed after code below in init function
      // depending on transport setup events and messages for session and plugin
      _handleTransportInitialization();
    } else {
      _context._logger.info("Plugin already Initialized! skipping");
    }
  }

  /// Binds listeners according to the selected transport (REST polling or WS).
  void _handleTransportInitialization() {
    if (_transport is RestJanusTransport) {
      _pollingTimer = Timer.periodic(_context._pollingInterval, (timer) async {
        if (!pollingActive) {
          timer.cancel();
        }
        await _handlePolling();
      });
    } else if (_transport is WebSocketJanusTransport) {
      _wsStreamSubscription = (_transport as WebSocketJanusTransport).stream.listen((event) {
        _streamController!.add(parse(event));
      });
    } else if (_transport is MqttJanusTransport) {
      _wsStreamSubscription = (_transport as MqttJanusTransport).stream.listen((event) {
        _streamController!.add(parse(event));
      });
    }
  }

  /// Sets up the broadcast stream controllers used throughout the plugin.
  void _initStreamControllersAndStreams() {
    //source and stream for session level events
    _streamController = StreamController<dynamic>();
    _events = _streamController!.stream.asBroadcastStream();
    //source and stream for localStream
    _localStreamController = StreamController<MediaStream?>();
    localStream = _localStreamController!.stream.asBroadcastStream();
    //source and stream for plugin level events
    _messagesStreamController = StreamController<EventMessage>();
    messages = _messagesStreamController!.stream.asBroadcastStream();

    //typed source and stream for plugin level events
    _typedMessagesStreamController = StreamController<TypedEvent<JanusEvent>>();
    typedMessages = _typedMessagesStreamController!.stream.asBroadcastStream() as Stream<TypedEvent<JanusEvent>>?;

    // remote track for unified plan support
    _remoteTrackStreamController = StreamController<RemoteTrack>();
    remoteTrack = _remoteTrackStreamController!.stream.asBroadcastStream();
    // remote MediaStream plan-b
    _remoteStreamController = StreamController<MediaStream>();
    remoteStream = _remoteStreamController!.stream.asBroadcastStream();

    // data channel stream contoller
    _dataStreamController = StreamController<RTCDataChannelMessage>();
    data = _dataStreamController!.stream.asBroadcastStream();

    // data channel state stream contoller
    _onDataStreamController = StreamController<RTCDataChannelState>();
    onData = _onDataStreamController!.stream.asBroadcastStream();
    // data channel state stream contoller
    _renegotiationNeededController = StreamController<void>();
    renegotiationNeeded = _renegotiationNeededController!.stream.asBroadcastStream();
  }

  /// Registers handlers that translate WebRTC track events to Janus streams.
  void _handleUnifiedWebRTCTracksEmitter(RTCPeerConnection peerConnection) {
    if (_context._isUnifiedPlan && !_context._usePlanB) {
      peerConnection.onTrack = (RTCTrackEvent event) async {
        _context._logger.finest('onTrack called with event');
        _context._logger.fine(event.toString());
        if (event.streams.isEmpty) return;
        // Notify about the new track event

        var mid =
            event.transceiver != null
                ? event.transceiver?.mid
                : event.receiver != null
                ? event.receiver?.track?.id
                : event.track.id;
        _remoteTrackStreamController?.add(RemoteTrack(track: event.track, mid: mid, flowing: true));
        event.track.onEnded = () async {
          // Notify the application
          if (!_remoteTrackStreamController!.isClosed) _remoteTrackStreamController?.add(RemoteTrack(track: event.track, mid: mid, flowing: false));
        };
        event.track.onMute = () async {
          if (!_remoteTrackStreamController!.isClosed) _remoteTrackStreamController?.add(RemoteTrack(track: event.track, mid: mid, flowing: false));
        };
        event.track.onUnMute = () async {
          if (!_remoteTrackStreamController!.isClosed) _remoteTrackStreamController?.add(RemoteTrack(track: event.track, mid: mid, flowing: true));
        };
      };
    }
    // source for onRemoteStream
    peerConnection.onAddStream = (mediaStream) {
      _remoteStreamController!.sink.add(mediaStream);
    };
  }

  /// Sends gathered ICE candidates to the Janus backend for this handle.
  void _handleIceCandidatesSending(RTCPeerConnection peerConnection) {
    // get ice candidates and send to janus on this plugin handle
    peerConnection.onIceCandidate = (RTCIceCandidate candidate) async {
      Map<String, dynamic>? response;
      if (!plugin!.contains('textroom')) {
        this._context._logger.finest('sending trickle');
        Map<String, dynamic> request = {"janus": "trickle", "candidate": candidate.toMap(), "transaction": getUuid().v4(), ..._context._apiMap, ..._context._tokenMap};
        request["session_id"] = _session!.sessionId;
        request["handle_id"] = handleId;
        //checking and posting using websocket if in available
        if (_transport is RestJanusTransport) {
          RestJanusTransport rest = (_transport as RestJanusTransport);
          response = (await rest.post(request, handleId: handleId)) as Map<String, dynamic>;
        } else if (_transport is WebSocketJanusTransport) {
          WebSocketJanusTransport ws = (_transport as WebSocketJanusTransport);
          response = (await ws.send(request, handleId: handleId)) as Map<String, dynamic>;
        } else if (_transport is MqttJanusTransport) {
          final mqtt = _transport as MqttJanusTransport;
          response = (await mqtt.send(request, handleId: handleId)) as Map<String, dynamic>;
        }
        _streamController!.sink.add(response);
      }
    };
  }

  /// Filters session-level events and emits those that match this handle.
  void _handleEventMessageEmitter() {
    //filter and only send events for current handleId
    _events.where((event) {
      Map<String, dynamic> result = event;
      if (result.containsKey('sender')) {
        if ((result['sender'] as int?) == handleId) return true;
        return false;
      } else {
        return false;
      }
    }).listen((event) {
      var jsep = event['jsep'];
      if (jsep != null) {
        _messagesStreamController!.sink.add(EventMessage(event: event, jsep: RTCSessionDescription(jsep['sdp'], jsep['type'])));
      } else {
        _addTrickleCandidate(event);
        _messagesStreamController!.sink.add(EventMessage(event: event, jsep: null));
      }
    });
  }

  /// Applies a single trickle candidate to the active peer connection.
  void _addTrickleCandidate(event) {
    final isTrickleEvent = event['janus'] == 'trickle';
    if (isTrickleEvent) {
      final candidateMap = event['candidate'];
      RTCIceCandidate candidate = RTCIceCandidate(candidateMap['candidate'], candidateMap['sdpMid'], candidateMap['sdpMLineIndex']);
      webRTCHandle!.peerConnection!.addCandidate(candidate);
    }
  }

  /// Pulls pending Janus events when REST polling is active.
  _handlePolling() async {
    if (!pollingActive) return;
    if (_session!.sessionId == null) {
      pollingActive = false;
      return;
    }
    try {
      Map<String, String> queryParameters = {};
      queryParameters["rid"] = new DateTime.now().millisecondsSinceEpoch.toString();
      if (_context._maxEvent != null) {
        queryParameters["maxev"] = _context._maxEvent.toString();
      }
      if (_context._token != null) {
        queryParameters["token"] = _context._token!;
      }
      if (_context._apiSecret != null) {
        queryParameters["apisecret"] = _context._apiSecret!;
      }
      var response = (await http.get(Uri.https(extractDomainFromUrl(_transport!.url!), "janus/" + _session!.sessionId.toString(), queryParameters)));
      if (response.statusCode != 200 || response.body.isEmpty) {
        var errorMessage = "polling is failed from janus with error code : ${response.statusCode} , header : ${response.headers}";
        print(response.body);
        print(response.statusCode);
        print(errorMessage);
        _context._logger.severe(errorMessage);
        throw errorMessage;
      }
      var decodedResponse = parse(response.body);
      List<dynamic> json = ((decodedResponse != null && decodedResponse.isNotEmpty)) ? decodedResponse : [];
      json.forEach((element) {
        if (!_streamController!.isClosed) {
          _streamController!.add(element);
        } else {
          pollingActive = false;
          return;
        }
      });
      _pollingRetries = 0;
      return;
    } on HttpException catch (_) {
      _pollingRetries++;
      pollingActive = false;
      if (_pollingRetries > 2) {
        // Did we just lose the server? :-(
        _context._logger.severe("Lost connection to the server (is it down?)");
        return;
      }
    } catch (e) {
      this._context._logger.fine(e);
      pollingActive = false;
      _context._logger.severe("fatal Exception");
      return;
    }
    return;
  }

  /// Checks whether a Janus room identified by [roomId] exists.
  Future<dynamic> exists(int roomId) async {
    var payload = {"request": "exists", "room": roomId};
    return (await this.send(data: payload));
  }

  /// Cancels the REST polling timer if it is currently running.
  void _cancelPollingTimer() {
    if (_pollingTimer != null) {
      _pollingTimer!.cancel();
    }
  }

  /// Disposes the active local stream and, unless [ignoreRemote] is `true`, the
  /// remote stream as well. Optional [video] and [audio] flags allow selectively
  /// stopping tracks before disposing their parent streams.
  Future<void> _disposeMediaStreams({ignoreRemote = false, video = true, audio = true}) async {
    _context._logger.finest('disposing localStream and remoteStream if it already exists');
    if (webRTCHandle?.localStream != null) {
      if (audio) {
        webRTCHandle?.localStream?.getAudioTracks().forEach((element) async {
          _context._logger.finest('stoping localStream => audio track ${element.toString()}');
          await element.stop();
        });
      }
      if (video) {
        webRTCHandle?.localStream?.getVideoTracks().forEach((element) async {
          _context._logger.finest('stoping localStream => video track ${element.toString()}');
          await element.stop();
        });
      }
      if (audio || video) {
        try {
          _context._logger.finest('disposing webRTCHandle?.localStream');
          await webRTCHandle?.localStream?.dispose();
        } catch (e) {
          _context._logger.severe('failed to dispose webRTCHandle?.localStream with error $e');
        }
      }
      webRTCHandle?.localStream = null;
    }
    if (webRTCHandle?.remoteStream != null && !ignoreRemote) {
      webRTCHandle?.remoteStream?.getTracks().forEach((element) async {
        _context._logger.finest('stoping remoteStream => ${element.toString()}');
        await element.stop();
      });
      try {
        _context._logger.finest('disposing webRTCHandle?.remoteStream');
        await webRTCHandle?.remoteStream?.dispose();
      } catch (e) {
        _context._logger.severe('failed to dispose webRTCHandle?.remoteStream with error $e');
      }
      webRTCHandle?.remoteStream = null;
    }
  }

  /// Stops polling and disposes media resources without fully disposing the handle.
  Future<void> hangup() async {
    _cancelPollingTimer();
    await _disposeMediaStreams();
  }

  /// Disposes timers, stream controllers, transports, and media tied to this plugin.
  Future<void> dispose() async {
    this.pollingActive = false;
    _pollingTimer?.cancel();
    _streamController?.close();
    _remoteStreamController?.close();
    _messagesStreamController?.close();
    _typedMessagesStreamController?.close();
    _localStreamController?.close();
    _remoteTrackStreamController?.close();
    _dataStreamController?.close();
    _onDataStreamController?.close();
    _renegotiationNeededController?.close();
    _wsStreamSubscription?.cancel();
    await stopAllTracks(webRTCHandle?.localStream);
    (await webRTCHandle?.peerConnection?.getTransceivers())?.forEach((element) async {
      await element.stop();
    });
    await webRTCHandle?.peerConnection?.close();
    await webRTCHandle?.remoteStream?.dispose();
    await webRTCHandle?.localStream?.dispose();
    await webRTCHandle?.peerConnection?.dispose();
    webRTCHandle?.localStream = null;
    webRTCHandle?.remoteStream = null;
    webRTCHandle?.peerConnection = null;
  }

  /// Creates the default data channel when missing for TextRoom/data usage.
  Future<void> initDataChannel({RTCDataChannelInit? rtcDataChannelInit}) async {
    if (webRTCHandle!.peerConnection != null) {
      if (webRTCHandle!.dataChannel[_context._dataChannelDefaultLabel] != null) return;
      if (rtcDataChannelInit == null) {
        rtcDataChannelInit = RTCDataChannelInit();
        rtcDataChannelInit.ordered = true;
        rtcDataChannelInit.protocol = 'janus-protocol';
      }
      webRTCHandle!.dataChannel[_context._dataChannelDefaultLabel] = await webRTCHandle!.peerConnection!.createDataChannel(_context._dataChannelDefaultLabel, rtcDataChannelInit);
      if (webRTCHandle!.dataChannel[_context._dataChannelDefaultLabel] != null) {
        webRTCHandle!.dataChannel[_context._dataChannelDefaultLabel]!.onDataChannelState = (state) {
          if (!_onDataStreamController!.isClosed) {
            _onDataStreamController!.sink.add(state);
          }
        };
        webRTCHandle!.dataChannel[_context._dataChannelDefaultLabel]!.onMessage = (RTCDataChannelMessage message) {
          if (!_dataStreamController!.isClosed) {
            _dataStreamController!.sink.add(message);
          }
        };
      }
    } else {
      throw Exception("You Must Initialize Peer Connection before even attempting data channel creation!");
    }
  }

  /// Sends a Janus `message` with optional SDP negotiation data.
  Future<dynamic> send({dynamic data, RTCSessionDescription? jsep}) async {
    try {
      String transaction = getUuid().v4();
      Map<String, dynamic>? response;
      Map<String, dynamic> request = {"janus": "message", "body": data, "transaction": transaction, ..._context._apiMap, ..._context._tokenMap};
      if (jsep != null) {
        _context._logger.finest("sending jsep");
        _context._logger.finest(jsep.toMap());
        request["jsep"] = jsep.toMap();
      }
      if (_transport is RestJanusTransport) {
        RestJanusTransport rest = (_transport as RestJanusTransport);
        response = (await rest.post(request, handleId: handleId)) as Map<String, dynamic>;
      } else if (_transport is WebSocketJanusTransport) {
        WebSocketJanusTransport ws = (_transport as WebSocketJanusTransport);
        if (!ws.isConnected) {
          return;
        }
        response = await ws.send(request, handleId: handleId);
      } else if (_transport is MqttJanusTransport) {
        final mqtt = _transport as MqttJanusTransport;
        if (!mqtt.isConnected) {
          return;
        }
        response = await mqtt.send(request, handleId: handleId);
      }
      return response;
    } catch (e) {
      this._context._logger.fine(e);
    }
  }

  /// Applies the remote [RTCSessionDescription] provided by Janus to this peer connection.
  Future<void> handleRemoteJsep(RTCSessionDescription? data) async {
    // var state = webRTCHandle?.peerConnection?.signalingState;
    if (data != null) {
      await webRTCHandle?.peerConnection?.setRemoteDescription(data);
    }
  }

  /// Initializes device media (camera, microphone, or display capture) and
  /// wires the resulting stream into the plugin's peer connection.
  ///
  /// The default behaviour predicts sensible audio/video constraints when
  /// possible so callers can pass `null` for [mediaConstraints]. To take full
  /// control provide a map compatible with `navigator.mediaDevices`.
  ///
  /// Parameter hints:
  /// - [useDisplayMediaDevices]: set to `true` to capture the screen instead of
  ///   camera input. Required for iOS/macOS screen share support.
  /// - [disableDevicePrediction]: skip automatic audio/video constraint hints
  ///   and rely solely on [mediaConstraints].
  /// - [simulcastSendEncodings]/[transceiverDirection]: advanced knobs for
  ///   unified-plan transceivers (e.g. simulcast in video rooms).
  /// - [desktopCaptureContext]: mandatory when [useDisplayMediaDevices] is true
  ///   on macOS, Windows, or Linux so the native dialog can be presented.
  ///
  /// Platform considerations:
  /// - **Android / iOS:** camera capture works out of the box; screen capture
  ///   requires OS-specific entitlements and typically sets
  ///   [useDisplayMediaDevices] to `true`.
  /// - **Desktop (macOS, Windows, Linux):** provide a valid
  ///   [desktopCaptureContext] to surface `ScreenSelectDialog()` when capturing
  ///   displays. Camera capture uses automatic device prediction when available.
  /// - **Web:** screen capture is also supported; the browser prompts the user
  ///   without requiring [desktopCaptureContext].
  ///
  /// ### Android
  /// ```dart
  /// Future<MediaStream?> initAndroidCamera(JanusPlugin plugin) {
  ///   return plugin.initializeMediaDevices(
  ///     mediaConstraints: {
  ///       'audio': true,
  ///       'video': {'facingMode': 'user'},
  ///     },
  ///   );
  /// }
  /// ```
  ///
  /// ### iOS
  /// ```dart
  /// Future<MediaStream?> initIosScreenShare(
  ///   BuildContext context,
  ///   JanusPlugin plugin,
  /// ) {
  ///   return plugin.initializeMediaDevices(
  ///     useDisplayMediaDevices: true,
  ///     mediaConstraints: {'audio': true, 'video': true},
  ///     desktopCaptureContext: context, // ReplayKit prompt.
  ///   );
  /// }
  /// ```
  ///
  /// ### Desktop (macOS / Windows / Linux)
  /// ```dart
  /// Future<MediaStream?> initDesktopScreenShare(
  ///   BuildContext context,
  ///   JanusPlugin plugin,
  /// ) {
  ///   return plugin.initializeMediaDevices(
  ///     useDisplayMediaDevices: true,
  ///     desktopCaptureContext: context,
  ///   );
  /// }
  /// ```
  Future<MediaStream?> initializeMediaDevices({
    Map<String, dynamic>? mediaConstraints,
    bool useDisplayMediaDevices = false,
    bool disableDevicePrediction = false,
    TransceiverDirection? transceiverDirection = TransceiverDirection.SendOnly,
    List<RTCRtpEncoding>? simulcastSendEncodings,
    BuildContext? desktopCaptureContext,
  }) async {
    await _disposeMediaStreams(ignoreRemote: true);
    Map<String, dynamic>? constraintsCandidate = mediaConstraints != null ? Map<String, dynamic>.from(mediaConstraints) : null;

    if (!disableDevicePrediction) {
      if (!useDisplayMediaDevices) {
        List<MediaDeviceInfo> videoDevices = await getVideoInputDevices();
        List<MediaDeviceInfo> audioDevices = await getAudioInputDevices();
        if (videoDevices.isEmpty && audioDevices.isEmpty) {
          throw Exception("No device found for media generation");
        }
        if (constraintsCandidate == null) {
          if (videoDevices.isEmpty && audioDevices.isNotEmpty) {
            constraintsCandidate = {"audio": true, "video": false};
          } else if (videoDevices.length == 1 && audioDevices.isNotEmpty) {
            constraintsCandidate = {"audio": true, 'video': true};
          } else {
            constraintsCandidate = {
              "audio": audioDevices.isNotEmpty,
              'video': {
                'deviceId': {'exact': videoDevices.first.deviceId},
              },
            };
          }
        }
      } else {
        constraintsCandidate ??= {'audio': true, 'video': true};
      }
    } else {
      if (constraintsCandidate == null) {
        throw Exception("No media constraints set");
      }
    }

    final Map<String, dynamic> resolvedConstraints = Map<String, dynamic>.from(constraintsCandidate);
    _context._logger.fine(resolvedConstraints);
    if (webRTCHandle != null) {
      if (useDisplayMediaDevices == true) {
        final displayConstraints = Map<String, dynamic>.from(resolvedConstraints);
        if (WebRTC.platformIsDesktop) {
          if (desktopCaptureContext == null) {
            throw ArgumentError('desktopCaptureContext is required when capturing display on desktop');
          }
          final source = await showDialog<DesktopCapturerSource>(
            context: desktopCaptureContext,
            builder: (context) => ScreenSelectDialog(),
          );
          if (source == null) {
            _context._logger.fine('desktop screen capture cancelled by user');
            return null;
          }
          final videoConstraints = Map<String, dynamic>.from((displayConstraints['video'] as Map<String, dynamic>?) ?? <String, dynamic>{});
          videoConstraints['deviceId'] = {'exact': source.id};
          final mandatoryConstraints = Map<String, dynamic>.from((videoConstraints['mandatory'] as Map<String, dynamic>?) ?? <String, dynamic>{});
          mandatoryConstraints.putIfAbsent('frameRate', () => 30.0);
          videoConstraints['mandatory'] = mandatoryConstraints;
          displayConstraints['video'] = videoConstraints;
          displayConstraints['audio'] ??= true;
          try {
            webRTCHandle!.localStream = await navigator.mediaDevices.getDisplayMedia(displayConstraints);
          } catch (error) {
            _context._logger.severe('Failed to capture desktop display media: $error');
            rethrow;
          }
        } else {
          webRTCHandle!.localStream = await navigator.mediaDevices.getDisplayMedia(displayConstraints);
        }
      } else {
        webRTCHandle!.localStream = await navigator.mediaDevices.getUserMedia(resolvedConstraints);
      }
      if (_context._isUnifiedPlan && !_context._usePlanB) {
        _context._logger.finest('using unified plan');
        webRTCHandle!.localStream!.getTracks().forEach((element) async {
          if (simulcastSendEncodings == null) {
            await webRTCHandle!.peerConnection!.addTrack(element, webRTCHandle!.localStream!);
            return;
          }
          await webRTCHandle!.peerConnection!.addTransceiver(
              track: element,
              kind: element.kind == 'audio' ? RTCRtpMediaType.RTCRtpMediaTypeAudio : RTCRtpMediaType.RTCRtpMediaTypeVideo,
              init: RTCRtpTransceiverInit(
                  streams: [webRTCHandle!.localStream!], direction: transceiverDirection, sendEncodings: element.kind == 'video' ? simulcastSendEncodings : null));
        });
      } else {
        _localStreamController!.sink.add(webRTCHandle!.localStream);
        await webRTCHandle!.peerConnection!.addStream(webRTCHandle!.localStream!);
      }
      return webRTCHandle!.localStream;
    } else {
      _context._logger.severe("error webrtchandle cant be null");
      return null;
    }
  }

  /// Returns all available video input devices from the underlying platform.
  Future<List<MediaDeviceInfo>> getVideoInputDevices() async {
    return (await navigator.mediaDevices.enumerateDevices()).where((element) => element.kind == 'videoinput').toList();
  }

  /// Returns all available audio input devices from the underlying platform.
  Future<List<MediaDeviceInfo>> getAudioInputDevices() async {
    return (await navigator.mediaDevices.enumerateDevices()).where((element) => element.kind == 'audioinput').toList();
  }

  /// Switches the active camera track to the one referenced by [deviceId].
  ///
  /// When [deviceId] is omitted on web, the helper defaults to the last device
  /// returned by [getVideoInputDevices], which is often the rear-facing camera.
  Future<bool> switchCamera({String? deviceId}) async {
    List<MediaDeviceInfo> videoDevices = await getVideoInputDevices();
    if (videoDevices.isEmpty) {
      throw Exception("No Camera Found");
    }
    if (kIsWeb) {
      if (deviceId == null) {
        _context._logger.finest('deviceId not provided,hence switching to default last deviceId should be of back camera ideally');
        deviceId = videoDevices.last.deviceId;
      }
      await _disposeMediaStreams(ignoreRemote: true);
      webRTCHandle!.localStream = await navigator.mediaDevices.getUserMedia({
        'video': {
          'deviceId': {'exact': deviceId},
        },
        'audio': true,
      });
      List<RTCRtpSender> senders = (await webRTCHandle!.peerConnection!.getSenders());
      webRTCHandle!.localStream?.getTracks().forEach((element) async {
        senders.forEach((sender) async {
          if (sender.track?.kind == element.kind) {
            await sender.replaceTrack(element);
          }
        });
      });
      return true;
    } else {
      if (webRTCHandle?.localStream != null) {
        _context._logger.finest('using helper to switch camera, only works in android and ios');
        return Helper.switchCamera(webRTCHandle!.localStream!.getVideoTracks().first);
      }
      return false;
    }
  }

  /// Creates an SDP offer and sets it as the local description.
  ///
  /// Supports both Plan-B and Unified Plan flows based on the internal flags.
  Future<RTCSessionDescription> createOffer({bool audioRecv = true, bool videoRecv = true}) async {
    dynamic offerOptions;
    offerOptions = {"offerToReceiveAudio": audioRecv, "offerToReceiveVideo": videoRecv};
    RTCSessionDescription offer = await webRTCHandle!.peerConnection!.createOffer(offerOptions ?? {});
    await webRTCHandle!.peerConnection!.setLocalDescription(offer);
    return offer;
  }

  /// Creates an SDP answer and sets it as the local description.
  Future<RTCSessionDescription> createAnswer() async {
    try {
      RTCSessionDescription answer = await webRTCHandle!.peerConnection!.createAnswer();
      await webRTCHandle!.peerConnection!.setLocalDescription(answer);
      return answer;
    } catch (e) {
      //    handling kstable exception most ugly way but currently there's no other workaround, it just works
      RTCSessionDescription answer = await webRTCHandle!.peerConnection!.createAnswer();
      await webRTCHandle!.peerConnection!.setLocalDescription(answer);
      return answer;
    }
  }

  /// Calculates the bitrate of the inbound video stream identified by [mid].
  ///
  /// When [mid] is omitted, statistics for the first video inbound RTP stream
  /// are returned. Mirrors the behaviour of `Janus#getBitrate` in janus.js.
  Future<String?> getBitrate([String? mid]) async {
    if (webRTCHandle?.peerConnection == null) {
      return null;
    }

    final stats = await webRTCHandle!.peerConnection!.getStats();
    final nowMillis = DateTime.now().millisecondsSinceEpoch;

    String? result;

    for (var report in stats) {
      // Look for the specific mid or first video stream
      bool isTargetStream = false;

      if (mid != null) {
        // Look for specific mid
        if (report.values['mid'] == mid && report.type == 'inbound-rtp' && report.values['kind'] == 'video') {
          isTargetStream = true;
        }
      } else {
        // Look for first video stream
        if (report.type == 'inbound-rtp' && report.values['kind'] == 'video') {
          isTargetStream = true;
        }
      }

      if (isTargetStream && report.values['bytesReceived'] != null) {
        final currentBytesReceived = report.values['bytesReceived'] as int;

        // Determine history key (use "default" if mid is null)
        final historyKey = mid ?? "default";

        // Calculate bitrate if we have previous values
        if (_lastBytesReceivedMap[historyKey] != null && _lastTimestampMap[historyKey] != null) {
          final bytesDiff = currentBytesReceived - _lastBytesReceivedMap[historyKey]!;
          final timeDiff = (nowMillis - _lastTimestampMap[historyKey]!) / 1000.0;

          if (timeDiff > 0 && bytesDiff >= 0) {
            final bitsDiff = bytesDiff * 8;
            final bitsPerSecond = bitsDiff / timeDiff;
            final kbps = (bitsPerSecond / 1000).round();

            result = "$kbps kbps";
          }
        }

        // Store current values for next calculation
        _lastBytesReceivedMap[historyKey] = currentBytesReceived;
        _lastTimestampMap[historyKey] = nowMillis;
        break; // Found our target stream
      }
    }

    return result;
  }

  /// Sends a text [message] over the default data channel.
  ///
  /// Ensure [initDataChannel] has been invoked and the channel is open before
  /// calling this helper. Throws if the peer connection or channel is missing.
  Future<void> sendData(String message) async {
    if (webRTCHandle!.peerConnection != null) {
      _context._logger.finest('before send RTCDataChannelMessage');
      if (webRTCHandle!.dataChannel[_context._dataChannelDefaultLabel] == null) {
        throw Exception("You Must  call initDataChannel method! before you can send any data channel message");
      }
      RTCDataChannel dataChannel = webRTCHandle!.dataChannel[_context._dataChannelDefaultLabel]!;
      if (dataChannel.state == RTCDataChannelState.RTCDataChannelOpen) {
        await dataChannel.send(RTCDataChannelMessage(message));
        return;
      }
    } else {
      throw Exception("You Must Initialize Peer Connection followed by initDataChannel()");
    }
  }
}
