import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const _channel = MethodChannel('render_kernel_flutter/display_frame_rate');
var _nextOwner = 0;

Future<void> _send(String method, Map<String, Object> arguments) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await _channel.invokeMethod<void>(method, arguments);
  } on MissingPluginException {
    // Hosts can use render-kernel without installing the optional window service.
  } on PlatformException catch (error) {
    debugPrint('Display frame rate: $error');
  }
}

/// A window refresh-rate request, independent of the rendering backend.
///
/// Android selects the highest supported refresh rate at or below [targetHz]
/// at the current physical resolution. Concurrent owners share the highest
/// target. Releasing the last owner or backgrounding the Activity restores its
/// previous window preferences. Other platforms retain their display policy.
final class DisplayFrameRateLease {
  DisplayFrameRateLease._(this._owner, this._ready);

  /// Acquires a request without blocking frame construction.
  factory DisplayFrameRateLease.acquire(double targetHz) {
    if (!targetHz.isFinite || targetHz <= 0) {
      throw ArgumentError.value(targetHz, 'targetHz');
    }
    final owner = '${++_nextOwner}';
    return DisplayFrameRateLease._(
      owner,
      _send('request', {'owner': owner, 'targetHz': targetHz}),
    );
  }

  final String _owner;
  final Future<void> _ready;
  Future<void>? _released;

  /// Completes after the platform has received the window preference.
  Future<void> get ready => _ready;

  /// Releases this owner once, including acquisition still in flight.
  Future<void> release() =>
      _released ??= _ready.then((_) => _send('release', {'owner': _owner}));
}

/// Applies a refresh-rate request while this route is current.
///
/// A null target leaves display policy to the host. Text and overview routes
/// can therefore share the same player shell without acquiring a request.
class DisplayFrameRateScope extends StatefulWidget {
  const DisplayFrameRateScope({
    super.key,
    required this.targetHz,
    required this.child,
  });

  final double? targetHz;
  final Widget child;

  @override
  State<DisplayFrameRateScope> createState() => _DisplayFrameRateScopeState();
}

class _DisplayFrameRateScopeState extends State<DisplayFrameRateScope> {
  DisplayFrameRateLease? _lease;
  double? _target;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(DisplayFrameRateScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final route = ModalRoute.of(context);
    final target = route == null || route.isCurrent ? widget.targetHz : null;
    if (target == _target) return;
    final old = _lease;
    _target = target;
    _lease = target == null ? null : DisplayFrameRateLease.acquire(target);
    // Acquire before releasing so adjacent scopes retain a window preference.
    unawaited(old?.release());
  }

  @override
  void dispose() {
    unawaited(_lease?.release());
    _lease = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
