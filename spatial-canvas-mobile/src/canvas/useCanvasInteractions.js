import { useEffect, useRef } from "react";
import { createCanvasInteractionController } from "./interactions.js";

/**
 * React lifecycle wrapper around `createCanvasInteractionController`.
 * The controller is created once; callback/config changes are read through a
 * ref, so active pointer gestures are not interrupted by React renders.
 */
export function useCanvasInteractions(options) {
  const optionsRef = useRef(options);
  optionsRef.current = options;
  const controllerRef = useRef(null);
  const lifecycleRef = useRef(0);

  if (controllerRef.current === null) {
    controllerRef.current = createCanvasInteractionController({
      getSnapshot: () => optionsRef.current.getSnapshot(),
      onCameraChange: (...args) => optionsRef.current.onCameraChange?.(...args),
      onItemsChange: (...args) => optionsRef.current.onItemsChange?.(...args),
      onSelectionChange: (...args) =>
        optionsRef.current.onSelectionChange?.(...args),
      onMarqueeChange: (...args) =>
        optionsRef.current.onMarqueeChange?.(...args),
      onSnapChange: (...args) => optionsRef.current.onSnapChange?.(...args),
      onHaptic: (...args) => optionsRef.current.onHaptic?.(...args),
      onInteractionChange: (...args) =>
        optionsRef.current.onInteractionChange?.(...args),
      requestFrame: options.requestFrame,
      cancelFrame: options.cancelFrame,
      zoom: options.zoom,
      snap: options.snap,
    });
  }

  useEffect(() => {
    const controller = controllerRef.current;
    const lifecycle = ++lifecycleRef.current;
    return () => {
      // React Strict Mode replays effects as setup → cleanup → setup. A
      // synchronous destroy here permanently disabled the controller during
      // development, so trackpad wheel and pinch events were silently queued
      // into a dead instance. Defer one microtask and only destroy if no newer
      // setup has taken ownership.
      queueMicrotask(() => {
        if (lifecycleRef.current === lifecycle) controller.destroy();
      });
    };
  }, []);

  return controllerRef.current;
}
