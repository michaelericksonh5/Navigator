/**
 * Navigator — Remove Background + Trim (single image).
 * Photoshop opens the ORIGINAL (SOURCE), removes the background (unified
 * `removeBackground`), trims transparent edges, and saves the result as a
 * transparent PNG at OUTPUT ("<name>_rmbg.png"). The original is opened
 * read-only and never written.
 *
 * Never calls alert() — an alert inside `do javascript` pops in Photoshop
 * (invisible when the user is in Navigator) AND blocks the automation call.
 * Instead this RETURNS a status string ("OK: …" / "ERROR: …") that osascript
 * prints to stdout so Navigator can surface any failure.
 *
 * Bundled inside Navigator.app — Navigator points Photoshop at it.
 */

#target photoshop
// NOTE: no app.bringToFront() — Navigator runs Photoshop hidden, so we must not
// pull it to the foreground.

// Replace the file extension with .png (background removal needs an alpha format).
function pngPathFor(p) {
    var dot = p.lastIndexOf(".");
    var slash = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"));
    return (dot > slash && dot >= 0) ? (p.substring(0, dot) + ".png") : (p + ".png");
}

// SOURCE = original image to open; OUTPUT = where to save the keyed PNG. Passed
// via `with arguments` (arguments[0]/[1]) with a $.global fallback.
var SOURCE = (typeof arguments !== "undefined" && arguments.length > 0) ? String(arguments[0])
    : (($.global && $.global.NAV_ARG) ? String($.global.NAV_ARG) : null);
var OUTPUT = (typeof arguments !== "undefined" && arguments.length > 1) ? String(arguments[1])
    : (($.global && $.global.NAV_ARG2) ? String($.global.NAV_ARG2) : (SOURCE ? pngPathFor(SOURCE) : null));

// Which call we're on, so a failure names the step instead of just echoing
// Photoshop's generic "General Photoshop error occurred". Photoshop intermittently
// refuses one file in a long batch with 'The command "Get" is not currently
// available' and that message alone doesn't say WHICH call was refused — open,
// activeLayer, removeBackground, trim or saveAs. Navigator retries a failure now, so
// this exists to identify the real culprit if the retries ever run out.
var STEP = "start";

// Retry one fragile Photoshop call IN-PLACE, without re-opening the file.
//
// Photoshop intermittently refuses a call in a long batch with 'The command "Get" is
// not currently available' — it is briefly unable to service scripting, and the very
// next moment it is fine. Navigator also retries the whole script, but that re-opens
// and re-decodes the source (14 MB / 17 megapixels in real use), so retrying the
// single call that actually failed is both faster and far more likely to succeed for
// the right reason.
//
// app.refresh() between attempts is the important part, not just the sleep: it lets
// Photoshop pump its own event loop and finish whatever left it unable to answer.
function withRetry(fn, tries) {
    var total = tries || 3;
    var lastErr = null;
    for (var i = 0; i < total; i++) {
        try { return fn(); }
        catch (e) {
            lastErr = e;
            if (i < total - 1) {
                $.sleep(500 * (i + 1));
                try { app.refresh(); } catch (rErr) {}
            }
        }
    }
    throw lastErr;
}

function doWork() {
    var priorDialogs = app.displayDialogs;
    app.displayDialogs = DialogModes.NO;  // never let PS pop a modal that would hang us

    var doc;
    if (SOURCE) {
        STEP = "open";
        doc = app.open(new File(SOURCE));
    } else if (app.documents.length) {
        STEP = "activeDocument";
        doc = app.activeDocument;
    } else {
        app.displayDialogs = priorDialogs;
        return "ERROR: no document open";
    }

    try {
        // Reading activeLayer IS a `get`, which is precisely the call the transient
        // error names, so it goes through withRetry too.
        STEP = "activeLayer";
        var layer = withRetry(function () { return doc.activeLayer; });
        if (!(layer && layer.typename === "ArtLayer")) {
            STEP = "flatten";
            doc.flatten();
            layer = withRetry(function () { return doc.activeLayer; });
        }
        STEP = "unlockBackground";
        try { layer.isBackgroundLayer = false; } catch (bgErr) {}

        // Sensei's Remove Background requires 8-bit RGB. A 16-bit export, a CMYK or
        // grayscale file, or an indexed-colour PNG makes it fail with the same opaque
        // "General Photoshop error" — so normalise first. This is a no-op for the
        // ordinary case (already 8-bit RGB) and costs nothing there.
        STEP = "normalizeMode";
        try {
            if (doc.mode !== DocumentMode.RGB) { doc.changeMode(ChangeMode.RGB); }
            if (doc.bitsPerChannel !== BitsPerChannelType.EIGHT) {
                doc.bitsPerChannel = BitsPerChannelType.EIGHT;
            }
        } catch (mErr) {}

        // Photoshop's unified Remove Background (Sensei). The heaviest call in the
        // script and the most likely one to be refused mid-batch.
        STEP = "removeBackground";
        var id = stringIDToTypeID("removeBackground");
        withRetry(function () {
            executeAction(id, new ActionDescriptor(), DialogModes.NO);
        });

        STEP = "trim";
        try { doc.trim(TrimType.TRANSPARENT, true, true, true, true); } catch (tErr) {}

        // saveAs a NEW "<name>_rmbg.png" — the source is opened read-only and
        // never written. Explicit PNG (bare doc.save() on a PNG is unreliable).
        STEP = "saveAs";
        var saved = OUTPUT || pngPathFor(SOURCE);
        var opts = new PNGSaveOptions();
        try { opts.compression = 6; } catch (oErr) {}
        doc.saveAs(new File(saved), opts, true, Extension.LOWERCASE);
        STEP = "close";
        doc.close(SaveOptions.DONOTSAVECHANGES);  // discard changes to SOURCE

        app.displayDialogs = priorDialogs;
        return "OK: " + saved;
    } catch (e) {
        // Only ever closes the document THIS script opened — never the user's own
        // open documents, which may hold unsaved work.
        try { doc.close(SaveOptions.DONOTSAVECHANGES); } catch (cErr) {}
        app.displayDialogs = priorDialogs;
        return "ERROR: [" + STEP + "] " + e.message;
    }
}

// app.open can throw AFTER the document actually opened — seen live: a wedged
// Photoshop opened the file and then failed the internal Get that returns it, so
// `doc` in doWork was never assigned, its catch closed nothing, and every retry
// stacked another hidden open copy (9 were found piled up). Close exactly the file
// we were asked to open, matched by full path — never a user document that merely
// shares the name. Runs only when doWork failed at the open step.
function closeLeakedSource() {
    if (!SOURCE) { return; }
    try {
        for (var i = app.documents.length - 1; i >= 0; i--) {
            var full = null;
            try { full = app.documents[i].fullName ? app.documents[i].fullName.fsName : null; } catch (fErr) {}
            if (full === SOURCE) {
                app.documents[i].close(SaveOptions.DONOTSAVECHANGES);
                return;
            }
        }
    } catch (sweepErr) {}
}

var RESULT;
try { RESULT = doWork(); } catch (e) { RESULT = "ERROR: [" + STEP + "] " + e.message; }
if (RESULT && RESULT.indexOf("ERROR: [open]") === 0) { closeLeakedSource(); }
RESULT;  // returned to osascript stdout so Navigator can report it
