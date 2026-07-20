import {describe, expect, it} from "vitest"
import {applyPatches, protocolVersion, validateEnvelope, validatePatches} from "../src/protocol"

describe("UTF-16 patch protocol", () => {
  it("applies sorted multi-range changes against one base", () => {
    const source = "one 😀 three"
    const changes = [
      {from: 0, to: 3, insert: "ONE"},
      {from: 4, to: 6, insert: "🙂"},
      {from: 7, to: 12, insert: "THREE"}
    ]
    expect(source.length).toBe(12)
    expect(validatePatches(source.length, changes)).toBe(true)
    expect(applyPatches(source, changes)).toBe("ONE 🙂 THREE")
  })

  it("rejects overlap, reversed ranges, and surrogate-overrun lengths", () => {
    expect(validatePatches(5, [{from: 1, to: 4, insert: ""}, {from: 3, to: 5, insert: ""}])).toBe(false)
    expect(validatePatches(5, [{from: 4, to: 2, insert: ""}])).toBe(false)
    expect(validatePatches("😀".length, [{from: 0, to: 3, insert: ""}])).toBe(false)
  })

  it("accepts only complete version-one envelopes", () => {
    expect(validateEnvelope({protocolVersion, sessionID: "s", requestID: "r", sequence: 0, method: "ready", payload: {}})).toBe(true)
    expect(validateEnvelope({protocolVersion: 2, sessionID: "s", requestID: "r", sequence: 0, method: "ready", payload: {}})).toBe(false)
    expect(validateEnvelope({protocolVersion, sessionID: "", requestID: "r", sequence: 0, method: "ready", payload: {}})).toBe(false)
  })
})
