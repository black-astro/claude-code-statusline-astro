# Single source of truth for the mascot faces.
# Emits: sh strings, ps1 code-point tables, README tables, legend SVGs.
import sys, unicodedata, os

# tier -> [(name, [frames...])]
FACES = {
    'error': [('Oops', ['（；へ；）', '（；ㅅ；）'])],
    'common': [('Kitten', ['（・ω・）', '（－ω－）']), ('Cozy', ['（´ ᴗ ｀）', '（´ ᴖ ｀）']), ('Snooze', ['（ ˘ᴗ˘ ）z', '（ ˘ᴗ˘ ）Z']), ('Whiskers', ['（=・ェ・=）', '（=－ェ－=）']), ('Grin', ['（・∀・）', '（－∀－）']), ('Smiley', ['（˙◡˙）', '（˙‿˙）']), ('Side-eye', ['（￢_￢）', '（￢‿￢）']), ('Bored', ['（´-ι_-｀）', '（´-ι.-｀）']), ('Blank', ['（・_・）', '（・.・）']), ('Smirk', ['（≖‿≖）', '（≖_≖）']), ('Scowl', ['（◣‸◢）', '（◢‸◣）']), ('Pleased', ['（＾ｖ＾）', '（＾ｕ＾）'])],
    'uncommon': [('Giggle', ['（๑˃ᴗ˂）', '（๑˂ᴗ˃）']), ('Rosy', ['（｡•ᴗ•｡）', '（｡•ᴖ•｡）']), ('Beam', ['（^▽^）', '（^∇^）']), ('Bright', ['（◕‿◕）', '（◠‿◠）']), ('Squee', ['（≧Д≦）', '（≧∀≦）']), ('Wink', ['（･ᵕ<）', '（-ᵕ<）']), ('Stare', ['（ㆆ_ㆆ）', '（ㆆ.ㆆ）']), ('Eyeroll', ['（◔_◔）', '（◔‸◔）']), ('Pout', ['（｡>ㅅ<｡）', '（｡>ㅁ<｡）']), ('Hamster', ['（・ㅂ・）', '（－ㅂ－）']), ('Dizzy', ['（＠_＠）', '（＠.＠）']), ('Gasp', ['（⊙o⊙）', '（⊙O⊙）'])],
    'rare': [('Twinkle', ['（･ᴗ･）◇', '（-ᴗ-）◆']), ('Cheer', ['ヽ（•‿•）ノ', 'ヾ（•‿•）ノ']), ('Blossom', ['（◕‿◕）✿', '（◠‿◠）❀']), ('Hooray', ['\\（^o^）/', '\\（^O^）/']), ('Melody', ['（´▽｀）♪', '（´▽｀）♬']), ('Wave', ['（・ω・）ノ', '（－ω－）ノ']), ('Smug', ['（￣ｰ￣）ゞ', '（￣ｰ￣）ゝ']), ('Cool', ['（▼ω▼）b', '（▼ω▼）d']), ('Kiss', ['（´ε｀）♡', '（´ε｀）♥']), ('Scheme', ['（￢‿￢）☆', '（￢‿￢）★']), ('Gunslinger', ['（☞°ヮ°）☞', '（☜°ヮ°）☜']), ('Shrug', ['┐（´～｀）┌', '┐（´〜｀）┌'])],
    'unique': [('Superstar', ['╰（☆▽☆）╯', '╰（★▽★）╯']), ('Jubilee', ['╭（◕ヮ◕）╮', '╭（◠ヮ◠）╮']), ('Lovestruck', ['┗（♡‿♡）┛', '┗（♥‿♥）┛']), ('Dazzle', ['＼（•∇•）／', '＼（•▽•）／']), ('Hurrah', ['⊂（＾ᴗ＾）⊃', '⊂（＾ᴖ＾）⊃']), ('Boss', ['╰（￣ヘ￣）╯', '╰（￣〜￣）╯']), ('Fury', ['┗（╬◣_◢）┛', '┗（╬◢_◣）┛']), ('Skeptic', ['⊂（￢_￢）⊃', '⊂（￢‿￢）⊃']), ('Villain', ['╭（▼ヘ▼）╮', '╭（▼〜▼）╮']), ('Grit', ['＼（⇀‸↼）／', '＼（⇀‿↼）／'])],
    'legend': [
        ('Halo', ['·°⊰ ☆（●ᴗ●）ノ ☆ ⊱°·', '·°⊰ ☆ ヽ（●ᴗ●）☆ ⊱°·', '·°⊰ ☆（●o●）ノ ☆ ⊱°·', '·°⊰ ☆ ヽ（●ᴗ●）☆ ⊱°·']),
        ('Wrath', ['≪◆ °（╬◣_◢）ψ ° ◆≫', '≪◆ ° ψ（◣_◢╬）° ◆≫', '≪◆ °（╬◣o◢）ψ ° ◆≫', '≪◆ ° ψ（◣_◢╬）° ◆≫']),
        ('Overlord', ['《◆ ·（▼_▼）† · ◆》', '《◆ · †（▼_▼）· ◆》', '《◆ ·（▼‿▼）† · ◆》', '《◆ · †（▼_▼）· ◆》']),
        ('Seraph', ['༺° ☆（◕‿◕）♪ ☆ °༻', '༺° ☆ ♪（◕‿◕）☆ °༻', '༺° ☆（◕ᴗ◕）♪ ☆ °༻', '༺° ☆ ♪（◕‿◕）☆ °༻']),
        ('Wyvern', ['⋘° ◆（◈ω◈）ζ ◆ °⋙', '⋘° ◆ ζ（◈ω◈）◆ °⋙', '⋘° ◆（◈▽◈）ζ ◆ °⋙', '⋘° ◆ ζ（◈ω◈）◆ °⋙']),
    ],
    'dev': [('Root', ['｛・ω・｝', '｛－ω－｝']), ('Sudo', ['⟨◕ᴗ◕⟩', '⟨◠ᴗ◠⟩']), ('Kernel', ['［◉_◉］', '［◉‸◉］']), ('Daemon', ['⟨◣_◢⟩', '⟨◢_◣⟩'])]}

# legend index -> palette name, mood-matched
LEGEND_PALETTES = ['dawn', 'ember', 'radiance', 'sapphire', 'emerald']
LEGEND_DESC = {
    'dawn':    '금빛에서 크림색으로',
    'ember':   '진한 붉은색에서 연한 붉은색으로',
    'radiance':'연보라에서 흰빛과 은색으로',
    'sapphire':'파랑에서 연한 하늘색으로',
    'emerald': '초록에서 연한 민트로',
}
# RGB keyframes of each legend ramp. The scripts interpolate them into
# GRADIENT_STEPS cells around a closed loop, so the band flows back into
# itself without a seam.
# One hue family per legend so no two read alike, and no cell darker than a
# relative luminance of 0.07 so every legend stays visible on a black screen:
#   dawn gold, crimson pink, royal tangerine, abyss cyan-ice, amethyst
#   green-to-navy, ember blood red, radiance lavender-silver.
PALETTES = {
    'dawn':    ['8f6508', 'd09a00', 'ffcc33', 'ffe9a3', 'fff8e1'],
    'ember':   ['a82524', 'd63c3c', 'ff6464', 'ff9595', 'ffbdb5'],
    'radiance':['8a78e0', 'bfb2f5', 'ece6ff', 'ffffff', 'd0d5e0', 'a9afc0'],
    'sapphire':['2b4aa8', '3f70e0', '6a9cff', 'a0c4ff', 'd6e6ff'],
    'emerald': ['0f7a4a', '17a86a', '3fd68f', '8ff0c0', 'd0ffe8'],
}
GRADIENT_STEPS = 36

# Unique wears one fixed gradient, lavender to deep purple, stretched across
# the text with no motion: a clear step below legend, a clear step above rare.
UNIQUE_KEYS = ['d2bcff', 'a877ff', '7a3fe6', '4a1a9c']
UNIQUE_STEPS = 8


def ramp_linear(keys, n):
    """n cells from the first keyframe to the last, no loop."""
    m = len(keys)
    rgb = [tuple(int(k[i:i + 2], 16) for i in (0, 2, 4)) for k in keys]
    out = []
    for s in range(n):
        pos = s * (m - 1) / max(n - 1, 1)
        seg = min(int(pos), m - 2)
        t = pos - seg
        a, b = rgb[seg], rgb[seg + 1]
        out.append('#%02x%02x%02x' % tuple(int(a[c] + (b[c] - a[c]) * t + 0.5) for c in range(3)))
    return out


def ramp(keys, n=GRADIENT_STEPS):
    """Same interpolation the scripts use: n cells around a closed loop."""
    m = len(keys)
    rgb = [tuple(int(k[i:i + 2], 16) for i in (0, 2, 4)) for k in keys]
    out = []
    for s in range(n):
        pos = s * m / n
        seg = int(pos)
        t = pos - seg
        a, b = rgb[seg], rgb[(seg + 1) % m]
        out.append('#%02x%02x%02x' % tuple(int(a[c] + (b[c] - a[c]) * t + 0.5) for c in range(3)))
    return out


TIER_ORDER = ['common', 'uncommon', 'rare', 'unique', 'legend']


def cw(ch, amb):
    e = unicodedata.east_asian_width(ch)
    if e in ('W', 'F'):
        return 2
    if e == 'A':
        return amb
    return 1


def width(s, amb=1):
    return sum(cw(c, amb) for c in s)


def validate():
    ok = True
    for tier, faces in FACES.items():
        for name, frames in faces:
            for f in frames:
                assert '|' not in f and '#' not in f and "'" not in f, (tier, name)
                assert all(ord(c) <= 0xFFFF for c in f), (tier, name, 'non-BMP')
            w1 = {width(f, 1) for f in frames}
            w2 = {width(f, 2) for f in frames}
            if len(w1) != 1 or len(w2) != 1:
                ok = False
                print('JITTER', tier, name, [(width(f, 1), width(f, 2)) for f in frames])
    names = [n for t in FACES for n, _ in FACES[t]]
    dup = {n for n in names if names.count(n) > 1}
    if dup:
        ok = False
        print('DUPLICATE NAMES', dup)
    return ok


def sh_block():
    out = []
    for tier in ['error', 'common', 'uncommon', 'rare', 'unique', 'legend', 'dev']:
        faces = FACES[tier]
        out.append("KAO_%s='%s'" % (tier.upper(), '|'.join('#'.join(fr) for _, fr in faces)))
    out.append('')
    for tier in ['common', 'uncommon', 'rare', 'unique', 'legend', 'dev']:
        out.append("NAME_%s='%s'" % (tier.upper(), '|'.join(n for n, _ in FACES[tier])))
    return '\n'.join(out)


def ps_block():
    out = []
    for tier in ['error', 'common', 'uncommon', 'rare', 'unique', 'legend', 'dev']:
        var = 'Kao' + tier.capitalize()
        out.append("$%s = '%s'" % (var, '|'.join('#'.join(fr) for _, fr in FACES[tier])))
    out.append('')
    for tier in ['common', 'uncommon', 'rare', 'unique', 'legend', 'dev']:
        out.append("$Name%s = '%s'" % (tier.capitalize(), '|'.join(n for n, _ in FACES[tier])))
    out.append('')
    out.append(ps_ramps())
    return chr(10).join(out)


def sh_palettes():
    out = []
    for name in ['dawn', 'crimson', 'royal', 'abyss', 'amethyst', 'ember', 'radiance']:
        out.append("PAL_%s='%s'" % (name.upper(), ' '.join(PALETTES[name])))
    out.append("LEGEND_PALETTES='%s'" % ' '.join(LEGEND_PALETTES))
    return chr(10).join(out)


def cube_index(r, g, b):
    """Nearest cell of the xterm 6x6x6 cube, same rule as the scripts' fallback."""
    def q(v):
        if v < 48:
            return 0
        if v < 115:
            return 1
        return int((v - 35) / 40)
    return 16 + 36 * q(r) + 6 * q(g) + q(b)


def codes_of(hexes, true_color):
    out = []
    for h in hexes:
        r, g, b = int(h[1:3], 16), int(h[3:5], 16), int(h[5:7], 16)
        out.append('38;2;%d;%d;%d' % (r, g, b) if true_color else '38;5;%d' % cube_index(r, g, b))
    return out


def ramp_codes(keys, true_color, n=GRADIENT_STEPS):
    """The SGR colour parameters of one ramp, precomputed for the scripts."""
    out = []
    for h in ramp(keys, n):
        r, g, b = int(h[1:3], 16), int(h[3:5], 16), int(h[5:7], 16)
        out.append('38;2;%d;%d;%d' % (r, g, b) if true_color else '38;5;%d' % cube_index(r, g, b))
    return out


PALETTE_ORDER = ['dawn', 'ember', 'radiance', 'sapphire', 'emerald']


def ps_ramps():
    out = ['# Legend ramps, 36 cells each, generated by docs/legend/render.py',
           '# from the RGB keyframes there. One set in 24-bit colour, one snapped to the',
           '# xterm cube for terminals that only know 256 colours.',
           '$RampTrue = @{']
    for name in PALETTE_ORDER:
        out.append("    %s = '%s'" % (name, '|'.join(ramp_codes(PALETTES[name], True))))
    out.append("    unique = '%s'" % '|'.join(codes_of(ramp_linear(UNIQUE_KEYS, UNIQUE_STEPS), True)))
    out.append('}')
    out.append('$Ramp256 = @{')
    for name in PALETTE_ORDER:
        out.append("    %s = '%s'" % (name, '|'.join(ramp_codes(PALETTES[name], False))))
    out.append("    unique = '%s'" % '|'.join(codes_of(ramp_linear(UNIQUE_KEYS, UNIQUE_STEPS), False)))
    out.append('}')
    out.append("$LegendPalettes = @(%s)" % ', '.join("'%s'" % p for p in LEGEND_PALETTES))
    return chr(10).join(out)


def sh_ramps():
    out = ['# Legend ramps, 36 cells each, generated by docs/legend/render.py',
           '# from the RGB keyframes there. One set in 24-bit colour, one snapped to the',
           '# xterm cube for terminals that only know 256 colours.']
    for name in PALETTE_ORDER:
        out.append("RAMP_TRUE_%s='%s'" % (name.upper(), ' '.join(ramp_codes(PALETTES[name], True))))
    out.append("RAMP_TRUE_UNIQUE='%s'" % ' '.join(codes_of(ramp_linear(UNIQUE_KEYS, UNIQUE_STEPS), True)))
    for name in PALETTE_ORDER:
        out.append("RAMP_256_%s='%s'" % (name.upper(), ' '.join(ramp_codes(PALETTES[name], False))))
    out.append("RAMP_256_UNIQUE='%s'" % ' '.join(codes_of(ramp_linear(UNIQUE_KEYS, UNIQUE_STEPS), False)))
    out.append("LEGEND_PALETTES='%s'" % ' '.join(LEGEND_PALETTES))
    return chr(10).join(out)


def html_page():
    import json
    tiers = []
    for t in TIER_ORDER:
        tiers.append({'tier': t, 'faces': [{'name': n, 'frames': f} for n, f in FACES[t]]})
    ramps = {name: ramp(PALETTES[name]) for name in PALETTE_ORDER}
    data = {
        'tiers': tiers,
        'legendPalettes': LEGEND_PALETTES,
        'ramps': ramps,
        'unique': ramp_linear(UNIQUE_KEYS, UNIQUE_STEPS),
        'flat': {'common': xterm_hex(253), 'uncommon': xterm_hex(120), 'rare': xterm_hex(117)},
        'labels': {'common': '커먼', 'uncommon': '언커먼', 'rare': '레어', 'unique': '유니크', 'legend': '레전드'},
        'talk': {'common': '냥!', 'uncommon': '다했다!', 'rare': '끝났어요', 'unique': '다 끝냈습니다!', 'legend': '전부 끝냈습니다, 확인 부탁드려요!'},
    }
    return """<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><title>statusline preview</title>
<style>
body{margin:0;padding:24px;background:#0d1117;color:#c9d1d9;font:14px/1.6 'Cascadia Code','D2Coding','JetBrains Mono','Consolas','Malgun Gothic','Noto Sans CJK KR','Apple SD Gothic Neo',monospace}
h1{font-size:18px;margin:0 0 4px}
p.note{color:#8b949e;margin:0 0 24px;font-size:13px}
h2{font-size:15px;margin:28px 0 10px;color:#8b949e;font-weight:normal;border-bottom:1px solid #21262d;padding-bottom:4px}
table{border-collapse:collapse}
td{padding:6px 14px 6px 0;vertical-align:middle;white-space:nowrap}
td.name{color:#8b949e;width:110px}
td.face{font-size:22px;letter-spacing:1px}
td.line{font-size:16px}
.sw{display:inline-block;width:18px;height:18px;border-radius:4px;margin-right:3px;vertical-align:middle}
.bar{margin-top:32px;font-size:15px;color:#8b949e}
.bar b{color:#fff;font-weight:normal}
.g{color:#00ff00}.m{color:#ff5fff}.y{color:#ffff5f}
</style></head><body>
<h1>claude-statusline-astro 미리보기</h1>
<p class="note">터미널과 같은 규칙으로 그립니다. 표정은 2초마다 바뀌고, 레전드는 그라데이션 위에서 시계에 맞춰 반짝입니다. 검은 배경 기준입니다.</p>
<div class="bar"><b>DIR</b> my-project <span style="color:#555">|</span> <b>GIT</b> <span class="m">main</span> <span style="color:#555">|</span> <b>MODEL</b> <span class="y">Opus 5</span> <span style="color:#555">|</span> <b>CTX</b> <span class="g">[◼◼◻◻◻◻◻◻◻◻] 21%</span> <span style="color:#555">|</span> <b>5H</b> <span class="g">[◼◼◼◻◻◻◻◻◻◻] 34%</span> <span style="color:#555">1h49m</span> <span id="barface"></span></div>
<div id="root"></div>
<script>
const D = """ + json.dumps(data, ensure_ascii=False) + """;
const root = document.getElementById('root');
function hash(seed, i, every){ let x=(seed*31+i*7+13)%2147483647; x=(x*48271)%2147483647; x=(x*48271)%2147483647; return x%every===0; }
function paintLegend(text, ramp, seed){
  const n=ramp.length, lo=0, hi=Math.floor(n/2), len=[...text].length;
  return [...text].map((ch,i)=>{ const d=Math.abs(2*i-(len-1)); let idx=len>1? hi-Math.floor((hi-lo)*d/(len-1)) : hi; let col=ramp[idx]; if(hash(seed,i,4)){ const v=parseInt(col.slice(1),16); const lum=(((v>>16)&255)*299+((v>>8)&255)*587+(v&255)*114)/1000; col = lum>170 ? ramp[0] : ramp[hi]; } return '<span style="color:'+col+'">'+ch+'</span>'; }).join('');
}
function paintUnique(text){ const r=D.unique, n=r.length, len=[...text].length; return [...text].map((ch,i)=>{ const idx=len>1?Math.floor(i*(n-1)/(len-1)):0; return '<span style="color:'+r[idx]+'">'+ch+'</span>'; }).join(''); }
function flat(text,c){ return '<span style="color:'+c+'">'+text+'</span>'; }
function render(){
  const now=Math.floor(Date.now()/1000), frame=Math.floor(now/2), seed=now%1000003;
  let html='';
  D.tiers.forEach(t=>{
    html+='<h2>'+D.labels[t.tier]+' · '+t.faces.length+'종</h2><table>';
    t.faces.forEach((f,fi)=>{
      const text=f.frames[frame%f.frames.length];
      let face, line, sw='';
      if(t.tier==='legend'){ const ramp=D.ramps[D.legendPalettes[fi]]; face=paintLegend(text,ramp,seed); line=paintLegend(D.talk.legend,ramp,seed+1); sw=[...Array(10).keys()].map(k=>'<i class="sw" style="background:'+ramp[Math.round(k*(ramp.length-1)/9)]+'"></i>').join(''); }
      else if(t.tier==='unique'){ face=paintUnique(text); line=paintUnique(D.talk.unique); sw=[...Array(10).keys()].map(k=>'<i class="sw" style="background:'+D.unique[Math.round(k*(D.unique.length-1)/9)]+'"></i>').join(''); }
      else { const c=D.flat[t.tier]; face=flat(text,c); line=flat(D.talk[t.tier],c); sw='<i class="sw" style="background:'+c+'"></i>'; }
      html+='<tr><td class="name">'+f.name+'</td><td class="face">'+face+'</td><td class="line">'+line+'</td><td>'+sw+'</td></tr>';
    });
    html+='</table>';
  });
  root.innerHTML=html;
  const w=D.tiers[4].faces[1]; document.getElementById('barface').innerHTML=paintLegend(w.frames[frame%4], D.ramps[D.legendPalettes[1]], seed)+' '+paintLegend(D.talk.legend, D.ramps[D.legendPalettes[1]], seed+1);
}
render(); setInterval(render, 2000);
</script></body></html>
"""


XTERM = None


def xterm_hex(n):
    global XTERM
    if XTERM is None:
        base = ['000000', '800000', '008000', '808000', '000080', '800080', '008080', 'c0c0c0',
                '808080', 'ff0000', '00ff00', 'ffff00', '0000ff', 'ff00ff', '00ffff', 'ffffff']
        XTERM = ['#' + b for b in base]
        steps = [0, 95, 135, 175, 215, 255]
        for r in steps:
            for g in steps:
                for b in steps:
                    XTERM.append('#%02x%02x%02x' % (r, g, b))
        for i in range(24):
            v = 8 + i * 10
            XTERM.append('#%02x%02x%02x' % (v, v, v))
    return XTERM[n]


def svg(text, ramp, offset=0):
    fs = 22
    unit = 13.6  # approx advance of one narrow cell at 22px
    x = 10.0
    parts = []
    for i, ch in enumerate(text):
        col = ramp[(offset + i) % len(ramp)]
        parts.append('<text x="%.1f" y="22.0" fill="%s">%s</text>' % (x, col, ch))
        x += unit * (2 if cw(ch, 1) == 2 else 1) * (0.81 if cw(ch, 1) == 2 else 1)
    w = int(x + 8)
    head = ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="42" viewBox="0 0 %d 42" role="img">\n'
            '<rect width="100%%" height="100%%" rx="6" fill="#0d1117"/>\n'
            '<g font-family="\'Segoe UI Symbol\',\'Malgun Gothic\',\'Noto Sans CJK KR\',\'Apple SD Gothic Neo\','
            '\'Noto Sans Symbols 2\',\'DejaVu Sans\',monospace" font-size="%d" dominant-baseline="middle">\n'
            % (w, w, fs))
    return head + '\n'.join(parts) + '\n</g></svg>\n'


def swatch_svg(hexes):
    """Ten squares, one per cell of a bar, coloured along the ramp."""
    cell, gap, pad = 22, 4, 4
    n = len(hexes)
    w = pad * 2 + cell * 10 + gap * 9
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" role="img">' % (w, cell + pad * 2, w, cell + pad * 2),
             '<rect width="100%" height="100%" rx="6" fill="#0d1117"/>']
    for i in range(10):
        col = hexes[int(round(i * (n - 1) / 9))]
        parts.append('<rect x="%d" y="%d" width="%d" height="%d" rx="4" fill="%s"/>' % (pad + i * (cell + gap), pad, cell, cell, col))
    parts.append('</svg>')
    return chr(10).join(parts) + chr(10)


def readme_tables():
    labels = {'common': '커먼', 'uncommon': '언커먼', 'rare': '레어', 'unique': '유니크', 'legend': '레전드'}
    out = []
    for tier in TIER_ORDER:
        out.append('| 이름 | 얼굴 | 표정 |')
        out.append('| --- | --- | --- |')
        for i, (name, frames) in enumerate(FACES[tier]):
            if tier == 'legend':
                pal = LEGEND_PALETTES[i]
                face = '![%s](docs/legend/legend-%d.svg)' % (frames[0], i + 1)
                out.append('| **%s** | %s | %s |' % (name, face, ' · '.join('`%s`' % f for f in frames)))
            else:
                out.append('| **%s** | `%s` | %s |' % (name, frames[0], ' · '.join('`%s`' % f for f in frames[1:])))
        out.append('')
    return '\n'.join(out)


if __name__ == '__main__':
    if not validate():
        sys.exit('validation failed')
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'check'
    if cmd == 'sh':
        print(sh_block())
    elif cmd == 'ps':
        print(ps_block())
    elif cmd == 'psramps':
        print(ps_ramps())
    elif cmd == 'shramps':
        print(sh_ramps())
    elif cmd == 'html':
        with open(sys.argv[2], 'w', encoding='utf-8', newline=chr(10)) as fh:
            fh.write(html_page())
        print('wrote', sys.argv[2])
    elif cmd == 'shpal':
        print(sh_palettes())
    elif cmd == 'readme':
        print(readme_tables())
    elif cmd == 'svg':
        outdir = sys.argv[2]
        os.makedirs(outdir, exist_ok=True)
        for i, (name, frames) in enumerate(FACES['legend']):
            ramp_ = ramp(PALETTES[LEGEND_PALETTES[i]])
            with open(os.path.join(outdir, 'legend-%d.svg' % (i + 1)), 'w', encoding='utf-8', newline='\n') as fh:
                fh.write(svg(frames[0], ramp_))
        face = FACES['unique'][0][1][0]
        lin = ramp_linear(UNIQUE_KEYS, UNIQUE_STEPS)
        stretched = [lin[int(i * (len(lin) - 1) / max(len(face) - 1, 1))] for i in range(len(face))]
        with open(os.path.join(outdir, 'unique.svg'), 'w', encoding='utf-8', newline='\n') as fh:
            fh.write(svg(face, stretched))
        for i, name in enumerate(LEGEND_PALETTES):
            with open(os.path.join(outdir, 'swatch-%d.svg' % (i + 1)), 'w', encoding='utf-8', newline=chr(10)) as fh:
                fh.write(swatch_svg(ramp(PALETTES[name])))
        with open(os.path.join(outdir, 'swatch-unique.svg'), 'w', encoding='utf-8', newline=chr(10)) as fh:
            fh.write(swatch_svg(lin))
        print('wrote', len(FACES['legend']), 'legend svgs + unique.svg + swatches')
    elif cmd == 'count':
        for t in TIER_ORDER:
            print(t, len(FACES[t]))
        print('total', sum(len(FACES[t]) for t in TIER_ORDER))
    else:
        print('ok')
