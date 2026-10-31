import 'package:flutter/material.dart';
import 'local_artwork.dart';

/// Visible, non-dismissible scan progress with a persistent result dialog.
Future<void> showLocalArtworkScan(BuildContext context, {bool chooseFolder = false}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text('Indexing local artwork'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          LinearProgressIndicator(),
          SizedBox(height: 18),
          Text('Scanning music folders and subfolders…'),
          SizedBox(height: 8),
          Text('Please wait. This may take longer on large libraries.'),
        ]),
      ),
    ),
  );
  String result;
  try {
    if (chooseFolder) {
      // The folder picker must open before the progress dialog, so this
      // method is only used after a folder was selected in the caller.
      final count = await LocalArtwork.instance.scan();
      result = 'Scan complete — $count artwork images indexed.';
    } else {
      final count = await LocalArtwork.instance.scan();
      result = 'Scan complete — $count artwork images indexed.';
    }
  } catch (e) {
    result = 'Artwork scan failed: $e';
  }
  if (!context.mounted) return;
  navigator.pop();
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Local artwork'),
      content: Text(result),
      actions: [TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: const Text('OK'),
      )],
    ),
  );
}
