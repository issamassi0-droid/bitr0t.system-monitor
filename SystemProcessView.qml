import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

import "SystemMonitorModel.js" as MonitorModel

// Processes tab of the system monitor popover: a live, searchable, sortable
// table of the user's own processes. `ps` runs on a 2s cadence, but only
// while `active` (the tab is showing), and every launch goes through an argv
// list — nothing typed into the search box, or read out of the environment,
// can ever reach a shell. Each completed snapshot is parsed into a bounded
// JS array and reassigned whole; selections carry the process's lstart
// birth token and are reconciled against every snapshot by PID *and*
// token, so neither an exited process nor a reused PID can linger as the
// kill target. Ending a process always goes through ConfirmDialog and one
// argv-only launch of the colocated `bin/pidfd-signal` helper, which pins
// the process with a pidfd, re-verifies its lstart birth token against
// kernel truth, and only then sends SIGTERM — a reused PID is never
// signalled and no validate-then-kill window exists.
Item {
  id: root

  required property QtObject bar
  property bool active: false
  // True on hosts that offer a large task-manager window: the footer's
  // secondary action then becomes "Open full view". The copy embedded in
  // that window keeps it false and keeps the btop action.
  property bool fullViewAvailable: false

  signal openBtopRequested()
  signal openTaskManagerRequested()

  // ---- theme and interactive surfaces -----------------------------------

  SystemMonitorTheme {
    id: theme
    bar: root.bar
  }

  readonly property color rowHoverColor:
    Style.hoverFillFor(theme.foreground, theme.accentColor, theme.criticalColor)
  readonly property color rowSelectedColor:
    Style.selectedFillFor(theme.foreground, theme.accentColor, theme.criticalColor)
  readonly property color rowZebraColor: theme.cardFill
  readonly property color ruleColor: theme.cardBorder

  // ---- table geometry ----------------------------------------------------
  readonly property real rowHeight: 26
  readonly property real edgeInset: 10
  readonly property real columnGap: 12
  readonly property real pidColumnWidth: 56
  readonly property real cpuColumnWidth: 60
  readonly property real memoryColumnWidth: 64
  readonly property real nameColumnWidth: Math.max(80,
    width - edgeInset * 2 - pidColumnWidth - cpuColumnWidth - memoryColumnWidth - columnGap * 3)
  readonly property real pidX: edgeInset + nameColumnWidth + columnGap
  readonly property real cpuX: pidX + pidColumnWidth + columnGap
  readonly property real memoryX: cpuX + cpuColumnWidth + columnGap

  // ---- state -------------------------------------------------------------
  //
  // `processes` is only ever reassigned with a complete, bounded snapshot —
  // never mutated in place — so the model binding recomputes atomically.
  property var processes: []
  property string sortKey: "cpu" // "cpu" | "memory" | "name"
  property bool sortDescending: true
  property int selectedPid: -1
  property string selectedName: ""
  property string selectedStartToken: ""
  property string statusText: ""
  property string statusKind: "" // "success" | "error" | "info"
  property bool loaded: false
  property string errorText: ""
  property int pollSerial: 0

  // Colocated race-free termination helper, resolved against this QML file
  // so hosts embedding the view from anywhere find the plugin's own copy.
  readonly property string helperPath: {
    var url = String(Qt.resolvedUrl("bin/pidfd-signal"))
    var path = url.indexOf("file://") === 0 ? url.substring(7) : url
    return decodeURIComponent(path)
  }

  // Hard bounds: parse at most this many rows out of any one ps snapshot and
  // render at most rowLimit of them, so a pathological session can never
  // balloon the delegate count.
  readonly property int snapshotLimit: 400
  readonly property int rowLimit: 200

  readonly property string query: searchField.text

  // True while this tab must own raw keyboard input: the search field is
  // focused, or the kill confirmation dialog is open. The owning panel
  // blocks its PanelKeyCatcher while this is set and feeds the raw key
  // events to handleKey(), which answers the dialog first — so arrows and
  // Tab edit the query instead of switching tabs, and the dialog's
  // Escape/Enter are honored before the panel's close/tab shortcuts.
  readonly property bool inputOwnsKeys: searchField.activeFocus || killDialog.opened

  // Filter + sort are pure bindings over the snapshot, so typing or switching
  // the sort column re-renders immediately — no debounce, no stale rows.
  readonly property var visibleProcesses:
    MonitorModel.filterAndSortProcesses(
      processes, query, sortKey, rowLimit, sortDescending)

  readonly property string placeholderText: {
    if (errorText !== "") return errorText
    if (!loaded) return "Collecting processes…"
    if (visibleProcesses.length === 0) {
      var needle = query.trim()
      return needle !== "" ? "No processes match “" + needle + "”" : "No processes found"
    }
    return ""
  }

  readonly property color statusColor: statusKind === "success"
    ? theme.uploadColor
    : (statusKind === "error" ? theme.criticalColor : theme.muted)

  readonly property string summaryText: {
    var count = visibleProcesses.length
    var label = count + (count === 1 ? " process" : " processes")
    if (count === rowLimit) label += "+"
    var sortLabel = sortKey === "memory" ? "memory" : (sortKey === "name" ? "name" : "CPU")
    return label + " · sorted by " + sortLabel
      + (sortDescending ? " descending" : " ascending")
  }

  // ---- data flow ---------------------------------------------------------

  function chooseSort(key) {
    if (sortKey === key) {
      sortDescending = !sortDescending
      return
    }
    sortKey = key
    sortDescending = key !== "name"
  }

  // Thresholds live in the model; only the palette mapping is local.
  function levelColor(value, base) {
    var level = MonitorModel.utilizationLevel(value)
    if (level === "critical") return theme.criticalColor
    if (level === "warning") return theme.warningColor
    return base
  }

  // argv list, never a shell string. The username comes from the environment,
  // not from anything the user typed, and it rides as a single argv element.
  function refresh() {
    // Never overlap probes: if ps is still draining, this tick is skipped.
    if (listProc.running) return
    pollSerial = pollSerial + 1
    listProc.serial = pollSerial
    listProc.lastExitCode = 0
    listProc.command = MonitorModel.buildPsCommand(String(Quickshell.env("USER") || ""))
    listProc.running = true
  }

  function applyProcesses(raw) {
    // A snapshot that fails to parse reads as "no processes" — same reading
    // the inline parser gave unusable output.
    var entries = MonitorModel.parsePsOutput(raw, snapshotLimit)
    processes = entries || []
    loaded = true
    errorText = ""
    reconcileSelection(processes)
  }

  // Drop the selection as soon as the PID + birth token leave the snapshot:
  // neither an exited process nor a reused PID can stay the kill target.
  function reconcileSelection(snapshot) {
    if (selectedPid < 0) return
    var match = MonitorModel.findProcessByPid(snapshot, selectedPid, selectedStartToken)
    if (match) {
      selectedName = match.name
      selectedStartToken = match.startToken || selectedStartToken
      return
    }
    var label = selectedName !== "" ? selectedName : "Process"
    selectedPid = -1
    selectedName = ""
    // Don't stomp a kill result that is still on screen; only announce the
    // exit when nothing else is being reported.
    if (statusText === "") setStatus("info", label + " exited")
  }

  function selectProcess(pid, name, startToken) {
    selectedPid = pid
    selectedName = name
    selectedStartToken = startToken || ""
  }

  function clearSelection() {
    selectedPid = -1
    selectedName = ""
    selectedStartToken = ""
  }

  function setStatus(kind, text) {
    statusKind = text !== "" ? kind : ""
    statusText = text
    if (text !== "") statusClear.restart()
  }

  function requestEndSelected() {
    if (selectedPid < 0 || helperProc.running) return
    killDialog.selectedIndex = 1
    killDialog.message = "End " + selectedName + " (PID " + selectedPid
      + ")?\nUnsaved work in this process will be lost."
    killDialog.opened = true
  }

  // Confirmation alone is not enough: between the click and the signal a
  // process can exit and its PID can be handed to a different program. The
  // helper closes that window itself — it pins the process with a pidfd,
  // re-derives the PID's lstart birth token from /proc and compares it with
  // the token captured at selection, sending SIGTERM through the pidfd only
  // on an exact match. argv list, never a shell string; invalid input
  // produces no command at all, so the helper simply never launches.
  function endSelectedProcess() {
    if (selectedPid < 0 || helperProc.running) return
    var argv = MonitorModel.buildPidfdSignalCommand(helperPath, selectedPid, selectedStartToken)
    if (!argv || argv.length === 0) return
    helperProc.targetPid = selectedPid
    helperProc.targetName = selectedName
    helperProc.command = argv
    helperProc.running = true
    setStatus("info", "Ending " + selectedName + "…")
  }

  // Optional wiring for the owning panel: route key events here before the
  // panel's own handling so the confirm dialog answers keyboard input.
  function handleKey(event) {
    return killDialog.handleKey(event)
  }

  // Public focus hook for hosts that embed this view in a window — the
  // search field is a private id, and refresh() is already public.
  function focusSearch() {
    if (root.active) searchField.forceActiveFocus()
  }

  onActiveChanged: {
    if (active) {
      refresh() // fresh snapshot the moment the tab is shown
    } else {
      killDialog.opened = false
    }
  }

  // ---- processes: 2s poll, strictly while the tab is active --------------

  Timer {
    interval: 2000
    running: root.active
    repeat: true
    onTriggered: root.refresh()
  }

  // Serial-guarded so an out-of-order drain from a superseded launch (or a
  // failed run) can never clobber a newer snapshot.
  Process {
    id: listProc
    property int serial: 0
    property int lastExitCode: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (listProc.serial !== root.pollSerial) return
        if (listProc.lastExitCode !== 0) return
        root.applyProcesses(text)
      }
    }
    onExited: function(exitCode, exitStatus) {
      lastExitCode = exitCode
      if (exitCode !== 0 && serial === root.pollSerial) {
        root.errorText = "Could not list processes (ps exited with code "
          + exitCode + ") — retrying every 2 seconds"
        root.loaded = true
      }
    }
  }

  // ---- ending: bin/pidfd-signal PID TOKEN, argv list, never a shell -----
  //
  // The single launch that validates identity and signals atomically: exit
  // 0 means the confirmed process was signalled; exit 3 (vanished) or 4
  // (identity mismatch — the PID now names a different process) clears the
  // selection and asks the user to confirm again; anything else is a
  // genuine failure. Identity failure is never reported as success.

  Process {
    id: helperProc
    property int targetPid: -1
    property string targetName: ""
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: helperStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      var label = targetName !== "" ? targetName : "process"
      var pid = targetPid
      targetPid = -1
      targetName = ""
      if (exitCode === 0) {
        setStatus("success", "Ended " + label + " (PID " + pid + ")")
        refresh()
        return
      }
      // Vanished (3), identity mismatch (4), or refused arguments (2):
      // the selection no longer names a confirmed process.
      if (exitCode === 2 || exitCode === 3 || exitCode === 4) {
        setStatus("error", "Could not confirm " + label + " (PID " + pid
          + ") — it may have exited; select it again")
        clearSelection()
        refresh()
        return
      }
      var detail = String(helperStderr.text || "").trim()
      setStatus("error", "Could not end " + label + " (PID " + pid + ")"
        + (detail !== "" ? " — " + detail : " — it may have already exited"))
      refresh()
    }
  }

  Timer {
    id: statusClear
    interval: 5000
    repeat: false
    onTriggered: root.setStatus("", "")
  }

  implicitHeight: Style.space(380)

  Column {
    id: contentColumn
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: Style.space(10)

    // ---- toolbar: search · manual refresh ----

    Row {
      id: toolbar
      width: parent.width
      spacing: Style.space(8)

      TextField {
        id: searchField
        width: parent.width - refreshButton.width - parent.spacing
        placeholderText: "Search process or PID…"
        foreground: theme.foreground
        accent: theme.accentColor
        font.family: theme.fontFamily
        font.pixelSize: Style.font.bodySmall
        selectByMouse: true
        onAccepted: {
          // Enter answers an open dialog before refreshing the snapshot.
          if (killDialog.opened && killDialog.handleKey({ key: Qt.Key_Return })) return
          root.refresh()
        }
      }

      PanelActionButton {
        id: refreshButton
        iconText: "󰑐"
        tooltipText: "Refresh now"
        foreground: theme.foreground
        hoverColor: theme.accentColor
        fontFamily: theme.fontFamily
        enabled: !listProc.running
        onClicked: root.refresh()
      }
    }

    // ---- header: column titles; CPU/MEM are sort toggles ----

    Item {
      id: tableHeader
      width: parent.width
      implicitHeight: Style.space(18)
      height: implicitHeight

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: root.ruleColor
      }

      SortHeader {
        label: "PROCESS"
        sortValue: "name"
        textColor: theme.foreground
        leftAlign: true
        x: root.edgeInset
        width: root.nameColumnWidth
      }

      Text {
        text: "PID"
        color: theme.muted
        font.family: theme.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        x: root.pidX
        width: root.pidColumnWidth
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
      }

      SortHeader {
        label: "CPU%"
        sortValue: "cpu"
        textColor: theme.cpuColor
        x: root.cpuX
        width: root.cpuColumnWidth
      }

      SortHeader {
        label: "MEM%"
        sortValue: "memory"
        textColor: theme.memoryColor
        x: root.memoryX
        width: root.memoryColumnWidth
      }
    }

    // ---- table ----

    Item {
      id: tableArea
      width: parent.width
      height: Math.max(Style.space(156),
        root.height - toolbar.implicitHeight - tableHeader.implicitHeight
          - footer.implicitHeight - contentColumn.spacing * 3)
      clip: true

      ListView {
        id: processList
        anchors.fill: parent
        model: root.visibleProcesses
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        QQC.ScrollBar.vertical: QQC.ScrollBar {}

        delegate: ProcessRow {
          width: processList.width
        }
      }

      // Loading / error / empty overlay — one centered line, same slot the
      // table occupies, so the layout never jumps between states.
      Text {
        anchors.centerIn: parent
        width: parent.width - Style.space(24)
        visible: root.placeholderText !== ""
        text: root.placeholderText
        textFormat: Text.PlainText
        color: root.errorText !== "" ? theme.criticalColor : theme.muted
        font.family: theme.fontFamily
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap

        Behavior on color {
          ColorAnimation { duration: theme.animationDuration }
        }
      }
    }

    // ---- footer: status/summary · end process · secondary action --------

    Row {
      id: footer
      width: parent.width
      spacing: Style.space(8)

      Text {
        text: root.statusText !== "" ? root.statusText : root.summaryText
        textFormat: Text.PlainText
        color: root.statusText !== "" ? root.statusColor : theme.muted
        font.family: theme.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - endButton.width - btopButton.width - parent.spacing * 2
        elide: Text.ElideRight
        Behavior on color {
          ColorAnimation { duration: theme.animationDuration }
        }
      }


      Button {
        id: endButton
        text: "End Process"
        tooltipText: root.selectedPid >= 0
          ? "End " + root.selectedName + " (PID " + root.selectedPid + ")"
          : "Select a process first"
        bordered: true
        enabled: root.selectedPid >= 0 && !helperProc.running
        foreground: theme.criticalColor
        accent: theme.criticalColor
        fontFamily: theme.fontFamily
        fontSize: Style.font.bodySmall
        horizontalPadding: Style.space(12)
        verticalPadding: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.requestEndSelected()
      }

      // The one footer slot whose meaning depends on the host: open the
      // large task-manager window where one exists, btop otherwise.
      Button {
        id: btopButton
        text: root.fullViewAvailable ? "Open full view" : "Open btop"
        tooltipText: root.fullViewAvailable
          ? "Open the task manager window"
          : "Open btop in a terminal"
        bordered: true
        foreground: theme.foreground
        accent: theme.cpuColor
        fontFamily: theme.fontFamily
        fontSize: Style.font.bodySmall
        horizontalPadding: Style.space(12)
        verticalPadding: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.fullViewAvailable
          ? root.openTaskManagerRequested()
          : root.openBtopRequested()
      }
    }
  }

  // ---- confirm dialog: scrimmed, scoped to this view ----

  ConfirmDialog {
    id: killDialog
    anchors.fill: parent
    opened: false
    message: ""
    cancelText: "Cancel"
    confirmText: "End Process"
    foreground: theme.foreground
    selectedText: theme.accentColor
    fontFamily: theme.fontFamily
    onCanceled: opened = false
    onConfirmed: {
      opened = false
      root.endSelectedProcess()
    }
  }

  // ---- reusable pieces ----------------------------------------------------

  // Sortable column header. Always sorts descending — top consumers first is
  // the only direction that matters here — and paints the active column in
  // its metric color with a trailing arrow.
  component SortHeader: Item {
    id: header
    property string label: ""
    property string sortValue: ""
    property color textColor: theme.foreground
    property bool leftAlign: false
    readonly property bool activeSort: root.sortKey === sortValue
    height: parent ? parent.height : Style.space(18)

    Text {
      anchors.left: header.leftAlign ? parent.left : undefined
      anchors.horizontalCenter: header.leftAlign ? undefined : parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      text: header.label + (header.activeSort
        ? (root.sortDescending ? "  ▼" : "  ▲") : "")
      color: header.activeSort ? header.textColor : theme.muted
      font.family: theme.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      Behavior on color {
        ColorAnimation { duration: theme.animationDuration }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.chooseSort(header.sortValue)
    }
  }

  component ProcessRow: Rectangle {
    id: row
    required property int index
    required property var modelData
    readonly property bool selected: root.selectedPid === modelData.pid
    readonly property bool hovered: rowMouse.containsMouse

    height: root.rowHeight
    color: selected
      ? root.rowSelectedColor
      : (hovered ? root.rowHoverColor : (index % 2 === 1 ? root.rowZebraColor : "transparent"))
    radius: Style.cornerRadius

    Behavior on color {
      ColorAnimation { duration: theme.animationDuration }
    }

    Text {
      text: row.modelData.name
      textFormat: Text.PlainText
      color: theme.foreground
      font.family: theme.fontFamily
      font.pixelSize: Style.font.bodySmall
      x: root.edgeInset
      width: root.nameColumnWidth
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideMiddle
    }

    Text {
      text: String(row.modelData.pid)
      textFormat: Text.PlainText
      color: theme.muted
      font.family: theme.fontFamily
      font.pixelSize: Style.font.bodySmall
      x: root.pidX
      width: root.pidColumnWidth
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
    }

    Text {
      text: row.modelData.cpu.toFixed(1)
      textFormat: Text.PlainText
      color: root.levelColor(row.modelData.cpu, theme.cpuColor)
      font.family: theme.fontFamily
      font.pixelSize: Style.font.bodySmall
      x: root.cpuX
      width: root.cpuColumnWidth
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight

      Behavior on color {
        ColorAnimation { duration: theme.animationDuration }
      }
    }

    Text {
      text: row.modelData.memory.toFixed(1)
      textFormat: Text.PlainText
      color: root.levelColor(row.modelData.memory, theme.memoryColor)
      font.family: theme.fontFamily
      font.pixelSize: Style.font.bodySmall
      x: root.memoryX
      width: root.memoryColumnWidth
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight

      Behavior on color {
        ColorAnimation { duration: theme.animationDuration }
      }
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (row.selected) root.clearSelection()
        else root.selectProcess(row.modelData.pid, row.modelData.name, row.modelData.startToken)
      }
    }
  }
}
