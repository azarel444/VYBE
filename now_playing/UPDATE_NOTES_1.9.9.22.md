# VYBE v1.9.9.22 — Settings organization

- Replaced sprawling choice-chip groups with compact dropdowns (theme, palette, background, blend, visualizer, night mode, launch grace, bar count).
- Reorganized Visuals into Theme & palette, Background, Visualizer, Visual effects, Clock, Performance.
- Moved background contrast alongside background darkness; grouped background source, animation and lighting blend controls.
- Context-aware visualizer and clock settings; irrelevant options hidden when disabled.
- Drive settings separated into artwork/layout and behavior/control sections.
- Existing settings values and persistence mechanisms unchanged.
- All existing backgrounds, FX and Drive behavior preserved.

This is a settings UI pass. Remaining work: landscape flip in non-Drive themes, exact shader blend parity, Drive activity lifecycle, runtime device testing.
