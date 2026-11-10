import 'dart:async';
import 'package:flutter/material.dart';
import 'local_artwork.dart';

/// Index images without making the user wait for the background backup copy.
/// Onboarding must remain recoverable even when SAF folders are slow/unplugged.
Future<void> showLocalArtworkScan(BuildContext context,
    {bool chooseFolder = false}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  var cancelled = false;
  showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Indexing local artwork'),
        content: const Column(mainAxisSize: MainAxisSize.min, children: [
          LinearProgressIndicator(),
          SizedBox(height: 18),
          Text('Scanning music folders and subfolders…'),
          SizedBox(height: 8),
          Text('Artwork backup continues separately once indexing finishes.'),
        ]),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Continue without waiting'),
          ),
        ],
      ),
    ),
  );

  String result;
  try {
    // Android's SAF providers can stall on missing media. Never require a
    // force-stop to escape onboarding if an external drive is slow or absent.
    final count = await LocalArtwork.instance.scan()
        .timeout(const Duration(seconds: 90));
    result = 'Scan complete — $count artwork images indexed. '
        'Saved artwork copies will finish separately.';
  } catch (error) {
    result = 'Artwork scan did not complete: $error. '
        'You can still use VYBE and rescan later in Settings.';
  }
  if (!context.mounted || cancelled) return;
  if (navigator.canPop()) navigator.pop();
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Local artwork'),
      content: Text(result),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
