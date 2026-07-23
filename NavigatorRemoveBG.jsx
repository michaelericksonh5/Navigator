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
app.bringToFront();

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

function doWork() {
    var priorDialogs = app.displayDialogs;
    app.displayDialogs = DialogModes.NO;  // never let PS pop a modal that would hang us

    var doc;
    if (SOURCE) {
        doc = app.open(new File(SOURCE));
    } else if (app.documents.length) {
        doc = app.activeDocument;
    } else {
        app.displayDialogs = priorDialogs;
        return "ERROR: no document open";
    }

    try {
        var layer = doc.activeLayer;
        if (!(layer && layer.typename === "ArtLayer")) {
            doc.flatten();
            layer = doc.activeLayer;
        }
        try { layer.isBackgroundLayer = false; } catch (bgErr) {}

        // Photoshop's unified Remove Background (Sensei).
        var id = stringIDToTypeID("removeBackground");
        executeAction(id, new ActionDescriptor(), DialogModes.NO);

        try { doc.trim(TrimType.TRANSPARENT, true, true, true, true); } catch (tErr) {}

        // saveAs a NEW "<name>_rmbg.png" — the source is opened read-only and
        // never written. Explicit PNG (bare doc.save() on a PNG is unreliable).
        var saved = OUTPUT || pngPathFor(SOURCE);
        var opts = new PNGSaveOptions();
        try { opts.compression = 6; } catch (oErr) {}
        doc.saveAs(new File(saved), opts, true, Extension.LOWERCASE);
        doc.close(SaveOptions.DONOTSAVECHANGES);  // discard changes to SOURCE

        app.displayDialogs = priorDialogs;
        return "OK: " + saved;
    } catch (e) {
        try { doc.close(SaveOptions.DONOTSAVECHANGES); } catch (cErr) {}
        app.displayDialogs = priorDialogs;
        return "ERROR: " + e.message;
    }
}

var RESULT;
try { RESULT = doWork(); } catch (e) { RESULT = "ERROR: " + e.message; }
RESULT;  // returned to osascript stdout so Navigator can report it
