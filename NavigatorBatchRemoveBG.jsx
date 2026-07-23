/**
 * Navigator — Batch Remove Background.
 * Driven by Navigator: opens every ORIGINAL image in the folder passed as
 * arguments[0] (and its subfolders) and saves a keyed "<name>_rmbg.png" next to
 * it. Originals are opened read-only and never written; images already ending in
 * "_rmbg" are skipped, so re-running is safe and there's no pre-duplication.
 * Skips "EN" folders. Trim defaults OFF (keeps the original canvas size).
 *
 * In automation (Navigator) it RETURNS a status string ("OK: …" / "ERROR: …")
 * that osascript prints to stdout — no blocking, invisible alerts. The manual
 * folder-picker GUI (run with no argument) still shows a summary alert.
 * Bundled inside Navigator.app.
 */

#target photoshop
app.bringToFront();

var SKIP_FOLDERS = ["EN", "en"];
var IMAGE_EXTENSIONS = [".jpg", ".jpeg", ".png", ".psd", ".tif", ".tiff", ".bmp"];
var TARGET = (typeof arguments !== "undefined" && arguments.length > 0) ? String(arguments[0])
    : (($.global && $.global.NAV_ARG) ? String($.global.NAV_ARG) : null);

// ============================================
// FILE PROCESSING
// ============================================
// Returns { message, total, processed, errors }.
function processFolder(rootFolder, shouldTrim) {
    var imageFiles = collectImageFiles(rootFolder);
    if (imageFiles.length === 0) {
        return { message: "No images to process in:\n" + rootFolder.fsName, total: 0, processed: 0, errors: 0 };
    }

    var startTime = new Date();
    var processed = 0, errors = 0, errorLog = [];
    var criticalStop = false, criticalReason = "", stoppedAt = "";
    var originalDialogMode = app.displayDialogs;

    app.displayDialogs = DialogModes.NO;
    try {
        for (var i = 0; i < imageFiles.length; i++) {
            var file = imageFiles[i];
            var doc = null;
            try {
                doc = openDocumentWithRetry(file);
                removeBackground(doc, shouldTrim);
                saveKeyedAs(doc, rmbgOutputFor(file));      // "<name>_rmbg.png" alongside
                doc.close(SaveOptions.DONOTSAVECHANGES);     // discard changes to the original
                purgeCachesSafely();
                processed++;
            } catch (e) {
                errors++;
                errorLog.push(file.name + ": " + e.message);
                try { if (doc !== null) { doc.close(SaveOptions.DONOTSAVECHANGES); } } catch (closeErr) {}
                if (isCriticalBatchError(e)) {
                    criticalStop = true; criticalReason = e.message; stoppedAt = file.name; break;
                }
            }
        }
    } finally {
        app.displayDialogs = originalDialogMode;
    }

    var duration = ((new Date()) - startTime) / 1000;
    var message = "Remove Background Complete!\n\n";
    message += "Trim enabled: " + (shouldTrim ? "Yes" : "No (default)") + "\n";
    message += "Total images: " + imageFiles.length + "\n";
    message += "Successfully processed: " + processed + "\n";
    message += "Errors: " + errors + "\n";
    message += "Time: " + duration.toFixed(1) + " seconds";
    if (criticalStop) {
        message += "\n\nStopped early at: " + stoppedAt + "\nReason: " + criticalReason;
        message += "\n\nAction required: free scratch disk space (or resolve cancellation), then rerun.";
    }
    if (errors > 0) { message += "\n\nErrors:\n" + errorLog.join("\n"); }
    return { message: message, total: imageFiles.length, processed: processed, errors: errors };
}

// "foo.png" → File(".../foo_rmbg.png") in the same folder.
function rmbgOutputFor(file) {
    var name = file.name;
    var dot = name.lastIndexOf(".");
    var base = (dot > 0) ? name.substring(0, dot) : name;
    return new File(file.parent.fsName + "/" + base + "_rmbg.png");
}

// Explicit PNG saveAs so transparency persists (bare doc.save() on a PNG is unreliable).
function saveKeyedAs(doc, outFile) {
    var opts = new PNGSaveOptions();
    try { opts.compression = 6; } catch (e) {}
    doc.saveAs(outFile, opts, true, Extension.LOWERCASE);
}

function removeBackground(doc, shouldTrim) {
    var layer = doc.activeLayer;
    if (!(layer && layer.typename === "ArtLayer")) {
        try { doc.flatten(); layer = doc.activeLayer; }
        catch (e) { throw new Error("Cannot process layer type"); }
    }
    try { layer.isBackgroundLayer = false; } catch (e) {}
    var id = stringIDToTypeID("removeBackground");
    executeAction(id, new ActionDescriptor(), DialogModes.NO);
    if (shouldTrim) { doc.trim(TrimType.TRANSPARENT, true, true, true, true); }
}

// ============================================
// FILE COLLECTION — originals only (skip our own "_rmbg" outputs)
// ============================================
function collectImageFiles(folder) {
    var imageFiles = [];
    function scanFolder(currentFolder, isRoot) {
        if (!isRoot && shouldSkipFolder(currentFolder.name)) { return; }
        var files = currentFolder.getFiles();
        for (var i = 0; i < files.length; i++) {
            var item = files[i];
            if (item instanceof Folder) {
                scanFolder(item, false);
            } else if (item instanceof File) {
                if (isImageFile(item.name) && !isRmbgFile(item.name)) { imageFiles.push(item); }
            }
        }
    }
    scanFolder(folder, true);
    imageFiles.sort(function (a, b) {
        var aName = a.fsName.toLowerCase(), bName = b.fsName.toLowerCase();
        return aName < bName ? -1 : (aName > bName ? 1 : 0);
    });
    return imageFiles;
}

function openDocumentWithRetry(file) {
    try {
        return app.open(file);
    } catch (e) {
        if (isOpenOptionsError(e)) { $.sleep(200); return app.open(file); }
        throw e;
    }
}

function isOpenOptionsError(errorObj) {
    var msg = "";
    try { msg = String(errorObj.message || "").toLowerCase(); } catch (e) {}
    return msg.indexOf("open options are incorrect") !== -1;
}

function isCriticalBatchError(errorObj) {
    var msg = "";
    try { msg = String(errorObj.message || "").toLowerCase(); } catch (e) {}
    if (msg.indexOf("scratch disks are full") !== -1) return true;
    if (msg.indexOf("user cancelled") !== -1) return true;
    return false;
}

function purgeCachesSafely() {
    try { app.purge(PurgeTarget.ALLCACHES); } catch (e) {}
}

function shouldSkipFolder(folderName) {
    for (var i = 0; i < SKIP_FOLDERS.length; i++) {
        if (folderName === SKIP_FOLDERS[i]) return true;
    }
    return false;
}

function isImageFile(filename) {
    var lowerName = filename.toLowerCase();
    for (var i = 0; i < IMAGE_EXTENSIONS.length; i++) {
        if (lowerName.indexOf(IMAGE_EXTENSIONS[i]) === lowerName.length - IMAGE_EXTENSIONS[i].length) {
            return true;
        }
    }
    return false;
}

// True when the base name (before the extension) ends in "_rmbg" — our own
// outputs. Keeps the batch from re-processing results sitting alongside originals.
function isRmbgFile(filename) {
    var dot = filename.lastIndexOf(".");
    var base = (dot > 0) ? filename.substring(0, dot) : filename;
    return base.toLowerCase().indexOf("_rmbg") === base.length - 5;
}

// ============================================
// FALLBACK GUI (manual run, no argument)
// ============================================
function showGUI() {
    var dialog = new Window("dialog", "Batch Remove Background");
    dialog.alignChildren = "fill";
    dialog.add("statictext", undefined, "Select a folder to process all images in subfolders.").alignment = "left";

    var folderGroup = dialog.add("group");
    folderGroup.orientation = "row";
    folderGroup.alignChildren = "left";
    folderGroup.add("statictext", undefined, "Folder:").preferredSize.width = 50;
    var folderPath = folderGroup.add("edittext", undefined, "");
    folderPath.preferredSize.width = 350;
    var browseBtn = folderGroup.add("button", undefined, "Browse...");

    var optionsPanel = dialog.add("panel", undefined, "Options");
    optionsPanel.orientation = "column";
    optionsPanel.alignChildren = "left";
    var trimCheckbox = optionsPanel.add("checkbox", undefined, "Trim transparent pixels after remove background");
    trimCheckbox.value = false;
    optionsPanel.add("statictext", undefined, "Writes '<name>_rmbg.png' next to each original (skips EN folder).");

    var buttonGroup = dialog.add("group");
    buttonGroup.orientation = "row";
    buttonGroup.alignment = "center";
    var processBtn = buttonGroup.add("button", undefined, "Process", {name: "ok"});
    buttonGroup.add("button", undefined, "Cancel", {name: "cancel"});
    processBtn.enabled = false;

    browseBtn.onClick = function () {
        var folder = Folder.selectDialog("Select folder containing images:");
        if (folder) { folderPath.text = folder.fsName; processBtn.enabled = true; }
    };
    folderPath.onChanging = function () { processBtn.enabled = folderPath.text !== ""; };
    processBtn.onClick = function () {
        var selectedFolder = new Folder(folderPath.text);
        if (!selectedFolder.exists) { alert("Selected folder does not exist."); return; }
        dialog.close(1);
        alert(processFolder(selectedFolder, trimCheckbox.value).message);
    };
    dialog.show();
}

// ============================================
// RUN
// ============================================
var RESULT;
if (TARGET) {
    try {
        var f = new Folder(TARGET);
        if (!f.exists) throw new Error("Folder does not exist: " + TARGET);
        var r = processFolder(f, false);                 // originals → "<name>_rmbg.png", no trim
        RESULT = (r.errors > 0) ? ("ERROR: " + r.message) : ("OK: processed " + r.processed + " of " + r.total);
    } catch (e) {
        RESULT = "ERROR: " + e.toString();
    }
} else {
    showGUI();
    RESULT = "OK";
}
RESULT;  // returned to osascript stdout
