import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'settings.dart';
import 'effects.dart';
import 'palette.dart';

const _cyan = Color(0xFF00E5FF);

class _FxSpec {
  final String name, description;
  final bool Function(AppSettings) enabled;
  final void Function(AppSettings, bool) setEnabled;
  final double Function(AppSettings) intensity;
  final void Function(AppSettings, double) setIntensity;
  const _FxSpec(this.name, this.description, this.enabled, this.setEnabled,
      this.intensity, this.setIntensity);
}

final _effects = <_FxSpec>[
  _FxSpec('VHS', 'Scanlines, grain and color separation', (s) => s.fxVhs, (s,v) => s.fxVhs=v, (s)=>s.vhsEffects,(s,v)=>s.vhsEffects=v),
  _FxSpec('Background Motion', 'Drift and beat pulse', (s)=>s.bgEffects,(s,v)=>s.bgEffects=v,(s)=>s.kMotion,(s,v)=>s.kMotion=v),
  _FxSpec('Floating Particles', 'Glowing drifting particles', (s)=>s.particles,(s,v)=>s.particles=v,(s)=>s.kParticles,(s,v)=>s.kParticles=v),
  _FxSpec('Nebula Haze', 'Soft animated clouds', (s)=>s.fxNebula,(s,v)=>s.fxNebula=v,(s)=>s.kNebula,(s,v)=>s.kNebula=v),
  _FxSpec('Perspective Grid', 'Receding grid lines', (s)=>s.fxGrid,(s,v)=>s.fxGrid=v,(s)=>s.kGrid,(s,v)=>s.kGrid=v),
  _FxSpec('Twinkling Stars', 'Subtle star field', (s)=>s.fxStars,(s,v)=>s.fxStars=v,(s)=>s.kStars,(s,v)=>s.kStars=v),
  _FxSpec('Breathing Glow', 'Slowly expanding color glow', (s)=>s.fxGlow,(s,v)=>s.fxGlow=v,(s)=>s.kGlow,(s,v)=>s.kGlow=v),
  _FxSpec('Aurora Sweep', 'Flowing ribbons of light', (s)=>s.fxSweep,(s,v)=>s.fxSweep=v,(s)=>s.kSweep,(s,v)=>s.kSweep=v),
  _FxSpec('Light Rays', 'Radiating beams of light', (s)=>s.fxRays,(s,v)=>s.fxRays=v,(s)=>s.kRays,(s,v)=>s.kRays=v),
  _FxSpec('Beat Ripples', 'Expanding concentric rings', (s)=>s.fxRipples,(s,v)=>s.fxRipples=v,(s)=>s.kRipples,(s,v)=>s.kRipples=v),
  _FxSpec('Water Shimmer', 'Reflective water highlights', (s)=>s.fxWater,(s,v)=>s.fxWater=v,(s)=>s.kWater,(s,v)=>s.kWater=v),
  _FxSpec('Cover Bloom', 'Soft glow around the cover', (s)=>s.fxBloom,(s,v)=>s.fxBloom=v,(s)=>s.kBloom,(s,v)=>s.kBloom=v),
  _FxSpec('Liquid Refraction', 'Animated liquid refraction', (s)=>s.extraFx['Liquid Refraction'] ?? false, (s,v)=>s.extraFx['Liquid Refraction']=v, (s)=>s.extraStrength['Liquid Refraction'] ?? 0.8, (s,v)=>s.extraStrength['Liquid Refraction']=v),
  _FxSpec('Bass Shockwave', 'Animated bass shockwave', (s)=>s.extraFx['Bass Shockwave'] ?? false, (s,v)=>s.extraFx['Bass Shockwave']=v, (s)=>s.extraStrength['Bass Shockwave'] ?? 0.8, (s,v)=>s.extraStrength['Bass Shockwave']=v),
  _FxSpec('Aurora Curtains', 'Animated aurora curtains', (s)=>s.extraFx['Aurora Curtains'] ?? false, (s,v)=>s.extraFx['Aurora Curtains']=v, (s)=>s.extraStrength['Aurora Curtains'] ?? 0.8, (s,v)=>s.extraStrength['Aurora Curtains']=v),
  _FxSpec('Vortex Tunnel', 'Animated vortex tunnel', (s)=>s.extraFx['Vortex Tunnel'] ?? false, (s,v)=>s.extraFx['Vortex Tunnel']=v, (s)=>s.extraStrength['Vortex Tunnel'] ?? 0.8, (s,v)=>s.extraStrength['Vortex Tunnel']=v),
  _FxSpec('Electric Arcs', 'Animated electric arcs', (s)=>s.extraFx['Electric Arcs'] ?? false, (s,v)=>s.extraFx['Electric Arcs']=v, (s)=>s.extraStrength['Electric Arcs'] ?? 0.8, (s,v)=>s.extraStrength['Electric Arcs']=v),
  _FxSpec('Prism Shards', 'Animated prism shards', (s)=>s.extraFx['Prism Shards'] ?? false, (s,v)=>s.extraFx['Prism Shards']=v, (s)=>s.extraStrength['Prism Shards'] ?? 0.8, (s,v)=>s.extraStrength['Prism Shards']=v),
  _FxSpec('Light Trails', 'Animated light trails', (s)=>s.extraFx['Light Trails'] ?? false, (s,v)=>s.extraFx['Light Trails']=v, (s)=>s.extraStrength['Light Trails'] ?? 0.8, (s,v)=>s.extraStrength['Light Trails']=v),
  _FxSpec('Morphing Wireframe', 'Animated morphing wireframe', (s)=>s.extraFx['Morphing Wireframe'] ?? false, (s,v)=>s.extraFx['Morphing Wireframe']=v, (s)=>s.extraStrength['Morphing Wireframe'] ?? 0.8, (s,v)=>s.extraStrength['Morphing Wireframe']=v),
  _FxSpec('Particle Currents', 'Animated particle currents', (s)=>s.extraFx['Particle Currents'] ?? false, (s,v)=>s.extraFx['Particle Currents']=v, (s)=>s.extraStrength['Particle Currents'] ?? 0.8, (s,v)=>s.extraStrength['Particle Currents']=v),
  _FxSpec('Holographic Interference', 'Animated holographic interference', (s)=>s.extraFx['Holographic Interference'] ?? false, (s,v)=>s.extraFx['Holographic Interference']=v, (s)=>s.extraStrength['Holographic Interference'] ?? 0.8, (s,v)=>s.extraStrength['Holographic Interference']=v),
];

/// Selection library backed by the actual effect flags used by the player.
/// Quick overrides never overwrite the user's saved custom combination.
class FxLibraryScreen extends StatefulWidget {
  final AppSettings settings;
  const FxLibraryScreen({super.key, required this.settings});
  @override
  State<FxLibraryScreen> createState() => _FxLibraryScreenState();
}

class _FxLibraryScreenState extends State<FxLibraryScreen> {
  static const _snapshotKey = 'fxLibraryLastCustomV2';
  List<bool>? _lastCustom;
  @override
  void initState() {
    super.initState();
    _load();
  }

  List<bool> get _current => [for (final fx in _effects) fx.enabled(widget.settings)];

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_snapshotKey);
    List<bool>? snapshot;
    if (stored != null) {
      try {
        final parsed = jsonDecode(stored);
        if (parsed is List && parsed.length == _effects.length && parsed.every((v)=>v is bool)) {
          snapshot = parsed.cast<bool>();
        }
      } catch (_) { /* ignore damaged previous snapshot */ }
    }
    if (!mounted) return;
    setState(() => _lastCustom = snapshot ?? _current);
  }

  Future<void> _saveCustom() async {
    final snapshot = _current;
    setState(() => _lastCustom = snapshot);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_snapshotKey, jsonEncode(snapshot));
  }

  void _setOne(int index, bool value) {
    widget.settings.update(() => _effects[index].setEnabled(widget.settings, value));
    _saveCustom();
  }

  void _override(bool enabled) {
    widget.settings.update(() {
      for (final fx in _effects) { fx.setEnabled(widget.settings, enabled); }
      if (enabled) widget.settings.performance = false;
    });
    setState(() {});
  }

  void _restore() {
    final snapshot = _lastCustom;
    if (snapshot == null) return;
    widget.settings.update(() {
      for (var i=0;i<_effects.length;i++) {
        _effects[i].setEnabled(widget.settings, snapshot[i]);
      }
    });
    setState(() {});
  }

  void _detail(int index) {
    final fx = _effects[index];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF151C29),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => AnimatedBuilder(
        animation: widget.settings,
        builder: (context, _) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Expanded(child: Text(fx.name, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w600))),
                Switch(activeColor: _cyan, value: fx.enabled(widget.settings), onChanged: (v)=>_setOne(index,v))]),
              Text(fx.description, style: const TextStyle(color: Colors.white60)),
              const SizedBox(height: 14),
              SizedBox(height: 130, width: double.infinity, child: CustomPaint(painter: _FxPainter(index))),
              const SizedBox(height: 16),
              Text('Intensity ${(fx.intensity(widget.settings)*100).round()}%'),
              Slider(value: fx.intensity(widget.settings).clamp(0.0,1.0).toDouble(), activeColor: _cyan,
                onChanged: (v)=>widget.settings.update(()=>fx.setIntensity(widget.settings,v),persist:false),
                onChangeEnd: (_)=>widget.settings.save()),
              const Text('Preview illustrates the effect shape; actual motion and color appear in Now Playing.',
                style: TextStyle(fontSize: 12,color: Colors.white54)),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = width > 850 ? 4 : width > 510 ? 3 : 2;
    return Scaffold(
      backgroundColor: const Color(0xFF05070D),
      appBar: AppBar(backgroundColor: const Color(0xFF080E18), title: const Text('Background FX Library'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: ()=>Navigator.pop(context))),
      body: AnimatedBuilder(animation: widget.settings, builder: (context, _) {
        final count = _current.where((v)=>v).length;
        return Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(16,12,16,8), child: Column(crossAxisAlignment: CrossAxisAlignment.start,children: [
            const Text('Layer effects over your album-art background', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(onPressed: ()=>_override(true), child: const Text('All On')),
              OutlinedButton(onPressed: ()=>_override(false), child: const Text('All Off')),
              FilledButton.tonal(onPressed: _lastCustom==null?null:_restore, child: const Text('Restore My FX')),
            ]),
            const SizedBox(height: 8),
            Text('$count of ${_effects.length} selected  •  Tap check to toggle; tap preview for intensity',
              style: const TextStyle(fontSize: 12,color: Colors.white54)),
          ])),
          Expanded(child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(12,4,12,24),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columns,
              childAspectRatio: width > 510 ? 1.45 : 1.20, crossAxisSpacing: 10, mainAxisSpacing: 10),
            itemCount: _effects.length,
            itemBuilder: (context,index) {
              final fx = _effects[index];
              final active = fx.enabled(widget.settings);
              return Material(color: const Color(0xFF111927), borderRadius: BorderRadius.circular(13),
                child: InkWell(borderRadius: BorderRadius.circular(13), onTap: ()=>_detail(index),
                  child: Container(decoration: BoxDecoration(borderRadius: BorderRadius.circular(13),
                    border: Border.all(color: active ? _cyan.withOpacity(.8):Colors.white12)),
                    child: Column(children: [
                      Expanded(child: ClipRRect(borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                        child: SizedBox(width: double.infinity,child: CustomPaint(painter: _FxPainter(index))))),
                      Padding(padding: const EdgeInsets.fromLTRB(9,5,4,5), child: Row(children: [
                        Expanded(child: Text(fx.name, maxLines: 1,overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13,fontWeight: FontWeight.w500))),
                        IconButton(visualDensity: VisualDensity.compact, constraints: const BoxConstraints(minWidth: 42,minHeight: 42),
                          tooltip: active?'Disable ${fx.name}':'Enable ${fx.name}',
                          icon: Icon(active?Icons.check_box:Icons.check_box_outline_blank,
                            color:active?_cyan:Colors.white54), onPressed: ()=>_setOne(index,!active)),
                      ])),
                    ])),
                ));
            },
          )),
        ]);
      }),
    );
  }
}

/// Lightweight effect-specific illustrations; the live engine remains the
/// source of truth for animation. No screenshot or network dependencies.
class _FxPainter extends CustomPainter {
  final int effect;
  const _FxPainter(this.effect);
  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRect(r, Paint()..shader=const LinearGradient(begin: Alignment.topLeft,end: Alignment.bottomRight,
      colors:[Color(0xFF102F49),Color(0xFF17162E),Color(0xFF050913)]).createShader(r));
    final c=Offset(size.width*.5,size.height*.52);
    final scale=math.min(size.width,size.height);
    final cyan=const Color(0xFF4CCFF5);
    final pink=const Color(0xFFD57CF2);
    Paint line(Color color,double stroke) => Paint()..color=color..style=PaintingStyle.stroke..strokeWidth=stroke;
    if (effect >= 12) {
      final clock = FxClock()..t = 3.0..bass = 0.7;
      ExpandedFxPainter(mode: effect - 12, clock: clock,
        palette: const ArtPalette(Color(0xFF4CCFF5), Color(0xFFD57CF2), Color(0xFF63F3C8)),
        k: 1, repaint: const AlwaysStoppedAnimation<int>(0)).paint(canvas, size);
      return;
    }
    switch(effect) {
      case 0: // VHS
        for(var y=2.0;y<size.height;y+=6) { canvas.drawLine(Offset(0,y),Offset(size.width,y),line(Colors.white24,.5)); }
        canvas.drawLine(Offset(0,size.height*.45),Offset(size.width,size.height*.45),line(pink,2));
        break;
      case 1: // motion
        for(var i=0;i<5;i++) {canvas.drawArc(Rect.fromCircle(center:c,radius:scale*(.14+i*.12)),.3,2.3,false,line(cyan.withOpacity(.5-i*.07),3));}
        break;
      case 2: // particles
      case 5: // stars
        final rand=math.Random(33);
        for(var i=0;i<32;i++) { final o=Offset(rand.nextDouble()*size.width,rand.nextDouble()*size.height);
          canvas.drawCircle(o,effect==5?1.1:1.3+rand.nextDouble()*3,Paint()..color=(i.isEven?cyan:pink).withOpacity(.25+rand.nextDouble()*.65)); }
        break;
      case 3: // nebula
      case 6: // glow
        for(var i=0;i<4;i++) { final pos=Offset(size.width*(.2+i*.2),size.height*(.35+(i.isEven ? 0.25 : -0.1)));
          canvas.drawCircle(pos,scale*.48,Paint()..shader=RadialGradient(colors:[(i.isEven?cyan:pink).withOpacity(.35),Colors.transparent]).createShader(Rect.fromCircle(center:pos,radius:scale*.48))); }
        break;
      case 4: // grid
        final horizon=size.height*.37;
        for(var i=0;i<=10;i++) {final x=size.width*i/10; canvas.drawLine(Offset(size.width*.5,horizon),Offset(x,size.height),line(cyan.withOpacity(.5),.8));}
        for(var i=1;i<7;i++){final t=i/7;final y=horizon+(size.height-horizon)*t*t;canvas.drawLine(Offset(0,y),Offset(size.width,y),line(cyan.withOpacity(.35),.8));}
        break;
      case 7: // aurora
        for(var i=0;i<5;i++) { final path=Path()..moveTo(-10,size.height*(.25+i*.10))
          ..cubicTo(size.width*.25,-size.height*.12+i*8,size.width*.62,size.height*.85+i*3,size.width+10,size.height*(.15+i*.09));
          canvas.drawPath(path,line((i.isEven?cyan:pink).withOpacity(.5),5)); }
        break;
      case 8: // rays
        for(var i=0;i<18;i++){final angle=i*math.pi/9;canvas.drawLine(c,c+Offset(math.cos(angle),math.sin(angle))*scale*.8,line(cyan.withOpacity(.12+i%3*.08),2.5));}
        break;
      case 9: // ripples
        for(var i=1;i<5;i++){canvas.drawCircle(c,scale*i*.15,line(cyan.withOpacity(1-i*.18),2));}
        break;
      case 10: // water
        for(var i=0;i<10;i++){final y=size.height*(.4+i*.055);canvas.drawLine(Offset(size.width*(.1+i%3*.08),y),Offset(size.width*(.9-i%4*.07),y),line(cyan.withOpacity(.6-i*.04),1.8));}
        break;
      case 11: // bloom
        canvas.drawCircle(c,scale*.3,Paint()..shader=RadialGradient(colors:[cyan.withOpacity(.8),pink.withOpacity(.28),Colors.transparent]).createShader(Rect.fromCircle(center:c,radius:scale*.5)));
        break;
    }
  }
  @override bool shouldRepaint(covariant _FxPainter old)=>old.effect!=effect;
}
