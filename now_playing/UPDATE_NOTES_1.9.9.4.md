# VYBE 1.9.9.4 – visual FX and near-white text contrast

- Bass Shockwave uses album artwork's actual screen center, mapped into the scaled FX canvas.
- Light Rays: increased beam visibility while retaining feathered angular edges and distance fade.
- Morphing Wireframe: expanded vertical coverage beyond top and bottom viewport edges.
- Orbit: removed the theme's additional full-screen black overlay and gradient; retained localized visualizer glow and user-controlled darkness.
- Breathing Glow, Aura Sweep, and Nebula Haze: increased motion range and speed.
- Canvas Prism Shards fallback: faster motion and thin glass highlights (GPU shader path remains the existing refractive treatment).
- Near-white text contrast: analyzes the already-decoded low-resolution artwork for pale, low-saturation coverage in the common text area, switching common song labels to dark text and a soft light shadow when the coverage threshold is reached. Bright saturated colors retain white text. This is a lightweight artwork-based approximation, not sampling the final animated composited background or per-theme text position.

## Verification
Archive integrity checked. Flutter SDK is not available in this environment, so compilation and on-device rendering are not verified. Existing pre-beta onboarding and Android launch changes retained.
