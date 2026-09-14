# Single source of truth for the mascot faces.
# Emits: sh strings, ps1 code-point tables, README tables, legend SVGs.
import sys, unicodedata, os

# tier -> [(name, [frames...])]
FACES = {
    'error': [
        ('Oops', ['（；へ；）', '（；ㅅ；）']),
    ],
    'common': [
        ('Kitten',   ['（・ω・）', '（－ω－）']),
        ('Droopy',   ['（´･ω･）', '（´-ω-）']),
        ('Snooze',   ['（ ˘ω˘ ）z', '（ ˘ω˘ ）Z']),
        ('Whiskers', ['（=・ω・=）', '（=－ω－=）']),
        ('Grin',     ['（・∀・）', '（－∀－）']),
        ('Smiley',   ['（・◡・）', '（－◡－）']),
        ('Side-eye', ['（￢_￢）', '（￢‿￢）']),
        ('Meh',      ['（＝_＝）', '（＝.＝）']),
        ('Blank',    ['（・_・）', '（－_－）']),
        ('Smirk',    ['（≖‿≖）', '（≖_≖）']),
        ('Scowl',    ['（◣_◢）', '（◢_◣）']),
        ('Deadpan',  ['（ー_ー）', '（ー.ー）']),
    ],
    'uncommon': [
        ('Giggle',   ['（๑˃ᴗ˂）', '（๑˂ᴗ˃）']),
        ('Rosy',     ['（｡･ω･｡）', '（｡-ω-｡）']),
        ('Beam',     ['（^▽^）', '（^∇^）']),
        ('Bright',   ['（◕‿◕）', '（◠‿◠）']),
        ('Squee',    ['（≧ω≦）', '（≧▽≦）']),
        ('Wink',     ['（･ω<）', '（-ω<）']),
        ('Stare',    ['（ㆆ_ㆆ）', '（ㆆ.ㆆ）']),
        ('Eyeroll',  ['（◔_◔）', '（◔‸◔）']),
        ('Half-lid', ['（◓_◓）', '（◒_◒）']),
        ('Hamster',  ['（・ㅂ・）', '（－ㅂ－）']),
        ('Sly',      ['（¬‿¬）', '（¬_¬）']),
        ('Shifty',   ['（◑_◑）', '（◐_◐）']),
    ],
    'rare': [
        ('Twinkle',     ['（๑˃ᴗ˂）✧', '（๑˂ᴗ˃）✦']),
        ('Cheer',       ['ヽ（•‿•）ノ', 'ヾ（•‿•）ノ']),
        ('Glow',        ['（◕‿◕）✧', '（◠‿◠）✦']),
        ('Hooray',      ['\\（^o^）/', '\\（^O^）/']),
        ('Starry',      ['（๑✧‿✧๑）', '（๑✦‿✦๑）']),
        ('Wave',        ['ヽ（^ω^）ノ', 'ヾ（^ω^）ノ']),
        ('Smug',        ['（￣ｰ￣）✧', '（￣ｰ￣）✦']),
        ('Shades',      ['（▼ω▼）✧', '（▼ω▼）✦']),
        ('Brat',        ['（◣ω◢）✧', '（◢ω◣）✦']),
        ('Knowing',     ['（￢‿￢）✧', '（￢‿￢）✦']),
        ('Starstruck',  ['（★ω★）', '（☆ω☆）']),
        ('Gunslinger',  ['（☞ﾟヮﾟ）☞', '（☜ﾟヮﾟ）☜']),
    ],
    'unique': [
        ('Superstar',  ['✧ヽ（☆▽☆）ノ✧', '✦ヾ（★▽★）ノ✦']),
        ('Jubilee',    ['✧（ﾉ◕ヮ◕）ﾉ✧', '✦（ﾉ◠ヮ◠）ﾉ✦']),
        ('Lovestruck', ['✧（๑♡‿♡๑）✧', '✦（๑♥‿♥๑）✦']),
        ('Dazzle',     ['✧ヽ（✧∇✧）ノ✧', '✦ヾ（✦▽✦）ノ✦']),
        ('Hurrah',     ['✧＼（◕ᴗ◕）／✧', '✦＼（◠ᴗ◠）／✦']),
        ('Boss',       ['✧ヽ（￣ヘ￣）ノ✧', '✦ヾ（￣ヘ￣）ノ✦']),
        ('Fury',       ['✧ヽ（╬◣_◢）ノ✧', '✦ヽ（╬◢_◣）ノ✦']),
        ('Skeptic',    ['✧ヽ（￢_￢）ノ✧', '✦ヾ（￢‿￢）ノ✦']),
        ('Villain',    ['✧ヽ（╬￣ヘ￣）ノ✧', '✦ヾ（╬￣ヘ￣）ノ✦']),
        ('Grit',       ['✧┗（⇀‸↼）┛✧', '✦┗（⇀‸↼）┛✦']),
    ],
    'legend': [
        ('Halo',       ['･ﾟ✧（◕ᴗ◕）✧ﾟ･', '･ﾟ✦（◕ᴗ◕）✦ﾟ･', '･ﾟ✧（◕ᴗ◕）✦ﾟ･', '･ﾟ✦（◕ᴗ◕）✧ﾟ･']),
        ('Heartthrob', ['♡ヽ（♥‿♥）ノ♡', '♥ヾ（♡‿♡）ノ♥', '♡ヾ（♥‿♥）ノ♡', '♥ヽ（♡‿♡）ノ♥']),
        ('Bliss',      ['✧ﾟ（ﾉ≧∇≦）ﾉﾟ✧', '✦ﾟ（ﾉ≧▽≦）ﾉﾟ✦', '✧ﾟ（ﾉ≧∇≦）ﾉﾟ✦', '✦ﾟ（ﾉ≧▽≦）ﾉﾟ✧']),
        ('Serenade',   ['♪ﾟ･（๑ᴖ◡ᴖ๑）･ﾟ♪', '♬ﾟ･（๑ᴖ◡ᴖ๑）･ﾟ♬', '♩ﾟ･（๑ᴖ◡ᴖ๑）･ﾟ♩', '♬ﾟ･（๑ᴖ◡ᴖ๑）･ﾟ♬']),
        ('Monarch',    ['･ﾟ✧（￣ヘ￣）✧ﾟ･', '･ﾟ✦（￣ヘ￣）✦ﾟ･', '･ﾟ✧（￣ヘ￣）✦ﾟ･', '･ﾟ✦（￣ヘ￣）✧ﾟ･']),
        ('Wrath',      ['✦ﾟ（╬◣_◢）ﾟ✦', '✧ﾟ（╬◢_◣）ﾟ✧', '✦ﾟ（╬◢_◣）ﾟ✦', '✧ﾟ（╬◣_◢）ﾟ✧']),
        ('Overlord',   ['≪✧（╬▼_▼）✧≫', '≪✦（╬▼_▼）✦≫', '≪✧（╬▼_▼）✦≫', '≪✦（╬▼_▼）✧≫']),
    ],
    'dev': [
        ('Root',   ['｛・ω・｝', '｛－ω－｝']),
        ('Sudo',   ['⟨◕ᴗ◕⟩', '⟨◠ᴗ◠⟩']),
        ('Kernel', ['［◉_◉］', '［◉‸◉］']),
        ('Daemon', ['⟨◣_◢⟩', '⟨◢_◣⟩']),
    ],
}

# legend index -> palette name, mood-matched
LEGEND_PALETTES = ['dawn', 'crimson', 'royal', 'abyss', 'amethyst', 'ember', 'radiance']
LEGEND_DESC = {
    'dawn':     '보라에서 금빛으로',
    'crimson':  '자주에서 분홍으로',
    'royal':    '호박빛에서 순금으로',
    'abyss':    '남색에서 청록으로',
    'amethyst': '진보라에서 자홍으로',
    'ember':    '진홍에서 금빛으로',
    'radiance': '연보라에서 흰빛과 은색으로',
}
PALETTES = {
    'abyss':    [17, 18, 19, 20, 26, 32, 38, 44, 51, 45, 39, 33, 27, 21, 20, 18],
    'amethyst': [55, 56, 57, 93, 129, 165, 201, 207, 213, 219, 213, 207, 201, 165, 129, 93],
    'crimson':  [53, 89, 125, 161, 197, 198, 199, 200, 201, 200, 199, 198, 197, 161, 125, 89],
    'dawn':     [55, 90, 125, 161, 197, 203, 209, 215, 221, 215, 209, 203, 197, 161, 125, 90],
    'ember':    [52, 88, 124, 160, 196, 202, 208, 214, 220, 214, 208, 202, 196, 160, 124, 88],
    'radiance': [104, 105, 111, 147, 183, 189, 225, 231, 255, 254, 252, 254, 255, 231, 189, 147],
    'royal':    [58, 94, 130, 166, 202, 208, 214, 220, 226, 220, 214, 208, 202, 166, 130, 94],
}
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


def ps_frame(f):
    return '@(' + ', '.join('0x%04X' % ord(c) for c in f) + ')'


def ps_block():
    out = []
    out.append('$KaoError = @(')
    out.append('    ' + ',\n    '.join(ps_frame(f) for f in FACES['error'][0][1]))
    out.append(')')
    out.append('')
    out.append('# Rarity -> faces -> frames.')
    out.append('$KaoTable = @{')
    for tier in ['common', 'uncommon', 'rare', 'unique', 'legend', 'dev']:
        out.append('    %s = @(' % tier)
        items = []
        for name, frames in FACES[tier]:
            s = '        @(  # %s  %s\n' % (frames[0], name)
            s += ',\n'.join('            ' + ps_frame(f) for f in frames)
            s += '\n        )'
            items.append(s)
        out.append(',\n'.join(items))
        out.append('    )')
    out.append('}')
    out.append('')
    out.append('# One short English name per face, in table order.')
    out.append('$KaoNames = @{')
    for tier in ['common', 'uncommon', 'rare', 'unique', 'legend', 'dev']:
        out.append("    %s = @(%s)" % (tier, ', '.join("'%s'" % n for n, _ in FACES[tier])))
    out.append('}')
    return '\n'.join(out)


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
        col = xterm_hex(ramp[(offset + i) % len(ramp)])
        parts.append('<text x="%.1f" y="22.0" fill="%s">%s</text>' % (x, col, ch))
        x += unit * (2 if cw(ch, 1) == 2 else 1) * (0.81 if cw(ch, 1) == 2 else 1)
    w = int(x + 8)
    head = ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="42" viewBox="0 0 %d 42" role="img">\n'
            '<rect width="100%%" height="100%%" rx="6" fill="#0d1117"/>\n'
            '<g font-family="\'Segoe UI Symbol\',\'Malgun Gothic\',\'Noto Sans CJK KR\',\'Apple SD Gothic Neo\','
            '\'Noto Sans Symbols 2\',\'DejaVu Sans\',monospace" font-size="%d" dominant-baseline="middle">\n'
            % (w, w, fs))
    return head + '\n'.join(parts) + '\n</g></svg>\n'


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
    elif cmd == 'readme':
        print(readme_tables())
    elif cmd == 'svg':
        outdir = sys.argv[2]
        os.makedirs(outdir, exist_ok=True)
        for i, (name, frames) in enumerate(FACES['legend']):
            ramp = PALETTES[LEGEND_PALETTES[i]]
            with open(os.path.join(outdir, 'legend-%d.svg' % (i + 1)), 'w', encoding='utf-8', newline='\n') as fh:
                fh.write(svg(frames[0], ramp))
        print('wrote', len(FACES['legend']), 'svgs')
    elif cmd == 'count':
        for t in TIER_ORDER:
            print(t, len(FACES[t]))
        print('total', sum(len(FACES[t]) for t in TIER_ORDER))
    else:
        print('ok')
