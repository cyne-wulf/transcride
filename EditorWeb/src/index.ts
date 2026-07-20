import {TranscrideEditor} from "./editor"
import type {BridgeReply} from "./protocol"

declare global {
  interface Window {
    transcrideEditor: {
      handleNativeMessage(message: unknown): Promise<BridgeReply>
    }
  }
}

const parent = document.getElementById("editor")
if (!parent) throw new Error("Missing editor mount point")
const editor = new TranscrideEditor(parent)

window.transcrideEditor = {
  handleNativeMessage(message: unknown): Promise<BridgeReply> {
    return editor.bridge.receive(message)
  }
}

void editor.ready()
