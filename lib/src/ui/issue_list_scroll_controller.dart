import 'package:flutter/widgets.dart';

/// Scroll controller of the overlay's issue list. [keepOffset] records the
/// attached list's offset before the list unmounts; the next list attached
/// starts there, once.
class IssueListScrollController extends ScrollController {
  double? _kept;

  /// The recorded offset, or 0.
  double get keptOffset => _kept ?? 0;

  /// Records the offset of the attached list. With none attached (it
  /// unmounted already, under a page), the offset recorded then stays.
  void keepOffset() {
    if (hasClients && position.hasPixels) _kept = position.pixels;
  }

  void dropKeptOffset() => _kept = null;

  @override
  double get initialScrollOffset => _kept ?? super.initialScrollOffset;

  @override
  void attach(ScrollPosition position) {
    super.attach(position);
    _kept = null;
  }
}
