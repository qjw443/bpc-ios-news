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
        switch site {
        case .bloomberg: return blockBloomberg
        case .reuters: return blockReuters
        case .wsj: return blockReuters          // WSJ 同属「付费墙 + 计量」类型，复用同一套拦截
        }
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
          if(out.blocks.length>=3){
            // JSON 里没有配图时，补一遍页面里的 figure（官网排版里图片是正文的一部分）
            var hasImg = false;
            for (var bi=0; bi<out.blocks.length; bi++) if (out.blocks[bi].type==='img') { hasImg = true; break; }
            if (!hasImg && out.blocks.length <= 14) {
              var figs = document.querySelectorAll('article figure, figure');
              for (var fi=0; fi<figs.length && fi<6; fi++) {
                var im = figs[fi].querySelector('img');
                if (!im) continue;
                var s2 = im.currentSrc || im.src || im.getAttribute('data-src') || '';
                if (!s2 || s2.indexOf('data:') === 0) continue;
                if (s2.indexOf('//') === 0) s2 = 'https:' + s2;
                var cap = figs[fi].querySelector('figcaption');
                out.blocks.push({type:'img', text:(cap?cap.innerText:'').trim().slice(0,200), src:s2});
              }
            }
            out.via='next_data'; walls(); return JSON.stringify(out);
          }
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

    /// 路透 / WSJ：对付费墙页面通用的一套提取
    ///   ① 拆掉 regwall/paywall 遮罩 + 解除 maxHeight 裁剪
    ///   ② 先读 JSON-LD 的 articleBody（付费墙页最可靠的正文来源）
    ///   ③ 再按宽选择器抓段落，过滤「Reporting by / Our Standards / opens new tab」等页脚样板
    static let extractPaywalled = #"""
    (function(){
      var out={title:'',blocks:[],summary:[],audio:'',via:'',walls:[]};
      function clean(s){ return (s||'').replace(/\u00a0/g,' ').replace(/[ \t]+/g,' ').trim(); }
      function boiler(s){
        return /^(our standards|reporting by|editing by|additional reporting|make sense of|register now|opens new tab|read more|advertisement|sign up|subscribe|follow us)/i.test(s)
          || /thomson reuters trust principle/i.test(s)
          || /opens new tab/i.test(s)
          || /^(汤森路透|我们的标准|记者|编辑|注册)/.test(s);
      }
      try{
        document.querySelectorAll('[class*="regwall"],[class*="paywall"],[class*="Paywall"],[class*="Regwall"],[data-testid*="paywall"]').forEach(function(e){
          if(e.offsetHeight>40) out.walls.push((e.className||'').toString().slice(0,50));
          e.remove();
        });
        document.querySelectorAll('div,section,article').forEach(function(e){
          var cs=getComputedStyle(e);
          if(cs.maxHeight && cs.maxHeight!=='none' && e.offsetHeight>240){
            e.style.maxHeight='none'; e.style.overflow='visible';
          }
          if(cs.position==='fixed' && e.offsetHeight>window.innerHeight*0.6) e.remove();
        });
      }catch(e){}

      var h=document.querySelector('h1');
      out.title=clean(h?h.innerText:(document.title||''));

      function push(t){
        var s=clean(t);
        if(s.length>30 && !boiler(s)) out.blocks.push({type:'p',text:s});
      }

      // ② JSON-LD articleBody
      try{
        document.querySelectorAll('script[type="application/ld+json"]').forEach(function(sc){
          var j=null; try{ j=JSON.parse(sc.textContent); }catch(e){ return; }
          var arr=Array.isArray(j)?j:[j];
          arr.forEach(function(o){
            if(!o) return;
            var body=o.articleBody||o.article_body;
            if(body && body.length>200){
              var segs=body.split(/\n{2,}/); if(segs.length<3){ segs=body.split(/[.!?]\s+/); } segs.forEach(function(seg){ push(seg); });
            }
          });
        });
      }catch(e){}
      if(out.blocks.length>=4){ out.via='jsonld_body'; return JSON.stringify(out); }

      // ③ 宽选择器
      out.blocks=[];
      var sel=['div[data-testid^="paragraph"]','[data-testid="paragraph"]',
               'article p','div[class*="article-body"] p','div[class*="ArticleBody"] p',
               'div[class*="article-content"] p','div[class*="content-body"] p',
               'div[class*="article__body"] p','main p','body p'];
      for(var si=0; si<sel.length; si++){
        var nodes=document.querySelectorAll(sel[si]);
        if(!nodes.length) continue;
        var seen={}, acc=[];
        for(var i=0;i<nodes.length;i++){
          var t=clean(nodes[i].innerText);
          if(t.length<=30 || boiler(t) || seen[t]) continue;
          seen[t]=1; acc.push({type:'p',text:t});
        }
        if(acc.length>=4){ out.blocks=acc; out.via='sel'+si; return JSON.stringify(out); }
      }
      out.via='none';
      return JSON.stringify(out);
    })();
    """#

    /// 路透
    static let extractReuters = extractPaywalled

    /// 华尔街日报（中文站结构不同，但同属付费墙，复用同一套）
    static let extractWSJ = extractPaywalled

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
