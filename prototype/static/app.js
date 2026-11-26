const $ = id => document.getElementById(id);
const el = (tag, text, cls) => { const n = document.createElement(tag); if (text != null) n.textContent = ['p','li'].includes(tag) ? String(text).replace(/\*\*([^*]+)\*\*/g,'$1').replace(/\*([^*\n]+)\*/g,'$1') : text; if (cls) n.className = cls; return n; };
let csrf, library = [], history = [], active = null, selectedFeedback = null;
const scopeNotes = {
  unread: 'Nouveaux titres et pile À lire. Tes lectures commencées sont exclues.',
  discovery: 'Toute ta bibliothèque est exclue, y compris les titres prévus dans ta pile À lire.',
  backlog: 'Seulement les œuvres marquées À lire dans MangaTime.',
  resume: 'Seulement les lectures En cours ou En pause. Les abandons sont exclus.'
};
async function api(path, body) {
  const options = body === undefined ? {} : {method: 'POST', headers: {'Content-Type': 'application/json', 'X-Reco-Token': csrf}, body: JSON.stringify(body)};
  const response = await fetch(path, options);
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'Le serveur ne répond pas.');
  return data;
}
function showError(message) { $('error').textContent = message; $('error').hidden = !message; }
function view(name) {
  document.querySelectorAll('.view').forEach(n => {n.hidden = n.id !== name;});
  document.querySelectorAll('.nav').forEach(n => n.classList.toggle('active', n.dataset.view === name));
  if (name === 'library') renderLibrary();
  if (name === 'history') loadHistory().catch(e => showError(e.message));
}
document.querySelectorAll('[data-view]').forEach(n => n.addEventListener('click', () => view(n.dataset.view)));
document.querySelectorAll('[data-prompt]').forEach(n => n.addEventListener('click', () => {$('prompt').value = n.dataset.prompt; $('prompt').focus();}));
$('scope').addEventListener('change', () => {$('scopeNote').textContent = scopeNotes[$('scope').value];});
$('adviceForm').addEventListener('submit', async event => {
  event.preventDefault(); showError('');
  try {
    $('submit').disabled = true;
    const job = await api('/api/advise', {prompt: $('prompt').value, scope: $('scope').value,count:Number($('count').value),mode:$('mode').value,filters:['finished','long'].filter(id=>$(id).checked)});
    $('result').replaceChildren(); $('emptyState').hidden = true;
    active = job.id;
    poll(job.id);
  } catch (error) {showError(error.message); $('submit').disabled = false;}
});
$('cancel').addEventListener('click', async () => {
  if (!active) return;
  try {await api('/api/cancel', {id: active}); $('cancel').disabled = true; $('step').textContent = 'Annulation demandée'; $('elapsed').textContent = 'L’appel API en cours peut encore se terminer et être facturé.';}
  catch (error) {showError(error.message);}
});
async function poll(id) {
  $('progress').hidden = false; $('submit').disabled = true;
  try {
    const job = await api('/api/jobs/' + id);
    const elapsed = Math.round(Date.now()/1000 - job.created);
    if (!$('cancel').disabled) $('step').textContent = job.step;
    $('elapsed').textContent = `${elapsed} s · ${cost(job.cost_usd)} estimé · ${job.input_tokens.toLocaleString('fr-FR')} jetons d’entrée`;
    if (job.status === 'running') {setTimeout(() => poll(id), 1500); return;}
    active = null; $('progress').hidden = true; $('submit').disabled = false; $('cancel').disabled = false;
    if (job.status === 'done') renderResult(job);
    else if (job.status === 'error') showError(job.error);
    else showError('Recherche annulée. Les appels déjà effectués restent comptabilisés.');
  } catch (error) {
    $('progress').hidden = true; $('submit').disabled = false; active = null;
    showError('Connexion interrompue : ' + error.message + ' Recharge la page pour retrouver une recherche encore active.');
  }
}
function cost(value) {return new Intl.NumberFormat('fr-FR', {style: 'currency', currency: 'USD', minimumFractionDigits: 3, maximumFractionDigits: 3}).format(value || 0);}
function link(url, label) {
  const a = el('a', label);
  try {const parsed = new URL(url); if (parsed.protocol === 'https:') a.href = parsed.href;} catch (_) {}
  a.target = '_blank'; a.rel = 'noopener noreferrer'; return a;
}
function details(title, contents) {const d=el('details'); d.append(el('summary',title), contents); return d;}
function renderResult(job) {
  $('result').replaceChildren(); $('emptyState').hidden = true;
  $('result').append(el('p','Périmètre de cet essai : '+scopeNotes[job.scope],'scope-note'));
  const result = job.result;
  if (Array.isArray(result.recommendations) && result.status === 'recommendation') {
    const heading=el('section',null,'selection-heading');
    const total=result.recommendations.length;
    heading.append(el('h2',total===1?'Ta proposition':`Tes ${total} propositions`),el('p',result.message));
    const list=el('ol',null,'selection-list');
    result.recommendations.forEach((recommendation,index)=>{
      const item=el('li'), a=el('a',recommendation.work.title+(recommendation.fit==='exploratory'?' · piste exploratoire':''));a.href='#proposal-'+(index+1);item.append(a);list.append(item);
    });heading.append(list);
    if(result.reservations.length)heading.append(el('p',result.reservations.join(' '),'hint'));
    $('result').append(heading);
    result.recommendations.forEach((recommendation,index)=>renderCard({...job,result:{...recommendation,status:'recommendation',contract:result.contract,trace:[]}},index+1,total));
    $('result').append(renderResearch(job));
    return;
  }
  renderCard({...job,result:{why_this:'',personal_basis:[],checks:[],evidence:[],...result}});
}
async function showCover(slot, work) {
  for (const catalogue of ['mangaupdates','anilist','mangadex']) {
    for (const source of work.sources.filter(s=>s.catalogue===catalogue)) {
      try {
        const {url} = await api('/api/cover/'+encodeURIComponent(source.id));
        if (!url) continue;
        const img = new Image();
        img.alt = 'Couverture de '+work.title;
        img.referrerPolicy = 'no-referrer';
        img.src = url;
        await img.decode();
        const anchor = link(source.url, '');
        anchor.title = 'Fiche de la couverture · '+catalogue;
        anchor.append(img);
        slot.append(anchor);
        return;
      } catch { /* Essayer la prochaine fiche identifiée pour cette œuvre. */ }
    }
  }
}
function renderCard(job, rank=null, total=null) {
  const result = job.result;
  const card=el('article',null,'result-card'), body=el('div',null,'result-main');
  if(rank)card.id='proposal-'+rank;
  body.append(el('span', rank ? `PROPOSITION ${rank} SUR ${total || 5}` : result.status === 'recommendation' ? 'ANCIEN CONSEIL · UNE LECTURE' : 'PRÉCISONS LA SÉLECTION', 'result-label'));
  if(result.fit==='exploratory'){
    const exploration=el('div',null,'reservations exploration');exploration.append(el('strong','Piste exploratoire · à confirmer'),el('p',result.exploration_reason));body.append(exploration);
  }else if(result.fit==='strong'){body.append(el('span','Choix étayé par les fiches','badge'));}
  if (result.work) {
    const slot=el('div',null,'book-cover');
    body.append(slot);
    showCover(slot,result.work);
  }
  body.append(el('h2', result.work?.title || (result.status === 'clarification' ? 'Une précision avant de choisir.' : 'Pas encore de conseil assez solide.')));
  body.append(el('p',result.message,'lead'));
  if (result.work) {
    const metadata=el('div',null,'metadata');
    if (result.work.library) metadata.append(el('span',result.work.library.statut,'badge'));
    const countries=[...new Set(result.work.sources.map(s=>s.fields.country).filter(s=>s!=='UNKNOWN'))];
    countries.forEach(c=>metadata.append(el('span',({KR:'Corée',JP:'Japon',CN:'Chine',EN:'Anglophone'})[c] || c,'badge')));
    body.append(metadata);
  }
  body.append(el('p',result.why_this));
  if(result.setting_assessment && result.setting_assessment.match!=='not_requested'){
    const setting=el('div',null,'setting-assessment');setting.append(el('h3','L’univers de cette œuvre'),el('p',result.setting_assessment.observed_world),el('p',result.setting_assessment.explanation,'hint'));
    if(result.setting_assessment.match!=='aligned')setting.append(el('strong',result.setting_assessment.match==='different'?'Un décor adjacent à ta demande':'Le décor reste à confirmer'));
    body.append(setting);
  }
  if (result.personal_basis.length) {
    body.append(el('h3','Pourquoi ça pourrait te plaire'));
    result.personal_basis.forEach((basis,i)=>{
      const reference=result.references?.[i]; const row=el('div',null,'reference');
      row.append(el('strong',reference?.title || basis.library_id));
      if (reference) row.append(el('small',`${reference.library.note}/5 · ${reference.library.statut}${reference.library.note_privee ? ' · '+reference.library.note_privee : ''}`));
      row.append(el('p',basis.explanation)); body.append(row);
    });
  }
  if (result.checks.length) {
    body.append(el('h3','Face à ta demande'));
    const checks=el('ul',null,'checks');
    result.checks.forEach(check=>{
      const constraint=result.contract?.constraints.find(c=>c.id===check.constraint_id);
      const item=el('li',null,'check '+check.verdict);
      item.append(el('small',constraint?.kind === 'library_scope' ? 'Contrôle de ta bibliothèque' : ({supported:'Étayé par la fiche',uncertain:'À confirmer',violated:'Ne correspond pas'})[check.verdict]));
      item.append(el('strong',constraint?.description || check.constraint_id));
      item.append(el('p',check.explanation)); checks.append(item);
    }); body.append(checks);
  }
  if (result.reservations.length) {
    const note=el('div',null,'reservations'); note.append(el('strong','À garder en tête'));
    const ul=el('ul');result.reservations.forEach(x=>ul.append(el('li',x)));note.append(ul);body.append(note);
  }
  if (result.work) {
    const links=el('div',null,'sources');
    result.work.sources.forEach(s=>links.append(link(s.url,({anilist:'AniList',mangadex:'MangaDex',mangaupdates:'MangaUpdates',publication:'Publication officielle'})[s.catalogue] || s.catalogue)));
    body.append(el('h3','Les fiches utilisées'),links);
    const proofs=el('div'); const seen=new Set();
    [...result.evidence,...result.checks.flatMap(c=>c.evidence),...(result.setting_assessment?.evidence || [])].forEach(e=>{
      const key=JSON.stringify(e);if(seen.has(key))return;seen.add(key);
      const source=result.work.sources.find(s=>s.id===e.source_id);const p=el('div',null,'proof');
      p.append(el('small',(source?.catalogue || e.source_id)+' · '+e.field),el('q',e.quote));proofs.append(p);
    });
    body.append(details('Voir les éléments de preuve',proofs));
  }
  if(!rank)body.append(renderResearch(job));
  card.append(body);
  if (result.work) card.append(feedbackForm(job));
  $('result').append(card);
}
function renderResearch(job) {
  const result=job.result, container=el('div',null,'selection-research'), trace=el('div');
  result.trace.forEach(t=>{const item=el('div',null,'trace-item');item.append(el('strong',(t.ok?'':'Échec · ')+t.label));item.append(el('small',t.error || JSON.stringify(t.arguments)));trace.append(item);});
  if (result.contract) {const request=el('div',null,'trace-item');request.append(el('strong','Demande retenue'),el('p',result.contract.description || result.contract.summary || job.prompt));trace.prepend(request);}
  if(result.enrichment_reports?.length){
    const research=el('div');result.enrichment_reports.forEach(report=>{
      const entry=el('div',null,'trace-item');entry.append(el('strong',report.reason));
      report.attempts.forEach(a=>entry.append(el('p',`${a.source} · ${a.title} : ${a.error || a.results+' résultat(s)'}`)));
      entry.append(el('p',report.quality.has_synopsis?'Un synopsis a été trouvé.':'Toujours aucun synopsis confirmé.'));research.append(entry);
    });container.append(details('Sources complémentaires recherchées',research));
  }
  container.append(details(`Voir la recherche (${result.trace.length} étapes)`,trace));
  container.append(el('p',`${cost(job.cost_usd)} estimé pour toute la sélection · ${job.input_tokens.toLocaleString('fr-FR')} jetons d’entrée / ${job.output_tokens.toLocaleString('fr-FR')} de sortie · ${Math.round(job.duration_seconds || 0)} s. Estimation au tarif standard, hors remises de cache.`, 'cost'));
  return container;
}
function feedbackForm(job) {
  const box=el('form',null,'feedback');box.append(el('p','Est-ce que ce conseil tombe juste ?'));
  const buttons=el('div',null,'feedback-buttons');let selected=null;
  [['interested','Ça me tente'],['off_topic','Hors sujet'],['already_read','Déjà lu'],['not_today','Pas aujourd’hui']].forEach(([kind,label])=>{
    const button=el('button',label);button.type='button';button.addEventListener('click',()=>{selected=kind;buttons.querySelectorAll('button').forEach(b=>b.classList.toggle('selected',b===button));comment.hidden=false;save.hidden=false;comment.focus();});buttons.append(button);
  });box.append(buttons);
  const comment=el('input');comment.placeholder='Pourquoi ? Un détail suffit (facultatif).';comment.maxLength=2000;comment.setAttribute('aria-label','Précision sur ton retour');comment.hidden=true;
  const save=el('button','Enregistrer mon retour','save');save.type='submit';save.hidden=true;
  const status=el('p');status.setAttribute('role','status');box.append(comment,save,status);
  box.addEventListener('submit',async event=>{event.preventDefault();if(!selected)return;save.disabled=true;try{await api('/api/feedback',{run_id:job.id,candidate_id:job.result.candidate_id,kind:selected,comment:comment.value});status.textContent='Retour enregistré sur cet ordinateur. Il sera pris en compte à la prochaine recherche.';save.hidden=true;comment.hidden=true;buttons.querySelectorAll('button').forEach(b=>b.disabled=true);}catch(e){status.textContent=e.message;save.disabled=false;}});
  return box;
}
async function renderLibrary() {
  if (!library.length) library=await api('/api/library');
  const search=$('librarySearch').value.toLocaleLowerCase('fr');const status=$('libraryStatus').value;
  const shown=library.filter(w=>(!status || w.library.statut===status) && (!search || JSON.stringify(w).toLocaleLowerCase('fr').includes(search)));
  $('libraryItems').replaceChildren();$('librarySummary').textContent=`${shown.length} œuvres affichées · Les titres alternatifs et fiches proviennent de l’audit corrigé.`;
  shown.forEach(w=>{
    const row=el('article',null,'library-row'), info=el('div');info.append(el('strong',w.title),el('small',`${w.library.statut} · ${w.library.type || 'Origine non renseignée'} · ${w.sources.length} fiches`));
    if(w.library.note_privee)info.append(el('p',w.library.note_privee));
    const links=el('div');w.sources.forEach(s=>{const entry=el('div',null,'proof');entry.append(link(s.url,s.catalogue),el('p',s.fields.aliases));links.append(entry);});info.append(details('Fiches et titres alternatifs',links));
    const rating=el('span',w.library.note==null?'Non noté':`${w.library.note} / 5`,'rating');row.append(info,rating);$('libraryItems').append(row);
  });
}
$('librarySearch').addEventListener('input',()=>renderLibrary().catch(e=>showError(e.message)));
$('libraryStatus').addEventListener('change',()=>renderLibrary().catch(e=>showError(e.message)));
async function loadHistory() {
  history=await api('/api/history');$('historyItems').replaceChildren();
  if (!history.length) {$('historyItems').append(el('p','Tes premiers essais apparaîtront ici.'));return;}
  history.forEach(job=>{
    const selection=job.result?.recommendations;
    const title=selection?.length ? `${selection.length} propositions · ${selection.map(r=>r.work.title).join(' · ')}` : job.result?.work?.title || job.error || job.step;
    const row=el('article',null,'history-row');row.append(el('strong',job.prompt));row.append(el('p',`${title} · ${cost(job.cost_usd)} estimé`));
    if(job.result){const button=el('button','Revoir le conseil','quiet');button.addEventListener('click',()=>{view('advisor');renderResult(job);$('prompt').value=job.prompt;$('result').scrollIntoView({behavior:'smooth',block:'start'});});row.append(button);}
    $('historyItems').append(row);
  });
}
(async()=>{
  try {const data=await api('/api/bootstrap');csrf=data.csrf;$('modelName').textContent=data.model;$('navCount').textContent=data.profile.total;$('libraryStat').textContent=`${data.profile.total} lectures, pas un profil figé.`;$('auditDate').textContent='Audit : '+data.audit_date;
    if(data.active_job){active=data.active_job.id;$('prompt').value=data.active_job.prompt;$('scope').value=data.active_job.scope;$('scopeNote').textContent=scopeNotes[data.active_job.scope];$('emptyState').hidden=true;poll(active);}
  }catch(error){showError('Démarrage impossible : '+error.message);$('submit').disabled=true;}
})();
