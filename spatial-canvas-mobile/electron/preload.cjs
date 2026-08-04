"use strict";

const { contextBridge, ipcRenderer } = require("electron");

const CHANNELS = Object.freeze({
  appInfo: "spatial:app-info",
  pickFiles: "spatial:pick-files",
  openExternal: "spatial:open-external",
  beforeClose: "spatial:before-close",
  closeReady: "spatial:close-ready",
});

contextBridge.exposeInMainWorld(
  "spatialDesktop",
  Object.freeze({
    getAppInfo: () => ipcRenderer.invoke(CHANNELS.appInfo),
    pickFiles: (options) => ipcRenderer.invoke(CHANNELS.pickFiles, options),
    openExternal: (url) => ipcRenderer.invoke(CHANNELS.openExternal, url),
    onBeforeClose: (callback) => {
      if (typeof callback !== "function") {
        throw new TypeError("onBeforeClose requires a callback");
      }

      const listener = () => callback();
      ipcRenderer.on(CHANNELS.beforeClose, listener);
      return () => ipcRenderer.removeListener(CHANNELS.beforeClose, listener);
    },
    confirmCloseReady: () => ipcRenderer.send(CHANNELS.closeReady),
  }),
);

