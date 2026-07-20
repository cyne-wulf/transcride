import {afterEach, vi} from "vitest"

class ResizeObserverStub {
  observe(): void {}
  unobserve(): void {}
  disconnect(): void {}
}

Object.defineProperty(globalThis, "ResizeObserver", {value: ResizeObserverStub, configurable: true})
Object.defineProperty(globalThis, "requestAnimationFrame", {
  value: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0),
  configurable: true
})
Object.defineProperty(globalThis, "cancelAnimationFrame", {value: (id: number) => clearTimeout(id), configurable: true})

if (!Range.prototype.getClientRects) {
  Object.defineProperty(Range.prototype, "getClientRects", {value: () => []})
}
if (!Range.prototype.getBoundingClientRect) {
  Object.defineProperty(Range.prototype, "getBoundingClientRect", {
    value: () => ({x: 0, y: 0, left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0, toJSON() { return {} }})
  })
}

afterEach(() => {
  document.body.replaceChildren()
  vi.restoreAllMocks()
})
