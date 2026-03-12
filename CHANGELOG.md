# Changelog

## 📦 NEXT BUILD

### What's New

### Improvements
- Full iPad layout overhaul

### Bug Fixes

## Previous Builds

## v1.0.0 — March 12, 2026

### What's New
- Added `@` model mention — type `@` in the chat input to quickly switch which model handles your message. Pick a model from the fluent popup, and a persistent chip appears in the composer showing the active override. The override stays until you dismiss it or pick a different model, letting you freely switch between models mid-conversation without changing the chat's default.
- Added Open Terminal integration — enable terminal access for AI models directly from the chat input pill, giving the model the ability to run commands, manage files, and interact with a real Linux environment.
- Added Terminal File Browser — swipe from the right edge to open a slide-over file panel with directory navigation, breadcrumb path bar, file upload, folder creation, file preview/download, and a built-in mini terminal for running commands directly.
- Added native SVG rendering in chat messages — AI-generated SVG code blocks now display as crisp, zoomable images with a header bar, Image/Source toggle, copy button, and fullscreen view with pinch-to-zoom and share sheet support.
- Added native Mermaid diagram rendering in chat messages (flowcharts, state, sequence, class, and ER diagrams rendered as beautiful images).
- Added Memories management (Settings → Personalization → Memories) — view, add, edit, and delete AI memories that persist across conversations.
- Added "Archive All Chats" option in the chat list menu for bulk archiving.

### Improvements
- App now sends timezone to the server on login, matching the web client for correct server-side date formatting.
- Archived chats endpoint now supports search, sort, and filter parameters for faster navigation.
- Matching formatting of content to the Open WebUI formatting.
- Sidebar drawer now slides smoothly with your finger.
- Returning to an existing chat now remembers the last model used in that conversation instead of reverting to the default model.
- Unified TTS and STT under a single mlx-audio-swift package, replacing two separate dependencies for smaller app size and easier maintenance.
- Improved audio transcription for long files with energy-based silence detection for smarter chunking at natural pauses.
- Smoother TTS audio playback with automatic crossfading between chunks, eliminating audio artifacts at sentence boundaries.
- User-attached images and files now display inline inside the message bubble instead of floating above it.

### Bug Fixes
- Fixed chat search using wrong query parameter, which could cause search to silently fail on some server versions.
- Fixed tag removal using incorrect API endpoint format (path-based instead of body-based DELETE).
- Fixed tag addition using wrong request body field name.
- Fixed tags list fetching from wrong endpoint, now uses the correct structured tags API.
- Fixed clone conversation not sending required request body.
- Fixed feature toggles (Web Search, Image Generation, Code Interpreter) still appearing in the tools menu even when the admin disabled the capability on the model. Toggles now respect per-model capabilities.
- Fixed tool-generated file download links opening in Safari instead of downloading within the app. Files are now downloaded and presented via the share sheet.
- Fixed some chats created from the app appearing blank or corrupted on the Open WebUI web interface.
- Fixed uploaded photos, PDFs, and other files not displaying on the Open WebUI web interface when sent from the app.
- Fixed chat view becoming pannable in all directions after follow-up suggestions appear, instead of strictly vertical scrolling.
- Fixed image uploads exceeding the 5 MB API limit by automatically downsampling photos to 2 megapixels before upload.
- Fixed external response stream not stopping when clicking the stop button.
