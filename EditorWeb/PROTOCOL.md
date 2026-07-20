# Transcride editor bridge protocol v1

The native host and editor exchange JSON-serializable dictionaries. Every message
has exactly this envelope shape:

```text
{
  protocolVersion: 1,
  sessionID: String,
  requestID: String,
  sequence: nonnegative integer,
  method: String,
  payload: dictionary
}
```

The page creates a fresh `sessionID` for each web-content lifetime and announces it
with `ready`. Each direction has its own sequence, beginning at zero. A receiver
rejects a wrong version, stale session, skipped/replayed sequence, unknown method,
or malformed payload. The sole exception is terminal `action.transportFailure`
from the active accepted session:
it bypasses ordinary sequencing because the two sides can no longer know whether
the previous sequence was accepted. Native freezes the page and begins a new
token-bound load/session. Request IDs are unique and are suitable for diagnostics;
ordering is otherwise defined only by `sequence`.

JavaScript sends requests through the reply-capable WebKit handler
`window.webkit.messageHandlers.editorBridge.postMessage(envelope)`. Native code
calls the promise-returning
`window.transcrideEditor.handleNativeMessage(message)` with an argument dictionary
through `callAsyncJavaScript`; Markdown is never interpolated into JavaScript.

## JavaScript to native

| Method | Payload |
| --- | --- |
| `ready` | `{protocolVersion, loadToken, utf16Coordinates, modes, capabilities}` |
| `patches` | `{baseLength, intent: "text"|"task"|"history", changes: [{from, to, insert}]}` |
| `snapshot` | `{text, mode, viewState, reason}` |
| `viewState` | `{selection: [{anchor, head}], mainSelectionIndex, scrollTop}` |
| `focusOwnership` | `{owner: "application"|"editor"|"search", acceptsTextInput, historyOwnership, composing, mode}` |
| `linkAction` | Wikilink `{kind, target, alias, from, to}` or Markdown link `{kind, label, destination, from, to}`. Native resolves and allowlists it. |
| `clickAction` | `{kind: "originalPosition"|"enterEditing", position}` |
| `preferenceAction` | `{kind: "fontSize", value}` |
| `performance` | `{kind, sampleCount, p95Milliseconds, maximumMilliseconds, documentLength, targetMet}` |
| `action` | `{kind: "userScroll"}` for manual scrolling, or terminal `{kind: "transportFailure", message}` |

Patch offsets and lengths are JavaScript-string/CodeMirror offsets: UTF-16 code
units. Every range is half-open, sorted, non-overlapping, and refers to the same
pre-transaction document of `baseLength` code units. An empty patch batch is valid.
The receiver applies a batch from the highest range to the lowest. Rejection causes
the page to send a full `snapshot` instead of guessing.

## Native to JavaScript

| Method | Payload | Reply result |
| --- | --- | --- |
| `configure` | `{mode?, preferences, appearance}` where preferences contains `fontSize` (12...28), `width` (`narrow`,`wide`,`full`), `editedAlignment` (`center`,`left`), and `focusMode`; appearance contains `colorScheme` (`light`,`dark`), `increasedContrast`, and `reduceMotion` | Current mode |
| `replaceDocument` | `{text, mode, selection?, mainSelectionIndex?, scrollTop?, resetHistory?}` | UTF-16 document length |
| `applyExternalChanges` | `{mode, changes: [{from,to,insert}]}` | Exact text and UTF-16 length |
| `requestSnapshot` | `{reason}` | The snapshot payload, after the native reply handler acknowledges the matching `snapshot` request |
| `captureViewState` | `{}` | View state; the same state is also sent as a `viewState` request |
| `restoreViewState` | View-state payload | Clamped/restored view state |
| `setStableDecorations` | `{decorations: [{from,to,kind,data?}]}` for search, speaker, and knowledge marks | Accepted count |
| `setPlaybackDecoration` | `{decoration: {from,to,kind:"playback",data?} | null}` | Whether playback is active |
| `setFrozen` | `{frozen, reason?}` | Frozen state |
| `executeCommand` | `{command}` | Whether the command ran |

Commands are `undo`, `redo`, `openFind`, `closeFind`, `findNext`, `findPrevious`,
`replaceNext`, `replaceAll`, `bold`, `italic`, and `link`. Replace and formatting
commands return false outside `editedEditing`. Document/configuration transactions
carry a private native annotation, do not echo patches, and do not enter history.
`applyExternalChanges` maps targeted disk hunks through local history without
adding them to local Undo. `resetHistory` constructs a fresh CodeMirror state only
for clean replacement, conflict resolution, or process recovery.

## Modes and lifecycle

`original` and `editedView` are DOM read-only; `editedEditing` accepts text unless
frozen. Task widgets intentionally dispatch one document transaction in Edited
view or editing. CodeMirror owns its current selection, scroll, composition, and
history. Native code owns the acknowledged mirror, layer-specific saved view state,
fork/autosave state, exact body revision, file I/O, and recovery policy.

Stable semantic/search decorations and transient playback are independent state
channels. A 30 Hz playback tick replaces only the playback mark and never rebuilds
or resends the note-wide knowledge set.
