
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../core/finance/expense_draft.dart';
import '../../core/finance/receipt_engine.dart';
import '../../core/finance/split_rules.dart';
import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../data/models.dart';
import '../../ui/components.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';
import '../movements/draft_mapper.dart';

const _maxBytes = 10 * 1024 * 1024;

class ReceiptCaptureScreen extends ConsumerStatefulWidget {
  const ReceiptCaptureScreen({super.key, this.source});
  final String? source;
  @override
  ConsumerState<ReceiptCaptureScreen> createState() => _ReceiptCaptureScreenState();
}

class _ReceiptCaptureScreenState extends ConsumerState<ReceiptCaptureScreen> with BusyState {
  Uint8List? _bytes;
  String _mime = 'image/jpeg';
  img.Image? _image;
  int _rotation = 0;
  bool _enhance = false;
  RangeValues _cropX = const RangeValues(0, 1);
  RangeValues _cropY = const RangeValues(0, 1);
  bool _showCrop = false;
  String? _workspaceId;
  String? _status;
  ExpenseDraft? _result;
  List<String> _warnings = const [];
  String? _legibility;

  @override
  void initState() {
    super.initState();
    if (widget.source != null) WidgetsBinding.instance.addPostFrameCallback((_) => _pick(widget.source!));
  }

  Future<void> _pick(String source) async {
    try {
      Uint8List? bytes;
      var mime = 'image/jpeg';
      if (source == 'pdf') {
        final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['pdf']);
        bytes = files.isEmpty ? null : await files.single.readAsBytes();
        mime = 'application/pdf';
      } else {
        // imageQuality forces a JPEG re-encode (HEIC photos become JPEG).
        final f = await ImagePicker().pickImage(source: source == 'camera' ? ImageSource.camera : ImageSource.gallery,
            imageQuality: 88, maxWidth: 2600, maxHeight: 2600);
        bytes = await f?.readAsBytes();
      }
      if (bytes == null) return;
      if (bytes.length > _maxBytes) {
        setState(() => _status = 'El archivo supera 10 MB. Elige uno más liviano.');
        return;
      }
      img.Image? decoded;
      if (mime != 'application/pdf') {
        decoded = await compute(img.decodeImage, bytes);
        if (decoded == null) {
          setState(() => _status = 'No pudimos abrir la imagen. Prueba con otra foto en JPG o PNG.');
          return;
        }
        if (bytes[0] == 0x89) mime = 'image/png';
      }
      setState(() {
        _bytes = bytes;
        _mime = mime;
        _image = decoded;
        _rotation = 0;
        _enhance = false;
        _cropX = const RangeValues(0, 1);
        _cropY = const RangeValues(0, 1);
        _status = null;
        _result = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _status = source == 'camera'
            ? 'No pudimos abrir la cámara. Revisa el permiso de cámara en los ajustes del dispositivo.'
            : 'No pudimos abrir el archivo.');
      }
    }
  }

  /// Applies rotate / crop / enhance and returns the bytes to upload.
  Future<Uint8List> _processed() async {
    if (_image == null) return _bytes!;
    final params = (_image!, _rotation, _cropX, _cropY, _enhance);
    return compute(_applyEdits, params);
  }

  Future<void> _process() async {
    final spaces = await ref.read(workspacesProvider.future);
    final me = ref.read(currentUserIdProvider)!;
    final ws = spaces.firstWhere((w) => w.id == (_workspaceId ?? spaces.firstWhere((w) => w.isPersonal).id));
    await runBusy(() async {
      setState(() => _status = 'Preparando imagen…');
      final bytes = await _processed();
      final mime = _image != null ? 'image/jpeg' : _mime;
      setState(() => _status = 'Subiendo de forma privada…');
      final path = await ref.read(transactionRepositoryProvider).uploadReceipt(ws.id, bytes, mime);
      final members = await ref.read(membersProvider(ws.id).future);
      final cats = await ref.read(categoriesProvider.future);
      final caps = await ref.read(aiCapabilitiesProvider.future);
      final draft = newDraft(ws: ws, me: me, members: members, source: TxSource.receipt)
        ..description = 'Compra'
        ..receipt = ReceiptDraft(storagePath: path, mimeType: mime, extractionStatus: 'manual');
      if (!ws.isPersonal) draft.rule = const ByItemSplit();
      var warnings = <String>[];
      if (caps.receiptExtraction) {
        setState(() => _status = 'Leyendo la factura…');
        try {
          final r = await ref.read(aiRepositoryProvider).extractReceipt(path);
          warnings = _applyExtraction(draft, r.extraction, r.provider, ws, me, members, cats);
          _legibility = r.extraction['legibility'] as String?;
        } catch (e) {
          warnings = ['La lectura automática falló. Escribe las líneas manualmente; la imagen ya quedó adjunta.'];
          draft.receipt!.extractionStatus = 'failed';
        }
      } else {
        warnings = ['La lectura automática de facturas no está configurada en el servidor. La imagen quedó adjunta: '
            'escribe el total y, si quieres, las líneas.'];
        draft.receipt!.extractionStatus = 'not_configured';
      }
      setState(() {
        _result = draft;
        _warnings = warnings;
        _status = null;
      });
    }, onError: (e) {
      setState(() => _status = null);
      showFailure(context, e);
    });
  }

  List<String> _applyExtraction(ExpenseDraft d, Map<String, dynamic> x, String provider, Workspace ws, String me,
      List<Member> members, List<Category> cats) {
    final warnings = <String>[...((x['warnings'] as List?) ?? const []).cast<String>()];
    final active = members.where((m) => m.active).map((m) => m.userId).toList();
    final r = d.receipt!;
    int? i(String k) => (x[k] as num?)?.toInt();
    r
      ..merchantName = x['merchant_name'] as String?
      ..merchantTaxId = x['merchant_tax_id'] as String?
      ..invoiceNumber = x['invoice_number'] as String?
      ..issuedOn = DateTime.tryParse(x['issued_on'] as String? ?? '')
      ..printedSubtotalMinor = i('printed_subtotal_minor')
      ..printedTotalMinor = i('printed_total_minor')
      ..discountMinor = i('discount_minor') ?? 0
      ..taxMinor = i('tax_minor') ?? 0
      ..taxesIncluded = x['taxes_included'] as bool? ?? true
      ..tipMinor = i('tip_minor') ?? 0
      ..extractionStatus = 'completed'
      ..extractionProvider = provider;
    if (x['taxes_included'] == null && r.taxMinor > 0) {
      warnings.add('No se pudo saber si el IVA está incluido en los precios. Revísalo.');
    }
    final items = ((x['items'] as List?) ?? const []).cast<Map>();
    var unread = 0;
    final confidences = <double>[];
    final catCount = <String, int>{};
    for (final it in items) {
      final total = (it['line_total_minor'] as num?)?.toInt();
      if (total == null) {
        unread++;
        continue;
      }
      final catId = cats.where((Category c) => c.systemKey == it['category_key']).firstOrNull?.id;
      if (catId != null) catCount[catId] = (catCount[catId] ?? 0) + 1;
      final conf = (it['confidence'] as num?)?.toDouble() ?? 0;
      confidences.add(conf);
      final q = (it['quantity'] as num?);
      r.lines.add(ReceiptLine(
        description: it['description'] as String,
        rawText: it['raw_text'] as String?,
        quantityMilli: q == null ? 1000 : (q * 1000).round(),
        unitPriceMinor: (it['unit_price_minor'] as num?)?.toInt(),
        lineDiscountMinor: (it['line_discount_minor'] as num?)?.toInt() ?? 0,
        lineTotalMinor: total,
        categoryId: catId,
        confidence: conf,
        rule: ws.isPersonal ? SingleSplit(me) : EqualSplit(active),
      ));
    }
    if (unread > 0) warnings.add('$unread línea(s) no tenían un valor legible y no se agregaron. Añádelas si corresponde.');
    if (confidences.isNotEmpty) r.extractionConfidence = confidences.reduce((a, b) => a + b) / confidences.length;
    d
      ..totalMinor = r.printedTotalMinor ?? (r.lines.isEmpty ? null : r.computedTotal)
      ..merchant = r.merchantName
      ..description = r.merchantName ?? 'Compra'
      ..occurredOn = r.issuedOn ?? d.occurredOn
      ..categoryId = catCount.isEmpty ? null : (catCount.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    if (x['payment_method'] != null && d.payments.isNotEmpty) d.payments.first.method = x['payment_method'] as String;
    if (r.printedTotalMinor == null) warnings.add('No se leyó el total impreso: confirma el total pagado.');
    if (r.lines.isEmpty && !ws.isPersonal) d.rule = EqualSplit(active);
    return warnings;
  }

  @override
  Widget build(BuildContext context) {
    final spaces = (ref.watch(workspacesProvider).value ?? const <Workspace>[]).where((w) => w.canWrite).toList();
    _workspaceId ??= spaces.where((w) => w.isPersonal).firstOrNull?.id;

    return Scaffold(
      appBar: AppBar(title: const Text('Factura')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (_bytes == null) ...[
          const EmptyState(compact: true, icon: Icons.document_scanner_outlined, title: 'Adjunta la factura',
              message: 'Toma una foto nítida, con buena luz y la factura completa. También puedes elegir una imagen o un PDF.'),
          Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.center, children: [
            if (!kIsWeb) FilledButton.icon(onPressed: () => _pick('camera'), icon: const Icon(Icons.photo_camera_outlined), label: const Text('Cámara')),
            OutlinedButton.icon(onPressed: () => _pick('gallery'), icon: const Icon(Icons.photo_library_outlined), label: const Text('Galería')),
            OutlinedButton.icon(onPressed: () => _pick('pdf'), icon: const Icon(Icons.picture_as_pdf_outlined), label: const Text('PDF')),
          ]),
        ],
        if (_status != null) ...[const SizedBox(height: 12), Notice(message: _status!)],
        if (_bytes != null && _result == null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(NexoTokens.radiusM),
            child: _image == null
                ? Container(height: 160, color: context.nexo.surfaceSoft, child: const Center(child: Icon(Icons.picture_as_pdf_outlined, size: 48)))
                : _Preview(bytes: _bytes!, rotation: _rotation, cropX: _cropX, cropY: _cropY, enhance: _enhance,
                    aspect: _rotation % 180 == 0 ? _image!.width / _image!.height : _image!.height / _image!.width),
          ),
          if (_image != null) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(onPressed: () => setState(() => _rotation = (_rotation + 90) % 360), icon: const Icon(Icons.rotate_right), label: const Text('Rotar')),
              FilterChip(label: const Text('Recortar'), selected: _showCrop, onSelected: (v) => setState(() => _showCrop = v), avatar: const Icon(Icons.crop, size: 18)),
              FilterChip(label: const Text('Mejorar contraste'), selected: _enhance, onSelected: (v) => setState(() => _enhance = v), avatar: const Icon(Icons.tonality, size: 18)),
            ]),
            if (_showCrop) ...[
              const SizedBox(height: 8),
              Text('Horizontal', style: context.text.labelMedium),
              RangeSlider(values: _cropX, min: 0, max: 1, divisions: 40, labels: const RangeLabels('Izquierda', 'Derecha'),
                  onChanged: (v) => v.end - v.start >= 0.2 ? setState(() => _cropX = v) : null),
              Text('Vertical', style: context.text.labelMedium),
              RangeSlider(values: _cropY, min: 0, max: 1, divisions: 40, labels: const RangeLabels('Arriba', 'Abajo'),
                  onChanged: (v) => v.end - v.start >= 0.2 ? setState(() => _cropY = v) : null),
            ],
          ],
          const SectionTitle('¿A qué espacio pertenece?'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final w in spaces)
              ChoiceChip(avatar: Icon(w.kind.icon, size: 18), label: Text(w.name), selected: _workspaceId == w.id,
                  onSelected: (_) => setState(() => _workspaceId = w.id)),
          ]),
          const SizedBox(height: 8),
          Text('La imagen se guarda en almacenamiento privado; solo la ven los miembros del espacio elegido.',
              style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
          const SizedBox(height: 20),
          FilledButton(onPressed: busy ? null : _process, child: Text(busy ? 'Procesando…' : 'Procesar factura')),
          TextButton(onPressed: busy ? null : () => setState(() => _bytes = null), child: const Text('Elegir otra')),
        ],
        if (_result != null) ...[
          SectionCard(
            title: 'Resultado',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_result!.receipt!.merchantName ?? 'Comercio no identificado', style: context.text.titleMedium),
              if (_result!.receipt!.merchantTaxId != null) Text('NIT ${_result!.receipt!.merchantTaxId}'),
              const SizedBox(height: 8),
              Text('${_result!.receipt!.lines.length} línea(s) detectada(s)'),
              if (_result!.totalMinor != null) Text('Total: ${formatMinor(_result!.totalMinor!, _result!.currency)}'),
              if (_legibility != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Pill(switch (_legibility) { 'good' => 'Buena legibilidad', 'partial' => 'Legibilidad parcial', _ => 'Difícil de leer' },
                      icon: Icons.visibility_outlined, color: _legibility == 'good' ? context.nexo.positive : context.nexo.warning),
                ),
            ]),
          ),
          for (final w in _warnings) Padding(padding: const EdgeInsets.only(top: 8), child: Notice(kind: NoticeKind.warning, message: w)),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => context.pushReplacement('/tx/new', extra: _result), child: const Text('Revisar líneas y repartir')),
        ],
      ]),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.bytes, required this.rotation, required this.cropX, required this.cropY, required this.enhance,
      required this.aspect});
  final Uint8List bytes;
  final double aspect;
  final int rotation;
  final RangeValues cropX;
  final RangeValues cropY;
  final bool enhance;

  @override
  Widget build(BuildContext context) {
    Widget image = Image.memory(bytes, fit: BoxFit.fill, semanticLabel: 'Vista previa de la factura');
    if (enhance) {
      image = ColorFiltered(colorFilter: const ColorFilter.matrix([
        1.4, 0, 0, 0, -40, 0, 1.4, 0, 0, -40, 0, 0, 1.4, 0, -40, 0, 0, 0, 1, 0,
      ]), child: ColorFiltered(colorFilter: const ColorFilter.matrix([
        0.33, 0.33, 0.33, 0, 0, 0.33, 0.33, 0.33, 0, 0, 0.33, 0.33, 0.33, 0, 0, 0, 0, 0, 1, 0,
      ]), child: image));
    }
    return Container(
      color: Colors.black,
      height: 360,
      child: Center(
        child: AspectRatio(
          aspectRatio: aspect,
          child: Stack(fit: StackFit.expand, children: [
            RotatedBox(quarterTurns: rotation ~/ 90, child: image),
            // Crop frame over the exact image bounds: darkens what will be removed.
            CustomPaint(painter: _CropPainter(cropX, cropY)),
          ]),
        ),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.x, this.y);
  final RangeValues x;
  final RangeValues y;

  @override
  void paint(Canvas canvas, Size size) {
    final keep = Rect.fromLTRB(size.width * x.start, size.height * y.start, size.width * x.end, size.height * y.end);
    final shade = Paint()..color = Colors.black.withValues(alpha: 0.55);
    canvas.drawPath(Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRect(keep)), shade);
    canvas.drawRect(keep, Paint()..style = PaintingStyle.stroke..color = Colors.white..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.x != x || old.y != y;
}

Uint8List _applyEdits((img.Image, int, RangeValues, RangeValues, bool) p) {
  var (image, rotation, cx, cy, enhance) = p;
  if (rotation != 0) image = img.copyRotate(image, angle: rotation);
  final x0 = (image.width * cx.start).round();
  final y0 = (image.height * cy.start).round();
  final w = (image.width * (cx.end - cx.start)).round();
  final h = (image.height * (cy.end - cy.start)).round();
  if (w < image.width || h < image.height) image = img.copyCrop(image, x: x0, y: y0, width: w, height: h);
  if (enhance) {
    image = img.grayscale(image);
    image = img.adjustColor(image, contrast: 1.4);
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 85));
}
