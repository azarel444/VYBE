# VYBE — Coverflow Theme Implementation Specification (Landscape First)

## Visual contract: approved Röyksopp / Lost Tapes render
This design is a **live Flutter theme**, not a static recreation or an image used as its background.
Target the supplied landscape reference composition as closely as current track data and the device allow.

### Composition and hierarchy
- Full-bleed artist fanart background, darkened behind artwork, with the existing artist clearlogo (fallback artist text) large at the top center.
- Active album cover centered and front-facing, surrounded by a vivid but carefully controlled illuminated border; the current cover remains the highest-resolution art.
- Distinct cover on each side angled toward the active cover, with **additional** covers behind it, receding in size, perspective, brightness and opacity; draw farthest first, nearest afterward.
- The front cover occludes and shades the rear cover. Keep a narrow edge of each cover behind visible. No identical invented “next” albums.
- Perspective floor below the covers with fine grain / streak texture, dark sheen, luminous contact line, and diffused light pools. Its texture must show **through** translucent reflections.
- The active and visible side covers each reflect directly beneath their own baseline, mirrored correctly with transparency strongest at the contact and gradually decreasing toward the bottom. The existing album-art drop-shadow treatment elsewhere in VYBE is unchanged.
- Thin horizontal waveforms on extreme left and right edges, tinted by active palette.
- Dominant title below the center cover, an angular outlined album-title plaque beneath, unobtrusive progress line beneath. Artist clearlogo remains the largest branding element when present.
- First implement a landscape composition for 16:9 head units (including 1600×900 DeX and ATOTO A5L); preserve visual character in narrower portrait using a scaled/reflowed arrangement, not a distorted horizontal stretch.

### Dynamic color contract
- By default use `NowPlayingScreen._palette`, which derives colors from the current album art (and existing custom accent choices).
- When “Use VYBE palette” is selected, the same glow strokes, floor light, reflections, waveforms, frame trim and plaque outline switch to the VYBE brand colors automatically.
- Do not hard-code orange, pink or any other hue from the approved example. Shadows and dark substrate remain neutral.
- Fanart keeps its original photographic color; colored lighting is a transparent overlay, not a permanent recoloring.

### Real queue, never fabricated
- The phone reads the active Android MediaSession's queue, if published, and determines the true current queue item using activeQueueItemId (fall back to an unambiguous current title match).
- Capture up to three previous and three next entries, each with its real title/artist and available artwork.
- Cache low-resolution side covers; keep the active cover's original high-quality bytes.
- Send descriptors and thumbnails (never audio) via the **existing verified VYBE Connect TCP socket**, keyed to the current song. Reject stale covers after track changes and reconnects.
- When a player publishes no queue (e.g. Spotify under previously tested conditions), remember previously played artwork. Show only confirmed covers. Leave unavailable future positions dark/empty; never pretend upcoming tracks are known.
- If fewer than five covers are available, adapt smoothly without creating fictitious album covers.

### Motion and hardware budget
- Run a short (approximately 400 ms) eased slide/depth transition on genuine track change, not a constant 60fps loop.
- Static covers are repaint boundaries. Side art is decoded at roughly 160–384 px; limit visible cover count and glow blur on the ATOTO A5L / performance mode.
- Floor texture is a lightweight CustomPainter with deterministic short strokes, not a GPU-intensive animated texture. No constant heavy blurs or newly downloaded art per frame.
- Preserve existing VYBE Connect background service, dynamic palette, original reflection/drop shadow in other themes, and all existing controls. No MediaProjection, Wi-Fi-audio streaming, or extra permissions.

### Acceptance checks
1. Landscape centered cover + multiple progressively receding real covers with shadowing.
2. Reflections correctly orient; floor texture remains visible beneath them.
3. Changing album changes **all** accent lights when using artwork palette; VYBE palette preference overrides them all.
4. Fanart and clearlogo remain intact and take proper layering.
5. Current album name and song title retain VYBE hierarchy; no text shrinks or gets clipped on ATOTO.
6. 2.4/5 GHz Wi-Fi Direct tests and synchronized lyric packets remain functional.
7. Songs without a published queue render accurately with no invented next covers.
8. Build succeeds on GitHub Actions, with `now-playing-apks` artifact for device testing.
