{{flutter_js}}
{{flutter_build_config}}

// Serve the rendering engine from our own origin instead of a third-party CDN
// (privacy, offline-friendly, works behind restrictive networks).
_flutter.loader.load({
  config: { canvasKitBaseUrl: "canvaskit/" },
});
