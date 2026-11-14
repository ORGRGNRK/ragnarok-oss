# CLI Tools

A macOS app that runs the "CLI Tools" shortcut pipeline from `CLITools/Resources/cli-tools.json`.
The app interprets the JSON rather than hard-coding the steps, so editing the JSON (or opening another
file with **Open Pipeline…**) changes what the app does.

Requires macOS 26+ with Apple Intelligence on (for the on-device model) and Xcode 26+.

## Build

Open `CLITools.xcodeproj` in Xcode and press ⌘R. `project.yml` is the XcodeGen source; after changing it,
run `xcodegen generate`.

## How the actions map

| JSON action          | In the app |
|----------------------|------------|
| `receive_input`      | Text sent through **Services › Find CLI Tool** becomes Shortcut Input (and pre-fills the question). Opened directly, it continues with no input. |
| `ask_for_input`      | Inline text field. Cancel stops the run. |
| `use_model`          | `FoundationModels` `LanguageModelSession`, a fresh session per run. |
| `split_text`, `get_item_from_list` | Done in Swift. Blank lines are dropped when splitting. |
| `list`               | Builds a list from templates, like the Shortcuts List action. |
| `run_shell_script`   | `/bin/zsh -c <script> cli-tools <input…>` (a list passes one argument per item), 30-second timeout, stdout with trailing newlines trimmed. |
| `if`                 | begins with / ends with / contains / is / is not / has any value. |
| `choose_from_menu`   | Inline buttons. |
| `save_record`        | Writes to the app's history database (see below). `record` is `lookup` or `command_run`; a command run needs `parent`, the ID a saved lookup returns. |
| `create_note`, `append_to_note` | AppleScript to Notes. Still supported, but the bundled pipeline no longer uses them; export from History instead. |

## History is the source of truth

Every lookup is saved by `a6r` right after verification, including ones that come back NOT_FOUND or INVALID,
to `~/Library/Application Support/CLI Tools/history.store` (SwiftData). Each command you verify or run is
attached to its lookup by `a8s9` (ran) or `a8s12` (blocked), with the verdict, reason, exit code, duration and
output. Status, tool, path, verdict and exit code are parsed from the scripts' `KEY: value` lines.

Open **History** (⌘Y, or the clock button) to search lookups, see every command run against them, copy one as
text, export it to Notes, or delete it.

## Running a command (a8s2–a8s13)

After a successful lookup, choose **Run a Command**. The app suggests a command (the model's `backticked` example, if it starts with the
verified tool) and lets you edit it. Cancel ends the run. Otherwise:

1. **Verify Command** blocks anything that isn't one plain line starting with the verified tool: no
   `; & | < > $ ( ) { }` or backticks, no unreplaced `<placeholders>`, the tool must still resolve to the same
   path, destructive or privileged tools (`rm`, `mv`, `sudo`, `kill`, `diskutil`, …) are refused, and so are
   options that write files or run programs (`find -delete/-exec`, `sed -i`, `curl -o`, `defaults write`, …).
2. **Run Command** repeats the check, then runs the command as an argument list (never `eval`) with no stdin,
   a 15-second limit and a 1 MB output cap.
3. The command and its result, or the reason it was blocked, are saved to History. A non-zero exit or a
   blocked command also shows an alert. Commands run from your home folder.

The deny list is a guard rail, not a sandbox. You still confirm every command before it runs.
| `show_alert`, `stop_shortcut` | Alert, then the run ends. |

`{{a2.Provided Input}}` refers to an action's output. `{{Current Date}}` and bare names such as
`{{Shortcut Input}}` work as magic variables.

## Notes

- App Sandbox is off so the shell script can run `man`, `whatis`, `whence` and so on.
  Hardened Runtime is on, with the Apple Events entitlement for Notes.
- The Services menu entry shows up once the app has been run from `/Applications` (or after `/System/Library/CoreServices/pbs -update`).

## Screenshots

Debug builds can capture their own window without Screen Recording permission:

```bash
"build/DerivedData/Build/Products/Debug/CLI Tools.app/Contents/MacOS/CLI Tools" -snapshot "$PWD/screenshots" -demo-query "find which process is listening on a network port"
```

It saves the idle window, the first question, the run paused at the Run a Command / Done menu, and the History
window after running the suggested command, then quits. Snapshots use an in-memory history, so nothing real is
recorded. The glass sidebars can't be captured that way, so their rows are re-rendered into the images.
