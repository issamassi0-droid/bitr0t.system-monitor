// Runtime smoke harness for the bitr0t.system-monitor plugin.
//
// tests/run-runtime-smoke assembles a throwaway Quickshell config that
// symlinks /usr/share/omarchy/shell/{Ui,Commons} plus this plugin, then runs
// this file as the config root. It instantiates the production views
// inactive — fake bar, fake host widget, no panel opened, task window never
// mapped — evaluates their public bindings and APIs, and prints
// SYSTEM_MONITOR_RUNTIME_SMOKE_PASS only when everything holds.
//
// A stale import, missing required property, invalid binding or type, or a
// broken public API either fails instantiation (no PASS marker, quickshell
// logs the QML error) or trips an explicit check below.
//
// Nothing here talks to the live shell over IPC, moves the pointer, takes
// focus, kills a user process, or writes outside the temp config. Production
// views stay inactive; one isolated bounded-command probe intentionally
// overflows by one byte to verify that no partial output reaches QML.

import QtQuick
import Quickshell
import Quickshell.Io

import "plugin" as Plugin

ShellRoot {
  id: root

  // ---- fakes ---------------------------------------------------------------

  // Stand-in for the host Bar the live shell injects. Carries the surface
  // the theme and views actually read; run()/moduleWidgets() exist so a
  // stray call fails loudly instead of on undefined.
  component FakeBar: QtObject {
    property bool vertical: false
    property int barSize: 32
    property string position: "top"
    property color foreground: "#f4f6f8"
    property color barForeground: foreground
    property color urgent: "#ff5577"
    property bool foregroundAnimationEnabled: false
    property string fontFamily: "smoke-monospace"
    property bool transparent: false
    property var runLog: []

    function run(command) {
      runLog.push(String(command))
    }

    function moduleWidgets(moduleName) {
      return []
    }

    function switchPanelFrom(instance, direction) {
      return false
    }
  }

  // Stand-in for the BarWidget that hosts the panel views: the metric
  // bindings the Performance tab reads, the sensor surfaces the Settings
  // tab reads, and the chip-settings mutation API it must route to. Every
  // routed call is recorded so wiring can be asserted without touching
  // persistent settings.
  component FakeHost: QtObject {
    property string chipMode: "instrument"
    property var chipMonitors: ["cpu", "memory", "network"]
    property int cpuUsage: 42
    property int memoryUsage: 63
    property real receiveRate: 1.25
    property real transmitRate: 0.5
    property real loadOne: 0.75
    property real loadFive: 0.5
    property real loadFifteen: 0.25
    property real uptimeSeconds: 86400
    property var cpuHistory: [4, 8, 15, 16]
    property var memoryHistory: [23, 42]
    property var receiveHistory: [0.5, 1.25]
    property var transmitHistory: [0.25, 0.5]
    property var selectedSensorReadings: []
    property var unavailableSelectedSensors: []
    property var availableSensors: []
    property var temperatureSensors: []
    property var fanSensors: []
    property bool sensorsLoading: false
    property var calls: []

    function setChipMode(mode) {
      calls.push("setChipMode:" + mode)
      chipMode = String(mode)
    }

    function setMonitorEnabled(id, enabled) {
      calls.push("setMonitorEnabled:" + id + ":" + (enabled ? "on" : "off"))
      var next = chipMonitors.slice()
      var at = next.indexOf(id)
      if (enabled && at < 0) next.push(id)
      if (!enabled && at >= 0) next.splice(at, 1)
      chipMonitors = next
    }

    function monitorEnabled(id) {
      return chipMonitors.indexOf(id) >= 0
    }

    function resetChipSettings() {
      calls.push("resetChipSettings")
    }

    function sensorHistory(id) {
      return []
    }

    function wasCalled(signature) {
      return calls.indexOf(signature) >= 0
    }
  }

  FakeBar {
    id: fakeBar
  }

  FakeHost {
    id: fakeHost
  }

  // ---- factories -------------------------------------------------------------

  // Components are instantiated on demand with fake bar/host injected and
  // active: false, instead of being declared visible in the scene.
  Component {
    id: themeFactory
    Plugin.SystemMonitorTheme {}
  }

  Component {
    id: barWidgetFactory
    Plugin.BarWidget {}
  }

  Component {
    id: performanceFactory
    Plugin.SystemPerformanceView {
      active: false
    }
  }

  Component {
    id: processFactory
    Plugin.SystemProcessView {
      active: false
    }
  }

  Component {
    id: infoFactory
    Plugin.SystemInfoView {
      active: false
    }
  }

  Component {
    id: settingsFactory
    Plugin.SystemMonitorSettingsView {
      active: false
    }
  }

  Component {
    id: taskWindowFactory
    Plugin.SystemTaskManagerWindow {}
  }

  property bool failed: false
  property var created: []
  property var taskWindowInstance: null

  function fail(message) {
    if (failed)
      return
    failed = true
    console.error("SYSTEM_MONITOR_RUNTIME_SMOKE_FAIL: " + message)
  }

  function check(condition, message) {
    if (!failed && !condition)
      fail(message)
  }

  property bool staticSmokeComplete: false
  property bool boundedOverflowComplete: false
  property bool boundedOverflowStreamFinished: false
  property bool boundedOverflowProcessExited: false
  property int boundedOverflowExitCode: -1
  property string boundedOverflowOutput: ""

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0)
      value = value.substring(7)
    return decodeURIComponent(value)
  }

  function maybePass() {
    if (staticSmokeComplete && boundedOverflowComplete && !failed)
      console.log("SYSTEM_MONITOR_RUNTIME_SMOKE_PASS")
  }

  function finishBoundedOverflowSmoke() {
    if (!boundedOverflowStreamFinished || !boundedOverflowProcessExited)
      return
    check(boundedOverflowExitCode === 74,
      "bounded-command overflow must exit 74")
    check(boundedOverflowOutput === "",
      "bounded-command overflow leaked partial output to StdioCollector")
    boundedOverflowComplete = true
    maybePass()
  }

  Process {
    id: boundedOverflowProcess
    running: false
    command: [
      root.localPath(Qt.resolvedUrl("plugin/bin/bounded-command")),
      "4",
      "/usr/bin/printf",
      "%s",
      "abcde"
    ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.boundedOverflowOutput = String(text || "")
        root.boundedOverflowStreamFinished = true
        root.finishBoundedOverflowSmoke()
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.boundedOverflowExitCode = exitCode
      root.boundedOverflowProcessExited = true
      root.finishBoundedOverflowSmoke()
    }
  }

  function make(factory, label, props) {
    var object = null
    try {
      object = factory.createObject(null, props || ({}))
    } catch (error) {
      fail(label + " threw during instantiation: " + error)
      return null
    }
    if (!object) {
      fail(label + " failed to instantiate")
      return null
    }
    created.push(object)
    return object
  }

  // ---- assertions ---------------------------------------------------------

  function smokeTheme() {
    var theme = make(themeFactory, "SystemMonitorTheme", {
      "bar": fakeBar
    })
    if (!theme)
      return
    check(Qt.colorEqual(theme.foreground, fakeBar.foreground),
      "theme.foreground does not track the bar foreground")
    check(theme.fontFamily === fakeBar.fontFamily,
      "theme.fontFamily does not track the bar font")
    check(theme.monitorGap > 0, "theme.monitorGap did not resolve")
    check(theme.animationDuration >= 0, "theme.animationDuration did not resolve")
  }

  function smokeSensorTransaction() {
    var widget = make(barWidgetFactory, "BarWidget", {
      "bar": fakeBar,
      "settings": ({
        "chipMode": "instrument",
        "monitors": ["cpu", "memory", "network"]
      })
    })
    if (!widget)
      return
    check(widget.boundedCommandPath.indexOf("/bin/bounded-command") > 0,
      "bar probes did not resolve the bounded producer")

    var firstOutput = "{\"k10temp-pci-00c3\":{\"Adapter\":\"PCI adapter\","
      + "\"Tctl\":{\"temp1_input\":42,\"temp1_max\":90,\"temp1_crit\":100}}}"

    // Stream completion first: no sensor publication until process exit.
    widget.pendingSensorsOutput = firstOutput
    widget.sensorExitCode = 0
    widget.sensorStreamFinished = true
    widget.sensorProcessExited = false
    widget.finishSensorsIfReady()
    check(widget.availableSensors.length === 0,
      "sensor transaction published before process exit")
    widget.sensorProcessExited = true
    widget.finishSensorsIfReady()
    check(widget.availableSensors.length === 1
      && widget.availableSensors[0].value === 42
      && widget.sensorsStale === false,
      "sensor transaction did not publish after stream+exit completion")

    // Exit first: stale state remains until the matching stream completes.
    widget.markSensorsStale()
    widget.pendingSensorsOutput = ""
    widget.sensorExitCode = 0
    widget.sensorStreamFinished = false
    widget.sensorProcessExited = true
    widget.finishSensorsIfReady()
    check(widget.availableSensors.length === 0 && widget.sensorsStale === true,
      "sensor transaction published before stream completion")
    widget.pendingSensorsOutput = firstOutput.replace("42", "43")
    widget.sensorStreamFinished = true
    widget.finishSensorsIfReady()
    check(widget.availableSensors.length === 1
      && widget.availableSensors[0].value === 43
      && widget.sensorsStale === false,
      "sensor transaction did not publish after exit+stream completion")
  }

  function smokePerformance() {
    var view = make(performanceFactory, "SystemPerformanceView", {
      "hostWidget": fakeHost,
      "bar": fakeBar
    })
    if (!view)
      return
    check(view.boundedCommandPath.indexOf("/bin/bounded-command") > 0,
      "performance probes did not resolve the bounded producer")
    check(view.cpuUsage === 42, "performance cpuUsage must bind to the host")
    check(view.memoryUsage === 63, "performance memoryUsage must bind to the host")
    check(view.uptimeSeconds === 86400, "performance uptimeSeconds must bind to the host")
    check(view.cpuHistory.length === 4, "performance cpuHistory must bind to the host")
    check(view.loadOne === 0.75, "performance loadOne must bind to the host")
    check(view.hasSelectedSensors === false,
      "sensor cards must resolve with no sensors selected")
    check(isFinite(view.networkScale), "networkScale must resolve")

    var diskOutput = "Filesystem 1B-blocks Used Available Use% Mounted on\n"
      + "/dev/test 1000 250 750 25% /"

    // Stream completion first: transaction must not publish until exit lands.
    view.probeKind = "disk"
    view.probeOutput = diskOutput
    view.probeExitCode = 0
    view.probeCancelled = false
    view.probeStreamFinished = true
    view.probeProcessExited = false
    view.finishProbeIfReady()
    check(view.probeKind === "disk" && view.diskAvailable === false,
      "disk probe published before process exit")
    view.probeProcessExited = true
    view.finishProbeIfReady()
    check(view.probeKind === "" && view.diskAvailable === true
      && view.diskUsedPercent === 25,
      "disk probe did not publish after stream+exit completion")

    // Exit first: same transaction must wait for the stream and publish once.
    view.diskAvailable = false
    view.probeKind = "disk"
    view.probeOutput = diskOutput
    view.probeExitCode = 0
    view.probeCancelled = false
    view.probeStreamFinished = false
    view.probeProcessExited = true
    view.finishProbeIfReady()
    check(view.probeKind === "disk" && view.diskAvailable === false,
      "disk probe published before stream completion")
    view.probeStreamFinished = true
    view.finishProbeIfReady()
    check(view.probeKind === "" && view.diskAvailable === true,
      "disk probe did not publish after exit+stream completion")

    // Cancellation must clear the transaction without publishing stale data.
    view.diskAvailable = false
    view.probeKind = "disk"
    view.probeOutput = diskOutput
    view.probeExitCode = 0
    view.probeCancelled = true
    view.probeStreamFinished = true
    view.probeProcessExited = true
    view.finishProbeIfReady()
    check(view.probeKind === "" && view.diskAvailable === false
      && view.probeCancelled === false,
      "cancelled disk probe published or failed to reset")
  }

  function smokeProcess() {
    var view = make(processFactory, "SystemProcessView", {
      "bar": fakeBar
    })
    if (!view)
      return
    check(view.active === false, "process view must stay inactive")
    check(view.boundedCommandPath.indexOf("/bin/bounded-command") > 0,
      "process probes did not resolve the bounded producer")
    check(view.sortKey === "cpu" && view.sortDescending === true,
      "process view default sort must be cpu descending")
    check(view.visibleProcesses.length === 0,
      "visibleProcesses must resolve against the empty snapshot")
    check(view.summaryText.indexOf("sorted by CPU descending") >= 0,
      "summaryText must reflect the default sort")
    check(view.placeholderText === "Collecting processes…",
      "placeholderText must report the unloaded state")
    check(view.query === "", "query must bind to the untouched search field")

    view.chooseSort("name")
    check(view.sortKey === "name", "chooseSort(name) must switch the sort key")
    check(view.sortDescending === false, "chooseSort(name) must start ascending")
    check(view.summaryText.indexOf("sorted by name ascending") >= 0,
      "summaryText must follow the name sort")

    view.chooseSort("name")
    check(view.sortDescending === true,
      "chooseSort(name) twice must toggle the direction")

    view.chooseSort("cpu")
    check(view.sortKey === "cpu", "chooseSort(cpu) must switch the key back")
    check(view.sortDescending === true, "chooseSort(cpu) must reset to descending")

    view.chooseSort("cpu")
    check(view.sortDescending === false,
      "chooseSort(cpu) twice must toggle the direction")
    check(view.active === false, "process view must remain inactive after sorting")

    var firstSnapshot = "123 Mon Aug 25 12:00:01 2026 5.0 1.0 demo"
    var reusedSnapshot = "123 Tue Aug 26 12:00:01 2026 5.0 1.0 replacement"
    view.applyProcesses(firstSnapshot)
    check(view.processes.length === 1
      && view.processes[0].startToken === "Mon Aug 25 12:00:01 2026",
      "process snapshot did not retain its birth token")
    view.selectProcess(123, "demo", view.processes[0].startToken)
    check(view.selectedPid === 123, "process selection did not bind")
    view.applyProcesses(reusedSnapshot)
    check(view.selectedPid === -1,
      "reused PID with a changed birth token retained selection")
  }

  function smokeSettings() {
    var view = make(settingsFactory, "SystemMonitorSettingsView", {
      "hostWidget": fakeHost,
      "bar": fakeBar
    })
    if (!view)
      return
    check(view.chipMode === "instrument", "settings chipMode must bind to the host")

    view.chooseChipMode("minimal")
    check(fakeHost.wasCalled("setChipMode:minimal"),
      "chooseChipMode must route to hostWidget.setChipMode")
    check(view.chipMode === "minimal", "chipMode binding must follow the host")

    check(view.monitorEnabled("memory") === true,
      "monitorEnabled must read the host monitors")
    view.setMonitorEnabled("cpu", false)
    check(fakeHost.wasCalled("setMonitorEnabled:cpu:off"),
      "setMonitorEnabled must route to hostWidget.setMonitorEnabled")
    check(view.monitorEnabled("cpu") === false,
      "monitorEnabled must reflect the disabled monitor")

    view.resetChipSettings()
    check(fakeHost.wasCalled("resetChipSettings"),
      "resetChipSettings must route to hostWidget.resetChipSettings")
  }

  function smokeInfo() {
    var view = make(infoFactory, "SystemInfoView", {
      "bar": fakeBar
    })
    if (!view)
      return
    check(view.boundedCommandPath.indexOf("/bin/bounded-command") > 0,
      "info probes did not resolve the bounded producer")
    check(view.implicitHeight > 0, "info view must resolve its layout")
    check(view.active === false, "info view must stay inactive")
  }

  function smokeTaskWindow() {
    var view = make(taskWindowFactory, "SystemTaskManagerWindow", {
      "bar": fakeBar
    })
    if (!view)
      return
    taskWindowInstance = view
    check(view.opened === false, "task window must start closed")
    check(view.windowTitle === "System Task Manager",
      "task window title must resolve")
  }

  Component.onCompleted: {
    smokeTheme()
    smokeSensorTransaction()
    smokePerformance()
    smokeProcess()
    smokeSettings()
    smokeInfo()
    smokeTaskWindow()
    check(!taskWindowInstance || taskWindowInstance.opened === false,
      "task window must still be closed at the end of the run")
    staticSmokeComplete = true
    boundedOverflowProcess.running = true
    maybePass()
  }
}
