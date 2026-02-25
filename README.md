# Open UI

**A beautiful, native iOS client for [Open WebUI](https://openwebui.com).**

Chat with any AI model on your self-hosted Open WebUI server — right from your iPhone. Open UI is built 100% in SwiftUI and brings a fast, polished, native experience that the PWA can't match.

<p align="center">
  <img src="openui.gif" alt="Open UI Demo" width="300">
</p>

---

## What It Does

Open UI connects to your Open WebUI server and lets you have conversations with any AI model you've configured —  It's like having ChatGPT on your phone, but pointed at *your* server and *your* models.

---

## Features

### 💬 Streaming Chat with Full Markdown
- Real-time word-by-word streaming responses via SSE
- **Rich Markdown rendering** — syntax-highlighted code blocks with language detection and copy button, tables, math equations, block quotes, headings, inline code, links, and more
- Everything renders smoothly as it streams in — no layout jumps
- Full conversation history with search
- Copy, regenerate, or continue from any message
- Follow-up suggestions after each response
- Auto-generated chat titles (with option to disable)

### 🧠 Reasoning / Thinking Display
- Collapsible **"Thought for X seconds"** blocks for chain-of-thought models (DeepSeek, QwQ, etc.)
- Expand to see the full reasoning process — just like the web UI
- Duration tracking for thinking time

### 📚 Knowledge Bases (RAG)
- Type **`#`** in the chat input to open a searchable knowledge picker
- Browse and attach **collections**, **folders**, and **files** from your server
- Selected knowledge sources are sent with your message for RAG retrieval
- Works exactly like the web UI's `#` picker

### 🔍 Web Search
- Toggle web search on/off per message via quick pills or tools menu
- AI searches the web and cites sources in its response
- **Source citations** with numbered references, favicons, and tappable links
- Full sources detail sheet showing all references

### 🖼️ Image Generation
- Toggle image generation for models/tools that support it (DALL-E, Stable Diffusion, ComfyUI, etc.)
- Generated images render inline in the conversation
- Automatic file reference extraction from tool results

### 💻 Code Interpreter
- Toggle code execution for supported models
- Inline tool call rendering with expandable arguments and results

### 🛠️ Tools Support
- All server-side tools appear in a toggleable tools menu
- Enable/disable tools per conversation
- **Inline tool call views** — collapsible sections showing tool name, arguments (pretty-printed JSON), and results
- Visual status indicators (spinner while running, checkmark when done)

### 📞 Voice Calls with AI
- Full voice conversation with AI — feels like a real phone call
- Uses **CallKit** for native iOS call integration
- Animated **orb visualization** that reacts to voice intensity and call state
- On-device speech recognition with real-time transcript display
- Mute, pause, skip, and end call controls
- State-aware UI (connecting, listening, processing, speaking)

### 🎙️ Text-to-Speech (Multiple Engines)
- **Marvis Neural Voice** — On-device AI TTS powered by MLX (~250MB model, runs fully locally)
- **Server TTS** — Use your Open WebUI server's text-to-speech endpoint
- **System TTS** — Apple's built-in AVSpeechSynthesizer with voice and speed selection
- **Auto mode** — Automatically picks the best available engine
- Configurable voice, speed, and quality settings
- Preview button to test your TTS configuration

### 🎤 Speech-to-Text
- **On-device** — Apple Speech framework (fast, private, works offline)
- **Server STT** — Open WebUI server-side transcription
- **Qwen3 ASR** — On-device ML model for offline transcription (~400MB)
- Configurable silence detection duration
- Audio attachments are auto-transcribed

### 📎 Rich Attachments
- Attach **files**, **photos** (library or camera), and **documents**
- **Paste images** directly into the chat input
- Upload progress indicators with processing status (uploading → processing → ready)
- **Share Extension** — share content from any app directly into Open UI

### 📁 Folders & Organization
- Organize conversations into **folders** with drag-and-drop
- **Pin** important conversations to the top
- Bulk select and delete conversations
- Collapsible sections grouped by time (Today, Yesterday, This Week, etc.)
- Search across all conversations
- Create, rename, and delete folders

### 🎨 Deep Theming & Customization
- **Light / Dark / System** color scheme modes
- **Accent color picker** with preset colors and a full custom color wheel
- **Pure black OLED mode** for true black backgrounds
- **Tinted surfaces** — subtle accent color tint on backgrounds
- **Live preview card** showing your theme in real-time as you customize
- Chat bubble, input field, and all UI elements adapt to your chosen color

### ⚡ Quick Action Pills
- Configurable quick-toggle pills below the chat input
- One-tap toggle for **web search**, **image generation**, or any server tool
- Customize which pills appear in Chat Settings

### 🔔 Notifications
- Background notifications when a generation completes
- Tap to jump directly to the conversation
- Configurable notification preferences

### 📝 Notes
- Create and manage notes alongside your chats
- Built-in **audio recording** support for voice notes
- Accessible from the sidebar drawer

### 🔐 Authentication
- **Username/password**, **LDAP**, and **SSO** (Single Sign-On) support
- Secure token storage in the **iOS Keychain**
- **Multi-server support** — connect to different Open WebUI instances and switch between them
- Session restoration with automatic retry on network issues
- Sign-up and pending approval flows

### ⚙️ Additional Settings
- **Default model picker** synced with your server
- **Send on Enter** toggle (Enter sends vs. newline)
- **Streaming haptics** — feel each token as it arrives
- **Temporary chats** — conversations not saved to the server for privacy
- **TTS engine selection** with per-engine configuration
- **STT engine selection** with silence duration control

---

## Requirements

- **iOS 18.0** or later
- **Xcode 16.0** or later (Swift 6.0+)
- A running **[Open WebUI](https://openwebui.com)** server instance accessible from your device

---

## Build & Run Locally

### 1. Clone the Repository

```bash
git clone https://github.com/ichigo3766/Open-UI.git
cd Open-UI
```

### 2. Open in Xcode

```bash
open "Open UI.xcodeproj"
```

Xcode will automatically fetch all Swift Package dependencies on first open. This may take a minute.

### 3. Configure Signing

- In Xcode, select the **Open UI** target in the project navigator
- Go to **Signing & Capabilities**
- Select your **Development Team**
- Update the **Bundle Identifier** if needed (e.g., `com.yourname.openui`)

### 4. Build & Run

- Select an **iOS 18+ simulator** or a connected device
- Press **⌘R** (or click the ▶️ Play button)
- On first launch, enter your Open WebUI server URL and sign in

---

## Tech Stack

- **SwiftUI** — 100% SwiftUI interface
- **Swift 6** with strict concurrency
- **MVVM** architecture
- **SSE (Server-Sent Events)** for real-time streaming
- **CallKit** for native voice call integration
- **MLX Swift** for on-device ML inference (Marvis TTS + Qwen3 ASR)
- **Core Data** for local persistence

---

## Acknowledgments

Special thanks to Conduit by cogwheel — Cross-Platform Open WebUI mobile client and a real inspiration for this project.

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
