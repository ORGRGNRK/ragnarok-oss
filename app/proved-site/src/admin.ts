import type { KV } from './env';

export interface StoredIntake {
  key: string;
  raw: string;
}

export async function listIntakes(kv: KV): Promise<StoredIntake[]> {
  const names: string[] = [];
  let cursor: string | undefined;
  for (;;) {
    const page = await kv.list({ prefix: 'intake:', cursor });
    for (const key of page.keys) names.push(key.name);
    if (page.list_complete || !page.cursor) break;
    cursor = page.cursor;
  }
  names.sort().reverse();
  const rows: StoredIntake[] = [];
  for (const key of names) rows.push({ key, raw: (await kv.get(key)) ?? '' });
  return rows;
}
