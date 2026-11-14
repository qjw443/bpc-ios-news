import Foundation
import WebKit

/// 反检测：把 WKWebView 的浏览器指纹补成「真实 iOS Safari」该有的样子。
///
/// 原则（很重要）：
///   UA 声明的是 **iPhone Safari**，所以指纹必须与 Safari 一致。
///   任何「Chrome 特征」都会自相矛盾（例如 userAgentData、Sec-CH-UA），反而更容易被判定为伪造。
///   因此这里**不伪造 window.chrome / userAgentData**，而是把它们藏成 Safari 的样子。
///
/// 覆盖的检测点：
///   · navigator.webdriver（自动化标志）
///   · navigator.plugins / mimeTypes（无头浏览器常为空）
///   · navigator.languages / language（与 Accept-Language 一致）
///   · hardwareConcurrency / deviceMemory / maxTouchPoints（移动设备合理值）
///   · navigator.vendor / platform（Apple）
///   · WebGL vendor / renderer（伪装 Apple GPU）
///   · navigator.connection / permissions（Safari 的形态）
///   · screen / devicePixelRatio（与 WebView 尺寸一致）
enum Stealth {

    /// 注入到每个 frame 的最早时机（documentStart），先于站点任何脚本
    static let script: String = #"""
    (function(){
      if (window.__bpcStealth) return;
      window.__bpcStealth = 1;

      function def(obj, prop, value){
        try{
          Object.defineProperty(obj, prop, { get: function(){ return value; }, configurable: true });
        }catch(e){}
      }

      try{
        var nav = window.navigator;

        // ① 自动化标志（最常被查）
        def(nav, 'webdriver', false);
        try{ delete nav.__proto__.webdriver; }catch(e){}

        // ② 语言：与请求头 en-US,en 一致
        def(nav, 'language', 'en-US');
        def(nav, 'languages', ['en-US', 'en']);

        // ③ Apple 平台特征
        def(nav, 'vendor', 'Apple Computer, Inc.');
        def(nav, 'platform', 'iPhone');
        def(nav, 'productSub', '20030107');
        def(nav, 'maxTouchPoints', 5);
        def(nav, 'hardwareConcurrency', 6);
        def(nav, 'deviceMemory', 4);
        def(nav, 'doNotTrack', null);

        // ④ Safari 没有 client hints：有就删掉（存在即矛盾）
        try{ delete nav.userAgentData; }catch(e){}
        try{ Object.defineProperty(nav, 'userAgentData', { get: function(){ return undefined; }, configurable: true }); }catch(e){}

        // ⑤ Safari 没有 window.chrome：有就删掉
        try{ delete window.chrome; }catch(e){}

        // ⑥ 插件：真实 Safari 有 3 个 PDF 插件，无头/伪造环境常为空
        try{
          if (!nav.plugins || nav.plugins.length === 0) {
            var mk = function(name, filename, desc){
              return { name: name, filename: filename, description: desc, length: 1 };
            };
            var plugins = [
              mk('PDF Viewer', 'internal-pdf-viewer', 'Portable Document Format'),
              mk('Chrome PDF Viewer', 'internal-pdf-viewer', 'Portable Document Format'),
              mk('WebKit built-in PDF', 'internal-pdf-viewer', 'Portable Document Format')
            ];
            plugins.item = function(i){ return plugins[i] || null; };
            plugins.namedItem = function(n){ for (var i=0;i<plugins.length;i++) if (plugins[i].name===n) return plugins[i]; return null; };
            plugins.refresh = function(){};
            Object.defineProperty(nav, 'plugins', { get: function(){ return plugins; }, configurable: true });
            var mimes = [{ type: 'application/pdf', suffixes: 'pdf', description: 'Portable Document Format' }];
            mimes.item = function(i){ return mimes[i] || null; };
            mimes.namedItem = function(n){ for (var i=0;i<mimes.length;i++) if (mimes[i].type===n) return mimes[i]; return null; };
            Object.defineProperty(nav, 'mimeTypes', { get: function(){ return mimes; }, configurable: true });
          }
        }catch(e){}

        // ⑦ WebGL：伪装 Apple GPU（真实 iPhone 的输出）
        try{
          var patchGL = function(proto){
            var orig = proto.getParameter;
            proto.getParameter = function(p){
              if (p === 37445) return 'Apple Inc.';                 // UNMASKED_VENDOR
              if (p === 37446) return 'Apple GPU';                  // UNMASKED_RENDERER
              return orig.apply(this, arguments);
            };
          };
          if (window.WebGLRenderingContext) patchGL(WebGLRenderingContext.prototype);
          if (window.WebGL2RenderingContext) patchGL(WebGL2RenderingContext.prototype);
        }catch(e){}

        // ⑧ 网络与权限：给 Safari 形态的值
        try{
          if (!nav.connection) {
            Object.defineProperty(nav, 'connection', {
              get: function(){
                return { effectiveType: '4g', rtt: 50, downlink: 10, saveData: false,
                         addEventListener: function(){}, removeEventListener: function(){} };
              }, configurable: true
            });
          }
        }catch(e){}
        try{
          if (nav.permissions && nav.permissions.query) {
            var origQuery = nav.permissions.query.bind(nav.permissions);
            nav.permissions.query = function(desc){
              if (desc && desc.name === 'notifications') {
                return Promise.resolve({ state: Notification.permission, onchange: null });
              }
              return origQuery(desc);
            };
          }
        }catch(e){}

        // ⑨ 视口一致性：屏幕尺寸跟 WebView 对齐
        try{
          Object.defineProperty(window.screen, 'width',  { get: function(){ return window.innerWidth  || 390; }, configurable: true });
          Object.defineProperty(window.screen, 'height', { get: function(){ return window.innerHeight || 844; }, configurable: true });
          Object.defineProperty(window.screen, 'availWidth',  { get: function(){ return window.innerWidth  || 390; }, configurable: true });
          Object.defineProperty(window.screen, 'availHeight', { get: function(){ return window.innerHeight || 844; }, configurable: true });
          Object.defineProperty(window, 'devicePixelRatio', { get: function(){ return 3; }, configurable: true });
        }catch(e){}

        // ⑩ iframe 内也要一致（有些检测在子 frame 里跑）
        try{
          if (window.top !== window.self) {
            Object.defineProperty(window.navigator, 'webdriver', { get: function(){ return false; }, configurable: true });
          }
        }catch(e){}
      }catch(e){}
    })();
    """#

    /// 与 UA 匹配的、真实移动 Safari 会发送的请求头（顺序之外的字段尽量少，越少越像原生）
    static func headers(for site: Site, url: URL) -> [String: String] {
        // 同站 Referer：从外站（google）跳进来的移动 Safari 才是异常的
        let home: String
        switch site {
        case .bloomberg: home = "https://www.bloomberg.com/"
        case .reuters:   home = "https://www.reuters.com/"
        case .wsj:       home = "https://cn.wsj.com/"
        }
        return [
            "Referer": home,
            "Accept-Language": "en-US,en;q=0.9",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ]
    }
}
