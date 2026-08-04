import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App.jsx";
import { installFrameProbe } from "./performance/frameProbe.js";
import "./styles.css";

installFrameProbe();

createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
