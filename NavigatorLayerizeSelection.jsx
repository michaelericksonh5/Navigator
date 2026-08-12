/**
 * Layerize Selection (AI) — split the selected area into real Photoshop layers, in place.
 *
 * Select an area and run this; with nothing selected it uses the whole canvas. The area is flattened,
 * sent to Seedream 5.0 Pro Layerize on fal.ai, and every element it separates comes back as its own
 * named layer inside a "Layerized" group, scaled and positioned exactly over the region you selected.
 * Your existing layers are untouched underneath.
 *
 * This is the in-Photoshop counterpart to Navigator's right-click Layerize. Navigator does the same
 * work from the Finder side and writes a folder plus a PSD; this one does it without leaving the
 * document you are already working in.
 *
 * HOW IT TALKS TO THE NETWORK: ExtendScript has no HTTP, so it shells out to curl via app.system()
 * and reads the response from a temp file — the same approach as AI_Image_Edit_Update.jsx on this
 * machine. curl is pre-installed on macOS and on Windows 10 1803+.
 *
 * THE PLACEMENT TRAP: a returned layer's PNG is NOT the size of its bounding box. Layerize renders
 * each element at its own resolution — measured between 1.03x and 3.36x its box within a single
 * image — so the box is both the POSITION and the TARGET SIZE and every layer must be scaled into it.
 * Dropping each PNG in at native size puts everything 2-3x too big and overlapping.
 *
 * COORDINATES: `bounding_box.absolute` is [left, top, right, bottom] in the returned BASE image's
 * pixel space, which is not the same size as what you sent (`image_size: auto` re-renders at its own
 * resolution). So boxes are scaled by selection-size / base-size before being placed.
 *
 * COST: fal bills this endpoint by compute second at $0.00017/s (fal's own pricing API). A call runs
 * roughly 2-3 minutes, so about 2-3 cents. Photoshop is frozen while curl runs — that is unavoidable
 * in ExtendScript, which is single-threaded.
 *
 * KEY: looked for in a FAL_KEY environment variable, then ~/.claude/settings.json -> env.FAL_KEY
 * (present on machines with the H5G plugins), then this script's own prefs file. If none of those
 * has one, it asks and remembers the answer. The key is NEVER written into this file — the script is
 * meant to be passed around, and the key must not travel with it.
 *
 * TO SHARE THIS: send the .jsx on its own. The recipient runs it, is asked for a fal.ai key once,
 * and it is saved to their own machine at Folder.userData/Navigator/fal_key.txt.
 */

#target photoshop

// Never use `name`, `version` or `path` as variable names in a #target photoshop script: at global
// scope `this` is the Application, so `var name = ...` silently assigns to the read-only app.name.

// ExtendScript has NO JSON object — verified: `typeof JSON` is "undefined" in Photoshop 27.11. Same
// polyfill approach as AI_Image_Edit_Update.jsx, with control characters escaped, which that one
// misses: an unescaped newline inside a string produces JSON the server rejects.
if (typeof JSON === "undefined") {
    JSON = {
        stringify: function (v) {
            if (v === null) { return "null"; }
            if (typeof v === "undefined") { return "null"; }
            if (typeof v === "string") {
                var s = v.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
                         .replace(/[\b]/g, "\\b").replace(/\f/g, "\\f").replace(/\n/g, "\\n")
                         .replace(/\r/g, "\\r").replace(/\t/g, "\\t");
                // Anything else below 0x20 is illegal raw in JSON.
                s = s.replace(/[\x00-\x1f]/g, function (c) {
                    var h = c.charCodeAt(0).toString(16);
                    return "\\u" + "0000".substring(h.length) + h;
                });
                return '"' + s + '"';
            }
            if (typeof v === "number") { return isFinite(v) ? String(v) : "null"; }
            if (typeof v === "boolean") { return v ? "true" : "false"; }
            if (v instanceof Array) {
                var a = [];
                for (var i = 0; i < v.length; i++) { a.push(JSON.stringify(v[i])); }
                return "[" + a.join(",") + "]";
            }
            var p = [];
            for (var k in v) {
                if (v.hasOwnProperty(k)) { p.push(JSON.stringify(String(k)) + ":" + JSON.stringify(v[k])); }
            }
            return "{" + p.join(",") + "}";
        },
        // eval is the only parser available without shipping a full tokeniser. The input is an HTTPS
        // response from fal, the same trust assumption the existing script makes.
        parse: function (text) {
            try { return eval("(" + text + ")"); }
            catch (e) { throw new Error("could not parse the response as JSON: " + e.message); }
        }
    };
}

var LAYERIZE_ENDPOINT = "https://fal.run/bytedance/seedream/v5/pro/layerize";
var UPLOAD_INITIATE   = "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3";
var IS_WINDOWS = ($.os.indexOf("Windows") !== -1);

// fal's documented input limits: total pixels between 512x512 and 6000x6000, aspect ratio between
// 1/16 and 16, file no larger than 30 MB. Checked before spending a call.
var MIN_PIXELS = 262144;
var MAX_PIXELS = 36000000;
var MAX_BYTES  = 30 * 1024 * 1024;

var TEMP_FILES = [];
var PROG = null;

// ---------------------------------------------------------------- small helpers

function progress(msg) {
    if (PROG === null) {
        PROG = new Window("palette", "Layerize Selection", undefined);
        PROG.line = PROG.add("statictext", undefined, "");
        PROG.line.preferredSize.width = 420;
        PROG.show();
    }
    PROG.line.text = msg;
    PROG.update();
}
function progressDone() { if (PROG !== null) { PROG.close(); PROG = null; } }

function tempFile(prefix, ext) {
    var f = new File(Folder.temp.fsName + "/" + prefix + "_" + (new Date().getTime()) +
                     "_" + Math.floor(Math.random() * 100000) + "." + ext);
    TEMP_FILES.push(f);
    return f;
}
function cleanupTemp() {
    for (var i = 0; i < TEMP_FILES.length; i++) {
        try { if (TEMP_FILES[i].exists) { TEMP_FILES[i].remove(); } } catch (e) {}
    }
    TEMP_FILES = [];
}

/// Run curl and return stdout as text. stderr is folded in so a transport failure is visible rather
/// than silently empty.
function curl(args) {
    var out = tempFile("curl_out", "txt");
    var cmd = IS_WINDOWS
        ? 'cmd.exe /c "curl.exe ' + args + ' > "' + out.fsName + '" 2>&1"'
        : 'curl ' + args + ' > "' + out.fsName + '" 2>&1';
    app.system(cmd);
    if (!out.exists) { return null; }
    out.encoding = "UTF-8";
    out.open("r");
    var txt = out.read();
    out.close();
    // JSON.parse chokes on a byte-order mark.
    if (txt && txt.charCodeAt(0) === 0xFEFF) { txt = txt.substring(1); }
    return txt;
}

// ---------------------------------------------------------------- the fal.ai key
//
// Looked for in three places, in order, so an H5G machine that already has one needs no setup and
// anyone else is asked once:
//   1. a FAL_KEY environment variable
//   2. ~/.claude/settings.json -> env.FAL_KEY   (shared by the H5G plugins; absent without them)
//   3. this script's own prefs file, written by the setup dialog below
//
// The key is NEVER written into this .jsx. The script gets passed around; the key must not travel
// with it.

function keyPrefsFile() {
    var folder = new Folder(Folder.userData.fsName + "/Navigator");
    if (!folder.exists) { folder.create(); }
    return new File(folder.fsName + "/fal_key.txt");
}

function readStoredKey() {
    try {
        var f = keyPrefsFile();
        if (!f.exists) { return null; }
        f.encoding = "UTF-8"; f.open("r");
        var t = f.read(); f.close();
        t = String(t).replace(/^\s+|\s+$/g, "");
        return t.length ? t : null;
    } catch (e) { return null; }
}

function storeKey(k) {
    try {
        var f = keyPrefsFile();
        f.encoding = "UTF-8"; f.open("w"); f.write(k); f.close();
        return true;
    } catch (e) { return false; }
}

function readClaudeSettingsKey() {
    var home = IS_WINDOWS ? $.getenv("USERPROFILE") : $.getenv("HOME");
    if (!home) { return null; }
    var f = new File(home + "/.claude/settings.json");
    if (!f.exists) { return null; }
    try {
        f.encoding = "UTF-8"; f.open("r");
        var txt = f.read(); f.close();
        var obj = JSON.parse(txt);
        return (obj && obj.env && obj.env.FAL_KEY) ? obj.env.FAL_KEY : null;
    } catch (e) { return null; }
}

/// Ask for a key and remember it. Returns the key, or null if cancelled.
function askForKey() {
    var w = new Window("dialog", "fal.ai key needed");
    w.alignChildren = "fill";
    w.margins = 16;
    w.add("statictext", undefined, "This script uses fal.ai to separate the image into layers.");
    var how = w.add("statictext", undefined,
        "1.  Sign in at  fal.ai/dashboard/keys\n" +
        "2.  Create an API key and copy it\n" +
        "3.  Paste it below — it is saved on this Mac only, in\n" +
        "     " + Folder.userData.fsName + "/Navigator/fal_key.txt\n\n" +
        "It is never written into this script, so the script is safe to share.",
        { multiline: true });
    how.preferredSize = [430, 96];
    // noecho so the key is not left on screen in a screen-share.
    var field = w.add("edittext", undefined, "", { noecho: true });
    field.preferredSize = [430, 24];
    var note = w.add("statictext", undefined,
        "At High 5, a key may already be set up for you — Cancel and ask, rather than making a second one.");
    note.graphics.font = ScriptUI.newFont(note.graphics.font.name, "italic", 10);

    var row = w.add("group"); row.alignment = "right";
    var cancel = row.add("button", undefined, "Cancel", { name: "cancel" });
    var save = row.add("button", undefined, "Save & Continue", { name: "ok" });
    var out = null;
    save.onClick = function () {
        var k = String(field.text).replace(/^\s+|\s+$/g, "");
        if (!k.length) { alert("Paste a key, or press Cancel."); return; }
        if (!storeKey(k)) { alert("Couldn't save the key — it will be used for this run only."); }
        out = k;
        w.close();
    };
    cancel.onClick = function () { out = null; w.close(); };
    w.show();
    return out;
}

/// The key, from whichever source has one. Prompts as a last resort.
function falKey() {
    var k = $.getenv("FAL_KEY");
    if (k) { return k; }
    k = readClaudeSettingsKey();
    if (k) { return k; }
    k = readStoredKey();
    if (k) { return k; }
    return askForKey();
}

/// Wipe a stored key that the server rejected, so the next run asks again instead of failing the
/// same way forever.
function forgetStoredKey() {
    try { var f = keyPrefsFile(); if (f.exists) { f.remove(); } } catch (e) {}
}

// The line that must be in EVERY prompt: without it fal returns names and descriptions in Chinese,
// and the layer names come straight from them. Never replaced by what the user types, only prepended.
var BASE_PROMPT = "Return name and description in english.";

/// Remembered between runs so a repeat is one Return away. A plain text file in the user's data
/// folder — Photoshop's own putCustomOptions needs an ActionDescriptor for no benefit here.
function promptPrefsFile() {
    return new File(Folder.userData.fsName + "/NavigatorLayerizeElements.txt");
}
function loadRememberedElements() {
    try {
        var f = promptPrefsFile();
        if (!f.exists) { return ""; }
        f.encoding = "UTF-8"; f.open("r");
        var t = f.read(); f.close();
        return t;
    } catch (e) { return ""; }
}
function rememberElements(t) {
    try {
        var f = promptPrefsFile();
        f.encoding = "UTF-8"; f.open("w"); f.write(t); f.close();
    } catch (e) {}
}

/// Ask what to separate. Returns the full prompt to send, or null if cancelled.
///
/// fal documents `prompt` as "instructions describing which elements to separate". Empty, the model
/// picks out "the major elements" — three or four blobs for a single character. Naming the parts is
/// what yields per-limb layers, left and right as separate ones.
function askElements() {
    var w = new Window("dialog", "Layerize Selection");
    w.alignChildren = "fill";
    w.margins = 16;

    w.add("statictext", undefined, "What should be separated into layers?");
    var hint = w.add("statictext", undefined,
        "Optional — the more specific, the better. Leave blank to let the model pick out\n" +
        "the major elements by itself.\n\n" +
        "e.g.  Separate guns, triggers, hands, and arms out from image",
        { multiline: true });
    hint.preferredSize = [420, 60];

    var field = w.add("edittext", undefined, loadRememberedElements(), { multiline: true });
    field.preferredSize = [420, 70];

    var foot = w.add("statictext", undefined,
        "“" + BASE_PROMPT + "” is always sent, so names come back in English.");
    foot.graphics.font = ScriptUI.newFont(foot.graphics.font.name, "italic", 10);

    var row = w.add("group");
    row.alignment = "right";
    var cancel = row.add("button", undefined, "Cancel", { name: "cancel" });
    var ok = row.add("button", undefined, "Layerize", { name: "ok" });
    var result = null;
    ok.onClick = function () {
        var t = String(field.text).replace(/^\s+|\s+$/g, "");
        rememberElements(t);
        // Someone pasting the whole prompt back in shouldn't get the base line twice.
        if (t.length === 0) { result = BASE_PROMPT; }
        else if (t.indexOf(BASE_PROMPT) === 0) { result = t; }
        else { result = BASE_PROMPT + "\n" + t; }
        w.close();
    };
    cancel.onClick = function () { result = null; w.close(); };
    w.show();
    return result;
}

function describe(e) {
    if (!e) { return "unknown error"; }
    var m = e.message ? String(e.message) : String(e);
    if (e.line) { m += " (jsx line " + e.line + ")"; }
    return m;
}

// ---------------------------------------------------------------- the work

/// Flatten the given rect of the document to a temp PNG, downsampling only if fal's pixel ceiling
/// demands it. Returns { file, w, h }.
function exportRegion(doc, x1, y1, x2, y2) {
    var cropDoc = null;
    try {
        // Merged copy of everything visible, exactly like AI_Image_Edit_Update does: duplicate the
        // whole document, then crop, so adjustment layers and blend modes are honoured.
        cropDoc = doc.duplicate("layerize_temp", true);
        cropDoc.crop([x1, y1, x2, y2]);

        var w = cropDoc.width.as("px"), h = cropDoc.height.as("px");
        if (w * h > MAX_PIXELS) {
            var ratio = Math.sqrt(MAX_PIXELS / (w * h));
            cropDoc.resizeImage(UnitValue(Math.floor(w * ratio), "px"),
                                UnitValue(Math.floor(h * ratio), "px"), null, ResampleMethod.BICUBICSHARPER);
            w = cropDoc.width.as("px"); h = cropDoc.height.as("px");
        }

        var f = tempFile("layerize_in", "png");
        var opts = new PNGSaveOptions();
        opts.compression = 6;
        cropDoc.saveAs(f, opts, true, Extension.LOWERCASE);
        cropDoc.close(SaveOptions.DONOTSAVECHANGES);
        cropDoc = null;
        return { file: f, w: w, h: h };
    } finally {
        if (cropDoc !== null) { try { cropDoc.close(SaveOptions.DONOTSAVECHANGES); } catch (e) {} }
        // duplicate() made the copy active; make sure the real document is frontmost again, because
        // every later placement asserts that and Photoshop refuses activeLayer otherwise.
        try { app.activeDocument = doc; } catch (e) {}
    }
}

/// Upload to fal's CDN and return the URL. Inlining as base64 inflates the body by ~4/3 and a 20 MB
/// image reliably lost the connection before the request landed, so uploading is the primary path.
/// Returns null on failure and the caller falls back to a data URI.
function uploadToFal(f, key) {
    // The initiate body goes in a temp file rather than inline: single-quoting a JSON literal on the
    // command line works in sh but cmd.exe passes the quotes through literally.
    var initBody = tempFile("upload_init", "json");
    initBody.encoding = "UTF-8";
    initBody.open("w");
    initBody.write(JSON.stringify({ content_type: "image/png", file_name: "layerize.png" }));
    initBody.close();

    var resp = curl('-s -S -X POST -H "Authorization: Key ' + key + '" ' +
                    '-H "Content-Type: application/json" "' + UPLOAD_INITIATE + '" ' +
                    '-d @"' + initBody.fsName + '"');
    if (!resp) { return null; }
    var j;
    try { j = JSON.parse(resp); } catch (e) { return null; }
    if (!j || !j.upload_url || !j.file_url) { return null; }

    // The PUT goes to a pre-signed URL and must NOT carry the API key. Body is discarded to a temp
    // file rather than /dev/null, which does not exist on Windows.
    var sink = tempFile("upload_put", "txt");
    var code = curl('-s -o "' + sink.fsName + '" -w "%{http_code}" -X PUT ' +
                    '-H "Content-Type: image/png" --data-binary @"' + f.fsName + '" "' +
                    j.upload_url + '"');
    if (!code || String(code).replace(/[\r\n]/g, "").indexOf("200") !== 0) { return null; }
    return j.file_url;
}

function base64DataURI(f) {
    var b64 = tempFile("layerize_b64", "txt");
    var cmd = IS_WINDOWS
        ? 'cmd.exe /c "certutil -encodehex -f "' + f.fsName + '" "' + b64.fsName + '" 0x40000001"'
        : 'base64 -i "' + f.fsName + '" -o "' + b64.fsName + '"';
    app.system(cmd);
    if (!b64.exists) { return null; }
    b64.open("r");
    var s = b64.read();
    b64.close();
    return "data:image/png;base64," + s.replace(/[\r\n]/g, "");
}

/// Ask fal to decompose the image. Returns the parsed `layers` array.
function requestLayerize(imageRef, key, promptText) {
    var payload = tempFile("layerize_payload", "json");
    payload.encoding = "UTF-8";
    payload.open("w");
    // Names come back in Chinese unless the prompt asks otherwise, and the layer names depend on it.
    payload.write(JSON.stringify({
        image_url: imageRef,
        image_size: "auto",
        prompt: promptText,
        enhance_prompt_mode: "standard"
    }));
    payload.close();

    var resp = curl('-s -S -X POST -H "Authorization: Key ' + key + '" ' +
                    '-H "Content-Type: application/json" -H "Accept: application/json" ' +
                    '"' + LAYERIZE_ENDPOINT + '" -d @"' + payload.fsName + '"');
    if (!resp) { throw new Error("no response from fal (is curl available?)"); }
    var j;
    try { j = JSON.parse(resp); } catch (e) {
        throw new Error("fal returned something that isn't JSON: " + resp.substring(0, 200));
    }
    if (j.detail) {
        // fal reports refusals under `detail`, sometimes as an array of field errors.
        var d = j.detail;
        var msg = (d instanceof Array && d.length && d[0].msg) ? d[0].msg : String(d);
        // A rejected key must not be kept, or every future run fails the same way with no way out.
        if (/unauthor|forbidden|invalid.*key|authentication/i.test(msg)) {
            forgetStoredKey();
            throw new Error(msg + "\n\nThat key was rejected, so it has been forgotten. " +
                            "Run the script again to enter a different one.");
        }
        throw new Error(msg);
    }
    if (!j.layers || !j.layers.length) { throw new Error("fal returned no layers"); }
    return j.layers;
}

function downloadTo(url, f) {
    curl('-s -S -L -o "' + f.fsName + '" "' + url + '"');
    // A PNG is 0x89 'P' 'N' 'G'. A zero-byte or HTML error body must not be treated as an image —
    // an empty download once got written, counted and recorded as a real layer.
    if (!f.exists || f.length < 100) { return false; }
    f.encoding = "BINARY";
    f.open("r");
    var sig = f.read(4);
    f.close();
    return sig.charCodeAt(0) === 0x89 && sig.substring(1) === "PNG";
}

/// Place one layer PNG into `doc`, scaled from base-image space into the target rect.
function placeLayer(doc, group, f, box, scaleX, scaleY, offsetX, offsetY, layerName) {
    var srcDoc = app.open(f);
    var placed = null;
    try {
        var src = srcDoc.artLayers[0];
        // An opaque PNG opens as a Background layer, which cannot be renamed, moved or duplicated.
        if (src.isBackgroundLayer) { src.isBackgroundLayer = false; }
        placed = src.duplicate(doc, ElementPlacement.PLACEATBEGINNING);
    } finally {
        try { srcDoc.close(SaveOptions.DONOTSAVECHANGES); } catch (e) {}
        try { app.activeDocument = doc; } catch (e) {}
    }
    // Only once `doc` is frontmost again: Photoshop rejects activeLayer on a document that is not
    // the frontmost one with "requires that the target document is the frontmost document".
    doc.activeLayer = placed;
    if (layerName) { placed.name = layerName; }
    placed.move(group, ElementPlacement.PLACEATBEGINNING);

    var targetW = (box[2] - box[0]) * scaleX;
    var targetH = (box[3] - box[1]) * scaleY;
    if (targetW < 1 || targetH < 1) { return placed; }

    var b0 = placed.bounds;
    var curW = b0[2].as("px") - b0[0].as("px");
    var curH = b0[3].as("px") - b0[1].as("px");
    if (curW > 0 && curH > 0) {
        placed.resize(targetW / curW * 100, targetH / curH * 100, AnchorPosition.TOPLEFT);
    }
    // Measured from the actual post-resize bounds rather than assumed.
    var b1 = placed.bounds;
    placed.translate(offsetX + box[0] * scaleX - b1[0].as("px"),
                     offsetY + box[1] * scaleY - b1[1].as("px"));
    return placed;
}

function run() {
    if (app.documents.length === 0) { alert("Open a document first."); return; }
    var doc = app.activeDocument;

    var priorUnits = app.preferences.rulerUnits;
    app.preferences.rulerUnits = Units.PIXELS;
    var priorDialogs = app.displayDialogs;
    app.displayDialogs = DialogModes.NO;
    var priorInterp = app.preferences.interpolation;
    // Every layer is scaled into its box, usually downwards, so this is the difference between a
    // sharp result and a mushy one. ArtLayer.resize has no interpolation argument.
    app.preferences.interpolation = ResampleMethod.BICUBICSHARPER;

    try {
        // Prompts for a key if none is configured; null means the user cancelled that dialog.
        var key = falKey();
        if (!key) { return; }

        // Asked before anything is flattened or uploaded, so Cancel costs nothing.
        var promptText = askElements();
        if (promptText === null) { return; }

        // Selection if there is one, otherwise the whole canvas.
        var x1 = 0, y1 = 0, x2 = doc.width.as("px"), y2 = doc.height.as("px");
        var usedSelection = false;
        try {
            var sb = doc.selection.bounds;      // throws when nothing is selected
            x1 = Math.round(sb[0].as("px")); y1 = Math.round(sb[1].as("px"));
            x2 = Math.round(sb[2].as("px")); y2 = Math.round(sb[3].as("px"));
            usedSelection = true;
        } catch (noSel) {}

        var selW = x2 - x1, selH = y2 - y1;
        if (selW < 4 || selH < 4) { alert("That selection is too small to layerize."); return; }
        if (selW * selH < MIN_PIXELS) {
            alert("Too small for Layerize.\n\nIt needs at least " + MIN_PIXELS +
                  " total pixels (about 512x512); this area is " + selW + "x" + selH + ".");
            return;
        }
        var aspect = selW / selH;
        if (aspect > 16 || aspect < 1 / 16) {
            alert("That area's aspect ratio (" + aspect.toFixed(2) +
                  ":1) is outside what Layerize accepts (1/16 to 16).");
            return;
        }

        progress("Flattening " + selW + "x" + selH + (usedSelection ? " selection" : " canvas") + "…");
        // Deselect so the duplicate/crop is not itself clipped by the marching ants.
        var savedSelection = null;
        if (usedSelection) {
            savedSelection = doc.channels.add();
            savedSelection.name = "Layerize_Selection";
            doc.selection.store(savedSelection);
            doc.selection.deselect();
        }
        var exported = exportRegion(doc, x1, y1, x2, y2);
        if (exported.file.length > MAX_BYTES) {
            throw new Error("the flattened area is " + Math.round(exported.file.length / 1048576) +
                            " MB, over fal's 30 MB limit — select a smaller area");
        }

        progress("Uploading " + Math.round(exported.file.length / 1048576 * 10) / 10 + " MB…");
        var imageRef = uploadToFal(exported.file, key);
        if (imageRef === null) {
            progress("Upload failed — inlining instead…");
            imageRef = base64DataURI(exported.file);
            if (imageRef === null) { throw new Error("could not upload or encode the image"); }
        }

        progress("Layerizing — this takes 2-3 minutes and Photoshop will be unresponsive…");
        var layers = requestLayerize(imageRef, key, promptText);

        // The base (z_index 0, no bounding box) defines the coordinate space every box is measured
        // in. It is downloaded to read its size but NOT inserted: your own artwork is already in the
        // document underneath, and for a transparent input the base is only a blank plate anyway.
        var baseEntry = null, elements = [];
        for (var i = 0; i < layers.length; i++) {
            var L = layers[i];
            var hasBox = (L.bounding_box && L.bounding_box.absolute && L.bounding_box.absolute.length === 4);
            if (!hasBox && baseEntry === null) { baseEntry = L; } else if (hasBox) { elements.push(L); }
        }
        if (!elements.length) { throw new Error("fal separated nothing out of that area"); }

        var canvasW = 0, canvasH = 0;
        if (baseEntry !== null && baseEntry.image && baseEntry.image.url) {
            progress("Measuring the returned canvas…");
            var baseFile = tempFile("layerize_base", "png");
            if (downloadTo(baseEntry.image.url, baseFile)) {
                var bd = app.open(baseFile);
                canvasW = bd.width.as("px"); canvasH = bd.height.as("px");
                bd.close(SaveOptions.DONOTSAVECHANGES);
                app.activeDocument = doc;
            }
        }
        if (canvasW <= 0 || canvasH <= 0) {
            // No base to measure: recover the canvas from the per-mille boxes, which describe the
            // same rectangles as `absolute` in thousandths of the base's size.
            var maxR = 0, maxB = 0, nW = 0, nH = 0, estW = 0, estH = 0;
            for (var k = 0; k < elements.length; k++) {
                var bb = elements[k].bounding_box;
                var a = bb.absolute, n = bb.normalized;
                if (a[2] > maxR) { maxR = a[2]; }
                if (a[3] > maxB) { maxB = a[3]; }
                if (n && n.length === 4) {
                    if (n[2] > nW) { nW = n[2]; estW = a[2] * 1000 / n[2]; }
                    if (n[3] > nH) { nH = n[3]; estH = a[3] * 1000 / n[3]; }
                }
            }
            canvasW = Math.max(maxR, Math.round(estW));
            canvasH = Math.max(maxB, Math.round(estH));
        }
        if (canvasW <= 0 || canvasH <= 0) { throw new Error("could not work out the returned canvas size"); }

        // Boxes are in the returned base's pixel space; the region on the canvas may be a different
        // size, so everything is scaled by region / base.
        var scaleX = selW / canvasW, scaleY = selH / canvasH;

        elements.sort(function (a, b) { return (a.z_index || 0) - (b.z_index || 0); });

        var group = doc.layerSets.add();
        group.name = "Layerized";

        var placed = 0, failed = [];
        for (var m = 0; m < elements.length; m++) {
            var e = elements[m];
            progress("Placing layer " + (m + 1) + " of " + elements.length +
                     (e.name ? " — " + e.name : "") + "…");
            var lf = tempFile("layerize_layer_" + m, "png");
            if (!e.image || !e.image.url || !downloadTo(e.image.url, lf)) {
                failed.push((e.name || ("layer " + m)) + " (download failed)");
                continue;
            }
            try {
                placeLayer(doc, group, lf, e.bounding_box.absolute, scaleX, scaleY, x1, y1, e.name);
                placed++;
            } catch (pe) {
                failed.push((e.name || ("layer " + m)) + " — " + describe(pe));
            }
        }

        if (savedSelection !== null) {
            try { doc.selection.load(savedSelection); savedSelection.remove(); } catch (se) {}
        }

        progressDone();
        var msg = "Added " + placed + " layer" + (placed === 1 ? "" : "s") + " in the “Layerized” group.";
        if (failed.length) { msg += "\n\n" + failed.length + " could not be placed:\n• " + failed.join("\n• "); }
        if (placed === 0) { msg = "Nothing could be placed.\n\n• " + failed.join("\n• "); }
        alert(msg);
    } catch (e) {
        progressDone();
        alert("Layerize failed:\n\n" + describe(e));
    } finally {
        progressDone();
        cleanupTemp();
        app.preferences.interpolation = priorInterp;
        app.preferences.rulerUnits = priorUnits;
        app.displayDialogs = priorDialogs;
    }
}

run();
