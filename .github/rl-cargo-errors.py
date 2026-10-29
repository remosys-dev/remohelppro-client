# cargo の失敗を GitHub の注記にする（win32-customer.yml から呼ぶ）。
# ⚠ 注記は1件が短く切られるので、エラー1つずつ、場所の行と一緒に出す（最大10件）。
import re
import sys

lines = open(sys.argv[1], encoding='utf-8', errors='replace').read().splitlines()
out = []
for i, l in enumerate(lines):
    if re.match(r'^error(\[|:)', l) or 'panicked' in l:
        blk = [l] + [x for x in lines[i + 1:i + 6] if x.strip()]
        out.append(' | '.join(s.strip() for s in blk)[:900])
if not out:
    out = [' | '.join(lines[-15:])[:900]]
for m in out[:10]:
    print('::error title=cargo::' + m.replace('%', '%25'))
