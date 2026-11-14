#!/usr/bin/env python3
"""Read-only source inventory. Exports metadata, hashes and curated descriptions, never source/data contents."""
import ast
from collections import Counter
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
from zoneinfo import ZoneInfo

HERE = Path(__file__).resolve().parent
BASE = Path('~/Developer')
PRUNE = {'node_modules','vendor','build','dist','DerivedData','__pycache__','venv','env','out','exports','photos',
         'dumps','logs','Logs','running','done','failed','queue','human','verify','transcripts','backups',
         'data','fixtures','Fixtures','work-atlas'}
EXT = {'.swift','.py','.ts','.js','.mjs','.sh','.sql','.applescript','.html','.css','.rs','.go','.c','.m','.mm','.h'}
# Descriptions are modest summaries of the documented/observed purpose, not functional assertions.
REGISTRY = [
 ('ragnarok','Ragnarok','Systems','Layered personal AI workspace: apps, connectors, data, agents, runners and operations.'),
 ('ragnarok/app','Application layer','Apps','The macOS interfaces collected under Ragnarok.'),
 ('ragnarok/app/heimdall','Heimdall / Ragnarok app','Apps','A macOS workspace for AI activity, shell activity, project controls and task handoffs.'),
 ('ragnarok/app/heimdall/demos/hardware-proof','Proof Lab','AI assurance','A bounded rule-proposal demo with frozen checks, exportable receipts and hardware approval paths.'),
 ('ragnarok/app/belt-ui','Belt UI','Apps','Swift package and source tree for a conveyor-board interface.'),
 ('ragnarok/app/cli-tools','CLI Tools','Apps','A documented macOS pipeline for looking up, checking and explicitly running CLI commands.'),
 ('ragnarok/app/local-ai','LocalAI','Apps','A documented local macOS chat app using on-device MLX models.'),
 ('ragnarok/brain','Brain / advisor','AI assurance','Documented fix memory, topic cartridges and model-routing components.'),
 ('ragnarok/brain/fix-memory','Fix memory','AI assurance','A documented loop that proposes fixes in disposable test environments and records reusable results.'),
 ('ragnarok/brain/cartridges','Domain cartridges','AI assurance','Topic-rule JSON files. The brain README explicitly labels these rules Unverified.'),
 ('ragnarok/brain/lookup','Lookup','AI assurance','A Python lookup component; behavior has not been tested in this inventory.'),
 ('ragnarok/connector','Ragnarok connector','Data & MCP','A documented TypeScript MCP doorway to project data and change receipts.'),
 ('ragnarok/connector/ygg-business','Business MCP platform','Data & MCP','A documented business-data platform with receipts and hardware-gate claims that require independent validation.'),
 ('ragnarok/connector/platform-deployment','Platform deployment template','Data & MCP','A deployment-source variant of the business MCP platform.'),
 ('ragnarok/connector/bridges/muse','Muse bridge','Data & MCP','A documented local adapter between a model API and MCP tools.'),
 ('ragnarok/data','Data & receipt layer','Data & MCP','Database schemas and scripts for the shared data and receipt layer.'),
 ('ragnarok/runner','Task runner','AI assurance','Documented task execution, checking and human-approval components.'),
 ('ragnarok/runner/conveyor','Conveyor','AI assurance','Checklist-driven AI work with a separate verification and critique workflow, as documented.'),
 ('ragnarok/runner/ragnarok','Container belt','AI assurance','Container and model-door source files for the Ragnarok task runner.'),
 ('ragnarok/agents/alexus-core','Alexus Core','Agents','A documented model harness with routing, domain cartridges and verification components. Performance claims were not benchmarked.'),
 ('ragnarok/agents/doc-pipe','Document pipe','Agents','A documented document-intake workflow with extraction, consistency checks and human review.'),
 ('ragnarok/agents/iphone-agent','iPhone Commands','Agents','A documented portable command protocol and policy-aware iPhone-mirroring runner.'),
 ('ragnarok/agents/phone-grader','PhoneGrader','Apps','A documented phone assessment, pricing, listing and resale-tracking application.'),
 ('ragnarok/agents/upwork-alert','Upwork Alert','Agents','A documented mail-to-local-summary notification workflow.'),
 ('ragnarok/clients/kit','Client kit','Business workflows','A documented self-hosted client-data template with MCP access and receipts.'),
 ('ragnarok/clients/repair-shop','Repair-shop workflow','Business workflows','A documented inventory, repair and sales workflow with a synthetic demo shop.'),
 ('ragnarok/clients/phoenix-audio','Audio client configuration','Business workflows','A client-kit configuration. Client records and private settings were not opened or published.'),
 ('ragnarok/clients/verde-coffee','Coffee client configuration','Business workflows','A client-kit configuration. This inventory does not establish a commercial customer relationship.'),
 ('ragnarok/clients/ragnarok-hq','Ragnarok HQ configuration','Business workflows','A documented workspace configuration with switch/resume packet history.'),
 ('ragnarok/ops/alexus','Alexus setup scripts','Operations','Server setup and maintenance script inventory; no deployment scripts were run.'),
 ('ragnarok/ops/mac-scripts','Mac operations scripts','Operations','Mac maintenance and workflow scripts. Operational execution remains Unverified.'),
 ('ragnarok/ops/script-catalog','Script catalog','Operations','A documented extraction, redaction and provenance catalog for scripts.'),
 ('ragnarok/ops/tools','Operations tools','Operations','Documented history scanning, transcript-unpacking and machine-checking tools.'),
 ('greenlight','Greenlight','AI assurance','A documented staging-copy workflow that keeps an AI change only after build and test checks.'),
 ('convo-embeddings','Conversation search','Research','Documented local embedding and search scripts. Conversation contents and the index were not read.'),
 ('phone-grader-portfolio','PhoneGrader portfolio edition','Snapshots','A public-oriented PhoneGrader variant whose README specifies made-up sample prices.'),
 ('phone-grader-scrub','PhoneGrader scrub tools','Snapshots','A source-preparation folder with scrubbing and sample-data scripts; it is not a full app checkout.'),
 ('ragnarok-control-center','Control Center checkout','Snapshots','A separate Swift checkout related to the Ragnarok interface. Not treated as a second shipped product.'),
 ('ragnarok-public','Ragnarok public edition','Snapshots','A public-oriented Ragnarok checkout; documentation describes homelab-specific limitations.'),
 ('scripts','Host scripts','Operations','Documented maintenance, backup, notification and measurement scripts.'),
 ('WebDriverAgent','WebDriverAgent dependency','External dependency','An external automation source checkout. It is not presented as original Ragnarok work.'),
 ('ygg-scratch','Database split rehearsal','Research','A documented scratch database/migration rehearsal, explicitly separate from the live system.'),
 ('alexus','Alexus packages','Research','A local packages folder. Purpose beyond the visible folder structure is Unverified.'),
 ('app animation','App animation','Research','An empty folder at inventory time; no implementation was observed.'),
 ('build-chronicle','Build chronicle','Research','A directory of dated Markdown records. Their contents were not used as verification evidence.'),
 ('sigcut','Sigcut','Research','A media-oriented directory with tools and video files. Media and output behavior were not inspected.'),
]

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def source_files(root):
    result=[];truncated=False
    for directory,dirs,files in os.walk(root,followlinks=False):
        dirs[:]=sorted(d for d in dirs if not d.startswith('.') and d not in PRUNE and not (Path(directory)/d).is_symlink())
        for name in sorted(files):
            p=Path(directory)/name
            if not p.is_symlink() and not name.startswith('.') and p.suffix in EXT:
                result.append(p)
                if len(result)>=4000:return result,True
    return result,truncated

def document(root):
    for name in ['README.md','readme.md','README','Package.swift','package.json']:
        p=root/name
        if p.is_file() and not p.is_symlink():
            raw=p.read_bytes();lines=raw.decode(errors='replace').splitlines()
            return {'path':str(p.relative_to(BASE)),'sha256':hashlib.sha256(raw).hexdigest(),
                    'total_lines':len(lines),'inventory_scope':'Document metadata and checksum; description uses separately reviewed excerpts where available.'}
    return None

def build(output_path=None):
    top=[p for p in sorted(BASE.iterdir()) if not p.name.startswith('.')]
    aliases={}
    for p in top:
        if p.is_symlink() and p.resolve().is_relative_to(BASE):
            aliases.setdefault(str(p.resolve().relative_to(BASE)),[]).append(p.name)
    projects=[]
    for rel,title,category,description in REGISTRY:
        root=BASE/rel;files,capped=source_files(root)
        ext=Counter(p.suffix for p in files)
        selected=[p for p in files if p.suffix=='.py'][:8]
        syntax=[]
        for p in selected:
            item={'path':str(p.relative_to(BASE)),'sha256':sha(p),'check':'Python AST parse; source not executed'}
            try:ast.parse(p.read_text());item['result']='passed'
            except (SyntaxError,UnicodeError,ValueError):item['result']='failed'
            syntax.append(item)
        doc=document(root)
        projects.append({'id':re.sub('[^a-z0-9]+','-',rel.lower()).strip('-'),'title':title,'path':rel,
                         'category':category,'description':description,'location':'Mac','kind':'source',
                         'aliases':aliases.get(rel,[]),'source_files_observed':len(files),'source_count_capped':capped,
                         'languages':[{'extension':k,'files':v} for k,v in ext.most_common(5)],
                         'document':doc,'syntax_checks':syntax,'checks':[],
                         'runtime':'Unverified','status':'Source inventoried',
                         'limits':['Source presence and syntax are not proof of functional behavior.','No full-code or security audit was performed.'],
                         'next_proof':'Run a documented isolated functional check and record the exact source revision and result.'})
    # Non-project-looking entries remain accounted for, without publishing names or private contents.
    registered={Path(rel).parts[0] for rel,*_ in REGISTRY}
    coverage={'visible_top_level_entries':len(top),'top_level_directories':sum(p.is_dir() and not p.is_symlink() for p in top),
              'top_level_aliases':sum(p.is_symlink() for p in top),'top_level_regular_files':sum(p.is_file() and not p.is_symlink() for p in top),
              'hidden_entries_not_opened':sum(p.name.startswith('.') for p in BASE.iterdir()),
              'withheld_directory_count':sum(p.is_dir() and not p.is_symlink() and p.name not in registered for p in top),
              'loose_scripts':sum(p.suffix=='.sh' for p in top if p.is_file() and not p.is_symlink()),
              'archives_and_logs_not_opened':sum(p.suffix in ('.log','.tgz','.zip','.gz') for p in top if p.is_file() and not p.is_symlink()),
              'scope':'Visible entries of ~/Developer and selected Ragnarok subprojects. Aliases mapped; hidden paths, private records, raw logs, archives and dependency/build trees excluded from content review.',
              'server_archive':{'status':'Unverified','scope':'Read-only directory listings of home, backups, Developer and /mnt/seagate on Alexus.',
                                'finding':'/mnt/seagate listed zero entries. Backup folders and a dated developer snapshot were observed; archive location awaits confirmation.',
                                'contents_read':False}}
    if (HERE/'archive-observation.json').exists():coverage['server_archive']=json.loads((HERE/'archive-observation.json').read_text())
    recorded = json.loads((HERE/'check-results.json').read_text()) if (HERE/'check-results.json').exists() else {}
    for project in projects:
        for check in recorded.get(project['path'],[]):
            match=all((BASE/f['path']).is_file() and sha(BASE/f['path'])==f['sha256'] for f in check['files'])
            project['checks'].append(dict(check,source_matches=match,result=check['result'] if match else 'stale'))
        if any(c['result']=='passed' for c in project['checks']):project['status']='Selected checks passed'
        if project['path']=='greenlight':project['next_proof']='Run a real agent CLI on a disposable representative repository, then repeat setup on a clean machine.'
        if project['path']=='ragnarok/app/heimdall':project['next_proof']='Build the exact source snapshot and run its app self-test and UI checks. The Doctor fixture suite does not verify the rest of the app.'
        if project['path'].endswith('/demos/hardware-proof'):
            project['demo_url']='https://demo.rgnrk.co/'
            project['next_proof']='Complete an actual OpenAI API run with physical YubiKey and Enclave approvals, then verify the export against independently pinned keys.'
    archive_records=json.loads((HERE/'archive-projects.json').read_text()) if (HERE/'archive-projects.json').exists() else []
    for item in archive_records:
        if 'archive_path' not in item:continue
        projects.append({'id':'archive-'+re.sub('[^a-z0-9]+','-',item['name'].lower()).strip('-'),
                         'title':item['name']+' · archive','path':'Seagate/'+item['archive_path'],
                         'category':'Archive','location':'Alexus / Seagate','kind':'archive',
                         'description':'Historical package observed in the consolidation snapshot. Member headers were inventoried; purpose, runnability and equivalence to current code are Unverified.',
                         'aliases':[],'source_files_observed':item['source_members_observed'],
                         'source_count_capped':item['header_scan_capped'],'languages':[],
                         'document':None,'syntax_checks':[],'checks':[],'runtime':'Unverified','status':'Archive inventoried',
                         'archive_evidence':item,
                         'limits':['Member-header inventory only; no archived source was executed.','No private payload or original archive is published.','A named archive is not an additional shipped product.'],
                         'next_proof':'Review a chosen source subset, check its provenance and dependencies, then run a documented check in an isolated scratch environment.'})
    coverage['local_catalog_entries']=len(REGISTRY)
    coverage['archive_catalog_entries']=len(archive_records)
    coverage['verification_suites']=sum(len(p['checks']) for p in projects)
    coverage['verification_cases']=sum(c['cases'] for p in projects for c in p['checks'] if c['result']=='passed')
    data={'schema':'ragnarok-work-atlas:v1','captured_at':datetime.now(ZoneInfo('America/Los_Angeles')).isoformat(timespec='seconds'),
          'account':'yggdrasil','source_root':'~/Developer','coverage':coverage,'projects':projects,
          'verification_policy':{'tests':'Only freshly executed named checks receive a passed-check label.',
                                 'reported':'README/history statements are claims, not a fresh test.',
                                 'unverified':'Not executed, incomplete, unavailable or awaiting physical/external evidence.',
                                 'trust':'Checksums identify snapshots; this author-generated catalog is not an independent attestation.'}}
    origin=HERE.parent/'foundation-origin.json'
    if not origin.exists():origin=HERE/'foundation-origin.json'
    if origin.exists():data['main_project']=dict(json.loads(origin.read_text()),id='alexus-project',children=[p['id'] for p in projects if p['category'] in ['Systems','AI assurance','Data & MCP','Agents'] or p['path'] in ['ragnarok/app/heimdall','ragnarok/app/local-ai','ragnarok/app/belt-ui','ragnarok/app/cli-tools','ragnarok/ops/script-catalog']])
    target=Path(output_path) if output_path else HERE/'dist/catalog.json'
    target.write_text(json.dumps(data,indent=2)+'\n')
    print(json.dumps({'projects':len(projects),'coverage':coverage,'python_files_parsed':sum(len(p['syntax_checks']) for p in projects),
                      'python_parse_failures':sum(s['result']=='failed' for p in projects for s in p['syntax_checks'])},indent=2))
    return data

if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output')
    build(parser.parse_args().output)
