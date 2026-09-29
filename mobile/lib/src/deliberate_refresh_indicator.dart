import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Pull-to-refresh that requires an intentional drag from the top edge.
///
/// Unlike [RefreshIndicator], a short top-edge overscroll cannot arm this
/// control. The user must cross [triggerDistance] and release their finger.
class DeliberateRefreshIndicator extends StatefulWidget {
  const DeliberateRefreshIndicator({
    super.key,
    required this.controller,
    required this.onRefresh,
    required this.child,
    this.enabled = true,
    this.triggerDistance = 120,
  });

  final ScrollController controller;
  final RefreshCallback onRefresh;
  final Widget child;
  final bool enabled;
  final double triggerDistance;

  @override
  State<DeliberateRefreshIndicator> createState() =>
      _DeliberateRefreshIndicatorState();
}

class _DeliberateRefreshIndicatorState
    extends State<DeliberateRefreshIndicator> {
  final GlobalKey<RefreshIndicatorState> _indicatorKey =
      GlobalKey<RefreshIndicatorState>();
  int? _pointer;
  Offset? _dragOrigin;
  double _pullProgress = 0;
  bool _eligible = false;
  bool _refreshing = false;

  bool get _atTop {
    if (!widget.controller.hasClients) {
      return false;
    }
    final position = widget.controller.position;
    return position.pixels <= position.minScrollExtent + 0.5;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_pointer != null || !widget.enabled || _refreshing || !_atTop) {
      return;
    }
    _pointer = event.pointer;
    _dragOrigin = event.position;
    _eligible = true;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || !_eligible) {
      return;
    }
    final origin = _dragOrigin;
    if (origin == null) {
      return;
    }
    final delta = event.position - origin;
    if (delta.distance > 18 && delta.dx.abs() > delta.dy.abs()) {
      _eligible = false;
      _setProgress(0);
      return;
    }
    _setProgress((delta.dy / widget.triggerDistance).clamp(0.0, 1.0));
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) {
      return;
    }
    final shouldRefresh = _eligible && _pullProgress >= 1;
    _resetPull();
    if (shouldRefresh) {
      unawaited(_showRefreshIndicator());
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) {
      _resetPull();
    }
  }

  void _setProgress(double value) {
    final crossedBoundary =
        (value == 0 && _pullProgress != 0) ||
        (value == 1 && _pullProgress != 1);
    if (!crossedBoundary && (value - _pullProgress).abs() < 0.015) {
      return;
    }
    setState(() => _pullProgress = value);
  }

  void _resetPull() {
    final hadProgress = _pullProgress > 0;
    _pointer = null;
    _dragOrigin = null;
    _eligible = false;
    _pullProgress = 0;
    if (hadProgress && mounted) {
      setState(() {});
    }
  }

  Future<void> _showRefreshIndicator() async {
    if (_refreshing || !mounted) {
      return;
    }
    _refreshing = true;
    try {
      unawaited(HapticFeedback.mediumImpact());
      await _indicatorKey.currentState?.show();
    } finally {
      _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _pullProgress >= 1;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: Stack(
        children: <Widget>[
          RefreshIndicator(
            key: _indicatorKey,
            onRefresh: widget.onRefresh,
            notificationPredicate: (_) => false,
            child: widget.child,
          ),
          Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 100),
                opacity: _pullProgress == 0 ? 0 : 1,
                child: Center(
                  child: Material(
                    elevation: 2,
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            ready
                                ? Icons.refresh_rounded
                                : Icons.arrow_downward_rounded,
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          Text(ready ? '松开刷新' : '继续下拉'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
