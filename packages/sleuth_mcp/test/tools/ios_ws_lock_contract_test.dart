import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

/// Pins the substring contract between `VmBridgeException.message` and
/// the typed `ios_vmservice_busy` / `ios_vmservice_unreachable`
/// `lastError` values surfaced on iOS-direct attach failure. SDK
/// wording changes that drop these substrings trip these assertions
/// rather than silently degrading the typed-error envelope into the
/// generic `bridge connect failed` path.
void main() {
  group('DaemonSession.mapBridgeConnectErrorToLastError', () {
    test('"Connection reset by peer" → ios_vmservice_busy', () {
      final mapped = DaemonSession.mapBridgeConnectErrorToLastError(
        'failed to connect: Connection reset by peer, uri = '
        'http://127.0.0.1:55958/abc=/ws',
      );
      expect(mapped, startsWith('ios_vmservice_busy:'));
      expect(mapped, contains('swipe the app'));
    });

    test(
        '"Connection closed before full header was received" → '
        'ios_vmservice_busy', () {
      final mapped = DaemonSession.mapBridgeConnectErrorToLastError(
        'failed to connect: HttpException: Connection closed before '
        'full header was received, uri = http://127.0.0.1:54628/x=/ws',
      );
      expect(mapped, startsWith('ios_vmservice_busy:'));
    });

    test('"Connection refused" → ios_vmservice_unreachable', () {
      final mapped = DaemonSession.mapBridgeConnectErrorToLastError(
        'failed to connect: SocketException: Connection refused, uri '
        '= http://127.0.0.1:9999/x=/ws',
      );
      expect(mapped, startsWith('ios_vmservice_unreachable:'));
      expect(mapped, contains('mDNS'));
    });

    test('unrelated error → generic bridge connect failed (NOT typed)', () {
      final mapped = DaemonSession.mapBridgeConnectErrorToLastError(
        'failed to connect: TimeoutException: deadline exceeded',
      );
      expect(mapped, startsWith('bridge connect failed:'));
      expect(mapped, isNot(startsWith('ios_vmservice_')));
    });

    test('empty / unknown message → generic mapping', () {
      final mapped = DaemonSession.mapBridgeConnectErrorToLastError('');
      expect(mapped, startsWith('bridge connect failed:'));
    });

    test('"Operation not permitted" → ios_vmservice_unreachable (wireless)',
        () {
      final mapped = DaemonSession.mapBridgeConnectErrorToLastError(
        'failed to connect: SocketException: Connection failed '
        '(OS Error: Operation not permitted, errno = 1), uri = '
        'ws://Pengen.local:55958/abc=/ws',
      );
      expect(mapped, startsWith('ios_vmservice_unreachable:'));
      expect(mapped, contains('Local Network'));
    });

    test('"Network is unreachable" → ios_vmservice_unreachable (wireless)', () {
      final mapped = DaemonSession.mapBridgeConnectErrorToLastError(
        'failed to connect: SocketException: Connection failed '
        '(OS Error: Network is unreachable, errno = 51), uri = '
        'ws://Pengen.local:55958/abc=/ws',
      );
      expect(mapped, startsWith('ios_vmservice_unreachable:'));
      expect(mapped, contains('Wi-Fi'));
    });

    test('"Failed host lookup" → ios_vmservice_unreachable (wireless DNS)', () {
      final mapped = DaemonSession.mapBridgeConnectErrorToLastError(
        'failed to connect: SocketException: Failed host lookup: '
        'Pengen.local',
      );
      expect(mapped, startsWith('ios_vmservice_unreachable:'));
    });
  });
}
