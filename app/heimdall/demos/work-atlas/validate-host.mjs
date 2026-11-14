import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const source=await readFile(new URL('./dist/server/index.js',import.meta.url),'utf8');
const manifest=JSON.parse(await readFile(new URL('./dist/.openai/hosting.json',import.meta.url),'utf8'));
assert.equal(manifest.r2,'BUCKET');assert(!manifest.static);
const module=await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
assert.equal(typeof module.default.fetch,'function');
console.log('Valid single-file Worker and BUCKET binding.');
