const panel    = document.getElementById('panel');
const aside    = document.getElementById('aside');
const burger   = document.getElementById('menu-toggle');
const backdrop = document.getElementById('backdrop');
const PREFIX   = document.body.dataset.prefix || '';
let activeBtn  = null;
let activeStream = null;

/* ── Agent-Health ───────────────────────────────────────── */
/* iPhone: one-shot on load only — no polling, no post-action refresh.
   Desktop: one-shot on load + poll every 5 minutes + refresh after actions. */
const IS_IPHONE = /iPhone/.test(navigator.userAgent);

async function refreshAgentStatus() {
  if (IS_IPHONE) return;
  try {
    const res = await fetch(PREFIX + '/agents/status', { cache: 'no-store' });
    if (!res.ok) return;
    const status = await res.json();
    document.querySelectorAll('.agent-badge').forEach(badge => {
      const name = badge.dataset.agent;
      const s = status[name];
      badge.classList.remove('online', 'degraded', 'offline');
      if (s) badge.classList.add(s);
    });
  } catch (e) {
    /* network error: leave badges as-is */
  }
}

if (document.querySelector('.agent-badge')) {
  // initial check on all devices
  (async () => {
    try {
      const res = await fetch(PREFIX + '/agents/status', { cache: 'no-store' });
      if (!res.ok) return;
      const status = await res.json();
      document.querySelectorAll('.agent-badge').forEach(badge => {
        const s = status[badge.dataset.agent];
        badge.classList.remove('online', 'degraded', 'offline');
        if (s) badge.classList.add(s);
      });
    } catch (e) { /* leave badges as-is */ }
  })();
  // desktop only: poll every 5 minutes
  if (!IS_IPHONE) setInterval(refreshAgentStatus, 5 * 60 * 1000);
}

/* ── Link-Grid (Default-View, Flame-Ersatz) ────────────── */
/* Lädt beim Start /links und zeigt ein Grid aus anklickbaren Links im
   Panel. Wenn die Stage-Instance keine `links:`-Section in der YAML hat,
   bleibt der HTML-Placeholder (»Button wählen«) sichtbar. */
async function loadLinkGrid() {
  try {
    const res = await fetch(PREFIX + '/links', { cache: 'no-store' });
    if (!res.ok) return;
    const { sections } = await res.json();
    if (!sections || !sections.length) return;
    setPanel(renderLinkGrid(sections));
    loadMdiIcons(panel);
  } catch (e) { /* Netzwerk-Fehler: Placeholder bleibt */ }
}

function renderLinkGrid(sections) {
  return '<div class="link-grid-wrap">' + sections.map(sec => `
    <h3 class="link-grid-title">${esc(sec.title)}</h3>
    <div class="link-grid">
      ${(sec.items || []).map(it => `
        <a class="link-card" href="${esc(it.url)}"${external(it.url) ? ' target="_blank" rel="noopener"' : ''}>
          ${it.icon ? (it.icon.startsWith('mdi:') ? mdiIcon(it.icon.slice(4), it.icon_color) : `<span class="link-icon">${esc(it.icon)}</span>`) : ''}
          <span class="link-label">${esc(it.label)}</span>
        </a>`).join('')}
    </div>`).join('') + '</div>';
}

const iconCache = {};
function mdiIcon(name, color) {
  const style = color ? ` style="color: ${nordColor(color)}"` : '';
  return iconCache[name] !== undefined
    ? iconCache[name].replace('class="link-icon-mdi"', `class="link-icon-mdi"${style}`)
    : `<span class="link-icon-mdi-placeholder" data-mdi="${esc(name)}" data-color="${esc(color || '')}"></span>`;
}

const NORD_VARS = ['teal','blue','red','grn','yel','pur','n9','n10'];
function nordColor(c) { return NORD_VARS.includes(c) ? `var(--${c})` : c; }

// Loads MDI icons asynchronously for the link grid (after renderLinkGrid)
async function loadMdiIcons(container) {
  const placeholders = container.querySelectorAll('[data-mdi]');
  for (const el of placeholders) {
    const name = el.dataset.mdi;
    if (iconCache[name] === undefined) {
      try {
        const res = await fetch(`${PREFIX}/assets/icons/${encodeURIComponent(name)}.svg`);
        if (res.ok) {
          const svg = await res.text();
          iconCache[name] = `<span class="link-icon-mdi">${svg}</span>`;
        } else { iconCache[name] = ''; }
      } catch { iconCache[name] = ''; }
    }
    if (iconCache[name]) {
      const color = el.dataset.color;
      const style = color ? ` style="color: ${nordColor(color)}"` : '';
      el.outerHTML = iconCache[name].replace('class="link-icon-mdi"', `class="link-icon-mdi"${style}`);
    }
  }
}

function external(url) {
  return /^[a-z][a-z0-9+.-]*:/i.test(url) && !url.startsWith(location.origin);
}

// Klick auf den Stage-Titel oben → zurück zur Home-Ansicht (Grid).
document.querySelector('header h1')?.addEventListener('click', () => {
  if (activeStream) { activeStream.close(); activeStream = null; }
  if (activeBtn)    { activeBtn.classList.remove('active'); activeBtn = null; }
  loadLinkGrid();
});
document.querySelector('header h1')?.style.setProperty('cursor', 'pointer');

loadLinkGrid();

/* ── Mobile-Drawer ─────────────────────────────────────── */
const MOBILE_BREAKPOINT = 700;
const isMobile = () => window.innerWidth <= MOBILE_BREAKPOINT;

function setDrawer(open) {
  aside.classList.toggle('open', open);
  backdrop.classList.toggle('visible', open);
  burger.setAttribute('aria-expanded', open);
}
burger.addEventListener('click', () => setDrawer(!aside.classList.contains('open')));
backdrop.addEventListener('click', () => setDrawer(false));

document.querySelectorAll('.btn').forEach(btn => {
  btn.addEventListener('click', () => {
    if (activeStream) { activeStream.close(); activeStream = null; }
    if (activeBtn)    activeBtn.classList.remove('active');
    btn.classList.add('active', 'loading');
    activeBtn = btn;

    // Drawer schliessen auf Mobile, damit der Panel-Inhalt sichtbar wird
    if (isMobile()) setDrawer(false);

    const { type, id, url, placeholder, source, format } = btn.dataset;

    if      (type === 'action')   runAction(id, url, btn, format);
    else if (type === 'stream')   runStream(id, btn, format);
    else if (type === 'input')    renderInput(id, url, placeholder, btn);
    else if (type === 'jobs')     loadJobs(btn);
    else if (type === 'notes')    loadNotes(source || id || 'cheaters', btn);
    else                          runAction(id, url, btn);
  });
});

/* ── Action ─────────────────────────────────────────────── */
async function runAction(id, url, btn, format) {
  setPanel(`<div class="output-label">Action · ${esc(id)}</div>
            <div class="output-box">Calling ${esc(url)} …</div>`);
  try {
    const res  = await fetch(url);
    const text = await res.text();
    const fmt  = format === 'nowrap' ? ' nowrap' : '';
    setPanel(`
      <div class="output-label">Output · ${esc(id)}</div>
      <div class="output-box${fmt} ${res.ok ? 'ok' : 'error'}">${esc(text.trim() || '(no output)')}</div>
    `);
    refreshAgentStatus();
  } catch (e) {
    setPanel(`<div class="output-box error">${esc(e.message)}</div>`);
    refreshAgentStatus();
  } finally {
    btn.classList.remove('loading');
  }
}

/* ── Input ──────────────────────────────────────────────── */
function renderInput(id, baseUrl, placeholder, btn) {
  setPanel(`
    <div class="output-label">Input · ${esc(id)}</div>
    <div class="input-row">
      <input class="pad-input" id="pad-input" type="text"
             placeholder="${esc(placeholder || 'Argument…')}" autofocus>
      <button class="run-btn" id="run-btn">Run</button>
    </div>
    <div class="output-box" id="input-out" style="display:none"></div>
  `);
  btn.classList.remove('loading');

  const input  = document.getElementById('pad-input');
  const runBtn = document.getElementById('run-btn');
  const out    = document.getElementById('input-out');

  const doRun = async () => {
    const val     = input.value.trim();
    const fullUrl = val ? baseUrl + '/' + encodeURIComponent(val) : baseUrl;
    out.style.display = '';
    out.className = 'output-box';
    out.textContent = 'Calling ' + fullUrl + ' …';
    runBtn.disabled = true;
    try {
      const res  = await fetch(fullUrl);
      const text = await res.text();
      out.className = 'output-box ' + (res.ok ? 'ok' : 'error');
      out.textContent = text.trim() || '(no output)';
    } catch (e) {
      out.className = 'output-box error';
      out.textContent = e.message;
    } finally {
      runBtn.disabled = false;
    }
  };

  runBtn.addEventListener('click', doRun);
  input.addEventListener('keydown', e => { if (e.key === 'Enter') doRun(); });
}

/* ── Stream ─────────────────────────────────────────────── */
function runStream(id, btn, format) {
  const fmt = format === 'nowrap' ? ' nowrap' : '';
  setPanel(`
    <div class="output-label">
      Stream · ${esc(id)}
      <span class="live-badge" id="live-badge">LIVE</span>
    </div>
    <div class="output-box${fmt}" id="stream-out"></div>
  `);
  const out = document.getElementById('stream-out');

  let reader = null;
  let done   = false;
  activeStream = { close: () => { reader && reader.cancel(); } };

  const finish = (cssClass, appendText) => {
    done = true;
    activeStream = null;
    if (appendText) out.textContent += appendText;
    out.classList.add(cssClass);
    document.getElementById('live-badge')?.remove();
    btn.classList.remove('loading');
  };

  function* parseSSE(text) {
    for (const block of text.split('\n\n')) {
      if (!block.trim()) continue;
      let event = 'message', data = null;
      for (const line of block.split('\n')) {
        if (line.startsWith('event: ')) event = line.slice(7).trim();
        else if (line.startsWith('data: '))  data  = line.slice(6);
      }
      if (data !== null) yield { event, data };
    }
  }

  (async () => {
    try {
      const res = await fetch(PREFIX + '/run/' + encodeURIComponent(id));
      if (!res.ok) { finish('error', '\n[error] HTTP ' + res.status); return; }

      reader = res.body.getReader();
      const dec = new TextDecoder();
      let buf = '';

      while (true) {
        const { done: eof, value } = await reader.read();
        if (eof) break;
        buf += dec.decode(value, { stream: true });

        const cut = buf.lastIndexOf('\n\n');
        if (cut === -1) continue;
        const chunk = buf.slice(0, cut + 2);
        buf = buf.slice(cut + 2);

        for (const { event, data } of parseSSE(chunk)) {
          if (event === 'done') {
            reader.cancel(); finish('ok', null); return;
          } else if (event === 'stream_error') {
            reader.cancel(); finish('error', '\n[error] ' + data); return;
          } else if (event === 'input_request') {
            // Multi-step workflow: Skript bittet um Eingabe und nennt die
            // Action-URL für den Folge-Aufruf. Wir beenden den aktuellen Stream
            // sauber und zeigen ein Prompt-Feld unter dem Output.
            reader.cancel();
            finish('ok', null);
            let prompt;
            try { prompt = JSON.parse(data); }
            catch (e) {
              out.textContent += '\n[invalid MILAN_PROMPT JSON: ' + data + ']\n';
              return;
            }
            renderStreamPrompt(prompt.label || 'Argument', prompt.action, btn);
            return;
          } else {
            out.textContent += data + '\n';
            out.scrollTop = out.scrollHeight;
          }
        }
      }
      if (!done) finish('ok', null);
      refreshAgentStatus();
    } catch (e) {
      if (!done) finish('error', '\n[connection error]');
      refreshAgentStatus();
    }
  })();
}

/* ── Prompt nach input_request ──────────────────────────── */
/* Stream ist beendet, der Output bleibt sichtbar; darunter erscheint eine
   Eingabezeile. Submit → ruft `action/<encoded-value>` als normalen Action-
   Endpoint auf, das Ergebnis erscheint als Output-Box unter dem Prompt. */
function renderStreamPrompt(label, action, btn) {
  if (!action) {
    panel.insertAdjacentHTML('beforeend',
      `<div class="output-box error">[MILAN_PROMPT ohne action]</div>`);
    return;
  }

  const wrap = document.createElement('div');
  wrap.className = 'input-row';
  wrap.style.marginTop = '12px';
  wrap.innerHTML = `
    <input class="pad-input" type="text" placeholder="${esc(label)}" autofocus>
    <button class="run-btn">Weiter</button>
  `;
  panel.appendChild(wrap);

  const input  = wrap.querySelector('input');
  const runBtn = wrap.querySelector('button');

  const submit = async () => {
    const val = input.value.trim();
    if (!val) return;
    runBtn.disabled = true;

    const url = action + '/' + encodeURIComponent(val);
    const resultBox = document.createElement('div');
    resultBox.className = 'output-box';
    resultBox.textContent = 'Calling ' + url + ' …';
    panel.appendChild(resultBox);

    try {
      const res  = await fetch(url);
      const text = await res.text();
      resultBox.className = 'output-box ' + (res.ok ? 'ok' : 'error');
      resultBox.textContent = text.trim() || '(no output)';
    } catch (e) {
      resultBox.className = 'output-box error';
      resultBox.textContent = e.message;
    } finally {
      input.disabled = true;        // einmal pro Prompt
    }
  };

  runBtn.addEventListener('click', submit);
  input.addEventListener('keydown', e => { if (e.key === 'Enter') submit(); });
}

/* ── Notes split panel ──────────────────────────────────── */
let notesTimer = null;

function loadNotes(source, btn) {
  setPanel(`
    <div class="notes-layout">
      <div class="notes-nav" id="notes-nav">
        <div class="notes-loading">Lade\u2026</div>
      </div>
      <div class="notes-content" id="notes-content">
        <div class="notes-placeholder">Datei w\u00e4hlen</div>
      </div>
    </div>
  `);
  // CSS-Hook: .panel.notes-active entfernt das Panel-Padding und stellt
  // overflow:hidden, damit das Split-View bis zum Browser-Rand reicht.
  panel.classList.add('notes-active');
  btn.classList.remove('loading');

  fetch(PREFIX + '/notes/' + encodeURIComponent(source))
    .then(r => r.json())
    .then(files => {
      const nav = document.getElementById('notes-nav');
      if (!files.length) {
        nav.innerHTML = '<div class="notes-empty">Keine Dateien</div>';
        return;
      }
      nav.innerHTML = files.map(f =>
        `<div class="note-item" data-source="${esc(source)}" data-file="${esc(f)}">${esc(f)}</div>`
      ).join('');

      nav.querySelectorAll('.note-item').forEach(item => {
        item.addEventListener('click', () => {
          nav.querySelectorAll('.note-item').forEach(i => i.classList.remove('active'));
          item.classList.add('active');
          const content = document.getElementById('notes-content');
          content.innerHTML = '<div class="notes-loading">Lade\u2026</div>';
          fetch(PREFIX + '/notes/' + encodeURIComponent(item.dataset.source) +
                '/' + encodeURIComponent(item.dataset.file))
            .then(r => r.text())
            .then(html => {
              content.innerHTML = '<div class="sheet-frame">' + html + '</div>';
            })
            .catch(e => {
              content.innerHTML = '<div class="output-box error">' + esc(e.message) + '</div>';
            });
        });
      });
    })
    .catch(e => {
      document.getElementById('notes-nav').innerHTML =
        '<div class="output-box error">' + esc(e.message) + '</div>';
    });
}

/* ── Jobs ───────────────────────────────────────────────── */
let jobsTimer = null;

function loadJobs(btn) {
  if (jobsTimer) { clearInterval(jobsTimer); jobsTimer = null; }

  const load = async () => {
    try {
      const res  = await fetch(PREFIX + '/jobs');
      const html = await res.text();
      if (activeBtn === btn) {
        setPanel(`
          <div class="output-label">Job Log
            <span style="font-weight:400;text-transform:none;letter-spacing:0;color:var(--n3);font-size:10px">
              · aktualisiert ${new Date().toLocaleTimeString('de')}
            </span>
          </div>
          ${html}
        `);
      }
    } catch (e) {
      if (activeBtn === btn)
        setPanel(`<div class="output-box error">${esc(e.message)}</div>`);
    }
  };

  load().finally(() => btn.classList.remove('loading'));
  jobsTimer = setInterval(() => {
    if (activeBtn !== btn) { clearInterval(jobsTimer); jobsTimer = null; return; }
    load();
  }, 30000);
}

/* ── Util ───────────────────────────────────────────────── */
function setPanel(html) {
  panel.classList.remove('cheaters-active', 'notes-active');
  panel.innerHTML = html;
  panel.scrollTop = 0;
}

function esc(str) {
  return String(str)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;')
    .replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}
