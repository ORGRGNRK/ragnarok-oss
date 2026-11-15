import { escapeHtml } from './http';

const PLACEHOLDER = /\[[^[\]]+\]/g;

export function highlightPlaceholders(escaped: string): string {
  return escaped.replace(PLACEHOLDER, (m) => `<mark class="placeholder">${m}</mark>`);
}

function inline(text: string): string {
  const escaped = escapeHtml(text);
  const withCode = escaped.replace(/`([^`]+)`/g, (_m, code: string) => `<code>${code}</code>`);
  const withBold = withCode.replace(/\*\*([^*]+)\*\*/g, (_m, strong: string) => `<strong>${strong}</strong>`);
  return highlightPlaceholders(withBold);
}

function isBlock(line: string): boolean {
  return line.startsWith('>') || line.startsWith('- ') || /^\d+\.\s/.test(line);
}

/** A small markdown subset. The source is escaped before any tag is added. */
export function renderMarkdown(src: string): string {
  const lines = src.replace(/\r\n/g, '\n').split('\n');
  const out: string[] = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i] ?? '';
    if (!line.trim()) {
      i++;
      continue;
    }
    if (line.startsWith('>')) {
      const quote: string[] = [];
      while (i < lines.length && (lines[i] ?? '').startsWith('>')) {
        quote.push((lines[i] ?? '').replace(/^>\s?/, ''));
        i++;
      }
      const paras: string[] = [];
      let buf: string[] = [];
      const flush = () => {
        if (!buf.length) return;
        paras.push(`<p>${inline(buf.join(' '))}</p>`);
        buf = [];
      };
      for (const q of quote) {
        if (!q.trim()) flush();
        else buf.push(q.trim());
      }
      flush();
      out.push(`<blockquote>${paras.join('')}</blockquote>`);
      continue;
    }
    if (line.startsWith('- ')) {
      const items: string[] = [];
      while (i < lines.length && (lines[i] ?? '').startsWith('- ')) {
        items.push(`<li>${inline((lines[i] ?? '').slice(2).trim())}</li>`);
        i++;
      }
      out.push(`<ul>${items.join('')}</ul>`);
      continue;
    }
    if (/^\d+\.\s/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^\d+\.\s/.test(lines[i] ?? '')) {
        items.push(`<li>${inline((lines[i] ?? '').replace(/^\d+\.\s+/, '').trim())}</li>`);
        i++;
      }
      out.push(`<ol>${items.join('')}</ol>`);
      continue;
    }
    const buf: string[] = [];
    while (i < lines.length && (lines[i] ?? '').trim() && !isBlock(lines[i] ?? '')) {
      buf.push((lines[i] ?? '').trim());
      i++;
    }
    out.push(`<p>${inline(buf.join(' '))}</p>`);
  }
  return out.join('\n');
}

export function applyRepoUrl(html: string, repoUrl: string | null): string {
  if (!repoUrl) return html;
  const link = `<a href="${escapeHtml(repoUrl)}">${escapeHtml(repoUrl)}</a>`;
  return html.replaceAll('<mark class="placeholder">[REPO_URL]</mark>', link);
}

export { inline };
