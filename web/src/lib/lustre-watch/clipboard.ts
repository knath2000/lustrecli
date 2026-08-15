export type ClipboardWriter = Pick<Clipboard, "writeText">;

export function copyText(value: string, clipboard: ClipboardWriter = navigator.clipboard) {
  return clipboard.writeText(value);
}
