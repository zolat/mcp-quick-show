// QuickShow markup canvas — injected into every WebView via WKUserScript
// at .atDocumentEnd. Provides a transparent <canvas> overlay on top of
// the document content; freehand strokes are drawn INTO the DOM so they
// inherit the WebView's pan/zoom for free, and WKWebView.takeSnapshot
// includes them in the output PNG without a separate composite step.
//
// Surface: window.__qsMarkup
//   enterDrawMode()           — pointer-events: auto, capture pen input
//   exitDrawMode()            — pointer-events: none, restore passthrough
//   clear()                   — wipe all strokes, send strokesChanged
//   setStrokes(arr)           — replace stroke array (no message back —
//                               Swift called us, Swift already knows)
//   getStrokes()              — read current array
//   popLastStroke()           — undo (Cmd+Z), send strokesChanged
//   setColor(hex)             — seed DEFAULT_COLOR for new strokes
//   setWidth(px)              — seed DEFAULT_WIDTH for new strokes
//   setTool("draw"/"erase")   — switch pointer behaviour; erase splices
//                               strokes within ~12pt of the pointer
//   appendStrokeForTest(s)    — test hook; no message back
//
// Messages posted to webkit.messageHandlers.markupStroke:
//   {type: "strokesChanged", strokes: [...]}   — after every JS-initiated
//                                                change (pen up, Cmd+Z,
//                                                clear-on-JS-side never
//                                                actually fires since
//                                                clear is Swift-initiated)
//   {type: "escape"}                            — user hit Esc in draw mode
(function () {
    if (window.__qsMarkup) { return; }  // idempotent across re-injections

    var DEFAULT_COLOR = "#d8392c";
    var DEFAULT_WIDTH = 3;

    // Tool modes. `currentTool` flips between "draw" (new strokes via
    // pointer events) and "erase" (pointer events splice intersecting
    // strokes within `ERASE_RADIUS`). Set via `window.__qsMarkup.setTool`.
    var TOOL_DRAW = "draw";
    var TOOL_ERASE = "erase";
    var currentTool = TOOL_DRAW;
    var ERASE_RADIUS = 12;  // CSS pt; tolerant enough for a casual flick

    var canvas = null;
    var ctx = null;
    var strokes = [];
    var currentStroke = null;
    var drawing = false;
    var dpr = window.devicePixelRatio || 1;

    function ensureCanvas() {
        if (canvas && canvas.isConnected) { return; }
        canvas = document.createElement("canvas");
        canvas.id = "qs-markup";
        canvas.style.position = "absolute";
        canvas.style.top = "0";
        canvas.style.left = "0";
        canvas.style.pointerEvents = "none";
        canvas.style.zIndex = "2147483647";
        canvas.style.touchAction = "none";
        var host = document.body || document.documentElement;
        host.appendChild(canvas);

        canvas.addEventListener("pointerdown", onPointerDown);
        canvas.addEventListener("pointermove", onPointerMove);
        canvas.addEventListener("pointerup", onPointerUp);
        canvas.addEventListener("pointercancel", onPointerUp);

        resize();
    }

    function resize() {
        if (!canvas) { return; }
        var w = Math.max(
            document.documentElement.scrollWidth,
            document.documentElement.clientWidth
        );
        var h = Math.max(
            document.documentElement.scrollHeight,
            document.documentElement.clientHeight
        );
        // Backing store at devicePixelRatio for crisp strokes.
        var pw = Math.max(1, Math.floor(w * dpr));
        var ph = Math.max(1, Math.floor(h * dpr));
        if (canvas.width !== pw) { canvas.width = pw; }
        if (canvas.height !== ph) { canvas.height = ph; }
        canvas.style.width = w + "px";
        canvas.style.height = h + "px";
        ctx = canvas.getContext("2d");
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.scale(dpr, dpr);  // draw in CSS-pixel coords
        redraw();
    }

    function redraw() {
        if (!ctx) { return; }
        // clearRect needs raw pixel coords — undo the scale temporarily.
        ctx.save();
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        ctx.restore();
        for (var i = 0; i < strokes.length; i++) {
            drawStroke(strokes[i]);
        }
        if (currentStroke) {
            drawStroke(currentStroke);
        }
    }

    function drawStroke(s) {
        if (!s.points || s.points.length === 0) { return; }
        ctx.strokeStyle = s.color || DEFAULT_COLOR;
        ctx.lineWidth = s.width || DEFAULT_WIDTH;
        ctx.lineCap = "round";
        ctx.lineJoin = "round";
        ctx.beginPath();
        ctx.moveTo(s.points[0].x, s.points[0].y);
        for (var i = 1; i < s.points.length; i++) {
            ctx.lineTo(s.points[i].x, s.points[i].y);
        }
        ctx.stroke();
    }

    function pointFromEvent(e) {
        var rect = canvas.getBoundingClientRect();
        // rect is in viewport CSS pixels; pageX/Y is in document CSS
        // pixels. Use pageX/Y so strokes anchor to document content
        // regardless of scroll position.
        var sx = canvas.clientWidth / rect.width;   // = 1 unless zoomed by CSS
        var sy = canvas.clientHeight / rect.height;
        return {
            x: (e.pageX) * sx - canvas.offsetLeft,
            y: (e.pageY) * sy - canvas.offsetTop
        };
    }

    function onPointerDown(e) {
        if (canvas.style.pointerEvents !== "auto") { return; }
        e.preventDefault();
        canvas.setPointerCapture(e.pointerId);
        drawing = true;
        var p = pointFromEvent(e);
        if (currentTool === TOOL_ERASE) {
            eraseAt(p);
            return;
        }
        currentStroke = {
            points: [p],
            color: DEFAULT_COLOR,
            width: DEFAULT_WIDTH
        };
        redraw();
    }

    function onPointerMove(e) {
        if (!drawing) { return; }
        e.preventDefault();
        var p = pointFromEvent(e);
        if (currentTool === TOOL_ERASE) {
            eraseAt(p);
            return;
        }
        if (!currentStroke) { return; }
        currentStroke.points.push(p);
        redraw();
    }

    function onPointerUp(e) {
        if (!drawing) { return; }
        e.preventDefault();
        drawing = false;
        try { canvas.releasePointerCapture(e.pointerId); } catch (_) {}
        if (currentTool === TOOL_ERASE) {
            // Erase has no in-progress state — each pointerdown / move
            // already spliced strokes inline. Nothing to commit here.
            return;
        }
        if (currentStroke && currentStroke.points.length > 1) {
            strokes.push(currentStroke);
            currentStroke = null;
            redraw();
            postStrokesChanged();
        } else {
            currentStroke = null;
            redraw();
        }
    }

    // Walk strokes; splice any whose closest point lies within
    // `ERASE_RADIUS` of `p`. Coarse O(n*m) hit test — fine for the
    // small stroke counts the markup loop deals with.
    function eraseAt(p) {
        var removed = false;
        for (var i = strokes.length - 1; i >= 0; i--) {
            var s = strokes[i];
            var pts = s.points;
            var hit = false;
            for (var j = 0; j < pts.length; j++) {
                var dx = pts[j].x - p.x;
                var dy = pts[j].y - p.y;
                if (dx * dx + dy * dy <= ERASE_RADIUS * ERASE_RADIUS) {
                    hit = true;
                    break;
                }
            }
            if (hit) {
                strokes.splice(i, 1);
                removed = true;
            }
        }
        if (removed) {
            redraw();
            postStrokesChanged();
        }
    }

    function postStrokesChanged() {
        post({ type: "strokesChanged", strokes: strokes });
    }

    function post(msg) {
        try {
            if (window.webkit && webkit.messageHandlers
                && webkit.messageHandlers.markupStroke) {
                webkit.messageHandlers.markupStroke.postMessage(msg);
            }
        } catch (_) { /* host not ready */ }
    }

    function onKeyDown(e) {
        // Escape — host exits draw mode.
        if (e.key === "Escape") {
            post({ type: "escape" });
            return;
        }
        // Cmd+Z — pop last stroke + notify host.
        if (e.metaKey && (e.key === "z" || e.key === "Z")) {
            if (canvas && canvas.style.pointerEvents === "auto") {
                e.preventDefault();
                if (strokes.length > 0) {
                    strokes.pop();
                    redraw();
                    postStrokesChanged();
                }
            }
            return;
        }
    }

    document.addEventListener("keydown", onKeyDown, true);

    // Track document size changes — when responsive content reflows or
    // when the template's __quickshow_render swaps innerHTML, the
    // scrollWidth/Height shifts and the canvas needs to resize.
    var ro = null;
    function startObserver() {
        if (ro) { return; }
        try {
            ro = new ResizeObserver(function () { resize(); });
            ro.observe(document.documentElement);
        } catch (_) { /* older WebKit; fall back to no observer */ }
    }

    window.__qsMarkup = {
        enterDrawMode: function () {
            ensureCanvas();
            canvas.style.pointerEvents = "auto";
            canvas.style.cursor = "crosshair";
        },
        exitDrawMode: function () {
            if (!canvas) { return; }
            canvas.style.pointerEvents = "none";
            canvas.style.cursor = "";
            drawing = false;
            currentStroke = null;
            redraw();
        },
        clear: function () {
            strokes = [];
            currentStroke = null;
            redraw();
        },
        setStrokes: function (arr) {
            strokes = Array.isArray(arr) ? arr.slice() : [];
            currentStroke = null;
            ensureCanvas();
            redraw();
        },
        getStrokes: function () {
            return strokes;
        },
        popLastStroke: function () {
            if (strokes.length > 0) {
                strokes.pop();
                redraw();
            }
        },
        appendStrokeForTest: function (s) {
            ensureCanvas();
            strokes.push(s);
            redraw();
        },
        hasStrokes: function () {
            return strokes.length > 0;
        },
        // Stroke color/width pickers in the title bar call these.
        // Only seeds NEW strokes — in-progress strokes keep their
        // captured color/width, and committed strokes preserve theirs
        // (per-stroke fields persist in `strokes[]`). So switching mid-
        // session lets the user paint different annotations in different
        // colors without disturbing earlier ones.
        setColor: function (hex) {
            if (typeof hex === "string" && hex.length > 0) {
                DEFAULT_COLOR = hex;
            }
        },
        setWidth: function (px) {
            var n = Number(px);
            if (isFinite(n) && n > 0) {
                DEFAULT_WIDTH = n;
            }
        },
        // Tool switch driven by the title-bar eraser button.
        // Resets any in-progress stroke; updates the cursor hint
        // so the user sees the mode change immediately. Unknown
        // tool names are a no-op (defensive against future
        // additions on the Swift side).
        setTool: function (name) {
            if (name !== TOOL_DRAW && name !== TOOL_ERASE) { return; }
            currentTool = name;
            currentStroke = null;
            drawing = false;
            if (canvas) {
                canvas.style.cursor = (name === TOOL_ERASE)
                    ? "not-allowed"
                    : "crosshair";
            }
        },
        // Diagnostic: pixel dimensions of the canvas right now.
        canvasInfo: function () {
            ensureCanvas();
            return {
                cssWidth: canvas.clientWidth,
                cssHeight: canvas.clientHeight,
                pixelWidth: canvas.width,
                pixelHeight: canvas.height,
                strokeCount: strokes.length
            };
        }
    };

    function init() {
        ensureCanvas();
        startObserver();
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", init);
    } else {
        init();
    }

    // Signal Swift that `window.__qsMarkup` is fully installed and
    // ready to receive enterDrawMode / setTool / etc. Without this,
    // an autoEnterDrawMode call right after a fresh upsert can race
    // ahead of the user-script's installation (atDocumentEnd does not
    // strictly precede DOMContentLoaded under load), the
    // `window.__qsMarkup && ...` short-circuit drops the call, and
    // the title bar appears in draw mode while the canvas's
    // pointer-events stay `none` until the user manually toggles.
    try {
        if (window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.renderComplete) {
            window.webkit.messageHandlers.renderComplete.postMessage({
                markupReady: true
            });
        }
    } catch (_) { /* bridge missing in non-WKWebView contexts */ }
})();
