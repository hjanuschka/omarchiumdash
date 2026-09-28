.pragma library

var CHANNELS = ["stable", "beta", "dev", "canary"]

var CHANNEL_COLORS = {
  stable: "#3fb950",
  beta: "#4c8df6",
  dev: "#f0883e",
  canary: "#e3b341"
}

var STATUS_COLORS = {
  good: "#3fb950",
  bad: "#f85149",
  warn: "#f0883e",
  info: "#4c8df6"
}

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

var SCHEDULE_URL = "https://chromiumdash.appspot.com/schedule"

function versionUrl(platform, channel) {
  return "https://versionhistory.googleapis.com/v1/chrome/platforms/" + platform
    + "/channels/" + channel + "/versions/?pageSize=1"
}

function scheduleUrl(milestone) {
  return "https://chromiumdash.appspot.com/fetch_milestone_schedule?mstone=" + milestone
}

function displayName(name) {
  return name ? name.charAt(0).toUpperCase() + name.slice(1) : ""
}

function milestoneOf(version) {
  return parseInt(String(version || "").split(".")[0], 10) || 0
}

// ChromiumDash dates are "YYYY-MM-DDT00:00:00" calendar days; read them as
// local dates so day math does not shift across timezones.
function parseDate(value) {
  var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(value || ""))
  if (!m) return null
  return new Date(parseInt(m[1], 10), parseInt(m[2], 10) - 1, parseInt(m[3], 10))
}

function startOfDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate())
}

function daysBetween(from, to) {
  return Math.round((startOfDay(to) - startOfDay(from)) / 86400000)
}

function daysUntil(value, now) {
  var date = parseDate(value)
  return date ? daysBetween(now, date) : null
}

function formatDate(date) {
  return date ? MONTHS[date.getMonth()] + " " + date.getDate() + ", " + date.getFullYear() : "TBD"
}

function dateText(value) {
  return formatDate(parseDate(value))
}

function relativeDays(days) {
  if (days === null) return "TBD"
  if (days === 0) return "today"
  if (days === 1) return "tomorrow"
  if (days === -1) return "yesterday"
  return days > 0 ? "in " + days + "d" : (-days) + "d ago"
}

function relativeText(value, now) {
  return relativeDays(daysUntil(value, now))
}

function branchCountdownText(value, now) {
  var days = daysUntil(value, now)
  if (days === null) return "branch TBD"
  if (days === 0) return "branches today"
  if (days === 1) return "branches tomorrow"
  if (days > 1) return "branches in " + days + "d"
  if (days === -1) return "branched yesterday"
  return "branched " + (-days) + "d ago"
}

function barBranchText(value, now) {
  var days = daysUntil(value, now)
  if (days === null) return "br?"
  if (days === 0) return "br today"
  return days > 0 ? "br " + days + "d" : "br+" + (-days) + "d"
}

// "past" | "urgent" (<= 2d) | "soon" (<= 7d) | "later" | "unknown"
function branchUrgency(value, now) {
  var days = daysUntil(value, now)
  if (days === null) return "unknown"
  if (days < 0) return "past"
  if (days <= 2) return "urgent"
  if (days <= 7) return "soon"
  return "later"
}

function urgencyColor(urgency, fallback) {
  if (urgency === "urgent") return STATUS_COLORS.bad
  if (urgency === "soon") return STATUS_COLORS.warn
  if (urgency === "later") return STATUS_COLORS.good
  return fallback
}

function hasBranched(schedule, now) {
  var days = daysUntil(schedule ? schedule.branch_point : null, now)
  return days !== null && days <= 0
}

function findChannel(channels, name) {
  for (var i = 0; i < channels.length; i++) {
    if (channels[i].name === name) return channels[i]
  }
  return null
}

// Once Dev has branched, trunk (Canary) already belongs to the next
// milestone even while its binary still reports the old major version.
function canaryNeedsBump(channels, now) {
  var dev = findChannel(channels, "dev")
  var canary = findChannel(channels, "canary")
  return !!(dev && canary && dev.milestone === canary.milestone && hasBranched(dev.schedule, now))
}

function sortChannels(channels) {
  return channels.slice().sort(function(a, b) {
    return CHANNELS.indexOf(a.name) - CHANNELS.indexOf(b.name)
  })
}

function showsBranch(name) {
  return name === "dev" || name === "canary"
}

function barParts(channels, visible, now) {
  var parts = []
  var sorted = sortChannels(channels)
  for (var i = 0; i < sorted.length; i++) {
    var c = sorted[i]
    if (visible.indexOf(c.name) < 0) continue
    var text = displayName(c.name).charAt(0) + c.milestone
    if (showsBranch(c.name)) text += " (" + barBranchText(c.schedule ? c.schedule.branch_point : null, now) + ")"
    parts.push({ name: c.name, milestone: c.milestone, text: text, color: CHANNEL_COLORS[c.name] })
  }
  return parts
}

function scheduleProgress(schedule, now) {
  var branch = parseDate(schedule ? schedule.branch_point : null)
  var stable = parseDate(schedule ? schedule.stable_date : null)
  if (!branch || !stable || stable <= branch) return 0
  return Math.max(0, Math.min(1, (now - branch) / (stable - branch)))
}

function channelDetails(channel, now) {
  var s = channel.schedule || {}
  var rows = [
    { label: "Branch point", key: "branch_point" },
    { label: "Beta starts", key: "earliest_beta" },
    { label: "Beta ends", key: "latest_beta" },
    { label: "Final beta cut", key: "final_beta" },
    { label: "Stable", key: "stable_date", highlight: true }
  ]
  if (s.stable_refresh_first) rows.push({ label: "Refresh 1", key: "stable_refresh_first" })
  return rows.map(function(row) {
    return {
      label: row.label,
      value: dateText(s[row.key]),
      meta: relativeText(s[row.key], now),
      highlight: !!row.highlight
    }
  })
}

function timelineEvents(channels, visible, now) {
  var today = startOfDay(now)
  var events = []
  var sorted = sortChannels(channels)
  for (var i = 0; i < sorted.length; i++) {
    var c = sorted[i]
    if (visible.indexOf(c.name) < 0 || !c.schedule) continue
    var defs = [
      ["branch_point", "Branch point", c.name],
      ["earliest_beta", "Beta starts", "beta"],
      ["stable_date", "Stable release", "stable"],
      ["stable_refresh_first", "Stable refresh", "stable"]
    ]
    for (var j = 0; j < defs.length; j++) {
      var date = parseDate(c.schedule[defs[j][0]])
      if (!date) continue
      var days = daysBetween(today, date)
      if (days < -10 || days > 90) continue
      events.push({
        milestone: c.milestone,
        channel: c.name,
        title: defs[j][1],
        color: CHANNEL_COLORS[defs[j][2]],
        date: date,
        dateText: formatDate(date),
        relative: relativeDays(days),
        days: days
      })
    }
  }
  events.sort(function(a, b) { return a.date - b.date })
  return events
}

// Timeline events grouped as [{ milestone, events: [...] }], milestones
// ascending, events chronological within each group.
function groupedTimeline(events) {
  var byMilestone = {}
  var order = []
  for (var i = 0; i < events.length; i++) {
    var m = events[i].milestone
    if (!byMilestone[m]) {
      byMilestone[m] = []
      order.push(m)
    }
    byMilestone[m].push(events[i])
  }
  order.sort(function(a, b) { return a - b })
  return order.map(function(m) { return { milestone: m, events: byMilestone[m] } })
}

function nextEvent(events) {
  for (var i = 0; i < events.length; i++) {
    if (events[i].days >= 0) return events[i]
  }
  return null
}

function insights(channels, events, now) {
  var result = []
  var stable = findChannel(channels, "stable")
  var beta = findChannel(channels, "beta")
  var dev = findChannel(channels, "dev")
  var canary = findChannel(channels, "canary")

  if (stable && beta && stable.milestone === beta.milestone)
    result.push("M" + stable.milestone + " is both Stable and Beta right now. That is a channel promotion overlap, not a new branch.")
  if (beta && dev && beta.milestone === dev.milestone)
    result.push("M" + beta.milestone + " is both Beta and Dev right now. Dev has not moved to the next milestone yet.")
  if (dev && hasBranched(dev.schedule, now))
    result.push("M" + dev.milestone + " Dev already branched " + relativeText(dev.schedule.branch_point, now) + ". New trunk work belongs to the next milestone.")
  if (dev && canary && canary.milestone === dev.milestone + 1) {
    var binary = milestoneOf(canary.version)
    if (binary !== canary.milestone)
      result.push("Canary binary is still " + binary + ".x, but schedule-wise Canary is treated as M" + canary.milestone + ".")
    else
      result.push("Canary is on the next milestone, M" + canary.milestone + ", while Dev remains M" + dev.milestone + ".")
  }

  var next = nextEvent(events)
  if (next)
    result.push("Next: M" + next.milestone + " " + displayName(next.channel) + " " + next.title.toLowerCase() + " on " + next.dateText + " (" + next.relative + ").")

  if (result.length === 0)
    result.push("No channel overlap or branch gap detected. The channels line up normally.")
  return result
}

// ---- Bookmarks

function firstGroup(pattern, text) {
  var m = pattern.exec(text)
  return m ? m[1] : null
}

// Returns { kind: "cl" | "issue", id } or null. CL ids are either a bare
// chromium/src change number or "host:project:number".
function parseBookmark(input) {
  var text = String(input || "").trim()
  if (!text) return null

  var issue = firstGroup(/issues\.chromium\.org\/issues\/(\d+)/i, text)
    || firstGroup(/bugs\.chromium\.org\/p\/chromium\/issues\/detail\?id=(\d+)/i, text)
    || firstGroup(/crbug\.com\/(\d+)/i, text)
    || firstGroup(/^(?:issue|bug|b)[: ]*(\d+)$/i, text)
  if (issue) return { kind: "issue", id: issue }

  if (/^\d+$/.test(text)) return { kind: "cl", id: text }

  var chromium = firstGroup(/chromium-review\.googlesource\.com\/c\/chromium\/src\/\+\/(\d+)/i, text)
  if (chromium) return { kind: "cl", id: chromium }

  var generic = /([a-z0-9-]+-review\.googlesource\.com)\/c\/(.+?)\/\+\/(\d+)/i.exec(text)
  if (generic) return { kind: "cl", id: generic[1] + ":" + generic[2] + ":" + generic[3] }

  var crrev = firstGroup(/crrev\.com\/c\/(\d+)/i, text)
  if (crrev) return { kind: "cl", id: crrev }

  return null
}

function gerritTarget(bookmark) {
  var parts = String(bookmark).split(":")
  var host = "chromium-review.googlesource.com"
  var project = "chromium/src"
  var id = bookmark
  if (parts.length >= 3) {
    host = parts[0]
    id = parts[parts.length - 1]
    project = parts.slice(1, parts.length - 1).join(":")
  }
  var changeRef = encodeURIComponent(project) + "~" + id
  return {
    host: host,
    project: project,
    id: id,
    url: "https://" + host + "/c/" + project + "/+/" + id,
    detailUrl: "https://" + host + "/changes/" + changeRef + "/detail?o=MESSAGES&o=DETAILED_ACCOUNTS&o=SUBMITTABLE",
    mergeableUrl: "https://" + host + "/changes/" + changeRef + "/revisions/current/mergeable"
  }
}

function issueUrl(id) {
  return "https://issues.chromium.org/issues/" + id
}

function bookmarkUrl(bookmark) {
  return bookmark.kind === "issue" ? issueUrl(bookmark.id) : gerritTarget(bookmark.id).url
}

function bookmarkKey(bookmark) {
  return bookmark.kind + ":" + bookmark.id
}

function stripXssi(text) {
  var s = String(text || "")
  return s.indexOf(")]}'") === 0 ? s.slice(s.indexOf("\n") + 1) : s
}

function accountName(account) {
  if (!account) return "unknown"
  return account.name || account.email || account.username || "unknown"
}

function clDisplayStatus(change) {
  var status = String(change.status || "").toUpperCase()
  if (status === "MERGED" || status === "ABANDONED") return status
  if (change.mergeable === false) return "MERGE CONFLICT"
  if (change.submittable === true) return "SUBMITTABLE"
  return "ACTIVE"
}

function clStatusColor(change) {
  var status = clDisplayStatus(change)
  if (status === "MERGED" || status === "SUBMITTABLE") return STATUS_COLORS.good
  if (status === "ABANDONED" || status === "MERGE CONFLICT") return STATUS_COLORS.bad
  return STATUS_COLORS.info
}

function latestMessage(change) {
  var messages = change.messages || []
  if (!messages.length) return "No messages yet."
  var last = messages[messages.length - 1]
  var text = String(last.message || "").replace(/\n\n+/g, "\n").trim()
  return accountName(last.author) + ", " + String(last.date || "").slice(0, 10) + "\n" + text
}

// ---- Persisted state

function defaultState() {
  return { version: 1, visibleChannels: CHANNELS.slice(), bookmarks: [] }
}

// Caps the bytes we parse from the state file so a swapped-in oversized file
// (e.g. via a symlink) cannot force an unbounded allocation on load.
var MAX_STATE_BYTES = 256 * 1024;

function parseState(text) {
  var state = defaultState()
  var raw = String(text || "")
  if (raw.length > MAX_STATE_BYTES) return state
  try {
    var parsed = JSON.parse(raw)
    if (parsed && Array.isArray(parsed.visibleChannels))
      state.visibleChannels = parsed.visibleChannels.filter(function(c) { return CHANNELS.indexOf(c) >= 0 })
    if (parsed && Array.isArray(parsed.bookmarks))
      state.bookmarks = parsed.bookmarks.filter(function(b) {
        return b && (b.kind === "cl" || b.kind === "issue") && typeof b.id === "string" && b.id !== ""
      })
  } catch (e) {}
  return state
}

function toggleChannel(visible, name) {
  var next = visible.filter(function(c) { return c !== name })
  if (next.length === visible.length) next.push(name)
  return CHANNELS.filter(function(c) { return next.indexOf(c) >= 0 })
}

function addBookmark(bookmarks, bookmark) {
  var key = bookmarkKey(bookmark)
  for (var i = 0; i < bookmarks.length; i++) {
    if (bookmarkKey(bookmarks[i]) === key) return bookmarks
  }
  return bookmarks.concat([bookmark])
}

function removeBookmark(bookmarks, key) {
  return bookmarks.filter(function(b) { return bookmarkKey(b) !== key })
}
