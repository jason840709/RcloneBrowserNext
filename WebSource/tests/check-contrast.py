"""Check computed production palette tokens; run render-previews.ts first."""
import json
from pathlib import Path
import sys

tokens_path = Path(sys.argv[1] if len(sys.argv) > 1 else '.build-cache/qa06-final-previews/palette-tokens.json')
def luminance(color):
    color = color.lstrip('#')
    if len(color) == 3:
        color = ''.join(char * 2 for char in color)
    values = [int(color[i:i+2], 16) / 255 for i in (0, 2, 4)]
    values = [v/12.92 if v <= .04045 else ((v+.055)/1.055)**2.4 for v in values]
    return sum(v * w for v, w in zip(values, [.2126, .7152, .0722]))
def ratio(a, b):
    lo, hi = sorted([luminance(a), luminance(b)])
    return (hi + .05) / (lo + .05)
checks = []
for theme, tokens in json.loads(tokens_path.read_text()).items():
    pairs = [(fg, bg, 4.5) for fg in ['text', 'muted', 'faint'] for bg in ['surface', 'toolbar', 'bg', 'row-stripe']]
    pairs += [('accent-foreground', bg, 4.5) for bg in ['accent', 'accent-hover', 'accent-pressed']]
    pairs += [('accent-soft-text', 'accent-soft', 4.5)]
    pairs += [(fg, fg+'-bg', 4.5) for fg in ['success', 'error', 'warning']]
    pairs += [('border', 'surface', 3)]
    for fg, bg, minimum in pairs:
        value = ratio(tokens[fg], tokens[bg])
        checks.append(dict(theme=theme, foreground=fg, background=bg, ratio=round(value, 2), minimum=minimum, passed=value >= minimum))
report = {'scope': 'Computed palette token contrast for text, metadata, placeholders, primary action states, selected text, notices and control border. Disabled controls excluded. This is not a full WCAG audit.', 'checks': checks, 'passed': all(c['passed'] for c in checks)}
(tokens_path.parent / 'contrast-report.json').write_text(json.dumps(report, indent=2) + '\n')
print(f"{sum(c['passed'] for c in checks)}/{len(checks)} contrast pairs passed.")
for check in checks:
    if not check['passed']:
        print(check)
sys.exit(0 if report['passed'] else 1)
