import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:mobile_scanner/mobile_scanner.dart' as ms;
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(DHBarcodeGeneratorApp(cameras: cameras));
}

class DHBarcodeGeneratorApp extends StatelessWidget {
  const DHBarcodeGeneratorApp({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DH Barcode Generator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: HomeTabs(cameras: cameras),
    );
  }
}

class HomeTabs extends StatefulWidget {
  const HomeTabs({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  State<HomeTabs> createState() => _HomeTabsState();
}

class _HomeTabsState extends State<HomeTabs>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_handleTabChanged);
  }

  void _handleTabChanged() {
    if (!_tabController.indexIsChanging) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_handleTabChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final index = _tabController.index;
    return Scaffold(
      appBar: AppBar(
        title: const Text('DH Barcode Generator'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.text_fields), text: 'Text Scan'),
            Tab(icon: Icon(Icons.qr_code_scanner), text: 'Barcode Scan'),
          ],
        ),
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: () {
          if (index == 0) {
            return TextScanTab(
              key: const ValueKey('text-scan-tab'),
              cameras: widget.cameras,
            );
          }
          if (index == 1) {
            return const BarcodeScanTab(key: ValueKey('barcode-scan-tab'));
          }
          return const SizedBox.shrink();
        }(),
      ),
    );
  }
}

enum _MqttConnectionState { disconnected, connecting, connected, error }

class _DetectedTextElement {
  const _DetectedTextElement({required this.text, required this.boundingBox});

  final String text;
  final Rect boundingBox;
}

class TextScanTab extends StatefulWidget {
  const TextScanTab({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  State<TextScanTab> createState() => _TextScanTabState();
}

class _TextScanTabState extends State<TextScanTab> {
  CameraController? _controller;
  bool _initializingController = false;
  PermissionStatus? _cameraPermission;
  String? _cameraError;

  late final TextRecognizer _textRecognizer;
  late final TextEditingController _manualController;

  List<_DetectedTextElement> _detectedElements = const [];
  List<String> _candidateTexts = const [];
  Size? _latestImageSize;
  InputImageRotation? _latestImageRotation;
  bool _isProcessingImage = false;
  DateTime? _lastDetection;

  Set<String> _selectedTexts = <String>{};
  bool _detectedTextsLocked = false;

  _MqttConnectionState _mqttState = _MqttConnectionState.disconnected;
  String? _mqttError;
  MqttServerClient? _mqttClient;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>?
      _mqttSubscription;

  bool _isAwaitingLookup = false;
  bool? _lookupMatchFound;
  double? _lookupMatchScore;
  String? _lookupRequestedName;
  Map<String, dynamic>? _matchedProduct;
  String? _responseError;

  String get _combinedSelectedText => _selectedTexts.join('\n');

  String? get _matchedProductCode {
    final code = _matchedProduct?['product_code'];
    if (code is String) {
      final trimmed = code.trim();
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return null;
  }

  String? get _matchedProductName {
    final name = _matchedProduct?['name'];
    if (name is String) {
      final trimmed = name.trim();
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    _manualController = TextEditingController();
    _requestPermissionAndInitialize();
    _initializeMqtt();
  }

  @override
  void dispose() {
    _controller?.dispose();
    _textRecognizer.close();
    _manualController.dispose();
    _mqttSubscription?.cancel();
    _mqttClient?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: _buildBody(context),
    );
  }

  Future<void> _requestPermissionAndInitialize() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    setState(() => _cameraPermission = status);
    if (status.isGranted) {
      await _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    setState(() {
      _initializingController = true;
      _cameraError = null;
    });

    if (widget.cameras.isEmpty) {
      setState(() {
        _cameraError = 'No cameras available on this device.';
        _initializingController = false;
      });
      return;
    }

    final camera = widget.cameras.firstWhere(
      (description) => description.lensDirection == CameraLensDirection.back,
      orElse: () => widget.cameras.first,
    );

    final controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
      });
      await controller.startImageStream(
        (image) => _processCameraImage(image, controller.description),
      );
    } on CameraException catch (error) {
      await controller.dispose();
      setState(() {
        _cameraError =
            'Failed to initialise camera: ${error.description ?? error.code}';
      });
    } finally {
      if (mounted) {
        setState(() => _initializingController = false);
      }
    }
  }

  Future<void> _initializeMqtt() async {
    setState(() {
      _mqttState = _MqttConnectionState.connecting;
      _mqttError = null;
    });

    final clientId = 'dh_barcode_${DateTime.now().millisecondsSinceEpoch}';
    final client =
        MqttServerClient('broker.hivemq.com', clientId)
          ..logging(on: false)
          ..port = 1883
          ..keepAlivePeriod = 20
          ..autoReconnect = true
          ..resubscribeOnAutoReconnect = false
          ..onConnected = _handleMqttConnected
          ..onDisconnected = _handleMqttDisconnected
          ..onAutoReconnect = _handleMqttAutoReconnect
          ..onAutoReconnected = _handleMqttConnected
          ..connectionMessage =
              MqttConnectMessage().withClientIdentifier(clientId).startClean();

    try {
      await client.connect();
      if (!mounted) {
        client.disconnect();
        return;
      }
      setState(() {
        _mqttClient = client;
        _mqttState = _MqttConnectionState.connected;
        _mqttError = null;
      });
      _subscribeToResponseTopic(client);
    } on Exception catch (error) {
      client.disconnect();
      if (!mounted) return;
      setState(() {
        _mqttState = _MqttConnectionState.error;
        _mqttError = error.toString();
      });
    }
  }

  void _handleMqttConnected() {
    if (!mounted) return;
    setState(() {
      _mqttState = _MqttConnectionState.connected;
      _mqttError = null;
    });
    final client = _mqttClient;
    if (client != null) {
      _subscribeToResponseTopic(client);
    }
  }

  void _handleMqttDisconnected() {
    if (!mounted) return;
    setState(() {
      if (_mqttState != _MqttConnectionState.error) {
        _mqttState = _MqttConnectionState.disconnected;
        _isAwaitingLookup = false;
      }
    });
    _mqttSubscription?.cancel();
    _mqttSubscription = null;
  }

  void _handleMqttAutoReconnect() {
    if (!mounted) return;
    setState(() {
      _mqttState = _MqttConnectionState.connecting;
    });
  }

  void _subscribeToResponseTopic(MqttServerClient client) {
    final updates = client.updates;
    if (updates == null) {
      return;
    }
    _mqttSubscription?.cancel();
    client.subscribe('lift/lobby/packages/response', MqttQos.atLeastOnce);
    _mqttSubscription = updates.listen(_handleMqttMessage);
  }

  void _handleMqttMessage(
    List<MqttReceivedMessage<MqttMessage>> messages,
  ) {
    for (final message in messages) {
      if (message.topic != 'lift/lobby/packages/response') {
        continue;
      }
      final payloadMessage = message.payload as MqttPublishMessage;
      final payload = MqttPublishPayload.bytesToStringAsString(
        payloadMessage.payload.message,
      );
      _processLookupResponse(payload);
    }
  }

  void _processLookupResponse(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Response is not a JSON object');
      }
      final requestedName =
          decoded['requested_name'] is String ? decoded['requested_name'] as String : null;
      final matchFound =
          decoded['match_found'] is bool ? decoded['match_found'] as bool : null;
      final matchScore =
          decoded['match_score'] is num ? (decoded['match_score'] as num).toDouble() : null;
      final product =
          decoded['product'] is Map<String, dynamic> ? decoded['product'] as Map<String, dynamic> : null;

      if (!mounted) return;
      setState(() {
        _isAwaitingLookup = false;
        _responseError = null;
        _lookupRequestedName = requestedName ?? _lookupRequestedName;
        _lookupMatchFound = matchFound;
        _lookupMatchScore = matchScore;
        _matchedProduct = matchFound == true ? product : null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isAwaitingLookup = false;
        _responseError = 'Failed to parse response: $error';
        _lookupMatchFound = null;
        _lookupMatchScore = null;
        _matchedProduct = null;
      });
    }
  }

  Future<void> _processCameraImage(
    CameraImage image,
    CameraDescription description,
  ) async {
    if (_detectedTextsLocked) {
      return;
    }
    if (_isProcessingImage) return;
    final now = DateTime.now();
    if (_lastDetection != null &&
        now.difference(_lastDetection!) < const Duration(milliseconds: 350)) {
      return;
    }

    _isProcessingImage = true;

    try {
      final inputImage = buildInputImageFromCameraImage(image, description);
      if (inputImage == null) {
        return;
      }

      final recognisedText = await _textRecognizer.processImage(inputImage);
      if (!mounted) return;

      final elements = <_DetectedTextElement>[];
      final candidates = <String>[];

      for (final block in recognisedText.blocks) {
        for (final line in block.lines) {
          final text = line.text.trim();
          final rect = line.boundingBox;
          if (text.isEmpty) continue;
          if (!candidates.contains(text)) {
            candidates.add(text);
          }
          elements.add(_DetectedTextElement(text: text, boundingBox: rect));
        }
      }

      final limitedCandidates =
          candidates.length > 12 ? candidates.sublist(0, 12) : candidates;

      final filteredSelections = LinkedHashSet<String>.from(
        _selectedTexts.where(limitedCandidates.contains),
      );
      if (filteredSelections.isEmpty && limitedCandidates.isNotEmpty) {
        filteredSelections.add(limitedCandidates.first);
      }
      final combined = filteredSelections.join('\n');
      final shouldLock = limitedCandidates.isNotEmpty;

      setState(() {
        _detectedElements = elements;
        _candidateTexts = limitedCandidates;
        _latestImageSize = Size(
          image.width.toDouble(),
          image.height.toDouble(),
        );
        _latestImageRotation = InputImageRotationValue.fromRawValue(
          description.sensorOrientation,
        );
        _selectedTexts = filteredSelections;
        _detectedTextsLocked = shouldLock;
        if (shouldLock) {
          _manualController.value = TextEditingValue(
            text: combined,
            selection: TextSelection.collapsed(offset: combined.length),
          );
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _detectedElements = const [];
      });
    } finally {
      _lastDetection = DateTime.now();
      _isProcessingImage = false;
    }
  }

  void _toggleSelectedText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    setState(() {
      final updated = LinkedHashSet<String>.from(_selectedTexts);
      if (updated.contains(trimmed)) {
        updated.remove(trimmed);
      } else {
        updated.add(trimmed);
      }
      _selectedTexts = updated;
      final combined = _combinedSelectedText;
      _manualController.value = TextEditingValue(
        text: combined,
        selection: TextSelection.collapsed(offset: combined.length),
      );
      _clearLookupState();
    });
  }

  void _handlePreviewTap(TapUpDetails details, Size size) {
    final controller = _controller;
    final imageSize = _latestImageSize;
    final rotation = _latestImageRotation;
    if (controller == null || imageSize == null || rotation == null) {
      return;
    }

    for (final element in _detectedElements) {
      final mappedRect = _mapBoundingBox(
        boundingBox: element.boundingBox,
        widgetSize: size,
        imageSize: imageSize,
        rotation: rotation,
        lensDirection: controller.description.lensDirection,
      );
      if (mappedRect.contains(details.localPosition)) {
        _toggleSelectedText(element.text);
        return;
      }
    }
  }

  void _clearLookupState() {
    _matchedProduct = null;
    _lookupMatchFound = null;
    _lookupMatchScore = null;
    _lookupRequestedName = null;
    _responseError = null;
    _isAwaitingLookup = false;
  }

  void _unlockDetections() {
    setState(() {
      _detectedTextsLocked = false;
      _detectedElements = const [];
      _candidateTexts = const [];
      _selectedTexts = <String>{};
      _manualController.clear();
      _clearLookupState();
    });
  }

  Future<void> _sendSelectedText() async {
    final client = _mqttClient;
    if (client == null || _selectedTexts.isEmpty) {
      return;
    }

    final connection = client.connectionStatus?.state;
    if (connection != MqttConnectionState.connected) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('MQTT broker not connected.')),
      );
      return;
    }

    final combinedText = _combinedSelectedText;
    setState(() {
      _isAwaitingLookup = true;
      _responseError = null;
      _lookupMatchFound = null;
      _lookupMatchScore = null;
      _matchedProduct = null;
      _lookupRequestedName = combinedText;
    });

    final payload = jsonEncode({
      'timestamp': DateTime.now().toIso8601String(),
      'texts': _selectedTexts.toList(),
      'combinedText': combinedText,
    });

    final builder = MqttClientPayloadBuilder()..addString(payload);

    try {
      client.publishMessage(
        'lift/lobby/packages/check',
        MqttQos.atLeastOnce,
        builder.payload!,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Inventory check sent (${_selectedTexts.length} text(s)).',
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _isAwaitingLookup = false;
        });
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to send message: $error')));
    }
  }

  Future<void> _sendPrintJob() async {
    final client = _mqttClient;
    final productCode = _matchedProductCode;
    final productName = _matchedProductName;
    if (client == null || productCode == null) {
      return;
    }

    final connection = client.connectionStatus?.state;
    if (connection != MqttConnectionState.connected) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('MQTT broker not connected.')),
      );
      return;
    }

    final payload = jsonEncode({
      'timestamp': DateTime.now().toIso8601String(),
      'productName': productName ?? _lookupRequestedName ?? productCode,
      'productCode': productCode,
      if (_lookupRequestedName != null) 'requestedName': _lookupRequestedName,
      if (_matchedProduct != null) 'product': _matchedProduct,
    });

    final builder = MqttClientPayloadBuilder()..addString(payload);

    try {
      client.publishMessage(
        'lift/lobby/packages/print',
        MqttQos.atLeastOnce,
        builder.payload!,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Sent print job for ${productName ?? productCode} to lift/lobby/packages/print',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send print job: $error')),
      );
    }
  }

  Color _mqttStatusColor() {
    switch (_mqttState) {
      case _MqttConnectionState.connected:
        return Colors.green;
      case _MqttConnectionState.connecting:
        return Colors.orange;
      case _MqttConnectionState.error:
        return Colors.red;
      case _MqttConnectionState.disconnected:
        return Colors.grey;
    }
  }

  String _mqttStatusLabel() {
    switch (_mqttState) {
      case _MqttConnectionState.connected:
        return 'Connected';
      case _MqttConnectionState.connecting:
        return 'Connecting…';
      case _MqttConnectionState.error:
        return 'Error';
      case _MqttConnectionState.disconnected:
        return 'Disconnected';
    }
  }

  bool get _hasInventoryAccess =>
      _mqttState == _MqttConnectionState.connected;

  IconData _inventoryIcon() =>
      _hasInventoryAccess ? Icons.inventory_2 : Icons.inventory_2_outlined;

  Color _inventoryStatusColor() =>
      _hasInventoryAccess ? Colors.green : Colors.red;

  String _inventoryStatusLabel() =>
      _hasInventoryAccess ? 'Available' : 'Unavailable';

  bool get _canSend =>
      _mqttState == _MqttConnectionState.connected && _selectedTexts.isNotEmpty;
  bool get _canPrint =>
      _mqttState == _MqttConnectionState.connected &&
      _matchedProductCode != null;

  Widget _buildBody(BuildContext context) {
    if (_cameraPermission == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_cameraPermission!.isDenied || _cameraPermission!.isPermanentlyDenied) {
      return _PermissionPrompt(
        status: _cameraPermission!,
        onRequest: _requestPermissionAndInitialize,
      );
    }

    if (_cameraError != null) {
      return _ErrorState(message: _cameraError!);
    }

    final controller = _controller;
    if (_initializingController ||
        controller == null ||
        !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CameraPreview(controller),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final size = Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      );
                      return GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTapUp: (details) => _handlePreviewTap(details, size),
                        child: CustomPaint(
                          painter: _TextDetectionsPainter(
                            elements: _detectedElements,
                            imageSize: _latestImageSize,
                            rotation: _latestImageRotation,
                            lensDirection: controller.description.lensDirection,
                            selectedTexts: _selectedTexts,
                          ),
                        ),
                      );
                    },
                  ),
                  if (_detectedElements.isEmpty)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        color: Colors.black54,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: const Text(
                          'Point at text and tap a highlight to select it.',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: _mqttStatusColor(),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'MQTT: ${_mqttStatusLabel()}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(
                    _inventoryIcon(),
                    color: _inventoryStatusColor(),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Inventory: ${_inventoryStatusLabel()}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ],
          ),
          if (_mqttError != null) ...[
            const SizedBox(height: 4),
            Text(
              _mqttError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_isAwaitingLookup) ...[
            const SizedBox(height: 8),
            Row(
              children: const [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('Checking product match…'),
              ],
            ),
          ],
          if (_responseError != null) ...[
            const SizedBox(height: 8),
            Text(
              _responseError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ] else if (_lookupMatchFound != null && !_isAwaitingLookup) ...[
            const SizedBox(height: 12),
            _buildMatchResultCard(context),
          ],
          const SizedBox(height: 16),
          if (_candidateTexts.isNotEmpty) ...[
            Text(
              'Detected text',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children:
                  _candidateTexts
                      .map(
                        (text) => FilterChip(
                          label: Text(text),
                          selected: _selectedTexts.contains(text),
                          onSelected: (_) => _toggleSelectedText(text),
                        ),
                      )
                      .toList(),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child:
                  _detectedTextsLocked
                      ? TextButton.icon(
                        onPressed: _unlockDetections,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Scan again'),
                      )
                      : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 8),
                          Text('Scanning for text…'),
                        ],
                      ),
            ),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _manualController,
            decoration: const InputDecoration(
              labelText: 'Selected text(s)',
              hintText: 'Tap highlights or type your own text (one per line)',
            ),
            maxLines: null,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            onChanged: (value) {
              final tokens = value
                  .split('\n')
                  .map((line) => line.trim())
                  .where((line) => line.isNotEmpty);
              setState(() {
                _selectedTexts = LinkedHashSet<String>.from(tokens);
                _clearLookupState();
              });
            },
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _canSend ? _sendSelectedText : null,
            icon: const Icon(Icons.inventory_2),
            label: const Text('Check Inventory'),
          ),
          if (_selectedTexts.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              'Selected texts',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _selectedTexts
                  .map(
                    (text) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: SelectableText(
                        text,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _canPrint ? _sendPrintJob : null,
              icon: const Icon(Icons.print),
              label: const Text('Print Label'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMatchResultCard(BuildContext context) {
    final matchFound = _lookupMatchFound ?? false;
    final theme = Theme.of(context);
    final productName = _matchedProductName;
    final productCode = _matchedProductCode;
    final matchScore = _lookupMatchScore;
    final requested = _lookupRequestedName;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: theme.colorScheme.surfaceContainerHighest,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            matchFound ? 'Product match found' : 'No matching product',
            style: theme.textTheme.titleSmall,
          ),
          if (requested != null) ...[
            const SizedBox(height: 4),
            Text('Requested: $requested'),
          ],
          if (matchFound && productName != null) ...[
            const SizedBox(height: 4),
            Text('Name: $productName'),
          ],
          if (matchFound && productCode != null) ...[
            const SizedBox(height: 4),
            Text('Product code: $productCode'),
          ],
          if (matchScore != null) ...[
            const SizedBox(height: 4),
            Text('Match score: ${matchScore.toStringAsFixed(2)}'),
          ],
        ],
      ),
    );
  }
}

class BarcodeScanTab extends StatefulWidget {
  const BarcodeScanTab({super.key});

  @override
  State<BarcodeScanTab> createState() => _BarcodeScanTabState();
}

class _BarcodeScanTabState extends State<BarcodeScanTab>
    with WidgetsBindingObserver {
  late final ms.MobileScannerController _controller;
  final LinkedHashMap<String, DateTime> _recentCaptures = LinkedHashMap();
  static const Duration _displayDuration = Duration(seconds: 4);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = ms.MobileScannerController(
      detectionSpeed: ms.DetectionSpeed.noDuplicates,
      facing: ms.CameraFacing.back,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _controller.start();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _controller.stop();
        break;
    }
  }

  void _handleDetection(ms.BarcodeCapture capture) {
    final now = DateTime.now();
    final updated = LinkedHashMap<String, DateTime>.from(_recentCaptures);
    var changed = false;

    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value == null || value.isEmpty) continue;
      if (updated.containsKey(value)) {
        updated.remove(value);
      }
      updated[value] = now;
      changed = true;
    }

    final removals = <String>[];
    updated.forEach((code, timestamp) {
      if (now.difference(timestamp) > _displayDuration) {
        removals.add(code);
      }
    });

    if (removals.isNotEmpty) {
      changed = true;
      for (final code in removals) {
        updated.remove(code);
      }
    }

    if (changed && !_mapsEqual(_recentCaptures, updated)) {
      setState(() {
        _recentCaptures
          ..clear()
          ..addAll(updated);
      });
    }
  }

  void _clearDetections() {
    setState(() => _recentCaptures.clear());
  }

  Future<void> _toggleTorch() async {
    final torchState = _controller.value.torchState;
    if (torchState == ms.TorchState.unavailable) {
      return;
    }
    await _controller.toggleTorch();
  }

  Future<void> _switchCamera() async {
    await _controller.switchCamera();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final visibleBarcodes =
        _recentCaptures.entries
            .where((entry) => now.difference(entry.value) <= _displayDuration)
            .map((entry) => entry.key)
            .toList();

    return Stack(
      fit: StackFit.expand,
      children: [
        ms.MobileScanner(
          controller: _controller,
          onDetect: _handleDetection,
          errorBuilder: (context, error, child) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Camera error: ${error.errorCode.name}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 16,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          },
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    ValueListenableBuilder<ms.MobileScannerState>(
                      valueListenable: _controller,
                      builder: (context, state, _) {
                        final hasTorch =
                            state.torchState != ms.TorchState.unavailable;
                        final enabled = state.torchState == ms.TorchState.on;
                        return IconButton.filledTonal(
                          onPressed: hasTorch ? _toggleTorch : null,
                          icon: Icon(
                            enabled ? Icons.flash_on : Icons.flash_off,
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: _switchCamera,
                      icon: const Icon(Icons.cameraswitch),
                    ),
                  ],
                ),
                const Spacer(),
                _BarcodeResultsOverlay(
                  barcodes: visibleBarcodes,
                  onClear: _clearDetections,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _BarcodeResultsOverlay extends StatelessWidget {
  const _BarcodeResultsOverlay({required this.barcodes, required this.onClear});

  final List<String> barcodes;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withAlpha((0.55 * 255).round()),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child:
          barcodes.isEmpty
              ? const Text(
                'Aim the camera at a barcode or QR code to see the value here.',
                style: TextStyle(color: Colors.white),
              )
              : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Live results',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      TextButton(
                        onPressed: onClear,
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ...barcodes.map(
                    (code) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        code,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
    );
  }
}

class _TextDetectionsPainter extends CustomPainter {
  _TextDetectionsPainter({
    required this.elements,
    required this.imageSize,
    required this.rotation,
    required this.lensDirection,
    required this.selectedTexts,
  });

  final List<_DetectedTextElement> elements;
  final Size? imageSize;
  final InputImageRotation? rotation;
  final CameraLensDirection lensDirection;
  final Set<String> selectedTexts;

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize == null || rotation == null) return;

    final defaultPaint =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.greenAccent;
    final selectedPaint =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = Colors.orangeAccent;
    final backgroundPaint =
        Paint()
          ..style = PaintingStyle.fill
          ..color = Colors.black.withAlpha((0.45 * 255).round());

    for (final element in elements) {
      final rect = _mapBoundingBox(
        boundingBox: element.boundingBox,
        widgetSize: size,
        imageSize: imageSize!,
        rotation: rotation!,
        lensDirection: lensDirection,
      );

      final paint =
          selectedTexts.contains(element.text) ? selectedPaint : defaultPaint;
      canvas.drawRect(rect, paint);

      final textPainter = TextPainter(
        text: TextSpan(
          text: element.text,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: rect.width);

      final labelRect = Rect.fromLTWH(
        rect.left,
        rect.top - textPainter.height - 4,
        textPainter.width + 8,
        textPainter.height + 4,
      );

      final adjustedLabelRect =
          labelRect.top < 0
              ? labelRect.shift(Offset(0, rect.height - labelRect.height))
              : labelRect;

      canvas.drawRRect(
        RRect.fromRectAndRadius(adjustedLabelRect, const Radius.circular(4)),
        backgroundPaint,
      );
      textPainter.paint(
        canvas,
        Offset(adjustedLabelRect.left + 4, adjustedLabelRect.top + 2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TextDetectionsPainter oldDelegate) {
    return oldDelegate.elements != elements ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.rotation != rotation ||
        !_setsEqual(oldDelegate.selectedTexts, selectedTexts);
  }
}

bool _setsEqual<T>(Set<T> a, Set<T> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (final value in a) {
    if (!b.contains(value)) {
      return false;
    }
  }
  return true;
}

bool _mapsEqual<K, V>(Map<K, V> a, Map<K, V> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

InputImage? buildInputImageFromCameraImage(
  CameraImage image,
  CameraDescription description,
) {
  final rotation = InputImageRotationValue.fromRawValue(
    description.sensorOrientation,
  );
  if (rotation == null) {
    return null;
  }

  late final Uint8List bytes;
  late final InputImageFormat format;
  switch (image.format.group) {
    case ImageFormatGroup.yuv420:
      format = InputImageFormat.nv21;
      bytes = _convertYuv420ToNv21(image);
      break;
    case ImageFormatGroup.bgra8888:
      format = InputImageFormat.bgra8888;
      bytes = image.planes.first.bytes;
      break;
    default:
      return null;
  }

  final metadata = InputImageMetadata(
    size: Size(image.width.toDouble(), image.height.toDouble()),
    rotation: rotation,
    format: format,
    bytesPerRow: image.planes.first.bytesPerRow,
  );

  return InputImage.fromBytes(bytes: bytes, metadata: metadata);
}

Uint8List _convertYuv420ToNv21(CameraImage image) {
  final yPlane = image.planes[0];
  final uPlane = image.planes[1];
  final vPlane = image.planes[2];

  final width = image.width;
  final height = image.height;
  final uvRowStride = uPlane.bytesPerRow;
  final uvPixelStride = uPlane.bytesPerPixel ?? 1;

  final int ySize = width * height;
  final int uvSize = ySize ~/ 2;
  final buffer = Uint8List(ySize + uvSize);

  buffer.setRange(0, ySize, yPlane.bytes);

  var uvIndex = ySize;
  for (var row = 0; row < height ~/ 2; row++) {
    final rowOffset = row * uvRowStride;
    for (var col = 0; col < width ~/ 2; col++) {
      final offset = rowOffset + col * uvPixelStride;
      if (offset >= vPlane.bytes.length || offset >= uPlane.bytes.length) {
        continue;
      }
      if (uvIndex + 1 >= buffer.length) {
        break;
      }
      buffer[uvIndex++] = vPlane.bytes[offset];
      buffer[uvIndex++] = uPlane.bytes[offset];
    }
  }

  return buffer;
}

Rect _mapBoundingBox({
  required Rect boundingBox,
  required Size widgetSize,
  required Size imageSize,
  required InputImageRotation rotation,
  required CameraLensDirection lensDirection,
}) {
  final mirror = lensDirection == CameraLensDirection.front;

  double translateX(double x) {
    late double result;
    switch (rotation) {
      case InputImageRotation.rotation90deg:
        result = x / imageSize.height * widgetSize.width;
        break;
      case InputImageRotation.rotation270deg:
        result = widgetSize.width - x / imageSize.height * widgetSize.width;
        break;
      case InputImageRotation.rotation180deg:
        result = widgetSize.width - x / imageSize.width * widgetSize.width;
        break;
      case InputImageRotation.rotation0deg:
        result = x / imageSize.width * widgetSize.width;
        break;
    }
    if (mirror) {
      return widgetSize.width - result;
    }
    return result;
  }

  double translateY(double y) {
    switch (rotation) {
      case InputImageRotation.rotation90deg:
        return y / imageSize.width * widgetSize.height;
      case InputImageRotation.rotation270deg:
        return widgetSize.height - y / imageSize.width * widgetSize.height;
      case InputImageRotation.rotation180deg:
        return widgetSize.height - y / imageSize.height * widgetSize.height;
      case InputImageRotation.rotation0deg:
        return y / imageSize.height * widgetSize.height;
    }
  }

  final left = translateX(boundingBox.left);
  final right = translateX(boundingBox.right);
  final top = translateY(boundingBox.top);
  final bottom = translateY(boundingBox.bottom);

  return Rect.fromLTRB(
    math.min(left, right),
    math.min(top, bottom),
    math.max(left, right),
    math.max(top, bottom),
  );
}

class _PermissionPrompt extends StatelessWidget {
  const _PermissionPrompt({required this.status, required this.onRequest});

  final PermissionStatus status;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final permanentlyDenied = status.isPermanentlyDenied;
    return Center(
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.camera_alt, size: 48),
              const SizedBox(height: 16),
              Text(
                'Camera permission is required to capture product photos.',
                style: Theme.of(context).textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed:
                    permanentlyDenied
                        ? () async {
                          await openAppSettings();
                        }
                        : onRequest,
                child: Text(
                  permanentlyDenied ? 'Open Settings' : 'Grant Permission',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          style: TextStyle(
            color: Theme.of(context).colorScheme.error,
            fontSize: 16,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
