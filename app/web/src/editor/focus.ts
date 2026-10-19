import type { EditorView } from "@codemirror/view";
import { call } from "../host";

/**
 * Focus the editor from code, not from a tap in the page (a native command,
 * a problem in the list, a new cell). WebKit only brings up the keyboard for
 * that when its content view is already first responder, so the host makes
 * it one first (`keyboard.take`, D56).
 */
export function takeFocus(view: EditorView) {
  if (view.hasFocus) return view.focus();
  void call("keyboard.take").catch(() => {}).then(() => view.focus());
}
