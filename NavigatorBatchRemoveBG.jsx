/**
 * Navigator — Batch Remove Background.
 * Driven by Navigator: processes every image whose name ends in "_rmbg" inside
 * the folder passed as arguments[0] (and its subfolders), in place. Navigator
 * has already duplicated each original to a "<name>_rmbg" copy, so originals are
 * never touched — only the copies. Skips "EN" folders. Trim defaults OFF (keeps
 * the original canvas size), matching the original batch script.
 *
 * Falls back to the interactive folder-picker GUI if run manually with no
 * argument. Bundled inside Navigator.app so no one has to keep it on disk.
 */

#target photoshop
app.bringToFront();

var SKIP_FOLDERS = ["EN", "en"];
var IMAGE_EXTENSIONS = [".jpg", ".jpeg", ".png", ".psd", ".tif", ".tiff", ".bmp"];
var TARGET = (typeof arguments !== "undefined" && arguments.length > 0) ? String(arguments[0]) : null;

// ============================================
// FILE PROCESSING
// ============================================
function processFolder(rootFolder, shouldTrim, onlyRmbg) {
    var imageFiles = collectImageFiles(rootFolder, onlyRmbg);

    if (imageFiles.length === 0) {
        alert("No image files found to process in:\n" + rootFolder.fsName);
        return;
    }

    var startTime = new Date();
    var processed = 0;
    var errors = 0;
    var errorLog = [];
    var criticalStop = false;
    var criticalReason = "";
    var stoppedAt = "";
    var originalDialogMode = app.displayDialogs;

    app.displayDialogs = DialogModes.NO;
    try {
        for (var i = 0; i < imageFiles.length; i++) {
            var file = imageFiles[i];
            var doc = null;

            try {
                doc = openDocumentWithRetry(file);
                removeBackground(doc, shouldTrim);
                doc.save();
                doc.close(SaveOptions.DONOTSAVECHANGES);
                purgeCachesSafely();
                processed++;
            } catch (e) {
                errors++;
                errorLog.push(file.name + ": " + e.message);

                try {
                    if (doc !== null) {
                        doc.close(SaveOptions.DONOTSAVECHANGES);
                    }
                } catch (closeErr) {}

                if (isCriticalBatchError(e)) {
                    criticalStop = true;
                    criticalReason = e.message;
                    stoppedAt = file.name;
                    break;
                }
            }
        }
    } finally {
        app.displayDialogs = originalDialogMode;
    }

    var endTime = new Date();
    var duration = (endTime - startTime) / 1000;

    var message = "Remove Background Complete!\n\n";
    message += "Trim enabled: " + (shouldTrim ? "Yes" : "No (default)") + "\n";
    message += "Total images: " + imageFiles.length + "\n";
    message += "Successfully processed: " + processed + "\n";
    message += "Errors: " + errors + "\n";
    message += "Time: " + duration.toFixed(1) + " seconds";

    if (criticalStop) {
        message += "\n\nStopped early at: " + stoppedAt;
        message += "\nReason: " + criticalReason;
        message += "\n\nAction required: free scratch disk space (or resolve cancellation),";
        message += "\nthen rerun the batch from this folder.";
    }

    if (errors > 0) {
        message += "\n\nErrors:\n" + errorLog.join("\n");
    }

    alert(message);
}

function removeBackground(doc, shouldTrim) {
    var layer = doc.activeLayer;

    if (!(layer && layer.typename === "ArtLayer")) {
        try {
            doc.flatten();
            layer = doc.activeLayer;
        } catch (e) {
            throw new Error("Cannot process layer type");
        }
    }

    try { layer.isBackgroundLayer = false; } catch (e) {}

    var id = stringIDToTypeID("removeBackground");
    executeAction(id, new ActionDescriptor(), DialogModes.NO);

    if (shouldTrim) {
        doc.trim(TrimType.TRANSPARENT, true, true, true, true);
    }
}

// ============================================
// FILE COLLECTION
// ============================================
function collectImageFiles(folder, onlyRmbg) {
    var imageFiles = [];

    function scanFolder(currentFolder, isRoot) {
        if (!isRoot && shouldSkipFolder(currentFolder.name)) {
            return;
        }

        var files = currentFolder.getFiles();
        for (var i = 0; i < files.length; i++) {
            var item = files[i];

            if (item instanceof Folder) {
                scanFolder(item, false);
            } else if (item instanceof File) {
                if (isImageFile(item.name) && (!onlyRmbg || isRmbgFile(item.name))) {
                    imageFiles.push(item);
                }
            }
        }
    }

    scanFolder(folder, true);
    imageFiles.sort(function (a, b) {
        var aName = a.fsName.toLowerCase();
        var bName = b.fsName.toLowerCase();
        if (aName < bName) return -1;
        if (aName > bName) return 1;
        return 0;
    });
    return imageFiles;
}

function openDocumentWithRetry(file) {
    try {
        return app.open(file);
    } catch (e) {
        if (isOpenOptionsError(e)) {
            $.sleep(200);
            return app.open(file);
        }
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

// True when the base name (before the extension) ends in "_rmbg" — the copies
// Navigator made. Keeps the batch from touching originals sitting alongside them.
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
    optionsPanel.add("statictext", undefined, "Default: OFF (keeps original canvas size).");
    optionsPanel.add("statictext", undefined, "Processes images in selected folder + subfolders (skips EN folder).");

    var buttonGroup = dialog.add("group");
    buttonGroup.orientation = "row";
    buttonGroup.alignment = "center";
    var processBtn = buttonGroup.add("button", undefined, "Process", {name: "ok"});
    buttonGroup.add("button", undefined, "Cancel", {name: "cancel"});
    processBtn.enabled = false;

    browseBtn.onClick = function () {
        var folder = Folder.selectDialog("Select folder containing image subfolders:");
        if (folder) { folderPath.text = folder.fsName; processBtn.enabled = true; }
    };
    folderPath.onChanging = function () { processBtn.enabled = folderPath.text !== ""; };
    processBtn.onClick = function () {
        var selectedFolder = new Folder(folderPath.text);
        if (!selectedFolder.exists) { alert("Selected folder does not exist."); return; }
        dialog.close(1);
        processFolder(selectedFolder, trimCheckbox.value, false);
    };
    dialog.show();
}

// ============================================
// RUN
// ============================================
if (TARGET) {
    var f = new Folder(TARGET);
    if (f.exists) processFolder(f, false, true); // only the _rmbg copies, no trim
    else alert("Folder does not exist:\n" + TARGET);
} else {
    showGUI();
}
