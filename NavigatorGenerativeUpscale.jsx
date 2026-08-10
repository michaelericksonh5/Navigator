/**
 * Navigator — Photoshop Generative Upscale (Adobe Firefly Upscaler).
 *
 * Photoshop opens the ORIGINAL read-only, pads it if its aspect is outside Generative
 * Upscale's supported band, plays the user's recorded upscale Action, crops the padding back
 * off, and saves an opaque PNG at OUTPUT. The original is never written.
 *
 * HOW THIS WAS FOUND (no ScriptingListener needed):
 * Guessing event names failed — ten plausible IDs all returned the generic "This functionality
 * may not be available in this version of Photoshop". Instead, Photoshop's registered
 * typeID→stringID table was walked backwards (`typeIDToStringID(1…120000)`) and searched, which
 * turned up the real names:
 *
 *     generativeUpscale   upscaleScale   upscaleCreativity
 *     upscaleModelId      upscaleFaceRecovery   upscaleModelVersion
 *
 * The numeric ids are deliberately NOT recorded here. They are assigned per install and MOVE:
 * generativeUpscale was 547 when this was written and is 568 today, upscaleScale 3196 -> 3220.
 * Everything below resolves names through stringIDToTypeID at runtime, which is why that churn
 * is harmless — but a reader who copied the old numbers into a descriptor would ship a bug.
 *
 * The earlier failure was passing an EMPTY ActionDescriptor: the event needs `upscaleScale`.
 * With it, the call succeeds — and Generative Upscale delivers its result as a **NEW document**
 * rather than resizing the current one, which is why a naive check on the source document's
 * dimensions makes a working call look like a no-op. Verified: 512×512 → a new
 * "<doc> Firefly Upscaler 2x scale" at 1024×1024.
 *
 * MODEL: Adobe's Firefly Upscaler, and only that one. The Model dropdown also lists Topaz
 * engines, but those are not licensed for use here, so this script must never select one.
 *
 * Firefly is Photoshop's DEFAULT, so no `upscaleModelId` is sent — passing nothing is both less
 * code and more robust than pinning a codename Adobe could rename. To make that safe rather
 * than assumed, the result document's name (Photoshop names it "<doc> <Model> Nx scale") is
 * CHECKED for "Firefly": if a future Photoshop ever changes the default, this fails loudly
 * instead of quietly upscaling through an unlicensed engine.
 *
 * "Unauthorized to perform request" is an ADOBE-SIDE refusal, not a bad descriptor. It is what
 * this event returns once generative credits / entitlement run out: the identical call that had
 * just produced three real results began failing with it, on both new and opened documents and
 * at both scales. Treat it as "check Photoshop's generative credits", never as a code fault —
 * retrying cannot fix it and each retry would spend another generation if it could.
 *
 * COST — settled against Adobe's own documentation, not a blog: the Firefly Upscaler is a
 * **STANDARD** feature and costs **1 credit per generation**. It is absent from Adobe's premium
 * feature table (which lists only "Generative Upscale ... using Partner Models") AND absent from
 * their "features that do not use generative credits" list, and standard features "use 1 credit
 * per generation".
 *
 * It is free ONLY on plans with "unlimited access to standard generations" — Creative Cloud Pro,
 * enterprise Edition 4 or above, Firefly and credit plans. Third-party write-ups calling it free
 * were describing those plans. On an enterprise plan without premium access the allowance is 25 a
 * month total, which is why this event returns "Unauthorized to perform request" once spent.
 *
 * Navigator therefore treats every run as costing a credit and confirms before spending — see
 * AdobeCreditRules / AdobeCredits in main.swift.
 *
 * WHY PADDING IS DONE HERE:
 * Photoshop refuses anything outside 1:4–4:1 ("Aspect ratio not supported. Please crop the
 * image to be tall or wide, between 1:4 and 4:1"), and refuses output over 6144px on either
 * side. Navigator preflights both (FireflyUpscaleRules) and only sends work that can succeed;
 * this script performs the padding it was told to do and undoes it afterwards.
 *
 * Never calls alert() — an alert inside `do javascript` pops in Photoshop (invisible when the
 * user is in Navigator) AND blocks the automation call. Returns "OK: …" / "ERROR: …" instead.
 *
 * Bundled inside Navigator.app — Navigator points Photoshop at it.
 */

#target photoshop
// No app.bringToFront() — Navigator runs Photoshop hidden and must not pull it forward.

// NOTE: never use `name`, `version` or `path` as variable names in a #target photoshop
// script. At global scope `this` is the Application, so `var name = ...` silently assigns to
// the read-only app.name and your variable keeps the value "Adobe Photoshop". That cost a
// confusing debugging round once already.

var SOURCE   = (typeof arguments !== "undefined" && arguments.length > 0) ? String(arguments[0]) : ($.global.NAV_ARG  ? String($.global.NAV_ARG)  : null);
var OUTPUT   = (typeof arguments !== "undefined" && arguments.length > 1) ? String(arguments[1]) : ($.global.NAV_ARG2 ? String($.global.NAV_ARG2) : null);
// 2 or 4. Photoshop rejects anything whose OUTPUT exceeds 6144px on either side, so Navigator
// preflights this (FireflyUpscaleRules) and only ever asks for a scale that can succeed.
var SCALE    = (typeof arguments !== "undefined" && arguments.length > 2) ? parseInt(String(arguments[2]), 10) : ($.global.NAV_ARG3 ? parseInt(String($.global.NAV_ARG3), 10) : 2);
// Canvas to pad to before upscaling ("WxH"), or "" for none. Computed by Navigator.
var PAD_TO   = (typeof arguments !== "undefined" && arguments.length > 3) ? String(arguments[3]) : ($.global.NAV_ARG4 ? String($.global.NAV_ARG4) : "");
// Backing colour for the padding as "RRGGBB" — chosen by Navigator's KeyColorRules so it
// never collides with a colour in the art.
var PAD_HEX  = (typeof arguments !== "undefined" && arguments.length > 4) ? String(arguments[4]) : ($.global.NAV_ARG5 ? String($.global.NAV_ARG5) : "00FF00");

var STEP = "start";
var MODEL_RAN = "";

// Retry one fragile Photoshop call in place. Photoshop intermittently refuses a call in a long
// batch with 'The command "Get" is not currently available'; app.refresh() between attempts is
// the part that matters, not the sleep. Same reasoning as NavigatorRemoveBG.jsx.
function withRetry(fn, tries) {
    var total = tries || 3, lastErr = null;
    for (var i = 0; i < total; i++) {
        try { return fn(); }
        catch (e) {
            lastErr = e;
            if (i < total - 1) { $.sleep(500 * (i + 1)); try { app.refresh(); } catch (rErr) {} }
        }
    }
    throw lastErr;
}

function hexToSolid(hex) {
    var c = new SolidColor();
    c.rgb.red   = parseInt(hex.substring(0, 2), 16);
    c.rgb.green = parseInt(hex.substring(2, 4), 16);
    c.rgb.blue  = parseInt(hex.substring(4, 6), 16);
    return c;
}

/// Fires Generative Upscale and returns the NEW document holding the result.
///
/// The result is a separate document — the source is left at its original size — so the caller
/// must switch to what this returns. `upscaleScale` is required; omitting it is what made an
/// empty descriptor look like an unsupported event.
function runUpscale(srcDoc) {
    var before = app.documents.length;
    var d = new ActionDescriptor();
    d.putInteger(stringIDToTypeID("upscaleScale"), SCALE);
    // No upscaleModelId: Firefly is the default and the only licensed engine here. Verified
    // against the result's name below rather than trusted.
    executeAction(stringIDToTypeID("generativeUpscale"), d, DialogModes.NO);
    if (app.documents.length <= before) { throw new Error("upscale produced no result document"); }
    var result = app.activeDocument;
    if (result === srcDoc) { throw new Error("upscale left the source active — no result document"); }
    return result;
}

function doWork() {
    var priorDialogs = app.displayDialogs;
    // Generative Upscale is a CLOUD round trip. displayDialogs = NO keeps Photoshop from
    // popping its dialog and deadlocking `do javascript`, which blocks until we return.
    app.displayDialogs = DialogModes.NO;
    var priorUnits = app.preferences.rulerUnits;
    app.preferences.rulerUnits = Units.PIXELS;

    if (!SOURCE) { app.displayDialogs = priorDialogs; return "ERROR: no source given"; }

    var doc = null;
    try {
        STEP = "open";
        doc = app.open(new File(SOURCE));

        STEP = "flatten";
        // Firefly upscaling flattens anyway, and a padded canvas needs one opaque layer so the
        // backing colour is real pixels rather than transparency. Navigator rebuilds the alpha
        // afterwards from the ORIGINAL file's alpha channel, so nothing is lost here.
        try { doc.flatten(); } catch (fErr) {}

        STEP = "normalizeMode";
        // Same normalisation the Remove BG path needs: a 16-bit, CMYK or indexed file fails
        // with an opaque "General Photoshop error". No-op for ordinary 8-bit RGB.
        try {
            if (doc.mode !== DocumentMode.RGB) { doc.changeMode(ChangeMode.RGB); }
            if (doc.bitsPerChannel !== BitsPerChannelType.EIGHT) { doc.bitsPerChannel = BitsPerChannelType.EIGHT; }
        } catch (mErr) {}

        var w0 = doc.width.as("px"), h0 = doc.height.as("px");
        var padX = 0, padY = 0;

        if (PAD_TO && PAD_TO.indexOf("x") > 0) {
            STEP = "pad";
            var parts = PAD_TO.split("x");
            var pw = parseInt(parts[0], 10), ph = parseInt(parts[1], 10);
            if (pw >= w0 && ph >= h0 && (pw > w0 || ph > h0)) {
                // Fill the new area with the colour Navigator picked. Extending the canvas
                // leaves transparency, so paint the backing on a layer UNDER the art.
                doc.resizeCanvas(new UnitValue(pw, "px"), new UnitValue(ph, "px"), AnchorPosition.MIDDLECENTER);
                var backing = doc.artLayers.add();
                backing.move(doc.layers[doc.layers.length - 1], ElementPlacement.PLACEAFTER);
                doc.activeLayer = backing;
                doc.selection.selectAll();
                doc.selection.fill(hexToSolid(PAD_HEX));
                doc.selection.deselect();
                doc.flatten();
                padX = Math.round((pw - w0) / 2);
                padY = Math.round((ph - h0) / 2);
            }
        }

        STEP = "generativeUpscale";
        // Cloud round trip: seconds to minutes. Navigator gives the AppleScript call a long
        // timeout to match, and a retry here would cost another generation, so this is NOT
        // wrapped in withRetry.
        var result = runUpscale(doc);
        MODEL_RAN = result.name;   // Photoshop names it "<doc> <Model> Nx scale"

        STEP = "verifyModel";
        // Refuse to ship a result from anything but Firefly. Topaz engines appear in the same
        // dropdown and are not licensed for this workflow, so a changed default must stop the
        // run rather than silently produce an asset we are not allowed to use.
        if (MODEL_RAN.indexOf("Firefly") < 0) {
            throw new Error("expected the Firefly Upscaler but Photoshop used a different model (result named \"" + MODEL_RAN + "\") — refusing to save it");
        }

        STEP = "verifyScale";
        // Derive the factor from what actually came back rather than trusting SCALE, so a
        // crop-back can never land in the wrong place.
        var padded = (padX > 0 || padY > 0);
        var srcW = padded ? (w0 + padX * 2) : w0;
        var w1 = result.width.as("px");
        var factor = srcW > 0 ? (w1 / srcW) : SCALE;

        if (padded) {
            STEP = "cropBack";
            // Crop the padding off the RESULT, scaled by the real factor. A crop, never a
            // resize, so it costs no sharpness.
            var left   = Math.round(padX * factor);
            var top    = Math.round(padY * factor);
            var right  = Math.round((padX + w0) * factor);
            var bottom = Math.round((padY + h0) * factor);
            app.activeDocument = result;
            result.crop([new UnitValue(left, "px"), new UnitValue(top, "px"),
                         new UnitValue(right, "px"), new UnitValue(bottom, "px")]);
        }

        STEP = "saveAs";
        var saved = OUTPUT;
        var opts = new PNGSaveOptions();
        try { opts.compression = 6; } catch (oErr) {}
        app.activeDocument = result;
        result.saveAs(new File(saved), opts, true, Extension.LOWERCASE);
        var outW = result.width.as("px"), outH = result.height.as("px");

        STEP = "closeResult";
        try { result.close(SaveOptions.DONOTSAVECHANGES); } catch (rErr) {}

        STEP = "close";
        doc.close(SaveOptions.DONOTSAVECHANGES);   // discard everything done to SOURCE

        app.preferences.rulerUnits = priorUnits;
        app.displayDialogs = priorDialogs;
        return "OK: " + saved + " (" + outW + "x" + outH + ", factor " + factor + ", model: " + MODEL_RAN + ")";
    } catch (e) {
        // Name the Adobe-side refusal explicitly so it never reads as a Navigator bug.
        var msg = String(e.message);
        if (msg.indexOf("Unauthorized to perform request") >= 0) {
            STEP = "generativeUpscale/entitlement";
        }
        // Close the upscale RESULT too if one was produced — an unsaved result left open is
        // exactly the leak that piled up nine hidden documents on the Remove BG path once.
        try {
            for (var z = app.documents.length - 1; z >= 0; z--) {
                var zd = app.documents[z], zsaved = true;
                try { zsaved = !!(zd.fullName && zd.fullName.fsName); } catch (zf) { zsaved = false; }
                if (!zsaved && zd !== doc) { try { zd.close(SaveOptions.DONOTSAVECHANGES); } catch (zc) {} }
            }
        } catch (sweepE) {}
        try { if (doc) { doc.close(SaveOptions.DONOTSAVECHANGES); } } catch (cErr) {}
        app.preferences.rulerUnits = priorUnits;
        app.displayDialogs = priorDialogs;
        return "ERROR: [" + STEP + "] " + e.message;
    }
}

// app.open can throw AFTER the document actually opened — seen live on the Remove BG path,
// where every retry stacked another hidden copy (9 were found piled up). Close exactly the
// file we were asked to open, matched by full path, never a user document sharing a name.
function closeLeakedSource() {
    if (!SOURCE) { return; }
    try {
        for (var i = app.documents.length - 1; i >= 0; i--) {
            var full = null;
            try { full = app.documents[i].fullName ? app.documents[i].fullName.fsName : null; } catch (fErr) {}
            if (full === SOURCE) { app.documents[i].close(SaveOptions.DONOTSAVECHANGES); return; }
        }
    } catch (sweepErr) {}
}

var RESULT;
try { RESULT = doWork(); } catch (e) { RESULT = "ERROR: [" + STEP + "] " + e.message; }
if (RESULT && RESULT.indexOf("ERROR: [open]") === 0) { closeLeakedSource(); }
RESULT;   // returned to osascript stdout so Navigator can report it
