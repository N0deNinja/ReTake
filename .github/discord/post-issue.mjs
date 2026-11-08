// Runs in the "Discord issues" GitHub Action: posts an issue opened, closed or reopened on GitHub in the
// Discord issues channel. Env: ISSUES_WEBHOOK.
// Everything about the issue is written by whoever opened it, so it is read from the event file, never put
// in a command line, and Discord is told to ping nobody whatever it says.
import { readFileSync } from 'node:fs';
import { TEAL } from './release-card.mjs';

const { ISSUES_WEBHOOK, GITHUB_EVENT_PATH } = process.env;
if (!ISSUES_WEBHOOK) {
  console.log('DISCORD_ISSUES_WEBHOOK is not set: nothing posted');
  process.exit(0);
}
const { action, issue } = JSON.parse(readFileSync(GITHUB_EVENT_PATH, 'utf8'));
if (issue.pull_request) process.exit(0);

const GREY = 0x6e7681, PURPLE = 0x8957e5;
const cut = (text, max) => (text.length <= max ? text : `${text.slice(0, max).trimEnd()}…`);

// The start of the issue: a bug report pastes ReTake's whole report, so only its first lines.
function excerpt(body = '') {
  const text = body
    .replace(/\r/g, '')
    .replace(/<!--[\s\S]*?-->/g, '')
    .replace(/```[\s\S]*?(```|$)/g, '')
    .replace(/^#{1,6}\s+(.+)$/gm, '**$1**')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
  return cut(text, 500);
}

const title = cut(`#${issue.number} ${issue.title}`, 250);
const author = { name: issue.user.login, icon_url: issue.user.avatar_url, url: issue.user.html_url };
const labels = issue.labels.map((l) => l.name);
let embed;
if (action === 'opened') {
  embed = {
    color: TEAL, author, title, url: issue.html_url,
    description: excerpt(issue.body) || '*No description.*',
    fields: labels.length ? [{ name: 'Labels', value: cut(labels.join(', '), 1000), inline: true }] : [],
    footer: { text: 'New issue on GitHub' },
    timestamp: issue.created_at,
  };
} else if (action === 'closed') {
  const done = issue.state_reason !== 'not_planned';
  embed = { color: done ? PURPLE : GREY, author, title, url: issue.html_url, footer: { text: done ? 'Closed: fixed or done' : 'Closed: not planned' }, timestamp: issue.closed_at };
} else if (action === 'reopened') {
  embed = { color: TEAL, author, title, url: issue.html_url, footer: { text: 'Reopened' }, timestamp: new Date().toISOString() };
} else {
  process.exit(0);
}

const res = await fetch(`${ISSUES_WEBHOOK}?wait=true&with_components=true`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    embeds: [embed],
    allowed_mentions: { parse: [] },
    components: [{ type: 1, components: [{ type: 2, style: 5, label: 'Open on GitHub', url: issue.html_url, emoji: { name: '🐞' } }] }],
  }),
});
if (!res.ok) throw new Error(`Discord: ${res.status} ${await res.text()}`);
console.log(`posted issue #${issue.number} (${action}) in Discord`);
