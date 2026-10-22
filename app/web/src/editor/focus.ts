import type { EditorView } from "@codemirror/view";
import { call } from "../host";

/**
 * Focus the editor from code, not from a tap in the page (a native command,
 * a problem in the list, a new cell). WebKit only brings up the keyboard for
 * that when its content view is already first responder, so the host makes
 * it one first (`keyboard.take`, D56).
 */
export function takeFocus(view: EditorView) {
  focusLog("take", view);
  if (view.hasFocus) return view.focus();
  void call("keyboard.take").catch(() => {}).then(() => {
    focusLog("taken", view);
    view.focus();
    focusLog("focused", view);
  });
}

/** What happened to focus lately (the self-test's editor_keyboard_from_native shows it when it fails). */
export const focusTimeline: string[] = [];
export function focusLog(what: string, view?: EditorView) {
  focusTimeline.push(`${Math.round(performance.now())} ${what} doc=${document.hasFocus()} cm=${view?.hasFocus ?? "-"} active=${document.activeElement?.className ?? "-"}`);
  if (focusTimeline.length > 30) focusTimeline.shift();
}
