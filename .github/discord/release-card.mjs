// Discord messages built from a GitHub release. Shared by setup.mjs and sync-release.mjs
// (sync-release.mjs runs in the ReTake repo's GitHub Action on every new release).

export const TEAL = 0x22e5cf;
export const REPO_URL = 'https://github.com/N0deNinja/ReTake';
export const RAW = 'https://raw.githubusercontent.com/N0deNinja/ReTake/main/docs';
const FOOTER = 'Offline only · fan project, not affiliated with EA, Full Circle or the ReSkate team';

export async function latestRelease(repo = 'N0deNinja/ReTake', token) {
  const res = await fetch(`https://api.github.com/repos/${repo}/releases/latest`, {
    headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'retake-discord', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
  });
  if (!res.ok) throw new Error(`GitHub releases: ${res.status}`);
  return res.json();
}

const zipOf = (r) => r.assets.find((a) => a.name.toLowerCase().endsWith('.zip')) || r.assets[0];
const mb = (bytes) => `${(bytes / 1048576).toFixed(1)} MB`;
const unix = (iso) => Math.floor(new Date(iso).getTime() / 1000);
const needs = (r) => r.body?.match(/Needs ReSkate \*\*([^*]+)\*\*/i)?.[1];

// Release notes -> embed-friendly text: headings become bold lines, cut at a clean boundary.
function notes(body = '', max) {
  const text = body
    .replace(/\r/g, '')
    .replace(/^#{1,6}\s+(.+)$/gm, '**$1**')
    .replace(/^>\s?/gm, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
  if (text.length <= max) return text;
  const cut = text.lastIndexOf('\n\n', max);
  return `${text.slice(0, cut > max * 0.5 ? cut : max).trim()}\n\n…`;
}

const link = (label, url, emoji) => ({ type: 2, style: 5, label, url, ...(emoji ? { emoji: { name: emoji } } : {}) });
const row = (...buttons) => ({ type: 1, components: buttons });

/** The pinned card in the download channel. Edited in place on every release. */
export function releaseCard(r) {
  const zip = zipOf(r);
  const fields = [
    { name: 'Version', value: `\`${r.tag_name}\``, inline: true },
    { name: 'Size', value: zip ? mb(zip.size) : '—', inline: true },
    { name: 'Released', value: `<t:${unix(r.published_at)}:R>`, inline: true },
  ];
  if (needs(r)) fields.push({ name: 'Needs', value: `ReSkate **${needs(r)}**`, inline: true });
  return {
    embeds: [{
      color: TEAL,
      author: { name: 'LATEST RELEASE' },
      title: r.name || r.tag_name,
      url: r.html_url,
      thumbnail: { url: `${RAW}/logo.png` },
      description: notes(r.body, 700),
      fields,
      footer: { text: FOOTER },
      timestamp: r.published_at,
    }],
    components: [
      row(
        ...(zip ? [link(`Download ${zip.name}`, zip.browser_download_url, '⬇️')] : []),
        link('Release notes', r.html_url, '📝'),
        link('Install guide', `${REPO_URL}#install`, '📖'),
      ),
      row(
        link('Report a bug', `${REPO_URL}/issues/new`, '🐞'),
        link('All releases', `${REPO_URL}/releases`, '🗂️'),
      ),
    ],
  };
}

/** A post in the updates channel when a release comes out. */
export function releaseAnnouncement(r) {
  const zip = zipOf(r);
  return {
    embeds: [{
      color: TEAL,
      author: { name: `NEW RELEASE · ${r.tag_name}` },
      title: r.name || r.tag_name,
      url: r.html_url,
      description: notes(r.body, 1800),
      image: { url: `${RAW}/how-it-works.jpg` },
      footer: { text: FOOTER },
      timestamp: r.published_at,
    }],
    components: [row(
      ...(zip ? [link(`Download ${r.tag_name}`, zip.browser_download_url, '⬇️')] : []),
      link('Release notes', r.html_url, '📝'),
    )],
  };
}

/** Welcome card. `ch` maps channel keys to mentions. */
export function welcomeCard(ch) {
  return {
    embeds: [{
      color: TEAL,
      title: 'Welcome to ReTake',
      url: REPO_URL,
      thumbnail: { url: `${RAW}/logo.png` },
      description: [
        '**Mess up anywhere in your line, go back to any moment, and carry on from there.**',
        'A fan-made [ReSkate](https://github.com/Dingo-Shenanigans/ReSkate) mod for skate. on PC.',
        '',
        `⬇️  Get the newest version in ${ch.download}`,
        `📰  News and releases in ${ch.updates}`,
        `💬  Talk in ${ch.chat}`,
        '🎙️  Got feedback? Jump into a **FEEDBACK** room and tell us live.',
        '',
        '**House rules**',
        '• Be respectful, keep it safe for work, no spam.',
        '• Offline only. Don\'t ask for or share ways around that.',
        '• Bugs: press F11, **Report a problem**, then attach the file to a GitHub issue.',
        '• Don\'t report ReTake bugs to EA, Full Circle or the ReSkate team.',
      ].join('\n'),
      image: { url: `${RAW}/how-it-works.jpg` },
      footer: { text: FOOTER },
    }],
    components: [row(
      link('Download latest', `${REPO_URL}/releases/latest`, '⬇️'),
      link('GitHub', REPO_URL, '⭐'),
      link('Report a bug', `${REPO_URL}/issues/new`, '🐞'),
    )],
  };
}
