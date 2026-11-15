import raw from './plan-text';

export interface Task {
  id: string;
  text: string;
}
export interface RhythmItem {
  id: string;
  label: string;
  detail: string;
  text: string;
}
export interface Week {
  title: string;
  tasks: Task[];
}
export interface Plan {
  title: string;
  intro: string;
  rhythm: RhythmItem[];
  numbers: string[];
  weeks: Week[];
}

const ITEM = /^-\s+([a-z0-9_-]+):\s+(.+)$/i;

/** Parse plan-content.md into weeks of day tasks, rhythm items and number fields. */
export function parsePlan(md: string): Plan {
  const lines = md.replace(/\r\n/g, '\n').split('\n');
  const plan: Plan = { title: '', intro: '', rhythm: [], numbers: [], weeks: [] };
  const intro: string[] = [];
  let section: 'intro' | 'rhythm' | 'numbers' | 'week' | 'other' = 'intro';
  let week: Week | null = null;

  for (const line of lines) {
    const t = line.trim();
    if (t.startsWith('# ')) {
      plan.title = t.slice(2).trim();
      continue;
    }
    if (t.startsWith('## ')) {
      const heading = t.slice(3).trim();
      week = null;
      if (/^daily rhythm/i.test(heading)) section = 'rhythm';
      else if (/^daily numbers/i.test(heading)) section = 'numbers';
      else if (/^week\s+\d+/i.test(heading)) {
        section = 'week';
        week = { title: heading, tasks: [] };
        plan.weeks.push(week);
      } else section = 'other';
      continue;
    }
    if (!t) continue;
    if (section === 'intro') {
      intro.push(t);
      continue;
    }
    if (section === 'numbers') {
      for (const n of t.split(',')) {
        const name = n.trim().toLowerCase();
        if (/^[a-z][a-z0-9_]*$/.test(name)) plan.numbers.push(name);
      }
      continue;
    }
    const m = ITEM.exec(t);
    if (!m) continue;
    const id = m[1]!.toLowerCase();
    const text = m[2]!.trim();
    if (section === 'rhythm') {
      const [label, ...rest] = text.split(' — ');
      plan.rhythm.push({ id, label: label!.trim(), detail: rest.join(' — ').trim(), text });
    } else if (section === 'week' && week) {
      week.tasks.push({ id, text });
    }
  }
  plan.intro = intro.join(' ');
  return plan;
}

export const PLAN: Plan = parsePlan(raw);
export const TASK_IDS = new Set(PLAN.weeks.flatMap((w) => w.tasks.map((t) => t.id)));
export const RHYTHM_IDS = new Set(PLAN.rhythm.map((r) => r.id));
export const NUMBER_KEYS = new Set(PLAN.numbers);
