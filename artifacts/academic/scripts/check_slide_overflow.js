// Overflow probe: loads presentation.html in headless Chrome after injecting a
// measurement script. For each Marp <section> it reports scrollHeight vs
// clientHeight and every element whose box extends past the slide's bottom edge.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const src = fs.readFileSync(path.join(__dirname, '..', 'presentation.html'), 'utf8');

const injected = src.replace('</body>', `
<script>
window.addEventListener('load', function () {
  setTimeout(function () {
    const out = [];
    document.querySelectorAll('section').forEach(function (sec) {
      const secBox = sec.getBoundingClientRect();
      const limit = secBox.bottom;
      const items = [];
      const overflowY = sec.scrollHeight - sec.clientHeight;
      sec.querySelectorAll('*').forEach(function (el) {
        if (el.tagName === 'SCRIPT' || el.tagName === 'STYLE') return;
        const r = el.getBoundingClientRect();
        if (r.height === 0 && r.width === 0) return;
        if (r.bottom > limit + 1) {
          items.push({
            tag: el.tagName.toLowerCase(),
            cls: ((el.className && el.className.baseVal !== undefined) ? el.className.baseVal : (el.className || '')).toString().slice(0, 40),
            text: (el.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 70),
            overBy: Math.round(r.bottom - limit)
          });
        }
      });
      // keep only the worst offender per distinct text to reduce noise
      const seen = {};
      const dedup = items.filter(function (it) {
        const k = it.text;
        if (seen[k]) return false;
        seen[k] = true;
        return true;
      });
      out.push({ slide: sec.id || out.length + 1, overflowY: overflowY, offenders: dedup.slice(0, 8) });
    });
    const lines = out
      .filter(function (d) { return d.overflowY > 1 || d.offenders.length; })
      .map(function (d) {
        return 'SLIDE ' + d.slide + ' | innerOverflow=' + d.overflowY + 'px' +
          d.offenders.map(function (o) {
            return '\\n    <' + o.tag + (o.cls ? '.' + o.cls : '') + '> +' + o.overBy + 'px  "' + o.text + '"';
          }).join('');
      });
    const pre = document.createElement('pre');
    pre.id = 'probe-output';
    pre.textContent = lines.length ? lines.join('\\n') : 'ALL_SLIDES_FIT';
    document.body.appendChild(pre);
  }, 900);
});
</script>
</body>`);

fs.writeFileSync('/tmp/probe_deck.html', injected);

const chrome = '/home/radhey/.local/bin/google-chrome-stable';
const dom = execFileSync(chrome, [
  '--headless', '--no-sandbox', '--disable-gpu',
  '--virtual-time-budget=10000',
  '--dump-dom',
  'file:///tmp/probe_deck.html'
], { maxBuffer: 64 * 1024 * 1024 }).toString('utf8');

const m = dom.match(/<pre id="probe-output">([\s\S]*?)<\/pre>/);
console.log(m
  ? m[1].replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&')
  : 'PROBE_FAILED');
