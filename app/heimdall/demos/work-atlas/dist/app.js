const $=id=>document.getElementById(id);
let data,category='all',visibleLimit=12;
const element=(tag,text,cls)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(cls)e.className=cls;return e;};
const passed=p=>p.checks.some(c=>c.result==='passed');
const badge=p=>element('span',passed(p)?'Selected checks passed':p.kind==='archive'?'Archive · Unverified':!p.source_files_observed&&!p.document?'Folder inventoried':'Source inventoried','badge '+(passed(p)?'passed':p.kind==='archive'?'unknown':'source'));
const categories=['Systems','Apps','AI assurance','Data & MCP','Agents','Business workflows','Operations','Research','Snapshots','Archive','External dependency'];
const notes={'Apps':'Native interfaces and daily tools.','AI assurance':'Proposal, verification and human authority.','Data & MCP':'Structured access, change history and adapters.','Agents':'Bounded tasks and workflow automation.','Business workflows':'Operational templates and vertical experiments.','Operations':'Maintenance, recovery and provenance.','Research':'Experiments, partial folders and early work.','Snapshots':'Related editions and separate checkouts.','External dependency':'Dependencies, credited as external work.'};
function filters(reset=true){
  if(reset)visibleLimit=12;
  const term=$('search').value.toLowerCase(),state=$('status').value;
  const list=data.projects.filter(p=>(category==='all'||p.category===category)&&[p.title,p.path,p.description,...p.aliases].join(' ').toLowerCase().includes(term)&&(state==='all'||state==='unverified'&&p.runtime==='Unverified'||state==='passed'&&passed(p)||state==='source'&&!passed(p)));
  $('project-list').replaceChildren();$('count').textContent=`Showing ${Math.min(visibleLimit,list.length)} of ${list.length} matches · ${data.projects.length} total`;$('empty').hidden=!!list.length;$('more').hidden=list.length<=visibleLimit;
  for(const p of list.slice(0,visibleLimit)){
    const a=element('a',undefined,'project');a.href='#/project/'+p.id;
    const top=element('div',undefined,'card-top');top.append(element('span',p.category,'small'),element('span','↗','arrow'));
    a.append(top,element('h3',p.title),element('p',p.description),badge(p));
    const bottom=element('div',undefined,'card-bottom');bottom.append(element('code',p.path),element('span','Runtime: Unverified','small'));a.append(bottom);$('project-list').append(a);
  }
  for(const b of $('branches').children)b.classList.toggle('selected',b.dataset.category===category);
}
function row(label,value){const d=element('div',undefined,'fact');d.append(element('dt',label),element('dd',value));return d;}
function alexus(){
  const p=data.main_project;$('home').hidden=true;$('detail').hidden=false;const root=$('detail');root.replaceChildren();
  const back=element('a','← All work','text-link');back.href='#projects';root.append(back,element('div',p.foundation_title,'eyebrow'),element('h1',p.project_title),element('blockquote',p.quote,'origin-quote'),element('p',p.attribution,'small'),element('p','AI systems, agent processes, model interfaces, data connectors and verification work belong to this main project.','lead'));
  const section=element('section',undefined,'detail-section');section.append(element('h2','Branches of ALEXUS'));
  for(const id of p.children){const project=data.projects.find(x=>x.id===id);if(!project)continue;const a=element('a',project.title+' ↗','related');a.href='#/project/'+id;section.append(a);}
  root.append(section,element('p',p.source_scope,'small'));window.scrollTo(0,0);
}
function detail(p){
  $('home').hidden=true;$('detail').hidden=false;const root=$('detail');root.replaceChildren();
  const back=element('a','← Back to the atlas','text-link');back.href='#projects';
  const intro=element('div',undefined,'detail-intro');intro.append(element('div',p.category.toUpperCase(),'eyebrow'),element('h1',p.title),element('p',p.description,'lead'),badge(p));
  const facts=element('dl',undefined,'facts');facts.append(row('Source',p.path),row('Location',p.location),row('Aliases',p.aliases.join(', ')||'None recorded'),row('Source files observed',p.source_files_observed+(p.source_count_capped?' (scan capped)':'')),row('Runtime behavior',p.runtime),row('Languages by extension',p.languages.map(l=>l.extension+' · '+l.files).join(' / ')||'No source extensions in scan'));
  root.append(back,intro,facts);
  if(p.demo_url){const link=element('a','Open Proof Lab ↗','cta');link.href=p.demo_url;root.append(link);}
  const checks=element('section',undefined,'detail-section');checks.append(element('div','OBSERVED VERIFICATION','eyebrow'),element('h2',p.checks.length?'Checks with a defined boundary.':'Functional verification is still open.'));
  if(!p.checks.length)checks.append(element('p','No functional suite was executed for this entry during this inventory. README results and historical claims are not promoted to a fresh pass.'));
  for(const c of p.checks){const article=element('article',undefined,'check');article.append(element('span',c.result.toUpperCase(),'badge '+(c.result==='passed'?'passed':'unknown')),element('h3',c.name),element('p',c.cases+' cases · '+c.checked_at),element('code',c.command,'command'),element('p',c.scope));
    const details=element('details');details.append(element('summary','Recorded source checksums'));for(const f of c.files){const item=element('p',f.path);item.append(element('code',f.sha256,'hash'));details.append(item);}article.append(details);checks.append(article);}
  const syntax=element('p',p.syntax_checks.length?`${p.syntax_checks.filter(s=>s.result==='passed').length} / ${p.syntax_checks.length} selected Python files parsed without execution. Syntax checks do not establish behavior.`:'No Python syntax sample was available or selected for this entry.','small');checks.append(syntax);root.append(checks);
  const docs=element('section',undefined,'detail-section');docs.append(element('div','SOURCE & LIMITATIONS','eyebrow'),element('h2','What this entry is based on.'));
  if(p.archive_evidence){docs.append(element('p',p.archive_evidence.headers_inspected+' archive headers inspected · '+p.archive_evidence.bytes+' bytes in package. No payload extracted or executed.'));for(const d of p.archive_evidence.readme_metadata)docs.append(element('p','README header observed: '+d.path+' ('+d.bytes+' bytes). Contents not read.'));}
  else if(p.document){docs.append(element('p',p.document.path+' · '+p.document.total_lines+' lines total'),element('p',p.document.inventory_scope),element('code',p.document.sha256,'hash'));}else docs.append(element('p','No immediate README or package manifest was found. This entry is based on the directory inventory only.'));
  const ul=element('ul');for(const limit of p.limits)ul.append(element('li',limit));ul.append(element('li','Runtime, deployment and performance remain Unverified. Descriptions reflect documented or structural purpose.'));docs.append(ul,element('h3','The next useful proof'),element('p',p.next_proof));root.append(docs);
  const children=data.projects.filter(q=>q.id!==p.id&&q.path.startsWith(p.path+'/'));
  if(children.length){const sec=element('section',undefined,'detail-section');sec.append(element('div','BRANCHES FROM HERE','eyebrow'));for(const q of children){const a=element('a',q.title+' ↗','related');a.href='#/project/'+q.id;sec.append(a);}root.append(sec);}
  root.append(element('p','This is an author-generated local observation record, not a third-party attestation. Confirm the checks against the source snapshot before relying on them.','small'));window.scrollTo(0,0);
}
function route(){
  if(location.hash==='#/alexus'&&data.main_project){alexus();return;}
  const prefix='#/project/';if(location.hash.startsWith(prefix)){const p=data.projects.find(p=>p.id===location.hash.slice(prefix.length));if(p){detail(p);return;}}
  $('home').hidden=false;$('detail').hidden=true;filters();if(['#projects','#coverage','#origin'].includes(location.hash))requestAnimationFrame(()=>$((location.hash.slice(1))).scrollIntoView());
}
try{
  const response=await fetch(location.protocol==='https:'?'/api/catalog':'catalog.json',{cache:'no-store'});if(!response.ok)throw Error('Inventory could not be loaded.');data=await response.json();
  if(data.main_project){const p=data.main_project;$('main-title').textContent=p.project_title;$('foundation-title').textContent=p.foundation_title;$('main-quote').textContent=p.quote;$('main-attribution').textContent=p.attribution;$('origin-quote').textContent=p.origin_quote;$('origin-source').textContent=p.source_scope;$('origin-theory').replaceChildren(...p.theory.map(t=>element('p',t)));}
  $('total').textContent=data.projects.length;$('suites').textContent=data.coverage.verification_suites;$('cases').textContent=data.coverage.verification_cases;
  const date=new Intl.DateTimeFormat('en-US',{dateStyle:'medium',timeStyle:'short',timeZone:'America/Los_Angeles'}).format(new Date(data.captured_at));$('snapshot').textContent=date+' · Pacific';$('footer-date').textContent='Snapshot: '+date;
  for(const cat of categories){const n=data.projects.filter(p=>p.category===cat).length;if(!n)continue;
    const b=element('button',undefined,'branch');b.dataset.category=cat;b.append(element('span',String(n).padStart(2,'0'),'branch-count'),element('h3',cat),element('p',notes[cat]||(cat==='Archive'?'Historical packages, independently labeled.':'The architecture that connects the work.')),element('span','Explore branch ↗','small'));b.onclick=()=>{category=cat;$('category').value=cat;filters();location.hash='projects';$('projects').scrollIntoView();};$('branches').append(b);
    const o=element('option',cat);o.value=cat;$('category').append(o);
  }
  $('scope').textContent=data.coverage.scope;
  for(const [n,label]of[[data.coverage.visible_top_level_entries,'visible top-level entries'],[data.coverage.top_level_aliases,'shortcuts mapped'],[data.coverage.withheld_directory_count,'private / data folders withheld'],[data.coverage.archives_and_logs_not_opened,'archive / log files not opened']]){const c=element('div');c.append(element('b',n),element('span',label));$('coverage-stats').append(c);}
  $('archive-finding').textContent=data.coverage.server_archive.finding;$('archive-scope').textContent=data.coverage.server_archive.scope;$('archive-status').textContent=data.coverage.server_archive.status.toUpperCase();
  $('search').oninput=()=>filters();$('category').onchange=()=>{category=$('category').value;filters();};$('status').onchange=()=>filters();$('more').onclick=()=>{visibleLimit+=12;filters(false);};window.addEventListener('hashchange',route);route();
}catch(e){$('error').hidden=false;$('error').textContent=e.message;}

// Independent sync observations never promote a project's runtime verification.
if(location.protocol==='https:'){
 try{const response=await fetch('/api/sync/status',{cache:'no-store'});if(response.ok){
 const status=await response.json(),target=$('sync-observation');
 if(target){target.replaceChildren(element('div','SYNC OBSERVATIONS','eyebrow'));
 for(const [host,value] of Object.entries(status.hosts)){target.append(element('p',value.counts?`${host.toUpperCase()} · ${value.observed_at} · ${value.counts.current} current / ${value.counts.held} held · ${value.status}`:`${host.toUpperCase()} · Unverified · no heartbeat`,'small'));}
 target.append(element('p','A sync heartbeat records repository state. Product runtime remains Unverified.','small'));}
 }}catch{}
}
