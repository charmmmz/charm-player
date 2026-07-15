const API = '/api/dashboard';

const ui = {
  loginScreen: document.querySelector('#login-screen'),
  loginForm: document.querySelector('#login-form'),
  loginToken: document.querySelector('#login-token'),
  loginMessage: document.querySelector('#login-message'),
  appShell: document.querySelector('#app-shell'),
  refreshButton: document.querySelector('#refresh-button'),
  updatedAt: document.querySelector('#updated-at'),
  viewTitle: document.querySelector('#view-title'),
  viewEyebrow: document.querySelector('#view-eyebrow'),
  toast: document.querySelector('#toast'),
};

const model = {
  state: null,
  logs: [],
  activeView: 'overview',
  logsSource: 'all',
  logsQuery: '',
  logsAutoRefresh: true,
  stateTimer: null,
  logsTimer: null,
};

const viewLabels = {
  overview: ['SYSTEM OVERVIEW', greeting()],
  sonos: ['ROOM CONTROL', 'Sonos setup.'],
  activity: ['ACTIVITYKIT PIPELINE', 'Live Activity sessions.'],
  hue: ['LIGHTING AMBIENCE', 'Philips Hue setup.'],
  mcp: ['AGENT INTERFACE', 'MCP setup.'],
  logs: ['DIAGNOSTICS', 'Relay & device logs.'],
};

ui.loginForm.addEventListener('submit', async event => {
  event.preventDefault();
  ui.loginMessage.textContent = '';
  const button = ui.loginForm.querySelector('button[type="submit"]');
  button.disabled = true;
  try {
    await request('/session', {
      method: 'POST',
      body: JSON.stringify({ token: ui.loginToken.value }),
    });
    ui.loginToken.value = '';
    await enterDashboard();
  } catch (error) {
    ui.loginMessage.textContent = friendlyError(error);
  } finally {
    button.disabled = false;
  }
});

document.querySelector('#reveal-token').addEventListener('click', event => {
  const visible = ui.loginToken.type === 'text';
  ui.loginToken.type = visible ? 'password' : 'text';
  event.currentTarget.textContent = visible ? '显示' : '隐藏';
});

document.querySelector('#logout-button').addEventListener('click', async () => {
  try { await request('/session', { method: 'DELETE' }); } catch { /* session may already be gone */ }
  leaveDashboard();
});

ui.refreshButton.addEventListener('click', () => refreshState(true));

document.querySelectorAll('.nav-item').forEach(button => {
  button.addEventListener('click', () => showView(button.dataset.view));
});

document.addEventListener('click', async event => {
  const button = event.target.closest('[data-command], [data-hue-stop], [data-copy-mcp]');
  if (!button) return;

  if (button.dataset.copyMcp !== undefined) {
    const code = document.querySelector('#mcp-config-code')?.textContent ?? '';
    await navigator.clipboard.writeText(code);
    showToast('MCP 配置已复制');
    return;
  }

  if (button.dataset.hueStop !== undefined) {
    if (!window.confirm('停止当前由 relay 驱动的 Hue ambience？灯光将按既有 stop behavior 处理。')) return;
    await runAction(button, () => request('/hue/stop', { method: 'POST' }), 'Hue ambience 已停止');
    return;
  }

  const command = button.dataset.command;
  const target = button.dataset.target;
  const body = { target };
  if (command === 'night-mode') body.enabled = button.dataset.enabled !== 'true';
  if (command === 'speech-enhancement') body.level = Number(button.dataset.level);
  await runAction(button, () => request(`/sonos/${command}`, {
    method: 'POST',
    body: JSON.stringify(body),
  }), commandLabel(command));
});

document.addEventListener('change', async event => {
  if (event.target.matches('[data-volume-target]')) {
    const input = event.target;
    const target = input.dataset.volumeTarget;
    const volume = Number(input.value);
    input.closest('.volume-control')?.querySelector('.volume-value').replaceChildren(`${volume}%`);
    await runAction(input, () => request('/sonos/volume', {
      method: 'POST',
      body: JSON.stringify({ target, volume }),
    }), `音量已设为 ${volume}%`);
  }
  if (event.target.id === 'logs-source') {
    model.logsSource = event.target.value;
    await refreshLogs();
  }
});

document.addEventListener('input', event => {
  if (event.target.id === 'logs-search') {
    model.logsQuery = event.target.value.trim().toLowerCase();
    renderLogs();
  }
  if (event.target.matches('[data-volume-target]')) {
    event.target.closest('.volume-control')?.querySelector('.volume-value')
      .replaceChildren(`${event.target.value}%`);
  }
});

document.addEventListener('click', event => {
  const auto = event.target.closest('#logs-auto-refresh');
  if (!auto) return;
  model.logsAutoRefresh = !model.logsAutoRefresh;
  auto.classList.toggle('active', model.logsAutoRefresh);
  auto.textContent = model.logsAutoRefresh ? '● Auto refresh' : '○ Paused';
});

async function bootstrap() {
  try {
    await request('/session');
    await enterDashboard();
  } catch (error) {
    showLogin(error.status === 503 ? 'Dashboard 尚未配置，请先设置 DASHBOARD_TOKEN 或 MCP_API_TOKEN。' : '');
  }
}

async function enterDashboard() {
  ui.loginScreen.hidden = true;
  ui.appShell.hidden = false;
  await refreshState(true);
  clearInterval(model.stateTimer);
  clearInterval(model.logsTimer);
  model.stateTimer = setInterval(() => refreshState(false), 5_000);
  model.logsTimer = setInterval(() => {
    if (model.activeView === 'logs' && model.logsAutoRefresh) void refreshLogs();
  }, 3_000);
}

function leaveDashboard() {
  clearInterval(model.stateTimer);
  clearInterval(model.logsTimer);
  model.state = null;
  model.logs = [];
  ui.appShell.hidden = true;
  showLogin('');
}

function showLogin(message) {
  ui.loginScreen.hidden = false;
  ui.appShell.hidden = true;
  ui.loginMessage.textContent = message;
  window.setTimeout(() => ui.loginToken.focus(), 30);
}

async function refreshState(showSpinner = false) {
  if (showSpinner) ui.refreshButton.classList.add('spinning');
  try {
    model.state = await request('/state');
    renderAll();
    setConnected(true);
  } catch (error) {
    if (error.status === 401 || error.status === 503) {
      leaveDashboard();
      return;
    }
    setConnected(false);
    if (showSpinner) showToast(friendlyError(error), true);
  } finally {
    ui.refreshButton.classList.remove('spinning');
  }
}

async function refreshLogs() {
  try {
    const response = await request(`/logs?limit=350&source=${encodeURIComponent(model.logsSource)}`);
    model.logs = response.entries ?? [];
    renderLogs();
  } catch (error) {
    if (error.status === 401) leaveDashboard();
  }
}

function renderAll() {
  const state = model.state;
  if (!state) return;
  renderOverview(state);
  renderSonos(state);
  renderActivity(state);
  renderHue(state);
  renderMcp(state);
  if (model.activeView === 'logs') void refreshLogs();
  ui.updatedAt.textContent = `更新于 ${formatClock(state.generatedAt)}`;
  document.querySelector('#sidebar-version').textContent = `v${state.relay.version} · ${formatDuration(state.relay.uptimeSeconds)}`;
}

function renderOverview(state) {
  const groups = state.sonos.groups ?? [];
  const featured = groups.find(group => group.isPlaying) ?? groups[0];
  const apnsReady = state.liveActivity.apns?.mode === 'ready';
  const hue = state.hue.ambience ?? {};
  const sessions = state.liveActivity.updateTokenCount ?? 0;
  const html = `
    <div class="overview-grid">
      ${featured ? nowPlayingCard(featured, state.mcp.maxVolume) : emptyNowPlaying()}
      <div class="status-stack">
        <article class="panel-card">
          <div class="panel-heading"><div><h2>System health</h2><p>局域网服务实时状态</p></div><span class="badge ${state.sonos.discovery.status === 'ready' ? 'good' : 'warn'}">${escapeHtml(state.sonos.discovery.status)}</span></div>
          <div class="health-list">
            ${healthRow('Sonos discovery', state.sonos.discovery.status === 'ready', `${groups.length} groups`)}
            ${healthRow('APNs delivery', apnsReady, state.liveActivity.apns?.environment ?? 'unknown')}
            ${healthRow('Hue bridge', state.hue.entertainment?.bridgeReachable, hue.configured ? (hue.bridge?.name ?? 'configured') : 'not configured')}
            ${healthRow('MCP endpoint', state.mcp.enabled, state.mcp.enabled ? 'LAN ready' : 'disabled')}
          </div>
        </article>
        <article class="panel-card">
          <div class="panel-heading"><div><h2>Live sessions</h2><p>当前 ActivityKit 注册</p></div><span class="badge">APNs</span></div>
          <div class="session-summary"><strong>${sessions}</strong><span>update sessions</span></div>
          <div class="session-bars">${Array.from({length:3}, (_, i) => `<span class="session-bar ${i < Math.min(sessions,3) ? 'on' : ''}"></span>`).join('')}</div>
        </article>
      </div>
    </div>
    <div class="stat-grid">
      ${statCard('Sonos groups', groups.length, `${groups.filter(g => g.isPlaying).length} currently playing`)}
      ${statCard('Start tokens', state.liveActivity.startTokenCount, `${state.liveActivity.dismissedSuppressionCount} suppressed`)}
      ${statCard('Hue ambience', hue.runtimeActive ? 'Active' : (hue.configured ? 'Standby' : 'Off'), hue.renderMode ?? hue.motionStyle ?? 'not configured')}
      ${statCard('MCP', state.mcp.enabled ? 'Ready' : 'Disabled', `${state.mcp.transport} · max ${state.mcp.maxVolume}%`)}
    </div>`;
  document.querySelector('#view-overview').innerHTML = html;
}

function renderSonos(state) {
  const groups = state.sonos.groups ?? [];
  document.querySelector('#view-sonos').innerHTML = `
    <div class="section-header"><div><h2>Discovered rooms</h2><p>轻量播放、音量与 soundbar 控制</p></div><span class="badge ${state.sonos.discovery.status === 'ready' ? 'good' : 'warn'}">${groups.length} groups · ${escapeHtml(state.sonos.discovery.mode)}</span></div>
    ${groups.length ? `<div class="room-grid">${groups.map(group => roomCard(group, state.mcp.maxVolume)).join('')}</div>` : emptyState('还没有发现 Sonos 分组', state.sonos.discovery.error ?? '确认 relay 与 Sonos 处于同一局域网，或配置 SONOS_SEED_IP。')}`;
}

function renderActivity(state) {
  const activity = state.liveActivity;
  const sessions = activity.sessions ?? [];
  const starts = activity.startTokens ?? [];
  const dismissals = activity.dismissals ?? [];
  document.querySelector('#view-activity').innerHTML = `
    <div class="section-header"><div><h2>ActivityKit pipeline</h2><p>只展示注册元数据，不展示 push token</p></div><span class="badge ${activity.apns.mode === 'ready' ? 'good' : 'warn'}">APNs ${escapeHtml(activity.apns.mode)}</span></div>
    <div class="activity-grid">
      ${metricCard('◫', activity.updateTokenCount, 'Update sessions')}
      ${metricCard('↗', activity.startTokenCount, 'Push-to-start tokens')}
      ${metricCard('⊘', activity.dismissedSuppressionCount, 'Dismissal suppressions')}
    </div>
    ${activityTable('Update sessions', sessions, [
      ['Room / group', row => row.attributes?.speakerName ?? groupName(state, row.groupId)],
      ['Client', row => shortId(row.clientId)],
      ['Activity', row => shortId(row.activityId)],
      ['Registered', row => formatRelative(row.registeredAt)],
      ['Last state', row => row.hasLastSentState ? 'Delivered' : 'Pending'],
    ])}
    ${activityTable('Push-to-start registrations', starts, [
      ['Room / group', row => row.speakerName ?? groupName(state, row.groupId)],
      ['Client', row => shortId(row.clientId)],
      ['Registered', row => formatRelative(row.registeredAt)],
      ['Last start', row => row.lastStartAt ? formatRelative(row.lastStartAt) : '—'],
      ['Attempts', row => row.startAttemptCount ?? 0],
    ])}
    ${dismissals.length ? activityTable('Active dismissal suppressions', dismissals, [
      ['Room / group', row => groupName(state, row.groupId)],
      ['Client', row => shortId(row.clientId)],
      ['Reason', row => row.reason ?? '—'],
      ['Until', row => formatRelative(row.suppressUntil)],
    ]) : ''}`;
}

function renderHue(state) {
  const hue = state.hue.ambience ?? {};
  const entertainment = state.hue.entertainment ?? {};
  if (!hue.configured) {
    document.querySelector('#view-hue').innerHTML = `<div class="section-header"><div><h2>Philips Hue</h2><p>Sonos ambience lighting</p></div></div>${emptyState('Hue 尚未配置', '请先通过 iOS app 完成 Hue Bridge 授权和房间映射，relay 会在这里自动展示配置。')}`;
    return;
  }
  const activeGroups = hue.activeGroups ?? [];
  document.querySelector('#view-hue').innerHTML = `
    <article class="hue-hero">
      <div class="hue-hero-top"><div><p class="eyebrow">${hue.runtimeActive ? 'AMBIENCE ACTIVE' : 'AMBIENCE STANDBY'}</p><h2>${escapeHtml(hue.bridge?.name ?? 'Hue Bridge')}</h2><p>${escapeHtml(hue.bridge?.ipAddress ?? '')} · ${hue.mappings ?? 0} Sonos mappings · ${hue.lights ?? 0} lights</p></div>${hue.runtimeActive ? '<button class="secondary-button danger" data-hue-stop>Stop ambience</button>' : '<span class="badge">Waiting for music</span>'}</div>
    </article>
    <div class="detail-grid">
      ${detailCard('Bridge & resources', [
        ['Bridge status', entertainment.bridgeReachable ? 'Reachable' : 'Unavailable'],
        ['Entertainment', entertainment.streaming ?? 'unknown'],
        ['Areas', hue.areas ?? 0],
        ['Lights', hue.lights ?? 0],
      ])}
      ${detailCard('Rendering policy', [
        ['Render mode', hue.renderMode ?? 'idle'],
        ['Motion', hue.motionStyle ?? '—'],
        ['Stop behavior', hue.stopBehavior ?? '—'],
        ['Active targets', (hue.activeTargetIds ?? []).length],
      ])}
      ${detailCard('Active groups', activeGroups.length ? activeGroups.map(group => [group.speakerName ?? groupName(state, group.groupId), group.renderMode ?? 'active']) : [['Status', 'No active group']])}
    </div>
    ${hue.lastError || entertainment.lastError ? `<div class="security-note">最近错误：${escapeHtml(hue.lastError ?? entertainment.lastError)}</div>` : ''}`;
}

function renderMcp(state) {
  const mcp = state.mcp;
  const endpoint = `${location.origin}${mcp.path}`;
  const config = `{
  "mcpServers": {
    "charm-sonos-lan": {
      "type": "streamable-http",
      "url": "${endpoint}",
      "headers": {
        "Authorization": "Bearer <MCP_API_TOKEN>"
      }
    }
  }
}`;
  document.querySelector('#view-mcp').innerHTML = `
    <div class="section-header"><div><h2>Model Context Protocol</h2><p>让局域网内的外部 agent 调用 relay 的 Sonos 能力</p></div><span class="badge ${mcp.enabled ? 'good' : 'warn'}">${mcp.enabled ? 'Endpoint ready' : 'Token required'}</span></div>
    <div class="detail-grid">
      ${detailCard('Endpoint', [['URL', endpoint], ['Transport', mcp.transport], ['Scope', mcp.scope], ['Authentication', mcp.auth]])}
      ${detailCard('Safety limits', [['Max volume', `${mcp.maxVolume}%`], ['Allowed origins', mcp.allowedOriginCount || 'same-origin / non-browser'], ['Credentials shown', 'Never']])}
      ${detailCard('Capabilities', [['Read', 'Groups & playback'], ['Playback', 'Play / pause / skip'], ['Soundbar', 'Night & speech'], ['Volume', `0–${mcp.maxVolume}`]])}
    </div>
    <div class="code-card"><div class="code-card-head"><span>Agent configuration example</span><button class="copy-button" data-copy-mcp>Copy</button></div><pre id="mcp-config-code">${escapeHtml(config)}</pre></div>
    <div class="security-note">MCP token 不会由 Dashboard API 返回。请只在可信 LAN 内使用，并为每个部署设置足够长的随机 token。</div>`;
}

function renderLogs() {
  const panel = document.querySelector('#view-logs');
  if (!panel) return;
  const query = model.logsQuery;
  const entries = model.logs.filter(entry => {
    if (!query) return true;
    return `${entry.message} ${entry.source} ${entry.level} ${JSON.stringify(entry.context ?? {})}`.toLowerCase().includes(query);
  });
  panel.innerHTML = `
    <div class="section-header"><div><h2>Diagnostics</h2><p>内存中的 relay 与 iOS device logs，重启后清空</p></div><span class="badge">${entries.length} entries</span></div>
    <div class="logs-toolbar">
      <input class="search-field" id="logs-search" type="search" placeholder="搜索日志、模块或 group…" value="${escapeAttr(model.logsQuery)}">
      <select class="select-field" id="logs-source"><option value="all" ${selected('all')}>All sources</option><option value="relay" ${selected('relay')}>Relay</option><option value="device" ${selected('device')}>iOS device</option></select>
      <button class="filter-button ${model.logsAutoRefresh ? 'active' : ''}" id="logs-auto-refresh">${model.logsAutoRefresh ? '● Auto refresh' : '○ Paused'}</button>
    </div>
    <div class="log-viewer">${entries.length ? entries.map(logEntry).join('') : '<div class="empty-state"><div><strong>没有匹配日志</strong><p>调整来源或搜索条件，新的日志会自动出现。</p></div></div>'}</div>`;
}

function showView(view) {
  if (!viewLabels[view]) return;
  model.activeView = view;
  document.querySelectorAll('.nav-item').forEach(button => button.classList.toggle('active', button.dataset.view === view));
  document.querySelectorAll('[data-view-panel]').forEach(panel => panel.classList.toggle('active', panel.dataset.viewPanel === view));
  [ui.viewEyebrow.textContent, ui.viewTitle.textContent] = viewLabels[view];
  if (view === 'logs') void refreshLogs();
}

function nowPlayingCard(group, maxVolume) {
  const progress = progressPercent(group);
  const volume = group.groupVolume ?? 0;
  return `<article class="now-playing-card">
    <div class="artwork-wrap">${artwork(group, true)}</div>
    <div class="now-playing-content">
      <div class="card-kicker"><span>Now playing</span><span class="room-live">${escapeHtml(group.speakerName)}</span></div>
      <div class="track-meta"><h2>${escapeHtml(group.trackTitle || 'Not playing')}</h2><p>${escapeHtml([group.artist, group.album].filter(Boolean).join(' · ') || 'No media metadata')}</p><div class="quality-row">${chip(group.playbackSourceRaw)}${chip(group.audioQualityLabel)}${chip(`${group.groupMemberCount} speaker${group.groupMemberCount === 1 ? '' : 's'}`)}</div></div>
      <div class="progress-row"><div class="progress-track"><div class="progress-fill" style="width:${progress}%"></div></div><div class="progress-times"><span>${formatTime(currentPosition(group))}</span><span>${formatTime(group.durationSeconds)}</span></div></div>
      <div class="playback-controls">${playbackButtons(group)}<span class="volume-mini">VOL ${Math.min(volume,maxVolume)}%</span></div>
    </div>
  </article>`;
}

function emptyNowPlaying() {
  return `<div class="empty-state"><div><strong>等待 Sonos</strong><p>relay 完成局域网发现后，正在播放的房间会显示在这里。</p></div></div>`;
}

function roomCard(group, maxVolume) {
  const volume = Math.min(group.groupVolume ?? 0, maxVolume);
  const speechLevel = group.soundbarSpeechEnhancementRawLevel ?? 0;
  return `<article class="room-card"><div class="room-top">${artwork(group, false)}<div class="room-info"><h3>${escapeHtml(group.speakerName)}</h3><p>${escapeHtml(group.trackTitle || 'Not playing')}${group.artist ? ` · ${escapeHtml(group.artist)}` : ''}</p><small>${group.isPlaying ? 'PLAYING' : 'PAUSED'} · ${escapeHtml(group.playbackSourceRaw ?? 'unknown')} · ${group.groupMemberCount} MEMBERS</small></div></div>
    <div class="room-controls"><div class="room-buttons">${playbackButtons(group)}</div><label class="volume-control" title="Group volume"><span>◖</span><input type="range" min="0" max="${maxVolume}" value="${volume}" data-volume-target="${escapeAttr(group.groupId)}"><span class="volume-value">${volume}%</span></label><span class="badge">max ${maxVolume}</span></div>
    ${(group.soundbarNightMode !== null && group.soundbarNightMode !== undefined) || speechLevel > 0 ? `<div class="soundbar-controls"><button class="toggle-chip ${group.soundbarNightMode ? 'on' : ''}" data-command="night-mode" data-target="${escapeAttr(group.groupId)}" data-enabled="${group.soundbarNightMode === true}">Night sound</button><button class="toggle-chip ${speechLevel > 0 ? 'on' : ''}" data-command="speech-enhancement" data-target="${escapeAttr(group.groupId)}" data-level="${speechLevel > 0 ? 0 : 1}">Speech ${speechLevel > 0 ? `L${speechLevel}` : 'off'}</button></div>` : ''}
  </article>`;
}

function playbackButtons(group) {
  const target = escapeAttr(group.groupId);
  return `<button class="control-button" data-command="previous" data-target="${target}" title="上一首">‹</button><button class="control-button primary" data-command="${group.isPlaying ? 'pause' : 'play'}" data-target="${target}" title="${group.isPlaying ? '暂停' : '播放'}">${group.isPlaying ? 'Ⅱ' : '▶'}</button><button class="control-button" data-command="next" data-target="${target}" title="下一首">›</button>`;
}

function artwork(group, large) {
  const url = safeUrl(group.albumArtUri || group.albumArtFallbackUri);
  if (url) return `<img class="${large ? '' : 'room-art'}" src="${escapeAttr(url)}" alt="${escapeAttr(group.album || group.trackTitle || 'Album artwork')}" referrerpolicy="no-referrer">`;
  return large ? '<div class="artwork-fallback">◉</div>' : '<div class="room-art placeholder">◉</div>';
}

function healthRow(label, ready, note) {
  return `<div class="health-row"><span class="dot ${ready ? '' : 'warn'}"></span><strong>${escapeHtml(label)}</strong><small>${escapeHtml(note)}</small></div>`;
}
function statCard(label, value, note) { return `<article class="stat-card"><div class="stat-label">${escapeHtml(label)}</div><div class="stat-value">${escapeHtml(value)}</div><div class="stat-note">${escapeHtml(note)}</div></article>`; }
function metricCard(icon, value, label) { return `<article class="metric-card"><div class="metric-icon">${icon}</div><strong>${escapeHtml(value)}</strong><span>${escapeHtml(label)}</span></article>`; }
function chip(value) { return value ? `<span class="mini-chip">${escapeHtml(value)}</span>` : ''; }

function detailCard(title, rows) {
  return `<article class="panel-card"><div class="panel-heading"><h3>${escapeHtml(title)}</h3></div><div class="detail-list">${rows.map(([label,value]) => `<div class="detail-line"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>`).join('')}</div></article>`;
}

function activityTable(title, rows, columns) {
  return `<div class="table-card"><div class="table-title"><h3>${escapeHtml(title)}</h3><span class="badge">${rows.length}</span></div>${rows.length ? `<table class="data-table"><thead><tr>${columns.map(([label]) => `<th>${escapeHtml(label)}</th>`).join('')}</tr></thead><tbody>${rows.map(row => `<tr>${columns.map(([,value]) => `<td>${escapeHtml(value(row))}</td>`).join('')}</tr>`).join('')}</tbody></table>` : '<div class="empty-state"><div><p>当前没有记录。</p></div></div>'}</div>`;
}
function emptyState(title, copy) { return `<div class="empty-state"><div><strong>${escapeHtml(title)}</strong><p>${escapeHtml(copy)}</p></div></div>`; }

function logEntry(entry) {
  const context = Object.fromEntries(Object.entries(entry.context ?? {}).filter(([,value]) => value !== undefined));
  return `<div class="log-entry"><span class="log-time">${formatClock(entry.timestamp)}</span><span class="log-level ${escapeAttr(entry.level)}">${escapeHtml(entry.level)}</span><span class="log-source">${escapeHtml(entry.source)}</span><div class="log-message">${escapeHtml(entry.message)}${Object.keys(context).length ? `<div class="log-context">${escapeHtml(JSON.stringify(context))}</div>` : ''}</div></div>`;
}

async function runAction(element, operation, successMessage) {
  element.disabled = true;
  try {
    await operation();
    showToast(successMessage);
    await refreshState(false);
  } catch (error) {
    showToast(friendlyError(error), true);
  } finally {
    element.disabled = false;
  }
}

async function request(path, options = {}) {
  const response = await fetch(`${API}${path}`, {
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', ...(options.headers ?? {}) },
    ...options,
  });
  let body = {};
  try { body = await response.json(); } catch { /* keep empty body */ }
  if (!response.ok) {
    const error = new Error(body.error ?? `HTTP ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return body;
}

function setConnected(connected) {
  const dot = document.querySelector('#sidebar-status-dot');
  dot.className = `status-dot ${connected ? 'ready' : 'error'}`;
  document.querySelector('#sidebar-status').textContent = connected ? 'Relay online' : 'Connection lost';
}

let toastTimer;
function showToast(message, error = false) {
  clearTimeout(toastTimer);
  ui.toast.textContent = message;
  ui.toast.className = `toast show${error ? ' error' : ''}`;
  toastTimer = setTimeout(() => { ui.toast.className = 'toast'; }, 2_800);
}

function commandLabel(command) {
  return ({ play: '播放已开始', pause: '播放已暂停', next: '已切到下一首', previous: '已返回上一首', 'night-mode': 'Night Sound 已更新', 'speech-enhancement': 'Speech Enhancement 已更新' })[command] ?? '控制已发送';
}

function friendlyError(error) {
  const messages = {
    invalid_token: 'Token 不正确，请检查后重试。',
    dashboard_not_configured: 'Dashboard 尚未配置 token。',
    dashboard_auth_required: '登录已过期，请重新进入。',
    origin_not_allowed: '请求来源与 relay 地址不一致。',
    state_unavailable: '暂时无法汇总 relay 状态。',
  };
  return messages[error.message] ?? error.message ?? '请求失败';
}

function groupName(state, groupId) { return state.sonos.groups.find(group => group.groupId === groupId)?.speakerName ?? groupId ?? '—'; }
function shortId(value) { if (!value) return '—'; return value.length > 15 ? `${value.slice(0,7)}…${value.slice(-5)}` : value; }
function selected(value) { return model.logsSource === value ? 'selected' : ''; }
function safeUrl(value) { try { const url = new URL(value); return ['http:','https:'].includes(url.protocol) ? url.href : ''; } catch { return ''; } }
function currentPosition(group) { if (!group.isPlaying) return group.positionSeconds ?? 0; const elapsed = Math.max(0, (Date.now() - Date.parse(group.sampledAt)) / 1000); return Math.min(group.durationSeconds || Infinity, (group.positionSeconds ?? 0) + elapsed); }
function progressPercent(group) { return group.durationSeconds > 0 ? Math.min(100, Math.max(0, currentPosition(group) / group.durationSeconds * 100)) : 0; }
function formatTime(seconds) { const safe = Number.isFinite(seconds) ? Math.max(0, Math.round(seconds)) : 0; return `${Math.floor(safe / 60)}:${String(safe % 60).padStart(2,'0')}`; }
function formatClock(value) { const date = new Date(value); return Number.isNaN(date.valueOf()) ? '—' : date.toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false }); }
function formatRelative(value) { const date = new Date(value); if (Number.isNaN(date.valueOf())) return '—'; const delta = Math.round((date.valueOf() - Date.now()) / 1000); const abs = Math.abs(delta); if (abs < 60) return delta < 0 ? `${abs}s ago` : `in ${abs}s`; if (abs < 3600) return delta < 0 ? `${Math.round(abs/60)}m ago` : `in ${Math.round(abs/60)}m`; if (abs < 86400) return delta < 0 ? `${Math.round(abs/3600)}h ago` : `in ${Math.round(abs/3600)}h`; return date.toLocaleDateString('zh-CN'); }
function formatDuration(seconds) { if (seconds < 3600) return `${Math.floor(seconds/60)}m`; if (seconds < 86400) return `${Math.floor(seconds/3600)}h`; return `${Math.floor(seconds/86400)}d`; }
function greeting() { const hour = new Date().getHours(); return hour < 12 ? 'Good morning.' : hour < 18 ? 'Good afternoon.' : 'Good evening.'; }
function escapeHtml(value) { return String(value ?? '').replace(/[&<>'"]/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[char])); }
function escapeAttr(value) { return escapeHtml(value); }

void bootstrap();
