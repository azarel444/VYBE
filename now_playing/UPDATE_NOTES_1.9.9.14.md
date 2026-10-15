# VYBE v1.9.9.14 — Animated background compile fix

Fixed invalid chaining of `Path.lineTo()` in `lib/template_background.dart` (line 97). Each method now executes separately. No visual behavior was intentionally changed.

Source archive integrity verified; Flutter build not run locally.
