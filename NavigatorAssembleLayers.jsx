/**
 * Navigator — rebuild a layered PSD from a Layerize `_Layers` folder.
 *
 * Takes the folder Layerize produced (layer PNGs plus `_layers.json`) and assembles a real
 * Photoshop document: the base image on the bottom when there is one, then every separated element
 * as its own named layer, positioned and sized where it belongs.
 *
 * THE ONE THING THAT MATTERS HERE: a layer's PNG is NOT the size of its bounding box. Layerize
 * renders each element at its own resolution, so the bounding box is both the POSITION and the
 * TARGET SIZE and every layer has to be scaled into it. Measured on one real image (bluebird,
 * 2752x1536 canvas, 10 layers) the PNGs ran between 1.03x and 3.36x their boxes — the two control
 * clusters came back at 809x569 and 772x773 for boxes of 258x182 and 230x230. Dropping each PNG in
 * at native size is the obvious implementation and produces total garbage. Other images (frame,
 * 2477x1703) come back almost entirely 1:1, so BOTH cases have to work.
 *
 * Aspect drift between each render and its box measured under 1%, so scaling width and height
 * independently is exact rather than a distortion.
 *
 * THE SECOND THING: there is often NO base layer. Layerize only returns a usable one for a mostly
 * opaque input; for a mostly transparent input (cutouts, frame art) the "base" is an invented flat
 * colour rather than an inpainted background, so Navigator discards it as junk and the manifest has
 * no z_index 0 entry. The canvas is then recovered from the bounding boxes — see canvasFromBoxes.
 *
 * COORDINATES: `bounding_box.absolute` is [left, top, right, bottom] in the BASE IMAGE's coordinate
 * system, top-left origin — the same convention as Photoshop layer bounds, so it maps directly. The
 * canvas is the base's size, NOT the original source image's: `image_size: auto` renders at its own
 * resolution, so a 5504x3072 source can come back on a 2752x1536 canvas.
 *
 * Never calls alert() — an alert inside `do javascript` pops in Photoshop (invisible when the user
 * is in Navigator) AND blocks the automation call. Returns "OK: …" / "ERROR: …" instead, and a
 * partial rebuild says so in the OK line so Navigator can surface it.
 *
 * Bundled inside Navigator.app — Navigator points Photoshop at it.
 */

#target photoshop

// NOTE: never use `name`, `version` or `path` as variable names in a #target photoshop script. At
// global scope `this` is the Application, so `var name = ...` silently assigns to the read-only
// app.name and your variable keeps the value "Adobe Photoshop". That cost a debugging round once.

var LAYERS_DIR = (typeof arguments !== "undefined" && arguments.length > 0) ? String(arguments[0]) : ($.global.NAV_ARG  ? String($.global.NAV_ARG)  : null);
var OUTPUT     = (typeof arguments !== "undefined" && arguments.length > 1) ? String(arguments[1]) : ($.global.NAV_ARG2 ? String($.global.NAV_ARG2) : null);

// Run straight from Photoshop's File > Scripts menu there are no arguments at all, so ask for the
// folder and work out the output path the same way Navigator does. This is also the ONLY mode allowed
// to show an alert: from the menu a person is sitting there waiting for an answer, whereas an alert
// raised during Navigator's `do javascript` pops behind the app and blocks the automation forever.
var INTERACTIVE = (LAYERS_DIR === null);

/// Never overwrite an existing rebuild — mirrors PathRules.uniqueDest / LayerAssemblyRules.
function uniqueFile(dirPath, base, ext) {
    var f = new File(dirPath + "/" + base + ext);
    var n = 2;
    while (f.exists) { f = new File(dirPath + "/" + base + " " + n + ext); n++; }
    return f;
}

if (INTERACTIVE) {
    var picked = Folder.selectDialog("Choose a Layerize \u201c_Layers\u201d folder to rebuild");
    if (picked !== null) {
        LAYERS_DIR = picked.fsName;
        // Only a trailing "_Layers" is stripped, so a deduped folder keeps what distinguishes it:
        // "bluebird_Layers 2" -> "bluebird_Layers 2_assembled.psd". Same rule as the Swift side.
        var pickedName = decodeURI(picked.name).replace(/_Layers$/, "");
        if (pickedName === "") { pickedName = "assembled"; }
        else { pickedName = pickedName + "_assembled"; }
        OUTPUT = uniqueFile(picked.parent.fsName, pickedName, ".psd").fsName;
    }
}

// Whatever failed, STEP says where. It is set to the specific FILE while layers are being placed,
// so a failure names the layer instead of just the phase.
var STEP = "start";

/// Photoshop throws Error objects with a useful `line`, but a rethrown string or a DOM error object
/// may have neither — without this a failure reported "ERROR: [step] undefined".
function describe(e) {
    if (!e) { return "unknown error"; }
    var m = e.message ? String(e.message) : String(e);
    if (e.line) { m += " (jsx line " + e.line + ")"; }
    return m;
}

/// ExtendScript has no JSON object, so the manifest is eval'd. Safe here specifically because
/// Navigator wrote this file: layer names go through LayerizeRules.safeName, and JSON string
/// escaping is a subset of JavaScript's.
function readManifest(dir) {
    var fh = new File(dir + "/_layers.json");
    if (!fh.exists) { return null; }
    fh.encoding = "UTF-8";
    fh.open("r");
    var t = fh.read();
    fh.close();
    try {
        return eval("(" + t + ")");
    } catch (parseErr) {
        // A truncated manifest reports ") does not have a value" at jsx line 1, which points at
        // nothing useful. Say what is actually wrong and how big the file was.
        throw new Error("_layers.json is not valid JSON (" + t.length + " bytes read) \u2014 " +
                        (parseErr.message ? parseErr.message : String(parseErr)));
    }
}

/// Canvas size when there is no base PNG to measure. Every box carries the SAME rectangle in two
/// coordinate systems — `absolute` in base-image pixels and `normalized` in per-mille of the base —
/// so the base's size falls out of the ratio. Per-mille is coarse and fal computes it independently
/// rather than by rounding, so this lands 1-2px over on a 2477px canvas: the box nearest each edge
/// is used because it has the smallest relative error, and `absolute` sets a hard floor so a layer
/// can never be clipped. A pixel or two of transparent margin at right/bottom is the cost.
function canvasFromBoxes(manifest) {
    var w = 0, h = 0, estW = 0, estH = 0, nW = 0, nH = 0;
    for (var i = 0; i < manifest.length; i++) {
        var bb = manifest[i].bounding_box;
        if (!bb || !bb.absolute || bb.absolute.length !== 4) { continue; }
        var a = bb.absolute, n = bb.normalized;
        if (a[2] > w) { w = a[2]; }
        if (a[3] > h) { h = a[3]; }
        if (!n || n.length !== 4) { continue; }
        if (n[2] > nW) { nW = n[2]; estW = a[2] * 1000 / n[2]; }
        if (n[3] > nH) { nH = n[3]; estH = a[3] * 1000 / n[3]; }
    }
    if (w <= 0 || h <= 0) { return null; }
    return { w: Math.max(w, Math.round(estW)), h: Math.max(h, Math.round(estH)) };
}

// ===== SHARED WITH THE OTHER NAVIGATOR JSX — keep byte-identical (checked by rebuild.sh) =====
/// Open a file, cleaning up after Photoshop when it opens the document but fails the call that
/// returns it, and retrying once.
///
/// This is real observed behaviour, not a hypothetical. app.open throws "The command Get is not
/// currently available" while the document IS open — NavigatorRemoveBG.jsx hit the same thing and
/// once found nine hidden copies stacked up. Here it cascaded: four assembly retries left four
/// orphaned documents, after which even a known-good file would no longer open, so one flaky call
/// turned into a Photoshop that had to be cleaned out by hand.
///
/// The orphan is matched by FULL PATH, never by name — a document of the user's that merely shares
/// a filename must not be closed.
function openOrCleanUp(file) {
    for (var attempt = 0; attempt < 2; attempt++) {
        try {
            return app.open(file);
        } catch (e) {
            var target = file.fsName;
            for (var i = app.documents.length - 1; i >= 0; i--) {
                var full = null;
                try { full = app.documents[i].fullName ? app.documents[i].fullName.fsName : null; } catch (fe) {}
                if (full === target) {
                    try { app.documents[i].close(SaveOptions.DONOTSAVECHANGES); } catch (ce) {}
                    break;
                }
            }
            if (attempt === 1) { throw e; }
            $.sleep(400);          // the refusal is usually transient; give it a moment
        }
    }
}
// ===== END SHARED =====

/// Open a PNG, move its pixels into `doc` as a new top-of-stack layer, close the source.
/// Returns { layer, w, h } — the PNG's own pixel dimensions come back because they're the
/// denominator of the scale and the source document is gone by the time the caller needs them.
function importPNG(doc, file) {
    var srcDoc = openOrCleanUp(file);
    var placed = null, w = 0, h = 0;
    try {
        w = srcDoc.width.as("px");
        h = srcDoc.height.as("px");

        // An opaque PNG opens as a Background layer, which can't be renamed, moved or duplicated
        // normally. Layerize's cut-outs have alpha but a base is usually opaque, so this is real.
        var src = srcDoc.artLayers[0];
        if (src.isBackgroundLayer) { src.isBackgroundLayer = false; }

        // PLACEATBEGINNING is the TOP of the stack, so importing in ascending z order and always
        // placing at the beginning yields the correct bottom-to-top result.
        placed = src.duplicate(doc, ElementPlacement.PLACEATBEGINNING);
    } finally {
        // The source closes whether or not the duplicate worked. Photoshop has been seen to open a
        // file and then fail the call that returns it, and every retry stacked another hidden copy
        // (nine were once found piled up on the Remove BG path).
        try { srcDoc.close(SaveOptions.DONOTSAVECHANGES); } catch (cErr) {}
        try { app.activeDocument = doc; } catch (aErr) {}
    }
    // ONLY once `doc` is frontmost again. Photoshop rejects activeLayer on a document that isn't
    // frontmost with "requires that the target document is the frontmost document", and while the
    // source is still open the frontmost document is the source — moving this one statement earlier
    // failed all seven layers of a folder that had assembled cleanly a moment before.
    doc.activeLayer = placed;
    return { layer: placed, w: w, h: h };
}

/// Scale `entry`'s PNG to its bounding box and put its top-left corner at the box's top-left.
/// Returns false if the file is missing — old folders from before the empty-download fix have gaps,
/// and a gap is worth reporting rather than failing over. Throws if Photoshop refuses the file.
function placeLayer(doc, dir, entry) {
    if (!entry.file) { return false; }
    var f = new File(dir + "/" + entry.file);
    if (!f.exists) { return false; }

    var got = importPNG(doc, f);
    if (entry.name) { got.layer.name = entry.name; }

    var box = entry.bounding_box ? entry.bounding_box.absolute : null;
    if (!box || box.length !== 4) { return true; }
    var left = box[0], top = box[1];
    var boxW = box[2] - left, boxH = box[3] - top;
    if (boxW <= 0 || boxH <= 0) { return true; }

    if (got.w !== boxW || got.h !== boxH) {
        got.layer.resize((boxW / got.w) * 100, (boxH / got.h) * 100, AnchorPosition.TOPLEFT);
    }
    // A TOPLEFT anchor keeps the layer's own top-left fixed through the resize, but the move is
    // still measured from the actual post-resize bounds rather than assumed.
    var b = got.layer.bounds;
    got.layer.translate(left - b[0].as("px"), top - b[1].as("px"));
    return true;
}

function doWork() {
    var priorDialogs = app.displayDialogs;
    app.displayDialogs = DialogModes.NO;
    var priorUnits = app.preferences.rulerUnits;
    app.preferences.rulerUnits = Units.PIXELS;
    // Layers are often downscaled, sometimes by 3x, so the resample method is the difference
    // between a sharp rebuild and a mushy one. ArtLayer.resize has no interpolation argument and
    // reads this preference instead.
    var priorInterp = app.preferences.interpolation;
    app.preferences.interpolation = ResampleMethod.BICUBICSHARPER;

    // Declared out here so the catch can close it. Nothing else this run leaves a document open —
    // importPNG closes its source in a finally — so there is no need to sweep, and a sweep would be
    // actively dangerous: closing every unsaved document would discard the user's own work.
    var doc = null;

    try {
        if (!LAYERS_DIR) { throw new Error("no _Layers folder given"); }
        if (!OUTPUT) { throw new Error("no output path given"); }

        STEP = "readManifest";
        var manifest = readManifest(LAYERS_DIR);
        if (!manifest) { throw new Error("no _layers.json in " + LAYERS_DIR); }
        if (!manifest.length) { throw new Error("_layers.json describes no layers"); }
        manifest.sort(function (a, b) { return a.z_index - b.z_index; });

        STEP = "findBase";
        var baseEntry = null, missing = [], failed = [];
        for (var i = 0; i < manifest.length; i++) {
            if (manifest[i].z_index === 0 && !manifest[i].bounding_box) { baseEntry = manifest[i]; break; }
        }
        var baseFile = (baseEntry && baseEntry.file) ? new File(LAYERS_DIR + "/" + baseEntry.file) : null;
        if (baseFile && !baseFile.exists) {
            // The manifest promises a base that isn't on disk. Report it, then carry on sizing the
            // canvas from the boxes rather than throwing away the layers that ARE here.
            missing.push(baseEntry.file);
            baseEntry = null;
            baseFile = null;
        }

        STEP = "canvasSize";
        var canvasW, canvasH, dpi = 72;
        if (baseFile) {
            var probe = openOrCleanUp(baseFile);
            try {
                canvasW = probe.width.as("px");
                canvasH = probe.height.as("px");
                dpi = probe.resolution;
            } finally {
                try { probe.close(SaveOptions.DONOTSAVECHANGES); } catch (pErr) {}
            }
        } else {
            var c = canvasFromBoxes(manifest);
            if (!c) { throw new Error("no base layer, and no bounding boxes to size the canvas from"); }
            canvasW = c.w; canvasH = c.h;
        }

        STEP = "createDocument";
        doc = app.documents.add(canvasW, canvasH, dpi, "assembled",
                                NewDocumentMode.RGB, DocumentFill.TRANSPARENT);
        var placeholder = doc.artLayers[0];   // the empty layer documents.add always creates

        // One unreadable or un-resizable layer must not cost the rest of the rebuild, so each is
        // attempted separately and its own reason recorded. STEP names the file throughout, so even
        // a failure that escapes this loop points at one layer rather than at the whole phase.
        var placedCount = 0;
        if (baseFile) {
            STEP = "place base " + baseEntry.file;
            try {
                importPNG(doc, baseFile).layer.name = "base";
                placedCount++;
            } catch (baseErr) {
                failed.push(baseEntry.file + " \u2014 " + describe(baseErr));
            }
        }
        for (var n = 0; n < manifest.length; n++) {
            var e = manifest[n];
            if (e === baseEntry) { continue; }
            STEP = "place " + (e.file || "layer z" + e.z_index);
            try {
                if (placeLayer(doc, LAYERS_DIR, e)) { placedCount++; }
                else { missing.push(e.file || "(no file named for z" + e.z_index + ")"); }
            } catch (layerErr) {
                failed.push((e.file || "z" + e.z_index) + " \u2014 " + describe(layerErr));
            }
        }

        STEP = "verify";
        // Saving an empty transparent document and calling it OK would be worse than failing: the
        // user gets a PSD that looks like success and contains nothing.
        if (placedCount === 0) {
            throw new Error("nothing could be placed \u2014 " + missing.length + " missing, " +
                            failed.length + " failed" +
                            (failed.length ? ": " + failed.join("; ") : ""));
        }
        // Drop the empty layer the document was created with, now that real pixels are in. Cosmetic,
        // so a failure here is not worth losing the rebuild over.
        try { placeholder.remove(); } catch (phErr) {}

        STEP = "saveAs";
        app.activeDocument = doc;
        var opts = new PhotoshopSaveOptions();
        opts.layers = true;
        opts.embedColorProfile = true;
        doc.saveAs(new File(OUTPUT), opts, false, Extension.LOWERCASE);

        STEP = "close";
        doc.close(SaveOptions.DONOTSAVECHANGES);
        doc = null;

        app.preferences.interpolation = priorInterp;
        app.preferences.rulerUnits = priorUnits;
        app.displayDialogs = priorDialogs;
        // MISSING/FAILED are spelled out so Navigator can spot a partial rebuild in this one line
        // and put it in front of the user instead of only in the log. See LayerAssemblyRules.
        var msg = "OK: " + OUTPUT + " (" + canvasW + "x" + canvasH + ", " + placedCount + " layers";
        if (missing.length) { msg += "; MISSING " + missing.length + ": " + missing.join(", "); }
        if (failed.length) { msg += "; FAILED " + failed.length + ": " + failed.join(", "); }
        return msg + ")";
    } catch (e) {
        // Close only the document THIS run created, by identity. The sibling scripts learned to
        // match the exact document rather than sweeping: closing every unsaved document would take
        // the user's own unsaved work with it, which is far worse than a leaked temp document.
        if (doc !== null) { try { doc.close(SaveOptions.DONOTSAVECHANGES); } catch (cErr) {} }
        app.preferences.interpolation = priorInterp;
        app.preferences.rulerUnits = priorUnits;
        app.displayDialogs = priorDialogs;
        return "ERROR: [" + STEP + "] " + describe(e);
    }
}

var RESULT;
if (INTERACTIVE && LAYERS_DIR === null) {
    RESULT = "OK: cancelled";          // the folder dialog was dismissed; nothing to report
} else {
    try { RESULT = doWork(); } catch (e) { RESULT = "ERROR: [" + STEP + "] " + describe(e); }
}
// Only ever interactively — see the note on INTERACTIVE above.
if (INTERACTIVE && RESULT !== "OK: cancelled") {
    alert(RESULT.replace(/^OK: /, "Rebuilt:\n").replace(/^ERROR: /, "Couldn\u2019t rebuild:\n"));
}
RESULT;   // returned to osascript stdout so Navigator can report it
