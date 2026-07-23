/**
 * Navigator — Remove Background + Trim (single image).
 * Driven by Navigator: opens the file passed as arguments[0], removes the
 * background (Photoshop's unified `removeBackground`), trims transparent pixels,
 * and saves. Falls back to the active document if run manually with no argument.
 *
 * Bundled inside Navigator.app — Navigator points Photoshop at it, so no one has
 * to keep this script in a specific place on disk.
 */

#target photoshop
app.bringToFront();

// `arguments` is injected by `do javascript ... with arguments {...}`. typeof is
// safe even when the identifier is absent (manual run). Capture before any
// function shadows it.
var TARGET = (typeof arguments !== "undefined" && arguments.length > 0) ? String(arguments[0]) : null;

function run() {
    var doc;
    if (TARGET) {
        doc = app.open(new File(TARGET));
    } else if (app.documents.length) {
        doc = app.activeDocument;
    } else {
        alert("No document open.");
        return;
    }

    var layer = doc.activeLayer;
    if (!(layer && layer.typename === "ArtLayer")) {
        // Flatten multi-layer/opened files down to a single pixel layer so
        // removeBackground has something to act on.
        try { doc.flatten(); layer = doc.activeLayer; }
        catch (e) { alert("Please select a pixel layer."); return; }
    }

    try {
        try { layer.isBackgroundLayer = false; } catch (e) {}
        var id = stringIDToTypeID("removeBackground");
        executeAction(id, new ActionDescriptor(), DialogModes.NO);
        doc.trim(TrimType.TRANSPARENT, true, true, true, true);
        if (TARGET) doc.save(); // save over the _rmbg copy Navigator made
    } catch (e) {
        alert("Remove Background and Trim failed:\n" + e.message);
    }
}

run();
