import { app, BrowserWindow, dialog, ipcMain, session, shell } from "electron";
import { readFile } from "node:fs/promises";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";

const rootDirectory = dirname(dirname(fileURLToPath(import.meta.url)));

const CHANNELS = Object.freeze({
  appInfo: "spatial:app-info",
  pickFiles: "spatial:pick-files",
  openExternal: "spatial:open-external",
  beforeClose: "spatial:before-close",
  closeReady: "spatial:close-ready",
});

/** @type {BrowserWindow | null} */
let mainWindow = null;
let forceClose = false;
let closeTimeout = null;

function parseHttpsUrl(value) {
  if (typeof value !== "string" || value.length > 4096) {
    throw new TypeError("invalid external URL");
  }

  const url = new URL(value);
  if (url.protocol !== "https:") {
    throw new TypeError("only HTTPS external URLs are allowed");
  }

  return url;
}

function isTrustedSender(event) {
  return Boolean(mainWindow && event.sender === mainWindow.webContents);
}

function sanitizePickerOptions(value) {
  const options = value && typeof value === "object" ? value : {};
  const requestedExtensions = typeof options.accept === "string"
    ? options.accept.split(",").map((entry) => entry.trim()).filter((entry) => /^\.[a-z0-9]+$/i.test(entry)).map((entry) => entry.slice(1).toLowerCase())
    : [];
  const extensions = typeof options.accept === "string" && options.accept.includes("image/*")
    ? [...new Set([...requestedExtensions, "png", "jpg", "jpeg", "gif", "webp", "avif"])]
    : [...new Set(requestedExtensions)];
  return {
    properties: options.multiple ? ["openFile", "multiSelections"] : ["openFile"],
    ...(extensions.length ? { filters: [{ name: "Supported files", extensions }] } : {}),
  };
}

function mimeTypeForPath(path) {
  const extension = extname(path).toLowerCase();
  if (extension === ".docx") return "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
  if (extension === ".pptx") return "application/vnd.openxmlformats-officedocument.presentationml.presentation";
  if (extension === ".xlsx") return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
  if (extension === ".png") return "image/png";
  if (extension === ".jpg" || extension === ".jpeg") return "image/jpeg";
  if (extension === ".gif") return "image/gif";
  if (extension === ".webp") return "image/webp";
  if (extension === ".avif") return "image/avif";
  return "application/octet-stream";
}

function registerIpcHandlers() {
  ipcMain.handle(CHANNELS.appInfo, (event) => {
    if (!isTrustedSender(event)) throw new Error("untrusted IPC sender");
    return { name: app.getName(), version: app.getVersion() };
  });

  ipcMain.handle(CHANNELS.pickFiles, async (event, options) => {
    if (!isTrustedSender(event) || !mainWindow) throw new Error("untrusted IPC sender");
    const result = await dialog.showOpenDialog(mainWindow, sanitizePickerOptions(options));
    if (result.canceled) return [];
    return Promise.all(result.filePaths.map(async (path) => {
      const data = await readFile(path);
      return {
        name: path.split(/[\\/]/).at(-1) ?? path,
        path,
        size: data.byteLength,
        type: mimeTypeForPath(path),
        bytes: new Uint8Array(data),
      };
    }));
  });

  ipcMain.handle(CHANNELS.openExternal, async (event, value) => {
    if (!isTrustedSender(event)) throw new Error("untrusted IPC sender");
    await shell.openExternal(parseHttpsUrl(value).toString());
  });

  ipcMain.on(CHANNELS.closeReady, (event) => {
    if (!isTrustedSender(event) || !mainWindow) return;
    forceClose = true;
    if (closeTimeout) clearTimeout(closeTimeout);
    mainWindow.close();
  });
}

async function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 900,
    minHeight: 640,
    titleBarStyle: "hiddenInset",
    backgroundColor: "#e5e9ea",
    show: false,
    webPreferences: {
      preload: join(rootDirectory, "electron", "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
    },
  });

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    try {
      void shell.openExternal(parseHttpsUrl(url).toString());
    } catch {
      // Invalid and non-HTTPS URLs remain blocked.
    }
    return { action: "deny" };
  });

  mainWindow.webContents.on("will-navigate", (event, targetUrl) => {
    const currentUrl = mainWindow?.webContents.getURL();
    if (currentUrl && new URL(targetUrl).origin === new URL(currentUrl).origin) return;
    event.preventDefault();
  });

  mainWindow.on("close", (event) => {
    if (forceClose || !mainWindow) return;
    event.preventDefault();
    mainWindow.webContents.send(CHANNELS.beforeClose);

    if (closeTimeout) clearTimeout(closeTimeout);
    closeTimeout = setTimeout(() => {
      forceClose = true;
      mainWindow?.close();
    }, 1200);
  });

  mainWindow.once("ready-to-show", () => mainWindow?.show());
  mainWindow.on("closed", () => {
    mainWindow = null;
  });

  const rendererUrl = process.env.SPATIAL_RENDERER_URL;
  if (rendererUrl) {
    await mainWindow.loadURL(rendererUrl);
  } else {
    await mainWindow.loadFile(join(rootDirectory, "dist", "index.html"));
  }
}

app.enableSandbox();
await app.whenReady();
session.defaultSession.setPermissionRequestHandler((_webContents, _permission, callback) => {
  callback(false);
});
registerIpcHandlers();
await createWindow();

app.on("activate", async () => {
  if (BrowserWindow.getAllWindows().length === 0) await createWindow();
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
