import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "hjanuschka.omarchiumdash"
  ipcTarget: "hjanuschka.omarchiumdash"

  readonly property string platform: String(setting("platform", "linux"))
  readonly property int refreshMinutes: Math.max(5, parseInt(setting("refreshMinutes", 60), 10) || 60)
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchiumdash.json"
  readonly property string scriptPath: Qt.resolvedUrl("scripts/io.sh").toString().replace(/^file:\/\//, "")

  property var channels: []
  property bool loading: false
  property string errorText: ""
  property var lastUpdated: null
  property var now: new Date()
  property int generation: 0

  property var persisted: Model.defaultState()
  // Bookmark key -> { change } | { error }
  property var clInfo: ({})
  // Channel name / bookmark key -> true when its detail rows are shown.
  property var expanded: ({})
  property string addError: ""

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property bool lightTheme: fg.r * 0.299 + fg.g * 0.587 + fg.b * 0.114 < 0.5
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var visibleChannels: persisted.visibleChannels
  readonly property var barParts: Model.barParts(channels, visibleChannels, now)
  readonly property var events: Model.timelineEvents(channels, visibleChannels, now)
  readonly property var insightList: Model.insights(channels, events, now)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- Networking and state I/O

  // Quickshell cannot bound XMLHttpRequest buffering or open FileView with
  // O_NOFOLLOW, so scripts/io.sh runs every network and state-file operation
  // behind hard byte, time, and descriptor-bound symlink guards.
  function runIO(args, input, onDone) {
    var proc = ioComponent.createObject(root, { args: args, input: input })
    if (!proc) {
      if (onDone) onDone(-1, "")
      return
    }
    proc.onDone = onDone
    proc.running = true
  }

  function request(url, done) {
    runIO(["fetch", url], "", function(code, out) {
      if (code !== 0) {
        done(code === 2 ? "Blocked host" : "Fetch failed", null)
        return
      }
      try {
        done("", JSON.parse(Model.stripXssi(out)))
      } catch (e) {
        done("Bad response", null)
      }
    })
  }

  function loadState() {
    runIO(["read-state", root.statePath], "", function(code, out) {
      root.persisted = Model.parseState(out)
      root.refreshBookmarks()
    })
  }

  function fetchSchedule(milestone, done) {
    request(Model.scheduleUrl(milestone), function(err, data) {
      done(!err && data && data.mstones && data.mstones.length ? data.mstones[0] : null)
    })
  }

  function refresh() {
    var gen = ++generation
    var results = []
    var failures = []
    var pending = Model.CHANNELS.length
    loading = true
    errorText = ""
    now = new Date()

    function finish() {
      if (--pending > 0) return
      if (failures.length) {
        loading = false
        errorText = failures.join(", ")
        return
      }
      if (!Model.canaryNeedsBump(results, now)) {
        applyChannels(gen, results)
        return
      }
      var next = Model.findChannel(results, "dev").milestone + 1
      fetchSchedule(next, function(schedule) {
        var canary = Model.findChannel(results, "canary")
        canary.milestone = next
        canary.schedule = schedule
        applyChannels(gen, results)
      })
    }

    Model.CHANNELS.forEach(function(name) {
      request(Model.versionUrl(root.platform, name), function(err, data) {
        if (gen !== root.generation) return
        var version = data && data.versions && data.versions.length ? data.versions[0].version : ""
        if (!version) {
          failures.push(Model.displayName(name) + ": " + (err || "no version"))
          finish()
          return
        }
        var milestone = Model.milestoneOf(version)
        fetchSchedule(milestone, function(schedule) {
          results.push({ name: name, version: version, milestone: milestone, schedule: schedule })
          finish()
        })
      })
    })

    refreshBookmarks()
  }

  function applyChannels(gen, results) {
    if (gen !== generation) return
    channels = Model.sortChannels(results)
    lastUpdated = new Date()
    loading = false
  }

  function refreshBookmarks() {
    persisted.bookmarks.forEach(function(bookmark) {
      if (bookmark.kind === "cl") refreshCL(bookmark)
    })
  }

  function refreshCL(bookmark) {
    var key = Model.bookmarkKey(bookmark)
    var target = Model.gerritTarget(bookmark.id)
    request(target.detailUrl, function(err, change) {
      if (err || !change) {
        setClInfo(key, { error: err || "Could not load CL" })
        return
      }
      if (String(change.status).toUpperCase() !== "NEW") {
        setClInfo(key, { change: change })
        return
      }
      request(target.mergeableUrl, function(mergeErr, mergeable) {
        if (!mergeErr && mergeable) change.mergeable = mergeable.mergeable
        setClInfo(key, { change: change })
      })
    })
  }

  function setClInfo(key, value) {
    var next = Object.assign({}, clInfo)
    if (value === null) delete next[key]
    else next[key] = value
    clInfo = next
  }

  // ---- Persisted state

  function savePersisted(next) {
    persisted = next
    runIO(["write-state", root.statePath], JSON.stringify(next, null, 2) + "\n", null)
  }

  function toggleChannel(name) {
    savePersisted(Object.assign({}, persisted, { visibleChannels: Model.toggleChannel(persisted.visibleChannels, name) }))
  }

  function addBookmark(text) {
    var bookmark = Model.parseBookmark(text)
    if (!bookmark) {
      addError = "Not a CL number, Gerrit URL, crrev link, or issue URL"
      return false
    }
    addError = ""
    savePersisted(Object.assign({}, persisted, { bookmarks: Model.addBookmark(persisted.bookmarks, bookmark) }))
    if (bookmark.kind === "cl") refreshCL(bookmark)
    return true
  }

  function removeBookmark(key) {
    savePersisted(Object.assign({}, persisted, { bookmarks: Model.removeBookmark(persisted.bookmarks, key) }))
    setClInfo(key, null)
  }

  function toggleExpanded(key) {
    var next = Object.assign({}, expanded)
    next[key] = !next[key]
    expanded = next
  }

  function openUrl(url) {
    Quickshell.execDetached(["xdg-open", url])
    close()
  }

  function timeText(date) {
    return date ? Qt.formatTime(date, "HH:mm") : ""
  }

  function relativeColor(text) {
    if (text === "today" || text === "tomorrow") return tone(Model.STATUS_COLORS.warn)
    if (text.indexOf("in ") === 0) return tone(Model.STATUS_COLORS.good)
    return root.dim
  }

  // Palette colors are tuned for dark themes; deepen them on light ones.
  function tone(c) {
    return root.lightTheme ? Qt.darker(c, 1.6) : c
  }

  function tooltip() {
    if (errorText) return "Chromium Branches: " + errorText
    return root.channels.map(function(c) {
      return Model.displayName(c.name) + " M" + c.milestone + " (" + c.version + ")"
    }).join("\n")
  }

  Component {
    id: ioComponent

    Process {
      id: proc
      property var args: []
      property string input: ""
      property var onDone: null
      property string collected: ""
      command: ["sh", root.scriptPath].concat(proc.args)
      stdinEnabled: proc.input !== ""

      stdout: StdioCollector {
        id: collector
        onStreamFinished: proc.collected = collector.text
      }

      onStarted: {
        if (proc.input !== "") {
          proc.write(proc.input)
          proc.stdinEnabled = false
        }
      }

      onExited: function(code, status) {
        var cb = proc.onDone
        var out = proc.collected
        proc.destroy()
        if (cb) cb(code, out)
      }
    }
  }

  Timer {
    interval: root.refreshMinutes * 60000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  // Keeps day countdowns correct across midnight between network refreshes.
  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.now = new Date()
  }

  onPlatformChanged: refresh()
  onOpenedChanged: if (opened) now = new Date()
  Component.onCompleted: {
    loadState()
    refresh()
  }

  // ---- Bar pill

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: vertical ? -1 : pill.implicitWidth + scaledHorizontalMargin * 2
    fixedHeight: vertical ? pill.implicitHeight + scaledVerticalPadding * 2 : -1
    tooltipText: root.opened ? "" : root.tooltip()

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else if (b === Qt.RightButton) root.openUrl(Model.SCHEDULE_URL)
      else root.toggle()
    }

    Grid {
      id: pill
      anchors.centerIn: parent
      columns: button.vertical ? 1 : Math.max(1, root.barParts.length)
      columnSpacing: Style.space(10)
      rowSpacing: Style.space(2)

      Text {
        visible: root.barParts.length === 0
        textFormat: Text.PlainText
        text: root.errorText ? "Cr !" : "Cr ..."
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Repeater {
        model: root.barParts

        Row {
          required property var modelData
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: "●"
            color: modelData.color
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            textFormat: Text.PlainText
            text: button.vertical ? String(modelData.milestone) : modelData.text
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: button.vertical ? Style.font.caption : Style.font.body
            font.bold: true
          }
        }
      }
    }
  }

  // ---- Popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: addField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r") root.refresh() }

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroller.width
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: "Chromium Branches"
            detail: root.platform
            meta: root.loading ? "Refreshing..." : (root.errorText ? "Error: " + root.errorText : "Updated " + root.timeText(root.lastUpdated))
            foreground: root.fg
            fontFamily: root.fontFamily
            iconSize: Style.font.display
            iconComponent: heroIcon
          }

          // At a glance
          PanelSeparator { width: parent.width; foreground: root.fg; visible: root.channels.length > 0 }
          SectionHeader { text: "AT A GLANCE"; visible: root.channels.length > 0 }

          Repeater {
            model: root.channels.length > 0 ? root.insightList : []

            Row {
              required property string modelData
              width: column.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: "?"
                color: root.tone(Model.CHANNEL_COLORS.beta)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                width: parent.width - Style.space(20)
                textFormat: Text.PlainText
                text: modelData
                wrapMode: Text.Wrap
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          // Channels
          PanelSeparator { width: parent.width; foreground: root.fg; visible: root.channels.length > 0 }
          SectionHeader { text: "CHANNELS"; visible: root.channels.length > 0 }

          Repeater {
            model: root.channels
            ChannelCard { width: column.width }
          }

          // Timeline
          PanelSeparator { width: parent.width; foreground: root.fg; visible: root.events.length > 0 }
          SectionHeader { text: "SCHEDULE (NEXT 90 DAYS)"; visible: root.events.length > 0 }

          Repeater {
            model: Model.groupedTimeline(root.events)

            Column {
              required property var modelData
              width: column.width
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: "M" + modelData.milestone
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Repeater {
                model: modelData.events
                TimelineRow { width: column.width }
              }
            }
          }

          // Bookmarks
          PanelSeparator { width: parent.width; foreground: root.fg }
          SectionHeader { text: "CL & ISSUE BOOKMARKS" }

          TextField {
            id: addField
            width: parent.width
            placeholderText: "Paste CL number, Gerrit/crrev URL, or issue URL"
            foreground: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (root.addBookmark(addField.text)) addField.text = ""
                event.accepted = true
              } else if (event.key === Qt.Key_Escape) {
                addField.text = ""
                root.addError = ""
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
            }
          }

          Text {
            visible: root.addError !== ""
            textFormat: Text.PlainText
            text: root.addError
            color: root.tone(Model.STATUS_COLORS.bad)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.persisted.bookmarks
            BookmarkRow { width: column.width }
          }

          // Bar visibility
          PanelSeparator { width: parent.width; foreground: root.fg }
          SectionHeader { text: "SHOW IN BAR" }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: Model.CHANNELS

              Button {
                required property string modelData
                width: (column.width - Style.space(6) * 3) / 4
                text: Model.displayName(modelData)
                fontSize: Style.font.caption
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                selected: root.visibleChannels.indexOf(modelData) >= 0
                onClicked: root.toggleChannel(modelData)
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.fg }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              width: (column.width - Style.space(6)) / 2
              text: "Refresh"
              iconText: "󰑐"
              fontSize: Style.font.caption
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.refresh()
            }

            Button {
              width: (column.width - Style.space(6)) / 2
              text: "ChromiumDash schedule"
              iconText: "󰖟"
              fontSize: Style.font.caption
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.openUrl(Model.SCHEDULE_URL)
            }
          }
        }
      }
    }
  }

  Component {
    id: heroIcon
    Text {
      textFormat: Text.PlainText
      text: ""
      color: root.tone(Model.CHANNEL_COLORS.stable)
      font.family: root.fontFamily
      font.pixelSize: Style.font.display
    }
  }

  component SectionHeader: PanelSectionHeader {
    foreground: root.fg
    fontFamily: root.fontFamily
  }

  component SmallText: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }

  component ChannelCard: Rectangle {
    id: card
    required property var modelData
    readonly property var channel: modelData
    readonly property color accent: Model.CHANNEL_COLORS[channel.name]
    readonly property var schedule: channel.schedule || {}
    readonly property bool showDetails: root.expanded[channel.name] === true
    readonly property string urgency: Model.branchUrgency(schedule.branch_point, root.now)

    implicitHeight: cardColumn.implicitHeight + Style.space(16)
    radius: Style.cornerRadius
    color: Qt.rgba(accent.r, accent.g, accent.b, cardMouse.containsMouse ? 0.16 : 0.10)

    Rectangle {
      width: Style.space(3)
      height: parent.height
      radius: width / 2
      color: card.accent
    }

    MouseArea {
      id: cardMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleExpanded(card.channel.name)
    }

    Column {
      id: cardColumn
      x: Style.space(12)
      y: Style.space(8)
      width: parent.width - Style.space(24)
      spacing: Style.space(4)

      Item {
        width: parent.width
        height: titleText.implicitHeight

        SmallText {
          id: titleText
          text: "M" + card.channel.milestone + " " + Model.displayName(card.channel.name)
            + (Model.showsBranch(card.channel.name) ? "  " + Model.branchCountdownText(card.schedule.branch_point, root.now) : "")
          font.pixelSize: Style.font.subtitle
          font.bold: true
          width: parent.width - versionText.implicitWidth - Style.space(8)
        }

        SmallText {
          id: versionText
          anchors.right: parent.right
          text: card.channel.version
          color: root.dim
        }
      }

      Item {
        width: parent.width
        height: branchText.implicitHeight

        SmallText {
          id: branchText
          text: "Branch: " + Model.dateText(card.schedule.branch_point) + " (" + Model.relativeText(card.schedule.branch_point, root.now) + ")"
          color: Model.urgencyColor(card.urgency, "") ? root.tone(Model.urgencyColor(card.urgency, "")) : root.dim
        }

        SmallText {
          anchors.right: parent.right
          text: "Stable: " + Model.dateText(card.schedule.stable_date)
          color: root.tone(Model.STATUS_COLORS.good)
        }
      }

      Rectangle {
        width: parent.width
        height: Style.space(4)
        radius: height / 2
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.15)

        Rectangle {
          width: parent.width * Model.scheduleProgress(card.schedule, root.now)
          height: parent.height
          radius: parent.radius
          color: card.accent
        }
      }

      Repeater {
        model: card.showDetails ? Model.channelDetails(card.channel, root.now) : []

        Item {
          required property var modelData
          width: cardColumn.width
          height: detailLabel.implicitHeight

          SmallText {
            id: detailLabel
            width: parent.width * 0.35
            text: modelData.label
            color: root.dim
          }

          SmallText {
            x: parent.width * 0.35
            width: parent.width * 0.4
            text: modelData.value
            font.bold: modelData.highlight
            color: modelData.highlight ? root.tone(Model.STATUS_COLORS.good) : root.fg
          }

          SmallText {
            anchors.right: parent.right
            text: modelData.meta
            color: root.relativeColor(modelData.meta)
          }
        }
      }
    }
  }

  component TimelineRow: Rectangle {
    id: row
    required property var modelData
    readonly property bool isToday: modelData.days === 0

    implicitHeight: rowItem.implicitHeight + Style.space(4)
    radius: Style.cornerRadius
    color: isToday ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18) : "transparent"

    Item {
      id: rowItem
      x: Style.space(4)
      width: parent.width - Style.space(8)
      implicitHeight: titleLabel.implicitHeight
      anchors.verticalCenter: parent.verticalCenter
      opacity: row.modelData.days < 0 ? 0.55 : 1

      Rectangle {
        width: Style.space(8)
        height: width
        radius: width / 2
        color: row.modelData.color
        anchors.verticalCenter: parent.verticalCenter
      }

      SmallText {
        id: titleLabel
        x: Style.space(16)
        width: parent.width * 0.32
        text: row.modelData.title
        font.bold: true
      }

      SmallText {
        x: parent.width * 0.38
        width: parent.width * 0.17
        text: Model.displayName(row.modelData.channel)
        color: root.tone(Model.CHANNEL_COLORS[row.modelData.channel])
        font.bold: true
      }

      SmallText {
        x: parent.width * 0.56
        width: parent.width * 0.26
        text: row.modelData.dateText
        color: root.dim
      }

      SmallText {
        anchors.right: parent.right
        text: row.modelData.relative
        color: root.relativeColor(row.modelData.relative)
        font.bold: true
      }
    }
  }

  component BookmarkRow: Rectangle {
    id: bookmarkRow
    required property var modelData
    readonly property var bookmark: modelData
    readonly property string key: Model.bookmarkKey(bookmark)
    readonly property bool isCL: bookmark.kind === "cl"
    readonly property var info: root.clInfo[key]
    readonly property var change: info && info.change ? info.change : null
    readonly property bool showDetails: root.expanded[key] === true
    readonly property string label: isCL ? "CL " + Model.gerritTarget(bookmark.id).id : "Issue " + bookmark.id
    readonly property string status: !isCL ? "BOOKMARKED"
      : change ? Model.clDisplayStatus(change)
      : info && info.error ? "ERROR"
      : "LOADING"
    readonly property color statusColor: !isCL ? root.tone(Model.CHANNEL_COLORS.dev)
      : change ? root.tone(Model.clStatusColor(change))
      : info && info.error ? root.tone(Model.STATUS_COLORS.bad)
      : root.dim
    readonly property string subtitle: !isCL ? "issues.chromium.org"
      : change ? Model.accountName(change.owner) + "  " + change.branch + "  " + String(change.updated).slice(0, 10)
      : info && info.error ? info.error
      : ""

    implicitHeight: rowColumn.implicitHeight + Style.space(12)
    radius: Style.cornerRadius
    color: rowMouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04)

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: bookmarkRow.isCL ? root.toggleExpanded(bookmarkRow.key) : root.openUrl(Model.bookmarkUrl(bookmarkRow.bookmark))
    }

    Column {
      id: rowColumn
      x: Style.space(8)
      y: Style.space(6)
      width: parent.width - Style.space(16) - actions.width
      spacing: Style.space(2)

      SmallText {
        width: parent.width
        text: "● " + bookmarkRow.label + "  " + bookmarkRow.status
        color: bookmarkRow.statusColor
        font.bold: true
      }

      SmallText {
        width: parent.width
        visible: text !== ""
        text: bookmarkRow.change ? bookmarkRow.change.subject : ""
      }

      SmallText {
        width: parent.width
        visible: text !== ""
        text: bookmarkRow.subtitle
        color: root.dim
        font.pixelSize: Style.font.caption
      }

      SmallText {
        width: parent.width
        visible: bookmarkRow.showDetails && bookmarkRow.change !== null
        text: bookmarkRow.change ? Model.latestMessage(bookmarkRow.change) : ""
        wrapMode: Text.Wrap
        maximumLineCount: 12
        color: root.dim
        font.pixelSize: Style.font.caption
      }
    }

    Row {
      id: actions
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.top: parent.top
      anchors.topMargin: Style.space(4)
      spacing: Style.space(2)

      PanelActionButton {
        iconText: "󰏌"
        tooltipText: "Open"
        foreground: root.fg
        fontFamily: root.fontFamily
        fontSize: Style.font.body
        onClicked: root.openUrl(Model.bookmarkUrl(bookmarkRow.bookmark))
      }

      PanelActionButton {
        iconText: "󰅖"
        tooltipText: "Remove"
        foreground: root.fg
        fontFamily: root.fontFamily
        fontSize: Style.font.body
        onClicked: root.removeBookmark(bookmarkRow.key)
      }
    }
  }
}
