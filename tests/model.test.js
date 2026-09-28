const test = require("node:test")
const assert = require("node:assert")
const fs = require("node:fs")
const path = require("node:path")

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*/, "")
const names = [...source.matchAll(/^(?:function|var) (\w+)/gm)].map(m => m[1])
const Model = new Function(source + "\nreturn {" + names.join(",") + "}")()

const now = new Date(2026, 4, 28, 15, 30)

function channel(name, version, schedule) {
  return { name, version, milestone: Model.milestoneOf(version), schedule }
}

test("relative and countdown text", () => {
  assert.strictEqual(Model.relativeText("2026-05-28T00:00:00", now), "today")
  assert.strictEqual(Model.relativeText("2026-05-29T00:00:00", now), "tomorrow")
  assert.strictEqual(Model.relativeText("2026-06-01T00:00:00", now), "in 4d")
  assert.strictEqual(Model.relativeText("2026-05-20T00:00:00", now), "8d ago")
  assert.strictEqual(Model.relativeText(null, now), "TBD")
  assert.strictEqual(Model.branchCountdownText("2026-06-01T00:00:00", now), "branches in 4d")
  assert.strictEqual(Model.barBranchText("2026-05-25T00:00:00", now), "br+3d")
  assert.strictEqual(Model.branchUrgency("2026-05-30T00:00:00", now), "urgent")
  assert.strictEqual(Model.branchUrgency("2026-06-03T00:00:00", now), "soon")
  assert.strictEqual(Model.dateText("2026-06-01T00:00:00"), "Jun 1, 2026")
})

test("canary bump only after dev branched on same milestone", () => {
  const dev = channel("dev", "156.0.8072.0", { branch_point: "2026-05-25T00:00:00" })
  const canary = channel("canary", "156.0.8077.0", {})
  assert.strictEqual(Model.canaryNeedsBump([dev, canary], now), true)
  dev.schedule.branch_point = "2026-06-01T00:00:00"
  assert.strictEqual(Model.canaryNeedsBump([dev, canary], now), false)
})

test("bar parts respect visibility and order", () => {
  const channels = [
    channel("dev", "156.0.1.0", { branch_point: "2026-06-01T00:00:00" }),
    channel("stable", "154.0.1.0", {}),
    channel("beta", "155.0.1.0", {})
  ]
  const parts = Model.barParts(channels, ["stable", "dev"], now)
  assert.deepStrictEqual(parts.map(p => p.text), ["S154", "D156 (br 4d)"])
})

test("insights mention overlaps and canary binary", () => {
  const channels = [
    channel("stable", "155.0.1.0", {}),
    channel("beta", "155.0.1.0", {}),
    channel("dev", "156.0.1.0", { branch_point: "2026-05-25T00:00:00" }),
    Object.assign(channel("canary", "156.0.2.0", {}), { milestone: 157 })
  ]
  const text = Model.insights(channels, [], now).join("\n")
  assert.match(text, /M155 is both Stable and Beta/)
  assert.match(text, /Dev already branched 3d ago/)
  assert.match(text, /Canary binary is still 156\.x/)
})

test("timeline filters window and groups by milestone", () => {
  const channels = [
    channel("dev", "156.0.1.0", {
      branch_point: "2026-06-01T00:00:00",
      earliest_beta: "2026-06-03T00:00:00",
      stable_date: "2026-12-01T00:00:00"
    }),
    channel("beta", "155.0.1.0", { stable_date: "2026-05-10T00:00:00", earliest_beta: "2026-05-26T00:00:00" })
  ]
  const events = Model.timelineEvents(channels, Model.CHANNELS, now)
  assert.deepStrictEqual(events.map(e => e.title), ["Beta starts", "Branch point", "Beta starts"])
  const groups = Model.groupedTimeline(events)
  assert.deepStrictEqual(groups.map(g => g.milestone), [155, 156])
  assert.strictEqual(Model.nextEvent(events).title, "Branch point")
})

test("bookmark parsing", () => {
  const cases = {
    "7941513": { kind: "cl", id: "7941513" },
    "https://chromium-review.googlesource.com/c/chromium/src/+/7941513/3": { kind: "cl", id: "7941513" },
    "https://crrev.com/c/1234": { kind: "cl", id: "1234" },
    "https://pdfium-review.googlesource.com/c/pdfium/+/555": { kind: "cl", id: "pdfium-review.googlesource.com:pdfium:555" },
    "https://chromium-review.googlesource.com/c/v8/v8/+/42": { kind: "cl", id: "chromium-review.googlesource.com:v8/v8:42" },
    "https://issues.chromium.org/issues/515480635": { kind: "issue", id: "515480635" },
    "crbug.com/123": { kind: "issue", id: "123" },
    "issue 99": { kind: "issue", id: "99" }
  }
  for (const [input, expected] of Object.entries(cases))
    assert.deepStrictEqual(Model.parseBookmark(input), expected, input)
  assert.strictEqual(Model.parseBookmark("hello"), null)
})

test("gerrit target urls", () => {
  const t = Model.gerritTarget("chromium-review.googlesource.com:v8/v8:42")
  assert.strictEqual(t.url, "https://chromium-review.googlesource.com/c/v8/v8/+/42")
  assert.match(t.detailUrl, /\/changes\/v8%2Fv8~42\/detail/)
  assert.strictEqual(Model.gerritTarget("7").project, "chromium/src")
})

test("cl status and xssi", () => {
  assert.strictEqual(Model.stripXssi(")]}'\n{\"a\":1}"), "{\"a\":1}")
  assert.strictEqual(Model.clDisplayStatus({ status: "NEW", mergeable: false }), "MERGE CONFLICT")
  assert.strictEqual(Model.clDisplayStatus({ status: "NEW", submittable: true }), "SUBMITTABLE")
  assert.strictEqual(Model.clDisplayStatus({ status: "MERGED" }), "MERGED")
})

test("state parsing and mutation", () => {
  const state = Model.parseState('{"visibleChannels":["dev","bogus"],"bookmarks":[{"kind":"cl","id":"1"},{"kind":"x"}]}')
  assert.deepStrictEqual(state.visibleChannels, ["dev"])
  assert.strictEqual(state.bookmarks.length, 1)
  assert.deepStrictEqual(Model.parseState("garbage").visibleChannels, Model.CHANNELS)
  assert.deepStrictEqual(Model.toggleChannel(["dev"], "stable"), ["stable", "dev"])
  assert.deepStrictEqual(Model.toggleChannel(["stable", "dev"], "dev"), ["stable"])
  const added = Model.addBookmark(state.bookmarks, { kind: "cl", id: "1" })
  assert.strictEqual(added.length, 1)
  assert.strictEqual(Model.removeBookmark(added, "cl:1").length, 0)
})
