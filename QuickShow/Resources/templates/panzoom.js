// Shared pan/zoom for SVG-rendered content (Mermaid + SVG renderers).
// Injected by WebViewPanelRenderer.loadTemplate via the <!--QS_PANZOOM-->
// marker. Pure vanilla — no dependencies — same posture as the rest
// of the in-template code.
//
// Public API on `window`:
//   __quickshow_install_panzoom(targetEl, opts?)
//     Reparents `targetEl` into a transform-wrapper div and installs
//     wheel/drag/dblclick handlers. Returns a controller object
//     `{ reset(), state() }` used by the QUICKSHOW_TEST_PANZOOM
//     smoke. opts: { minZoom = 0.25, maxZoom = 8 }.
//
// Behavior:
//   - Wheel    → zoom centered on cursor. Clamped to [minZoom, maxZoom].
//   - mousedown+drag → pan (translate). Always available, regardless
//     of zoom level.
//   - dblclick → reset to fit. fitZoom is min(containerW/contentW,
//     containerH/contentH), capped at 1.0 so we don't enlarge small
//     SVGs past their natural size.
//   - WKWebView trackpad pinches arrive as wheel events with
//     ctrlKey=true; the wheel handler covers them implicitly.

(function() {
  "use strict";

  if (typeof window === 'undefined') return;

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }

  function installPanZoom(targetEl, opts) {
    opts = opts || {};
    var minZoom = typeof opts.minZoom === 'number' ? opts.minZoom : 0.25;
    var maxZoom = typeof opts.maxZoom === 'number' ? opts.maxZoom : 8;

    var container = targetEl.parentElement;
    if (!container) {
      throw new Error('panzoom: targetEl has no parent');
    }

    // Reparent into a wrapper that we transform. The wrapper sits
    // inside the original parent at the same position the SVG used to.
    var wrap = document.createElement('div');
    wrap.className = 'qs-panzoom-wrap';
    wrap.style.position = 'relative';
    wrap.style.transformOrigin = '0 0';
    wrap.style.cursor = 'grab';
    wrap.style.userSelect = 'none';
    wrap.style.willChange = 'transform';
    container.insertBefore(wrap, targetEl);
    wrap.appendChild(targetEl);

    // Lift the SVG's responsive sizing — we want it at natural size so
    // our transform math is honest. Save originals so reset() can
    // restore if needed (we won't, but the data is captured).
    var origMaxWidth = targetEl.style.maxWidth;
    var origWidth = targetEl.style.width;
    var origHeight = targetEl.style.height;
    targetEl.style.maxWidth = 'none';
    // SVGs without explicit width/height + viewBox-only sometimes
    // collapse to zero size in a non-flex container. Read the
    // rendered size before reparent so we can keep it.
    var natW = targetEl.getBoundingClientRect().width || 200;
    var natH = targetEl.getBoundingClientRect().height || 200;
    targetEl.style.width = natW + 'px';
    targetEl.style.height = natH + 'px';

    var state = { zoom: 1, panX: 0, panY: 0 };

    function apply() {
      wrap.style.transform =
        'translate(' + state.panX + 'px, ' + state.panY + 'px) ' +
        'scale(' + state.zoom + ')';
    }

    function fitZoom() {
      // Use the renderer container (#qs-content's parent — body) as
      // the available area. This keeps fit honest as the HUD resizes.
      var available = container.getBoundingClientRect();
      var z = Math.min(available.width / natW, available.height / natH);
      return Math.min(1.0, z);
    }

    function reset() {
      var z = fitZoom();
      state.zoom = z;
      // Center within the container.
      var available = container.getBoundingClientRect();
      state.panX = (available.width - natW * z) / 2;
      state.panY = (available.height - natH * z) / 2;
      apply();
    }

    // Initial fit so the diagram lands centered + sized to the panel.
    reset();

    // ---------- wheel: zoom centered on cursor ----------
    function onWheel(ev) {
      ev.preventDefault();
      var rect = wrap.getBoundingClientRect();
      // Cursor in container-local coords.
      var cx = ev.clientX - container.getBoundingClientRect().left;
      var cy = ev.clientY - container.getBoundingClientRect().top;
      // Pre-zoom position in content-local coords (un-translated).
      var sx = (cx - state.panX) / state.zoom;
      var sy = (cy - state.panY) / state.zoom;
      // Zoom factor: WKWebView delivers trackpad pinches as wheel
      // events with deltaY in points; mice deliver larger deltas.
      // Normalize by capping the per-event multiplier.
      var factor = Math.exp(-ev.deltaY * 0.0025);
      var newZoom = clamp(state.zoom * factor, minZoom, maxZoom);
      // Pan so the same content point stays under the cursor.
      state.panX = cx - sx * newZoom;
      state.panY = cy - sy * newZoom;
      state.zoom = newZoom;
      apply();
    }

    // ---------- drag: pan ----------
    var dragging = false;
    var dragStart = { x: 0, y: 0, panX: 0, panY: 0 };
    function onMouseDown(ev) {
      if (ev.button !== 0) return;
      dragging = true;
      dragStart.x = ev.clientX;
      dragStart.y = ev.clientY;
      dragStart.panX = state.panX;
      dragStart.panY = state.panY;
      wrap.style.cursor = 'grabbing';
      ev.preventDefault();
    }
    function onMouseMove(ev) {
      if (!dragging) return;
      state.panX = dragStart.panX + (ev.clientX - dragStart.x);
      state.panY = dragStart.panY + (ev.clientY - dragStart.y);
      apply();
    }
    function onMouseUp(ev) {
      if (!dragging) return;
      dragging = false;
      wrap.style.cursor = 'grab';
    }

    // ---------- dblclick: reset ----------
    function onDblClick(ev) {
      ev.preventDefault();
      reset();
    }

    // Bind handlers. wheel binds to the container so events outside
    // the wrap (in the padding) still target this instance; the others
    // bind to the wrap itself.
    container.addEventListener('wheel', onWheel, { passive: false });
    wrap.addEventListener('mousedown', onMouseDown);
    // mousemove + mouseup bind to window so the drag continues if the
    // cursor leaves the wrap mid-drag (the user can release outside).
    window.addEventListener('mousemove', onMouseMove);
    window.addEventListener('mouseup', onMouseUp);
    wrap.addEventListener('dblclick', onDblClick);

    return {
      reset: reset,
      state: function() { return { zoom: state.zoom, panX: state.panX, panY: state.panY }; },
      // Test affordance — invoke the handlers directly without
      // dispatching real events (which is finicky inside WK from JS).
      _wheel: function(deltaY, clientX, clientY) {
        onWheel({ preventDefault: function() {}, deltaY: deltaY, clientX: clientX, clientY: clientY });
      },
      _resetForTest: function() { reset(); },
    };
  }

  window.__quickshow_install_panzoom = installPanZoom;
  // Module also exposes the latest controller so smoke tests can
  // poke at state via JS evaluate without DOM-traversing for it.
  window.__quickshow_panzoom_latest = null;
  var rawInstall = window.__quickshow_install_panzoom;
  window.__quickshow_install_panzoom = function(el, opts) {
    var ctrl = rawInstall(el, opts);
    window.__quickshow_panzoom_latest = ctrl;
    return ctrl;
  };
})();
