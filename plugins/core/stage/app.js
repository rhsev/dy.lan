const panel    = document.getElementById('panel');
const aside    = document.getElementById('aside');
const burger   = document.getElementById('menu-toggle');
const backdrop = document.getElementById('backdrop');
const PREFIX   = document.body.dataset.prefix || '';
const ACTIVE_PANEL = document.body.dataset.activePanel || '';
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

/* ── Panels (type: panel) ──────────────────────────────────
   One fragment endpoint per panel (/panel/<id>), state lives in the URL via
   pushState/popstate. Panels that carry a live state (the widget board, the
   job log) keep polling while they're the active panel; loadPanel is a
   one-shot fetch for everything else. */
let panelTimer = null;
let lastPolledHtml = null;

function stopPanelPolling() {
  if (panelTimer) { clearInterval(panelTimer); panelTimer = null; }
  lastPolledHtml = null;
}

async function fetchPanelFragment(id, cache) {
  const res  = await fetch(PREFIX + '/panel/' + encodeURIComponent(id), {
    headers: { 'X-Requested-With': 'fetch' },
    cache
  });
  const html = await res.text();
  return { ok: res.ok, html };
}

async function loadPanel(btn) {
  const { id, panel: kind, refresh } = btn.dataset;
  let loaded = null;
  try {
    const { ok, html } = await fetchPanelFragment(id, 'no-store');
    if (!ok) { setPanel(`<div class="output-box error">${esc(html.trim())}</div>`); return; }
    setPanel(html);
    loaded = html;
    if (kind === 'notes') { panel.classList.add('notes-active'); wireNotes(); }
  } catch (e) {
    setPanel(`<div class="output-box error">${esc(e.message)}</div>`);
  } finally {
    btn.classList.remove('loading');
  }

  // Der gerade geladene Stand wird als Saat übergeben: sonst holt der erste
  // Tick dasselbe Fragment sofort noch einmal und zeichnet es neu.
  if (kind === 'widget') startPanelPolling(id, parseInt(refresh || '0', 10) || 3, false, loaded);
  else if (kind === 'jobs') startPanelPolling(id, 30, true);
}

// widget: compare fragments (server answers 304 → unchanged text) so a
// no-op poll doesn't reset scroll/selection. jobs: the label always carries
// the current time, so every poll redraws — the timestamp is the point.
function startPanelPolling(id, seconds, alwaysRedraw, seedHtml = null) {
  stopPanelPolling();
  lastPolledHtml = seedHtml;
  const tick = async () => {
    try {
      const { ok, html } = await fetchPanelFragment(id, 'no-cache');
      if (!ok) { setPanel(`<div class="output-box error">${esc(html.trim())}</div>`); return; }
      if (!alwaysRedraw) {
        if (html === lastPolledHtml) return;
        lastPolledHtml = html;
        setPanel(html);
        return;
      }
      setPanel(`
        <div class="output-label">Job Log
          <span style="font-weight:400;text-transform:none;letter-spacing:0;color:var(--n3);font-size:10px">
            · aktualisiert ${new Date().toLocaleTimeString('de')}
          </span>
        </div>
        ${html}
      `);
    } catch (e) {
      /* Netzwerk-Fehler: letzten Stand stehen lassen, nächster Tick versucht es neu */
    }
  };
  // Ohne Saat (jobs) sofort einmal ziehen — dort trägt erst der Tick den
  // Zeitstempel bei, auf den es bei einem Job-Log ankommt.
  if (!seedHtml) tick();
  panelTimer = setInterval(tick, seconds * 1000);
}

function openPanel(btn, push) {
  stopPanelPolling();
  if (activeStream) { activeStream.close(); activeStream = null; }
  if (activeBtn) activeBtn.classList.remove('active');
  btn.classList.add('active');
  activeBtn = btn;

  if (push) history.pushState({ panel: btn.dataset.id }, '', PREFIX + '/panel/' + encodeURIComponent(btn.dataset.id));
  loadPanel(btn);
}

function findPanelButton(id) {
  return id ? document.querySelector(`.btn[data-panel][data-id="${CSS.escape(id)}"]`) : null;
}

window.addEventListener('popstate', () => {
  const match = location.pathname.match(/\/panel\/([\w-]+)$/);
  const id  = match ? match[1] : ACTIVE_PANEL;
  const btn = findPanelButton(id);
  if (btn) openPanel(btn, false);
});

// Klick auf den Stage-Titel oben → zurück zur Home-Ansicht (default-Panel).
const title = document.querySelector('header h1');
if (title) {
  title.addEventListener('click', () => {
    const btn = findPanelButton(ACTIVE_PANEL);
    if (btn) openPanel(btn, true);
  });
  title.style.setProperty('cursor', 'pointer');
}

// Ein reines Board hat keine Buttons — dann braucht es auch keine Sidebar.
if (!aside.querySelector('.btn')) document.body.classList.add('no-sidebar');

// Initial: das Default-Panel ist bereits serverseitig als aktiver Button
// markiert — lädt hier nur dessen Inhalt nach.
(() => {
  const btn = findPanelButton(ACTIVE_PANEL);
  if (btn) { activeBtn = btn; loadPanel(btn); }
})();

/* ── Mobile-Drawer ─────────────────────────────────────── */
// Muss mit der Drawer-Query in style.css übereinstimmen (iPad mini hochkant
// = 744 pt, liegt darunter).
const MOBILE_BREAKPOINT = 834;
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
    if (btn.dataset.type === 'panel') {
      btn.classList.add('loading');
      openPanel(btn, true);
      if (isMobile()) setDrawer(false);
      return;
    }

    stopPanelPolling();
    if (activeStream) { activeStream.close(); activeStream = null; }
    if (activeBtn)    activeBtn.classList.remove('active');
    btn.classList.add('active', 'loading');
    activeBtn = btn;

    // Drawer schliessen auf Mobile, damit der Panel-Inhalt sichtbar wird
    if (isMobile()) setDrawer(false);

    const { type, id, url, placeholder, format } = btn.dataset;

    if      (type === 'action') runAction(id, url, btn, format);
    else if (type === 'stream') runStream(id, btn, format);
    else if (type === 'input')  renderInput(id, url, placeholder, btn);
    else                        runAction(id, url, btn);
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
    const badge = document.getElementById('live-badge');
    if (badge) badge.remove();
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
/* Die Datei-Liste kommt bereits gerendert im Panel-Fragment (render_notes_panel
   in 55-stage.rb) — hier werden nur noch die Klicks auf die Liste verdrahtet. */
function wireNotes() {
  const nav = document.getElementById('notes-nav');
  if (!nav) return;
  nav.querySelectorAll('.note-item').forEach(item => {
    item.addEventListener('click', () => {
      nav.querySelectorAll('.note-item').forEach(i => i.classList.remove('active'));
      item.classList.add('active');
      const content = document.getElementById('notes-content');
      content.innerHTML = '<div class="notes-loading">Lade…</div>';
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
}

/* ── Util ───────────────────────────────────────────────── */
function setPanel(html) {
  panel.classList.remove('notes-active');
  panel.innerHTML = html;
  panel.scrollTop = 0;
}

function esc(str) {
  return String(str)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;')
    .replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}
