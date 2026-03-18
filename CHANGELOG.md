# Changelog

## v1.2.1 — March 18, 2026

### What's New
- Servers protected by auth proxies (Authelia, Authentik, Keycloak, oauth2-proxy, etc.) now show a sign-in WebView instead of a "proxy authentication" error, letting you authenticate through whatever portal your server uses.

### Improvements
- Welcome screen prompt suggestions are now sourced from the server's.
- Allow STT language change within the call feature.
- Tapping an audio attachment chip after on-device transcription now opens a preview sheet showing the full transcript text, with a copy button, before sending.
- Audio files attached in chat are now uploaded to the server by default (server handles transcription automatically). On-Device transcription is available as an alternative in Settings → Speech-to-Text → Audio File Transcription.

### Bug Fixes
- File attachments now show a distinct "Processing…" spinner for server-side transcription as well after upload completes, so you can see when the server is indexing or transcribing the file before it's ready to send.
- Fixed audio file transcription being cancelled when navigating away from a chat — transcription now continues in the background and completes even if you switch chats.
- Fixed channels incorrectly showing as read-only for the channel owner and members with write access when access grants were present.
- Fixed background chat content (e.g. prompt cards) being accidentally tappable or scrollable while swiping to open the left or right drawer panel.
- Fixed function calling mode not being respected — the app was incorrectly overriding the server's per-model setting; it now lets the server control this entirely, matching the web client behavior.

## v1.2 — March 16, 2026

### What's New
- Added Channels — collaborative, topic-based chat rooms where multiple users and AI models interact.
- Added Accessibility settings with customizable text scaling — independently adjust message text, conversation titles, and UI elements (buttons, icons, spacing) with live preview and quick presets.
- Added slash command prompt library — type `/` in the chat input to browse and search your Open WebUI prompt library.

### Improvements
- Inline source citations now appear as small, elevated pill badges showing shortened page titles or domain names — matching the Open WebUI web interface style.
- Profile/model avatars will now show properly.

### Bug Fixes
- Fixed repeated `heartbeat() missing 1 required positional argument: 'data'` errors in Open WebUI server logs
- Fixed web search, image generation, and code interpreter toggles being ignored when turned off mid-chat — toggling a tool off now correctly prevents it from being used.
- Fixed conversations older than "This Month" not loading — pagination now properly triggers when scrolling to the bottom, allowing all conversation history to load.

## Previous Builds

## v1.1.0 — March 12, 2026

### What's New
- Added Cloudflare protected endpoint support.

### Improvements
- Full iPad layout overhaul — persistent sidebar, centered reading width, 4-column prompt grid, terminal as persistent panel.
- Added example URL placeholder in the server connection field so users know to include http:// or https:// in their URL.
- Moved the terminal toggle from the pills row to a compact inline icon next to the voice button, keeping the chat input single-line when no quick pills are pinned.
- Redesigned onboarding experience.

### Bug Fixes
- Fixed dollar amounts being incorrectly rendered as math equations instead of plain text.
- Fixed stale model list persisting after signing out and logging into a different server or account — models now refresh correctly without needing to restart the app.
- Fixed model avatars not updating when changed by the admin — avatar images are now properly invalidated and re-fetched on each model refresh.
- Fixed false proxy error on Cloudflare-protected servers.

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
