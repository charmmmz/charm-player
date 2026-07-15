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
  selectedSonosGroupId: null,
  logsSource: 'all',
  logsQuery: '',
  logsAutoRefresh: true,
  groupingSourceGroupId: null,
  groupingDragBlocked: false,
  animatedArtwork: new Map(),
  artworkThemes: new Map(),
  stateTimer: null,
  progressTimer: null,
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
  event.currentTarget.textContent = visible ? 'Show' : 'Hide';
});

document.querySelector('#logout-button').addEventListener('click', async () => {
  try { await request('/session', { method: 'DELETE' }); } catch { /* session may already be gone */ }
  leaveDashboard();
});

ui.refreshButton.addEventListener('click', () => refreshState(true));

document.querySelectorAll('.nav-item').forEach(button => {
  button.addEventListener('click', () => {
    if (button.dataset.view === 'sonos') {
      model.selectedSonosGroupId = null;
      renderSonos(model.state);
    }
    showView(button.dataset.view);
  });
});

document.addEventListener('click', async event => {
  const button = event.target.closest('[data-open-group], [data-close-group], [data-command], [data-hue-action], [data-copy-mcp]');
  if (!button) return;

  if (button.dataset.openGroup !== undefined) {
    openSonosGroup(button.dataset.openGroup);
    return;
  }

  if (button.dataset.closeGroup !== undefined) {
    model.selectedSonosGroupId = null;
    renderSonos(model.state);
    return;
  }

  if (button.dataset.copyMcp !== undefined) {
    const code = document.querySelector('#mcp-config-code')?.textContent ?? '';
    await navigator.clipboard.writeText(code);
    showToast('MCP configuration copied');
    return;
  }

  if (button.dataset.hueAction !== undefined) {
    const action = button.dataset.hueAction;
    if (action === 'stop' && !window.confirm('Stop Hue ambience? Lights will follow the configured stop behavior.')) return;
    await runAction(
      button,
      () => request(`/hue/${action}`, { method: 'POST' }),
      action === 'start' ? 'Hue ambience started' : 'Hue ambience stopped',
    );
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

document.addEventListener('keydown', event => {
  if (!event.target.matches('.now-playing-card[data-open-group]')) return;
  if (event.key !== 'Enter' && event.key !== ' ') return;
  event.preventDefault();
  openSonosGroup(event.target.dataset.openGroup);
});

document.addEventListener('pointerdown', event => {
  model.groupingDragBlocked = Boolean(
    event.target.closest('.room-card button, .room-card input, .room-card label, .room-card a'),
  );
});

document.addEventListener('pointerup', () => {
  model.groupingDragBlocked = false;
});

document.addEventListener('dragstart', event => {
  const card = event.target.closest('.room-card[data-drag-group]');
  if (!card || model.groupingDragBlocked) {
    event.preventDefault();
    return;
  }
  const groupId = card.dataset.dragGroup;
  if (!groupId || !event.dataTransfer) return;
  model.groupingSourceGroupId = groupId;
  event.dataTransfer.effectAllowed = 'move';
  event.dataTransfer.setData('text/plain', groupId);
  const group = model.state?.sonos?.groups?.find(candidate => candidate.groupId === groupId);
  document.querySelector('#view-sonos')?.classList.add('sonos-grouping-active');
  document.querySelector('[data-ungroup-drop]')?.classList.toggle('disabled', (group?.groupMemberCount ?? 1) <= 1);
  requestAnimationFrame(() => card.classList.add('is-dragging'));
});

document.addEventListener('dragover', event => {
  const sourceGroupId = model.groupingSourceGroupId;
  if (!sourceGroupId) return;
  const targetCard = event.target.closest('.room-card[data-drag-group]');
  if (targetCard && targetCard.dataset.dragGroup !== sourceGroupId) {
    event.preventDefault();
    if (event.dataTransfer) event.dataTransfer.dropEffect = 'move';
    clearGroupingDropTargets(targetCard);
    targetCard.classList.add('is-group-drop-target');
    const targetGroup = model.state?.sonos?.groups?.find(group => group.groupId === targetCard.dataset.dragGroup);
    targetCard.dataset.dropLabel = `Group with ${targetGroup?.speakerName ?? 'this room'}`;
    return;
  }

  const ungroupDrop = event.target.closest('[data-ungroup-drop]');
  if (ungroupDrop && !ungroupDrop.classList.contains('disabled')) {
    event.preventDefault();
    if (event.dataTransfer) event.dataTransfer.dropEffect = 'move';
    clearGroupingDropTargets();
    ungroupDrop.classList.add('is-group-drop-target');
  }
});

document.addEventListener('dragleave', event => {
  const dropTarget = event.target.closest('.room-card[data-drag-group], [data-ungroup-drop]');
  if (!dropTarget || dropTarget.contains(event.relatedTarget)) return;
  dropTarget.classList.remove('is-group-drop-target');
  delete dropTarget.dataset.dropLabel;
});

document.addEventListener('drop', async event => {
  const sourceGroupId = model.groupingSourceGroupId || event.dataTransfer?.getData('text/plain');
  if (!sourceGroupId) return;
  const targetCard = event.target.closest('.room-card[data-drag-group]');
  if (targetCard && targetCard.dataset.dragGroup !== sourceGroupId) {
    event.preventDefault();
    const targetGroupId = targetCard.dataset.dragGroup;
    endGroupingDrag();
    await runGroupingAction(
      () => request('/sonos/group', {
        method: 'POST',
        body: JSON.stringify({ source: sourceGroupId, into: targetGroupId }),
      }),
      `${groupName(model.state, sourceGroupId)} grouped with ${groupName(model.state, targetGroupId)}`,
    );
    return;
  }

  const ungroupDrop = event.target.closest('[data-ungroup-drop]');
  if (ungroupDrop && !ungroupDrop.classList.contains('disabled')) {
    event.preventDefault();
    endGroupingDrag();
    await runGroupingAction(
      () => request('/sonos/ungroup', {
        method: 'POST',
        body: JSON.stringify({ target: sourceGroupId }),
      }),
      `${groupName(model.state, sourceGroupId)} ungrouped`,
    );
  }
});

document.addEventListener('dragend', endGroupingDrag);

document.addEventListener('change', async event => {
  if (event.target.matches('[data-volume-target]')) {
    const input = event.target;
    const target = input.dataset.volumeTarget;
    const volume = Number(input.value);
    input.closest('.volume-control, .player-volume-control')?.querySelector('.volume-value').replaceChildren(`${volume}%`);
    await runAction(input, () => request('/sonos/volume', {
      method: 'POST',
      body: JSON.stringify({ target, volume }),
    }), `Volume set to ${volume}%`);
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
    event.target.closest('.volume-control, .player-volume-control')?.querySelector('.volume-value')
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
    showLogin(error.status === 503 ? 'Dashboard authentication is not configured. Set DASHBOARD_TOKEN or MCP_API_TOKEN first.' : '');
  }
}

async function enterDashboard() {
  ui.loginScreen.hidden = true;
  ui.appShell.hidden = false;
  await refreshState(true);
  clearInterval(model.stateTimer);
  clearInterval(model.progressTimer);
  clearInterval(model.logsTimer);
  model.stateTimer = setInterval(() => refreshState(false), 5_000);
  model.progressTimer = setInterval(tickPlaybackProgress, 1_000);
  model.logsTimer = setInterval(() => {
    if (model.activeView === 'logs' && model.logsAutoRefresh) void refreshLogs();
  }, 3_000);
}

function leaveDashboard() {
  clearInterval(model.stateTimer);
  clearInterval(model.progressTimer);
  clearInterval(model.logsTimer);
  model.state = null;
  model.logs = [];
  model.animatedArtwork.clear();
  model.artworkThemes.clear();
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
  if (!model.groupingSourceGroupId) renderSonos(state);
  renderActivity(state);
  renderHue(state);
  renderMcp(state);
  if (model.activeView === 'logs') void refreshLogs();
  ui.updatedAt.textContent = `Updated ${formatClock(state.generatedAt)}`;
  document.querySelector('#sidebar-version').textContent = `v${state.relay.version} · ${formatDuration(state.relay.uptimeSeconds)}`;
}

function renderOverview(state) {
  const playbackTimes = captureAnimatedArtworkTimes();
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
          <div class="panel-heading"><div><h2>System health</h2><p>Live status of LAN services</p></div><span class="badge ${state.sonos.discovery.status === 'ready' ? 'good' : 'warn'}">${escapeHtml(state.sonos.discovery.status)}</span></div>
          <div class="health-list">
            ${healthRow('Sonos discovery', state.sonos.discovery.status === 'ready', `${groups.length} groups`)}
            ${healthRow('APNs delivery', apnsReady, state.liveActivity.apns?.environment ?? 'unknown')}
            ${healthRow('Hue bridge', state.hue.entertainment?.bridgeReachable, hue.configured ? (hue.bridge?.name ?? 'configured') : 'not configured')}
            ${healthRow('MCP endpoint', state.mcp.enabled, state.mcp.enabled ? 'LAN ready' : 'disabled')}
          </div>
        </article>
        <article class="panel-card">
          <div class="panel-heading"><div><h2>Live sessions</h2><p>Current ActivityKit registrations</p></div><span class="badge">APNs</span></div>
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
  hydrateAnimatedArtwork(playbackTimes);
  void resolveAnimatedArtwork(groups);
  void resolveArtworkThemes(groups);
}

function renderSonos(state) {
  const playbackTimes = captureAnimatedArtworkTimes();
  const groups = state.sonos.groups ?? [];
  const selected = groups.find(group => group.groupId === model.selectedSonosGroupId);
  if (model.selectedSonosGroupId && !selected) model.selectedSonosGroupId = null;
  if (selected) {
    document.querySelector('#view-sonos').innerHTML = playerDetail(selected, state.mcp.maxVolume);
    hydrateAnimatedArtwork(playbackTimes);
    void resolveAnimatedArtwork(groups);
    void resolveArtworkThemes(groups);
    return;
  }
  document.querySelector('#view-sonos').innerHTML = `
    <div class="section-header"><div class="brand-heading"><img class="integration-logo sonos-logo" src="/dashboard/assets/sonos-wordmark.svg" alt="Sonos"><div><h2>Discovered rooms</h2><p>Playback, volume, and soundbar controls</p></div></div><span class="badge ${state.sonos.discovery.status === 'ready' ? 'good' : 'warn'}">${groups.length} groups · ${escapeHtml(state.sonos.discovery.mode)}</span></div>
    ${groups.length ? `<div class="grouping-guide"><span class="grouping-guide-icon">⇄</span><span><strong>Group rooms by dragging</strong><small>Drop one speaker card onto another. Drop a grouped room into the tray to separate it.</small></span></div><div class="room-grid">${groups.map(group => roomCard(group, state.mcp.maxVolume)).join('')}</div><div class="grouping-action-tray" data-ungroup-drop><span class="grouping-tray-icon">−</span><span><strong>Ungroup</strong><small>Separate this room group</small></span></div>` : emptyState('No Sonos groups discovered', state.sonos.discovery.error ?? 'Make sure the relay and Sonos are on the same LAN, or configure SONOS_SEED_IP.')}`;
  hydrateAnimatedArtwork(playbackTimes);
  void resolveAnimatedArtwork(groups);
  void resolveArtworkThemes(groups);
}

function renderActivity(state) {
  const activity = state.liveActivity;
  const sessions = activity.sessions ?? [];
  const starts = activity.startTokens ?? [];
  const dismissals = activity.dismissals ?? [];
  document.querySelector('#view-activity').innerHTML = `
    <div class="section-header"><div><h2>ActivityKit pipeline</h2><p>Registration metadata only; push tokens are never displayed</p></div><span class="badge ${activity.apns.mode === 'ready' ? 'good' : 'warn'}">APNs ${escapeHtml(activity.apns.mode)}</span></div>
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
    document.querySelector('#view-hue').innerHTML = `<div class="section-header"><div class="brand-heading"><img class="integration-logo hue-logo" src="/dashboard/assets/philips-hue-logo.svg" alt="Philips Hue"><div><h2>Lighting setup</h2><p>Sonos ambience lighting</p></div></div></div>${emptyState('Hue is not configured', 'Pair a Hue Bridge and map rooms in the iOS app. The relay will show the configuration here automatically.')}`;
    return;
  }
  const activeGroups = hue.activeGroups ?? [];
  document.querySelector('#view-hue').innerHTML = `
    <article class="hue-hero">
      <div class="hue-hero-top"><div><img class="integration-logo hue-logo hue-hero-logo" src="/dashboard/assets/philips-hue-logo.svg" alt="Philips Hue"><p class="eyebrow">${hue.runtimePaused ? 'AMBIENCE STOPPED' : (hue.runtimeActive ? 'AMBIENCE ACTIVE' : 'AMBIENCE STANDBY')}</p><h2>${escapeHtml(hue.bridge?.name ?? 'Hue Bridge')}</h2><p>${escapeHtml(hue.bridge?.ipAddress ?? '')} · ${hue.mappings ?? 0} Sonos mappings · ${hue.lights ?? 0} lights</p></div><button class="secondary-button ${hue.runtimePaused ? '' : 'danger'}" data-hue-action="${hue.runtimePaused ? 'start' : 'stop'}">${hue.runtimePaused ? 'Start ambience' : 'Stop ambience'}</button></div>
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
    ${hue.lastError || entertainment.lastError ? `<div class="security-note">Latest error: ${escapeHtml(hue.lastError ?? entertainment.lastError)}</div>` : ''}`;
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
    <div class="section-header"><div><h2>Model Context Protocol</h2><p>Expose relay Sonos capabilities to agents on the local network</p></div><span class="badge ${mcp.enabled ? 'good' : 'warn'}">${mcp.enabled ? 'Endpoint ready' : 'Token required'}</span></div>
    <div class="detail-grid">
      ${detailCard('Endpoint', [['URL', endpoint], ['Transport', mcp.transport], ['Scope', mcp.scope], ['Authentication', mcp.auth]])}
      ${detailCard('Safety limits', [['Max volume', `${mcp.maxVolume}%`], ['Allowed origins', mcp.allowedOriginCount || 'same-origin / non-browser'], ['Credentials shown', 'Never']])}
      ${detailCard('Capabilities', [['Read', 'Groups & playback'], ['Playback', 'Play / pause / skip'], ['Soundbar', 'Night & speech'], ['Volume', `0–${mcp.maxVolume}`]])}
    </div>
    <div class="code-card"><div class="code-card-head"><span>Agent configuration example</span><button class="copy-button" data-copy-mcp>Copy</button></div><pre id="mcp-config-code">${escapeHtml(config)}</pre></div>
    <div class="security-note">The Dashboard API never returns the MCP token. Use this endpoint only on a trusted LAN and configure a long, random token for every deployment.</div>`;
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
    <div class="section-header"><div><h2>Diagnostics</h2><p>In-memory relay and iOS device logs, cleared on restart</p></div><span class="badge">${entries.length} entries</span></div>
    <div class="logs-toolbar">
      <input class="search-field" id="logs-search" type="search" placeholder="Search logs, modules, or groups…" value="${escapeAttr(model.logsQuery)}">
      <select class="select-field" id="logs-source"><option value="all" ${selected('all')}>All sources</option><option value="relay" ${selected('relay')}>Relay</option><option value="device" ${selected('device')}>iOS device</option></select>
      <button class="filter-button ${model.logsAutoRefresh ? 'active' : ''}" id="logs-auto-refresh">${model.logsAutoRefresh ? '● Auto refresh' : '○ Paused'}</button>
    </div>
    <div class="log-viewer">${entries.length ? entries.map(logEntry).join('') : '<div class="empty-state"><div><strong>No matching logs</strong><p>Change the source or search terms. New log entries will appear automatically.</p></div></div>'}</div>`;
}

function showView(view) {
  if (!viewLabels[view]) return;
  model.activeView = view;
  document.querySelectorAll('.nav-item').forEach(button => button.classList.toggle('active', button.dataset.view === view));
  document.querySelectorAll('[data-view-panel]').forEach(panel => panel.classList.toggle('active', panel.dataset.viewPanel === view));
  [ui.viewEyebrow.textContent, ui.viewTitle.textContent] = viewLabels[view];
  hydrateAnimatedArtwork(captureAnimatedArtworkTimes());
  if (view === 'logs') void refreshLogs();
}

function openSonosGroup(groupId) {
  if (!groupId || !model.state) return;
  model.selectedSonosGroupId = groupId;
  showView('sonos');
  renderSonos(model.state);
}

function nowPlayingCard(group, maxVolume) {
  const progress = progressPercent(group);
  const volume = group.groupVolume ?? 0;
  return `<article class="now-playing-card album-themed-card is-clickable" style="${albumThemeStyle(group)}" data-open-group="${escapeAttr(group.groupId)}" role="link" tabindex="0" aria-label="Open ${escapeAttr(group.speakerName)} in Sonos">
    ${albumThemeBackdrop(group)}
    <div class="artwork-wrap">${artwork(group, true)}</div>
    <div class="now-playing-content">
      <div class="card-kicker"><span>Now playing</span><span class="room-live">${escapeHtml(group.speakerName)} <span class="open-player-arrow">→</span></span></div>
      <div class="track-meta"><h2>${escapeHtml(group.trackTitle || 'Not playing')}</h2><p>${escapeHtml([group.artist, group.album].filter(Boolean).join(' · ') || 'No media metadata')}</p><div class="quality-row">${streamingServiceBadge(group.playbackSourceRaw)}${audioQualityBadge(group.audioQualityLabel)}${chip(`${group.groupMemberCount} speaker${group.groupMemberCount === 1 ? '' : 's'}`)}</div></div>
      <div class="progress-row" data-progress-group="${escapeAttr(group.groupId)}"><div class="progress-track"><div class="progress-fill" style="width:${progress}%"></div></div><div class="progress-times"><span data-progress-current>${formatTime(currentPosition(group))}</span><span>${formatTime(group.durationSeconds)}</span></div></div>
      <div class="playback-controls">${playbackButtons(group)}<span class="volume-mini">VOL ${Math.min(volume,maxVolume)}%</span></div>
    </div>
  </article>`;
}

function emptyNowPlaying() {
  return `<div class="empty-state"><div><strong>Waiting for Sonos</strong><p>Rooms that are playing will appear after LAN discovery completes.</p></div></div>`;
}

function roomCard(group, maxVolume) {
  const volume = Math.min(group.groupVolume ?? 0, maxVolume);
  const speechLevel = group.soundbarSpeechEnhancementRawLevel ?? 0;
  return `<article class="room-card album-themed-card" style="${albumThemeStyle(group)}" draggable="true" data-drag-group="${escapeAttr(group.groupId)}">${albumThemeBackdrop(group)}<div class="room-top">${artwork(group, false)}<div class="room-info"><h3>${escapeHtml(group.speakerName)}</h3><p>${escapeHtml(group.trackTitle || 'Not playing')}${group.artist ? ` · ${escapeHtml(group.artist)}` : ''}</p><div class="room-source-row">${streamingServiceBadge(group.playbackSourceRaw)}${audioQualityBadge(group.audioQualityLabel)}</div><small>${group.isPlaying ? 'PLAYING' : 'PAUSED'} · ${group.groupMemberCount} MEMBERS</small></div><button class="room-detail-button" data-open-group="${escapeAttr(group.groupId)}" aria-label="Open player for ${escapeAttr(group.speakerName)}"><span aria-hidden="true">→</span></button></div>
    <div class="room-controls"><div class="room-buttons">${playbackButtons(group)}</div><label class="volume-control" title="Group volume"><span>◖</span><input type="range" min="0" max="${maxVolume}" value="${volume}" data-volume-target="${escapeAttr(group.groupId)}"><span class="volume-value">${volume}%</span></label><span class="badge">max ${maxVolume}</span></div>
    ${(group.soundbarNightMode !== null && group.soundbarNightMode !== undefined) || speechLevel > 0 ? `<div class="soundbar-controls"><button class="toggle-chip ${group.soundbarNightMode ? 'on' : ''}" data-command="night-mode" data-target="${escapeAttr(group.groupId)}" data-enabled="${group.soundbarNightMode === true}">Night sound</button><button class="toggle-chip ${speechLevel > 0 ? 'on' : ''}" data-command="speech-enhancement" data-target="${escapeAttr(group.groupId)}" data-level="${speechLevel > 0 ? 0 : 1}">Speech ${speechLevel > 0 ? `L${speechLevel}` : 'off'}</button></div>` : ''}
  </article>`;
}

function playerDetail(group, maxVolume) {
  const progress = progressPercent(group);
  const volume = Math.min(group.groupVolume ?? 0, maxVolume);
  const speechLevel = group.soundbarSpeechEnhancementRawLevel ?? 0;
  const hasSoundbar = group.soundbarNightMode !== null && group.soundbarNightMode !== undefined
    || group.soundbarSpeechEnhancementRawLevel !== null && group.soundbarSpeechEnhancementRawLevel !== undefined;
  return `
    <div class="player-detail-header">
      <button class="back-button" data-close-group>← All rooms</button>
      <span class="badge ${group.isPlaying ? 'good' : ''}">${group.isPlaying ? 'Playing' : 'Paused'}</span>
    </div>
    <article class="player-detail-card album-themed-card" style="${albumThemeStyle(group)}">
      ${albumThemeBackdrop(group)}
      <div class="player-detail-artwork artwork-wrap">${artwork(group, true)}</div>
      <div class="player-detail-content">
        <div class="card-kicker"><span>${escapeHtml(group.speakerName)}</span><span>${group.groupMemberCount} speaker${group.groupMemberCount === 1 ? '' : 's'}</span></div>
        <div class="player-detail-track">
          <h2>${escapeHtml(group.trackTitle || 'Not playing')}</h2>
          <p>${escapeHtml(group.artist || 'Unknown artist')}</p>
          <small>${escapeHtml(group.album || 'No album metadata')}</small>
          <div class="quality-row">${streamingServiceBadge(group.playbackSourceRaw)}${audioQualityBadge(group.audioQualityLabel)}</div>
        </div>
        <div class="player-detail-progress" data-progress-group="${escapeAttr(group.groupId)}">
          <div class="progress-track"><div class="progress-fill" style="width:${progress}%"></div></div>
          <div class="progress-times"><span data-progress-current>${formatTime(currentPosition(group))}</span><span>${formatTime(group.durationSeconds)}</span></div>
        </div>
        <div class="player-detail-controls">${playbackButtons(group)}</div>
        <label class="player-volume-control">
          <span>Volume</span>
          <input type="range" min="0" max="${maxVolume}" value="${volume}" data-volume-target="${escapeAttr(group.groupId)}">
          <strong class="volume-value">${volume}%</strong>
        </label>
        ${hasSoundbar ? `<div class="player-soundbar-controls"><span>Soundbar</span><div class="soundbar-controls"><button class="toggle-chip ${group.soundbarNightMode ? 'on' : ''}" data-command="night-mode" data-target="${escapeAttr(group.groupId)}" data-enabled="${group.soundbarNightMode === true}">Night sound</button><button class="toggle-chip ${speechLevel > 0 ? 'on' : ''}" data-command="speech-enhancement" data-target="${escapeAttr(group.groupId)}" data-level="${speechLevel > 0 ? 0 : 1}">Speech ${speechLevel > 0 ? `L${speechLevel}` : 'off'}</button></div></div>` : ''}
      </div>
    </article>`;
}

function playbackButtons(group) {
  const target = escapeAttr(group.groupId);
  return `<button class="control-button" data-command="previous" data-target="${target}" title="Previous track">‹</button><button class="control-button primary" data-command="${group.isPlaying ? 'pause' : 'play'}" data-target="${target}" title="${group.isPlaying ? 'Pause' : 'Play'}">${group.isPlaying ? 'Ⅱ' : '▶'}</button><button class="control-button" data-command="next" data-target="${target}" title="Next track">›</button>`;
}

function artwork(group, large) {
  const url = safeUrl(group.albumArtUri || group.albumArtFallbackUri);
  const staticArtwork = url
    ? `<img class="${large ? '' : 'room-art'}" src="${escapeAttr(url)}" alt="${escapeAttr(group.album || group.trackTitle || 'Album artwork')}" referrerpolicy="no-referrer">`
    : (large ? '<div class="artwork-fallback">◉</div>' : '<div class="room-art placeholder">◉</div>');
  if (!large || !group.isPlaying || prefersReducedMotion()) return staticArtwork;

  const key = animatedArtworkKey(group);
  const resolution = key ? model.animatedArtwork.get(key) : null;
  const animatedUrl = resolution?.status === 'ready' && !resolution.unplayable
    ? safeUrl(resolution.url)
    : '';
  if (!animatedUrl) return staticArtwork;

  const poster = url ? ` poster="${escapeAttr(url)}"` : '';
  return `${staticArtwork}<video class="animated-artwork" data-animated-key="${escapeAttr(key)}" data-animated-src="${escapeAttr(animatedUrl)}"${poster} muted loop playsinline preload="metadata" aria-hidden="true"></video><span class="animated-artwork-badge" aria-hidden="true">Animated</span>`;
}

function albumThemeBackdrop(group) {
  const url = safeUrl(group.albumArtUri || group.albumArtFallbackUri);
  if (!url) return '';
  return `<div class="album-theme-backdrop" aria-hidden="true"><img src="${escapeAttr(url)}" alt="" referrerpolicy="no-referrer"></div>`;
}

function albumThemeStyle(group) {
  const url = safeUrl(group.albumArtUri || group.albumArtFallbackUri);
  const theme = safeThemeColor(model.artworkThemes.get(url)?.color) || '#FF9C6F';
  return `--album-theme:${theme}`;
}

async function resolveArtworkThemes(groups) {
  const now = Date.now();
  const candidates = new Set();
  for (const group of groups) {
    const url = safeUrl(group.albumArtUri || group.albumArtFallbackUri);
    if (!url) continue;
    const current = model.artworkThemes.get(url);
    if (current?.status === 'loading' || current?.status === 'ready') continue;
    if (current?.retryAt && current.retryAt > now) continue;
    candidates.add(url);
  }
  if (!candidates.size) return;

  for (const url of candidates) model.artworkThemes.set(url, { status: 'loading' });
  const results = await Promise.all([...candidates].map(async url => {
    try {
      const response = await request(`/artwork-theme?url=${encodeURIComponent(url)}`);
      const color = safeThemeColor(response.color);
      return [url, color
        ? { status: 'ready', color }
        : { status: 'error', retryAt: Date.now() + 15 * 60 * 1_000 }];
    } catch {
      return [url, { status: 'error', retryAt: Date.now() + 15 * 60 * 1_000 }];
    }
  }));

  let hasNewTheme = false;
  for (const [url, resolution] of results) {
    model.artworkThemes.set(url, resolution);
    if (resolution.status === 'ready') hasNewTheme = true;
  }
  if (hasNewTheme && model.state) {
    renderOverview(model.state);
    renderSonos(model.state);
  }
}

async function resolveAnimatedArtwork(groups) {
  if (prefersReducedMotion()) return;
  const now = Date.now();
  const candidates = new Map();
  for (const group of groups) {
    const key = animatedArtworkKey(group);
    if (!key || !group.isPlaying || !isAppleMusic(group.playbackSourceRaw)) continue;
    const current = model.animatedArtwork.get(key);
    if (current?.status === 'loading' || current?.status === 'ready') continue;
    if (current?.retryAt && current.retryAt > now) continue;
    candidates.set(key, group);
  }
  if (!candidates.size) return;

  for (const key of candidates.keys()) model.animatedArtwork.set(key, { status: 'loading' });
  const results = await Promise.all([...candidates].map(async ([key, group]) => {
    try {
      const query = new URLSearchParams({ artist: group.artist, album: group.album });
      const response = await fetch(`/api/animated-artwork/search?${query}`, { credentials: 'same-origin' });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error ?? `HTTP ${response.status}`);
      const url = safeUrl(body.squareUrl || body.tallUrl);
      if (body.status === 'hit' && url) return [key, { status: 'ready', url }];
      if (body.status === 'error' || body.status === 'rate-limited') {
        return [key, { status: 'error', retryAt: Date.now() + 15 * 60 * 1_000 }];
      }
      return [key, { status: 'miss' }];
    } catch {
      return [key, { status: 'error', retryAt: Date.now() + 15 * 60 * 1_000 }];
    }
  }));

  let hasNewArtwork = false;
  for (const [key, resolution] of results) {
    model.animatedArtwork.set(key, resolution);
    if (resolution.status === 'ready') hasNewArtwork = true;
  }
  if (hasNewArtwork && model.state) {
    renderOverview(model.state);
    renderSonos(model.state);
  }
}

function hydrateAnimatedArtwork(playbackTimes = new Map()) {
  const reduceMotion = prefersReducedMotion();
  document.querySelectorAll('.animated-artwork').forEach(video => {
    const isVisible = video.closest('.view')?.classList.contains('active') === true;
    if (reduceMotion || !isVisible) {
      video.pause();
      video.classList.remove('ready');
      return;
    }

    if (video.dataset.hydrated !== 'true') {
      video.dataset.hydrated = 'true';
      video.muted = true;
      video.loop = true;
      video.playsInline = true;
      video.addEventListener('loadedmetadata', () => {
        const rememberedTime = playbackTimes.get(video.dataset.animatedKey);
        if (Number.isFinite(rememberedTime) && rememberedTime > 0 && Number.isFinite(video.duration)) {
          video.currentTime = Math.min(rememberedTime, Math.max(0, video.duration - 0.1));
        }
      }, { once: true });
      video.addEventListener('playing', () => video.classList.add('ready'));
      video.addEventListener('error', () => {
        video.hidden = true;
        video.parentElement?.querySelector('.animated-artwork-badge')?.setAttribute('hidden', '');
        const resolution = model.animatedArtwork.get(video.dataset.animatedKey);
        if (resolution?.status === 'ready') resolution.unplayable = true;
      }, { once: true });
      video.src = video.dataset.animatedSrc;
      video.load();
    }
    void video.play().catch(() => video.classList.remove('ready'));
  });
}

function captureAnimatedArtworkTimes() {
  const times = new Map();
  document.querySelectorAll('.animated-artwork').forEach(video => {
    if (!video.paused && Number.isFinite(video.currentTime)) {
      times.set(video.dataset.animatedKey, video.currentTime);
    }
  });
  return times;
}

function tickPlaybackProgress() {
  const groups = model.state?.sonos?.groups ?? [];
  if (!groups.length) return;
  const byId = new Map(groups.map(group => [group.groupId, group]));
  document.querySelectorAll('[data-progress-group]').forEach(container => {
    const group = byId.get(container.dataset.progressGroup);
    if (!group) return;
    const position = currentPosition(group);
    const progress = progressPercent(group, position);
    const fill = container.querySelector('.progress-fill');
    if (fill) fill.style.width = `${progress}%`;
    container.querySelector('[data-progress-current]')?.replaceChildren(formatTime(position));
  });
}

function animatedArtworkKey(group) {
  const artist = String(group.artist ?? '').trim().toLowerCase();
  const album = String(group.album ?? '').trim().toLowerCase();
  return artist && album ? `${encodeURIComponent(artist)}::${encodeURIComponent(album)}` : '';
}

function isAppleMusic(value) {
  return String(value ?? '').toLowerCase().replace(/[^a-z0-9]/g, '').includes('applemusic');
}

function prefersReducedMotion() {
  return window.matchMedia?.('(prefers-reduced-motion: reduce)').matches === true;
}

function healthRow(label, ready, note) {
  return `<div class="health-row"><span class="dot ${ready ? '' : 'warn'}"></span><strong>${escapeHtml(label)}</strong><small>${escapeHtml(note)}</small></div>`;
}
function statCard(label, value, note) { return `<article class="stat-card"><div class="stat-label">${escapeHtml(label)}</div><div class="stat-value">${escapeHtml(value)}</div><div class="stat-note">${escapeHtml(note)}</div></article>`; }
function metricCard(icon, value, label) { return `<article class="metric-card"><div class="metric-icon">${icon}</div><strong>${escapeHtml(value)}</strong><span>${escapeHtml(label)}</span></article>`; }
function chip(value) { return value ? `<span class="mini-chip">${escapeHtml(value)}</span>` : ''; }

function streamingServiceBadge(value) {
  if (!value) return '';
  const key = String(value).toLowerCase().replace(/[^a-z0-9]/g, '');
  const brands = {
    spotify: ['/dashboard/assets/brand-spotify.svg', 'Spotify', 'icon'],
    applemusic: ['/dashboard/assets/brand-apple-music-wordmark.svg', 'Apple Music', 'wordmark'],
    amazonmusic: ['/dashboard/assets/brand-amazon-music.svg', 'Amazon Music', 'wordmark'],
    youtubemusic: ['/dashboard/assets/brand-youtube-music.svg', 'YouTube Music', 'icon'],
    neteasemusic: ['/dashboard/assets/brand-netease-music.svg', 'NetEase Cloud Music', 'icon'],
  };
  const brand = brands[key] ?? Object.entries(brands)
    .find(([brandKey]) => key.startsWith(brandKey) || key.endsWith(brandKey))?.[1];
  if (!brand) return chip(value);
  return `<span class="media-badge"><img class="media-brand ${brand[2]}" src="${brand[0]}" alt="${brand[1]}"></span>`;
}

function audioQualityBadge(value) {
  if (!value) return '';
  const quality = String(value).toLowerCase();
  if (quality.includes('dolby atmos')) {
    return `<span class="media-badge quality"><img class="quality-brand dolby-atmos" src="/dashboard/assets/badge-dolby-atmos.png" alt="${escapeAttr(value)}"></span>`;
  }
  if (quality.includes('lossless')) {
    return `<span class="media-badge quality"><img class="quality-brand apple-lossless" src="/dashboard/assets/badge-apple-lossless.svg" alt="${escapeAttr(value)}"></span>`;
  }
  return chip(value);
}

function detailCard(title, rows) {
  return `<article class="panel-card"><div class="panel-heading"><h3>${escapeHtml(title)}</h3></div><div class="detail-list">${rows.map(([label,value]) => `<div class="detail-line"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>`).join('')}</div></article>`;
}

function activityTable(title, rows, columns) {
  return `<div class="table-card"><div class="table-title"><h3>${escapeHtml(title)}</h3><span class="badge">${rows.length}</span></div>${rows.length ? `<table class="data-table"><thead><tr>${columns.map(([label]) => `<th>${escapeHtml(label)}</th>`).join('')}</tr></thead><tbody>${rows.map(row => `<tr>${columns.map(([,value]) => `<td>${escapeHtml(value(row))}</td>`).join('')}</tr>`).join('')}</tbody></table>` : '<div class="empty-state"><div><p>No records yet.</p></div></div>'}</div>`;
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

async function runGroupingAction(operation, successMessage) {
  document.querySelector('#view-sonos')?.classList.add('sonos-grouping-busy');
  try {
    await operation();
    showToast(successMessage);
    model.selectedSonosGroupId = null;
    await refreshState(false);
  } catch (error) {
    showToast(friendlyError(error), true);
  } finally {
    document.querySelector('#view-sonos')?.classList.remove('sonos-grouping-busy');
  }
}

function clearGroupingDropTargets(except = null) {
  document.querySelectorAll('.is-group-drop-target').forEach(element => {
    if (element === except) return;
    element.classList.remove('is-group-drop-target');
    delete element.dataset.dropLabel;
  });
}

function endGroupingDrag() {
  model.groupingSourceGroupId = null;
  model.groupingDragBlocked = false;
  clearGroupingDropTargets();
  document.querySelectorAll('.room-card.is-dragging').forEach(card => card.classList.remove('is-dragging'));
  document.querySelector('#view-sonos')?.classList.remove('sonos-grouping-active');
  document.querySelector('[data-ungroup-drop]')?.classList.remove('disabled');
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
  return ({ play: 'Playback started', pause: 'Playback paused', next: 'Skipped to the next track', previous: 'Returned to the previous track', 'night-mode': 'Night Sound updated', 'speech-enhancement': 'Speech Enhancement updated' })[command] ?? 'Command sent';
}

function friendlyError(error) {
  const messages = {
    invalid_token: 'The token is incorrect. Check it and try again.',
    dashboard_not_configured: 'Dashboard authentication is not configured.',
    dashboard_auth_required: 'Your session has expired. Sign in again.',
    origin_not_allowed: 'The request origin does not match the relay address.',
    state_unavailable: 'Relay status is temporarily unavailable.',
  };
  return messages[error.message] ?? error.message ?? 'Request failed';
}

function groupName(state, groupId) { return state.sonos.groups.find(group => group.groupId === groupId)?.speakerName ?? groupId ?? '—'; }
function shortId(value) { if (!value) return '—'; return value.length > 15 ? `${value.slice(0,7)}…${value.slice(-5)}` : value; }
function selected(value) { return model.logsSource === value ? 'selected' : ''; }
function safeUrl(value) { try { const url = new URL(value); return ['http:','https:'].includes(url.protocol) ? url.href : ''; } catch { return ''; } }
function safeThemeColor(value) { return /^#[0-9a-f]{6}$/i.test(String(value ?? '')) ? String(value).toUpperCase() : ''; }
function currentPosition(group) { if (!group.isPlaying) return group.positionSeconds ?? 0; const sampledAt = Date.parse(group.sampledAt); const elapsed = Number.isFinite(sampledAt) ? Math.max(0, (Date.now() - sampledAt) / 1000) : 0; return Math.min(group.durationSeconds || Infinity, (group.positionSeconds ?? 0) + elapsed); }
function progressPercent(group, position = currentPosition(group)) { return group.durationSeconds > 0 ? Math.min(100, Math.max(0, position / group.durationSeconds * 100)) : 0; }
function formatTime(seconds) { const safe = Number.isFinite(seconds) ? Math.max(0, Math.round(seconds)) : 0; return `${Math.floor(safe / 60)}:${String(safe % 60).padStart(2,'0')}`; }
function formatClock(value) { const date = new Date(value); return Number.isNaN(date.valueOf()) ? '—' : date.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', second: '2-digit' }); }
function formatRelative(value) { const date = new Date(value); if (Number.isNaN(date.valueOf())) return '—'; const delta = Math.round((date.valueOf() - Date.now()) / 1000); const abs = Math.abs(delta); if (abs < 60) return delta < 0 ? `${abs}s ago` : `in ${abs}s`; if (abs < 3600) return delta < 0 ? `${Math.round(abs/60)}m ago` : `in ${Math.round(abs/60)}m`; if (abs < 86400) return delta < 0 ? `${Math.round(abs/3600)}h ago` : `in ${Math.round(abs/3600)}h`; return date.toLocaleDateString('en-US'); }
function formatDuration(seconds) { if (seconds < 3600) return `${Math.floor(seconds/60)}m`; if (seconds < 86400) return `${Math.floor(seconds/3600)}h`; return `${Math.floor(seconds/86400)}d`; }
function greeting() { const hour = new Date().getHours(); return hour < 12 ? 'Good morning.' : hour < 18 ? 'Good afternoon.' : 'Good evening.'; }
function escapeHtml(value) { return String(value ?? '').replace(/[&<>'"]/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[char])); }
function escapeAttr(value) { return escapeHtml(value); }

void bootstrap();
