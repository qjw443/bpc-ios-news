import Foundation
import WebKit

/// 站点规则：拦什么 JS / 怎么清 DOM / 怎么取正文。
/// 提取一律做「多层策略」，任何单层失效都不会让功能瘫痪。
enum Rules {

    // MARK: - UA

    static let chromeUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static let googlebotUA = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"

    // MARK: - 内容拦截规则（WKContentRuleList，JSON 数组）

    /// Bloomberg：掐 bwbx.io 的 fortress / fence 付费墙客户端
    /// 证据：BPC sites.js  block_regex: /\.bwbx\.io\/s3\/fence\/(fortress-client|fast-path|plug-client)\//
    static let blockBloomberg = #"""
    [
      {"trigger":{"url-filter":".*\\.bwbx\\.io/s3/fence/(fortress-client|fast-path|plug-client)/.*",
                  "resource-type":["script","raw"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\.bloomberg\\.com/(fence|paywall|regwall|subscription)/.*",
                  "resource-type":["script","raw"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*assets\\.bwbx\\.io/.*/(fortress|fence)[^/]*\\.js.*",
                  "resource-type":["script"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*(datadome|perimeterx|px-cdn|_px|px-cloud)\\.(com|net|io)/.*",
                  "resource-type":["script"]},"action":{"type":"block"}}
    ]
    """#

    /// Reuters：掐 Arc XP 订阅脚本
    /// 证据：BPC sites.js  block_regex: /\.reuters\.com\/arc\/subs\/p\.min\.js/
    static let blockReuters = #"""
    [
      {"trigger":{"url-filter":".*\\.reuters\\.com/arc/subs/p\\.min\\.js.*",
                  "resource-type":["script","raw"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\.reuters\\.com/arc/outboundfeeds/.*subs.*",
                  "resource-type":["script","raw"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*consent\\.reuters\\.com/.*","resource-type":["script"]},
       "action":{"type":"block"}},
      {"trigger":{"url-filter":".*(datadome|perimeterx|px-cdn|_px|px-cloud)\\.(com|net|io)/.*",
                  "resource-type":["script"]},"action":{"type":"block"}}
    ]
    """#

    static func blockListJSON(for site: Site) -> String {
        site == .bloomberg ? blockBloomberg : blockReuters
    }

    // MARK: - 页面清理（对应 BPC 的 cs_code）

    static let cleanupJS = #"""
    (function(){
      var WALL = /(subscribe to continue|already a subscriber|unlimited access|claim this offer|subscribe now|create a free account|sign in to continue|this article is for subscribers|继续阅读|订阅)/i;
      function clean(){
        try{
          // ① 去模糊：articleBlur 类 + 内联 filter/mask（BPC: div[class*="articleBlur"] 去类）
          document.querySelectorAll('div[class*="articleBlur"]').forEach(function(e){
            e.className = e.className.split(/\s+/).filter(function(c){return c && !/articleBlur/i.test(c);}).join(' ');
            e.style.filter='none'; e.style.webkitMaskImage='none'; e.style.maskImage='none';
            e.style.opacity='1'; e.style.maxHeight='none';
          });
          // ② 任何带 blur / mask 内联样式的容器都还原
          document.querySelectorAll('[style*="blur"],[style*="mask"]').forEach(function(e){
            e.style.filter='none'; e.style.webkitMaskImage='none'; e.style.maskImage='none';
          });
          // ③ 订阅浮层（BPC: div[class*="_sheetWrapper_"] 且含订阅文案）
          document.querySelectorAll('div[class*="_sheetWrapper_"],[class*="BreachScreen"],[class*="BreachWall"],[data-testid*="paywall"],[class*="Paywall"],[class*="Regwall"],[id*="paywall"]').forEach(function(e){
            e.remove();
          });
          document.querySelectorAll('div[role="dialog"],[aria-modal="true"]').forEach(function(e){
            if(WALL.test(e.innerText||'')) e.remove();
          });
          // ④ 兜底：任何占屏面积大、且只说「订阅」的遮罩
          document.querySelectorAll('div,section,aside').forEach(function(e){
            if(e.offsetHeight > window.innerHeight*0.35 && WALL.test((e.innerText||'').slice(0,400))) e.remove();
          });
          // ⑤ 解除滚动锁与半透明遮罩（BPC: 去掉 html/body 的 class）
          [document.documentElement, document.body].forEach(function(e){
            if(!e) return;
            e.removeAttribute('class');
            e.style.overflow='auto'; e.style.position='static';
            e.style.filter='none';
          });
          // ⑥ 广告位顺手清掉（不影响正文）
          document.querySelectorAll('div[data-testid="ResponsiveAdSlot"],div[data-testid="Dianomi"],div[data-testid="article-subscriber-gate"]').forEach(function(e){e.remove();});
          // ⑦ 同意/隐私弹窗：能点「全部接受」就点，避免被挡在条款页
          var cands = document.querySelectorAll('button,[role="button"],a');
          for (var ci = 0; ci < cands.length; ci++) {
            var tx = (cands[ci].innerText || '').trim();
            if (/^(accept all|allow all|i agree|agree to all|全部接受|全部同意|同意|接受全部)$/i.test(tx)) {
              try { cands[ci].click(); } catch (e) {}
              break;
            }
          }
          document.querySelectorAll('#onetrust-consent-sdk,[id*="cookie-banner"],[class*="cookie-banner"],[aria-label*="cookie" i]').forEach(function(e){
            if (e.offsetHeight > 80) e.remove();
          });
        }catch(e){}
      }
      clean();
      var n=0, t=setInterval(function(){ clean(); if(++n>50) clearInterval(t); }, 300);
    })();
    """#

    /// documentStart：清计量计数（localStorage/sessionStorage + 可删的 cookie）
    static let storageJS = #"""
    (function(){
      try{ localStorage.clear(); sessionStorage.clear(); }catch(e){}
      try{
        document.cookie.split(';').forEach(function(c){
          var n=c.split('=')[0].trim();
          if(!n) return;
          document.cookie = n+'=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/';
          document.cookie = n+'=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/; domain=.'+location.hostname.replace(/^www\./,'');
        });
      }catch(e){}
    })();
    """#

    // MARK: - 正文提取（返回 JSON 字符串，含 via / walls 便于诊断）

    /// Bloomberg 三层：
    ///   A. __NEXT_DATA__ → props.pageProps.story.body.content（Arcadia，BPC 同路径）
    ///   B. DOM → div > p[class^="ArticleBodyText_"]（BPC 的 article_pars 选择器）
    ///   C. DOM → article p
    static let extractBloomberg = #"""
    (function(){
      var out={title:'',blocks:[],summary:[],audio:'',via:'',walls:[]};
      var WALL=/(subscribe to continue|already a subscriber|unlimited access|claim this offer|subscribe now|create a free account)/i;
      function push(t,type){ if(t&&t.trim().length>0) out.blocks.push({type:type||'p',text:t.trim()}); }
      function walls(){ try{
        document.querySelectorAll('[class*="paywall"],[id*="paywall"],[class*="Paywall"],[class*="_sheetWrapper_"]').forEach(function(e){
          if(e.offsetHeight>60 && WALL.test(e.innerText||'')) out.walls.push((e.className||e.id||'wall').toString().slice(0,40));
        });
      }catch(e){} }

      // A. __NEXT_DATA__
      var el=document.querySelector('script#__NEXT_DATA__');
      if(el){
        var j; try{ j=JSON.parse(el.textContent); }catch(e){ j=null; }
        var story=j&&j.props&&j.props.pageProps&&j.props.pageProps.story;
        if(story){
          out.title=story.headline||'';
          if(story.readingUrl) out.audio=story.readingUrl;
          if(story.aiSummary&&story.aiSummary.text) out.summary=story.aiSummary.text;
          function txt(it){
            if(!it) return '';
            if(it.type==='text') return it.value||'';
            if(it.type==='entity') return (it.data&&(it.data.text||it.data.value))||'';
            if(it.type==='link'){
              var t=(it.content||[]).map(txt).join('');
              var h=(it.data&&it.data.href)||'';
              if(h.indexOf('bbg://securities/')===0){
                var s=h.split('bbg://securities/')[1];
                var p=/\d+[A-Z]%20[A-Z]{2}%20Equity/.test(s)?'/profile/company/':'/quote/';
                h='https://www.bloomberg.com'+p+s;
              }
              return t&&h?('<a href="'+h+'">'+t+'</a>'):t;
            }
            if(it.content) return it.content.map(txt).join('');
            return '';
          }
          var body=(story.body&&story.body.content)||[];
          for(var i=0;i<body.length;i++){
            var p=body[i],t=p.type||'';
            if(t==='paragraph'||t==='heading') push(txt(p), t==='heading'?'h2':'p');
            else if(t==='hr') out.blocks.push({type:'hr',text:''});
            else if(t.slice(-5)==='quote') push((p.content||[]).map(function(c){return txt(c);}).join(' '),'quote');
            else if(t==='list') (p.content||[]).forEach(function(li){ push(txt(li),'li'); });
            else if(t==='media'&&p.data&&p.data.image&&p.data.image.url)
              out.blocks.push({type:'img',text:(p.data.image.caption||''),src:p.data.image.url});
          }
          if(out.blocks.length>=3){ out.via='next_data'; walls(); return JSON.stringify(out); }
        }
      }

      // B. ArticleBodyText_ 段落（BPC 的 DOM 回退选择器）
      var ps=document.querySelectorAll('div > p[class^="ArticleBodyText_"], p[class*="ArticleBodyText_"]');
      if(ps.length>=3){
        out.blocks=[];
        for(var k=0;k<ps.length;k++) push(ps[k].innerText,'p');
        if(!out.title){ var h1=document.querySelector('h1'); out.title=h1?h1.innerText:document.title; }
        if(out.blocks.length>=3){ out.via='dom_artbodytext'; walls(); return JSON.stringify(out); }
      }

      // C. 通用 article/main 段落
      out.blocks=[];
      var box=document.querySelector('article, main, [role="main"]')||document.body;
      var gen=box.querySelectorAll('p, h2');
      for(var g=0;g<gen.length;g++){
        var s=(gen[g].innerText||'').trim();
        if(s.length>40) out.blocks.push({type:/^H/.test(gen[g].tagName)?'h2':'p',text:s});
      }
      if(!out.title){ var hh=document.querySelector('h1'); out.title=hh?hh.innerText:document.title; }
      out.via='dom_generic';
      walls();
      return JSON.stringify(out);
    })();
    """#

    /// Reuters 三层：paragraph-N → Article 内 p → article/main p
    static let extractReuters = #"""
    (function(){
      var out={title:'',blocks:[],summary:[],audio:'',via:'',walls:[]};
      function push(t){ if(t&&t.trim().length>1) out.blocks.push({type:'p',text:t.trim()}); }
      function title(){
        var h=document.querySelector('h1');
        out.title=(h?h.innerText:document.title||'').trim();
      }
      function walls(){
        try{
          document.querySelectorAll('[class*="paywall"],[data-testid*="paywall"],[class*="Regwall"]').forEach(function(e){
            if(e.offsetHeight>60) out.walls.push((e.className||'').toString().slice(0,40));
          });
        }catch(e){}
      }
      function done(v){ out.via=v; walls(); return JSON.stringify(out); }

      title();
      var nodes=document.querySelectorAll('div[data-testid^="paragraph-"], div[data-testid="paragraph"]');
      if(nodes.length>=3){
        for(var i=0;i<nodes.length;i++){
          var t=(nodes[i].innerText||'').replace(/\s+\n/g,'\n');
          if(!/^(advertisement|read more|sign up|register)/i.test(t.trim())) push(t);
        }
        if(out.blocks.length>=3) return done('testid_paragraph');
      }

      out.blocks=[];
      var art=document.querySelector('div[data-testid="Article"], article, main, [role="main"]');
      if(art){
        var ps=art.querySelectorAll('p');
        for(var k=0;k<ps.length;k++){
          var s=(ps[k].innerText||'').trim();
          if(s.length>40 && !/^(advertisement|read more)/i.test(s)) out.blocks.push({type:'p',text:s});
        }
      }
      if(out.blocks.length>=3) return done('dom_article_p');

      out.blocks=[];
      var all=document.querySelectorAll('body p');
      for(var m=0;m<all.length;m++){
        var u=(all[m].innerText||'').trim();
        if(u.length>60) out.blocks.push({type:'p',text:u});
      }
      return done('dom_body_p');
    })();
    """#

    static func extractJS(for site: Site) -> String {
        site == .bloomberg ? extractBloomberg : extractReuters
    }

    /// archive.ph 兜底
    static let extractArchive = #"""
    (function(){
      var out={title:'',blocks:[],summary:[],audio:'',via:'archive',walls:[]};
      var box=document.querySelector('div.TEXT-BLOCK, article, #CONTENT, div.post-content');
      if(!box) return JSON.stringify(out);
      out.title=(document.title||'').replace(/\s*[-|]\s*archive.*$/i,'');
      var ps=box.querySelectorAll('p, h2, h3');
      for(var i=0;i<ps.length;i++){
        var t=(ps[i].innerText||'').trim();
        if(t.length>1) out.blocks.push({type:/^H/.test(ps[i].tagName)?'h2':'p',text:t});
      }
      return JSON.stringify(out);
    })();
    """#

    // MARK: - 文案

    static func hint(for site: Site) -> String {
        site == .bloomberg
            ? "已拦 fence 客户端 · 已去 articleBlur 模糊 · 已清计量计数"
            : "已拦 arc/subs · 已清 cookie 与遮罩"
    }
}
