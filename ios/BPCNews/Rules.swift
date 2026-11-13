import Foundation
import WebKit

/// 把 Chrome 扩展 BPC 的规则翻译成 iOS 能用的三件套：
///   1. WKContentRuleList  -> 按正则拦付费墙 JS（对应 block_regex）
///   2. WKUserScript       -> 清 DOM / 清 storage（对应 cs_code + remove_cookies_fn）
///   3. customUserAgent    -> 伪装 Googlebot 或真 Chrome（对应 modifyHeaders）
enum Rules {

    // MARK: - UA

    static let chromeUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static let googlebotUA = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"

    // MARK: - 内容拦截规则（JSON 数组）

    /// Bloomberg：掐 bwbx.io 的 fortress/fence 反付费墙客户端
    /// 对应 sites.js: block_regex: /\.bwbx\.io\/s3\/fence\/(fortress-client|fast-path|plug-client)\//
    static let blockBloomberg = #"""
    [
      {"trigger":{"url-filter":".*\\.bwbx\\.io/s3/fence/(fortress-client|fast-path|plug-client)/.*",
                  "resource-type":["script","raw"]},
       "action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\.bloomberg\\.com/(fence|paywall|regwall|subscription)/.*",
                  "resource-type":["script","raw"]},
       "action":{"type":"block"}},
      {"trigger":{"url-filter":".*assets\\.bwbx\\.io/.*/(fortress|fence)[^/]*\\.js.*",
                  "resource-type":["script"]},
       "action":{"type":"block"}},
      {"trigger":{"url-filter":".*(datadome|perimeterx|px-cdn|_px)\\.(com|net|io)/.*",
                  "resource-type":["script"]},
       "action":{"type":"block"}}
    ]
    """#

    /// Reuters：掐 Arc XP 的订阅脚本
    /// 对应 sites.js: block_regex: /\.reuters\.com\/arc\/subs\/p\.min\.js/
    static let blockReuters = #"""
    [
      {"trigger":{"url-filter":".*\\.reuters\\.com/arc/subs/p\\.min\\.js.*",
                  "resource-type":["script","raw"]},
       "action":{"type":"block"}},
      {"trigger":{"url-filter":".*\\.reuters\\.com/arc/outboundfeeds/.*subs.*",
                  "resource-type":["script","raw"]},
       "action":{"type":"block"}},
      {"trigger":{"url-filter":".*consent\\.reuters\\.com/.*",
                  "resource-type":["script"]},
       "action":{"type":"block"}},
      {"trigger":{"url-filter":".*(datadome|perimeterx|px-cdn|_px)\\.(com|net|io)/.*",
                  "resource-type":["script"]},
       "action":{"type":"block"}}
    ]
    """#

    static func blockListJSON(for site: Site) -> String {
        site == .bloomberg ? blockBloomberg : blockReuters
    }

    // MARK: - 页面清理脚本

    /// 对应 BPC 的 cs_code：去 articleBlur 类、删 subscription sheet、清 html/body 类
    static let cleanupJS = #"""
    (function(){
      function clean(){
        try{
          document.querySelectorAll('div[class*="articleBlur"]').forEach(function(e){
            e.className = e.className.split(/\s+/).filter(function(c){return c && !/articleBlur/i.test(c);}).join(' ');
            e.style.filter='none'; e.style.webkitMaskImage='none'; e.style.maskImage='none';
          });
          document.querySelectorAll('div[class*="_sheetWrapper_"]').forEach(function(e){
            var t=e.innerText||'';
            if(/(unlimited access|claim this offer|subscribe now|already a subscriber)/i.test(t)) e.remove();
          });
          [document.documentElement, document.body].forEach(function(e){
            if(e){ e.removeAttribute('class'); e.style.overflow='auto'; }
          });
          document.querySelectorAll('[class*="paywall"],[id*="paywall"],[class*="Paywall"],[class*="Regwall"],[class*="ArticleBody-articleBody-fade"]').forEach(function(e){
            if(e.offsetHeight > window.innerHeight*0.22) e.remove();
          });
          document.querySelectorAll('[class*="paywall"],[data-testid*="paywall"]').forEach(function(e){ e.remove(); });
          document.querySelectorAll('div[data-testid="ResponsiveAdSlot"],div[data-testid="Dianomi"]').forEach(function(e){ e.remove(); });
          document.querySelectorAll('body > div[role="dialog"]').forEach(function(e){ e.remove(); });
          document.body.style.overflow='auto';
        }catch(e){}
      }
      clean();
      var n=0, t=setInterval(function(){ clean(); if(++n>40) clearInterval(t); }, 300);
    })();
    """#

    /// documentStart 就清一次 storage（对应 remove_cookies 的 cs_clear_lclstrg）
    static let storageJS = """
    (function(){ try{ localStorage.clear(); sessionStorage.clear(); }catch(e){} })();
    """

    // MARK: - 正文提取（在页面里执行，返回 JSON 字符串）

    /// Bloomberg：从 __NEXT_DATA__ 的 Arcadia 结构还原全文
    /// 路径 props.pageProps.story.body.content（与 cs_local/contentScript_en.js:1911 一致）
    static let extractBloomberg = #"""
    (function(){
      var out = {title:'', blocks:[], summary:[], audio:''};
      var el = document.querySelector('script#__NEXT_DATA__');
      if(!el) return JSON.stringify(out);
      var j;
      try{ j = JSON.parse(el.textContent); }catch(e){ return JSON.stringify(out); }
      var story = j && j.props && j.props.pageProps && j.props.pageProps.story;
      if(!story) return JSON.stringify(out);
      out.title = story.headline || '';
      if(story.readingUrl) out.audio = story.readingUrl;
      if(story.aiSummary && story.aiSummary.text) out.summary = story.aiSummary.text;
      function txt(it){
        if(!it) return '';
        if(it.type==='text') return it.value||'';
        if(it.type==='entity') return (it.data && (it.data.text||it.data.value))||'';
        if(it.type==='link'){
          var t=(it.content||[]).map(txt).join('');
          var h=(it.data&&it.data.href)||'';
          if(h.indexOf('bbg://securities/')===0){
            var s=h.split('bbg://securities/')[1];
            var p=/\d+[A-Z]%20[A-Z]{2}%20Equity/.test(s)?'/profile/company/':'/quote/';
            h='https://www.bloomberg.com'+p+s;
          }
          return t && h ? ('<a href="'+h+'">'+t+'</a>') : t;
        }
        if(it.content) return it.content.map(txt).join('');
        return '';
      }
      var body = (story.body && story.body.content) || [];
      for(var i=0;i<body.length;i++){
        var p=body[i], t=p.type||'';
        if(t==='paragraph'||t==='heading'){
          var s=txt(p).trim();
          if(s) out.blocks.push({type:(t==='heading'?'h2':'p'), text:s});
        } else if(t==='hr'){ out.blocks.push({type:'hr', text:''}); }
        else if(t.slice(-5)==='quote'){
          var q=(p.content||[]).map(function(c){return txt(c);}).join(' ').trim();
          if(q) out.blocks.push({type:'quote', text:q});
        } else if(t==='list'){
          (p.content||[]).forEach(function(li){
            var s=txt(li).trim();
            if(s) out.blocks.push({type:'li', text:s});
          });
        } else if(t==='media' && p.data && p.data.image && p.data.image.url){
          out.blocks.push({type:'img', text:(p.data.image.caption||''), src:p.data.image.url});
        }
      }
      return JSON.stringify(out);
    })();
    """#

    /// Reuters：DOM 直取 data-testid="paragraph-N"
    static let extractReuters = #"""
    (function(){
      var out = {title:'', blocks:[], summary:[], audio:''};
      var h1 = document.querySelector('h1');
      out.title = (h1 && h1.innerText ? h1.innerText : document.title || '').trim();
      var nodes = document.querySelectorAll('div[data-testid^="paragraph-"], div[data-testid="paragraph"]');
      if(!nodes.length){
        var art = document.querySelector('div[data-testid="Article"], article, main');
        if(art) nodes = art.querySelectorAll('p');
      }
      for(var i=0;i<nodes.length;i++){
        var t=(nodes[i].innerText||'').replace(/\s+\n/g,'\n').trim();
        if(t.length>1 && !/^(advertisement|read more|sign up|register)/i.test(t))
          out.blocks.push({type:'p', text:t});
      }
      return JSON.stringify(out);
    })();
    """#

    static func extractJS(for site: Site) -> String {
        site == .bloomberg ? extractBloomberg : extractReuters
    }

    /// archive.ph 兜底提取
    static let extractArchive = #"""
    (function(){
      var box = document.querySelector('div.TEXT-BLOCK, article, #CONTENT, div.post-content');
      if(!box) return JSON.stringify({title:'',blocks:[],summary:[],audio:''});
      var out={title:(document.title||'').replace(/\s*[-|]\s*archive.*$/i,''),blocks:[],summary:[],audio:''};
      var ps = box.querySelectorAll('p, h2, h3');
      for(var i=0;i<ps.length;i++){
        var t=(ps[i].innerText||'').trim();
        if(t.length>1) out.blocks.push({type:/^H/.test(ps[i].tagName)?'h2':'p', text:t});
      }
      return JSON.stringify(out);
    })();
    """#

    // MARK: - 提示文案

    static func hint(for site: Site) -> String {
        site == .bloomberg
            ? "已拦截 bwbx.io fence 脚本 · 已清计量 cookie"
            : "已拦截 arc/subs 订阅脚本 · 已清 cookie"
    }
}
