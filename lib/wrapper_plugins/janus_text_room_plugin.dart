part of janus_client;

class JanusTextRoomPlugin extends JanusPlugin {
  JanusTextRoomPlugin({handleId, context, transport, session})
      : super(context: context, handleId: handleId, plugin: JanusPlugins.TEXT_ROOM, session: session, transport: transport);

  bool _setup = false;

  bool get setupDone => _setup;

  /// Negotiates the peer connection and data channel used for the text room.
  ///
  /// Call this before invoking any other text room operation.
  Future<void> setup() async {
    var body = {"request": "setup"};
    await this.send(data: body);
    this.messages?.listen((event) async {
      if (event.jsep != null) {
        await this.handleRemoteJsep(event.jsep);
        var body = {"request": "ack"};
        await this.initDataChannel();
        RTCSessionDescription answer = await this.createAnswer();
        await this.send(
          data: body,
          jsep: answer,
        );
      }
    });
    this._setup = true;
  }

  /// Joins the text room identified by [roomId].
  ///
  /// Parameters:
  /// - [username]: Unique username within the room (required).
  /// - [pin]: Room pin when configured.
  /// - [display]: Display name shown to other participants.
  /// - [token]: Invitation token for ACL-protected rooms.
  /// - [history]: Requests buffered history when `true` (default).
  Future<void> joinRoom(int roomId, String username, {String? pin, String? display, String? token, bool? history}) async {
    if (setupDone) {
      _context._logger.info('data channel is open, now trying to join');
      var register = {'textroom': "join", 'transaction': randomString(), 'room': roomId, 'username': username, 'display': display, "pin": pin, "token": token, "history": history}
        ..removeWhere((key, value) => value == null);
      _handleRoomIdTypeDifference(register);
      await this.sendData(stringify(register));
    } else {
      _context._logger.shout('method was called before calling setup(), hence aborting further operation.');
      throw "method was called before calling setup(), hence aborting further operation.";
    }
  }

  /// Leaves the specified text room after a successful [joinRoom] call.
  Future<void> leaveRoom(int roomId) async {
    if (setupDone) {
      _context._logger.fine('trying to leave room $roomId');
      var payload = {"textroom": "leave", "room": roomId};
      _handleRoomIdTypeDifference(payload);
      await this.sendData(stringify(payload));
    } else {
      _context._logger.shout('method was called before calling setup(), hence aborting further operation.');
      throw "method was called before calling setup(), hence aborting further operation.";
    }
  }

  /// Sends a chat [text] message to the specified room.
  ///
  /// Parameters:
  /// - [roomId]: Room identifier.
  /// - [ack]: Requests delivery acknowledgements (defaults to `true`).
  /// - [to]: Username for a private message.
  /// - [tos]: Multiple usernames for a multi-target private message.
  Future<void> sendMessage(dynamic roomId, String text, {bool? ack, String? to, List<String>? tos}) async {
    if (setupDone) {
      var message = {'transaction': randomString(), "textroom": "message", "room": roomId, "text": text, "to": to, "tos": tos, "ack": ack}
        ..removeWhere((key, value) => value == null);
      _handleRoomIdTypeDifference(message);
      _context._logger.fine('sending text message to room:$roomId with payload:$message');
      await this.sendData(stringify(message));
    } else {
      _context._logger.shout('method was called before calling setup(), hence aborting further operation.');
      throw "method was called before calling setup(), hence aborting further operation.";
    }
  }

  /// Returns all text rooms configured on the Janus server.
  Future<List<JanusTextRoom>?> listRooms() async {
    var payload = {
      "request": "list",
    };
    _handleRoomIdTypeDifference(payload);
    _context._logger.fine('list rooms invoked');
    JanusEvent response = JanusEvent.fromJson(await this.send(data: payload));
    JanusError.throwErrorFromEvent(response);
    return (response.plugindata?.data?['list'] as List<dynamic>?)?.map((e) => JanusTextRoom.fromJson(e)).toList();
  }

  /// Returns the participant roster for the specified room.
  Future<List<dynamic>?> listParticipants(dynamic roomId) async {
    var payload = {"request": "listparticipants", "room": roomId};
    _handleRoomIdTypeDifference(payload);
    _context._logger.fine('listParticipants invoked with roomId:$roomId');
    JanusEvent response = JanusEvent.fromJson(await this.send(data: payload));
    JanusError.throwErrorFromEvent(response);
    return response.plugindata?.data?['participants'];
  }

  /// Verifies whether a text room with the given identifier exists.
  Future<bool?> exists(dynamic roomId) async {
    var payload = {"request": "exists", "room": roomId};
    _handleRoomIdTypeDifference(payload);
    _context._logger.fine('exists invoked with roomId:$roomId');
    JanusEvent response = JanusEvent.fromJson(await this.send(data: payload));
    JanusError.throwErrorFromEvent(response);
    return response.plugindata?.data?['exists'];
  }

  /// Removes a participant from the room when the admin secret is provided.
  ///
  /// Parameters:
  /// - [roomId]: Target room identifier.
  /// - [username]: Participant to remove.
  /// - [secret]: Admin secret when required by the room.
  Future<dynamic> kickParticipant(dynamic roomId, String username, {String? secret}) async {
    var payload = {"request": "kick", "secret": secret, "room": roomId, "username": username}..removeWhere((key, value) => value == null);
    _handleRoomIdTypeDifference(payload);
    JanusEvent response = JanusEvent.fromJson(await this.send(data: payload));
    JanusError.throwErrorFromEvent(response);
    return response.plugindata?.data;
  }

  /// Destroys an existing text room.
  ///
  /// Parameters:
  /// - [roomId]: Room identifier.
  /// - [secret]: Admin secret when required.
  /// - [permanent]: Removes the room from the configuration file when `true`.
  Future<dynamic> destroyRoom({int? roomId, String? secret, bool? permanent}) async {
    var payload = {
      "textroom": "destroy",
      "room": roomId,
      "secret": secret,
      "permanent": permanent,
    };
    _handleRoomIdTypeDifference(payload);
    _context._logger.fine('destroyRoom invoked with roomId:$roomId');
    JanusEvent response = JanusEvent.fromJson(await this.send(data: payload));
    JanusError.throwErrorFromEvent(response);
    return response;
  }

  /// Creates a new text room.
  ///
  /// Parameters:
  /// - [roomId]: Custom room identifier (auto-generated when omitted).
  /// - [adminKey]: Plugin administrator key when required.
  /// - [description]: Human-readable room name.
  /// - [secret]: Admin secret used for destructive operations.
  /// - [pin]: Participant pin code.
  /// - [isPrivate]: Hides the room from list queries when `true`.
  /// - [history]: Number of historical messages retained.
  /// - [permanent]: Persists the room to the configuration file.
  Future<dynamic> createRoom({String? roomId, String? adminKey, String? description, String? secret, String? pin, bool? isPrivate, int? history, bool? permanent}) async {
    var payload = {
      "textroom": "create",
      "room": roomId,
      "admin_key": adminKey,
      "description": description,
      "secret": secret,
      "pin": pin,
      "is_private": isPrivate,
      "history": history,
      "permanent": permanent,
    };
    _handleRoomIdTypeDifference(payload);
    _context._logger.fine('createRoom invoked with roomId:$roomId');
    JanusEvent response = JanusEvent.fromJson(await this.send(data: payload));
    JanusError.throwErrorFromEvent(response);
    return response;
  }

  /// Updates metadata or access settings for an existing text room.
  ///
  /// Parameters:
  /// - [roomId]: Room identifier.
  /// - [description]: Updated display name.
  /// - [secret]: Existing admin secret when required.
  /// - [newSecret]: New admin secret for future operations.
  /// - [pin]: New participant pin.
  /// - [isPrivate]: Toggles list visibility.
  /// - [permanent]: Persists changes to the configuration file.
  Future<dynamic> editRoom({String? roomId, String? description, String? secret, String? newSecret, String? pin, bool? isPrivate, bool? permanent}) async {
    var payload = {
      "textroom": "create",
      "room": roomId,
      "secret": secret,
      "permanent": permanent,
      "new_description": description,
      "new_secret": newSecret,
      "new_pin": pin,
      "new_is_private": isPrivate,
    };
    _handleRoomIdTypeDifference(payload);
    _context._logger.fine('editRoom invoked with roomId:$roomId');
    JanusEvent response = JanusEvent.fromJson(await this.send(data: payload));
    JanusError.throwErrorFromEvent(response);
    return response;
  }
}
