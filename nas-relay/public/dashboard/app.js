import { selectAnimatedArtworkPlayback } from './hlsPlayback.js';
import {
  ALBUM_THEME_TRANSITION_MS,
  albumTransitionIdentity,
  shouldAnimateAlbumThemeTransition,
} from './albumThemeTransition.js?v=20260717-album-transition';
import { presentationSignature } from './renderSignature.js';
import {
  groupDisplayName,
  groupPlaybackSubtitle,
  groupPlaybackTitle,
  groupSourceState,
  isGroupPlaying,
  isActivePlaybackGroup,
  isLiveStreamGroup,
  isTVGroup,
  tvAudioPresentation,
} from './sonosPresentation.js';

const API = '/api/dashboard';
const QUEUE_RENDER_CHUNK = 100;
const QUEUE_ARTWORK_BATCH_LIMIT = 12;
const CURRENT_FAVORITE_REFRESH_MS = 15_000;

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
  favoritesTargetGroupId: null,
  favorites: { status: 'idle', items: [], error: null },
  currentFavorite: currentFavoriteInitialState(),
  queueOpen: false,
  queue: { status: 'idle', groupId: null, updateId: 0, currentTrackNumber: null, items: [], error: null },
  queueVisibleCount: QUEUE_RENDER_CHUNK,
  queueArtworkAttempted: new Set(),
  queueArtworkObserver: null,
  logsSource: 'all',
  logsQuery: '',
  logsAutoRefresh: true,
  groupingSourceGroupId: null,
  groupingDragBlocked: false,
  expandedMemberGroups: new Set(),
  speakerOrder: loadSpeakerOrder(),
  animatedArtwork: new Map(),
  animatedArtworkPlayers: new Set(),
  artworkThemes: new Map(),
  albumArtworkUrls: new Map(),
  overviewRenderSignature: null,
  sonosRenderSignature: null,
  stateTimer: null,
  progressTimer: null,
  logsTimer: null,
};

const viewLabels = {
  overview: ['SYSTEM OVERVIEW', greeting()],
  sonos: ['ROOM CONTROL', 'Sonos setup.'],
  favorites: ['SONOS LIBRARY', 'Your Sonos Favorites.'],
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
      resetQueueView();
      renderSonos(model.state);
    }
    showView(button.dataset.view);
  });
});

document.addEventListener('click', async event => {
  const button = event.target.closest('[data-open-group], [data-close-group], [data-command], [data-members-toggle], [data-hue-action], [data-copy-mcp], [data-favorites-refresh], [data-play-favorite], [data-toggle-queue], [data-queue-refresh], [data-queue-more], [data-favorite-current]');
  if (!button) return;

  if (button.dataset.openGroup !== undefined) {
    openSonosGroup(button.dataset.openGroup);
    return;
  }

  if (button.dataset.closeGroup !== undefined) {
    model.selectedSonosGroupId = null;
    resetQueueView();
    renderSonos(model.state);
    return;
  }

  if (button.dataset.favoritesRefresh !== undefined) {
    await loadFavorites(true);
    return;
  }

  if (button.dataset.playFavorite !== undefined) {
    await playFavorite(button, button.dataset.playFavorite);
    return;
  }

  if (button.dataset.toggleQueue !== undefined) {
    if (model.queueOpen) {
      resetQueueView();
      renderSonos(model.state);
    } else {
      await loadQueue(button.dataset.toggleQueue, false);
    }
    return;
  }

  if (button.dataset.queueRefresh !== undefined) {
    await loadQueue(button.dataset.queueRefresh, true);
    return;
  }

  if (button.dataset.queueMore !== undefined) {
    const queueList = document.querySelector('.queue-list');
    const previousScrollTop = queueList?.scrollTop ?? 0;
    model.queueVisibleCount += QUEUE_RENDER_CHUNK;
    renderSonos(model.state);
    requestAnimationFrame(() => {
      const nextQueueList = document.querySelector('.queue-list');
      if (nextQueueList) nextQueueList.scrollTop = previousScrollTop;
    });
    return;
  }

  if (button.dataset.favoriteCurrent !== undefined) {
    await addCurrentTrackToFavorites(button, button.dataset.favoriteCurrent);
    return;
  }

  if (button.dataset.copyMcp !== undefined) {
    const code = document.querySelector('#mcp-config-code')?.textContent ?? '';
    await navigator.clipboard.writeText(code);
    showToast('MCP configuration copied');
    return;
  }

  if (button.dataset.membersToggle !== undefined) {
    const groupId = button.dataset.membersToggle;
    if (model.expandedMemberGroups.has(groupId)) model.expandedMemberGroups.delete(groupId);
    else model.expandedMemberGroups.add(groupId);
    renderSonos(model.state);
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
  const rollback = applyOptimisticPlaybackCommand(command, target);
  await runAction(button, () => request(`/sonos/${command}`, {
    method: 'POST',
    body: JSON.stringify(body),
  }), commandLabel(command), rollback);
});

document.addEventListener('keydown', event => {
  if (!event.target.matches('[role="link"][data-open-group]')) return;
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
    const rect = targetCard.getBoundingClientRect();
    const relativeY = event.clientY - rect.top;
    const edge = rect.height * 0.25;
    const intent = relativeY < edge ? 'before' : (relativeY > rect.height - edge ? 'after' : 'group');
    targetCard.dataset.dropIntent = intent;
    targetCard.classList.toggle('is-reorder-before', intent === 'before');
    targetCard.classList.toggle('is-reorder-after', intent === 'after');
    targetCard.dataset.dropLabel = intent === 'group'
      ? `Group with ${targetGroup ? groupDisplayName(targetGroup) : 'this room'}`
      : `Move ${intent} ${targetGroup ? groupDisplayName(targetGroup) : 'this room'}`;
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
  dropTarget.classList.remove('is-group-drop-target', 'is-reorder-before', 'is-reorder-after');
  delete dropTarget.dataset.dropLabel;
  delete dropTarget.dataset.dropIntent;
});

document.addEventListener('drop', async event => {
  const sourceGroupId = model.groupingSourceGroupId || event.dataTransfer?.getData('text/plain');
  if (!sourceGroupId) return;
  const targetCard = event.target.closest('.room-card[data-drag-group]');
  if (targetCard && targetCard.dataset.dragGroup !== sourceGroupId) {
    event.preventDefault();
    const targetGroupId = targetCard.dataset.dragGroup;
    const intent = targetCard.dataset.dropIntent;
    if (intent === 'before' || intent === 'after') {
      endGroupingDrag();
      reorderSpeakerGroup(sourceGroupId, targetGroupId, intent);
      showToast(`${groupName(model.state, sourceGroupId)} moved ${intent} ${groupName(model.state, targetGroupId)}`);
      renderSonos(model.state);
      return;
    }
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
  if (event.target.matches('[data-speech-level]')) {
    const select = event.target;
    const target = select.dataset.speechLevel;
    const level = Number(select.value);
    await runAction(select, () => request('/sonos/speech-enhancement', {
      method: 'POST',
      body: JSON.stringify({ target, level }),
    }), `Speech Enhancement set to ${speechLevelLabel(level)}`);
    return;
  }
  if (event.target.matches('[data-hue-mapping-group]')) {
    const select = event.target;
    const groupId = select.dataset.hueMappingGroup;
    const target = hueMappingTargetFromValue(model.state, select.value);
    await runAction(select, () => request('/hue/mapping', {
      method: 'PUT',
      body: JSON.stringify({ groupId, target }),
    }), target ? 'Hue group assignment saved' : 'Hue group assignment removed');
    return;
  }
  if (event.target.matches('[data-member-volume-target]')) {
    const input = event.target;
    const target = input.dataset.memberVolumeTarget;
    const memberId = input.dataset.memberId;
    const volume = Number(input.value);
    input.closest('.member-volume-row')?.querySelector('.volume-value')?.replaceChildren(`${volume}`);
    updateOptimisticMemberVolume(target, memberId, volume);
    await runAction(input, () => request('/sonos/member-volume', {
      method: 'POST',
      body: JSON.stringify({ target, memberId, volume }),
    }), `${input.dataset.memberName || 'Room'} volume set to ${volume}%`);
    return;
  }
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
  if (event.target.id === 'favorites-target') {
    model.favoritesTargetGroupId = event.target.value;
    model.favorites = { status: 'idle', items: [], error: null };
    await loadFavorites(true);
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
  if (event.target.matches('[data-member-volume-target]')) {
    event.target.closest('.member-volume-row')?.querySelector('.volume-value')
      ?.replaceChildren(`${event.target.value}`);
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
  model.favoritesTargetGroupId = null;
  model.favorites = { status: 'idle', items: [], error: null };
  model.currentFavorite = currentFavoriteInitialState();
  resetQueueView();
  model.animatedArtwork.clear();
  destroyAnimatedArtworkPlayers();
  model.artworkThemes.clear();
  model.overviewRenderSignature = null;
  model.sonosRenderSignature = null;
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
  if (model.activeView === 'favorites') renderFavorites(state);
  renderActivity(state);
  if (!document.activeElement?.matches('[data-hue-mapping-group]:not(:disabled)')) renderHue(state);
  renderMcp(state);
  if (model.activeView === 'logs') void refreshLogs();
  ui.updatedAt.textContent = `Updated ${formatClock(state.generatedAt)}`;
  document.querySelector('#sidebar-version').textContent = `v${state.relay.version} · ${formatDuration(state.relay.uptimeSeconds)}`;
}

function renderOverview(state) {
  const playbackTimes = captureAnimatedArtworkTimes();
  const overviewPanel = document.querySelector('#view-overview');
  const groups = orderedSonosGroups(state.sonos.groups ?? []);
  const featured = groups.find(isActivePlaybackGroup) ?? groups[0];
  const apnsReady = state.liveActivity.apns?.mode === 'ready';
  const hue = state.hue.ambience ?? {};
  const sessions = state.liveActivity.updateTokenCount ?? 0;
  const renderSignature = presentationSignature({
    featured,
    featuredArtwork: animatedArtworkRenderState(featured ? [featured] : []),
    groupCount: groups.length,
    activeGroupCount: groups.filter(isActivePlaybackGroup).length,
    discoveryStatus: state.sonos.discovery.status,
    apnsMode: state.liveActivity.apns?.mode,
    apnsEnvironment: state.liveActivity.apns?.environment,
    sessions,
    startTokenCount: state.liveActivity.startTokenCount,
    dismissedSuppressionCount: state.liveActivity.dismissedSuppressionCount,
    hueConfigured: hue.configured,
    hueRuntimeActive: hue.runtimeActive,
    hueRenderMode: hue.renderMode,
    hueMotionStyle: hue.motionStyle,
    hueBridgeReachable: state.hue.entertainment?.bridgeReachable,
    hueBridgeName: hue.bridge?.name,
    mcpEnabled: state.mcp.enabled,
    mcpTransport: state.mcp.transport,
    mcpMaxVolume: state.mcp.maxVolume,
  });
  if (model.overviewRenderSignature === renderSignature) {
    void resolveAnimatedArtwork(groups);
    void resolveArtworkThemes(groups);
    return;
  }
  const previousTheme = captureAlbumThemeTransition(
    overviewPanel?.querySelector('.now-playing-card'),
  );
  model.overviewRenderSignature = renderSignature;
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
      ${statCard('Sonos groups', groups.length, `${groups.filter(isActivePlaybackGroup).length} currently playing`)}
      ${statCard('Start tokens', state.liveActivity.startTokenCount, `${state.liveActivity.dismissedSuppressionCount} suppressed`)}
      ${statCard('Hue ambience', hue.runtimeActive ? 'Active' : (hue.configured ? 'Standby' : 'Off'), hue.renderMode ?? hue.motionStyle ?? 'not configured')}
      ${statCard('MCP', state.mcp.enabled ? 'Ready' : 'Disabled', `${state.mcp.transport} · max ${state.mcp.maxVolume}%`)}
    </div>`;
  overviewPanel.innerHTML = html;
  animateAlbumThemeTransition(
    overviewPanel.querySelector('.now-playing-card'),
    previousTheme,
  );
  hydrateAnimatedArtwork(playbackTimes);
  void resolveAnimatedArtwork(groups);
  void resolveArtworkThemes(groups);
}

function renderSonos(state) {
  const playbackTimes = captureAnimatedArtworkTimes();
  const sonosPanel = document.querySelector('#view-sonos');
  const groups = orderedSonosGroups(state.sonos.groups ?? []);
  const selected = groups.find(group => group.groupId === model.selectedSonosGroupId);
  if (model.selectedSonosGroupId && !selected) model.selectedSonosGroupId = null;
  if (selected) ensureCurrentFavoriteStatus(selected);
  const renderSignature = presentationSignature({
    groups,
    artwork: animatedArtworkRenderState(groups),
    selectedSonosGroupId: model.selectedSonosGroupId,
    expandedMemberGroups: [...model.expandedMemberGroups].sort(),
    queue: model.queueOpen ? {
      groupId: model.queue.groupId,
      status: model.queue.status,
      updateId: model.queue.updateId,
      currentTrackNumber: model.queue.currentTrackNumber,
      itemCount: model.queue.items.length,
      visibleCount: model.queueVisibleCount,
      error: model.queue.error,
    } : null,
    currentFavorite: selected ? currentFavoriteRenderState(selected) : null,
    discovery: state.sonos.discovery,
    maxVolume: state.mcp.maxVolume,
  });
  if (model.sonosRenderSignature === renderSignature) {
    void resolveAnimatedArtwork(groups);
    void resolveArtworkThemes(groups);
    return;
  }
  const previousPlayerTheme = captureAlbumThemeTransition(
    sonosPanel?.querySelector('.player-detail-card'),
  );
  model.sonosRenderSignature = renderSignature;
  if (selected) {
    sonosPanel.innerHTML = playerDetail(selected, state.mcp.maxVolume);
    animateAlbumThemeTransition(
      sonosPanel.querySelector('.player-detail-card'),
      previousPlayerTheme,
    );
    hydrateAnimatedArtwork(playbackTimes);
    void resolveAnimatedArtwork(groups);
    void resolveArtworkThemes(groups);
    observeVisibleQueueArtwork(selected.groupId);
    return;
  }
  sonosPanel.innerHTML = `
    <div class="section-header"><div class="brand-heading"><img class="integration-logo sonos-logo" src="/dashboard/assets/sonos-wordmark.svg" alt="Sonos"><div><h2>Discovered rooms</h2><p>Playback, volume, and soundbar controls</p></div></div><span class="badge ${state.sonos.discovery.status === 'ready' ? 'good' : 'warn'}">${groups.length} groups · ${escapeHtml(state.sonos.discovery.mode)}</span></div>
    ${groups.length ? `<div class="grouping-guide"><span class="grouping-guide-icon">⇄</span><span><strong>Group rooms by dragging</strong><small>Drop one speaker card onto another. Drop a grouped room into the tray to separate it.</small></span></div><div class="room-grid">${groups.map(group => roomCard(group, state.mcp.maxVolume)).join('')}</div><div class="grouping-action-tray" data-ungroup-drop><span class="grouping-tray-icon">−</span><span><strong>Ungroup</strong><small>Separate this room group</small></span></div>` : emptyState('No Sonos groups discovered', state.sonos.discovery.error ?? 'Make sure the relay and Sonos are on the same LAN, or configure SONOS_SEED_IP.')}`;
  hydrateAnimatedArtwork(playbackTimes);
  void resolveAnimatedArtwork(groups);
  void resolveArtworkThemes(groups);
}

function renderFavorites(state) {
  const panel = document.querySelector('#view-favorites');
  if (!panel) return;
  const groups = orderedSonosGroups(state.sonos.groups ?? []);
  if (!groups.length) {
    panel.innerHTML = emptyState('No Sonos rooms discovered', 'Favorites need a reachable Sonos coordinator on this LAN.');
    return;
  }
  if (!groups.some(group => group.groupId === model.favoritesTargetGroupId)) {
    model.favoritesTargetGroupId = preferredSonosTarget(groups)?.groupId ?? groups[0].groupId;
  }
  const target = groups.find(group => group.groupId === model.favoritesTargetGroupId) ?? groups[0];
  const targetOptions = groups.map(group => `<option value="${escapeAttr(group.groupId)}" ${group.groupId === target.groupId ? 'selected' : ''}>${escapeHtml(groupDisplayName(group))}</option>`).join('');
  const favorites = model.favorites.items ?? [];
  const content = model.favorites.status === 'loading'
    ? '<div class="library-loading"><span class="library-spinner" aria-hidden="true"></span><strong>Loading Sonos Favorites…</strong></div>'
    : model.favorites.status === 'error'
      ? emptyState('Favorites could not be loaded', model.favorites.error || 'Check that this Sonos room is reachable, then try again.')
      : favorites.length
        ? favoriteSections(favorites)
        : emptyState('No Sonos Favorites yet', 'Add the current track from a player page, or add favorites in the Sonos app.');
  panel.innerHTML = `
    <div class="section-header favorites-section-header">
      <div class="brand-heading"><img class="integration-logo sonos-logo" src="/dashboard/assets/sonos-wordmark.svg" alt="Sonos"><div><h2>Sonos Favorites</h2><p>Your household favorites, ready for any room</p></div></div>
      <div class="library-toolbar"><label><span>Play on</span><select class="select-field" id="favorites-target" aria-label="Room for Sonos Favorites">${targetOptions}</select></label><button class="icon-button" data-favorites-refresh title="Refresh Favorites" aria-label="Refresh Favorites">↻</button></div>
    </div>
    <div class="library-summary"><span><strong>${favorites.length}</strong> favorite${favorites.length === 1 ? '' : 's'}</span><span>Tap Play to replace playback in ${escapeHtml(groupDisplayName(target))}</span></div>
    ${content}`;
}

const favoriteCategoryOrder = ['playlist', 'album', 'song', 'artist', 'station', 'collection'];

function favoriteSections(favorites) {
  return `<div class="favorite-sections">${favoriteCategoryOrder.map(category => {
    const items = favorites.filter(favorite => favorite.category === category);
    if (!items.length) return '';
    const content = category === 'song'
      ? `<div class="favorite-song-list">${items.map(favoriteSongRow).join('')}</div>`
      : `<div class="favorite-card-rail">${items.map(favoriteCard).join('')}</div>`;
    return `<section class="favorite-category-section" data-favorite-category="${escapeAttr(category)}">
      <div class="favorite-category-heading"><h3>${escapeHtml(favoriteCategoryTitle(category))}</h3><span>${items.length}</span></div>
      ${content}
    </section>`;
  }).join('')}</div>`;
}

function favoriteCard(favorite) {
  const artworkURL = safeUrl(favorite.albumArtUri);
  const artwork = artworkURL
    ? `<img src="${escapeAttr(artworkURL)}" alt="${escapeAttr(favorite.title)}" referrerpolicy="no-referrer">`
    : '<span class="favorite-artwork-fallback" aria-hidden="true">★</span>';
  const actionLabel = favoriteActionLabel(favorite);
  return `<button type="button" class="favorite-card ${favorite.category === 'artist' ? 'artist' : ''}" data-play-favorite="${escapeAttr(favorite.id)}" ${favorite.playable ? '' : 'disabled'} title="${escapeAttr(actionLabel)}" aria-label="${escapeAttr(actionLabel)}">
    <div class="favorite-artwork">${artwork}</div>
    <span class="favorite-card-copy"><strong>${escapeHtml(favorite.title)}</strong>${favoriteMetadata(favorite)}</span>
    <span class="favorite-card-action" aria-hidden="true">${favorite.playable ? controlIcon('play') : '—'}</span>
  </button>`;
}

function favoriteSongRow(favorite) {
  const artworkURL = safeUrl(favorite.albumArtUri);
  const artwork = artworkURL
    ? `<img src="${escapeAttr(artworkURL)}" alt="${escapeAttr(favorite.title)}" referrerpolicy="no-referrer">`
    : '<span class="favorite-artwork-fallback" aria-hidden="true">♪</span>';
  const actionLabel = favoriteActionLabel(favorite);
  return `<button type="button" class="favorite-song-row" data-play-favorite="${escapeAttr(favorite.id)}" ${favorite.playable ? '' : 'disabled'} title="${escapeAttr(actionLabel)}" aria-label="${escapeAttr(actionLabel)}">
    <span class="favorite-song-artwork">${artwork}</span>
    <span class="favorite-card-copy"><strong>${escapeHtml(favorite.title)}</strong>${favoriteMetadata(favorite)}</span>
    <span class="favorite-card-action" aria-hidden="true">${favorite.playable ? controlIcon('play') : '—'}</span>
  </button>`;
}

function favoriteCategoryTitle(category) {
  return ({ playlist: 'Playlists', album: 'Albums', song: 'Songs', artist: 'Artists', station: 'Stations', collection: 'Collections' })[category] ?? 'Other';
}

function favoriteCategoryLabel(category) {
  return ({ playlist: 'Playlist', album: 'Album', song: 'Song', artist: 'Artist Radio', station: 'Station', collection: 'Collection' })[category] ?? 'Sonos Favorite';
}

function favoriteMetadata(favorite) {
  return `<span class="favorite-card-meta">${favoriteStreamingServiceBadge(favorite)}<small>${escapeHtml(favoriteCategoryLabel(favorite.category))}</small></span>`;
}

function favoriteStreamingServiceBadge(favorite) {
  const badge = streamingServiceBadge(favorite.playbackSourceRaw);
  return badge || '<span class="media-badge favorite-generic-service" aria-label="Music service"><span aria-hidden="true">♪</span></span>';
}

function favoriteActionLabel(favorite) {
  if (!favorite.playable) return `${favorite.title} cannot be played from the Dashboard`;
  return favorite.playbackKind === 'artistStation'
    ? `Play ${favorite.title} Radio`
    : `Play ${favorite.title}`;
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
  const mappingSetup = state.hue.mappingSetup ?? { targets: [], assignments: [] };
  if (!hue.configured) {
    document.querySelector('#view-hue').innerHTML = `<div class="section-header"><div class="brand-heading"><img class="integration-logo hue-logo" src="/dashboard/assets/philips-hue-logo.svg" alt="Philips Hue"><div><h2>Lighting setup</h2><p>Sonos ambience lighting</p></div></div></div>${emptyState('Hue is not configured', 'Pair a Hue Bridge in the iOS app first. Sonos-to-Hue assignments can then be managed here.')}`;
    return;
  }
  const activeGroups = hue.activeGroups ?? [];
  const ambienceRunning = hue.enabled !== false && hue.runtimePaused !== true;
  document.querySelector('#view-hue').innerHTML = `
    <article class="hue-hero">
      <div class="hue-hero-top"><div><img class="integration-logo hue-logo hue-hero-logo" src="/dashboard/assets/philips-hue-logo.svg" alt="Philips Hue"><p class="eyebrow">${!ambienceRunning ? 'AMBIENCE STOPPED' : (hue.runtimeActive ? 'AMBIENCE ACTIVE' : 'AMBIENCE STANDBY')}</p><h2>${escapeHtml(hue.bridge?.name ?? 'Hue Bridge')}</h2><p>${escapeHtml(hue.bridge?.ipAddress ?? '')} · ${hue.mappings ?? 0} Sonos mappings · ${hue.lights ?? 0} lights</p></div><button class="secondary-button ${ambienceRunning ? 'danger' : ''}" data-hue-action="${ambienceRunning ? 'stop' : 'start'}">${ambienceRunning ? 'Stop ambience' : 'Start ambience'}</button></div>
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
    ${hueMappingEditor(state, mappingSetup)}
    ${hue.lastError || entertainment.lastError ? `<div class="security-note">Latest error: ${escapeHtml(hue.lastError ?? entertainment.lastError)}</div>` : ''}`;
}

function hueMappingEditor(state, mappingSetup) {
  const groups = orderedSonosGroups(state.sonos.groups ?? []);
  const targets = mappingSetup.targets ?? [];
  const assignments = mappingSetup.assignments ?? [];
  const assignedCount = groups.filter(group => hueAssignmentForGroup(assignments, group)).length;
  if (!groups.length) {
    return `<section class="hue-mapping-panel"><div class="hue-mapping-header"><div><p class="eyebrow">ROOM ASSIGNMENTS</p><h2>Sonos groups → Hue groups</h2><p>Assign each discovered Sonos group to an Entertainment Area, Room, or Zone.</p></div></div>${emptyState('No Sonos groups discovered', 'Wait for LAN discovery before configuring room assignments.')}</section>`;
  }
  if (!targets.length) {
    return `<section class="hue-mapping-panel"><div class="hue-mapping-header"><div><p class="eyebrow">ROOM ASSIGNMENTS</p><h2>Sonos groups → Hue groups</h2><p>Assign each discovered Sonos group to an Entertainment Area, Room, or Zone.</p></div></div>${emptyState('No Hue groups available', 'Refresh Hue resources from the iOS app, then return here to configure assignments.')}</section>`;
  }
  return `<section class="hue-mapping-panel">
    <div class="hue-mapping-header"><div><p class="eyebrow">ROOM ASSIGNMENTS</p><h2>Sonos groups → Hue groups</h2><p>Assignments are saved directly on this relay and take effect immediately.</p></div><span class="badge ${assignedCount === groups.length ? 'good' : ''}">${assignedCount} of ${groups.length} assigned</span></div>
    <div class="hue-mapping-list">${groups.map(group => hueMappingRow(group, targets, assignments)).join('')}</div>
  </section>`;
}

function hueMappingRow(group, targets, assignments) {
  const assignment = hueAssignmentForGroup(assignments, group);
  const displayName = groupDisplayName(group);
  const selectedTarget = assignment?.target ? hueTargetValue(assignment.target) : '';
  const targetOptions = targets.map(target => {
    const value = hueTargetValue(target);
    const details = `${hueTargetKindLabel(target.kind)} · ${target.lightCount} light${target.lightCount === 1 ? '' : 's'}`;
    return `<option value="${escapeAttr(value)}" ${value === selectedTarget ? 'selected' : ''}>${escapeHtml(target.name)} · ${escapeHtml(details)}</option>`;
  }).join('');
  return `<label class="hue-mapping-row">
    <span class="hue-mapping-room"><span class="hue-mapping-icon" aria-hidden="true">◉</span><span><strong>${escapeHtml(displayName)}</strong><small>${group.groupMemberCount} speaker${group.groupMemberCount === 1 ? '' : 's'} · ${escapeHtml(groupSourceState(group).toLowerCase())}</small></span></span>
    <span class="hue-mapping-field"><span class="hue-mapping-field-label">Hue group</span><select class="select-field hue-mapping-select" data-hue-mapping-group="${escapeAttr(group.groupId)}" aria-label="Hue group for ${escapeAttr(displayName)}"><option value="">No Hue group</option>${targetOptions}</select></span>
  </label>`;
}

function hueAssignmentForGroup(assignments, group) {
  return assignments.find(assignment => (
    assignment.relayGroupID === group.groupId
    || assignment.sonosID === group.groupId
    || assignment.sonosName === group.speakerName
  ));
}

function hueMappingTargetFromValue(state, value) {
  if (!value) return null;
  const target = (state?.hue?.mappingSetup?.targets ?? [])
    .find(candidate => hueTargetValue(candidate) === value);
  return target ? { kind: target.kind, id: target.id } : null;
}

function hueTargetValue(target) {
  return `${target.kind}:${target.id}`;
}

function hueTargetKindLabel(kind) {
  return ({ entertainmentArea: 'Entertainment Area', room: 'Room', zone: 'Zone' })[kind] ?? 'Group';
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
  if (view === 'favorites') {
    renderFavorites(model.state);
    if (model.favorites.status === 'idle') void loadFavorites(false);
  }
}

function openSonosGroup(groupId) {
  if (!groupId || !model.state) return;
  model.selectedSonosGroupId = groupId;
  resetQueueView();
  showView('sonos');
  renderSonos(model.state);
}

function preferredSonosTarget(groups) {
  return groups.find(isActivePlaybackGroup) ?? groups[0] ?? null;
}

async function loadFavorites(force) {
  if (!model.state) return;
  const groups = orderedSonosGroups(model.state.sonos.groups ?? []);
  if (!groups.length) return;
  if (!groups.some(group => group.groupId === model.favoritesTargetGroupId)) {
    model.favoritesTargetGroupId = preferredSonosTarget(groups)?.groupId ?? groups[0].groupId;
  }
  if (!force && model.favorites.status === 'ready') {
    renderFavorites(model.state);
    return;
  }
  model.favorites = { ...model.favorites, status: 'loading', error: null };
  renderFavorites(model.state);
  try {
    const response = await request(`/sonos/favorites?target=${encodeURIComponent(model.favoritesTargetGroupId)}`);
    model.favorites = { status: 'ready', items: response.favorites ?? [], error: null };
  } catch (error) {
    model.favorites = { status: 'error', items: [], error: friendlyError(error) };
  }
  renderFavorites(model.state);
}

async function playFavorite(button, favoriteId) {
  if (!favoriteId || !model.favoritesTargetGroupId) return;
  button.disabled = true;
  try {
    const favorite = model.favorites.items.find(item => item.id === favoriteId);
    await request('/sonos/play-favorite', {
      method: 'POST',
      body: JSON.stringify({ target: model.favoritesTargetGroupId, favoriteId }),
    });
    showToast(favorite?.playbackKind === 'artistStation'
      ? `Playing ${favorite.title} Radio`
      : `Playing ${favorite?.title ?? 'Sonos Favorite'}`);
    await refreshState(false);
  } catch (error) {
    showToast(friendlyError(error), true);
  } finally {
    button.disabled = false;
  }
}

async function loadQueue(groupId, force) {
  if (!groupId || !model.state) return;
  if (!force && model.queueOpen && model.queue.groupId === groupId && model.queue.status === 'ready') {
    renderSonos(model.state);
    return;
  }
  model.queueOpen = true;
  model.queueVisibleCount = QUEUE_RENDER_CHUNK;
  model.queueArtworkAttempted.clear();
  model.queueArtworkObserver?.disconnect();
  model.queue = {
    status: 'loading', groupId, updateId: 0, currentTrackNumber: null, items: [], error: null,
  };
  renderSonos(model.state);
  try {
    const response = await request(`/sonos/queue?target=${encodeURIComponent(groupId)}`);
    model.queue = { status: 'ready', error: null, ...response.queue };
  } catch (error) {
    model.queue = {
      status: 'error', groupId, updateId: 0, currentTrackNumber: null, items: [], error: friendlyError(error),
    };
  }
  renderSonos(model.state);
}

function resetQueueView() {
  model.queueArtworkObserver?.disconnect();
  model.queueArtworkObserver = null;
  model.queueArtworkAttempted.clear();
  model.queueVisibleCount = QUEUE_RENDER_CHUNK;
  model.queueOpen = false;
  model.queue = {
    status: 'idle', groupId: null, updateId: 0, currentTrackNumber: null, items: [], error: null,
  };
}

async function addCurrentTrackToFavorites(button, groupId) {
  if (!groupId) return;
  button.disabled = true;
  try {
    const result = await request('/sonos/favorite-current', {
      method: 'POST',
      body: JSON.stringify({ target: groupId }),
    });
    showToast(result.alreadyExists ? 'Already in Sonos Favorites' : 'Added to Sonos Favorites');
    model.favorites = { status: 'idle', items: [], error: null };
    const group = model.state?.sonos?.groups?.find(candidate => candidate.groupId === groupId);
    if (group) {
      model.currentFavorite = {
        status: 'ready',
        groupId,
        identity: currentFavoriteIdentity(group),
        available: true,
        isFavorite: true,
        favorite: result.favorite ?? null,
        pending: false,
        checkedAt: Date.now(),
        error: null,
      };
      model.sonosRenderSignature = null;
      renderSonos(model.state);
    }
  } catch (error) {
    showToast(friendlyError(error), true);
  } finally {
    button.disabled = false;
  }
}

function currentFavoriteInitialState() {
  return {
    status: 'idle', groupId: null, identity: '', available: false,
    isFavorite: false, favorite: null, pending: false, checkedAt: 0, error: null,
  };
}

function canFavoriteGroup(group) {
  return Boolean(group)
    && !isTVGroup(group)
    && !isLiveStreamGroup(group)
    && groupPlaybackTitle(group) !== 'Not playing';
}

function currentFavoriteIdentity(group) {
  if (!canFavoriteGroup(group)) return '';
  return [group.groupId, group.trackTitle, group.artist, group.album, group.durationSeconds]
    .map(value => String(value ?? '').trim().toLowerCase())
    .join('|');
}

function currentFavoriteRenderState(group) {
  const identity = currentFavoriteIdentity(group);
  const state = model.currentFavorite;
  if (!identity || state.groupId !== group.groupId || state.identity !== identity) {
    return { status: identity ? 'loading' : 'unavailable', isFavorite: false };
  }
  return { status: state.status, available: state.available, isFavorite: state.isFavorite };
}

function ensureCurrentFavoriteStatus(group) {
  const identity = currentFavoriteIdentity(group);
  if (!identity) return;
  const state = model.currentFavorite;
  if (state.groupId !== group.groupId || state.identity !== identity) {
    model.currentFavorite = {
      ...currentFavoriteInitialState(),
      status: 'loading', groupId: group.groupId, identity, pending: true,
    };
    void loadCurrentFavoriteStatus(group.groupId, identity);
    return;
  }
  if (!state.pending && Date.now() - state.checkedAt >= CURRENT_FAVORITE_REFRESH_MS) {
    state.pending = true;
    void loadCurrentFavoriteStatus(group.groupId, identity);
  }
}

async function loadCurrentFavoriteStatus(groupId, identity) {
  try {
    const response = await request(`/sonos/favorite-current?target=${encodeURIComponent(groupId)}`);
    if (model.currentFavorite.groupId !== groupId || model.currentFavorite.identity !== identity) return;
    model.currentFavorite = {
      status: 'ready', groupId, identity,
      available: response.available === true,
      isFavorite: response.isFavorite === true,
      favorite: response.favorite ?? null,
      pending: false,
      checkedAt: Date.now(),
      error: null,
    };
    model.sonosRenderSignature = null;
    renderSonos(model.state);
  } catch (error) {
    if (model.currentFavorite.groupId !== groupId || model.currentFavorite.identity !== identity) return;
    const keepReadyState = model.currentFavorite.status === 'ready';
    model.currentFavorite = {
      ...model.currentFavorite,
      status: keepReadyState ? 'ready' : 'error',
      pending: false,
      checkedAt: Date.now(),
      error: friendlyError(error),
    };
    if (!keepReadyState) {
      model.sonosRenderSignature = null;
      renderSonos(model.state);
    }
  }
}

function nowPlayingCard(group, maxVolume) {
  const volume = group.groupVolume ?? 0;
  const displayName = groupDisplayName(group);
  const tv = isTVGroup(group);
  const sourceClass = isTVGroup(group) ? ' tv-source' : (isLiveStreamGroup(group) ? ' live-source' : '');
  return `<article class="now-playing-card album-themed-card is-clickable${sourceClass}" style="${albumThemeStyle(group)}" data-album-theme-key="${escapeAttr(albumThemeKey(group))}" data-open-group="${escapeAttr(group.groupId)}" role="link" tabindex="0" aria-label="Open ${escapeAttr(displayName)} in Sonos">
    ${albumThemeBackdrop(group)}
    <div class="artwork-wrap">${artwork(group, 'large')}</div>
    <div class="now-playing-content">
      <div class="card-kicker"><span>${tv ? 'TV input' : 'Now playing'}</span><span class="room-live">${escapeHtml(displayName)} <span class="open-player-arrow">→</span></span></div>
      <div class="track-meta"><h2>${escapeHtml(groupPlaybackTitle(group))}</h2>${tv ? '' : `<p>${escapeHtml(groupPlaybackSubtitle(group))}</p><div class="quality-row">${sourceBadges(group)}</div>`}</div>
      ${playbackProgress(group, 'overview')}
      <div class="playback-controls ${tv ? 'tv-summary-controls' : ''}">${playbackButtons(group)}<span class="volume-mini">VOL ${Math.min(volume,maxVolume)}%</span></div>
    </div>
  </article>`;
}

function emptyNowPlaying() {
  return `<div class="empty-state"><div><strong>Waiting for Sonos</strong><p>Rooms that are playing will appear after LAN discovery completes.</p></div></div>`;
}

function roomCard(group, maxVolume) {
  const volume = Math.min(group.groupVolume ?? 0, maxVolume);
  const speechLevel = group.soundbarSpeechEnhancementRawLevel ?? 0;
  const target = escapeAttr(group.groupId);
  const displayName = groupDisplayName(group);
  const sourceClass = isTVGroup(group) ? ' tv-source' : (isLiveStreamGroup(group) ? ' live-source' : '');
  const title = groupPlaybackTitle(group);
  const subtitle = groupPlaybackSubtitle(group, { compact: true });
  const trackLine = title === 'Not playing' ? 'Idle' : `${escapeHtml(title)} — ${escapeHtml(subtitle)}`;
  const mediaBadges = isTVGroup(group) ? '' : sourceBadges(group);
  const members = visibleGroupMembers(group);
  const membersExpanded = members.length > 1 && model.expandedMemberGroups.has(group.groupId);
  return `<article class="room-card album-themed-card${sourceClass}" style="${albumThemeStyle(group)}" draggable="true" data-drag-group="${target}">${albumThemeBackdrop(group)}
    <div class="room-top">
      <div class="room-open-button" data-open-group="${target}" role="link" tabindex="0" aria-label="Open player for ${escapeAttr(displayName)}">${artwork(group, 'room')}<span class="room-info"><strong>${escapeHtml(displayName)}</strong><span class="room-track">${trackLine}</span>${mediaBadges ? `<span class="room-meta">${mediaBadges}</span>` : ''}</span></div>
      ${roomPrimaryControl(group)}
    </div>
    <div class="room-volume-section"><label class="room-volume-control" title="Group volume"><span class="room-volume-icon" aria-hidden="true">◖</span><input type="range" min="0" max="${maxVolume}" value="${volume}" data-volume-target="${target}" aria-label="${escapeAttr(displayName)} group volume"><span class="volume-value">${volume}</span></label>${members.length > 1 ? `<button class="member-volume-toggle ${membersExpanded ? 'expanded' : ''}" data-members-toggle="${target}" title="${membersExpanded ? 'Hide' : 'Show'} room volumes" aria-label="${membersExpanded ? 'Hide' : 'Show'} room volumes">⌄</button>` : ''}</div>
    ${membersExpanded ? memberVolumePanel(group, maxVolume) : ''}
    ${(group.soundbarNightMode !== null && group.soundbarNightMode !== undefined) || speechLevel > 0 ? `<div class="soundbar-controls"><button class="toggle-chip ${group.soundbarNightMode ? 'on' : ''}" data-command="night-mode" data-target="${escapeAttr(group.groupId)}" data-enabled="${group.soundbarNightMode === true}">Night sound</button><button class="toggle-chip ${speechLevel > 0 ? 'on' : ''}" data-command="speech-enhancement" data-target="${escapeAttr(group.groupId)}" data-level="${(speechLevel + 1) % 5}">Speech ${speechLevelLabel(speechLevel)}</button></div>` : ''}
  </article>`;
}

function visibleGroupMembers(group) {
  const members = Array.isArray(group?.groupMembers) ? group.groupMembers : [];
  return members
    .filter(member => member && member.id && member.host)
    .sort((left, right) => Number(right.isCoordinator) - Number(left.isCoordinator));
}

function memberVolumePanel(group, maxVolume, detailed = false) {
  const target = escapeAttr(group.groupId);
  const rows = visibleGroupMembers(group).map(member => {
    const volume = Math.min(Number(member.volume ?? 0), maxVolume);
    return `<label class="member-volume-row"><span class="member-volume-name">${escapeHtml(member.name)}</span><span class="room-volume-icon" aria-hidden="true">◖</span><input type="range" min="0" max="${maxVolume}" value="${volume}" data-member-volume-target="${target}" data-member-id="${escapeAttr(member.id)}" data-member-name="${escapeAttr(member.name)}" aria-label="${escapeAttr(member.name)} volume"><span class="volume-value">${volume}</span></label>`;
  }).join('');
  return `<section class="member-volume-panel ${detailed ? 'detailed' : ''}">${detailed ? '<div class="member-volume-heading"><strong>Room volumes</strong><small>Adjust each visible room independently</small></div>' : ''}${rows}</section>`;
}

function playerDetail(group, maxVolume) {
  const volume = Math.min(group.groupVolume ?? 0, maxVolume);
  const speechLevel = group.soundbarSpeechEnhancementRawLevel ?? 0;
  const tv = isTVGroup(group);
  const hasSoundbar = tv || group.soundbarNightMode !== null && group.soundbarNightMode !== undefined
    || group.soundbarSpeechEnhancementRawLevel !== null && group.soundbarSpeechEnhancementRawLevel !== undefined;
  const displayName = groupDisplayName(group);
  const sourceClass = isTVGroup(group) ? ' tv-source' : (isLiveStreamGroup(group) ? ' live-source' : '');
  return `
    <div class="player-detail-header">
      <button class="back-button" data-close-group>← All rooms</button>
      <div class="player-library-actions">
        <button class="secondary-button compact ${model.queueOpen ? 'active' : ''}" data-toggle-queue="${escapeAttr(group.groupId)}"><span aria-hidden="true">≡</span>${model.queueOpen ? 'Hide Queue' : 'Queue'}</button>
        ${favoriteCurrentButton(group)}
      </div>
    </div>
    <div class="player-stage ${model.queueOpen ? 'queue-open' : ''}">
    <article class="player-detail-card album-themed-card${sourceClass}" style="${albumThemeStyle(group)}" data-album-theme-key="${escapeAttr(albumThemeKey(group))}">
      ${albumThemeBackdrop(group)}
      <div class="player-detail-artwork artwork-wrap">${artwork(group, 'large')}</div>
      <div class="player-detail-content">
        <div class="card-kicker"><span>${escapeHtml(displayName)}</span><span>${group.groupMemberCount} speaker${group.groupMemberCount === 1 ? '' : 's'}</span></div>
        <div class="player-detail-track">
          <h2>${escapeHtml(groupPlaybackTitle(group))}</h2>
          ${isTVGroup(group) ? '' : `<p>${escapeHtml(groupPlaybackSubtitle(group))}</p>`}
          ${isTVGroup(group) ? '' : `<small>${escapeHtml(group.album || 'No album metadata')}</small>`}
          ${tv ? '' : `<div class="quality-row">${sourceBadges(group)}</div>`}
        </div>
        ${playbackProgress(group, 'detail')}
        ${tv ? (hasSoundbar ? soundbarControlPanel(group, speechLevel) : '') : `<div class="player-detail-controls ${isLiveStreamGroup(group) ? 'single-control' : ''}">${playbackButtons(group)}</div>`}
        <label class="player-volume-control">
          <span class="player-volume-icon" aria-hidden="true">${volumeIcon()}</span>
          <input type="range" min="0" max="${maxVolume}" value="${volume}" data-volume-target="${escapeAttr(group.groupId)}" aria-label="${escapeAttr(displayName)} group volume">
          <strong class="volume-value">${volume}%</strong>
        </label>
        ${visibleGroupMembers(group).length > 1 ? memberVolumePanel(group, maxVolume, true) : ''}
        ${!tv && hasSoundbar ? soundbarControlPanel(group, speechLevel) : ''}
      </div>
    </article>
    ${model.queueOpen ? queuePanel(group) : ''}
    </div>`;
}

function favoriteCurrentButton(group) {
  if (!canFavoriteGroup(group)) return '';
  const state = currentFavoriteRenderState(group);
  if (state.status === 'loading') {
    return '<button class="secondary-button compact favorite-current-button checking" disabled><span class="library-spinner" aria-hidden="true"></span>Checking Favorites…</button>';
  }
  if (state.status === 'ready' && state.isFavorite) {
    return '<button class="secondary-button compact favorite-current-button active" disabled title="This track is already in Sonos Favorites"><span aria-hidden="true">★</span>In Sonos Favorites</button>';
  }
  return `<button class="secondary-button compact favorite-current-button" data-favorite-current="${escapeAttr(group.groupId)}"><span aria-hidden="true">☆</span>Add to Sonos Favorites</button>`;
}

function queuePanel(group) {
  const queue = model.queue;
  const loading = queue.status === 'loading' || queue.groupId !== group.groupId;
  const currentIndex = Math.max(0, queue.items.findIndex(item => item.trackNumber === queue.currentTrackNumber));
  const visibleItems = queue.items.slice(currentIndex, currentIndex + model.queueVisibleCount);
  const hiddenCount = Math.max(0, queue.items.length - currentIndex - visibleItems.length);
  let content;
  if (loading) {
    content = '<div class="library-loading queue-loading"><span class="library-spinner" aria-hidden="true"></span><strong>Loading queue…</strong></div>';
  } else if (queue.status === 'error') {
    content = emptyState('Queue could not be loaded', queue.error || 'Try refreshing this room queue.');
  } else if (!queue.items.length) {
    content = emptyState('The queue is empty', 'Play an album or add music from the Sonos app to populate this room queue.');
  } else {
    content = `<div class="queue-list">${visibleItems.map(item => queueRow(item, queue.currentTrackNumber)).join('')}${hiddenCount > 0 ? `<button class="queue-load-more" data-queue-more="${escapeAttr(group.groupId)}">Load ${Math.min(QUEUE_RENDER_CHUNK, hiddenCount)} more <span>${hiddenCount} remaining</span></button>` : ''}</div>`;
  }
  return `<aside class="queue-panel" aria-label="${escapeAttr(groupDisplayName(group))} Queue">
    <div class="queue-panel-header"><div><p class="eyebrow">UP NEXT</p><h2>${escapeHtml(groupDisplayName(group))} Queue</h2><p>${queue.items.length} track${queue.items.length === 1 ? '' : 's'}${queue.items.length ? ` · showing ${visibleItems.length} from current` : ''}</p></div><div class="queue-panel-actions"><button class="icon-button" data-queue-refresh="${escapeAttr(group.groupId)}" title="Refresh Queue" aria-label="Refresh Queue">↻</button><button class="icon-button" data-toggle-queue="${escapeAttr(group.groupId)}" title="Close Queue" aria-label="Close Queue">×</button></div></div>
    ${content}
  </aside>`;
}

function queueRow(item, currentTrackNumber) {
  const current = item.trackNumber === currentTrackNumber;
  const artworkURL = safeUrl(item.albumArtUri);
  const artwork = artworkURL
    ? `<img src="${escapeAttr(artworkURL)}" alt="${escapeAttr(item.album || item.title)}" loading="lazy" decoding="async" referrerpolicy="no-referrer">`
    : '<span aria-hidden="true">♪</span>';
  const subtitle = [item.artist, item.album].filter(Boolean).join(' · ') || 'Unknown artist';
  return `<article class="queue-row ${current ? 'current' : ''}" data-queue-album-key="${escapeAttr(item.albumKey)}" data-artwork-source="${escapeAttr(item.artworkSource)}">
    <span class="queue-number">${current ? '<i aria-hidden="true"></i>' : item.trackNumber}</span>
    <span class="queue-artwork">${artwork}</span>
    <span class="queue-copy"><strong>${escapeHtml(item.title)}</strong><small>${escapeHtml(subtitle)}</small></span>
    <span class="queue-duration">${item.durationSeconds > 0 ? formatTime(item.durationSeconds) : '—'}</span>
  </article>`;
}

function observeVisibleQueueArtwork(groupId) {
  model.queueArtworkObserver?.disconnect();
  model.queueArtworkObserver = null;
  if (!model.queueOpen || model.queue.status !== 'ready' || model.queue.groupId !== groupId) return;
  const queueList = document.querySelector('.queue-list');
  const rows = [...document.querySelectorAll('.queue-row[data-queue-album-key]')];
  if (!queueList || !rows.length) return;

  if (!('IntersectionObserver' in window)) {
    void loadQueueArtworkAlbums(groupId, rows.slice(0, QUEUE_ARTWORK_BATCH_LIMIT)
      .map(row => row.dataset.queueAlbumKey));
    return;
  }
  model.queueArtworkObserver = new IntersectionObserver(entries => {
    const albumKeys = entries
      .filter(entry => entry.isIntersecting)
      .map(entry => entry.target.dataset.queueAlbumKey)
      .filter(Boolean);
    if (albumKeys.length) void loadQueueArtworkAlbums(groupId, albumKeys);
  }, { root: queueList, rootMargin: '180px 0px' });
  rows.forEach(row => model.queueArtworkObserver.observe(row));
}

async function loadQueueArtworkAlbums(groupId, albumKeys) {
  const requested = [...new Set(albumKeys)]
    .filter(key => key && !model.queueArtworkAttempted.has(key))
    .slice(0, QUEUE_ARTWORK_BATCH_LIMIT);
  if (!requested.length) return;
  requested.forEach(key => model.queueArtworkAttempted.add(key));
  try {
    const response = await request('/sonos/queue-artwork', {
      method: 'POST',
      body: JSON.stringify({ target: groupId, albumKeys: requested }),
    });
    if (!model.queueOpen || model.queue.groupId !== groupId) return;
    const artworkByAlbum = new Map((response.artwork ?? [])
      .filter(item => safeUrl(item.albumArtUri))
      .map(item => [item.albumKey, item]));
    if (!artworkByAlbum.size) return;
    model.queue.items = model.queue.items.map(item => {
      const artwork = artworkByAlbum.get(item.albumKey);
      return artwork ? {
        ...item,
        albumArtUri: artwork.albumArtUri,
        artworkSource: artwork.artworkSource,
      } : item;
    });
    document.querySelectorAll('.queue-row[data-queue-album-key]').forEach(row => {
      const artwork = artworkByAlbum.get(row.dataset.queueAlbumKey);
      const url = safeUrl(artwork?.albumArtUri);
      if (!url) return;
      const container = row.querySelector('.queue-artwork');
      const item = model.queue.items.find(candidate => candidate.albumKey === artwork.albumKey);
      if (!container || !item) return;
      container.innerHTML = `<img src="${escapeAttr(url)}" alt="${escapeAttr(item.album || item.title)}" loading="lazy" decoding="async" referrerpolicy="no-referrer">`;
      row.dataset.artworkSource = artwork.artworkSource;
    });
  } catch (error) {
    console.warn('[dashboard] queue artwork batch failed', { groupId, error: friendlyError(error) });
  }
}

function playbackButtons(group) {
  const target = escapeAttr(group.groupId);
  if (isTVGroup(group)) return '';
  if (isLiveStreamGroup(group)) {
    const label = group.isPlaying ? 'Stop live stream' : 'Play live stream';
    return `<button class="control-button primary live-control" data-command="${group.isPlaying ? 'pause' : 'play'}" data-target="${target}" title="${label}" aria-label="${label}">${controlIcon(group.isPlaying ? 'stop' : 'play')}</button>`;
  }
  return `<button class="control-button" data-command="previous" data-target="${target}" title="Previous track" aria-label="Previous track">${controlIcon('previous')}</button><button class="control-button primary" data-command="${group.isPlaying ? 'pause' : 'play'}" data-target="${target}" title="${group.isPlaying ? 'Pause' : 'Play'}" aria-label="${group.isPlaying ? 'Pause' : 'Play'}">${controlIcon(group.isPlaying ? 'pause' : 'play')}</button><button class="control-button" data-command="next" data-target="${target}" title="Next track" aria-label="Next track">${controlIcon('next')}</button>`;
}

function controlIcon(kind) {
  const body = {
    previous: '<path d="M15 5 8 12l7 7"/>',
    next: '<path d="m9 5 7 7-7 7"/>',
    play: '<path class="filled" d="m9 6 10 6-10 6z"/>',
    pause: '<path class="filled" d="M8 6h3v12H8zM15 6h3v12h-3z"/>',
    stop: '<path class="filled" d="M7 7h10v10H7z"/>',
  }[kind] ?? '';
  return `<svg class="control-icon" viewBox="0 0 24 24" aria-hidden="true">${body}</svg>`;
}

function volumeIcon() {
  return '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 10v4h4l5 4V6L9 10H5z"/><path class="sound-wave" d="M17 9.5c1.4 1.4 1.4 3.6 0 5M19.5 7c2.8 2.8 2.8 7.2 0 10"/></svg>';
}

function roomPrimaryControl(group) {
  const target = escapeAttr(group.groupId);
  if (isTVGroup(group)) {
    const live = tvAudioPresentation(group).hasSignal;
    return `<span class="room-source-indicator ${live ? 'active' : ''}" title="${live ? 'TV audio live' : 'TV audio idle'}" aria-label="${live ? 'TV audio live' : 'TV audio idle'}"><span aria-hidden="true"></span></span>`;
  }
  const liveStream = isLiveStreamGroup(group);
  const progress = liveStream ? 0 : progressPercent(group);
  const label = liveStream
    ? (group.isPlaying ? 'Stop live stream' : 'Play live stream')
    : (group.isPlaying ? 'Pause' : 'Play');
  return `<button class="room-play-button ${liveStream ? 'live-control' : ''}" style="--room-progress:${progress * 3.6}deg" ${liveStream ? '' : `data-room-progress-group="${target}"`} data-command="${group.isPlaying ? 'pause' : 'play'}" data-target="${target}" title="${label}" aria-label="${label}"><span aria-hidden="true">${group.isPlaying ? (liveStream ? '■' : 'Ⅱ') : '▶'}</span></button>`;
}

function playbackProgress(group, variant) {
  const className = variant === 'detail' ? 'player-detail-progress' : 'progress-row';
  if (isTVGroup(group)) {
    return `<div class="${className} tv-format-progress">${tvFormatBadge(group)}</div>`;
  }
  if (isLiveStreamGroup(group)) {
    return `<div class="${className} source-progress"><span></span><strong>${escapeHtml(groupSourceState(group))}</strong><span></span></div>`;
  }
  const progress = progressPercent(group);
  return `<div class="${className}" data-progress-group="${escapeAttr(group.groupId)}"><div class="progress-track"><div class="progress-fill" style="width:${progress}%"></div></div><div class="progress-times"><span data-progress-current>${formatTime(currentPosition(group))}</span><span>${formatTime(group.durationSeconds)}</span></div></div>`;
}

function sourceBadges(group) {
  if (isTVGroup(group)) return tvFormatBadge(group);
  return `${streamingServiceBadge(group.playbackSourceRaw)}${audioQualityBadge(group.audioQualityLabel)}`;
}

function soundbarControlPanel(group, speechLevel) {
  const target = escapeAttr(group.groupId);
  return `<div class="player-soundbar-panel">
    <div class="soundbar-control-grid">
      <button class="soundbar-control-card ${group.soundbarNightMode ? 'on' : ''}" data-command="night-mode" data-target="${target}" data-enabled="${group.soundbarNightMode === true}"><span class="soundbar-control-icon" aria-hidden="true">☾</span><strong>Night Sound</strong><small>${group.soundbarNightMode ? 'On' : 'Off'}</small></button>
      <label class="soundbar-control-card soundbar-speech-card ${speechLevel > 0 ? 'on' : ''}"><span class="soundbar-control-icon" aria-hidden="true">≋</span><strong>Speech Enhancement</strong><span class="soundbar-select-value"><small>${speechLevelLabel(speechLevel)}</small><span aria-hidden="true">⌄</span></span><select class="soundbar-level-select" data-speech-level="${target}" aria-label="Speech Enhancement level">${[0,1,2,3,4].map(level => `<option value="${level}" ${level === speechLevel ? 'selected' : ''}>${speechLevelLabel(level)}</option>`).join('')}</select></label>
    </div>
  </div>`;
}

function speechLevelLabel(level) {
  return ['Off', 'Low', 'Medium', 'High', 'Max'][Math.max(0, Math.min(4, Number(level) || 0))];
}

function tvFormatBadge(group) {
  const format = tvAudioPresentation(group);
  if (!format.hasSignal) return '<span class="tv-format-placeholder" aria-label="No TV signal"></span>';
  if (format.isAtmos) {
    return `<span class="tv-format-chip"><img src="/dashboard/assets/badge-dolby-atmos.png" alt="Dolby Atmos">${format.atmosVariant ? `<strong>${escapeHtml(format.atmosVariant)}</strong>` : ''}</span>`;
  }
  return `<span class="tv-format-chip"><strong>${escapeHtml(format.codec || format.label)}</strong>${format.channelLayout ? `<span>·</span><code>${escapeHtml(format.channelLayout)}</code>` : ''}</span>`;
}

function artwork(group, variant) {
  const large = variant === 'large';
  const room = variant === 'room';
  if (isTVGroup(group)) {
    const live = tvAudioPresentation(group).hasSignal;
    const state = live ? 'LIVE' : 'IDLE';
    const tvArtwork = `<div class="${large ? 'artwork-fallback ' : 'room-art placeholder '}tv-artwork ${live ? 'has-signal' : ''}" role="img" aria-label="TV audio ${state.toLowerCase()}"><span class="tv-screen" aria-hidden="true"><span></span></span>${large ? `<span class="tv-signal-badge ${live ? 'live' : ''}"><i aria-hidden="true"></i>${state}</span>` : ''}</div>`;
    return room ? `<span class="room-artwork">${tvArtwork}</span>` : tvArtwork;
  }
  const url = albumArtworkURL(group);
  const staticArtwork = url
    ? `<img class="${large ? '' : 'room-art'}" src="${escapeAttr(url)}" alt="${escapeAttr(group.album || group.trackTitle || 'Album artwork')}" referrerpolicy="no-referrer">`
    : (large ? '<div class="artwork-fallback">◉</div>' : '<div class="room-art placeholder">◉</div>');
  if ((!large && !room) || !group.isPlaying || prefersReducedMotion()) {
    return room ? `<span class="room-artwork">${staticArtwork}</span>` : staticArtwork;
  }

  const key = animatedArtworkKey(group);
  const resolution = key ? model.animatedArtwork.get(key) : null;
  const animatedUrl = resolution?.status === 'ready' && !resolution.unplayable
    ? safeUrl(resolution.url)
    : '';
  if (!animatedUrl) return room ? `<span class="room-artwork">${staticArtwork}</span>` : staticArtwork;

  const poster = url ? ` poster="${escapeAttr(url)}"` : '';
  const animatedArtwork = `${staticArtwork}<video class="animated-artwork" data-animated-key="${escapeAttr(key)}" data-animated-src="${escapeAttr(animatedUrl)}"${poster} muted loop playsinline preload="metadata" aria-hidden="true"></video>`;
  return room
    ? `<span class="room-artwork">${animatedArtwork}</span>`
    : animatedArtwork;
}

function albumThemeBackdrop(group) {
  if (isTVGroup(group)) {
    return `<div class="album-theme-backdrop tv-theme-backdrop ${tvAudioPresentation(group).hasSignal ? 'has-signal' : ''}" aria-hidden="true"></div>`;
  }
  const url = albumArtworkURL(group);
  if (!url) return '';
  return `<div class="album-theme-backdrop" aria-hidden="true"><img src="${escapeAttr(url)}" alt="" referrerpolicy="no-referrer"></div>`;
}

function albumThemeStyle(group) {
  if (isTVGroup(group)) {
    const atmos = tvAudioPresentation(group).isAtmos;
    return atmos
      ? '--album-theme:#86A9E8;--tv-glow-rgb:134,169,232'
      : '--album-theme:#E1E1DD;--tv-glow-rgb:225,225,221';
  }
  const url = albumArtworkURL(group);
  const theme = safeThemeColor(model.artworkThemes.get(url)?.color) || '#FF9C6F';
  return `--album-theme:${theme}`;
}

function albumThemeKey(group) {
  if (isTVGroup(group)) {
    const presentation = tvAudioPresentation(group);
    return `tv:${presentation.hasSignal}:${presentation.isAtmos}`;
  }
  return albumTransitionIdentity(group);
}

function albumArtworkURL(group) {
  if (!group || isTVGroup(group)) return '';
  const key = albumTransitionIdentity(group);
  const candidate = safeUrl(group.albumArtFallbackUri || group.albumArtUri);
  const cached = model.albumArtworkUrls.get(key);
  if (cached) return cached;
  if (!candidate) return '';
  model.albumArtworkUrls.set(key, candidate);
  while (model.albumArtworkUrls.size > 128) {
    const oldest = model.albumArtworkUrls.keys().next().value;
    if (!oldest) break;
    model.albumArtworkUrls.delete(oldest);
  }
  return candidate;
}

function captureAlbumThemeTransition(card) {
  if (!card) return null;
  const style = getComputedStyle(card);
  return {
    key: card.dataset.albumThemeKey ?? '',
    albumTheme: style.getPropertyValue('--album-theme').trim(),
    tvGlowRgb: style.getPropertyValue('--tv-glow-rgb').trim(),
    backdrop: card.querySelector(':scope > .album-theme-backdrop')?.cloneNode(true) ?? null,
    artwork: card.querySelector(':scope > .artwork-wrap')?.cloneNode(true) ?? null,
  };
}

function animateAlbumThemeTransition(card, previous) {
  if (!card || !previous) return;
  const nextKey = card.dataset.albumThemeKey ?? '';
  if (!shouldAnimateAlbumThemeTransition(previous.key, nextKey, prefersReducedMotion())) return;

  const nextBackdrop = card.querySelector(':scope > .album-theme-backdrop');
  const nextArtwork = card.querySelector(':scope > .artwork-wrap');
  const nextAlbumTheme = card.style.getPropertyValue('--album-theme').trim();
  if (previous.albumTheme && nextAlbumTheme && previous.albumTheme !== nextAlbumTheme) {
    card.style.setProperty('--album-theme', previous.albumTheme);
    card.classList.add('album-theme-accent-transition');
  }

  if (nextBackdrop) nextBackdrop.classList.add('album-theme-backdrop-entering');
  if (nextArtwork) nextArtwork.classList.add('album-artwork-entering');
  const previousBackdrop = previous.backdrop;
  if (previousBackdrop) {
    previousBackdrop.classList.remove('album-theme-backdrop-entering', 'is-active');
    previousBackdrop.classList.add('album-theme-backdrop-previous');
    previousBackdrop.style.setProperty('--album-theme', previous.albumTheme);
    if (previous.tvGlowRgb) previousBackdrop.style.setProperty('--tv-glow-rgb', previous.tvGlowRgb);
    card.insertBefore(previousBackdrop, card.children[1] ?? null);
  }

  const previousArtwork = previous.artwork;
  let previousArtworkLayer = null;
  if (previousArtwork && nextArtwork) {
    previousArtwork.querySelectorAll('video').forEach(video => video.remove());
    previousArtworkLayer = document.createElement('div');
    previousArtworkLayer.className = 'album-artwork-previous';
    while (previousArtwork.firstChild) previousArtworkLayer.append(previousArtwork.firstChild);
    nextArtwork.append(previousArtworkLayer);
  }

  let started = false;
  const startTransition = () => {
    if (started) return;
    started = true;
    requestAnimationFrame(() => requestAnimationFrame(() => {
    nextBackdrop?.classList.add('is-active');
    previousBackdrop?.classList.add('is-active');
    nextArtwork?.classList.add('is-active');
    previousArtworkLayer?.classList.add('is-active');
    if (nextAlbumTheme) card.style.setProperty('--album-theme', nextAlbumTheme);
    }));

    window.setTimeout(() => {
      previousBackdrop?.remove();
      previousArtworkLayer?.remove();
      nextBackdrop?.classList.remove('album-theme-backdrop-entering', 'is-active');
      nextArtwork?.classList.remove('album-artwork-entering', 'is-active');
      card.classList.remove('album-theme-accent-transition');
    }, ALBUM_THEME_TRANSITION_MS + 100);
  };

  const nextImage = nextArtwork?.querySelector(':scope > img')
    ?? nextBackdrop?.querySelector('img');
  if (!nextImage || nextImage.complete) startTransition();
  else {
    nextImage.addEventListener('load', startTransition, { once: true });
    nextImage.addEventListener('error', startTransition, { once: true });
    window.setTimeout(startTransition, 900);
  }
}

async function resolveArtworkThemes(groups) {
  const now = Date.now();
  const candidates = new Set();
  for (const group of groups) {
    const url = albumArtworkURL(group);
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
      if (group.trackUri) query.set('trackUri', group.trackUri);
      if (group.albumArtUri) query.set('albumArtUri', group.albumArtUri);
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
  destroyDisconnectedAnimatedArtworkPlayers();
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
        console.warn('[dashboard] animated artwork media error', {
          key: video.dataset.animatedKey,
          code: video.error?.code ?? null,
          message: video.error?.message ?? '',
        });
        markAnimatedArtworkUnplayable(video);
      }, { once: true });
      attachAnimatedArtworkSource(video);
    }
    // Existing HLS players are paused while their view is hidden. Resume the
    // same media element when the view becomes visible again instead of
    // waiting for a manifest event that has already fired.
    playAnimatedArtworkVideo(video);
  });
}

function animatedArtworkRenderState(groups) {
  return groups.map(group => {
    const key = animatedArtworkKey(group);
    const artworkURL = albumArtworkURL(group);
    const resolution = key ? model.animatedArtwork.get(key) : null;
    return {
      key,
      status: resolution?.status ?? null,
      url: resolution?.url ?? null,
      unplayable: resolution?.unplayable === true,
      theme: model.artworkThemes.get(artworkURL)?.color ?? null,
    };
  });
}

function attachAnimatedArtworkSource(video) {
  const source = video.dataset.animatedSrc;
  if (!source) return;
  const Hls = window.Hls;
  const playbackMethod = selectAnimatedArtworkPlayback(
    Hls?.isSupported?.() === true,
    Boolean(video.canPlayType('application/vnd.apple.mpegurl')),
  );
  if (playbackMethod === 'native') {
    video.src = source;
    video.load();
    return;
  }

  if (playbackMethod === 'unsupported') {
    markAnimatedArtworkUnplayable(video);
    return;
  }

  const player = new Hls({
    enableWorker: true,
    lowLatencyMode: false,
    maxBufferLength: 12,
    backBufferLength: 0,
  });
  const entry = { video, player };
  model.animatedArtworkPlayers.add(entry);
  video.dataset.hlsPlayer = 'true';
  player.on(Hls.Events.MANIFEST_PARSED, () => playAnimatedArtworkVideo(video));
  player.on(Hls.Events.ERROR, (_event, data) => {
    if (!data?.fatal) return;
    console.warn('[dashboard] animated artwork HLS error', {
      key: video.dataset.animatedKey,
      type: data.type,
      details: data.details,
    });
    markAnimatedArtworkUnplayable(video);
    player.destroy();
    model.animatedArtworkPlayers.delete(entry);
  });
  player.loadSource(source);
  player.attachMedia(video);
}

function playAnimatedArtworkVideo(video) {
  void video.play().catch(error => {
    console.warn('[dashboard] animated artwork playback rejected', {
      key: video.dataset.animatedKey,
      name: error?.name ?? 'Error',
      message: error?.message ?? '',
    });
    video.classList.remove('ready');
  });
}

function markAnimatedArtworkUnplayable(video) {
  video.hidden = true;
  video.classList.remove('ready');
  const resolution = model.animatedArtwork.get(video.dataset.animatedKey);
  if (resolution?.status === 'ready') resolution.unplayable = true;
}

function destroyDisconnectedAnimatedArtworkPlayers() {
  for (const entry of model.animatedArtworkPlayers) {
    if (entry.video.isConnected) continue;
    entry.player.destroy();
    model.animatedArtworkPlayers.delete(entry);
  }
}

function destroyAnimatedArtworkPlayers() {
  for (const entry of model.animatedArtworkPlayers) entry.player.destroy();
  model.animatedArtworkPlayers.clear();
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
  document.querySelectorAll('[data-room-progress-group]').forEach(button => {
    const group = byId.get(button.dataset.roomProgressGroup);
    if (!group) return;
    button.style.setProperty('--room-progress', `${progressPercent(group, currentPosition(group)) * 3.6}deg`);
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

async function runAction(element, operation, successMessage, rollback = null) {
  element.disabled = true;
  try {
    await operation();
    showToast(successMessage);
    await refreshState(false);
  } catch (error) {
    rollback?.();
    showToast(friendlyError(error), true);
  } finally {
    element.disabled = false;
  }
}

function applyOptimisticPlaybackCommand(command, groupId) {
  if (!['play', 'pause'].includes(command) || !model.state) return null;
  const group = model.state.sonos?.groups?.find(candidate => candidate.groupId === groupId);
  if (!group) return null;
  const previous = { isPlaying: group.isPlaying, transportStateRaw: group.transportStateRaw };
  group.isPlaying = command === 'play';
  group.transportStateRaw = command === 'play' ? 'PLAYING' : 'PAUSED_PLAYBACK';
  renderOverview(model.state);
  renderSonos(model.state);
  return () => {
    group.isPlaying = previous.isPlaying;
    group.transportStateRaw = previous.transportStateRaw;
    renderOverview(model.state);
    renderSonos(model.state);
  };
}

function updateOptimisticMemberVolume(groupId, memberId, volume) {
  const group = model.state?.sonos?.groups?.find(candidate => candidate.groupId === groupId);
  const member = group?.groupMembers?.find(candidate => candidate.id === memberId || candidate.host === memberId);
  if (member) member.volume = volume;
}

function loadSpeakerOrder() {
  try {
    const parsed = JSON.parse(localStorage.getItem('charm-relay-speaker-order') || '[]');
    return Array.isArray(parsed) ? parsed.filter(value => typeof value === 'string') : [];
  } catch {
    return [];
  }
}

function orderedSonosGroups(groups) {
  const positions = new Map(model.speakerOrder.map((groupId, index) => [groupId, index]));
  return [...groups].sort((left, right) => {
    const leftIndex = positions.get(left.groupId) ?? Number.MAX_SAFE_INTEGER;
    const rightIndex = positions.get(right.groupId) ?? Number.MAX_SAFE_INTEGER;
    return leftIndex - rightIndex;
  });
}

function reorderSpeakerGroup(sourceGroupId, targetGroupId, placement) {
  const ids = orderedSonosGroups(model.state?.sonos?.groups ?? []).map(group => group.groupId);
  const sourceIndex = ids.indexOf(sourceGroupId);
  if (sourceIndex < 0) return;
  ids.splice(sourceIndex, 1);
  const targetIndex = ids.indexOf(targetGroupId);
  if (targetIndex < 0) return;
  ids.splice(placement === 'before' ? targetIndex : targetIndex + 1, 0, sourceGroupId);
  model.speakerOrder = ids;
  localStorage.setItem('charm-relay-speaker-order', JSON.stringify(ids));
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
    element.classList.remove('is-reorder-before', 'is-reorder-after');
    delete element.dataset.dropLabel;
    delete element.dataset.dropIntent;
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
    unknown_sonos_group: 'This Sonos group is no longer available. Refresh and try again.',
    current_favorite_unavailable: 'Choose a regular music track before adding it to Sonos Favorites.',
    artist_station_unavailable: 'This Apple Music artist radio could not be resolved for the selected Sonos room.',
    favorite_not_playable: 'This Sonos shortcut cannot be played directly from the Dashboard.',
    unknown_favorite: 'This Sonos Favorite is no longer available. Refresh Favorites and try again.',
    hue_not_configured: 'Pair and sync the Hue Bridge before configuring assignments.',
    unknown_hue_group: 'This Hue group is no longer available. Refresh Hue resources and try again.',
    hue_mapping_save_failed: 'The Hue assignment could not be saved.',
  };
  const message = error?.message ?? '';
  const matchedKey = Object.keys(messages).find(key => message === key || message.startsWith(`${key}:`));
  return (matchedKey ? messages[matchedKey] : null) ?? message ?? 'Request failed';
}

function groupName(state, groupId) { const group = state.sonos.groups.find(candidate => candidate.groupId === groupId); return group ? groupDisplayName(group) : (groupId ?? '—'); }
function shortId(value) { if (!value) return '—'; return value.length > 15 ? `${value.slice(0,7)}…${value.slice(-5)}` : value; }
function selected(value) { return model.logsSource === value ? 'selected' : ''; }
function safeUrl(value) { try { const url = new URL(value); return ['http:','https:'].includes(url.protocol) ? url.href : ''; } catch { return ''; } }
function safeThemeColor(value) { return /^#[0-9a-f]{6}$/i.test(String(value ?? '')) ? String(value).toUpperCase() : ''; }
function currentPosition(group) { if (!isGroupPlaying(group)) return group.positionSeconds ?? 0; const sampledAt = Date.parse(group.sampledAt); const elapsed = Number.isFinite(sampledAt) ? Math.max(0, (Date.now() - sampledAt) / 1000) : 0; return Math.min(group.durationSeconds || Infinity, (group.positionSeconds ?? 0) + elapsed); }
function progressPercent(group, position = currentPosition(group)) { return group.durationSeconds > 0 ? Math.min(100, Math.max(0, position / group.durationSeconds * 100)) : 0; }
function formatTime(seconds) { const safe = Number.isFinite(seconds) ? Math.max(0, Math.round(seconds)) : 0; return `${Math.floor(safe / 60)}:${String(safe % 60).padStart(2,'0')}`; }
function formatClock(value) { const date = new Date(value); return Number.isNaN(date.valueOf()) ? '—' : date.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', second: '2-digit' }); }
function formatRelative(value) { const date = new Date(value); if (Number.isNaN(date.valueOf())) return '—'; const delta = Math.round((date.valueOf() - Date.now()) / 1000); const abs = Math.abs(delta); if (abs < 60) return delta < 0 ? `${abs}s ago` : `in ${abs}s`; if (abs < 3600) return delta < 0 ? `${Math.round(abs/60)}m ago` : `in ${Math.round(abs/60)}m`; if (abs < 86400) return delta < 0 ? `${Math.round(abs/3600)}h ago` : `in ${Math.round(abs/3600)}h`; return date.toLocaleDateString('en-US'); }
function formatDuration(seconds) { if (seconds < 3600) return `${Math.floor(seconds/60)}m`; if (seconds < 86400) return `${Math.floor(seconds/3600)}h`; return `${Math.floor(seconds/86400)}d`; }
function greeting() { const hour = new Date().getHours(); return hour < 12 ? 'Good morning.' : hour < 18 ? 'Good afternoon.' : 'Good evening.'; }
function escapeHtml(value) { return String(value ?? '').replace(/[&<>'"]/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[char])); }
function escapeAttr(value) { return escapeHtml(value); }

void bootstrap();
