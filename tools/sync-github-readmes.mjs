import { readFile } from 'node:fs/promises';

const token = requiredEnv('GITHUB_TOKEN');
const repository = process.env.GITHUB_REPOSITORY_TARGET ?? 'charmmmz/Charm-for-Sonos';
const branch = process.env.GITHUB_BRANCH_TARGET ?? 'main';
const apiBase = (process.env.GITHUB_API_URL ?? 'https://api.github.com').replace(/\/$/, '');
const dryRun = process.env.GITHUB_README_SYNC_DRY_RUN === 'true';
const files = [
  { local: 'README.md', remote: 'README.md' },
  { local: 'nas-relay/README.md', remote: 'nas-relay/README.md' },
];

for (const file of files) {
  await syncFile(file);
}

async function syncFile(file) {
  const localContent = await readFile(file.local);
  const endpoint = `${apiBase}/repos/${repository}/contents/${encodedPath(file.remote)}`;
  const currentResponse = await githubRequest(`${endpoint}?ref=${encodeURIComponent(branch)}`);

  let currentSha;
  if (currentResponse.status === 200) {
    const current = await currentResponse.json();
    currentSha = current.sha;
    const remoteContent = Buffer.from(current.content ?? '', 'base64');
    if (remoteContent.equals(localContent)) {
      console.log(`${file.remote}: already current`);
      return;
    }
  } else if (currentResponse.status !== 404) {
    throw await responseError('read', file.remote, currentResponse);
  }

  const body = {
    message: `docs: sync ${file.remote} from Forgejo [skip ci]`,
    content: localContent.toString('base64'),
    branch,
    ...(currentSha ? { sha: currentSha } : {}),
  };
  if (dryRun) {
    console.log(`${file.remote}: would update`);
    return;
  }
  const updateResponse = await githubRequest(endpoint, {
    method: 'PUT',
    body: JSON.stringify(body),
  });
  if (updateResponse.status !== 200 && updateResponse.status !== 201) {
    throw await responseError('update', file.remote, updateResponse);
  }
  console.log(`${file.remote}: updated`);
}

function githubRequest(url, options = {}) {
  return fetch(url, {
    ...options,
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      'User-Agent': 'charm-for-sonos-readme-sync',
      'X-GitHub-Api-Version': '2022-11-28',
      ...options.headers,
    },
  });
}

async function responseError(operation, file, response) {
  const detail = await response.text();
  return new Error(`Failed to ${operation} ${file}: HTTP ${response.status} ${detail}`);
}

function encodedPath(path) {
  return path.split('/').map(encodeURIComponent).join('/');
}

function requiredEnv(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}
