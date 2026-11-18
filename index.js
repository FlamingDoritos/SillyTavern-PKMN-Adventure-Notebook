/*
 * PKMN Adventure Notebook — SillyTavern extension
 * Receives the adventure log from the mGBA script (pkmn_notebook.lua) and injects it into the prompt
 * like an Author's Note: position, depth, role, frequency, WI scanning, per-chat overrides, chat notes.
 */

const MODULE = 'pkmn_notebook';
const PROMPT_KEY = 'PKMN_ADVENTURE_NOTEBOOK';
const VERSION = '1.2.0';

// Same values as SillyTavern's extension_prompt_types / extension_prompt_roles
const POS = { NONE: -1, IN_PROMPT: 0, IN_CHAT: 1, BEFORE_PROMPT: 2 };
const ROLE = { SYSTEM: 0, USER: 1, ASSISTANT: 2 };

const DEFAULT_TEMPLATE = `[Pokémon Adventure Notebook — a record of what has actually happened in {{player}}'s playthrough of {{game}}. Keep the story consistent with it.]
Current location: {{location}} | Badges: {{badges}} | Play time: {{playtime}}
{{battle}}
Party:
{{party}}

Milestones:
{{milestones}}

Recent events:
{{recent}}
{{notes}}`;

const CATEGORIES = {
    travel: { label: 'Travel', types: ['location'] },
    trainer: { label: 'Trainer battles', types: ['battle_won', 'battle_lost', 'battle_draw', 'battle_end'] },
    wild: { label: 'Wild battles', types: ['wild_defeated', 'wild_fled', 'wild_escaped'] },
    party: { label: 'Catches & party', types: ['catch', 'party_join', 'party_leave', 'hatch', 'nickname'] },
    growth: { label: 'Level-ups & evolutions', types: ['level_up', 'evolution'] },
    moves: { label: 'Moves learned', types: ['move_learned'] },
    faint: { label: 'Faints', types: ['faint'] },
    milestone: { label: 'Badges & milestones', types: ['badge', 'champion'] },
    notes: { label: 'Notes', types: ['note', 'manual'] },
    session: { label: 'Sessions', types: ['session'] },
};
const TYPE_TO_CATEGORY = {};
for (const [cat, def] of Object.entries(CATEGORIES)) for (const t of def.types) TYPE_TO_CATEGORY[t] = cat;

const TYPE_ICONS = {
    location: 'fa-map-location-dot', battle_won: 'fa-trophy', battle_lost: 'fa-skull', battle_draw: 'fa-handshake',
    battle_end: 'fa-flag', wild_defeated: 'fa-paw', wild_fled: 'fa-person-running', wild_escaped: 'fa-wind',
    catch: 'fa-circle-dot', party_join: 'fa-user-plus', party_leave: 'fa-user-minus', hatch: 'fa-egg', nickname: 'fa-tag',
    level_up: 'fa-arrow-up', evolution: 'fa-dna', move_learned: 'fa-bolt', faint: 'fa-heart-crack', badge: 'fa-medal',
    champion: 'fa-crown', note: 'fa-pen', manual: 'fa-pen-nib', session: 'fa-gamepad',
};

const DEFAULT_PROMPT = { position: POS.IN_PROMPT, depth: 4, role: ROLE.SYSTEM, interval: 1, scan: false };

const DEFAULT_SETTINGS = {
    enabled: true,
    bridgeUrl: 'http://127.0.0.1:8888',
    autoSync: true,
    pollSeconds: 5,
    template: DEFAULT_TEMPLATE,
    prompt: { ...DEFAULT_PROMPT },
    recentCount: 15,
    minImportance: 1,
    milestoneCount: 20,
    partyStyle: 'detailed',
    includeGender: true,
    includeNature: true,
    categories: Object.fromEntries(Object.keys(CATEGORIES).map(k => [k, k !== 'session'])),
    maxStoredEvents: 4000,
    activeAdventure: null,
    adventures: {},
    panel: { top: 80, left: 80, width: 520, height: 640, tab: 'notebook' },
    newChatsEnabled: true,
};

let pollTimer = null;
let connected = false;
let lastError = '';
let syncing = false;
let logFilter = { text: '', category: 'all', showHidden: true };
let logLimit = 200;
let lastSavedAt = 0;

// ------------------------------------------------------------------------------------------------
// Settings & chat metadata
// ------------------------------------------------------------------------------------------------
function ctx() { return SillyTavern.getContext(); }

function settings() {
    const all = ctx().extensionSettings;
    if (!all[MODULE]) all[MODULE] = structuredClone(DEFAULT_SETTINGS);
    const s = all[MODULE];
    for (const [k, v] of Object.entries(DEFAULT_SETTINGS)) {
        if (s[k] === undefined) s[k] = structuredClone(v);
    }
    for (const [k, v] of Object.entries(DEFAULT_PROMPT)) if (s.prompt[k] === undefined) s.prompt[k] = v;
    for (const k of Object.keys(CATEGORIES)) if (s.categories[k] === undefined) s.categories[k] = k !== 'session';
    if (s.includeGender === undefined) s.includeGender = true;
    if (s.includeNature === undefined) s.includeNature = true;
    return s;
}
function save() { ctx().saveSettingsDebounced(); }

function inChat() {
    const c = ctx();
    return !!(c.groupId || c.characterId !== undefined) && !!c.getCurrentChatId?.();
}

function chatMeta() {
    const c = ctx();
    if (!c.chatMetadata) return null;
    if (!c.chatMetadata[MODULE]) {
        c.chatMetadata[MODULE] = { enabled: settings().newChatsEnabled, adventureId: null, override: false, notes: '', prompt: { ...settings().prompt }, template: null };
    }
    const m = c.chatMetadata[MODULE];
    if (!m.prompt) m.prompt = { ...settings().prompt };
    return m;
}
function saveChat() { const c = ctx(); (c.saveMetadataDebounced || c.saveMetadata)?.(); }

function effective() {
    const s = settings();
    const m = inChat() ? chatMeta() : null;
    const useChat = m && m.override;
    return {
        enabled: s.enabled && (!m || m.enabled !== false),
        prompt: useChat ? m.prompt : s.prompt,
        template: (useChat && m.template) ? m.template : s.template,
        notes: m ? (m.notes || '') : '',
        adventureId: (m && m.adventureId) || s.activeAdventure,
    };
}

function adventure(id) {
    const s = settings();
    return s.adventures[id ?? effective().adventureId] || null;
}

// ------------------------------------------------------------------------------------------------
// Bridge (mGBA script) sync
// ------------------------------------------------------------------------------------------------
async function getJson(path, timeout = 4000) {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), timeout);
    try {
        const url = settings().bridgeUrl.replace(/\/+$/, '') + path;
        const res = await fetch(url, { cache: 'no-store', signal: ctrl.signal });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return await res.json();
    } finally {
        clearTimeout(t);
    }
}

function eventKey(e) { return `${e.seq}:${e.t}`; }

function ensureAdventure(id, status) {
    const s = settings();
    if (!s.adventures[id]) {
        s.adventures[id] = { id, game: '', gameCode: '', player: '', lastSeq: 0, events: [], status: null, created: Date.now(), updated: Date.now() };
    }
    const a = s.adventures[id];
    if (status) {
        a.game = status.game?.title || a.game;
        a.gameCode = status.game?.code || a.gameCode;
        a.profile = status.game?.profile || a.profile;
        a.player = status.player || status.adventure?.player || a.player;
    }
    return a;
}

function mergeEvents(a, events) {
    const known = new Set(a.events.map(eventKey));
    let added = 0;
    for (const e of events) {
        const k = eventKey(e);
        if (known.has(k)) continue;
        known.add(k);
        a.events.push({ ...e });
        added++;
        if (typeof e.seq === 'number' && e.seq > a.lastSeq) a.lastSeq = e.seq;
    }
    if (added) {
        a.events.sort((x, y) => (x.t - y.t) || ((x.seq || 0) - (y.seq || 0)));
        const max = settings().maxStoredEvents;
        if (a.events.length > max) {
            // drop the oldest low-importance events first, never milestones or manual entries
            let excess = a.events.length - max;
            a.events = a.events.filter(e => {
                if (excess > 0 && !e.manual && (e.imp ?? 1) < 2) { excess--; return false; }
                return true;
            });
        }
    }
    return added;
}

async function sync({ manual = false } = {}) {
    if (syncing) return;
    syncing = true;
    try {
        const status = await getJson('/status');
        connected = true; lastError = '';
        if (!status.adventure) {
            setStatusLine(status.ready ? 'Connected — waiting for a save file to load in the game' : 'Connected — waiting for a game');
            if (manual) toastr.info('Connected to mGBA. Load your save in the game.', 'Adventure Notebook');
            return;
        }
        const s = settings();
        const a = ensureAdventure(status.adventure.id, status);
        if (status.adventure.seq < a.lastSeq) a.lastSeq = 0; // log was reset on the game side
        const ev = await getJson(`/events?since=${a.lastSeq}&adventure=${encodeURIComponent(a.id)}`, 8000);
        const added = mergeEvents(a, ev.events || []);
        a.status = status;
        a.updated = Date.now();
        if (s.activeAdventure !== a.id) {
            s.activeAdventure = a.id;
            refreshAdventureSelect();
        }
        if (inChat()) {
            const m = chatMeta();
            if (m && !m.adventureId) { m.adventureId = a.id; saveChat(); }
        }
        if (added || Date.now() - lastSavedAt > 60000) { save(); lastSavedAt = Date.now(); }
        await maybeFetchData(status);
        setStatusLine(`Connected — ${status.player || a.player} in ${status.location || '?'}${added ? ` (+${added} new)` : ''}`);
        if (manual) toastr.success(`Synced ${added} new event(s).`, 'Adventure Notebook');
        if (added || manual) { renderAll(); updatePrompt(); }
        else renderStatus();
    } catch (err) {
        connected = false;
        lastError = err?.name === 'AbortError' ? 'timed out' : (err?.message || String(err));
        setStatusLine(`Not connected (${lastError}). Is pkmn_notebook.lua running in mGBA and the game unpaused?`);
        if (manual) toastr.warning(`Could not reach the game at ${settings().bridgeUrl}: ${lastError}`, 'Adventure Notebook');
    } finally {
        syncing = false;
        renderConnection();
    }
}

function dataStoreKey(game) { return `pkmn_nb_data_${game.code}_${game.crc}`; }
let gameDataCache = null;
async function maybeFetchData(status) {
    if (!status?.game?.code) return;
    const key = dataStoreKey(status.game);
    if (gameDataCache?.key === key) return;
    try {
        const stored = localStorage.getItem(key);
        if (stored) { gameDataCache = { key, data: JSON.parse(stored) }; return; }
    } catch { /* ignore */ }
    try {
        const data = await getJson('/data', 15000);
        if (data?.ok) {
            gameDataCache = { key, data };
            try { localStorage.setItem(key, JSON.stringify(data)); } catch { /* quota */ }
            renderData();
        }
    } catch { /* not fatal */ }
}
function loadCachedGameData() {
    const a = adventure();
    const g = a?.status?.game;
    if (!g) return null;
    const key = dataStoreKey(g);
    if (gameDataCache?.key === key) return gameDataCache.data;
    try {
        const stored = localStorage.getItem(key);
        if (stored) { gameDataCache = { key, data: JSON.parse(stored) }; return gameDataCache.data; }
    } catch { /* ignore */ }
    return null;
}

function startPolling() {
    stopPolling();
    const s = settings();
    if (!s.autoSync) return;
    pollTimer = setInterval(() => sync(), Math.max(2, Number(s.pollSeconds) || 5) * 1000);
    sync();
}
function stopPolling() { if (pollTimer) clearInterval(pollTimer); pollTimer = null; }

// ------------------------------------------------------------------------------------------------
// Building the notebook text
// ------------------------------------------------------------------------------------------------
function visibleEvents(a) {
    if (!a) return [];
    const s = settings();
    return a.events.filter(e => !e.hidden && s.categories[TYPE_TO_CATEGORY[e.type] || 'notes'] !== false);
}

function eventLine(e) {
    const where = e.loc && !/^Arrived|^Returned/.test(e.text) && !(e.text || '').includes(e.loc) ? ` [${e.loc}]` : '';
    const when = e.pt ? `(${e.pt}) ` : '';
    return `- ${when}${e.text}${where}`;
}

function partyText(st, style) {
    const party = st?.party || [];
    if (!party.length) return '(no Pokémon yet)';
    return party.map(p => {
        if (p.isEgg) return '- An Egg';
        const s = settings();
        const nick = p.nickname && p.nickname.toUpperCase() !== (p.species || '').toUpperCase();
        const tags = [];
        if (nick) tags.push(p.species);
        if (s.includeGender && p.gender) tags.push(p.gender);
        const name = nick ? `${p.nickname}${tags.length ? ` (${tags.join(', ')})` : ''}` : `${p.species}${tags.length ? ` (${tags.join(', ')})` : ''}`;
        if (style === 'short') return `- ${name} Lv${p.level}${s.includeNature && p.nature ? `, ${p.nature} nature` : ''}${p.shiny ? ', shiny' : ''}`;
        const bits = [`Lv${p.level}`, `${p.hp}/${p.maxHP} HP`];
        if (p.status) bits.push(p.status === 'FNT' ? 'fainted' : p.status);
        if (s.includeNature && p.nature) bits.push(`${p.nature} nature`);
        if (p.shiny) bits.push('shiny');
        if (p.item) bits.push(`holding ${p.item}`);
        let line = `- ${name}: ${bits.join(', ')}`;
        if (p.moves?.length) line += `; moves: ${p.moves.join(', ')}`;
        if (p.metAt && style === 'full') line += `; met at ${p.metAt}${p.metLevel ? ` (Lv${p.metLevel})` : ''}`;
        return line;
    }).join('\n');
}

function battleText(st) {
    const b = st?.battle;
    if (!b) return '';
    const foes = (b.enemies || []).map(e => `${e.species} Lv${e.level}`).join(', ');
    return b.kind === 'trainer' ? `IN BATTLE right now against ${b.trainer || 'a trainer'} (${foes}).` : `IN BATTLE right now against a wild ${foes}.`;
}

function buildVars(a, notes) {
    const s = settings();
    const st = a?.status || {};
    const evs = visibleEvents(a);
    const recent = evs.filter(e => (e.imp ?? 1) >= s.minImportance || e.manual).slice(-Math.max(0, s.recentCount));
    const milestones = evs.filter(e => (e.imp ?? 1) >= 3 || e.pinned).slice(-Math.max(0, s.milestoneCount));
    const caught = (a?.events || []).filter(e => e.type === 'catch' && !e.hidden);
    const visited = [...new Set((a?.events || []).filter(e => e.type === 'location' && e.data?.to).map(e => e.data.to))];
    const badgeList = st.badgeList?.length ? ` (${st.badgeList.join(', ')})` : '';
    return {
        player: st.player || a?.player || '{{user}}',
        game: a?.game || st.game?.title || 'Pokémon',
        location: st.location || 'unknown',
        badges: `${st.badges ?? 0}/8${badgeList}`,
        badge_count: String(st.badges ?? 0),
        money: st.money != null ? `₽${st.money}` : 'unknown',
        playtime: st.playTime || 'unknown',
        party: partyText(st, s.partyStyle),
        party_short: partyText(st, 'short'),
        party_full: partyText(st, 'full'),
        battle: battleText(st),
        recent: recent.length ? recent.map(eventLine).join('\n') : '(nothing yet)',
        milestones: milestones.length ? milestones.map(eventLine).join('\n') : '(none yet)',
        caught: caught.length ? caught.map(e => `- ${e.text}`).join('\n') : '(none yet)',
        visited: visited.length ? visited.join(', ') : '(none yet)',
        last_event: evs.length ? evs[evs.length - 1].text : '',
        notes: notes ? `Notes: ${notes}` : '',
    };
}

function renderTemplate(template, vars) {
    let text = template.replace(/\{\{(\w+)\}\}/g, (m, k) => (k in vars ? vars[k] : m));
    text = text.replace(/\n{3,}/g, '\n\n').trim();
    try { text = ctx().substituteParams(text); } catch { /* ignore */ }
    return text;
}

function buildNotebook() {
    const eff = effective();
    const a = adventure(eff.adventureId);
    if (!a) return '';
    return renderTemplate(eff.template, buildVars(a, eff.notes));
}

// ------------------------------------------------------------------------------------------------
// Prompt injection (Author's Note style)
// ------------------------------------------------------------------------------------------------
function insertionCountdown(chat, interval) {
    // mirrors Author's Note: counts user messages
    let n = Array.isArray(chat) ? chat.filter(m => m.is_user).length : 0;
    if (interval === 1) n = 1;
    if (n <= 0 || interval <= 0) return -1;
    return n >= interval ? (n % interval) : (interval - n);
}

function updatePrompt(chatOverride) {
    const c = ctx();
    const eff = effective();
    const p = eff.prompt;
    if (!inChat() || !eff.enabled || !adventure(eff.adventureId)) {
        c.setExtensionPrompt(PROMPT_KEY, '', POS.NONE, 0);
        renderCountdown(null);
        return '';
    }
    const left = insertionCountdown(chatOverride || c.chat, Number(p.interval));
    const text = left === 0 ? buildNotebook() : '';
    c.setExtensionPrompt(PROMPT_KEY, text, Number(p.position), Number(p.depth), !!p.scan, Number(p.role));
    renderCountdown(left);
    return text;
}

globalThis.pkmnNotebookInterceptor = async function (chat) {
    try {
        if (settings().autoSync && !syncing) await Promise.race([sync(), new Promise(r => setTimeout(r, 1500))]);
        updatePrompt(chat);
    } catch (e) { console.error('[Adventure Notebook]', e); }
};

// ------------------------------------------------------------------------------------------------
// UI
// ------------------------------------------------------------------------------------------------
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function panelHtml() {
    const catBoxes = Object.entries(CATEGORIES).map(([k, d]) =>
        `<label class="checkbox_label"><input type="checkbox" class="pkmn_cat" data-cat="${k}"> ${d.label}</label>`).join('');
    return `
<div id="pkmnNotebookPanel" class="pkmn-panel" style="display:none">
  <div id="pkmnNotebookPanelheader" class="pkmn-panel-header">
    <span class="fa-solid fa-book-open"></span>
    <b>Adventure Notebook</b>
    <span id="pkmn_conn_dot" class="pkmn-dot" title="Not connected"></span>
    <span class="pkmn-grow"></span>
    <div id="pkmn_sync_btn" class="menu_button menu_button_icon fa-solid fa-rotate" title="Sync now"></div>
    <div id="pkmn_close_btn" class="fa-solid fa-circle-xmark hoverglow pkmn-close" title="Close"></div>
  </div>
  <div class="pkmn-tabs">
    <div class="pkmn-tab" data-tab="notebook"><i class="fa-solid fa-feather"></i> Notebook</div>
    <div class="pkmn-tab" data-tab="log"><i class="fa-solid fa-list"></i> Log</div>
    <div class="pkmn-tab" data-tab="game"><i class="fa-solid fa-gamepad"></i> Game</div>
    <div class="pkmn-tab" data-tab="data"><i class="fa-solid fa-database"></i> Data</div>
  </div>
  <div class="pkmn-body">

    <!-- NOTEBOOK -->
    <div class="pkmn-page" data-page="notebook">
      <div class="pkmn-row">
        <label class="checkbox_label"><input type="checkbox" id="pkmn_enabled"> Inject notebook</label>
        <label class="checkbox_label"><input type="checkbox" id="pkmn_chat_enabled"> Enabled in this chat</label>
      </div>
      <div class="pkmn-row">
        <label for="pkmn_adv_select">Adventure for this chat</label>
        <select id="pkmn_adv_select" class="text_pole"></select>
      </div>

      <details class="pkmn-details" open>
        <summary><b>Current party</b></summary>
        <div id="pkmn_party_mini" class="pkmn-party pkmn-party-mini"></div>
      </details>

      <div class="pkmn-row pkmn-scope">
        <label class="checkbox_label" title="Like Author's Note chat-specific settings: this chat gets its own template, position, depth, role and frequency">
          <input type="checkbox" id="pkmn_override"> Use custom settings for this chat</label>
        <small id="pkmn_scope_label" class="pkmn-muted"></small>
      </div>

      <label for="pkmn_template"><b>Notebook template</b> <small class="pkmn-muted">placeholders: {{party}} {{recent}} {{milestones}} {{location}} {{badges}} {{battle}} {{caught}} {{visited}} {{player}} {{game}} {{money}} {{playtime}} {{notes}} {{party_short}} {{party_full}} {{last_event}} — ST macros like {{user}}/{{char}} work too</small></label>
      <textarea id="pkmn_template" class="text_pole textarea_compact" rows="9"></textarea>
      <div class="pkmn-row"><div id="pkmn_template_reset" class="menu_button">Reset template</div><span class="pkmn-grow"></span><small id="pkmn_tokens" class="pkmn-muted"></small></div>

      <label for="pkmn_notes"><b>Chat notes</b> <small class="pkmn-muted">(this chat only, fills {{notes}})</small></label>
      <textarea id="pkmn_notes" class="text_pole textarea_compact" rows="3" placeholder="Your own notes for this chat: story beats, rules (e.g. Nuzlocke), relationships..."></textarea>

      <div class="pkmn-grid">
        <div>
          <b>Placement</b>
          <label class="checkbox_label"><input type="radio" name="pkmn_pos" value="2"> Before Main Prompt / Story String</label>
          <label class="checkbox_label"><input type="radio" name="pkmn_pos" value="0"> After Main Prompt / Story String</label>
          <label class="checkbox_label"><input type="radio" name="pkmn_pos" value="1"> In-chat @ Depth
            <input id="pkmn_depth" class="text_pole pkmn-num" type="number" min="0" max="10000"> as
            <select id="pkmn_role" class="text_pole pkmn-role"><option value="0">System</option><option value="1">User</option><option value="2">Assistant</option></select></label>
        </div>
        <div>
          <b>Frequency</b>
          <label>Insert every <input id="pkmn_interval" class="text_pole pkmn-num" type="number" min="0" max="999"> user messages <small class="pkmn-muted">(0 = disable, 1 = always)</small></label>
          <small id="pkmn_countdown" class="pkmn-muted"></small>
          <label class="checkbox_label"><input type="checkbox" id="pkmn_scan"> Include in World Info scanning</label>
        </div>
      </div>

      <details class="pkmn-details">
        <summary><b>What goes into the notebook</b></summary>
        <div class="pkmn-grid">
          <label>Recent events: <input id="pkmn_recent" class="text_pole pkmn-num" type="number" min="0" max="500"></label>
          <label>Milestones: <input id="pkmn_milestones" class="text_pole pkmn-num" type="number" min="0" max="500"></label>
          <label>Min. importance for recent:
            <select id="pkmn_minimp" class="text_pole"><option value="0">0 – everything</option><option value="1">1 – normal</option><option value="2">2 – notable</option><option value="3">3 – milestones only</option></select></label>
          <label>Party detail:
            <select id="pkmn_partystyle" class="text_pole"><option value="short">Short</option><option value="detailed">Detailed</option><option value="full">Full (+ where met)</option></select></label>
        </div>
        <div class="pkmn-cats">
          <label class="checkbox_label"><input type="checkbox" id="pkmn_inc_gender"> Gender in party list</label>
          <label class="checkbox_label"><input type="checkbox" id="pkmn_inc_nature"> Nature in party list</label>
        </div>
        <div class="pkmn-cats">${catBoxes}</div>
      </details>

      <details class="pkmn-details" id="pkmn_preview_box">
        <summary><b>Preview</b> <small class="pkmn-muted">(exactly what will be sent)</small></summary>
        <pre id="pkmn_preview" class="pkmn-preview"></pre>
      </details>
    </div>

    <!-- LOG -->
    <div class="pkmn-page" data-page="log">
      <div class="pkmn-row">
        <input id="pkmn_log_search" class="text_pole" placeholder="Search..." style="flex:1">
        <select id="pkmn_log_cat" class="text_pole" style="flex:0 0 auto;width:auto"><option value="all">All</option>${Object.entries(CATEGORIES).map(([k, d]) => `<option value="${k}">${d.label}</option>`).join('')}</select>
        <label class="checkbox_label" title="Show events you hid from the prompt"><input type="checkbox" id="pkmn_log_hidden"> hidden</label>
      </div>
      <div class="pkmn-row">
        <input id="pkmn_manual_text" class="text_pole" placeholder="Add your own entry (story beat, decision, rule...)" style="flex:1">
        <div id="pkmn_manual_add" class="menu_button menu_button_icon"><i class="fa-solid fa-plus"></i> Add</div>
      </div>
      <small class="pkmn-muted">Click a line to edit it. ★ = importance (click to change, 3 = milestone). <i class="fa-solid fa-thumbtack"></i> pins to milestones, <i class="fa-solid fa-eye"></i> hides from the prompt.</small>
      <div id="pkmn_log" class="pkmn-log"></div>
    </div>

    <!-- GAME -->
    <div class="pkmn-page" data-page="game">
      <div class="pkmn-row">
        <label for="pkmn_url">mGBA bridge</label>
        <input id="pkmn_url" class="text_pole" style="flex:1">
        <div id="pkmn_connect" class="menu_button">Connect</div>
      </div>
      <div class="pkmn-row">
        <label class="checkbox_label"><input type="checkbox" id="pkmn_autosync"> Auto-sync every</label>
        <input id="pkmn_poll" class="text_pole pkmn-num" type="number" min="2" max="600"> s
        <label class="checkbox_label" title="New chats start with the notebook enabled"><input type="checkbox" id="pkmn_newchats"> On for new chats</label>
      </div>
      <div id="pkmn_status_line" class="pkmn-status-line"></div>
      <div id="pkmn_live" class="pkmn-live"></div>
      <hr>
      <b>Adventures</b>
      <div id="pkmn_adv_list" class="pkmn-adv-list"></div>
      <div class="pkmn-row">
        <div id="pkmn_import" class="menu_button menu_button_icon" title="Import a logs/*.jsonl file written by the mGBA script, or an exported .json"><i class="fa-solid fa-file-import"></i> Import log</div>
        <input id="pkmn_import_file" type="file" accept=".jsonl,.json,.txt" style="display:none">
        <div id="pkmn_export" class="menu_button menu_button_icon"><i class="fa-solid fa-file-export"></i> Export selected</div>
      </div>
    </div>

    <!-- DATA -->
    <div class="pkmn-page" data-page="data">
      <small class="pkmn-muted">Everything below was read straight out of the ROM by the mGBA script, so romhack names are used.</small>
      <div class="pkmn-row">
        <select id="pkmn_data_cat" class="text_pole" style="width:auto;flex:0 0 auto">
          <option value="species">Pokémon</option><option value="moves">Moves</option><option value="abilities">Abilities</option>
          <option value="items">Items</option><option value="types">Types</option><option value="maps">Maps</option>
          <option value="trainers">Trainers</option><option value="trainerClasses">Trainer classes</option>
        </select>
        <input id="pkmn_data_search" class="text_pole" placeholder="Search..." style="flex:1">
        <div id="pkmn_data_refresh" class="menu_button menu_button_icon" title="Re-download from the game"><i class="fa-solid fa-rotate"></i></div>
      </div>
      <div id="pkmn_data_info" class="pkmn-muted"></div>
      <div id="pkmn_data_list" class="pkmn-data-list"></div>
    </div>

  </div>
</div>`;
}

function settingsDrawerHtml() {
    return `
<div class="pkmn-notebook-settings">
  <div class="inline-drawer">
    <div class="inline-drawer-toggle inline-drawer-header">
      <b>PKMN Adventure Notebook</b>
      <div class="inline-drawer-icon fa-solid fa-circle-chevron-down down"></div>
    </div>
    <div class="inline-drawer-content">
      <div class="pkmn-row">
        <div id="pkmn_open_from_settings" class="menu_button menu_button_icon"><i class="fa-solid fa-book-open"></i> Open notebook</div>
        <span id="pkmn_settings_status" class="pkmn-muted"></span>
      </div>
      <small class="pkmn-muted">Also in the <i class="fa-solid fa-magic-wand-sparkles"></i> Extensions menu. Run <code>pkmn_notebook.lua</code> in mGBA (Tools → Scripting).</small>
    </div>
  </div>
</div>`;
}

function setStatusLine(text) {
    $('#pkmn_status_line').text(text);
    $('#pkmn_settings_status').text(text);
}

function renderConnection() {
    $('#pkmn_conn_dot').toggleClass('pkmn-on', connected).attr('title', connected ? 'Connected to mGBA' : `Not connected${lastError ? `: ${lastError}` : ''}`);
}

function showTab(tab) {
    settings().panel.tab = tab; save();
    $('.pkmn-tab').removeClass('pkmn-active').filter(`[data-tab="${tab}"]`).addClass('pkmn-active');
    $('.pkmn-page').hide().filter(`[data-page="${tab}"]`).show();
    if (tab === 'data') renderData();
    if (tab === 'log') renderLog();
}

function openPanel() {
    const $p = $('#pkmnNotebookPanel');
    const s = settings();
    const vw = window.innerWidth, vh = window.innerHeight;
    const w = Math.min(s.panel.width, vw - 10), h = Math.min(s.panel.height, vh - 10);
    $p.css({ top: Math.max(0, Math.min(s.panel.top, vh - 60)), left: Math.max(0, Math.min(s.panel.left, vw - 120)), width: w, height: h, display: 'flex' });
    renderAll();
    showTab(s.panel.tab || 'notebook');
    if (!connected) sync();
}
function closePanel() { $('#pkmnNotebookPanel').hide(); }

function makeDraggable() {
    const $p = $('#pkmnNotebookPanel');
    const header = document.getElementById('pkmnNotebookPanelheader');
    let sx, sy, st, sl, dragging = false;
    header.addEventListener('pointerdown', (e) => {
        if ($(e.target).closest('.menu_button, .pkmn-close').length) return;
        dragging = true; sx = e.clientX; sy = e.clientY;
        const r = $p[0].getBoundingClientRect(); st = r.top; sl = r.left;
        header.setPointerCapture(e.pointerId);
    });
    header.addEventListener('pointermove', (e) => {
        if (!dragging) return;
        const top = Math.max(0, Math.min(window.innerHeight - 40, st + e.clientY - sy));
        const left = Math.max(-200, Math.min(window.innerWidth - 80, sl + e.clientX - sx));
        $p.css({ top, left });
    });
    header.addEventListener('pointerup', () => {
        if (!dragging) return;
        dragging = false;
        const r = $p[0].getBoundingClientRect();
        Object.assign(settings().panel, { top: Math.round(r.top), left: Math.round(r.left) }); save();
    });
    new ResizeObserver(() => {
        if ($p.is(':visible')) {
            const r = $p[0].getBoundingClientRect();
            if (r.width > 200 && r.height > 150) Object.assign(settings().panel, { width: Math.round(r.width), height: Math.round(r.height) });
        }
    }).observe($p[0]);
}

function refreshAdventureSelect() {
    const s = settings();
    const $sel = $('#pkmn_adv_select').empty();
    const advs = Object.values(s.adventures).sort((a, b) => b.updated - a.updated);
    $sel.append(`<option value="">Active game adventure${s.activeAdventure ? ` (${esc(s.adventures[s.activeAdventure]?.player || '')})` : ''}</option>`);
    for (const a of advs) $sel.append(`<option value="${esc(a.id)}">${esc(a.player || '?')} — ${esc(a.game || a.gameCode)} (${a.events.length} events)</option>`);
    const m = inChat() ? chatMeta() : null;
    $sel.val(m?.adventureId || '');
    $sel.prop('disabled', !inChat());
}

function promptTarget() {
    const m = inChat() ? chatMeta() : null;
    return (m && m.override) ? m.prompt : settings().prompt;
}

function renderNotebook() {
    const s = settings();
    const m = inChat() ? chatMeta() : null;
    const p = promptTarget();
    $('#pkmn_enabled').prop('checked', s.enabled);
    $('#pkmn_chat_enabled').prop('checked', m ? m.enabled !== false : false).prop('disabled', !m);
    $('#pkmn_override').prop('checked', !!m?.override).prop('disabled', !m);
    $('#pkmn_scope_label').text(!m ? 'Open a chat to use chat-specific settings. Editing defaults.' : (m.override ? 'Editing THIS CHAT\'s settings' : 'Editing default settings (all chats)'));
    $('#pkmn_template').val((m?.override && m.template) ? m.template : s.template);
    $('#pkmn_notes').val(m?.notes || '').prop('disabled', !m);
    $(`input[name="pkmn_pos"][value="${p.position}"]`).prop('checked', true);
    $('#pkmn_depth').val(p.depth);
    $('#pkmn_role').val(String(p.role));
    $('#pkmn_interval').val(p.interval);
    $('#pkmn_scan').prop('checked', !!p.scan);
    $('#pkmn_recent').val(s.recentCount);
    $('#pkmn_milestones').val(s.milestoneCount);
    $('#pkmn_minimp').val(String(s.minImportance));
    $('#pkmn_partystyle').val(s.partyStyle);
    $('#pkmn_inc_gender').prop('checked', !!s.includeGender);
    $('#pkmn_inc_nature').prop('checked', !!s.includeNature);
    $('.pkmn_cat').each(function () { $(this).prop('checked', s.categories[$(this).data('cat')] !== false); });
    refreshAdventureSelect();
    renderPreview();
}

let previewTimer = null;
function renderPreview() {
    clearTimeout(previewTimer);
    previewTimer = setTimeout(async () => {
        const text = buildNotebook();
        $('#pkmn_preview').text(text || '(nothing to inject yet — connect to the game or import a log)');
        try {
            const n = text ? await ctx().getTokenCountAsync(text) : 0;
            $('#pkmn_tokens').text(`Tokens: ${n}`);
        } catch { $('#pkmn_tokens').text(''); }
        updatePrompt();
    }, 250);
}

function renderCountdown(left) {
    const $c = $('#pkmn_countdown');
    if (left === null) $c.text(inChat() ? '(disabled)' : '(no chat open)');
    else if (left < 0) $c.text('(disabled)');
    else $c.text(left === 0 ? 'Will be inserted with the next message' : `Will be inserted in ${left} message(s)`);
}

function fmtTime(e) {
    const d = new Date((e.t || 0) * 1000);
    const date = isNaN(d) ? '' : d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
    return e.pt ? `${e.pt}` : date;
}

function renderLog() {
    const a = adventure();
    const $log = $('#pkmn_log').empty();
    if (!a) { $log.html('<div class="pkmn-muted pkmn-empty">No adventure yet. Start the mGBA script and load your save, or import a log on the Game tab.</div>'); return; }
    const q = logFilter.text.toLowerCase();
    let list = a.events.filter(e => !e.deleted &&
        (logFilter.showHidden || !e.hidden) &&
        (logFilter.category === 'all' || TYPE_TO_CATEGORY[e.type] === logFilter.category) &&
        (!q || (e.text || '').toLowerCase().includes(q) || (e.loc || '').toLowerCase().includes(q)));
    const total = list.length;
    list = list.slice(-logLimit).reverse();
    const rows = list.map(e => {
        const k = esc(eventKey(e));
        const imp = e.imp ?? 1;
        return `<div class="pkmn-ev pkmn-imp${imp}${e.hidden ? ' pkmn-ev-hidden' : ''}${e.pinned ? ' pkmn-pinned' : ''}" data-key="${k}">
          <i class="fa-solid ${TYPE_ICONS[e.type] || 'fa-circle'} pkmn-ev-icon" title="${esc(e.type)}"></i>
          <div class="pkmn-ev-main">
            <div class="pkmn-ev-text" title="Click to edit">${esc(e.text)}</div>
            <div class="pkmn-ev-meta">${esc(fmtTime(e))}${e.loc ? ` · ${esc(e.loc)}` : ''}${e.edited ? ' · edited' : ''}${e.manual ? ' · manual' : ''}</div>
          </div>
          <div class="pkmn-ev-tools">
            <span class="pkmn-imp" title="Importance ${imp}">${'★'.repeat(imp)}${'☆'.repeat(3 - imp)}</span>
            <i class="fa-solid fa-thumbtack pkmn-pin" title="Pin to milestones"></i>
            <i class="fa-solid ${e.hidden ? 'fa-eye-slash' : 'fa-eye'} pkmn-hide" title="${e.hidden ? 'Hidden from the prompt — click to include it again' : 'Included in the prompt — click to hide it from the prompt'}"></i>
            <i class="fa-solid fa-trash-can pkmn-del" title="Delete"></i>
          </div>
        </div>`;
    }).join('');
    $log.html(rows || '<div class="pkmn-muted pkmn-empty">No matching events.</div>');
    if (total > logLimit) $log.append(`<div class="menu_button pkmn-more">Show older (${total - logLimit} more)</div>`);
}

function findEvent(key) {
    const a = adventure();
    return a ? a.events.find(e => eventKey(e) === key) : null;
}

// Built-in sparkle (no icon font needed): one big four-point star and a small one, like the games' shiny sparkle
const SHINY_ICON = `<span class="pkmn-shiny" title="Shiny!"><svg viewBox="0 0 24 24" width="1em" height="1em" aria-label="Shiny">
  <path d="M10 1.5 L12.2 7.8 L18.5 10 L12.2 12.2 L10 18.5 L7.8 12.2 L1.5 10 L7.8 7.8 Z" fill="currentColor"/>
  <path d="M19 14 L20 17 L23 18 L20 19 L19 22 L18 19 L15 18 L18 17 Z" fill="currentColor"/>
</svg></span>`;

function genderIcon(g) {
    if (g === 'male') return '<span class="pkmn-gender pkmn-male" title="Male">♂</span>';
    if (g === 'female') return '<span class="pkmn-gender pkmn-female" title="Female">♀</span>';
    if (g === 'genderless') return '<span class="pkmn-gender pkmn-genderless" title="Genderless">∅</span>';
    return '';
}

function partyCardsHtml(st, compact) {
    return (st?.party || []).map(p => {
        const pct = p.maxHP ? Math.round(100 * p.hp / p.maxHP) : 0;
        const cls = pct > 50 ? 'pkmn-hp-ok' : pct > 20 ? 'pkmn-hp-mid' : 'pkmn-hp-low';
        const shiny = p.shiny ? SHINY_ICON : '';
        const details = [];
        if (!p.isEgg && p.nature) details.push(`${esc(p.nature)} nature`);
        if (!compact) {
            details.push(`${p.hp}/${p.maxHP} HP`);
            if (p.item) details.push(esc(p.item));
            if (p.moves?.length) details.push(esc(p.moves.join(', ')));
        }
        return `<div class="pkmn-mon${p.shiny ? ' pkmn-mon-shiny' : ''}">
          <div><b>${esc(p.isEgg ? 'Egg' : p.name)}</b>${p.isEgg ? '' : genderIcon(p.gender)}${!p.isEgg && p.name !== p.species ? ` <small>(${esc(p.species)})</small>` : ''} <span class="pkmn-lv">Lv${p.level}${shiny}</span>${p.status ? ` <span class="pkmn-statusbadge">${esc(p.status)}</span>` : ''}</div>
          <div class="pkmn-hp"><div class="pkmn-hp-fill ${cls}" style="width:${pct}%"></div></div>
          ${details.length ? `<small class="pkmn-muted">${details.join(' · ')}</small>` : ''}
        </div>`;
    }).join('');
}

function renderStatus() {
    const a = adventure();
    const st = a?.status;
    const $live = $('#pkmn_live');
    $('#pkmn_party_mini').html(st?.party?.length ? partyCardsHtml(st, true) : '<span class="pkmn-muted">No party data yet — connect to the game.</span>');
    if (!st) { $live.html('<div class="pkmn-muted">No live data yet.</div>'); return; }
    const party = partyCardsHtml(st, false);
    $live.html(`
      <div class="pkmn-live-head"><b>${esc(st.player || '')}</b> · ${esc(st.location || '?')} · ${st.badges ?? 0}/8 badges${st.money != null ? ` · ₽${st.money}` : ''}${st.playTime ? ` · ${esc(st.playTime)}` : ''}</div>
      <div class="pkmn-muted">${esc(st.game?.title || '')} [${esc(st.game?.code || '')}] · ${esc(st.game?.profile || '')}${st.game?.ram === 'auto' ? ' · battles tracked from the enemy party' : ''}</div>
      ${st.battle ? `<div class="pkmn-battle">${esc(battleText(st))}</div>` : ''}
      <div class="pkmn-party">${party || '<span class="pkmn-muted">No Pokémon yet</span>'}</div>`);
}

function renderAdventures() {
    const s = settings();
    const sel = adventure();
    const html = Object.values(s.adventures).sort((a, b) => b.updated - a.updated).map(a => `
      <div class="pkmn-adv${sel && sel.id === a.id ? ' pkmn-selected' : ''}" data-id="${esc(a.id)}">
        <div><b>${esc(a.player || '?')}</b> — ${esc(a.game || a.gameCode || '')}<br><small class="pkmn-muted">${a.events.length} events · last update ${new Date(a.updated).toLocaleString()}${s.activeAdventure === a.id ? ' · <b>active in game</b>' : ''}</small></div>
        <span class="pkmn-grow"></span>
        <i class="fa-solid fa-pen pkmn-adv-rename" title="Rename player"></i>
        <i class="fa-solid fa-trash-can pkmn-adv-del" title="Delete adventure"></i>
      </div>`).join('');
    $('#pkmn_adv_list').html(html || '<div class="pkmn-muted">None yet.</div>');
}

function renderData() {
    if ($('#pkmnNotebookPanel').css('display') === 'none') return;
    const data = loadCachedGameData();
    const cat = $('#pkmn_data_cat').val() || 'species';
    const q = String($('#pkmn_data_search').val() || '').toLowerCase();
    if (!data) { $('#pkmn_data_info').text('No game data yet — connect to the running game.'); $('#pkmn_data_list').empty(); return; }
    const found = data.found || {};
    const foundKey = cat === 'maps' ? 'mapsecs' : cat;
    const list = data[cat] || [];
    $('#pkmn_data_info').text(`${data.game?.title || ''} — ${list.length} entries (${found[foundKey] || '?'})`);
    const rows = list.filter(r => !q || JSON.stringify(r).toLowerCase().includes(q)).slice(0, 1500).map(r => {
        if (cat === 'trainers') return `<div class="pkmn-data-row"><span class="pkmn-id">#${r.id}</span> ${esc(r.class)} <b>${esc(r.name)}</b>${r.size ? ` <small class="pkmn-muted">${r.size} Pokémon</small>` : ''}</div>`;
        return `<div class="pkmn-data-row"><span class="pkmn-id">#${r.id}</span> ${esc(r.name)}</div>`;
    }).join('');
    $('#pkmn_data_list').html(rows || '<div class="pkmn-muted">Nothing found.</div>');
}

function renderAll() {
    if (!$('#pkmnNotebookPanel').length) return;
    renderNotebook();
    renderStatus();
    renderAdventures();
    renderConnection();
    if ($('.pkmn-page[data-page="log"]').is(':visible')) renderLog();
    $('#pkmn_url').val(settings().bridgeUrl);
    $('#pkmn_autosync').prop('checked', settings().autoSync);
    $('#pkmn_poll').val(settings().pollSeconds);
    $('#pkmn_newchats').prop('checked', settings().newChatsEnabled);
}

// ------------------------------------------------------------------------------------------------
// Import / export
// ------------------------------------------------------------------------------------------------
function importText(text, fileName) {
    const s = settings();
    let events = [];
    let meta = {};
    const trimmed = text.trim();
    if (trimmed.startsWith('{') && !trimmed.includes('\n{')) {
        const obj = JSON.parse(trimmed);
        if (Array.isArray(obj.events)) { events = obj.events; meta = obj; } else if (obj.text) events = [obj];
    } else {
        for (const line of trimmed.split(/\r?\n/)) {
            if (!line.trim()) continue;
            try { events.push(JSON.parse(line)); } catch { /* skip bad line */ }
        }
    }
    if (!events.length) throw new Error('No events found in that file.');
    const id = meta.id || String(fileName || 'imported').replace(/\.(jsonl|json|txt)$/i, '');
    const a = ensureAdventure(id, null);
    if (meta.player) a.player = meta.player;
    if (meta.game) a.game = meta.game;
    if (meta.gameCode) a.gameCode = meta.gameCode;
    if (meta.status && !a.status) a.status = meta.status;
    if (!a.player) {
        const m = id.match(/^[A-Z]{3}-[A-Z0-9]{4}-(.+)-\d+$/);
        if (m) a.player = m[1].replace(/_/g, ' ');
    }
    const added = mergeEvents(a, events);
    a.updated = Date.now();
    save();
    return { a, added };
}

function exportAdventure() {
    const a = adventure();
    if (!a) { toastr.warning('No adventure selected.'); return; }
    const blob = new Blob([JSON.stringify(a, null, 2)], { type: 'application/json' });
    const link = document.createElement('a');
    link.href = URL.createObjectURL(blob);
    link.download = `${a.id}.json`;
    link.click();
    setTimeout(() => URL.revokeObjectURL(link.href), 2000);
}

// ------------------------------------------------------------------------------------------------
// Event handlers
// ------------------------------------------------------------------------------------------------
function bind() {
    const $p = $('#pkmnNotebookPanel');
    $p.on('click', '.pkmn-tab', function () { showTab($(this).data('tab')); });
    $('#pkmn_close_btn').on('click', closePanel);
    $('#pkmn_sync_btn').on('click', () => sync({ manual: true }));

    // Notebook tab
    $('#pkmn_enabled').on('change', function () { settings().enabled = this.checked; save(); renderPreview(); });
    $('#pkmn_chat_enabled').on('change', function () { const m = chatMeta(); if (m) { m.enabled = this.checked; saveChat(); renderPreview(); } });
    $('#pkmn_adv_select').on('change', function () {
        const m = chatMeta(); if (!m) return;
        m.adventureId = $(this).val() || null; saveChat(); renderAll(); renderLog();
    });
    $('#pkmn_override').on('change', function () {
        const m = chatMeta(); if (!m) return;
        m.override = this.checked;
        if (m.override) {
            m.prompt = { ...settings().prompt, ...(m.promptSaved || {}) };
            if (!m.template) m.template = settings().template;
        }
        saveChat(); renderNotebook();
    });
    $('#pkmn_template').on('input', function () {
        const m = inChat() ? chatMeta() : null;
        if (m && m.override) { m.template = this.value; saveChat(); } else { settings().template = this.value; save(); }
        renderPreview();
    });
    $('#pkmn_template_reset').on('click', () => {
        const m = inChat() ? chatMeta() : null;
        if (m && m.override) { m.template = DEFAULT_TEMPLATE; saveChat(); } else { settings().template = DEFAULT_TEMPLATE; save(); }
        renderNotebook();
    });
    $('#pkmn_notes').on('input', function () { const m = chatMeta(); if (m) { m.notes = this.value; saveChat(); renderPreview(); } });

    const promptField = (sel, key, parse, ev = 'input') => $(sel).on(ev, function () {
        const p = promptTarget();
        p[key] = parse(this);
        const m = inChat() ? chatMeta() : null;
        if (m && m.override) { m.promptSaved = { ...m.prompt }; saveChat(); } else save();
        renderPreview();
    });
    promptField('input[name="pkmn_pos"]', 'position', el => Number(el.value), 'change');
    promptField('#pkmn_depth', 'depth', el => Math.max(0, Number(el.value) || 0));
    promptField('#pkmn_role', 'role', el => Number(el.value), 'change');
    promptField('#pkmn_interval', 'interval', el => Math.max(0, Number(el.value) || 0));
    promptField('#pkmn_scan', 'scan', el => el.checked, 'change');

    $('#pkmn_recent').on('input', function () { settings().recentCount = Math.max(0, Number(this.value) || 0); save(); renderPreview(); });
    $('#pkmn_milestones').on('input', function () { settings().milestoneCount = Math.max(0, Number(this.value) || 0); save(); renderPreview(); });
    $('#pkmn_minimp').on('change', function () { settings().minImportance = Number(this.value); save(); renderPreview(); });
    $('#pkmn_partystyle').on('change', function () { settings().partyStyle = this.value; save(); renderPreview(); });
    $('#pkmn_inc_gender').on('change', function () { settings().includeGender = this.checked; save(); renderPreview(); });
    $('#pkmn_inc_nature').on('change', function () { settings().includeNature = this.checked; save(); renderPreview(); });
    $p.on('change', '.pkmn_cat', function () { settings().categories[$(this).data('cat')] = this.checked; save(); renderPreview(); });

    // Log tab
    $('#pkmn_log_search').on('input', function () { logFilter.text = this.value; renderLog(); });
    $('#pkmn_log_cat').on('change', function () { logFilter.category = this.value; renderLog(); });
    $('#pkmn_log_hidden').prop('checked', logFilter.showHidden).on('change', function () { logFilter.showHidden = this.checked; renderLog(); });
    const addManual = () => {
        const text = String($('#pkmn_manual_text').val() || '').trim();
        const a = adventure();
        if (!text) return;
        if (!a) { toastr.warning('No adventure yet — connect to the game or import a log first.'); return; }
        const st = a.status || {};
        mergeEvents(a, [{ seq: `m${Date.now()}`, t: Math.floor(Date.now() / 1000), pt: st.playTime, type: 'manual', imp: 2, text, loc: st.location, manual: true }]);
        save(); $('#pkmn_manual_text').val(''); renderLog(); renderPreview();
    };
    $('#pkmn_manual_add').on('click', addManual);
    $('#pkmn_manual_text').on('keydown', (e) => { if (e.key === 'Enter') addManual(); });
    $('#pkmn_log').on('click', '.pkmn-ev-text', function () {
        const $t = $(this);
        if ($t.find('textarea').length) return;
        const e = findEvent($t.closest('.pkmn-ev').data('key'));
        if (!e) return;
        const $ta = $('<textarea class="text_pole textarea_compact" rows="2"></textarea>').val(e.text);
        $t.empty().append($ta); $ta.trigger('focus');
        const commit = () => {
            const v = String($ta.val()).trim();
            if (v && v !== e.text) { if (!e.original) e.original = e.text; e.text = v; e.edited = true; save(); renderPreview(); }
            renderLog();
        };
        $ta.on('blur', commit).on('keydown', (ev) => { if (ev.key === 'Enter' && !ev.shiftKey) { ev.preventDefault(); $ta.trigger('blur'); } if (ev.key === 'Escape') renderLog(); });
    });
    $('#pkmn_log').on('click', '.pkmn-imp', function () {
        const e = findEvent($(this).closest('.pkmn-ev').data('key')); if (!e) return;
        e.imp = ((e.imp ?? 1) + 1) % 4; save(); renderLog(); renderPreview();
    });
    $('#pkmn_log').on('click', '.pkmn-pin', function () {
        const e = findEvent($(this).closest('.pkmn-ev').data('key')); if (!e) return;
        e.pinned = !e.pinned; save(); renderLog(); renderPreview();
    });
    $('#pkmn_log').on('click', '.pkmn-hide', function () {
        const e = findEvent($(this).closest('.pkmn-ev').data('key')); if (!e) return;
        e.hidden = !e.hidden; save(); renderLog(); renderPreview();
    });
    $('#pkmn_log').on('click', '.pkmn-del', function () {
        const a = adventure(); const key = $(this).closest('.pkmn-ev').data('key');
        if (!a) return;
        // keep a hidden tombstone so the next sync doesn't bring it back
        const e = findEvent(key); if (!e) return;
        if (e.manual) a.events = a.events.filter(x => x !== e); else { e.hidden = true; e.deleted = true; }
        save(); renderLog(); renderPreview();
    });
    $('#pkmn_log').on('click', '.pkmn-more', () => { logLimit += 300; renderLog(); });

    // Game tab
    $('#pkmn_url').on('change', function () { settings().bridgeUrl = this.value.trim() || DEFAULT_SETTINGS.bridgeUrl; save(); });
    $('#pkmn_connect').on('click', () => { settings().bridgeUrl = String($('#pkmn_url').val()).trim() || DEFAULT_SETTINGS.bridgeUrl; save(); sync({ manual: true }); startPolling(); });
    $('#pkmn_autosync').on('change', function () { settings().autoSync = this.checked; save(); this.checked ? startPolling() : stopPolling(); });
    $('#pkmn_poll').on('change', function () { settings().pollSeconds = Math.max(2, Number(this.value) || 5); save(); startPolling(); });
    $('#pkmn_newchats').on('change', function () { settings().newChatsEnabled = this.checked; save(); });
    $('#pkmn_adv_list').on('click', '.pkmn-adv', function (ev) {
        if ($(ev.target).is('.pkmn-adv-del, .pkmn-adv-rename')) return;
        const id = $(this).data('id');
        if (inChat()) { chatMeta().adventureId = id; saveChat(); } else { settings().activeAdventure = id; save(); }
        renderAll();
    });
    $('#pkmn_adv_list').on('click', '.pkmn-adv-rename', async function () {
        const a = settings().adventures[$(this).closest('.pkmn-adv').data('id')]; if (!a) return;
        const name = prompt('Player / adventure name', a.player || '');
        if (name !== null) { a.player = name.trim(); save(); renderAll(); }
    });
    $('#pkmn_adv_list').on('click', '.pkmn-adv-del', function () {
        const id = $(this).closest('.pkmn-adv').data('id');
        if (!confirm(`Delete adventure "${id}" from SillyTavern? (The log file on the game side is kept.)`)) return;
        delete settings().adventures[id];
        if (settings().activeAdventure === id) settings().activeAdventure = null;
        save(); renderAll();
    });
    $('#pkmn_import').on('click', () => $('#pkmn_import_file').trigger('click'));
    $('#pkmn_import_file').on('change', async function () {
        const f = this.files?.[0]; if (!f) return;
        try {
            const { a, added } = importText(await f.text(), f.name);
            if (inChat()) { chatMeta().adventureId = a.id; saveChat(); }
            toastr.success(`Imported ${added} event(s) into "${a.id}".`, 'Adventure Notebook');
            renderAll();
        } catch (e) { toastr.error(String(e.message || e), 'Import failed'); }
        this.value = '';
    });
    $('#pkmn_export').on('click', exportAdventure);

    // Data tab
    $('#pkmn_data_cat').on('change', renderData);
    $('#pkmn_data_search').on('input', renderData);
    $('#pkmn_data_refresh').on('click', async () => {
        const a = adventure();
        if (a?.status?.game) try { localStorage.removeItem(dataStoreKey(a.status.game)); } catch { /* */ }
        gameDataCache = null;
        await maybeFetchData(a?.status);
        renderData();
    });
}

// ------------------------------------------------------------------------------------------------
// Macros usable anywhere in SillyTavern ({{pkmn_party}} etc.)
// ------------------------------------------------------------------------------------------------
function registerMacros() {
    const c = ctx();
    const defs = {
        pkmn_notebook: ['The full Adventure Notebook text', () => buildNotebook()],
        pkmn_party: ['Current party', () => buildVars(adventure(), '').party],
        pkmn_location: ['Current location in the game', () => buildVars(adventure(), '').location],
        pkmn_recent: ['Recent game events', () => buildVars(adventure(), '').recent],
        pkmn_milestones: ['Badges, gym leaders and other milestones', () => buildVars(adventure(), '').milestones],
        pkmn_badges: ['Badge count and names', () => buildVars(adventure(), '').badges],
        pkmn_battle: ['Current battle, if any', () => buildVars(adventure(), '').battle],
        pkmn_last_event: ['Most recent game event', () => buildVars(adventure(), '').last_event],
    };
    for (const [name, [description, fn]] of Object.entries(defs)) {
        const handler = () => { try { return adventure() ? fn() : ''; } catch { return ''; } };
        try {
            if (c.macros?.register) c.macros.register(name, { handler, description });
            else c.registerMacro?.(name, handler, description);
        } catch {
            try { c.registerMacro?.(name, handler, description); } catch { /* old ST */ }
        }
    }
}

// ------------------------------------------------------------------------------------------------
// Init
// ------------------------------------------------------------------------------------------------
jQuery(async () => {
    settings();
    $('body').append(panelHtml());
    $('#extensions_settings2').append(settingsDrawerHtml());

    const menuItem = `<div id="pkmn_notebook_menu" class="list-group-item flex-container flexGap5" title="PKMN Adventure Notebook">
        <div class="fa-solid fa-book-open extensionsMenuExtensionButton"></div>Adventure Notebook</div>`;
    const addMenu = (tries = 0) => {
        if (!$('#extensionsMenu').length) { if (tries < 40) setTimeout(() => addMenu(tries + 1), 250); return; }
        $('#extensionsMenu').append(menuItem);
        $('#pkmn_notebook_menu').on('click', () => ($('#pkmnNotebookPanel').is(':visible') ? closePanel() : openPanel()));
    };
    addMenu();
    $('#pkmn_open_from_settings').on('click', openPanel);

    makeDraggable();
    bind();

    const c = ctx();
    const es = c.eventSource, et = c.eventTypes || c.event_types;
    if (es && et) {
        es.on(et.CHAT_CHANGED, () => { renderAll(); updatePrompt(); });
        if (et.MESSAGE_SENT) es.on(et.MESSAGE_SENT, () => renderCountdown(insertionCountdown(ctx().chat, Number(effective().prompt.interval))));
    }
    registerMacros();
    startPolling();
    updatePrompt();
    console.log(`[Adventure Notebook] v${VERSION} loaded`);
});
