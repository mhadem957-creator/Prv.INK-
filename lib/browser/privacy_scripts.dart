/// JavaScript snippets injected by INK for privacy and branding.
///
/// Kept in a dedicated file so [BrowserScreen] stays focused on UI + state.

/// Early injection that restyles public SearXNG instances to match INK theme
/// and hides the instance branding.
const String searxCloakJs = r"""
(function(){
  try {
    var h = location.hostname || '';
    if (h.indexOf('searx') === -1 && location.href.indexOf('/search') === -1) return;
    var css = 'body,html{background:#F6F5F0!important;color:#121212!important}'
      + '.title,.navbar-brand,#main-logo,.logo,footer,#footer,.footer,.powered-by,'
      + 'img[alt*="SearX"],img[src*="searx"],header .title,.instance-name'
      + '{display:none!important;height:0!important;overflow:hidden!important}'
      + 'nav.navbar,.searx-navbar,header{background:#F6F5F0!important;border-bottom:3px solid #121212!important;box-shadow:none!important}'
      + 'input[type=text],input[type=search],#q{border:3px solid #121212!important;border-radius:0!important;background:#fff!important;box-shadow:3px 3px 0 #121212!important}'
      + 'button,.btn,input[type=submit]{background:#E60012!important;color:#F6F5F0!important;border:3px solid #121212!important;border-radius:0!important;font-weight:800!important}'
      + '#urls article,.result{border:2px solid #121212!important;background:#fff!important;box-shadow:3px 3px 0 #121212!important;margin-bottom:10px!important;padding:10px!important}'
      + 'a{color:#E60012!important}h3,h4{color:#121212!important;font-weight:900!important}';
    var s=document.createElement('style'); s.textContent=css;
    (document.documentElement||document.head).appendChild(s);
  } catch(e) {}
})();
""";

/// Runtime cloak (re-applied on load stop). More complete than the early script.
const String searxCloakRuntimeJs = r"""
(function() {
  if (window.__inkCloak) return;
  window.__inkCloak = true;
  var css = `
    body, html { background: #F6F5F0 !important; color: #121212 !important; }
    .title, a.navbar-brand, .navbar-brand, #main-logo, .logo,
    footer, #footer, .footer, .powered-by,
    img[alt*="SearX"], img[src*="searx"],
    header .title, .instance-name {
      display: none !important;
      visibility: hidden !important;
      height: 0 !important;
      overflow: hidden !important;
    }
    nav.navbar, .searx-navbar, header {
      background: #F6F5F0 !important;
      border-bottom: 3px solid #121212 !important;
      box-shadow: none !important;
    }
    input[type="text"], input[type="search"], #q {
      border: 3px solid #121212 !important;
      border-radius: 0 !important;
      background: #fff !important;
      box-shadow: 3px 3px 0 #121212 !important;
      color: #121212 !important;
      font-weight: 600 !important;
    }
    button, .btn, input[type="submit"] {
      background: #E60012 !important;
      color: #F6F5F0 !important;
      border: 3px solid #121212 !important;
      border-radius: 0 !important;
      box-shadow: 3px 3px 0 #121212 !important;
      font-weight: 800 !important;
    }
    #urls article, .result, #urls .result {
      border: 2px solid #121212 !important;
      border-radius: 0 !important;
      background: #fff !important;
      box-shadow: 3px 3px 0 #121212 !important;
      margin-bottom: 12px !important;
      padding: 12px !important;
    }
    a { color: #E60012 !important; }
    h3, h4 { color: #121212 !important; font-weight: 900 !important; }
  `;
  var s = document.createElement('style');
  s.id = 'ink-cloak';
  s.textContent = css;
  (document.head || document.documentElement).appendChild(s);
  try {
    document.title = (document.title || '').replace(/SearXNG/gi, 'Ink').replace(/SearxNG/gi, 'Ink').replace(/Searx/gi, 'Ink');
  } catch (e) {}
})();
""";

/// Blocks WebRTC so pages cannot read the device's local/public IP via STUN.
const String webrtcBlockJs = r"""
(function(){
  try {
    var noop = function(){};
    var fake = function(){ throw new Error('WebRTC disabled by INK'); };
    window.RTCPeerConnection = fake;
    window.webkitRTCPeerConnection = fake;
    window.mozRTCPeerConnection = fake;
    window.RTCSessionDescription = noop;
    window.RTCIceCandidate = noop;
    if (navigator.mediaDevices) {
      try {
        navigator.mediaDevices.getUserMedia = function(){
          return Promise.reject(new Error('Blocked by INK'));
        };
        navigator.mediaDevices.enumerateDevices = function(){
          return Promise.resolve([]);
        };
      } catch(e){}
    }
  } catch(e){}
})();
""";

/// Light anti-fingerprint: limit common high-entropy APIs used for tracking.
const String fingerprintGuardJs = r"""
(function(){
  try {
    // Stabilize canvas fingerprint noise without breaking pages.
    var toDataURL = HTMLCanvasElement.prototype.toDataURL;
    HTMLCanvasElement.prototype.toDataURL = function(){
      try {
        var ctx = this.getContext('2d');
        if (ctx) {
          var s = ctx.fillStyle;
          ctx.fillStyle = 'rgba(0,0,0,0.01)';
          ctx.fillRect(0,0,1,1);
          ctx.fillStyle = s;
        }
      } catch(e){}
      return toDataURL.apply(this, arguments);
    };
    // Reduce audio fingerprint surface.
    if (window.AudioContext || window.webkitAudioContext) {
      var AC = window.AudioContext || window.webkitAudioContext;
      var orig = AC.prototype.createAnalyser;
      AC.prototype.createAnalyser = function(){
        var a = orig.apply(this, arguments);
        try {
          var getFloat = a.getFloatFrequencyData.bind(a);
          a.getFloatFrequencyData = function(arr){
            getFloat(arr);
            for (var i=0;i<arr.length;i+=10){ arr[i] += (Math.random()*0.01); }
          };
        } catch(e){}
        return a;
      };
    }
  } catch(e){}
})();
""";

/// Force a basic dark palette on pages that ignore system dark mode.
const String forceDarkJs = r"""
(function(){
  if (window.__inkDark) return; window.__inkDark = true;
  var s=document.createElement('style');
  s.textContent='html,body{background:#121212!important;color:#E8E6DF!important}a{color:#E60012!important}img,video{opacity:.92}';
  (document.head||document.documentElement).appendChild(s);
})();
""";

/// Hide images and videos (used when "Load images" is disabled).
const String hideMediaJs = r"""
(function(){var s=document.createElement('style');s.textContent='img,picture,video{display:none!important}';(document.head||document.documentElement).appendChild(s);})();
""";

/// Desktop Chrome user-agent used when Desktop Mode is enabled.
const String desktopUserAgent =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
