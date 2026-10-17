import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_esc_pos_usb_universal/flutter_esc_pos_usb_universal.dart';

import 'usb_printer.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'USB Printer Example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  ThermalPosPrinterPageSize _paperSize = ThermalPosPrinterPageSize.size80mm;
  PrinterUsbManager _manager = PrinterUsbManager();
  List<UsbPrinter> _printers = const [];
  List<UsbPrinterNote> _notes = const [];
  UsbBridgeInfo? _bridge;
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    final bridge = kIsWeb ? await _manager.checkBridge() : null;
    final printers = await _manager.listPrinters();
    if (!mounted) return;
    setState(() {
      _bridge = bridge;
      _printers = printers;
      _notes = _manager.notes;
      _busy = false;
    });
    // Keep the selection when the printer is still there.
    final selected = _manager.selectedPrinter?.findIn(printers);
    if (selected != null) {
      _select(selected);
    } else if (printers.isNotEmpty) {
      _select(printers.first);
    }
  }

  void _select(UsbPrinter printer) {
    _manager.selectPrinter(printer);
    // Use the printer's own paper width when its name gives it away.
    final width = printer.paperWidthMm;
    if (width == 58 && _paperSize != ThermalPosPrinterPageSize.size58mm) {
      _setPaperSize(ThermalPosPrinterPageSize.size58mm);
    } else if (width == 80 &&
        _paperSize == ThermalPosPrinterPageSize.size58mm) {
      _setPaperSize(ThermalPosPrinterPageSize.size80mm);
    }
    setState(() {});
  }

  void _setPaperSize(ThermalPosPrinterPageSize size) {
    final printer = _manager.selectedPrinter;
    _manager.dispose();
    _paperSize = size;
    _manager = PrinterUsbManager(printer: printer, paperSize: size);
  }

  Future<void> _choose() async {
    try {
      final printer = await _manager.requestPrinter();
      if (printer != null) await _refresh();
    } on PrinterTransportException catch (e) {
      setState(() => _status = e.result.msg);
    }
  }

  Future<void> _print(Future<PosPrintResult> Function() job) async {
    setState(() {
      _busy = true;
      _status = 'Printing…';
    });
    final result = await job();
    if (!mounted) return;
    setState(() {
      _busy = false;
      final error = _manager.lastError;
      _status = result.isSuccess
          ? 'Printed: ${_manager.lastPrint}'
          : '${result.msg}${error == null ? '' : '\n$error'}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final caps = PrinterUsbManager.capabilities;
    final selected = _manager.selectedPrinter;
    return Scaffold(
      appBar: AppBar(
        title: const Text('USB Printer Example'),
        actions: [
          IconButton(
            tooltip: 'List printers again',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_bridge != null) _BridgeCard(info: _bridge!),
          for (final note in _notes)
            Card(
              color: note.isWarning ? Colors.amber.shade50 : null,
              child: ListTile(
                leading: Icon(
                  note.isWarning
                      ? Icons.warning_amber_rounded
                      : Icons.info_outline,
                ),
                title: SelectableText(note.message),
                subtitle: Text(note.code),
              ),
            ),
          Row(
            children: [
              Text('Printers', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              if (caps.chooser)
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _choose,
                  icon: const Icon(Icons.usb),
                  label: const Text('Choose USB printer'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_printers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                _busy
                    ? 'Looking for printers…'
                    : 'No USB printer found. Plug one in and switch it on, then press refresh.',
                textAlign: TextAlign.center,
              ),
            ),
          RadioGroup<String>(
            groupValue: selected?.id,
            onChanged: (id) => _select(_printers.firstWhere((p) => p.id == id)),
            child: Column(
              children: [
                for (final p in _printers)
                  RadioListTile<String>(
                    value: p.id,
                    title: Text(p.displayName),
                    subtitle: Text(_describe(p)),
                    secondary: Icon(
                      p.isReceiptPrinter ? Icons.receipt_long : Icons.print,
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 32),
          Row(
            children: [
              const Text('Paper'),
              const SizedBox(width: 16),
              SegmentedButton<ThermalPosPrinterPageSize>(
                segments: [
                  for (final size in ThermalPosPrinterPageSize.values)
                    ButtonSegment(value: size, label: Text(size.title)),
                ],
                selected: {_paperSize},
                onSelectionChanged: (s) =>
                    setState(() => _setPaperSize(s.single)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _busy || selected == null
                    ? null
                    : () => _print(
                        () => _manager.printWidget(
                          context,
                          child: TestReceiptWidget(paperSize: _paperSize),
                        ),
                      ),
                icon: const Icon(Icons.image_outlined),
                label: const Text('Print widget receipt'),
              ),
              OutlinedButton.icon(
                onPressed: _busy || selected == null
                    ? null
                    : () => _print(
                        () async => _manager.printTicket(
                          await UsbPrinterTickets.testTicket(_paperSize),
                        ),
                      ),
                icon: const Icon(Icons.text_fields),
                label: const Text('Print text ticket'),
              ),
            ],
          ),
          if (_status != null) ...[
            const SizedBox(height: 16),
            SelectableText(_status!),
          ],
          const SizedBox(height: 24),
          Text(
            'Capabilities: $caps',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  static String _describe(UsbPrinter p) {
    final parts = <String>[
      switch (p.route) {
        UsbPrinterRoute.windowsQueue => 'Installed Windows printer',
        UsbPrinterRoute.webUsb => 'WebUSB',
        UsbPrinterRoute.bridge =>
          p.isQueue ? 'Installed printer (bridge)' : 'USB (bridge)',
        _ => 'USB',
      },
      if (p.commandSet != null) p.commandSet!,
      if (p.paperWidthMm != null) '${p.paperWidthMm} mm',
      if (p.vendorId != null && p.productId != null)
        '${p.vendorId!.toRadixString(16).padLeft(4, '0')}:'
            '${p.productId!.toRadixString(16).padLeft(4, '0')}',
      if (p.queueStatus != null && p.queueStatus != UsbQueueStatus.ready)
        p.queueStatus!.name,
      if (p.isBusy) 'in use',
      if (!p.isAccessible) 'needs permission',
    ];
    return parts.join(' · ');
  }
}

class _BridgeCard extends StatelessWidget {
  const _BridgeCard({required this.info});

  final UsbBridgeInfo info;

  @override
  Widget build(BuildContext context) {
    final (icon, color, text) = switch (info.status) {
      UsbBridgeStatus.ready => (
        Icons.check_circle,
        Colors.green,
        'Local TCP bridge ${info.hostVersion ?? ''} ready (${info.platform ?? '?'})',
      ),
      UsbBridgeStatus.outdated => (
        Icons.system_update,
        Colors.orange,
        'Local TCP bridge ${info.hostVersion ?? ''} is too old for USB printing. Run its installer again.',
      ),
      UsbBridgeStatus.notLinked => (
        Icons.link_off,
        Colors.orange,
        'The Local TCP extension is installed, but its bridge is not. Open the extension to install it.',
      ),
      _ => (
        Icons.extension_off,
        Colors.grey,
        'Local TCP extension not found. Chrome and Edge on Windows and Linux need it for USB '
            'printers: https://chromewebstore.google.com/detail/local-tcp/ngbakchodnmhndnghhejmocfadjfekkf',
      ),
    };
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: SelectableText(text),
      ),
    );
  }
}
