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
 *
 * TO REPLACE A SAVED KEY: hold Option while starting the script. A stored key is otherwise never
 * questioned again, so a rotated or mistyped-but-valid-looking one would need the file deleted by
 * hand.
 *
 * CONNECTIONS: the dialog has a Connections button. It shows where the fal.ai key came from and
 * lets you set or forget one, and it shows whether Vertex is signed in and can start that sign-in.
 * Claude's own settings are tried FIRST for both, so a machine with the H5G plugins needs nothing;
 * these controls exist for machines without them.
 *
 * THE LOG: every run writes a plain-text log to Documents/Navigator Layerize Logs, and its path is
 * in the final message. It records the document's layers, exactly what was sent (including whether
 * any transparency survived the flatten), fal's raw response verbatim, and the placement arithmetic
 * for every layer. ExtendScript offers no console and no stack from the Scripts menu, so without it
 * a bad run leaves no evidence at all. Tick "Keep images in the log folder" to also save what was
 * sent and every layer that came back.
 *
 * ANALYZE (optional, High 5 only): the dialog can ask Gemini what is worth separating in this
 * particular image and offer a few named plans. That runs on the company's metered Vertex service,
 * which is a browser sign-in rather than a key — so it needs the h5g-ai-connect skill installed and
 * `node client.mjs login` done once. Without it the button explains itself and everything else works
 * exactly as before: the fal.ai key and the typed element list are all layerizing has ever needed.
 * The service URL is read from the installed client, never written here, because this file is public.
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

// ---------------------------------------------------------------- the log
//
// Every run writes one. ExtendScript gives you no console, no breakpoints and no stack when a script
// is launched from the Scripts menu, so without this the only evidence of a bad run is whatever the
// person watching can describe — and "it put white over everything" has at least four possible
// causes that all look identical on screen. The log records what was in the document, exactly what
// was sent, exactly what came back, and the placement arithmetic for every layer.
//
// It is plain text in a folder you can open, and its path is named in the final message.

var LOG = [];
var LOG_FILE = null;
var KEEP_IMAGES = false;

function logFolder() {
    var docs = Folder.myDocuments;
    var f = new Folder(docs.fsName + "/Navigator Layerize Logs");
    if (!f.exists) { f.create(); }
    return f;
}

function stamp() {
    var d = new Date();
    function p(n) { return (n < 10 ? "0" : "") + n; }
    return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()) + "_" +
           p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds());
}

function logStart() {
    LOG = [];
    try { LOG_FILE = new File(logFolder().fsName + "/layerize_" + stamp() + ".txt"); }
    catch (e) { LOG_FILE = null; }
    log("Layerize Selection log");
    log("when:       " + (new Date()).toString());
    log("photoshop:  " + app.name + " " + app.version);
    log("os:         " + $.os);
    log("script:     " + (typeof $.fileName === "string" ? $.fileName : "(unknown)"));
    log("");
}

function log(line) {
    LOG.push(String(line));
    // Flushed on every line, not at the end: if Photoshop dies or a call never returns, the log up
    // to that point is the only thing that says where it stopped, and a log written at the end
    // would be exactly the log that never gets written.
    logFlush();
}

function logFlush() {
    if (LOG_FILE === null) { return; }
    try {
        LOG_FILE.encoding = "UTF-8";
        LOG_FILE.lineFeed = "Unix";
        LOG_FILE.open("w");
        LOG_FILE.write(LOG.join("\n") + "\n");
        LOG_FILE.close();
    } catch (e) { LOG_FILE = null; }      // a log that cannot be written must not break the run
}

/// Copy a file next to the log, so a bad image can be looked at instead of described. Only when the
/// person asked for it: layer PNGs run to several MB each.
function logKeep(f, asName) {
    if (!KEEP_IMAGES || f === null) { return; }
    try {
        var dest = new File(logFolder().fsName + "/" + stamp() + "_" + asName);
        f.copy(dest.fsName);
        log("    kept: " + dest.fsName);
    } catch (e) { log("    could not keep " + asName + ": " + e.message); }
}

/// A PNG's own header: dimensions and whether it carries alpha.
///
/// Read from the IHDR rather than asked of Photoshop, because this has to work on a file that was
/// just downloaded and never opened. Bytes 16-23 are width and height, big-endian; byte 25 is the
/// colour type, where 6 is RGBA and 4 is grey+alpha, and 0/2/3 carry no alpha at all.
function pngInfo(f) {
    try {
        if (!f || !f.exists) { return null; }
        f.encoding = "BINARY";
        f.open("r");
        var head = f.read(26);
        f.close();
        if (head.length < 26) { return null; }
        function be32(at) {
            return (head.charCodeAt(at) << 24) | (head.charCodeAt(at + 1) << 16) |
                   (head.charCodeAt(at + 2) << 8) | head.charCodeAt(at + 3);
        }
        var colourType = head.charCodeAt(25);
        return { w: be32(16), h: be32(20), colourType: colourType,
                 hasAlpha: (colourType === 4 || colourType === 6), bytes: f.length };
    } catch (e) { try { f.close(); } catch (ce) {} return null; }
}

function describePng(f) {
    var i = pngInfo(f);
    if (i === null) { return "not a readable PNG"; }
    return i.w + "x" + i.h + ", " + Math.round(i.bytes / 1024) + " KB, colour type " +
           i.colourType + (i.hasAlpha ? " (has alpha)" : " (NO alpha)");
}

/// Everything about the document that could explain a white result. Written before anything is
/// flattened, because after the flatten the evidence is gone.
function logDocument(doc) {
    log("document:   " + doc.name);
    log("  size:     " + doc.width.as("px") + " x " + doc.height.as("px") +
        "  mode=" + doc.mode + "  depth=" + doc.bitsPerChannel);
    log("  layers:   " + doc.layers.length + " at the top level");
    for (var i = 0; i < doc.layers.length; i++) {
        var L = doc.layers[i];
        var line = "    [" + i + "] " + L.name + "   " + L.typename +
                   "  visible=" + L.visible;
        try { line += "  opacity=" + Math.round(L.opacity) + "%"; } catch (e) {}
        try { line += "  blend=" + L.blendMode; } catch (e) {}
        try { if (L.isBackgroundLayer === true) { line += "  *** BACKGROUND LAYER (opaque) ***"; } } catch (e) {}
        try {
            var b = L.bounds;
            line += "  bounds=" + Math.round(b[0].as("px")) + "," + Math.round(b[1].as("px")) +
                    "," + Math.round(b[2].as("px")) + "," + Math.round(b[3].as("px"));
        } catch (e) {}
        log(line);
    }
    log("");
}

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
        "3.  Paste it below \u2014 it is saved on this Mac only, in\n" +
        "     " + Folder.userData.fsName + "/Navigator/fal_key.txt\n\n" +
        "It is never written into this script, so the script is safe to share.",
        { multiline: true });
    how.preferredSize = [430, 96];
    // noecho so the key is not left on screen in a screen-share.
    var field = w.add("edittext", undefined, "", { noecho: true });
    field.preferredSize = [430, 24];
    var note = w.add("statictext", undefined,
        "At High 5 a key may already be set up \u2014 Cancel and ask, rather than making a second one.\n" +
        "To replace this key later, hold Option while starting the script.",
        { multiline: true });
    note.preferredSize = [430, 30];
    note.graphics.font = ScriptUI.newFont(note.graphics.font.name, "italic", 10);

    var row = w.add("group"); row.alignment = "right";
    var cancel = row.add("button", undefined, "Cancel", { name: "cancel" });
    var save = row.add("button", undefined, "Save & Continue", { name: "ok" });
    var out = null;
    save.onClick = function () {
        var k = String(field.text).replace(/^\s+|\s+$/g, "");
        if (!k.length) { alert("Paste a key, or press Cancel."); return; }
        if (!storeKey(k)) { alert("Couldn't save the key \u2014 it will be used for this run only."); }
        out = k;
        w.close();
    };
    cancel.onClick = function () { out = null; w.close(); };
    w.show();
    return out;
}

/// True when Option/Alt is held as the script starts — the escape hatch for changing a stored key.
///
/// Without this the only ways out of a wrong-but-well-formed key are waiting for the server to
/// reject it or hand-editing a file in the Library, because a stored key is never questioned again.
function optionKeyHeld() {
    try { return ScriptUI.environment.keyboardState.altKey === true; } catch (e) { return false; }
}

/// The key, from whichever source has one. Prompts as a last resort, or on demand.
function falKey() {
    // Hold Option while launching the script to replace a saved key.
    if (optionKeyHeld() && readStoredKey() !== null) {
        var replaced = askForKey();
        if (replaced !== null) { return replaced; }
        // Cancelled out of the change dialog — carry on with what was already there.
    }
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

// ---------------------------------------------------------------- Analyze (Vertex, optional)
//
// A second, INDEPENDENT credential lives here, and the difference matters when something fails:
//
//   fal.ai  — an API key, required, does the actual layerizing.
//   Vertex  — a browser sign-in, OPTIONAL, only powers the "Analyze image" button.
//
// They fail separately and the dialog says which one is missing, because a coworker who sees
// "not signed in" next to a fal key they just pasted will otherwise assume the key is wrong.
//
// No service URL is written into this file: the repository is public. It is read from the installed
// h5g-ai-connect client, exactly as Navigator does, so a redeploy that moves the service needs no
// change here — and anyone without that client has no Vertex access to reach anyway.

var MAX_ELEMENTS = 16;   // fal returns "the base image followed by up to 16 separated layers"

function homeDir() { return IS_WINDOWS ? $.getenv("USERPROFILE") : $.getenv("HOME"); }

/// The Vertex session token, written by `node client.mjs login`. Null when not signed in.
function h5gToken() {
    try {
        var home = homeDir();
        if (!home) { return null; }
        var f = new File(home + "/.h5g-ai-gen/token.json");
        if (!f.exists) { return null; }
        f.encoding = "UTF-8"; f.open("r");
        var txt = f.read(); f.close();
        var j = JSON.parse(txt);
        return (j && j.token) ? j.token : null;
    } catch (e) { return null; }
}

/// The metered service's URL: the env var the client honours, else scraped out of the client itself.
function h5gServiceURL() {
    var env = $.getenv("H5G_AIGEN_URL");
    if (env) { return String(env).replace(/\/+$/, ""); }
    var home = homeDir();
    if (!home) { return null; }
    var candidates = [
        home + "/.claude/skills/h5g-ai-connect/client.mjs",
        home + "/Documents/h5g-ai-connect/skills/h5g-ai-connect/client.mjs",
        home + "/Downloads/claude-plugins-main/plugins/h5g-ai-connect/skills/h5g-ai-connect/client.mjs"
    ];
    var f = null;
    for (var i = 0; i < candidates.length; i++) {
        var c = new File(candidates[i]);
        if (c.exists) { f = c; break; }
    }
    if (f === null) { f = findClientInPluginCache(new Folder(home + "/.claude/plugins/cache"), 0); }
    if (f === null) { return null; }
    try {
        f.encoding = "UTF-8"; f.open("r");
        var src = f.read(); f.close();
        var at = src.indexOf("SERVICE_URL");
        if (at < 0) { return null; }
        var m = /https:\/\/[^"'\s]+/.exec(src.substring(at));
        return m ? m[0].replace(/\/+$/, "") : null;
    } catch (e) { return null; }
}

/// Plugin installs land under a versioned cache path, so the client has to be hunted for. Depth is
/// capped: this walks the user's plugin cache, and an unbounded walk of a deep tree would hang
/// Photoshop with no way to interrupt it.
function findClientInPluginCache(folder, depth) {
    if (depth > 6 || !folder || !folder.exists) { return null; }
    var items;
    try { items = folder.getFiles(); } catch (e) { return null; }
    for (var i = 0; i < items.length; i++) {
        var it = items[i];
        if (it instanceof File) {
            if (it.name === "client.mjs" && it.fsName.indexOf("h5g-ai-connect") !== -1) { return it; }
        } else if (it instanceof Folder) {
            var hit = findClientInPluginCache(it, depth + 1);
            if (hit !== null) { return hit; }
        }
    }
    return null;
}

/// Same brief Navigator gives the model, and for the same reasons.
///
/// Two earlier versions failed instructively. The first ordered elements "back to front (background
/// first)" and spent four of ten slots on sky, mountains, lake and boat hull — scenery layerize
/// hands back in the base for free. The second fixed that but kept fixed COUNTS per tier, so an
/// image with three genuinely useful pieces got padded to reach the number. Usefulness is not a
/// quantity, it is a purpose, so the model proposes named JOBS instead.
var PLAN_SYSTEM_PROMPT =
    "You plan how to split a flat 2D image into layers for a game-art pipeline.\n\n" +
    "HOW THE TOOL WORKS, and why it constrains you:\n" +
    "- It returns a BASE image plus AT MOST 16 named elements.\n" +
    "- Anything you do NOT name stays merged in the base, and the base is kept as the bottom\n" +
    "  layer. So the leftover background is ALWAYS returned \u2014 you never need to name it just to\n" +
    "  keep it.\n" +
    "- Name a background ONLY when it is a distinct designed plate someone would reuse or replace\n" +
    "  on its own (a symbol's backdrop, a parallax band), NOT when it is ambient scenery sitting\n" +
    "  behind UI.\n\n" +
    "Propose 1-4 DIFFERENT ways to split THIS image, each aimed at a real job someone would do:\n" +
    " - structure: the reusable compositional pieces (backdrop / frame / subject / UI chrome)\n" +
    " - extract:   lift the interactive or foreground items off a scene, leaving the scene whole\n" +
    " - animate:   split ONE subject into moving parts (limbs, jaw, fins, held objects)\n" +
    " - parallax:  split a background plate into depth bands\n" +
    " - inventory: one layer per repeated item in a sheet or grid\n" +
    "Only propose options that make sense for what you actually see. ONE option is a perfectly\n" +
    "good answer.\n\n" +
    "PICK ONE LEVEL PER THING inside any single option. Never list a container and its own parts\n" +
    "together \u2014 \"ornate frame with corner gems\" and \"top left corner gem\" cannot both be layers,\n" +
    "because the gems are inside the frame. The same goes for a subject: either the whole dragon\n" +
    "as one layer, or its head, jaw, claw and tail as several, never both.\n\n" +
    "RULES:\n" +
    "- NEVER pad a list to reach a number. Return only elements that genuinely earn their own\n" +
    "  layer. Three good elements beat eight with filler. Do not invent sub-parts nobody asked\n" +
    "  for.\n" +
    "- Order elements MOST VALUABLE FIRST; the list is truncated at 16.\n" +
    "- If a job would need more than 16 elements, still give the best 16 and set \"warning\".\n\n" +
    "Return STRICT JSON only, no prose, no markdown fence:\n" +
    "{\n" +
    "  \"kind\": \"<what this image is, short>\",\n" +
    "  \"options\": [\n" +
    "    {\"label\": \"<3-5 words>\", \"job\": \"structure|extract|animate|parallax|inventory\",\n" +
    "     \"why\": \"<one short line>\", \"elements\": [\"...\"], \"warning\": \"<optional>\"}\n" +
    "  ]\n" +
    "}\n" +
    "Order options best-first for this image.";

// ---------------------------------------------------------------- Connections
//
// Both credentials get one place you can open on purpose, rather than only being asked when
// something is already missing. There was previously no way at all to sign in to Vertex, and the
// only way to change a fal key was a keyboard trick nobody would find.
//
// Claude's own settings are still tried FIRST for both, so a machine with the H5G plugins needs no
// setup whatsoever. These controls are the fallback for a machine without them.

/// Where node lives.
///
/// Asking a shell is NOT good enough, which was proved the hard way. A Photoshop launched from the
/// Dock gets launchd's environment, and in a clean environment on this very machine `command -v
/// node` finds nothing in login bash, login zsh OR interactive zsh — because node is managed by nvm
/// and nvm is not initialised in any rc file. The first version of this reported "Node.js isn't
/// installed" on a machine running node 26, and it looked correct in testing only because that
/// Photoshop had inherited a developer shell's PATH.
///
/// So the version managers' own directories are searched directly, which is what Navigator's Swift
/// side already does. The shell is asked last, for machines where the rc files DO set it up.
function resolveNode() {
    var home = homeDir();
    var candidates = [];

    if (IS_WINDOWS) {
        candidates.push("C:\\Program Files\\nodejs\\node.exe");
        candidates.push("C:\\Program Files (x86)\\nodejs\\node.exe");
        if (home) { candidates.push(home + "\\AppData\\Roaming\\npm\\node.exe"); }
    } else {
        candidates.push("/opt/homebrew/bin/node");     // Apple silicon Homebrew
        candidates.push("/usr/local/bin/node");        // Intel Homebrew, and the .pkg installer
        candidates.push("/usr/bin/node");
        candidates.push("/opt/local/bin/node");        // MacPorts
        if (home) {
            candidates.push(home + "/.volta/bin/node");
            candidates.push(home + "/.local/bin/node");
            candidates.push(home + "/n/bin/node");
        }
    }

    // Version managers keep every release in its own directory, newest is not last alphabetically,
    // and a plain string sort puts v9 above v26. Compared numerically, component by component.
    if (home) {
        var roots = [
            { dir: home + "/.nvm/versions/node",                                  bin: "/bin/node" },
            { dir: home + "/Library/Application Support/fnm/node-versions",        bin: "/installation/bin/node" },
            { dir: home + "/.local/share/fnm/node-versions",                      bin: "/installation/bin/node" },
            { dir: home + "/.asdf/installs/nodejs",                                bin: "/bin/node" }
        ];
        for (var r = 0; r < roots.length; r++) {
            var found = newestNodeIn(roots[r].dir, roots[r].bin);
            if (found !== null) { candidates.push(found); }
        }
    }

    for (var i = 0; i < candidates.length; i++) {
        if (new File(candidates[i]).exists) { return candidates[i]; }
    }

    // Last resort: a shell that may have the version manager wired into its startup files.
    var shells = IS_WINDOWS
        ? ['cmd.exe /c "where node"']
        : ['/bin/zsh -lc "command -v node"', '/bin/bash -lc "command -v node"',
           '/bin/zsh -ic "command -v node"', '/bin/bash -ic "command -v node"'];
    for (var s = 0; s < shells.length; s++) {
        var out = tempFile("nodepath", "txt");
        app.system(shells[s] + ' > "' + out.fsName + '" 2>/dev/null');
        if (!out.exists) { continue; }
        out.open("r"); var t = out.read(); out.close();
        // An interactive shell can print noise ("no job control in this shell") before the answer,
        // so every line is considered rather than just the first.
        var lines = String(t).split(/[\r\n]+/);
        for (var L = 0; L < lines.length; L++) {
            var p = lines[L].replace(/^\s+|\s+$/g, "");
            if (p.length && new File(p).exists) { return p; }
        }
    }
    return null;
}

/// The highest-numbered node under a version manager's directory, or null.
function newestNodeIn(dir, binSuffix) {
    var f = new Folder(dir);
    if (!f.exists) { return null; }
    var items;
    try { items = f.getFiles(); } catch (e) { return null; }
    var bestPath = null, bestParts = null;
    for (var i = 0; i < items.length; i++) {
        if (!(items[i] instanceof Folder)) { continue; }
        var exe = new File(items[i].fsName + binSuffix);
        if (!exe.exists) { continue; }
        var parts = versionParts(items[i].name);
        if (bestParts === null || compareVersions(parts, bestParts) > 0) {
            bestParts = parts; bestPath = exe.fsName;
        }
    }
    return bestPath;
}

function versionParts(s) {
    var m = String(s).replace(/^v/i, "").split(".");
    var out = [];
    for (var i = 0; i < 3; i++) {
        var n = parseInt(m[i], 10);
        out.push(isNaN(n) ? 0 : n);
    }
    return out;
}

function compareVersions(a, b) {
    for (var i = 0; i < 3; i++) {
        if (a[i] !== b[i]) { return a[i] > b[i] ? 1 : -1; }
    }
    return 0;
}

/// The h5g-ai-connect client, which owns the Vertex sign-in. Null when the skill isn't installed.
function resolveH5GClient() {
    var home = homeDir();
    if (!home) { return null; }
    var candidates = [
        home + "/.claude/skills/h5g-ai-connect/client.mjs",
        home + "/Documents/h5g-ai-connect/skills/h5g-ai-connect/client.mjs",
        home + "/Downloads/claude-plugins-main/plugins/h5g-ai-connect/skills/h5g-ai-connect/client.mjs"
    ];
    for (var i = 0; i < candidates.length; i++) {
        var c = new File(candidates[i]);
        if (c.exists) { return c; }
    }
    return findClientInPluginCache(new Folder(home + "/.claude/plugins/cache"), 0);
}

/// Which source the fal key came from, without revealing the key itself.
function falKeySource() {
    if ($.getenv("FAL_KEY")) { return "the FAL_KEY environment variable"; }
    if (readClaudeSettingsKey()) { return "Claude's settings.json"; }
    if (readStoredKey()) { return "this script's saved key"; }
    return null;
}

/// Open the Vertex sign-in in a Terminal window, because the flow is a browser round trip that
/// needs a live console — Photoshop cannot host it, and a silent app.system would leave the person
/// staring at nothing while a browser tab waits for them somewhere behind Photoshop.
function startVertexSignIn() {
    var node = resolveNode();
    if (node === null) {
        return "Couldn't find Node.js, which the Vertex sign-in needs. If it is installed, run\n" +
               "  node " + (resolveH5GClient() === null ? "<client.mjs>" : resolveH5GClient().fsName) +
               " login\nin a Terminal yourself, then click Re-check. Layerizing does not use Vertex.";
    }
    var client = resolveH5GClient();
    if (client === null) {
        return "The h5g-ai-connect skill isn't on this Mac, so there's nothing to sign in to. " +
               "Analyze is a High 5 extra; everything else works with just a fal.ai key.";
    }
    try {
        if (IS_WINDOWS) {
            app.system('start "Vertex sign-in" cmd /k ""' + node + '" "' + client.fsName + '" login"');
        } else {
            // Run it from a script file: quoting a nested osascript/Terminal command inline is how
            // you get a command that works on one machine and not the next.
            var sh = new File(Folder.temp.fsName + "/navigator_vertex_login.command");
            sh.encoding = "UTF-8"; sh.lineFeed = "Unix"; sh.open("w");
            sh.write('#!/bin/bash\n"' + node + '" "' + client.fsName + '" login\n' +
                     'echo\necho "You can close this window and click Re-check in Photoshop."\n');
            sh.close();
            app.system('chmod +x "' + sh.fsName + '"');
            app.system('open -a Terminal "' + sh.fsName + '"');
        }
    } catch (e) { return "Couldn't start the sign-in: " + e.message; }
    return null;
}

/// The connections panel: what is configured, and how to change it.
function showConnections() {
    var w = new Window("dialog", "Layerize Connections");
    w.alignChildren = "fill";
    w.margins = 16;

    var falPanel = w.add("panel", undefined, "fal.ai  \u2014  required, does the layerizing");
    falPanel.alignChildren = "fill";
    falPanel.margins = 12;
    var falStatus = falPanel.add("statictext", undefined, "", { truncate: "middle" });
    falStatus.preferredSize.width = 440;
    var falRow = falPanel.add("group");
    var setKey = falRow.add("button", undefined, "Set key\u2026");
    var forgetKey = falRow.add("button", undefined, "Forget saved key");

    var vxPanel = w.add("panel", undefined, "Vertex  \u2014  optional, only powers Analyze image");
    vxPanel.alignChildren = "fill";
    vxPanel.margins = 12;
    // 62px, because a multiline statictext does not grow to fit and these messages run to three
    // lines at 440 wide - the first version cut off mid-sentence.
    var vxStatus = vxPanel.add("statictext", undefined, "", { multiline: true });
    vxStatus.preferredSize = [440, 62];
    var vxRow = vxPanel.add("group");
    var signIn = vxRow.add("button", undefined, "Sign in to Vertex\u2026");
    var recheck = vxRow.add("button", undefined, "Re-check");

    function refresh() {
        var src = falKeySource();
        falStatus.text = (src === null) ? "No key set \u2014 layerizing cannot run without one."
                                        : "Key found in " + src + ".";
        forgetKey.enabled = (readStoredKey() !== null);

        var tok = h5gToken(), url = h5gServiceURL();
        if (tok !== null && url !== null) {
            vxStatus.text = "Signed in. Analyze is available.";
        } else if (resolveH5GClient() === null) {
            vxStatus.text = "The h5g-ai-connect skill isn't installed, so Analyze is unavailable.\n" +
                            "Everything else works with just a fal.ai key.";
        } else if (tok === null) {
            vxStatus.text = "Not signed in. Sign in once and it lasts about 30 days.";
        } else {
            vxStatus.text = "Signed in, but the service address couldn't be read from the\n" +
                            "installed client. Analyze is unavailable; layerizing is unaffected.";
        }
        signIn.enabled = (resolveH5GClient() !== null);
    }
    refresh();

    setKey.onClick = function () { if (askForKey() !== null) { refresh(); } };
    forgetKey.onClick = function () { forgetStoredKey(); refresh(); };
    signIn.onClick = function () {
        var err = startVertexSignIn();
        vxStatus.text = (err === null)
            ? "A Terminal window is finishing the sign-in. Pick your @high5games.com\n" +
              "account in the browser, then click Re-check."
            : err;
    };
    recheck.onClick = refresh;

    var foot = w.add("group");
    foot.alignment = "right";
    foot.add("button", undefined, "Done", { name: "ok" });
    w.show();
}

/// Record the credential situation in the log, without ever writing a key or token into it.
function logConnections() {
    log("connections:");
    var src = falKeySource();
    log("  fal.ai key:   " + (src === null ? "NOT SET" : "found in " + src));
    var home = homeDir();
    log("  home dir:     " + (home ? home : "*** $.getenv could not resolve it ***"));
    var client = resolveH5GClient();
    log("  h5g client:   " + (client === null ? "not installed" : client.fsName));
    var node = resolveNode();
    log("  node:         " + (node === null ? "NOT FOUND" : node));
    log("  PATH:         " + ($.getenv("PATH") || "(empty)"));
    log("  vertex token: " + (h5gToken() === null ? "not signed in" : "present"));
    var url = h5gServiceURL();
    log("  service url:  " + (url === null ? "could not be resolved" : "resolved"));
    log("  analyze:      " + ((h5gToken() !== null && url !== null) ? "available" : "unavailable"));
    log("");
}

/// A gateway hiccup, not a real refusal — worth retrying rather than reporting. Observed live: the
/// vision endpoint answered `HTTP 502: {"error":"Vertex 502: <!DOCTYPE html>…` mid-session.
function isTransientError(msg) {
    var e = String(msg).toLowerCase();
    var marks = ["http 502", "http 503", "http 504", "http 429", "timed out", "timeout",
                 "connection was lost", "network connection", "bad gateway", "temporarily unavailable"];
    for (var i = 0; i < marks.length; i++) { if (e.indexOf(marks[i]) !== -1) { return true; } }
    return false;
}

/// Something a person can read in one line of status. The service wraps upstream failures in JSON
/// containing a whole HTML error page.
function friendlyError(msg) {
    if (isTransientError(msg)) { return "the AI service is busy \u2014 try Analyze again in a moment"; }
    var s = String(msg);
    var cut = s.indexOf("<!DOCTYPE");
    if (cut < 0) { cut = s.indexOf("<html"); }
    if (cut >= 0) { s = s.substring(0, cut); }
    s = s.replace(/^[\s{}"\\:,]+|[\s{}"\\:,]+$/g, "");
    return s.length > 140 ? s.substring(0, 140) + "\u2026" : s;
}

/// Parse the model's reply into { kind, options:[{label,job,why,elements,warning}] }.
/// Tolerates a ```json fence and surrounding prose, because "STRICT JSON only" is an instruction,
/// not a guarantee.
function parsePlan(reply) {
    var s = String(reply);
    var a = s.indexOf("{"), b = s.lastIndexOf("}");
    if (a < 0 || b <= a) { return null; }
    var obj;
    try { obj = JSON.parse(s.substring(a, b + 1)); } catch (e) { return null; }
    if (!obj || !obj.options || !obj.options.length) { return null; }
    function str(o, k) { return (o && typeof o[k] === "string") ? o[k].replace(/^\s+|\s+$/g, "") : ""; }
    var options = [];
    for (var i = 0; i < obj.options.length; i++) {
        var o = obj.options[i];
        var els = [];
        var raw = (o && o.elements instanceof Array) ? o.elements : [];
        for (var j = 0; j < raw.length; j++) {
            if (typeof raw[j] === "string") {
                var t = raw[j].replace(/^\s+|\s+$/g, "");
                if (t.length) { els.push(t); }
            }
        }
        if (!els.length) { continue; }          // an option that separates nothing is noise
        options.push({ label: str(o, "label"), job: str(o, "job"), why: str(o, "why"),
                       elements: els, warning: str(o, "warning") });
    }
    if (!options.length) { return null; }
    return { kind: str(obj, "kind"), options: options };
}

/// What the popup shows. Counts the BASE: naming N elements yields N+1 layers, because everything
/// unnamed comes back merged as the bottom layer. Reporting "2 layers" for a run that produced
/// three made it look like the background had been missed, when the background was layer one.
function optionTitle(o) {
    return (o.label.length ? o.label : o.job) + "  (" + (o.elements.length + 1) + " layers)";
}

/// Turn element names into the instruction sent to fal as `prompt`.
///
/// "background" is dropped: it is the base image, which layerize returns anyway, so asking for it
/// wastes one of the 16 slots. Returns { text, dropped }.
function instructionFor(names) {
    var usable = [], seen = {};
    for (var i = 0; i < names.length; i++) {
        var n = String(names[i]).replace(/^\s+|\s+$/g, "");
        var lower = n.toLowerCase();
        if (!n.length || lower === "background") { continue; }
        if (seen[lower]) { continue; }          // appending a second proposal repeats names
        seen[lower] = true;
        usable.push(n);
    }
    var kept = usable.slice(0, MAX_ELEMENTS);
    var dropped = usable.slice(MAX_ELEMENTS);
    if (!kept.length) { return { text: "", dropped: dropped }; }
    return { text: "Separate these elements out from the image as individual layers: " +
                   kept.join(", "), dropped: dropped };
}

/// Recover element names from an instruction this script produced, so a second proposal can be
/// appended to a first. Anything typed freehand that isn't in that shape is treated as one item,
/// which keeps the person's words rather than discarding them.
function elementsInInstruction(text) {
    var t = String(text).replace(/^\s+|\s+$/g, "");
    if (!t.length) { return []; }
    var marker = "individual layers:";
    var at = t.indexOf(marker);
    if (at >= 0) { t = t.substring(at + marker.length); }
    var parts = t.split(",");
    var out = [];
    for (var i = 0; i < parts.length; i++) {
        var p = parts[i].replace(/^\s+|\s+$/g, "");
        if (p.length) { out.push(p); }
    }
    return out;
}

/// Ask Gemini what is worth separating. Returns { plan, cost, error } — `plan` null on failure.
function requestPlan(pngFile) {
    var token = h5gToken();
    if (!token) {
        return { plan: null, cost: 0,
                 error: "not signed in to Vertex \u2014 run  node client.mjs login  from the " +
                        "h5g-ai-connect skill" };
    }
    var base = h5gServiceURL();
    if (!base) {
        return { plan: null, cost: 0,
                 error: "the h5g-ai-connect client isn't installed on this Mac, so there is no " +
                        "service to ask" };
    }
    var b64 = base64Of(pngFile);
    if (b64 === null) { return { plan: null, cost: 0, error: "could not encode the image" }; }

    // Written in pieces rather than via JSON.stringify: the payload carries a megabyte of base64,
    // and running the polyfill's five escape passes over it is pure waste — base64 has no character
    // that needs escaping.
    var payload = tempFile("vision_payload", "json");
    payload.encoding = "UTF-8";
    payload.open("w");
    payload.write('{"prompt":' + JSON.stringify("Plan how to split this image into layers.") +
                  ',"system_prompt":' + JSON.stringify(PLAN_SYSTEM_PROMPT) +
                  ',"input_images":[{"mime":"image/png","base64":"');
    payload.write(b64);
    payload.write('"}]}');
    payload.close();

    var lastError = "no response";
    for (var attempt = 0; attempt < 3; attempt++) {
        var resp = curl('-s -S --max-time 120 -X POST -H "Authorization: Bearer ' + token + '" ' +
                        '-H "Content-Type: application/json" "' + base + '/v1/vision" ' +
                        '-d @"' + payload.fsName + '"');
        if (resp) {
            var j = null;
            try { j = JSON.parse(resp); } catch (e) { j = null; }
            if (j && typeof j.text === "string") {
                var plan = parsePlan(j.text);
                if (plan !== null) { return { plan: plan, cost: (j.cost_usd || 0), error: null }; }
                lastError = "the planner's answer wasn't in the expected shape";
                break;      // a malformed answer is not a transport problem; retrying re-spends
            }
            lastError = (j && j.error) ? String(j.error) : String(resp).substring(0, 300);
        }
        if (!isTransientError(lastError)) { break; }
        $.sleep(1500);
    }
    return { plan: null, cost: 0, error: friendlyError(lastError) };
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
/// `thumbFile` is a small flattened PNG of the same region, used only by Analyze. Pass null to get
/// the typed-only dialog.
function askElements(thumbFile) {
    var w = new Window("dialog", "Layerize Selection");
    w.alignChildren = "fill";
    w.margins = 16;

    w.add("statictext", undefined, "What should be separated into layers?");
    // Lines are kept under ~66 characters and the height matches the line count. A multiline
    // statictext does NOT grow to fit: at 460px the first draft wrapped onto a fifth line and the
    // example was simply cut off the bottom, which a screenshot caught and reading the code did not.
    var hint = w.add("statictext", undefined,
        "Optional \u2014 naming the parts gives better layers than a blank box.\n" +
        "e.g.  Separate guns, triggers, hands, and arms out from image\n" +
        "Or click Analyze image\u2026 for plans built from this picture.",
        { multiline: true });
    hint.preferredSize = [460, 58];

    // --- Analyze row: look at the image and propose plans ---------------------------------------
    var arow = w.add("group");
    arow.alignment = "fill";
    var analyze = arow.add("button", undefined, "Analyze image\u2026");
    analyze.preferredSize.width = 116;
    var picker = arow.add("dropdownlist", undefined, []);
    picker.preferredSize.width = 250;
    picker.enabled = false;
    var addBtn = arow.add("button", undefined, "\uff0b");
    addBtn.preferredSize.width = 34;
    addBtn.helpTip = "Add this proposal's elements to the list below, instead of replacing it";
    addBtn.enabled = false;

    var status = w.add("statictext", undefined, "", { truncate: "middle" });
    status.preferredSize.width = 460;
    status.graphics.font = ScriptUI.newFont(status.graphics.font.name, "italic", 10);

    var field = w.add("edittext", undefined, loadRememberedElements(), { multiline: true });
    field.preferredSize = [460, 80];

    var foot = w.add("statictext", undefined,
        "\u201c" + BASE_PROMPT + "\u201d is always sent, so names come back in English.");
    foot.graphics.font = ScriptUI.newFont(foot.graphics.font.name, "italic", 10);

    var row = w.add("group");
    row.alignment = "fill";
    var conn = row.add("button", undefined, "Connections\u2026");
    conn.preferredSize.width = 116;
    conn.helpTip = "Set the fal.ai key, or sign in to Vertex for Analyze";
    var keep = row.add("checkbox", undefined, "Keep images in the log folder");
    keep.helpTip = "Saves what was sent and every layer that came back, for working out a bad result";
    var spacer = row.add("group");
    spacer.alignment = "fill";
    var cancel = row.add("button", undefined, "Cancel", { name: "cancel" });
    var ok = row.add("button", undefined, "Layerize", { name: "ok" });

    // Analyze is optional and uses a DIFFERENT credential from the rest of the script, so when it is
    // unavailable it says exactly which one is missing. A coworker who has just pasted a fal key and
    // then sees a dead button will otherwise conclude the key was wrong.
    var plan = null;
    function refreshAnalyze() {
        if (thumbFile === null || thumbFile === undefined) {
            analyze.enabled = false;
            status.text = "Analyze needs the flattened area, which isn't available here \u2014 type the elements.";
        } else if (h5gToken() === null) {
            analyze.enabled = false;
            status.text = "Analyze needs a Vertex sign-in \u2014 click Connections. Your fal.ai key is unrelated.";
        } else if (h5gServiceURL() === null) {
            analyze.enabled = false;
            status.text = "Analyze needs the h5g-ai-connect skill installed. Typing the elements works without it.";
        } else {
            analyze.enabled = true;
            status.text = "";
        }
    }
    refreshAnalyze();
    conn.onClick = function () { showConnections(); refreshAnalyze(); };
    keep.onClick = function () { KEEP_IMAGES = (keep.value === true); };

    function showOption(index, append) {
        if (plan === null || index < 0 || index >= plan.options.length) { return; }
        var o = plan.options[index];
        var names = append ? elementsInInstruction(field.text).concat(o.elements) : o.elements;
        var built = instructionFor(names);
        field.text = built.text;
        var note = o.why;
        if (o.warning.length) { note = note.length ? note + " \u2014 " + o.warning : o.warning; }
        if (built.dropped.length) {
            note = (note.length ? note + " \u2014 " : "") + "over the " + MAX_ELEMENTS +
                   "-element limit, dropped: " + built.dropped.join(", ");
        }
        status.text = note;
    }

    analyze.onClick = function () {
        analyze.enabled = false;
        status.text = "Looking at the image\u2026";
        // Photoshop is single-threaded, so the window cannot repaint while curl runs. Force the one
        // update that matters before blocking, or the button just appears to do nothing for 10s.
        status.update();
        w.update();
        var r = requestPlan(thumbFile);
        analyze.enabled = true;
        if (r.plan === null) { status.text = "Analyze failed: " + r.error; return; }
        plan = r.plan;
        picker.removeAll();
        for (var i = 0; i < plan.options.length; i++) { picker.add("item", optionTitle(plan.options[i])); }
        picker.enabled = true;
        addBtn.enabled = true;
        picker.selection = 0;       // fires onChange, which fills the field
        if (plan.kind.length) { status.text = plan.kind + " \u2014 " + status.text; }
    };
    picker.onChange = function () {
        if (picker.selection !== null) { showOption(picker.selection.index, false); }
    };
    addBtn.onClick = function () {
        if (picker.selection !== null) { showOption(picker.selection.index, true); }
    };

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
/// demands it. Pass `maxDim` to cap the long edge as well — the Analyze thumbnail does, since a
/// vision read only needs enough resolution to make out the subject. Returns { file, w, h }.
function exportRegion(doc, x1, y1, x2, y2, maxDim) {
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
        if (maxDim && Math.max(w, h) > maxDim) {
            var s = maxDim / Math.max(w, h);
            cropDoc.resizeImage(UnitValue(Math.max(1, Math.round(w * s)), "px"),
                                UnitValue(Math.max(1, Math.round(h * s)), "px"), null, ResampleMethod.BICUBICSHARPER);
            w = cropDoc.width.as("px"); h = cropDoc.height.as("px");
        }

        log("  merged copy: " + w + "x" + h + ", layers in the copy=" + cropDoc.layers.length +
            ", bottom isBackgroundLayer=" +
            (cropDoc.layers[cropDoc.layers.length - 1].isBackgroundLayer === true));
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
    if (!code || String(code).replace(/[\r\n]/g, "").indexOf("200") !== 0) {
        log("  upload PUT did not return 200: " + String(code).substring(0, 80));
        return null;
    }
    return j.file_url;
}

/// Raw base64 of a file, via the platform's own encoder — ExtendScript has none.
function base64Of(f) {
    var b64 = tempFile("layerize_b64", "txt");
    var cmd = IS_WINDOWS
        ? 'cmd.exe /c "certutil -encodehex -f "' + f.fsName + '" "' + b64.fsName + '" 0x40000001"'
        : 'base64 -i "' + f.fsName + '" -o "' + b64.fsName + '"';
    app.system(cmd);
    if (!b64.exists) { return null; }
    b64.open("r");
    var s = b64.read();
    b64.close();
    return s.replace(/[\r\n]/g, "");
}

function base64DataURI(f) {
    var s = base64Of(f);
    return (s === null) ? null : "data:image/png;base64," + s;
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

    log("");
    log("--- request to fal ---");
    log("endpoint:   " + LAYERIZE_ENDPOINT);
    log("image_size: auto      enhance_prompt_mode: standard");
    log("prompt:     " + promptText.replace(/\n/g, "\n            "));
    log("");
    var resp = curl('-s -S -X POST -H "Authorization: Key ' + key + '" ' +
                    '-H "Content-Type: application/json" -H "Accept: application/json" ' +
                    '"' + LAYERIZE_ENDPOINT + '" -d @"' + payload.fsName + '"');
    if (!resp) { throw new Error("no response from fal (is curl available?)"); }
    // The whole reply, verbatim. It is metadata and URLs, a few KB, and it is the ONLY record of
    // what fal decided - including whether it handed back a full-canvas backdrop as an element.
    log("--- raw response from fal ---");
    log(String(resp));
    log("--- end of response ---");
    log("");
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

/// Place one layer PNG into `doc`, scaled from base-image space into the target rect.
function placeLayer(doc, group, f, box, scaleX, scaleY, offsetX, offsetY, layerName) {
    var srcDoc = openOrCleanUp(f);
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
    logStart();

    var priorUnits = app.preferences.rulerUnits;
    app.preferences.rulerUnits = Units.PIXELS;
    var priorDialogs = app.displayDialogs;
    app.displayDialogs = DialogModes.NO;
    var priorInterp = app.preferences.interpolation;
    // Every layer is scaled into its box, usually downwards, so this is the difference between a
    // sharp result and a mushy one. ArtLayer.resize has no interpolation argument.
    app.preferences.interpolation = ResampleMethod.BICUBICSHARPER;

    // Declared out here so the finally block can always put the selection back, including on the
    // path where the dialog is cancelled after the marching ants have been stashed away.
    var savedSelection = null;

    try {
        logDocument(doc);
        logConnections();

        // Prompts for a key if none is configured; null means the user cancelled that dialog.
        var key = falKey();
        if (!key) { log("no fal.ai key - the person cancelled the key dialog"); return; }

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

        progress("Flattening " + selW + "x" + selH + (usedSelection ? " selection" : " canvas") + "\u2026");
        // Deselect so the duplicate/crop is not itself clipped by the marching ants.
        if (usedSelection) {
            savedSelection = doc.channels.add();
            savedSelection.name = "Layerize_Selection";
            doc.selection.store(savedSelection);
            doc.selection.deselect();
        }

        // A small flatten first, purely so Analyze has something to look at. It is the cheap half of
        // the work — the full-resolution export is left until after the dialog is accepted, so
        // cancelling still costs nothing worth noticing.
        var thumb = null;
        try { thumb = exportRegion(doc, x1, y1, x2, y2, 768).file; } catch (te) { thumb = null; }

        progressDone();
        var promptText = askElements(thumb);
        if (promptText === null) { log("the person cancelled the element dialog"); return; }

        progress("Flattening " + selW + "x" + selH + "\u2026");
        var exported = exportRegion(doc, x1, y1, x2, y2);
        log("sent to fal: " + describePng(exported.file));
        logKeep(exported.file, "sent_to_fal.png");
        if (exported.file.length > MAX_BYTES) {
            throw new Error("the flattened area is " + Math.round(exported.file.length / 1048576) +
                            " MB, over fal's 30 MB limit \u2014 select a smaller area");
        }

        // Recorded before the upload so the final message can say what was actually sent. "It added
        // white over everything" is impossible to act on; "what we sent was fully opaque" points
        // straight at a visible layer in the document, and its opposite clears the export entirely.
        var sentAlpha = pngInfo(exported.file);
        sentAlpha = (sentAlpha === null) ? null : sentAlpha.hasAlpha;

        progress("Uploading " + Math.round(exported.file.length / 1048576 * 10) / 10 + " MB\u2026");
        var imageRef = uploadToFal(exported.file, key);
        if (imageRef === null) {
            progress("Upload failed \u2014 inlining instead\u2026");
            imageRef = base64DataURI(exported.file);
            if (imageRef === null) { throw new Error("could not upload or encode the image"); }
        }

        progress("Layerizing \u2014 this takes 2-3 minutes and Photoshop will be unresponsive\u2026");
        var layers = requestLayerize(imageRef, key, promptText);

        // The base (z_index 0, no bounding box) defines the coordinate space every box is measured
        // in. It is downloaded to read its size but NOT inserted: your own artwork is already in the
        // document underneath, and for a transparent input the base is only a blank plate anyway.
        var baseEntry = null, elements = [];
        for (var i = 0; i < layers.length; i++) {
            var L = layers[i];
            var hasBox = (L.bounding_box && L.bounding_box.absolute && L.bounding_box.absolute.length === 4);
            if (!hasBox && baseEntry === null) { baseEntry = L; } else if (hasBox) { elements.push(L); }
            log("  returned [" + i + "] z=" + (typeof L.z_index === "undefined" ? "?" : L.z_index) +
                "  " + (L.name || "(unnamed)") +
                (hasBox ? "  box=" + L.bounding_box.absolute.join(",")
                        : "  NO BOX -> treated as the base" +
                          (baseEntry === L ? " (kept for measuring, never inserted)"
                                           : " -> DISCARDED, a second box-less entry")));
        }
        log("");
        if (!elements.length) { throw new Error("fal separated nothing out of that area"); }

        var canvasW = 0, canvasH = 0;
        if (baseEntry !== null && baseEntry.image && baseEntry.image.url) {
            progress("Measuring the returned canvas\u2026");
            var baseFile = tempFile("layerize_base", "png");
            if (downloadTo(baseEntry.image.url, baseFile)) {
                var bd = openOrCleanUp(baseFile);
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

        // The script never inserts fal's base, but fal sometimes hands the same backdrop back as a
        // NAMED element with a bounding box, and then it is placed like anything else. Because the
        // group sits above the document, a whole-area layer like that hides the artwork underneath \u2014
        // which looks exactly like the script having painted over everything. Named in the summary
        // rather than dropped: a symbol's own backdrop disc is also whole-area and is wanted.
        var placed = 0, failed = [], fullCanvasElements = [];
        for (var m = 0; m < elements.length; m++) {
            var e = elements[m];
            var bx = e.bounding_box.absolute;
            if ((bx[2] - bx[0]) >= canvasW * 0.98 && (bx[3] - bx[1]) >= canvasH * 0.98) {
                fullCanvasElements.push(e.name || ("layer " + (m + 1)));
            }
            progress("Placing layer " + (m + 1) + " of " + elements.length +
                     (e.name ? " \u2014 " + e.name : "") + "\u2026");
            var lf = tempFile("layerize_layer_" + m, "png");
            if (!e.image || !e.image.url || !downloadTo(e.image.url, lf)) {
                log("  layer " + (m + 1) + " " + (e.name || "(unnamed)") + ": DOWNLOAD FAILED  " +
                    ((e.image && e.image.url) ? e.image.url : "(no url)"));
                failed.push((e.name || ("layer " + m)) + " (download failed)");
                continue;
            }
            log("  layer " + (m + 1) + " " + (e.name || "(unnamed)") +
                "\n      png:   " + describePng(lf) +
                "\n      box:   " + bx.join(",") + "   in a " + canvasW + "x" + canvasH + " canvas" +
                "\n      onto:  " + Math.round((bx[2] - bx[0]) * scaleX) + "x" +
                Math.round((bx[3] - bx[1]) * scaleY) + " at " +
                Math.round(x1 + bx[0] * scaleX) + "," + Math.round(y1 + bx[1] * scaleY) +
                (fullCanvasElements.length &&
                 fullCanvasElements[fullCanvasElements.length - 1] === (e.name || ("layer " + (m + 1)))
                     ? "\n      *** covers the whole area ***" : ""));
            logKeep(lf, "layer" + (m + 1) + "_" + String(e.name || "unnamed").replace(/[^A-Za-z0-9]+/g, "_") + ".png");
            try {
                var placedLayer = placeLayer(doc, group, lf, e.bounding_box.absolute, scaleX, scaleY, x1, y1, e.name);
                try {
                    var pb = placedLayer.bounds;
                    log("      final: " + Math.round(pb[2].as("px") - pb[0].as("px")) + "x" +
                        Math.round(pb[3].as("px") - pb[1].as("px")) + " at " +
                        Math.round(pb[0].as("px")) + "," + Math.round(pb[1].as("px")));
                } catch (be) {}
                placed++;
            } catch (pe) {
                log("      PLACEMENT FAILED: " + describe(pe));
                failed.push((e.name || ("layer " + m)) + " \u2014 " + describe(pe));
            }
        }

        progressDone();
        var msg = "Added " + placed + " layer" + (placed === 1 ? "" : "s") + " in the \u201cLayerized\u201d group.";
        if (failed.length) { msg += "\n\n" + failed.length + " could not be placed:\n\u2022 " + failed.join("\n\u2022 "); }
        if (placed === 0) { msg = "Nothing could be placed.\n\n\u2022 " + failed.join("\n\u2022 "); }
        msg += "\n\nSent " + selW + "x" + selH + ", " +
               (sentAlpha === false
                   ? "fully opaque \u2014 nothing in that area was transparent, so a visible layer was " +
                     "covering it. Hide it and run again if you meant to send a cutout."
                   : "transparency intact.");
        if (LOG_FILE !== null) { msg += "\n\nLog: " + LOG_FILE.fsName; }
        if (fullCanvasElements.length) {
            msg += "\n\nCovering the whole area: " + fullCanvasElements.join(", ") +
                   ". If that hides your artwork, delete it \u2014 it is fal's own backdrop, not " +
                   "something of yours.";
        }
        alert(msg);
    } catch (e) {
        progressDone();
        log("");
        log("FAILED: " + describe(e));
        alert("Layerize failed:\n\n" + describe(e) +
              (LOG_FILE === null ? "" : "\n\nLog: " + LOG_FILE.fsName));
    } finally {
        progressDone();
        if (savedSelection !== null) {
            try { doc.selection.load(savedSelection); savedSelection.remove(); } catch (se) {}
        }
        cleanupTemp();
        app.preferences.interpolation = priorInterp;
        app.preferences.rulerUnits = priorUnits;
        app.displayDialogs = priorDialogs;
    }
}

run();
