import Foundation

/// Progressive enhancement: without script the existing details and forms remain usable.
enum PublisherFleet {
    static func icon(_ identifier: String?) -> String {
        let id = identifier?.lowercased().replacingOccurrences(of: " ", with: "") ?? ""
        let drawing: String
        if id.hasPrefix("imac") {
            drawing = "<rect x=3 y=3 width=26 height=19 rx='2'/><path d='M3 18h26M16 22v6m-6 0h12'/>"
        } else if id.hasPrefix("macbook") {
            drawing = "<rect x=6 y=4 width=20 height=17 rx='2'/><path d='M6 21 2 27h28l-4-6M12 25h8'/>"
        } else if id.hasPrefix("macmini") {
            drawing = "<rect x=3 y=9 width=26 height=16 rx='4'/><path d='M4 20h24m-6 2h2'/>"
        } else if id.hasPrefix("macstudio") {
            drawing = "<rect x=5 y=5 width=22 height=23 rx='4'/><path d='M6 20h20m-15 4h3m3 0h3'/>"
        } else if id.hasPrefix("macpro") {
            drawing = "<rect x=9 y=3 width=15 height=26 rx='2'/><path d='M12 3V1m9 2V1M12 9h9m-9 5h9m-9 5h9m-9 5h9'/>"
        } else {
            drawing = "<rect x=3 y=4 width=26 height=20 rx='2'/><path d='M16 24v4m-6 0h12'/>"
        }
        return "<svg class=deviceicon viewBox='0 0 32 32' fill=none stroke=currentColor stroke-width=1.5 stroke-linecap=round stroke-linejoin=round aria-hidden=true>\(drawing)</svg>"
    }

    static let script = #"""
    function bindFleet(){
      var list=document.querySelector('.maclist'),search=document.getElementById('filter');document.querySelector('.tools').hidden=false;if(!list||!search)return;
      var rows=Array.from(list.querySelectorAll('details.mac')),page=Math.max(1,Number(S.getItem('khu-page'))||1);
      var site=document.getElementById('site-filter'),tag=document.getElementById('tag-filter'),group=document.getElementById('group-by'),size=document.getElementById('page-size');
      function tags(row){try{return JSON.parse(row.dataset.tags||'[]')}catch(e){return []}}
      function options(select,values,key){values.forEach(function(value){var o=document.createElement('option');o.value=value;o.textContent=value;select.appendChild(o)});select.value=S.getItem(key)||'';if(select.selectedIndex<0)select.selectedIndex=0}
      options(site,Array.from(new Set(rows.map(function(r){return r.dataset.site}).filter(Boolean))).sort(),'khu-site');
      options(tag,Array.from(new Set(rows.flatMap(tags))).sort(),'khu-tag');
      group.value=S.getItem('khu-group')||'';if(group.selectedIndex<0)group.selectedIndex=0;
      size.value=S.getItem('khu-size')||'25';if(size.selectedIndex<0)size.value='25';
      function run(reset){
        if(reset)page=1;
        var query=search.value.trim().toLowerCase(),matches=rows.filter(function(r){var st=r.dataset.state;return (!query||r.dataset.mac.indexOf(query)>=0)&&(!site.value||r.dataset.site===site.value)&&(!tag.value||tags(r).indexOf(tag.value)>=0)&&(mode==='all'||st===mode||(mode==='update'&&st==='updating'))});
        function key(r){return group.value==='site'?(r.dataset.site||'No site'):group.value==='tags'?(tags(r).join(', ')||'No tags'):''}
        matches.sort(function(a,b){return key(a).localeCompare(key(b))||Number(a.dataset.rank)-Number(b.dataset.rank)||a.dataset.mac.localeCompare(b.dataset.mac)});
        var per=size.value==='all'?Math.max(1,matches.length):Number(size.value),pages=Math.max(1,Math.ceil(matches.length/per));page=Math.min(page,pages);
        rows.forEach(function(r){r.hidden=true});list.querySelectorAll('.groupheading').forEach(function(e){e.remove()});
        var visible=matches.slice((page-1)*per,page*per),last=null;
        visible.forEach(function(r){var k=key(r);if(k&&k!==last){var heading=document.createElement('h3');heading.className='groupheading';heading.textContent=k;list.appendChild(heading);last=k}r.hidden=false;list.appendChild(r)});
        list.hidden=matches.length===0;document.getElementById('nomatch').hidden=matches.length>0;
        document.getElementById('count').textContent=matches.length?((page-1)*per+1)+'–'+Math.min(page*per,matches.length)+' of '+matches.length+' Macs':'0 Macs';
        document.getElementById('page-label').textContent='Page '+page+' of '+pages;document.getElementById('page-prev').disabled=page<=1;document.getElementById('page-next').disabled=page>=pages;
        document.querySelectorAll('.filter').forEach(function(b){b.setAttribute('aria-pressed',b.dataset.f===mode)});
        S.setItem('khu-filter',search.value);S.setItem('khu-mode',mode);S.setItem('khu-site',site.value);S.setItem('khu-tag',tag.value);S.setItem('khu-group',group.value);S.setItem('khu-size',size.value);S.setItem('khu-page',page);
      }
      document.querySelector('.tools').hidden=false;document.querySelector('.fleetoptions').hidden=false;document.querySelector('.pager').hidden=false;
      search.value=S.getItem('khu-filter')||'';search.addEventListener('input',function(){run(true)});
      [site,tag,group,size].forEach(function(e){e.addEventListener('change',function(){run(true)})});
      document.querySelectorAll('.filter').forEach(function(b){b.addEventListener('click',function(){mode=b.dataset.f;run(true)})});
      document.getElementById('page-prev').addEventListener('click',function(){page--;run(false)});document.getElementById('page-next').addEventListener('click',function(){page++;run(false)});
      var dialog=document.getElementById('mac-dialog'),body=document.getElementById('mac-dialog-body'),opened=null,opener=null;
      function close(){if(opened){opened.appendChild(body.firstElementChild);opened=null}S.removeItem('khu-modal');if(opener&&opener.isConnected&&!opener.closest('[hidden]'))opener.focus();else document.getElementById('refresh').focus()}
      dialog.addEventListener('close',close);document.getElementById('mac-dialog-close').addEventListener('click',function(){dialog.close()});
      dialog.addEventListener('click',function(e){if(e.target===dialog){var box=dialog.getBoundingClientRect();if(e.clientX<box.left||e.clientX>box.right||e.clientY<box.top||e.clientY>box.bottom)dialog.close()}});
      function open(row){if(opened)return;opened=row;opener=row.querySelector('summary');body.appendChild(row.querySelector('.detail'));document.getElementById('mac-dialog-title').textContent=row.dataset.label;S.setItem('khu-modal',row.dataset.machine);dialog.showModal()}
      rows.forEach(function(row){row.querySelector('summary').addEventListener('click',function(e){if(typeof dialog.showModal!=='function')return;var f=e.target.closest('form');e.preventDefault();if(f){f.requestSubmit();return}open(row)})});
      var saved=S.getItem('khu-modal');if(saved){var restore=rows.find(function(r){return r.dataset.machine===saved});if(restore)open(restore);else S.removeItem('khu-modal')}
      run(false);
    }
    """#

    static let style = """
    .deviceicon{width:32px;height:32px;flex:none;color:var(--sub)}.who{flex-direction:row;align-items:center;gap:10px}.whotext{display:flex;flex-direction:column;min-width:0}.state{min-width:0}.state .chip{white-space:normal;overflow-wrap:anywhere}details.mac>summary:focus-visible{outline-offset:-3px}.fleetoptions,.pager{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin:14px 0}.fleetoptions label,.pager label{display:flex;align-items:center;gap:6px;color:var(--sub);font-size:12.5px}select{font:inherit;color:var(--text);background:var(--panel);border:1px solid var(--field);border-radius:7px;min-height:30px;padding:3px 8px;max-width:220px}.pager{justify-content:flex-end}.groupheading{padding:12px 16px;margin:0;background:var(--muted-bg);font-size:13px;color:var(--text)}dialog{width:min(1000px,calc(100vw - 32px));max-height:calc(100dvh - 40px);padding:0;border:1px solid var(--line);border-radius:14px;background:var(--panel);color:var(--text);box-shadow:var(--shadow)}dialog::backdrop{background:rgba(0,0,0,.48)}.modalbar{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:18px 24px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--panel);z-index:2}.modalbar h2{margin:0;font-size:20px;overflow-wrap:anywhere}dialog .detail{padding:20px 24px;border:0}.macsummary{display:flex;gap:12px;align-items:center;margin-bottom:20px}.macsummary .deviceicon{width:48px;height:48px}.metadata{display:flex;gap:12px;flex-wrap:wrap;margin:20px 0}.metadata label{display:flex;flex-direction:column;gap:4px;min-width:0;flex:1 1 180px}.metadata input,input[name=name]{padding:6px 8px;max-width:100%;min-width:0;border:1px solid var(--field);border-radius:7px;background:var(--panel)}.metadata button{align-self:end}.identity dd{display:flex;gap:8px;align-items:center;flex-wrap:wrap}.inventorynote{color:var(--sub);font-size:12.5px}.apptable .actions{white-space:normal}.apptable .actions form{display:inline-block;margin-bottom:4px}@media(max-width:820px){dialog{width:calc(100vw - 16px);max-height:calc(100dvh - 16px)}.modalbar{padding:14px}dialog .detail{padding:14px}.pager{justify-content:flex-start}.fleetoptions{align-items:flex-start}.fleetoptions label{flex:1 1 140px;flex-direction:column;align-items:flex-start}select{max-width:100%;width:100%}.pager select{width:auto}.macsummary{flex-wrap:wrap}.inventorytable thead{display:none}.inventorytable tr{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:8px;padding:12px 0}.inventorytable td{padding:0;border:0!important;min-width:0}.inventorytable td:first-child,.inventorytable td:last-child{grid-column:1/-1}.inventorytable td:nth-child(2)::before{content:"Version ";color:var(--sub)}.inventorytable td:nth-child(3)::before{content:"Maker ";color:var(--sub)}.inventorytable code{overflow-wrap:anywhere}.inventorytable button{margin:4px 0 0 6px}}
    """
}
