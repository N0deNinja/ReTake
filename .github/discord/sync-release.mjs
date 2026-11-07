// Runs in the ReTake repo's GitHub Action on every published release:
//  - edits the card in the Discord download channel to show the newest release
//  - posts the release in the Discord updates channel
// Env: DOWNLOAD_WEBHOOK, DOWNLOAD_MESSAGE_ID, UPDATES_WEBHOOK, POST_UPDATE ("true" to post), GITHUB_TOKEN
import { readFileSync, existsSync } from 'node:fs';
import { latestRelease, releaseCard, releaseAnnouncement } from './release-card.mjs';

const { DOWNLOAD_WEBHOOK, DOWNLOAD_MESSAGE_ID, UPDATES_WEBHOOK, POST_UPDATE, GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_EVENT_PATH } = process.env;

async function send(method, url, body) {
  const res = await fetch(url, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  if (!res.ok) throw new Error(`Discord ${method}: ${res.status} ${await res.text()}`);
}

const latest = await latestRelease(GITHUB_REPOSITORY || 'N0deNinja/ReTake', GITHUB_TOKEN);
const event = GITHUB_EVENT_PATH && existsSync(GITHUB_EVENT_PATH) ? JSON.parse(readFileSync(GITHUB_EVENT_PATH, 'utf8')).release : null;

if (DOWNLOAD_WEBHOOK && DOWNLOAD_MESSAGE_ID) {
  await send('PATCH', `${DOWNLOAD_WEBHOOK}/messages/${DOWNLOAD_MESSAGE_ID}?with_components=true`, releaseCard(latest));
  console.log(`download card now shows ${latest.tag_name}`);
}
if (UPDATES_WEBHOOK && POST_UPDATE === 'true') {
  const r = event || latest;
  await send('POST', `${UPDATES_WEBHOOK}?wait=true&with_components=true`, releaseAnnouncement(r));
  console.log(`posted ${r.tag_name} in updates`);
}
