export interface Section {
  title: string;
  body: string;
}

export interface Tier {
  id: string;
  name: string;
  price: string;
  detail: string;
}

export interface Copy {
  title: string;
  sections: Section[];
}

export const SECTION_TITLES = [
  'Hero',
  'What you get',
  'How it works',
  'Onboarding',
  'Pricing',
  'Sample proof report',
  'Open source',
  'FAQ',
] as const;

export type SectionTitle = (typeof SECTION_TITLES)[number];

export const SECTION_IDS: Record<SectionTitle, string> = {
  Hero: 'hero',
  'What you get': 'offer',
  'How it works': 'how-it-works',
  Onboarding: 'onboarding',
  Pricing: 'pricing',
  'Sample proof report': 'sample-proof-report',
  'Open source': 'open-source',
  FAQ: 'faq',
};

/** First word of the tier name, uppercased. "Intro job" → INTRO, env PAY_URL_INTRO. */
export function tierId(name: string): string {
  const word = name.trim().split(/\s+/)[0] ?? '';
  return word.toUpperCase().replace(/[^A-Z0-9]/g, '');
}

const PRICE_SEP = ' — ';

export function parsePricing(body: string): { tiers: Tier[]; notes: string } {
  const tiers: Tier[] = [];
  const notes: string[] = [];
  for (const line of body.split('\n')) {
    const trimmed = line.trim();
    if (trimmed.startsWith('- ')) {
      const parts = trimmed.slice(2).split(PRICE_SEP);
      const price = parts[1]?.trim() ?? '';
      if (parts.length >= 3 && price.includes('[PRICE:')) {
        const name = parts[0]!.trim();
        const id = tierId(name);
        if (!id) throw new Error(`Pricing tier has no id: ${name}`);
        tiers.push({
          id,
          name,
          price,
          detail: parts.slice(2).join(PRICE_SEP).trim(),
        });
        continue;
      }
    }
    notes.push(line);
  }
  return { tiers, notes: notes.join('\n').trim() };
}

export function parseCopy(md: string): Copy {
  const lines = md.replace(/\r\n/g, '\n').split('\n');
  let title = '';
  const sections: Section[] = [];
  let current: Section | null = null;
  const buf: string[] = [];
  const flush = () => {
    if (!current) return;
    current.body = buf.join('\n').trim();
    buf.length = 0;
  };
  for (const line of lines) {
    if (line.startsWith('# ')) {
      title = line.slice(2).trim();
      continue;
    }
    if (line.startsWith('## ')) {
      flush();
      current = { title: line.slice(3).trim(), body: '' };
      sections.push(current);
      continue;
    }
    if (current) buf.push(line);
  }
  flush();
  const titles = sections.map((s) => s.title);
  if (titles.join('\n') !== SECTION_TITLES.join('\n')) {
    throw new Error(`copy.md sections must be: ${SECTION_TITLES.join(', ')}`);
  }
  if (!title) throw new Error('copy.md needs an H1 title');
  return { title, sections };
}

export function sectionByTitle(copy: Copy, title: SectionTitle): Section {
  const found = copy.sections.find((s) => s.title === title);
  if (!found) throw new Error(`missing section ${title}`);
  return found;
}
