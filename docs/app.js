/* ============================================================================
   Smartii for Mac — site interactions
   1. bespoke WebGL aurora shader (fbm plasma) with graceful CSS fallback
   2. scroll-illuminated typography — words light up as you scroll, page pinned
   3. reveal-on-scroll, nav state, card spotlight, hero pointer light
   ========================================================================== */
(() => {
  "use strict";
  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ───────────────────────── 1. WebGL aurora ───────────────────────── */
  function initShader() {
    const cvs = document.getElementById("shader");
    if (!cvs) return;
    const gl = cvs.getContext("webgl2", { antialias: false, alpha: false, powerPreference: "low-power" });
    if (!gl) return; // keep the CSS gradient fallback

    const vert = `#version 300 es
      in vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }`;

    const frag = `#version 300 es
      precision highp float;
      out vec4 fragColor;
      uniform vec2 u_res;
      uniform float u_t;

      float hash(vec2 p){ p = fract(p*vec2(123.34,456.21)); p += dot(p, p+45.32); return fract(p.x*p.y); }
      float noise(vec2 p){
        vec2 i = floor(p), f = fract(p);
        vec2 u = f*f*(3.0-2.0*f);
        float a = hash(i), b = hash(i+vec2(1,0)), c = hash(i+vec2(0,1)), d = hash(i+vec2(1,1));
        return mix(mix(a,b,u.x), mix(c,d,u.x), u.y);
      }
      float fbm(vec2 p){ float v=0.0,a=0.5; for(int i=0;i<5;i++){ v+=a*noise(p); p*=2.02; a*=0.5; } return v; }

      void main(){
        vec2 uv = gl_FragCoord.xy / u_res.xy;
        vec2 p  = (uv - 0.5) * vec2(u_res.x/u_res.y, 1.0) * 3.0;
        float t = u_t * 0.04;
        vec2 q = vec2(fbm(p + vec2(0.0, t)), fbm(p + vec2(5.2, 1.3) - t));
        float f = fbm(p + q*1.8 + t*0.5);

        vec3 c1 = vec3(0.02, 0.02, 0.05);   // near-black
        vec3 c2 = vec3(0.20, 0.13, 0.50);   // indigo spark
        vec3 c3 = vec3(0.04, 0.34, 0.36);   // teal
        vec3 col = mix(c1, c2, smoothstep(0.15, 0.85, f));
        col = mix(col, c3, smoothstep(0.45, 1.0, q.x) * 0.45);
        col += c2 * pow(max(f - 0.55, 0.0), 2.0) * 1.2;   // soft hot cores

        float vig = smoothstep(1.25, 0.25, length(uv - 0.5));
        col *= vig;
        fragColor = vec4(col, 1.0);
      }`;

    const compile = (type, src) => {
      const s = gl.createShader(type);
      gl.shaderSource(s, src); gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) { console.warn(gl.getShaderInfoLog(s)); return null; }
      return s;
    };
    const vs = compile(gl.VERTEX_SHADER, vert), fs = compile(gl.FRAGMENT_SHADER, frag);
    if (!vs || !fs) return;
    const prog = gl.createProgram();
    gl.attachShader(prog, vs); gl.attachShader(prog, fs); gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return;
    gl.useProgram(prog);

    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 3,-1, -1,3]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, "p");
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

    const uRes = gl.getUniformLocation(prog, "u_res");
    const uT = gl.getUniformLocation(prog, "u_t");

    // canvas is rendered behind everything; CSS opacity blends it in
    cvs.style.background = "transparent";

    const dpr = Math.min(devicePixelRatio || 1, 1.5);
    function resize() {
      const w = Math.floor(innerWidth * dpr), h = Math.floor(innerHeight * dpr);
      if (cvs.width !== w || cvs.height !== h) { cvs.width = w; cvs.height = h; gl.viewport(0, 0, w, h); }
    }
    resize(); addEventListener("resize", resize, { passive: true });

    let running = true;
    document.addEventListener("visibilitychange", () => { running = !document.hidden; if (running && !reduce) loop(start); });
    let start = null;
    function loop(ts) {
      if (start === null) start = ts;
      gl.uniform2f(uRes, cvs.width, cvs.height);
      gl.uniform1f(uT, (ts - start) / 1000);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      if (running && !reduce) requestAnimationFrame(loop);
    }
    requestAnimationFrame(loop);
  }

  /* ─────────────────── 2. scroll-illuminated typography ─────────────────── */
  const stages = [];
  function buildStages() {
    document.querySelectorAll("[data-illuminate]").forEach((stage) => {
      const target = stage.querySelector("[data-words]");
      if (!target) return;
      const words = [];
      (function walk(node) {
        Array.from(node.childNodes).forEach((k) => {
          if (k.nodeType === 3) {                       // text node → wrap each word
            const parts = k.textContent.split(/(\s+)/);
            const frag = document.createDocumentFragment();
            parts.forEach((part) => {
              if (part === "" ) return;
              if (/^\s+$/.test(part)) { frag.appendChild(document.createTextNode(part)); return; }
              const s = document.createElement("span");
              s.className = "w"; s.textContent = part;
              frag.appendChild(s); words.push(s);
            });
            node.replaceChild(frag, k);
          } else if (k.nodeType === 1) {                // element
            if (k.classList.contains("stage-tag")) return; // leave eyebrows alone
            walk(k);                                    // recurse into .accent etc.
          }
        });
      })(target);
      stages.push({ el: stage, words });
    });
  }

  function paint() {
    const vh = innerHeight;
    for (const { el, words } of stages) {
      const r = el.getBoundingClientRect();
      const travel = el.offsetHeight - vh;
      const p = travel > 0 ? clamp(-r.top / travel, 0, 1) : 0;
      const n = words.length;
      const spread = 6;
      const head = p * (n - 1 + spread);
      for (let i = 0; i < n; i++) {
        const t = clamp((head - i) / spread, 0, 1);
        words[i].style.setProperty("--t", t.toFixed(3));
      }
    }
  }

  /* ───────────────────────── 3. reveal + interactions ───────────────────────── */
  function initReveals() {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e, i) => {
        if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
      });
    }, { threshold: 0.18, rootMargin: "0px 0px -8% 0px" });
    document.querySelectorAll(".reveal-up").forEach((el, i) => {
      if (el.closest(".in")) return;        // hero items already animate
      el.style.animationDelay = (i % 4) * 0.07 + "s";
      io.observe(el);
    });
  }

  function initNav() {
    const nav = document.getElementById("nav");
    const onScroll = () => nav.classList.toggle("scrolled", scrollY > 24);
    onScroll(); addEventListener("scroll", onScroll, { passive: true });
  }

  function initCards() {
    document.querySelectorAll(".card").forEach((card) => {
      card.addEventListener("pointermove", (e) => {
        const r = card.getBoundingClientRect();
        card.style.setProperty("--mx", (e.clientX - r.left) + "px");
        card.style.setProperty("--my", (e.clientY - r.top) + "px");
      });
    });
  }

  function initSpotlight() {
    const sp = document.getElementById("spotlight");
    if (!sp || reduce) return;
    addEventListener("pointermove", (e) => {
      sp.style.transform = `translate(${e.clientX}px, ${e.clientY}px)`;
      sp.style.opacity = scrollY < innerHeight ? "1" : "0";
    }, { passive: true });
  }

  /* ───────────────────────── boot ───────────────────────── */
  function boot() {
    initShader();
    buildStages();
    initReveals();
    initNav();
    initCards();
    initSpotlight();

    let ticking = false;
    const onScrollPaint = () => {
      if (ticking) return; ticking = true;
      requestAnimationFrame(() => { paint(); ticking = false; });
    };
    paint();
    addEventListener("scroll", onScrollPaint, { passive: true });
    addEventListener("resize", () => { paint(); }, { passive: true });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
