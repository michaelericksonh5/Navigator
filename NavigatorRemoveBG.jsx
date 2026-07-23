/**
 * Navigator — Remove Background + Trim (single image).
 * Driven by Navigator: opens the file passed as arguments[0], removes the
 * background (Photoshop's unified `removeBackground`), trims transparent pixels,
 * and saves the result as a transparent PNG. Falls back to the active document
 * if run manually with no argument.
 *
 * IMPORTANT: never calls alert(). An alert inside `do javascript` pops in
 * Photoshop (invisible when the user is in Navigator) AND blocks the automation
 * call. Instead this returns a status string ("OK: ..." / "ERROR: ...") that
 * osascript prints to stdout so Navigator can surface it, and writes a
 * "<target>.rmbg.log" next to the image for post-mortem.
 *
 * Bundled inside Navigator.app — Navigator points Photoshop at it.
 */

#target photoshop
app.bringToFront();

var TARGET = (typeof arguments !== "undefined" && arguments.length > 0) ? String(arguments[0])
    : (($.global && $.global.NAV_ARG) ? String($.global.NAV_ARG) : null);

function logTo(path, msg) {
    try { var f = File(path); f.open("a"); f.write(msg + "\n"); f.close(); } catch (e) {}
}

// Replace the file extension with .png (background removal needs an alpha format).
function pngPathFor(p) {
    var dot = p.lastIndexOf(".");
    var slash = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"));
    return (dot > slash && dot >= 0) ? (p.substring(0, dot) + ".png") : (p + ".png");
}

function doWork() {
    var logPath = TARGET ? (TARGET + ".rmbg.log") : (Folder.desktop.fsName + "/rmbg.log");
    var priorDialogs = app.displayDialogs;
    app.displayDialogs = DialogModes.NO;  // never let PS pop a modal that would hang us
    logTo(logPath, "=== Remove BG start: " + (TARGET || "(active doc)") + " ===");

    var doc;
    if (TARGET) {
        doc = app.open(new File(TARGET));
    } else if (app.documents.length) {
        doc = app.activeDocument;
    } else {
        app.displayDialogs = priorDialogs;
        return "ERROR: no document open";
    }
    logTo(logPath, "Opened: " + doc.name + " " + doc.width.value + "x" + doc.height.value);

    try {
        var layer = doc.activeLayer;
        if (!(layer && layer.typename === "ArtLayer")) {
            doc.flatten();
            layer = doc.activeLayer;
        }
        try { layer.isBackgroundLayer = false; } catch (bgErr) {}

        // Photoshop's unified Remove Background (Sensei). Same call as the
        // original working script.
        var id = stringIDToTypeID("removeBackground");
        executeAction(id, new ActionDescriptor(), DialogModes.NO);
        logTo(logPath, "removeBackground executed");

        try {
            doc.trim(TrimType.TRANSPARENT, true, true, true, true);
            logTo(logPath, "trimmed transparent edges");
        } catch (tErr) {
            logTo(logPath, "trim skipped: " + tErr.message);
        }

        var saved = TARGET;
        if (TARGET) {
            // Explicit PNG save (bare doc.save() on a PNG is unreliable and was
            // the original failure). Flatten first so alpha bakes in cleanly.
            saved = pngPathFor(TARGET);
            var opts = new PNGSaveOptions();
            try { opts.compression = 6; } catch (oErr) {}
            doc.saveAs(new File(saved), opts, true, Extension.LOWERCASE);
            logTo(logPath, "saved PNG: " + saved);
            doc.close(SaveOptions.DONOTSAVECHANGES);
        }
        app.displayDialogs = priorDialogs;
        return "OK: " + saved;
    } catch (e) {
        logTo(logPath, "ERROR: " + e.message);
        try { doc.close(SaveOptions.DONOTSAVECHANGES); } catch (cErr) {}
        app.displayDialogs = priorDialogs;
        return "ERROR: " + e.message;
    }
}

var RESULT;
try { RESULT = doWork(); } catch (e) { RESULT = "ERROR: " + e.message; }
RESULT;  // returned to osascript stdout so Navigator can report it
