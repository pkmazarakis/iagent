# Spatial

A React reconstruction of Spatial's fast, direct-manipulation board, designed to run identically in a browser and in an Electron shell.

## Run the web app

```bash
pnpm install
pnpm dev
```

Open <http://127.0.0.1:5173/>.

## Run the desktop app

```bash
pnpm electron:dev
```

For a packaged macOS build:

```bash
pnpm electron:dist
```

## What is implemented

- Infinite-feeling pan and zoom canvas with marquee selection
- Multi-item drag, resize handles, alignment snapping and haptic feedback when available
- Contextual toolbar with live radial color editing
- Organic stacks: create, collapse, expand, rename, unpack, extract and restore
- Shared-element detail/editor transitions for notes, documents, tasks and images
- Notes, task lists, URL clips, image import/drop, scratch pad and board switching
- Undo/redo shortcuts and local-first IndexedDB persistence
- Electron preload bridge with the same built renderer used by the web app

## Verification

```bash
pnpm test
pnpm build
```
