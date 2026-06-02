# Smartii for Mac

> AI in your menu bar. Press a global hotkey anywhere → screenshot your screen → get the answer from your chosen AI provider, shown in a floating panel and copied to your clipboard.

**Smartii for Mac** is a native macOS menu-bar assistant written in AppKit — the desktop sibling of the [Smartii browser extension](https://github.com/platret/Smartii). It lives in the menu bar (no Dock icon), reaches across every app on your screen, and talks directly to the AI provider of your choice with your own API key. No backend, no telemetry, no account.

<p align="center">
  <a href="https://github.com/platret/Smartii-Mac/releases/latest"><b>⬇ Download the latest release</b></a>
  ·
  <a href="https://platret.github.io/Smartii-Mac/">Website</a>
  ·
  <a href="https://github.com/platret/Smartii">Browser extension</a>
</p>

---

## What it is

Hit a key in any app. Smartii captures your main display with **ScreenCaptureKit**, sends the image (or just your typed question) to a vision-capable model, and shows the answer in a floating panel — already copied to your clipboard so you can paste it anywhere. Then it gets out of the way.

- **Menu bar, not a window.** Runs as an accessory app (`LSUIElement`) — a `✦` in your menu bar is the whole UI. No Dock icon, no app-switcher clutter.
- **Sees your whole screen.** Not just a browser tab — any app, any window, the entire desktop.
- **Your key, your data.** API keys are stored in the macOS **Keychain** and sent straight to the provider you picked. Nothing routes through a Smartii server.
- **7 providers in one.** Gemini, Groq, OpenRouter, Hugging Face, Anthropic, OpenAI, Perplexity. Vision routing automatically picks an image-capable model when a screenshot is attached.
- **Global hotkeys.** Carbon-registered shortcuts work system-wide, from inside any frontmost app.
- **⚡ Godmode.** One press reads everything on screen and answers it all — quizzes, code, errors, multiple-choice — numbered, with the reasoning and the fix.

## How it differs from the browser extension

|                       | **Smartii for Mac**                          | **Smartii (browser extension)**            |
| --------------------- | -------------------------------------------- | ------------------------------------------ |
| Platform              | Native macOS app (AppKit)                    | Chrome / Edge / Brave / Arc / any Chromium |
| Where it lives        | Menu bar — system-wide                       | A bar at the bottom of the active page     |
| What it can see       | Your **entire screen**, every app            | Only the visible web page                  |
| Screenshot engine     | ScreenCaptureKit (needs Screen Recording)    | `chrome.tabs.captureVisibleTab`            |
| Key storage           | macOS Keychain                               | Browser encrypted sync storage             |
| Summon hotkey         | `⌘⇧S`                                         | `Ctrl⇧S`                                    |
| Distribution          | Unsigned `.app` from GitHub Releases         | Load-unpacked / packaged extension         |

Same idea, same providers, same Godmode prompt — just unshackled from the browser.

## Hotkeys

All shortcuts are **global**: they fire from inside whatever app is frontmost.

| Shortcut | Action          | What it does                                                                 |
| -------- | --------------- | ---------------------------------------------------------------------------- |
| `⌘⇧S`    | **Summon / Ask** | Toggle the floating panel. Type a question and **Send**, or **Solve** to attach a screenshot. |
| `⌥⇧S`    | **Solve screen** | Instantly screenshot the main display and ask the model what's on it.        |
| `⌥⇧G`    | **Godmode**      | Read the entire screen and answer every question, problem and error — automatically, no typing. |
| `⌥⇧X`    | **Panic**        | Hide the panel instantly. One keystroke and the screen is yours again.       |

## Install (prebuilt)

1. **Download `Smartii.dmg`** from [GitHub Releases](https://github.com/platret/Smartii-Mac/releases/latest) and open it.
2. **Drag `Smartii` into the `Applications` folder** in the window that appears.
3. **Right-click `Smartii.app` in `/Applications` → Open** the first time. The app is unsigned, so macOS asks you to confirm — click **Open**. (See [Permissions](#permissions) if Gatekeeper blocks it outright.)
4. **Grant Screen Recording** permission when prompted, then pick a provider and paste your API key from the menu-bar Settings.

After that first launch, **Smartii keeps itself up to date** — it checks GitHub Releases and downloads new versions automatically, so you only have to do this once.

> **Prefer a zip?** A `Smartii-mac.zip` is attached to every release as an alternative. Unzip it, move `Smartii.app` into `/Applications`, then right-click → Open the first time (same as step 3). This is the same archive the in-app updater uses.

## Build from source

Requires **Xcode 16 / Swift 6.x** toolchain and **macOS 14 (Sonoma) or later**. There are no third-party dependencies — only system frameworks (Cocoa/AppKit, Carbon.HIToolbox, ScreenCaptureKit, Security, CoreGraphics, UniformTypeIdentifiers).

```bash
# 1. Compile the Swift Package Manager executable
swift build -c release

# 2. Wrap the binary into a proper Smartii.app bundle
#    (sets LSUIElement, the Info.plist, icon, and usage descriptions)
bash Scripts/make-app.sh

# 3. Launch it
open build/Smartii.app
```

`Scripts/make-app.sh` packages the compiled `Smartii` binary into `build/Smartii.app` with an `Info.plist` that marks the app as a menu-bar accessory (`LSUIElement = true`) and declares the Screen Recording usage description. The first launch will ask for Screen Recording permission.

> Running `swift run` directly works for a quick test, but you'll want the `.app` bundle for a real menu-bar experience and for the system permission prompts to attribute correctly.

## Permissions

Smartii needs two things from macOS:

- **Screen Recording.** Required for the screenshot/Solve/Godmode features (ScreenCaptureKit captures your display). On first capture, macOS prompts you; if you miss it, enable it manually under **System Settings → Privacy & Security → Screen Recording**, then relaunch Smartii.
- **Gatekeeper (unsigned app).** The release builds are **not notarized**. The simplest path is **right-click the app → Open** on first launch. If macOS still refuses ("Smartii is damaged" / "can't be opened"), clear the quarantine attribute:

  ```bash
  xattr -dr com.apple.quarantine /Applications/Smartii.app
  ```

## Providers & API keys

Smartii is **bring-your-own-key**. Open the menu-bar **Settings** window, choose a provider, paste your key (it goes into the Keychain), and optionally pick a model. Switch providers any time from the menu.

| Provider         | Tier  | Default model                         | Vision | Get a key                                                          |
| ---------------- | ----- | ------------------------------------- | :----: | ----------------------------------------------------------------- |
| **Gemini**       | free  | `gemini-2.0-flash`                    |   ✅    | <https://aistudio.google.com/app/apikey>                          |
| **Groq**         | free  | `llama-3.3-70b-versatile`             |   ✅\*  | <https://console.groq.com/keys>                                   |
| **OpenRouter**   | mixed | `meta-llama/llama-3.3-70b-instruct:free` | ✅\* | <https://openrouter.ai/keys>                                      |
| **Hugging Face** | free  | `meta-llama/Llama-3.3-70B-Instruct`   |   ❌    | <https://huggingface.co/settings/tokens>                          |
| **Anthropic**    | paid  | `claude-sonnet-4-6`                   |   ✅    | <https://console.anthropic.com/settings/keys>                     |
| **OpenAI**       | paid  | `gpt-4o`                              |   ✅    | <https://platform.openai.com/api-keys>                            |
| **Perplexity**   | paid  | `sonar`                               |   ❌    | <https://www.perplexity.ai/settings/api>                          |

\* When a screenshot is attached, Smartii automatically routes to a vision-capable model (e.g. Groq's `llama-4-scout`, OpenRouter's `gemini-2.0-flash-exp:free`). **Perplexity** and **Hugging Face** can't read images — switch to Gemini or Groq for Solve/Godmode.

Keys never leave your machine except in the request to the provider you selected. Smartii has no server of its own.

## How Godmode works

When you press `⌥⇧G`, Smartii screenshots your screen and sends it with a single instruction:

> GODMODE: read the entire attached screenshot of the user's screen. Identify the most important question, problem, code, error, or task on screen and answer it directly and completely. If there are multiple questions, answer all of them, numbered. If it's a multiple-choice question, give the correct letter AND the reasoning. If it's code or an error, show the fix. Be precise. No filler.

The answer lands in the floating panel and on your clipboard.

## Privacy

- No analytics, no tracking, no accounts.
- API keys live in the macOS Keychain (service `app.smartii.mac`).
- Screenshots are sent **only** to the provider you chose, **only** when you trigger a capture, and are not stored or logged by Smartii.

## License

[MIT](LICENSE) © platret. Use it, fork it, ship it.
