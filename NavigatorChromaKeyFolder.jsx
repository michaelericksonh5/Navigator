/*
Batch Chroma Key Folder for After Effects
=========================================

Reads a folder batch config, then runs chroma_key_still.jsx once per PNG.
This file is intended to be launched by run.bat.
*/

(function chromaKeyFolderBatch() {
    function normalizePath(path) {
        return String(path || "").replace(/\\/g, "/");
    }

    function makeFile(path) {
        return File(normalizePath(path));
    }

    function makeFolder(path) {
        return Folder(normalizePath(path));
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

    function scriptFolder() {
        try {
            return File($.fileName).parent;
        } catch (e) {
            return Folder.current;
        }
    }

    function configFile() {
        if ($.global && $.global.H5G_BATCH_CONFIG_FILE) {
            return makeFile($.global.H5G_BATCH_CONFIG_FILE);
        }
        return File(scriptFolder().fsName + "/chroma_key_folder_config.json");
    }

    function ensureFolder(folderObj) {
        if (!folderObj.exists && !folderObj.create()) {
            throw new Error("Could not create folder: " + folderObj.fsName);
        }
        return folderObj;
    }

    function appendLog(logFile, message) {
        $.writeln("[chroma_key_folder] " + message);
        if (!logFile) {
            return;
        }
        logFile.open(logFile.exists ? "a" : "w");
        logFile.write("[chroma_key_folder] " + message + "\n");
        logFile.close();
    }

    function powerShellQuote(text) {
        return "'" + String(text).replace(/'/g, "''") + "'";
    }

    function shQuote(text) {
        return "'" + String(text).replace(/'/g, "'\\''") + "'";
    }

    // Cross-platform TIFF->PNG fallback. Windows: PowerShell/System.Drawing.
    // macOS: sips (ships with the OS, preserves alpha).
    function convertImageToPng(inputFile, outputFile) {
        var command, scriptFile = null;
        if (File.fs === "Windows") {
            scriptFile = File(outputFile.parent.fsName + "/h5g_convert_to_png.ps1");
            var script =
                "$ErrorActionPreference = 'Stop'\n" +
                "Add-Type -AssemblyName System.Drawing\n" +
                "$src = " + powerShellQuote(inputFile.fsName) + "\n" +
                "$dst = " + powerShellQuote(outputFile.fsName) + "\n" +
                "$img = [System.Drawing.Image]::FromFile($src)\n" +
                "try { $img.Save($dst, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $img.Dispose() }\n";
            scriptFile.open("w");
            scriptFile.write(script);
            scriptFile.close();
            command = 'cmd.exe /c powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + scriptFile.fsName + '"';
        } else {
            command = "sips -s format png " + shQuote(inputFile.fsName) + " --out " + shQuote(outputFile.fsName);
        }
        var result = system.callSystem(command);
        for (var i = 0; i < 20 && !outputFile.exists; i++) {
            $.sleep(250);
        }
        if (outputFile.exists) {
            if (scriptFile) { try { scriptFile.remove(); } catch (cleanupErr) {} }
            return outputFile;
        }
        throw new Error("PNG conversion failed for " + inputFile.fsName + ". " + result);
    }

    function renderedFilesForBase(outputFolder, outputName) {
        var pngs = outputFolder.getFiles(outputName + "_*.png");
        if (pngs.length > 0) {
            return pngs;
        }
        var tifs = outputFolder.getFiles(outputName + "_*.tif");
        if (tifs.length > 0) {
            return tifs;
        }
        return outputFolder.getFiles(outputName + "_*.tiff");
    }

    function convertRenderedFiles(outputFolder, outputName, deleteIntermediate) {
        var files = renderedFilesForBase(outputFolder, outputName);
        var converted = [];
        for (var i = 0; i < files.length; i++) {
            var fileObj = files[i];
            if (/\.png$/i.test(fileObj.name)) {
                converted.push(fileObj.fsName);
                continue;
            }
            var pngFile = File(fileObj.parent.fsName + "/" + fileObj.name.replace(/\.(tif|tiff)$/i, ".png"));
            converted.push(convertImageToPng(fileObj, pngFile).fsName);
            if (deleteIntermediate) {
                try {
                    fileObj.remove();
                } catch (e) {
                }
            }
        }
        return converted;
    }

    function baseNameWithoutExtension(fileObj) {
        var name = fileObj.name;
        var idx = name.lastIndexOf(".");
        return idx > 0 ? name.substring(0, idx) : name;
    }

    function pngFiles(folderObj) {
        return folderObj.getFiles(function (fileObj) {
            return fileObj instanceof File && /\.png$/i.test(fileObj.name);
        });
    }

    function main() {
        var cfgFile = configFile();
        if (!cfgFile.exists) {
            throw new Error("Batch config does not exist: " + cfgFile.fsName);
        }

        var config = parseJsonText(readTextFile(cfgFile));
        var sourceFolder = makeFolder(config.sourceFolder);
        var outputFolder = ensureFolder(makeFolder(config.outputFolder));
        var singleScript = config.singleScript ? makeFile(config.singleScript) : File(scriptFolder().fsName + "/chroma_key_still.jsx");
        var logFile = makeFile(config.logFile || (outputFolder.fsName + "/chroma_key_folder.log"));

        appendLog(logFile, "Batch config: " + cfgFile.fsName);
        appendLog(logFile, "Source folder: " + sourceFolder.fsName);
        appendLog(logFile, "Output folder: " + outputFolder.fsName);
        appendLog(logFile, "Single-image script: " + singleScript.fsName);

        if (!sourceFolder.exists) {
            throw new Error("Source folder does not exist: " + sourceFolder.fsName);
        }
        if (!singleScript.exists) {
            throw new Error("Single-image script does not exist: " + singleScript.fsName);
        }

        var files = pngFiles(sourceFolder);
        if (files.length === 0) {
            throw new Error("No PNG files found in " + sourceFolder.fsName);
        }

        try {
            app.project.renderQueue.queueNotify = false;
        } catch (notifyErr) {
            appendLog(logFile, "Queue notify disable unavailable: " + notifyErr.toString());
        }

        var queued = [];
        var queueFailed = 0;
        var outputFailed = 0;
        for (var i = 0; i < files.length; i++) {
            var source = files[i];
            var outputName = baseNameWithoutExtension(source) + (config.outputSuffix || "_rmbg");
            appendLog(logFile, "Queueing " + (i + 1) + "/" + files.length + ": " + source.fsName);

            try {
                $.global.H5G_CHROMA_KEY_CONFIG = {
                    sourceFile: source.fsName,
                    outputFolder: outputFolder.fsName,
                    outputName: outputName,
                    automationMode: true,
                    showUi: false,
                    keyMode: config.keyMode || "auto",
                    customKeyColorHex: config.customKeyColorHex || "#00FF00",
                    useSampleAverage: config.useSampleAverage !== false,
                    sampleAutoInAutomation: config.sampleAutoInAutomation !== false,
                    autoSampleStrategy: config.autoSampleStrategy || "corners",
                    renderImmediately: false,
                    finalOutputFormat: "png",
                    deleteIntermediateRender: config.deleteIntermediateRender !== false,
                    logFile: outputFolder.fsName + "/" + outputName + ".log"
                };
                $.evalFile(singleScript);
                queued.push({ sourceName: source.name, outputName: outputName });
                appendLog(logFile, "Queued: " + source.name);
            } catch (itemErr) {
                queueFailed++;
                appendLog(logFile, "FAILED TO QUEUE: " + source.name + " :: " + itemErr.toString());
            }
        }

        if (queued.length > 0) {
            var rq = app.project.renderQueue;
            for (var r = 1; r <= rq.numItems; r++) {
                try {
                    rq.item(r).queueItemNotify = false;
                } catch (itemNotifyErr) {
                }
            }

            appendLog(logFile, "Rendering queued items once. Count=" + queued.length);
            app.beginSuppressDialogs();
            try {
                rq.render();
            } finally {
                app.endSuppressDialogs(false);
            }
            appendLog(logFile, "Render pass complete.");

            for (var q = 0; q < queued.length; q++) {
                var outputs = renderedFilesForBase(outputFolder, queued[q].outputName);
                if (outputs.length > 0) {
                    appendLog(logFile, "Rendered output: " + queued[q].sourceName + " -> " + outputs.join(", "));
                } else {
                    outputFailed++;
                    appendLog(logFile, "FAILED OUTPUT: " + queued[q].sourceName + " :: no rendered file found");
                }
            }
        }

        var failed = queueFailed + outputFailed;
        var succeeded = queued.length - outputFailed;
        appendLog(logFile, "Complete. Succeeded=" + succeeded + " Failed=" + failed);
        if (failed > 0) {
            throw new Error("Batch completed with failures. See " + logFile.fsName);
        }
    }

    try {
        main();
    } catch (e) {
        $.writeln("[chroma_key_folder] ERROR: " + e.toString());
        throw e;
    }
})();
