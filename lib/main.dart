import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'package:uuid/uuid.dart';        
import 'dart:convert';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'dart:async';



void main() {
  runApp(const MyApp());
}

/// Aplikasi langsung masuk ke layar chat (tanpa home counter)
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  

  @override
  Widget build(BuildContext context) {
    final seed = const Color(0xFF25D366); // nuansa hijau WA
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Chat Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
      ),
      home: const ChatPage(contactName: 'Ayu'),
    );
  }
}

/// Model pesan sederhana
class Message {
  final String text;
  final bool isMe;
  final DateTime time;

  Message({required this.text, required this.isMe, required this.time});
}

/// Layar chat 1–1
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.contactName});
  final String contactName;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _messages = <Message>[
    // Message(text: 'Halo! 👋', isMe: false, time: DateTime.now().subtract(const Duration(minutes: 5))),
    // Message(text: 'Halo juga, apa kabar?', isMe: true, time: DateTime.now().subtract(const Duration(minutes: 4))),
    // Message(text: 'Baik, lagi belajar Flutter nih.', isMe: false, time: DateTime.now().subtract(const Duration(minutes: 3))),
  ];

  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();

  final _topicController = TextEditingController();
  final _uuid = const Uuid();

  String? _currentTopic;

  MqttServerClient? _mqtt;

  final String _broker = 'test.mosquitto.org';
  final int _port = 1883;
  late final String _clientId;
  late final String _myId;
  String? _lastSubscribedTopic;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _mqttSub;

  bool get _isConnected =>
    _mqtt?.connectionStatus?.state == MqttConnectionState.connected;

  bool get _canSend =>
    (_currentTopic?.isNotEmpty ?? false) && _isConnected;



  // Prefix biar rapi di broker publik
  static const String _topicPrefix = 'chat-private/';

  bool _isValidTopic(String t) {
    // Topik tidak boleh kosong, tidak boleh mengandung spasi,
    // dan panjangnya wajar (mis. <= 200).
    return t.isNotEmpty && !t.contains(' ') && t.length <= 200;
  }

  String _normalizeTopic(String raw) {
    // trim + tambahkan prefix jika belum ada
    final t = raw.trim();
    final withPrefix = t.startsWith(_topicPrefix) ? t : '$_topicPrefix$t';
    return withPrefix;
  }



  @override
  void initState() {
    super.initState();
    _clientId = 'flutter_${DateTime.now().millisecondsSinceEpoch}';
    _myId = _uuid.v4().substring(0, 8); // penanda singkat device ini
    _connectMqtt(); // mulai konek ke broker
  }


  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _topicController.dispose();

    try { _mqttSub?.cancel(); } catch (_) {}
    try {
      final client = _mqtt;
      if (client?.connectionStatus?.state == MqttConnectionState.connected) {
        client?.disconnect();
      }
    } catch (_) {}

    super.dispose();
  }

  void _showTopBanner(
    String msg, {
    IconData icon = Icons.info_outline,
    Color? bg,
    Color? fg,
    Duration duration = const Duration(seconds: 2),
  }) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearMaterialBanners();

    final scheme = Theme.of(context).colorScheme;

    messenger.showMaterialBanner(
      MaterialBanner(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(icon, color: fg ?? scheme.onSurfaceVariant),
        backgroundColor: bg ?? scheme.surface,
        content: Text(
          msg,
          style: TextStyle(color: fg ?? scheme.onSurface),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => messenger.hideCurrentMaterialBanner(),
            child: const Text('Tutup'),
          ),
        ],
      ),
    );

    // auto-dismiss
    Future.delayed(duration, () {
      if (!mounted) return;
      messenger.hideCurrentMaterialBanner();
    });
  }

  // convenience wrappers
  void _bannerSuccess(String m) =>
      _showTopBanner(m, icon: Icons.check_circle_outline, bg: Colors.greenAccent.withOpacity(.15));
  void _bannerError(String m) =>
      _showTopBanner(m, icon: Icons.error_outline, bg: Colors.redAccent.withOpacity(.15));
  void _bannerInfo(String m) =>
      _showTopBanner(m, icon: Icons.info_outline);



  Future<void> _connectMqtt() async {
    final client = MqttServerClient(_broker, _clientId)
      ..port = _port
      ..logging(on: false)
      ..keepAlivePeriod = 20
      ..autoReconnect = true
      ..resubscribeOnAutoReconnect = true
      ..onConnected = () => debugPrint('✅ MQTT connected');

    // Hooks auto reconnect
    client.onAutoReconnect = () => debugPrint('🔁 MQTT auto reconnecting...');
    client.onAutoReconnected = () {
      debugPrint('✅ MQTT auto reconnected');
      _resubscribeToTopic();
    };

    client.onDisconnected = () {
      debugPrint('❌ MQTT disconnected');
    };
    client.onSubscribed = (String topic) {
      debugPrint('📌 Subscribed: $topic');
    };

    final connMess = MqttConnectMessage()
        .withClientIdentifier(_clientId)
        .keepAliveFor(20)
        .startClean()
        .withWillQos(MqttQos.atMostOnce);
    client.connectionMessage = connMess;

    _mqtt = client; // <-- assign dulu, sebelum connect, supaya getter aman

    try {
      await client.connect(); // broker publik: tanpa user/pass
    } catch (e) {
      debugPrint('MQTT connect error: $e');
      client.disconnect();
      if (mounted) {
        // ScaffoldMessenger.of(context).showSnackBar(
        //   const SnackBar(content: Text('Gagal konek ke broker MQTT')),
        // );
        _bannerError('Gagal konek ke broker MQTT');
      }
      return;
    }

    // Listener pesan masuk — pastikan hanya satu
    _mqttSub?.cancel();
    final updates = client.updates;
    if (updates == null) return;

    _mqttSub = updates.listen((List<MqttReceivedMessage<MqttMessage>> events) {
      if (events.isEmpty) return;

      // 🔁 Penting: proses SEMUA event, bukan hanya first
      for (final rec in events) {
        final msg = rec.payload as MqttPublishMessage;
        final topic = rec.topic;
        final payload =
            MqttPublishPayload.bytesToStringAsString(msg.payload.message);

        if (topic != _currentTopic) continue;

        try {
          final data = jsonDecode(payload) as Map<String, dynamic>;
          final text = (data['text'] ?? '').toString();
          final from = (data['from'] ?? '').toString();
          final tsMs = (data['ts'] ?? DateTime.now().millisecondsSinceEpoch) as int;

          if (from == _myId) continue; // cegah duplikat

          setState(() {
            _messages.add(Message(
              text: text,
              isMe: false,
              time: DateTime.fromMillisecondsSinceEpoch(tsMs),
            ));
          });
          _scrollToBottom();
        } catch (e) {
          debugPrint('Invalid payload: $payload ($e)');
        }
      }
    });
  }


  Future<void> _resubscribeToTopic() async {
    // Pastikan ada client
    var client = _mqtt;
    if (client == null ||
        client.connectionStatus?.state != MqttConnectionState.connected) {
      await _connectMqtt();
      client = _mqtt;
      if (client == null ||
          client.connectionStatus?.state != MqttConnectionState.connected) {
        return;
      }
    }

    // Unsubscribe topik lama
    if ((_lastSubscribedTopic ?? '').isNotEmpty) {
      try {
        client.unsubscribe(_lastSubscribedTopic!);
        debugPrint('🔕 Unsubscribed: $_lastSubscribedTopic');
      } catch (_) {}
    }

    // Subscribe topik baru
    if ((_currentTopic ?? '').isNotEmpty) {
      client.subscribe(_currentTopic!, MqttQos.atLeastOnce);
      _lastSubscribedTopic = _currentTopic;
      if (mounted) {
        // ScaffoldMessenger.of(context).showSnackBar(
        //   SnackBar(content: Text('Subscribed ke topic: $_currentTopic')),
        // );
        _bannerSuccess('Subscribed ke topic: $_currentTopic');
      }
    }
  }


  Future<void> _generateAndShowTopic() async {
    final id = _uuid.v4();              // UUID v4 mentah
    final normalized = _normalizeTopic(id); // <-- hoist ke luar setState

    setState(() {
      _currentTopic = normalized;
      _topicController.text = normalized;
    });

    await _resubscribeToTopic();

    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Unique Topic'),
          content: GestureDetector(
            onLongPress: () async {
              await Clipboard.setData(ClipboardData(text: normalized)); // <-- pakai normalized
              if (context.mounted) {
                Navigator.of(ctx).pop();
                // ScaffoldMessenger.of(context).showSnackBar(
                //   const SnackBar(content: Text('Topic disalin ke clipboard')),
                // );

                _bannerSuccess('Topic disalin ke clipboard');

              }
            },
            child: SelectableText(
              normalized, // <-- tampilkan normalized juga kalau mau
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Tutup'),
            ),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: normalized)); // <-- pakai normalized
                if (context.mounted) {
                  Navigator.of(ctx).pop();
                  // ScaffoldMessenger.of(context).showSnackBar(
                  //   const SnackBar(content: Text('Topic disalin ke clipboard')),
                  // );
                  _bannerSuccess('Topic disalin ke clipboard');
                }
              },
              icon: const Icon(Icons.copy),
              label: const Text('Salin'),
            ),
          ],
        );
      },
    );
  }



  void _setTopicFromInput() {
    final raw = _topicController.text;
    if (!_isValidTopic(raw.trim())) {
      // ScaffoldMessenger.of(context).showSnackBar(
      //   const SnackBar(content: Text('Topic tidak valid (tidak boleh kosong atau ada spasi)')),
      // );
      _bannerError('Topic tidak valid (tidak boleh kosong atau ada spasi)');
      return;
    }

    final t = _normalizeTopic(raw);
    setState(() {
      _currentTopic = t;
    });

    // ScaffoldMessenger.of(context).showSnackBar(
    //   SnackBar(content: Text('Topic di-set ke: $t')),
    // );
    _bannerInfo('Topic di-set ke: $t');

    _resubscribeToTopic();
  }

  void _scrollToBottom() {
  // ListView kita pakai reverse:true, jadi posisi "bawah" = offset 0
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }


  Future<void> _confirmClearChat() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus semua chat?'),
        content: const Text('Tindakan ini tidak bisa dibatalkan.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.delete),
            label: const Text('Hapus'),
          ),
        ],
      ),
    );

    if (ok == true) {
      setState(() {
        _messages.clear();
      });
      if (!mounted) return;
      // ScaffoldMessenger.of(context).showSnackBar(
      //   const SnackBar(content: Text('Semua chat dihapus')),
      // );
      _bannerInfo('Semua chat dihapus');
    }
  }



  void _sendMessage([String? quick]) {
    final text = quick ?? _controller.text.trim();
    if (text.isEmpty) return;

    final client = _mqtt;
    if ((_currentTopic ?? '').isEmpty) {
      // ScaffoldMessenger.of(context).showSnackBar(
      //   const SnackBar(content: Text('Set topic dulu sebelum kirim pesan')),
      // );

      _bannerError('Set topic dulu sebelum kirim pesan');
      return;
    }
    if (client == null ||
        client.connectionStatus?.state != MqttConnectionState.connected) {
      // ScaffoldMessenger.of(context).showSnackBar(
      //   const SnackBar(content: Text('Belum terhubung ke broker MQTT')),
      // );

      _bannerError('Belum terhubung ke broker MQTT');
      return;
    }

    final msgMap = {
      'from': _myId,
      'text': text,
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    final builder = MqttClientPayloadBuilder()..addString(jsonEncode(msgMap));
    client.publishMessage(_currentTopic!, MqttQos.atLeastOnce, builder.payload!);

    // Optimistic UI
    setState(() {
      _messages.add(Message(text: text, isMe: true, time: DateTime.now()));
    });
    _controller.clear();
    _focusNode.requestFocus();
    _scrollToBottom();
  }


  @override
  Widget build(BuildContext context) {

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        elevation: 0,
        titleSpacing: 0,
        // Gunakan title untuk meletakkan input topic + tombol set
        title: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                child: TextField(
                  controller: _topicController,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (v) {
                    _setTopicFromInput();
                  },
                  decoration: InputDecoration(
                    hintText: 'Masukkan topic…',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Set topic dari input',
              icon: const Icon(Icons.check_circle_outline),
              onPressed: _setTopicFromInput,
            ),
          ],
        ),
        // Tombol generate ada di kanan
        actions: [
          IconButton(
            tooltip: 'Generate unique topic',
            icon: const Icon(Icons.auto_awesome),
            onPressed: _generateAndShowTopic,
          ),
        ],
      ),


      body: SafeArea(
        child: Column(
          children: [
          
          
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: Theme.of(context).colorScheme.surface,
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isConnected ? Colors.green : Colors.red,
                  ),
                ),
                Expanded(
                  child: Text(
                    _currentTopic == null ? 'Topic: (belum di-set)' : 'Topic: $_currentTopic',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _isConnected ? 'Connected' : 'Disconnected',
                  style: TextStyle(
                    fontSize: 12,
                    color: _isConnected ? Colors.green : Colors.red,
                  ),
                ),
              ],
            ),
          ),



            // Daftar pesan
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  // image: const DecorationImage(
                  //   image: AssetImage('assets/chat_bg.png'), // opsional: hapus baris ini kalau belum punya asset
                  //   fit: BoxFit.cover,
                  //   opacity: .06,
                  // ),
                  color: Theme.of(context).scaffoldBackgroundColor,
                ),
                child: ListView.builder(
                  controller: _scrollController,
                  reverse: true, // pesan terbaru di bawah
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    // karena reverse:true, kita render dari akhir
                    final msg = _messages[_messages.length - 1 - index];
                    return _MessageBubble(message: msg);
                  },
                ),
              ),
            ),

            // Input area
            _InputBar(
              controller: _controller,
              focusNode: _focusNode,
              onSend: _sendMessage,
              onAttach: _confirmClearChat, // Hapus semua chat
              canSend: _canSend, // <-- tambahan
            ),
          ],
        ),
      ),
    );
  }
}

/// Widget bubble pesan
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});
  final Message message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isMe = message.isMe;

    final bg = isMe
        ? const Color(0xFFDCF8C6) // hijau muda khas WA untuk pengirim
        : Theme.of(context).colorScheme.surface;

    final align = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: isMe ? const Radius.circular(16) : const Radius.circular(4),
      bottomRight: isMe ? const Radius.circular(4) : const Radius.circular(16),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Row(
            mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: radius,
                    boxShadow: [
                      BoxShadow(
                        blurRadius: 2,
                        offset: const Offset(0, 1),
                        color: Colors.black.withOpacity(.05),
                      )
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      SelectableText(
                        message.text,
                        style: TextStyle(
                          color: isMe ? Colors.black87 : scheme.onSurface,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatTime(message.time),
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

/// Widget input teks + tombol send
class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onAttach,
    required this.canSend
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final void Function([String? quick]) onSend;
  final VoidCallback onAttach;

  final bool canSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.black),
              onPressed: onAttach,
              tooltip: 'Hapus semua chat',
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (v) {
                    if (canSend) onSend();
                  },
                  decoration: const InputDecoration(
                    hintText: 'Tulis pesan',
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 24,
              child: IconButton(
                icon: const Icon(Icons.send_rounded),
                onPressed: canSend ? onSend : null,
                tooltip: 'Kirim',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
