/*
Chroma Key Still Export for After Effects (manual footage workflow)
=========================================

Purpose:
  Import a green/magenta/cyan-screen still image, apply Keylight, optionally add
  Key Cleaner and Advanced Spill Suppressor, then render a single frame with
  alpha for use as a transparent Spine layer.

How to run:
  1. Edit CONFIG below, or place chroma_key_config.json next to this script.
  2. In After Effects: File > Scripts > Run Script File...
  3. Or from command line:
       afterfx.exe -r "C:\\path\\to\\chroma_key_still.jsx"

Config JSON example:
  {
    "sourceFile": "C:/temp/symbol_green.png",
    "outputFolder": "C:/temp/keyed",
    "outputName": "symbol_keyed",
    "keyMode": "auto",
    "useSampleAverage": false
  }

Notes:
  - Keylight is designed primarily for green/blue screen work. The script can
    set magenta/cyan as screen colours, but those must be tested on your AE
    install and asset style.
  - Navigator uses native minimum-opacity extraction for uniform-backed still FX.
    Its blue/magenta outputs were opaque when automation selected green, and
    saturation keying eroded soft rays. This manual footage keyer is not that path.
*/

(function chromaKeyStillExport() {
    var CONFIG = {
        sourceFile: "",
        outputFolder: "",
        outputName: "",
        configFile: "",
        logFile: "",
        resultFile: "",

        // Automation mode never opens dialogs or alerts. Set showUi=false for
        // command-line runs that provide source/output in JSON.
        automationMode: false,
        showUi: true,
        quitWhenDone: false,

        // "auto", "green", "magenta", "cyan", "blue", or "custom".
        keyMode: "auto",
        customKeyColor: [0, 1, 0],
        customKeyColorHex: "#00FF00",

        // If true, auto mode uses the sampled edge average directly. This is
        // better when the generated "green" is slightly off from exact #00FF00.
        // If false, auto mode snaps to the nearest preset key color.
        useSampleAverage: true,
        sampleAutoInAutomation: false,

        // In auto mode, "corners" works like an automatic eyedropper: sample
        // the matte colour from the image corners, where generated symbols
        // should not appear. "edges" samples corners plus edge centres.
        autoSampleStrategy: "corners",
        cornerInsetPixels: 2,
        sampleEdgePercent: 0.04,
        sampleRadius: 8,

        // Conservative defaults for generated flat backgrounds. Tune per test.
        keylight: {
            screenGain: null,
            screenBalance: null,
            clipBlack: null,
            clipWhite: null,
            screenPreblur: null
        },

        addKeyCleaner: true,
        addAdvancedSpillSuppressor: true,

        compName: "H5G_Chroma_Key_Still",
        compDuration: 1 / 24,
        compFps: 24,

        // These names are machine/version/template dependent. The script tries
        // them in order and logs which one worked.
        renderSettingsTemplate: "Best Settings",
        outputModuleTemplates: [
            "PNG Sequence with Alpha",
            "TIFF Sequence with Alpha"
        ],

        // Sequence output. AE expects bracket tokens for image sequences.
        outputExtension: "png",
        appendFrameToken: true,
        renderImmediately: true,
        failOnImageSignatureMismatch: true,

        // Navigator converts completed TIFFs with ImageIO; AE's shell access is refused
        // on installations with scripting network/file security disabled.
        finalOutputFormat: "tif"
    };

    var PRESET_COLORS = {
        green: [0, 1, 0],
        magenta: [1, 0, 1],
        cyan: [0, 1, 1],
        blue: [0, 0, 1]
    };

    var ACTIVE_CONFIG = CONFIG;
    var LOG_FILE = null;
    var LOG_INITIALIZED = false;
    var DID_BEGIN_UNDO = false;

    // Everything this run adds to the AE project, so it can be taken back out again.
    //
    // Navigator drives this script once PER IMAGE against one long-lived After Effects
    // session, so anything left behind accumulates for the whole batch: a 39-image run
    // was ending with 39 imported footage items, 39 comps all named the same thing, and
    // 39 render-queue entries in a project that was never cleaned. That is a real cause
    // of a long run degrading and then failing partway through, and it also left the
    // user's AE session full of junk.
    //
    // Only ever removes items THIS run created — never touches a project the user has
    // open, and never closes the project, which could destroy unsaved work.
    var CREATED = { rqItem: null, comp: null, footage: null };

    function cleanupCreatedItems() {
        // Render queue item first: it references the comp, and removing the comp out
        // from under a queued item is what leaves AE in a bad state.
        if (CREATED.rqItem) {
            try { CREATED.rqItem.remove(); log("Removed render queue item."); }
            catch (e) { log("WARNING: could not remove render queue item: " + e.toString()); }
            CREATED.rqItem = null;
        }
        if (CREATED.comp) {
            try { CREATED.comp.remove(); log("Removed comp."); }
            catch (e) { log("WARNING: could not remove comp: " + e.toString()); }
            CREATED.comp = null;
        }
        if (CREATED.footage) {
            try { CREATED.footage.remove(); log("Removed imported footage."); }
            catch (e) { log("WARNING: could not remove footage: " + e.toString()); }
            CREATED.footage = null;
        }
    }

    function log(message) {
        // Console only — no log FILE is written (keeps the output folder clean).
        $.writeln("[chroma_key_still] " + message);
        if (!LOG_FILE) {
            return;
        }
        try {
            LOG_FILE.open(LOG_INITIALIZED ? "a" : "w");
            LOG_FILE.write("[chroma_key_still] " + message + "\n");
            LOG_FILE.close();
            LOG_INITIALIZED = true;
        } catch (e) {
            $.writeln("[chroma_key_still] log write failed: " + e.toString());
        }
    }

    function scriptFolder() {
        try {
            var fileName = String($.fileName || "");
            if (fileName && fileName !== "2") {
                return File(fileName).parent;
            }
        } catch (e) {
        }
        return Folder.current;
    }

    function normalizePath(path) {
        return String(path || "").replace(/\\/g, "/");
    }

    function makeFile(path) {
        return File(normalizePath(path));
    }

    function makeFolder(path) {
        return Folder(normalizePath(path));
    }

    function ensureFolder(folderObj) {
        if (folderObj.exists) {
            return folderObj;
        }
        if (!folderObj.create()) {
            throw new Error("Could not create folder: " + folderObj.fsName);
        }
        return folderObj;
    }

    function readTextFile(fileObj) {
        fileObj.open("r");
        var text = fileObj.read();
        fileObj.close();
        return text;
    }

    function parseJsonText(text) {
        if (typeof JSON !== "undefined" && JSON.parse) {
            return JSON.parse(text);
        }
        return eval("(" + text + ")");
    }

    function resolveConfigFile(config) {
        if ($.global && $.global.H5G_CHROMA_KEY_CONFIG) {
            if (typeof $.global.H5G_CHROMA_KEY_CONFIG === "string") {
                return makeFile($.global.H5G_CHROMA_KEY_CONFIG);
            }
            if (typeof $.global.H5G_CHROMA_KEY_CONFIG === "object") {
                mergeObjects(config, $.global.H5G_CHROMA_KEY_CONFIG);
                return null;
            }
        }
        if (config.configFile) {
            return makeFile(config.configFile);
        }
        var adjacent = File(scriptFolder().fsName + "/chroma_key_config.json");
        return adjacent.exists ? adjacent : null;
    }

    function readConfigFromJson(config) {
        var cfgFile = resolveConfigFile(config);
        if (!cfgFile) {
            return config;
        }
        if (!cfgFile.exists) {
            throw new Error("Config file does not exist: " + cfgFile.fsName);
        }

        var parsed = parseJsonText(readTextFile(cfgFile));
        config = mergeObjects(config, parsed);
        config.configFile = cfgFile.fsName;
        return config;
    }

    function initLogFile(config) {
        // Logging to a file is disabled — only write a file if a logFile is
        // explicitly requested in the config (Navigator never sets one).
        if (config.logFile) {
            LOG_FILE = makeFile(config.logFile);
            var parent = LOG_FILE.parent;
            if (parent && !parent.exists) { ensureFolder(parent); }
            LOG_INITIALIZED = false;
        }
    }

    function mergeObjects(base, override) {
        for (var key in override) {
            if (!override.hasOwnProperty(key)) {
                continue;
            }
            if (
                base[key] &&
                typeof base[key] === "object" &&
                !(base[key] instanceof Array) &&
                typeof override[key] === "object" &&
                !(override[key] instanceof Array)
            ) {
                mergeObjects(base[key], override[key]);
            } else {
                base[key] = override[key];
            }
        }
        return base;
    }

    function isAutomation(config) {
        try {
            if (app.exitAfterLaunchAndEval) {
                return true;
            }
        } catch (e) {
        }
        return !!config.automationMode || config.showUi === false;
    }

    function parseHexColor(text) {
        var hex = String(text || "").replace(/^#/, "");
        if (!/^[0-9a-fA-F]{6}$/.test(hex)) {
            throw new Error("Custom key color must be a hex value like #00FF00.");
        }
        return [
            parseInt(hex.substring(0, 2), 16) / 255,
            parseInt(hex.substring(2, 4), 16) / 255,
            parseInt(hex.substring(4, 6), 16) / 255
        ];
    }

    function colorToHex(color) {
        function one(v) {
            var n = Math.max(0, Math.min(255, Math.round(v * 255)));
            var s = n.toString(16).toUpperCase();
            return s.length === 1 ? "0" + s : s;
        }
        return "#" + one(color[0]) + one(color[1]) + one(color[2]);
    }

    function chooseSourceFile(config) {
        if (config.sourceFile) {
            return makeFile(config.sourceFile);
        }
        if (isAutomation(config)) {
            throw new Error("Automation mode requires sourceFile.");
        }
        return File.openDialog("Choose green/magenta/cyan-screen symbol image");
    }

    function chooseOutputFolder(config) {
        if (config.outputFolder) {
            return ensureFolder(makeFolder(config.outputFolder));
        }
        if (isAutomation(config)) {
            throw new Error("Automation mode requires outputFolder.");
        }
        var folder = Folder.selectDialog("Choose output folder for keyed image");
        return folder ? ensureFolder(folder) : null;
    }

    function showInteractiveDialog(config) {
        if (isAutomation(config) || !config.showUi) {
            return config;
        }

        var win = new Window("dialog", "H5G Chroma Key Still");
        win.orientation = "column";
        win.alignChildren = ["fill", "top"];

        var sourceGroup = win.add("group");
        sourceGroup.add("statictext", undefined, "Source image:");
        var sourceEdit = sourceGroup.add("edittext", undefined, config.sourceFile || "");
        sourceEdit.characters = 48;
        var sourceButton = sourceGroup.add("button", undefined, "Browse");

        var outputGroup = win.add("group");
        outputGroup.add("statictext", undefined, "Output folder:");
        var outputEdit = outputGroup.add("edittext", undefined, config.outputFolder || "");
        outputEdit.characters = 48;
        var outputButton = outputGroup.add("button", undefined, "Browse");

        var nameGroup = win.add("group");
        nameGroup.add("statictext", undefined, "Output name:");
        var nameEdit = nameGroup.add("edittext", undefined, config.outputName || "");
        nameEdit.characters = 32;

        var modeGroup = win.add("group");
        modeGroup.add("statictext", undefined, "Key mode:");
        var modeList = modeGroup.add("dropdownlist", undefined, ["auto", "green", "blue", "cyan", "magenta", "custom"]);
        var mode = String(config.keyMode || "auto").toLowerCase();
        var selected = 0;
        for (var i = 0; i < modeList.items.length; i++) {
            if (modeList.items[i].text === mode) {
                selected = i;
                break;
            }
        }
        modeList.selection = selected;

        var colorGroup = win.add("group");
        colorGroup.add("statictext", undefined, "Custom color:");
        var colorEdit = colorGroup.add("edittext", undefined, config.customKeyColorHex || colorToHex(config.customKeyColor));
        colorEdit.characters = 10;
        colorGroup.add("statictext", undefined, "hex, e.g. #00FF00");

        var sampleCheck = win.add("checkbox", undefined, "Use sampled color directly in auto mode");
        sampleCheck.checked = !!config.useSampleAverage;

        var buttons = win.add("group");
        buttons.alignment = "right";
        buttons.add("button", undefined, "Cancel", { name: "cancel" });
        buttons.add("button", undefined, "Run", { name: "ok" });

        sourceButton.onClick = function () {
            var file = File.openDialog("Choose green/magenta/cyan-screen symbol image");
            if (file) {
                sourceEdit.text = file.fsName;
                if (!nameEdit.text) {
                    nameEdit.text = baseNameWithoutExtension(file) + "_keyed";
                }
            }
        };
        outputButton.onClick = function () {
            var folder = Folder.selectDialog("Choose output folder for keyed image");
            if (folder) {
                outputEdit.text = folder.fsName;
            }
        };

        if (win.show() !== 1) {
            throw new Error("Chroma key export cancelled.");
        }

        config.sourceFile = sourceEdit.text;
        config.outputFolder = outputEdit.text;
        config.outputName = nameEdit.text;
        config.keyMode = modeList.selection ? modeList.selection.text : "auto";
        config.customKeyColorHex = colorEdit.text;
        if (String(config.keyMode).toLowerCase() === "custom") {
            config.customKeyColor = parseHexColor(config.customKeyColorHex);
        }
        config.useSampleAverage = sampleCheck.checked;
        return config;
    }

    function baseNameWithoutExtension(fileObj) {
        var name = fileObj.name;
        var idx = name.lastIndexOf(".");
        if (idx > 0) {
            name = name.substring(0, idx);
        }
        return name;
    }

    function fileExtension(fileObj) {
        var name = String(fileObj.name || "").toLowerCase();
        var idx = name.lastIndexOf(".");
        return idx >= 0 ? name.substring(idx + 1) : "";
    }

    function readSignature(fileObj, count) {
        fileObj.encoding = "BINARY";
        fileObj.open("r");
        var bytes = fileObj.read(count);
        fileObj.close();
        return bytes;
    }

    function byteAt(text, index) {
        return text.charCodeAt(index) & 255;
    }

    function detectImageSignature(fileObj) {
        var bytes = readSignature(fileObj, 12);
        if (bytes.length >= 8 &&
            byteAt(bytes, 0) === 0x89 &&
            byteAt(bytes, 1) === 0x50 &&
            byteAt(bytes, 2) === 0x4E &&
            byteAt(bytes, 3) === 0x47 &&
            byteAt(bytes, 4) === 0x0D &&
            byteAt(bytes, 5) === 0x0A &&
            byteAt(bytes, 6) === 0x1A &&
            byteAt(bytes, 7) === 0x0A) {
            return "png";
        }
        if (bytes.length >= 2 && byteAt(bytes, 0) === 0xFF && byteAt(bytes, 1) === 0xD8) {
            return "jpg";
        }
        return "unknown";
    }

    function validateSourceImage(fileObj, config) {
        var ext = fileExtension(fileObj);
        var sig = detectImageSignature(fileObj);
        log("Source extension: " + ext + "; signature: " + sig);

        if (sig === "unknown") {
            log("WARNING: Could not identify image signature.");
            return;
        }

        if ((ext === "png" && sig !== "png") ||
            ((ext === "jpg" || ext === "jpeg") && sig !== "jpg")) {
            var message = "Image extension does not match file bytes: ." + ext + " contains " + sig + " data.";
            if (config.failOnImageSignatureMismatch) {
                throw new Error(message);
            }
            log("WARNING: " + message);
        }
    }

    function importFootage(fileObj) {
        var opts = new ImportOptions(fileObj);
        return app.project.importFile(opts);
    }

    function makeCompFromFootage(footage, config) {
        var width = footage.width || (footage.mainSource ? footage.mainSource.width : 0);
        var height = footage.height || (footage.mainSource ? footage.mainSource.height : 0);
        var fps = Number(config.compFps) || 24;
        var duration = Number(config.compDuration) || 1;
        if (duration < 1) {
            duration = 1;
        }
        log("Imported footage dimensions: " + width + "x" + height);
        log("Comp timing: duration=" + duration + ", fps=" + fps);
        if (!width || !height) {
            throw new Error("Imported footage has invalid dimensions.");
        }
        var comp = app.project.items.addComp(
            config.compName,
            width,
            height,
            1,
            duration,
            fps
        );
        log("Created comp: " + comp.name);
        var layer = comp.layers.add(footage);
        log("Added source layer.");
        layer.name = "source_symbol";
        return { comp: comp, layer: layer };
    }

    function colorDistance(a, b) {
        var dr = a[0] - b[0];
        var dg = a[1] - b[1];
        var db = a[2] - b[2];
        return Math.sqrt(dr * dr + dg * dg + db * db);
    }

    function nearestPresetName(color) {
        var bestName = "green";
        var bestDistance = 999999;
        for (var name in PRESET_COLORS) {
            if (!PRESET_COLORS.hasOwnProperty(name)) {
                continue;
            }
            var dist = colorDistance(color, PRESET_COLORS[name]);
            if (dist < bestDistance) {
                bestDistance = dist;
                bestName = name;
            }
        }
        return bestName;
    }

    function sampleLayerColor(comp, layer, x, y, radius) {
        // AE scripting cannot call sampleImage directly. This expression bridge
        // is slower but works for small numbers of samples.
        var ctrl = layer.property("ADBE Effect Parade").addProperty("ADBE Color Control");
        try {
            var prop = ctrl.property(1);
            var expr =
                "sampleImage([" +
                Math.round(x) +
                "," +
                Math.round(y) +
                "],[" +
                radius +
                "," +
                radius +
                "],false,0);";
            prop.expression = expr;
            prop.expressionEnabled = true;
            comp.time = 0;
            $.sleep(250);
            var value = prop.valueAtTime(0, false);
            return [value[0], value[1], value[2], value[3]];
        } finally {
            ctrl.remove();
        }
    }

    function averageSamples(comp, layer, points, radius) {
        var samples = [];
        for (var i = 0; i < points.length; i++) {
            try {
                var rgba = sampleLayerColor(comp, layer, points[i][0], points[i][1], radius);
                if (rgba[3] > 0.01) {
                    samples.push([rgba[0], rgba[1], rgba[2]]);
                }
            } catch (e) {
                log("WARNING: Could not sample color at " + points[i][0] + "," + points[i][1] + ": " + e.toString());
            }
        }

        if (samples.length === 0) {
            log("WARNING: No valid color samples; falling back to green.");
            return PRESET_COLORS.green;
        }

        // Pick the most representative sample by finding the colour with the
        // smallest total distance to all other samples. This tolerates one bad
        // corner better than a plain average.
        var bestIndex = 0;
        var bestScore = 999999;
        for (var s = 0; s < samples.length; s++) {
            var score = 0;
            for (var t = 0; t < samples.length; t++) {
                score += colorDistance(samples[s], samples[t]);
            }
            if (score < bestScore) {
                bestScore = score;
                bestIndex = s;
            }
        }

        var representative = samples[bestIndex];
        var close = [];
        for (var c = 0; c < samples.length; c++) {
            if (colorDistance(samples[c], representative) < 0.12) {
                close.push(samples[c]);
            }
        }
        if (close.length === 0) {
            close = samples;
        }

        var sum = [0, 0, 0];
        for (var k = 0; k < close.length; k++) {
            sum[0] += close[k][0];
            sum[1] += close[k][1];
            sum[2] += close[k][2];
        }
        return [sum[0] / close.length, sum[1] / close.length, sum[2] / close.length];
    }

    function estimateCornerColor(comp, layer, config) {
        var w = layer.source.width;
        var h = layer.source.height;
        var inset = Math.max(0, config.cornerInsetPixels);
        log("Corner sample dimensions: " + w + "x" + h + ", inset=" + inset);
        var pts = [
            [inset, inset],
            [w - 1 - inset, inset],
            [inset, h - 1 - inset],
            [w - 1 - inset, h - 1 - inset]
        ];
        return averageSamples(comp, layer, pts, config.sampleRadius);
    }

    function estimateEdgeColor(comp, layer, config) {
        var w = layer.source.width;
        var h = layer.source.height;
        var marginX = Math.max(2, Math.round(w * config.sampleEdgePercent));
        var marginY = Math.max(2, Math.round(h * config.sampleEdgePercent));
        log("Edge sample dimensions: " + w + "x" + h + ", margin=" + marginX + "x" + marginY);
        var pts = [
            [marginX, marginY],
            [w / 2, marginY],
            [w - marginX, marginY],
            [marginX, h / 2],
            [w - marginX, h / 2],
            [marginX, h - marginY],
            [w / 2, h - marginY],
            [w - marginX, h - marginY]
        ];
        return averageSamples(comp, layer, pts, config.sampleRadius);
    }

    function resolveKeyColor(comp, layer, config) {
        var mode = String(config.keyMode || "auto").toLowerCase();
        if (mode === "custom") {
            if (config.customKeyColorHex) {
                config.customKeyColor = parseHexColor(config.customKeyColorHex);
            }
            return { name: "custom", color: config.customKeyColor };
        }
        if (mode !== "auto" && PRESET_COLORS[mode]) {
            return { name: mode, color: PRESET_COLORS[mode] };
        }
        if (isAutomation(config) && !config.sampleAutoInAutomation) {
            log("Automation auto mode using green fallback; set sampleAutoInAutomation=true to use expression sampling.");
            return { name: "green", color: PRESET_COLORS.green };
        }

        var sampled;
        try {
            if (String(config.autoSampleStrategy || "corners").toLowerCase() === "edges") {
                sampled = estimateEdgeColor(comp, layer, config);
            } else {
                sampled = estimateCornerColor(comp, layer, config);
            }
        } catch (e) {
            log("WARNING: Auto key sampling failed; falling back to green: " + e.toString());
            return { name: "green", color: PRESET_COLORS.green };
        }
        if (config.useSampleAverage) {
            return { name: "sampleAverage", color: sampled };
        }
        var presetName = nearestPresetName(sampled);
        return { name: presetName, color: PRESET_COLORS[presetName], sampled: sampled };
    }

    function effectAvailable(matchName) {
        try {
            for (var i = 0; i < app.effects.length; i++) {
                if (app.effects[i].matchName === matchName) {
                    log("Effect available: " + app.effects[i].displayName + " (" + matchName + ")");
                    return true;
                }
            }
        } catch (e) {
            log("WARNING: Could not inspect app.effects: " + e.toString());
            return true;
        }
        log("Effect unavailable: " + matchName);
        return false;
    }

    function checkCapabilities(config) {
        if (!effectAvailable("Keylight 906")) {
            throw new Error("Required Keylight effect is not installed: Keylight 906.");
        }
        if (config.addKeyCleaner) {
            effectAvailable("ADBE KeyCleaner");
        }
        if (config.addAdvancedSpillSuppressor) {
            effectAvailable("ADBE Spill2");
        }
    }

    function isValueProperty(prop) {
        try {
            return prop.propertyType === PropertyType.PROPERTY;
        } catch (e) {
            return false;
        }
    }

    function findPropertyRecursive(group, names) {
        if (!group) {
            return null;
        }
        for (var i = 1; i <= group.numProperties; i++) {
            var p = group.property(i);
            for (var n = 0; n < names.length; n++) {
                if ((p.name === names[n] || p.matchName === names[n]) && isValueProperty(p)) {
                    return p;
                }
            }
            if (p.numProperties && p.numProperties > 0) {
                var found = findPropertyRecursive(p, names);
                if (found) {
                    return found;
                }
            }
        }
        return null;
    }

    function setIfFound(effect, names, value) {
        var prop = findPropertyRecursive(effect, names);
        if (prop) {
            try {
                prop.setValue(value);
                log("Set " + prop.name + " = " + value);
                return true;
            } catch (e) {
                log("Could not set " + prop.name + ": " + e.toString());
                return false;
            }
        }
        log("Could not find Keylight property: " + names.join(" / "));
        return false;
    }

    function keylightColorValue(color) {
        var epsilon = 0.001;
        function clamp(v) {
            return Number(Math.max(epsilon, Math.min(1 - epsilon, v)));
        }
        return new Array(clamp(color[0]), clamp(color[1]), clamp(color[2]));
    }

    function setKeylightScreenColor(keylight, color) {
        var value = keylightColorValue(color);
        if (color[0] === 0 && color[1] === 1 && color[2] === 0) {
            value = [0.001, 0.999, 0.001];
        }
        var prop = keylight.property("Keylight 906-0004");
        try {
            log("Screen Colour target = " + value[0] + "," + value[1] + "," + value[2]);
            prop.setValue(value);
            log("Set Screen Colour = " + value);
            return true;
        } catch (directErr) {
            log("Direct Screen Colour set failed: " + directErr.toString());
            try {
                prop.expression = "[" + value[0] + "," + value[1] + "," + value[2] + ",1]";
                prop.expressionEnabled = true;
                log("Set Screen Colour expression fallback = " + prop.expression);
                return true;
            } catch (expressionErr) {
                log("Screen Colour expression fallback failed: " + expressionErr.toString());
                return setIfFound(keylight, ["Screen Colour", "Screen Color"], value);
            }
        }
    }

    function applyKeylight(layer, keyInfo, config) {
        var effects = layer.property("ADBE Effect Parade");
        var keylight = effects.addProperty("Keylight 906");

        setKeylightScreenColor(keylight, keyInfo.color);
        keylight.name = "Keylight - " + keyInfo.name;

        if (config.keylight.screenGain !== null) {
            setIfFound(keylight, ["Screen Gain"], config.keylight.screenGain);
        }
        if (config.keylight.screenBalance !== null) {
            setIfFound(keylight, ["Screen Balance"], config.keylight.screenBalance);
        }
        if (config.keylight.screenPreblur !== null) {
            setIfFound(keylight, ["Screen Pre-blur", "Screen Preblur"], config.keylight.screenPreblur);
        }
        if (config.keylight.clipBlack !== null) {
            setIfFound(keylight, ["Clip Black"], config.keylight.clipBlack);
        }
        if (config.keylight.clipWhite !== null) {
            setIfFound(keylight, ["Clip White"], config.keylight.clipWhite);
        }

        return keylight;
    }

    function tryAddEffect(layer, matchName, label) {
        if (!effectAvailable(matchName)) {
            log("Skipping " + label + " because it is unavailable.");
            return null;
        }
        try {
            var effects = layer.property("ADBE Effect Parade");
            var effect = effects.addProperty(matchName);
            effect.name = label;
            log("Added " + label + " (" + matchName + ")");
            return effect;
        } catch (e) {
            log("Could not add " + label + ": " + e.toString());
            return null;
        }
    }

    function applyOutputTemplate(rqItem, templates) {
        var available = rqItem.outputModule(1).templates;
        log("Available output templates: " + available.join(", "));
        for (var i = 0; i < templates.length; i++) {
            var templateAvailable = false;
            for (var a = 0; a < available.length; a++) {
                if (available[a] === templates[i]) {
                    templateAvailable = true;
                    break;
                }
            }
            if (!templateAvailable) {
                log("Output template unavailable, skipping: " + templates[i]);
                continue;
            }
            try {
                rqItem.outputModule(1).applyTemplate(templates[i]);
                // The guide documents invalidation after OM edits; inspect a fresh reference.
                var settings = rqItem.outputModule(1).getSettings(GetSettingsFormat.STRING);
                if ((settings.Format !== "PNG Sequence" && settings.Format !== "TIFF Sequence") ||
                    settings.Channels !== "RGB + Alpha") {
                    log("Rejected output template: " + templates[i] + " " + settings.Format + " " + settings.Channels);
                    continue;
                }
                log("Applied output module template: " + templates[i]);
                return templates[i];
            } catch (e) {
                log("Output template failed: " + templates[i]);
            }
        }
        throw new Error("No configured alpha output module template is available. Available templates: " + available.join(", "));
    }

    function queueRender(comp, outputFolder, outputBaseName, config) {
        var rqItem = app.project.renderQueue.items.add(comp);
        CREATED.rqItem = rqItem;   // so cleanup can take it back out (see CREATED)
        try {
            rqItem.applyTemplate(config.renderSettingsTemplate);
            log("Applied render settings template: " + config.renderSettingsTemplate);
        } catch (e) {
            log("Render settings template failed: " + config.renderSettingsTemplate);
        }
        rqItem.timeSpanStart = 0;
        rqItem.timeSpanDuration = comp.frameDuration;
        var templateUsed = applyOutputTemplate(rqItem, config.outputModuleTemplates);
        var settings = rqItem.outputModule(1).getSettings(GetSettingsFormat.STRING);
        var ext = settings.Format === "PNG Sequence" ? "png" : "tif";
        // AE 26.5 fails with error 784 for name.tif without a token. Adobe's still-image
        // export docs require [#####] even when timeSpanDuration is only one frame.
        var outputPath = outputFolder.fsName + "/" + outputBaseName + "_[#####]." + ext;
        rqItem.outputModule(1).file = File(outputPath);
        log("Output settings: " + rqItem.outputModule(1).getSettings(GetSettingsFormat.STRING).toSource());

        if (config.renderImmediately) {
            var paused = [];
            try {
                // render() runs the whole queue, including unrelated user jobs unless disabled.
                for (var i = 1; i <= app.project.renderQueue.numItems; i++) {
                    var other = app.project.renderQueue.item(i);
                    if (other !== rqItem && other.status === RQItemStatus.QUEUED) {
                        paused.push(other);
                        other.render = false;
                    }
                }
                app.project.renderQueue.render();
                if (rqItem.status !== RQItemStatus.DONE) {
                    throw new Error("Still render did not complete: " + rqItem.status);
                }
            } finally {
                for (var j = 0; j < paused.length; j++) { paused[j].render = true; }
            }
            var escaped = outputBaseName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
            var pattern = new RegExp("^" + escaped + "_[0-9]+\\." + ext + "$", "i");
            var frames = outputFolder.getFiles(function (f) {
                return f instanceof File && pattern.test(File.decode(f.name)) && f.length > 0;
            });
            if (frames.length !== 1) { throw new Error("Expected one completed still, found " + frames.length); }
            outputPath = frames[0].fsName;
        }
        return {
            outputPath: outputPath,
            outputFolder: outputFolder,
            outputBaseName: outputBaseName,
            ext: ext,
            templateUsed: templateUsed
        };
    }

    function main() {
        CONFIG = readConfigFromJson(CONFIG);
        ACTIVE_CONFIG = CONFIG;
        initLogFile(CONFIG);
        CONFIG = showInteractiveDialog(CONFIG);
        ACTIVE_CONFIG = CONFIG;
        initLogFile(CONFIG);
        log("Automation mode: " + isAutomation(CONFIG));
        if (!isAutomation(CONFIG)) {
            app.beginUndoGroup("H5G Chroma Key Still Export");
            DID_BEGIN_UNDO = true;
        }
        checkCapabilities(CONFIG);

        var sourceFile = chooseSourceFile(CONFIG);
        if (!sourceFile) {
            throw new Error("No source file selected.");
        }
        if (!sourceFile.exists) {
            throw new Error("Source file does not exist: " + sourceFile.fsName);
        }
        validateSourceImage(sourceFile, CONFIG);

        var outputFolder = chooseOutputFolder(CONFIG);
        if (!outputFolder) {
            throw new Error("No output folder selected.");
        }

        var outputName = CONFIG.outputName || baseNameWithoutExtension(sourceFile) + "_keyed";

        log("Source: " + sourceFile.fsName);
        var footage = importFootage(sourceFile);
        CREATED.footage = footage;
        var made = makeCompFromFootage(footage, CONFIG);
        CREATED.comp = made.comp;
        var keyInfo = resolveKeyColor(made.comp, made.layer, CONFIG);
        log("Key mode resolved: " + keyInfo.name + " RGB=" + keyInfo.color[0] + "," + keyInfo.color[1] + "," + keyInfo.color[2]);
        if (keyInfo.sampled) {
            log("Sampled edge RGB=" + keyInfo.sampled);
        }

        applyKeylight(made.layer, keyInfo, CONFIG);
        if (CONFIG.addKeyCleaner) {
            tryAddEffect(made.layer, "ADBE KeyCleaner", "Key Cleaner");
        }
        if (CONFIG.addAdvancedSpillSuppressor) {
            tryAddEffect(made.layer, "ADBE Spill2", "Advanced Spill Suppressor");
        }

        var renderInfo = queueRender(made.comp, outputFolder, outputName, CONFIG);
        var finalOutputs = [renderInfo.outputPath];
        log("Done. Final output: " + finalOutputs.join(", "));
        return finalOutputs.join(", ");
    }

    var RESULT;
    try {
        RESULT = "OK: " + main();
    } catch (e) {
        // Return the error as a status string (osascript stdout) so Navigator can
        // surface it — no blocking alert (invisible when the user is in Navigator).
        RESULT = "ERROR: " + e.toString();
    } finally {
        // Always — success or failure. The rendered PNG is already on disk by this
        // point (Navigator reads it from the filesystem, not from AE), so
        // removing the project items can't affect the output.
        try { cleanupCreatedItems(); } catch (cleanErr) {}
        try {
            if (DID_BEGIN_UNDO) {
                app.endUndoGroup();
            }
        } catch (endErr) {
        }
        // AE 26.5 DoScript returns 0 over AppleScript even when JSX returns a string.
        // Navigator must read completion from a file, not treat that 0 as render success.
        if (ACTIVE_CONFIG && ACTIVE_CONFIG.resultFile) {
            var resultFile = makeFile(ACTIVE_CONFIG.resultFile);
            if (resultFile.open("w")) {
                resultFile.write(RESULT);
                resultFile.close();
            }
        }
        if (ACTIVE_CONFIG && ACTIVE_CONFIG.quitWhenDone) {
            app.quit();
        }
    }
    return RESULT;  // returned to osascript stdout
})();
