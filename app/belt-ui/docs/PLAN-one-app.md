# Plan: one Mac app (Conveyor + LocalAI)

Written 2026-10-26, revised the same day for an App-Store-first design. This is a
plan only: nothing in it has been built yet. Facts were checked against the
linked sources on 2026-10-26.

## What the product is
One Mac app that takes a task in plain words and **only marks it done when it's
proven**. Each task gets a checklist, and every step has a check that has to pass.
A second AI that never saw the work tries to prove it wrong. Every action
leaves a receipt. The work can be done by a model running on the Mac (no account,
nothing leaves the machine), by Apple's Private Cloud Compute model, or by a cloud
AI the user chooses.

Today this is two apps:
- **Conveyor:** a SwiftUI front end over a bash "belt" in `~/conveyor`.
- **LocalAI** (`~/Developer/local-ai-app`, about 5,000 lines of Swift): Qwen2.5-Coder-7B
  through MLX, a confined workspace, receipts and a claim checker. It already pins
  mlx-swift-lm 3.32.3, the release that added the Foundation Models bridge.

## What changed at WWDC26 (macOS 27)
- **One API for every model.** A new `LanguageModel` protocol lets local and server models back a
  `LanguageModelSession`. Apple ships `SystemLanguageModel` (on device) and
  `PrivateCloudComputeLanguageModel`, and open-sources `MLXLanguageModel` and `CoreAILanguageModel`.
  Anthropic and Google publish Swift packages. Apple's advice is to keep tokens out of the binary
  (use OAuth or the Keychain). Sessions report token `usage`
  ([WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)).
- **Private Cloud Compute (PCC) costs the developer nothing in cloud API fees** if they're in the
  App Store Small Business Program with under 2M first-time downloads and have the PCC
  entitlement. Each user gets a daily limit, which is higher with iCloud+. It has a 32K context
  and reasoning, and works only on Apple-Intelligence devices and regions, App Store / TestFlight builds
  ([macOS 27 what's new](https://developer.apple.com/macos/whats-new/),
  [PCC access](https://developer.apple.com/private-cloud-compute/)). There's also a new Evaluations framework.
- **Shipped packages:**
  - `MLXFoundationModels` is in mlx-swift-lm 3.32.3 (MIT) ([PR #334](https://github.com/ml-explore/mlx-swift-lm/pull/334)).
  - Anthropic's `ClaudeForFoundationModels` 0.2.3 (Apache 2.0, labelled beta) ([repo](https://github.com/anthropics/ClaudeForFoundationModels)).
  - Gemini comes through Firebase AI Logic, in preview ([Firebase docs](https://firebase.google.com/docs/ai-logic/apple-foundation-models-framework/get-started)).
  - Apple's `foundation-models-utilities` (Apache 2.0) adds `ChatCompletionsLanguageModel`, which works with any
    OpenAI-compatible server ([repo](https://github.com/apple/foundation-models-utilities)).
  - All of them need macOS 27.
- **Guideline 5.1.2(i) (Nov 2025):** an app must "clearly disclose where personal data will be shared
  with third parties, including with third-party AI, and obtain explicit permission"
  ([Apple news](https://developer.apple.com/news/?id=ey6d8onl)).
- **Unchanged:** the Mac App Store still requires the App Sandbox ([2.4.5(i)](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)).
  It also bans reading or writing outside the container and downloading or running code that changes
  features ([2.5.2](https://developer.apple.com/app-store/review/guidelines/#software-requirements)).

## Recommended architecture: App Store first
**One sandboxed Swift app. The belt loop is rewritten in Swift. Every seat is a `LanguageModelSession`. No external CLIs.**

- **The belt in Swift:** trays, legs, the checklist checker, the verifier, planner/critic and step tries.
  The bash belt and its 112 stand-in-AI checks become the specification, ported to XCTest against a fake
  `LanguageModel` (mlx-swift-lm ships `MLXScriptedLM` for stubbing).
- **Seats (the user picks one per role):**
  - **On this Mac:** Qwen2.5-Coder-7B (Apache 2.0) through `MLXLanguageModel`, reusing LocalAI's MLX code.
    No account, offline.
  - **Apple PCC:** free to us and to the user up to their daily limit. A good default for the
    **planner and critic** (big context, reasoning), while the local model builds.
  - **Claude:**
    - The package's recommended production mode is App Attest, which bills **our** Anthropic workspace.
    - An `.apiKey` mode also exists; the README only warns against *bundling* a key.
    - Plan: let the user paste their own key, stored in the Keychain. Confirm that Anthropic allows this before launch.
  - **Gemini:** goes through Firebase and App Check, so it bills **our** Firebase project. No user-key path is documented.
  - **Any OpenAI-compatible provider, user's key:** through `ChatCompletionsLanguageModel`.
    This is the route for Grok/xAI, OpenAI, OpenRouter, or a local LM Studio/Ollama server.
- **Files:** each task gets its own folder inside the app container. A user can also grant a project
  folder with the open panel, which we remember with a security-scoped bookmark. Nothing else is reachable.
- **Consent screen (5.1.2(i)):**
  - Before the first send to any non-local seat, a sheet names the provider and lists what will be sent
    (the task text, the files in the task folder, and check output).
  - It needs an explicit "Allow".
  - Permission is per provider, and revocable in Settings.
  - On-device seats skip the sheet. PCC still gets a one-line notice.
- **The model download** on first run goes into the container, with the size (about 4.3 GB) shown and consent asked first
  ([4.2.3(ii)](https://developer.apple.com/app-store/review/guidelines/#minimum-functionality)).
- **Memory on 8 GB** (the owner's own Mac is an 8 GB M2, so they can test this themselves):
  - Run one local leg at a time.
  - Unload the model while a check runs.
  - Refuse to load it when free memory is low.
  - The local model shouldn't check its own work. On 8 GB, PCC is the checker.

**Alternative: direct download (Developer ID + notarization), the "Pro" edition.** It uses the same
Swift core, with the sandbox off. It adds the CLI seats (claude/codex/gemini/grok with the user's own logins),
any shell check, Homebrew tools, and any folder. It's sold from a website with Paddle or Lemon Squeezy.
PCC isn't available here (it's App Store / TestFlight only).

## What step checks can run inside the sandbox (tested)
I tested this on the owner's Mac (macOS 27.0.1) with a throwaway ad-hoc-signed sandboxed probe app.
No AI was involved, and it wasn't App Review. A command the app starts **inherits the sandbox**
([Apple](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app),
[forums 123873](https://developer.apple.com/forums/thread/123873)).

- **Works, on files in the container:**
  - `/bin/sh` and `zsh`
  - `grep`, `awk`, `sed`, `diff`, `wc`, `sort`, `shasum`, `plutil`
  - `perl`, `ruby`, `osascript`
  - `curl` (with the network entitlement)
- **Blocked:**
  - `swift`, `python3` and `git` all fail with "xcrun: error: cannot be used within an App Sandbox".
  - Homebrew (`/opt/homebrew`) and `~/.local/bin/claude` fail with "Operation not permitted".
  - So do `~/Documents`, `~/.claude` and every other folder that wasn't granted.
- **A script the AI writes can't be run directly.** New files get `com.apple.quarantine`, and running
  `./s.sh` failed with "Operation not permitted". Only `sh s.sh` (feeding the text to the shell) worked.
- **Not tested yet:**
  - whether commands the app starts can also see folders the user granted
  - a bundled helper tool (allowed if signed with `app-sandbox` + `inherit`, per the Apple link above)

**Honest limit:** App Store checks are **Swift-native checks plus built-in macOS tools, on files in the task
folder**. Examples: the file exists, it contains or matches some text, the JSON or CSV parses with
the right columns, row counts, image size, hashes and diffs. **No `git`, `python`, `npm`, `swift`, compilers or
test runners.** So the App Store edition is right for document, data and file tasks, not for coding tasks.
Code tasks belong in the Pro edition.

Running AI-written shell lines, even through `/bin/sh`, may be read by App Review as running code that
changes features (2.5.2). That's a review risk. **So the App Store build should use a fixed menu of check
types, written in Swift, and no free-form shell.**

## Effort, at the owner's pace
The owner directs AI coding agents. They built their MCP server in about 3 hours. A **session** below means
about 3 focused hours of that.

| # | Milestone | Sessions |
|---|---|---|
| 1 | Clean-up: remove Alexus/personal references (audit list), LocalAI's "You are ALEXUS" prompt (`AppSettings.swift:40,69`), new bundle ID, one repo | 1 |
| 2 | Swift belt core, plus the 112 checks ported to XCTest with a fake model | 3–4 |
| 3 | Seats: MLX local, Apple on-device + PCC, ChatCompletions (user key), Claude; Keychain; consent screen | 3 |
| 4 | Sandbox: container folders, granted-folder bookmarks, Swift check menu, entitlements | 1–2 |
| 5 | One-app UI (Conveyor board + LocalAI chat/model manager), first-run download, memory guard | 2 |
| 6 | Ship: App Store Connect listing, in-app purchase, privacy policy, screenshots; Pro DMG + notarization + Sparkle | 1–2 |

That's **about 11–14 sessions, roughly 4–6 full working days** of hands-on work. Agents write code fast. They
don't make the first real-model run or the first sandbox surprise any faster, so expect a couple of sessions of
debugging on top.

**Wall-clock time that speed doesn't shorten:**
- **Apple Developer Program enrollment ($99/yr):** usually quick for an individual. A company needs a D-U-N-S
  number first, which can take much longer. These times weren't verified.
- **Small Business Program enrollment and the PCC entitlement request:** separate approvals, with unknown turnaround.
  PCC can't be tested until it's granted.
- **App Review:** "at least 50% of submissions in less than 24 hours and 90% in less than 48 hours", per round
  ([Apple](https://developer.apple.com/distribute/app-review/)). A first submission of an AI agent app should expect
  at least one rejection round.
- **Notarization** (Pro edition): usually minutes, sometimes hours.
- **Real-model testing on 8 GB:** a 7B model on an M2 with 8 GB is slow, and tuning prompts so the local model
  passes its checks takes real runs over a day or two. This needs the owner's go-ahead, since so far we've used stand-in AIs only.

Realistic: **a sellable App Store build in about 2 weeks of calendar time**, if enrollment and the PCC entitlement come
through quickly. The Pro DMG could ship a few days sooner.

## Model and licences
- **Qwen2.5-Coder-7B-Instruct is Apache 2.0**, so commercial use is OK. Ship its license and notices
  ([LICENSE](https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct/raw/main/LICENSE)).
  The MLX 4-bit version is about 4.3 GB and tagged Apache 2.0 ([HF](https://huggingface.co/api/models/mlx-community/Qwen2.5-Coder-7B-Instruct-4bit)).
  **The 3B is not Apache** (Qwen research license), so don't ship it. The 1.5B and 14B are Apache 2.0.
- mlx-swift and mlx-swift-lm are MIT. ClaudeForFoundationModels and foundation-models-utilities are Apache 2.0.
- The belt's PolyForm Noncommercial license must be replaced with the product's own terms.

## Minimum hardware
- Apple silicon running **macOS 27** (every new model API needs it).
- PCC also needs an Apple-Intelligence-eligible Mac and region.
- 8 GB works for one task at a time; 16 GB is recommended.
- About 6 GB of free disk.
- Building it needs Xcode 27.

## Open checks (not yet verified)
- **OS and API status:** the owner runs macOS 27.0.1, but Apple's PCC `QuotaUsage` doc page still shows "Beta" badges.
  Confirm the APIs are final in the shipping SDK.
  - The on-device context size is unclear: 4K in the PCC docs table, 8192 in the session 241 code sample.
  - mlx-swift-lm fixed several FM-27 API changes in September, so expect churn.
- **Anthropic:**
  - ClaudeForFoundationModels is still labelled beta.
  - It isn't confirmed that its terms allow a user-supplied key in a shipped app.
  - App Attest support on Macs (it needs a Secure Enclave) isn't confirmed.
- **Gemini:** Firebase preview terms; whether a user-key mode exists; cost to us.
- **Grok/xAI:** there's no first-party Swift package. The route would be `ChatCompletionsLanguageModel` with the user's key;
  check that xAI's endpoint and tool calling work with it.
- **Sandbox:**
  - whether child processes can see bookmark-granted folders
  - whether App Review accepts the fixed check menu
- **PCC terms:** the daily limit size, and what happens past 2M downloads (we would have 6 months to migrate).

## What the owner must decide
- Name, seller and bundle ID. Enrolling as an individual or a company sets how long Apple enrollment takes.
- App Store first (recommended), with the Pro DMG alongside or later.
- Price: one-time or subscription (in-app purchase on the App Store, [3.1.1](https://developer.apple.com/app-store/review/guidelines/#in-app-purchase)).
  If Claude or Gemini bill to us, a subscription is needed to cover the tokens.
- Which seats are in v1: local + PCC only is the cheapest and simplest. User-key cloud seats can come next.
- Whether to keep the bash belt as an open-source engine, or retire it after milestone 2.
