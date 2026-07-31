/**
 * Navigator — Quick Export as PNG (single file).
 * Photoshop opens the ORIGINAL (SOURCE, typically a .psd/.psb), flattens the
 * composite into an 8-bit RGB PNG, and saves it at OUTPUT. The original is
 * opened read-only and never written — same contract as Remove Background.
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

// SOURCE = original file to open; OUTPUT = where to save the PNG. Passed via
// `with arguments` (arguments[0]/[1]) with a $.global fallback.
var SOURCE = (typeof arguments !== "undefined" && arguments.length > 0) ? String(arguments[0])
    : (($.global && $.global.NAV_ARG) ? String($.global.NAV_ARG) : null);
var OUTPUT = (typeof arguments !== "undefined" && arguments.length > 1) ? String(arguments[1])
    : (($.global && $.global.NAV_ARG2) ? String($.global.NAV_ARG2) : null);

// Which call we're on, so a failure names the step instead of just echoing
// Photoshop's generic "General Photoshop error occurred" (same pattern as
// NavigatorRemoveBG.jsx, added there after a real batch failure couldn't say
// which call was refused).
var STEP = "start";

function doWork() {
    if (!SOURCE || !OUTPUT) { return "ERROR: missing SOURCE/OUTPUT arguments"; }
    var priorDialogs = app.displayDialogs;
    app.displayDialogs = DialogModes.NO;  // never let PS pop a modal that would hang us

    STEP = "open";
    var doc = app.open(new File(SOURCE));

    try {
        // PNG can't represent CMYK, and Quick Export's output is 8-bit — normalise
        // exactly like Remove BG does. No-op for the ordinary 8-bit RGB case.
        STEP = "normalizeMode";
        try {
            if (doc.mode !== DocumentMode.RGB) { doc.changeMode(ChangeMode.RGB); }
            if (doc.bitsPerChannel !== BitsPerChannelType.EIGHT) {
                doc.bitsPerChannel = BitsPerChannelType.EIGHT;
            }
        } catch (mErr) {}

        // saveAs writes the flattened composite for single-layer formats like PNG —
        // no explicit flatten needed, and transparency is preserved.
        STEP = "saveAs";
        var opts = new PNGSaveOptions();
        try { opts.compression = 6; } catch (oErr) {}
        doc.saveAs(new File(OUTPUT), opts, true, Extension.LOWERCASE);
        STEP = "close";
        doc.close(SaveOptions.DONOTSAVECHANGES);  // discard changes to SOURCE

        app.displayDialogs = priorDialogs;
        return "OK: " + OUTPUT;
    } catch (e) {
        // Only ever closes the document THIS script opened — never the user's own
        // open documents, which may hold unsaved work.
        try { doc.close(SaveOptions.DONOTSAVECHANGES); } catch (cErr) {}
        app.displayDialogs = priorDialogs;
        return "ERROR: [" + STEP + "] " + e.message;
    }
}

// app.open can throw AFTER the document actually opened — a wedged Photoshop was
// seen live opening the file and then failing the internal Get that returns it,
// leaving the document stacked up in the hidden session. Close exactly the file
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
