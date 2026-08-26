import QtQuick
import QtQuick.Controls as QQC
import Quickshell.Io
import qs.Commons
import qs.Ui
import "SystemMonitorModel.js" as MonitorModel

Item {
  id: root

  required property QtObject bar
  property bool active: false

  implicitHeight: Style.space(380)
  enabled: active

  SystemMonitorTheme {
    id: theme
    bar: root.bar
  }

  property var cpuInfo: null
  property var memoryInfo: null
  property var osInfo: null
  property var kernelInfo: null
  property var graphicsAdapters: []
  property var nvidiaInfo: null
  property var dmiValues: ({})

  property bool cpuLoading: false
  property bool memoryLoading: false
  property bool osLoading: false
  property bool kernelLoading: false
  property bool graphicsLoading: false
  property bool nvidiaLoading: false
  property int dmiPendingReads: 0
  property int dmiReadFailures: 0
  property bool graphicsFailed: false
  property bool nvidiaAvailabilityKnown: false
  property bool nvidiaCommandAvailable: false

  property bool refreshing: false
  property bool hasCompletedRefresh: false
  property int refreshGeneration: 0
  property int pendingFileReads: 0
  property var pendingProbeKinds: []
  property string probeKind: ""
  property string probeOutput: ""
  property bool probeStreamFinished: false
  property bool probeProcessExited: false
  property bool probeCancelled: false
  property int probeExitCode: -1
  property bool probePipelineComplete: false
  property bool nvidiaAttempted: false

  readonly property bool narrowLayout: width < Style.space(520)
  readonly property bool hasDmiData: {
    for (var key in dmiValues) {
      if (String(dmiValues[key] || "") !== "") return true
    }
    return false
  }
  readonly property bool hasNvidiaAdapter: {
    for (var index = 0; index < graphicsAdapters.length; index++) {
      var adapter = graphicsAdapters[index] || ({})
      var identity = (String(adapter.vendor || "") + " "
        + String(adapter.device || "")).toLowerCase()
      if (identity.indexOf("nvidia") !== -1) return true
    }
    return false
  }
  readonly property string boundedCommandPath: MonitorModel.localFilePath(
    Qt.resolvedUrl("bin/bounded-command"))
  readonly property string headerStatus: refreshing
    ? "COLLECTING" : (hasCompletedRefresh ? "CURRENT" : "WAITING")

  function clean(value) {
    if (value === undefined || value === null) return ""
    return String(value).replace(/^\s+|\s+$/g, "")
  }

  function memoryText(bytes) {
    var value = Number(bytes)
    return isFinite(value) && value > 0 ? MonitorModel.formatBytes(value) : ""
  }

  function vramText(mebibytes) {
    var value = Number(mebibytes)
    if (!isFinite(value) || value <= 0) return ""
    return value >= 1024
      ? (value / 1024).toFixed(1) + " GiB"
      : Math.round(value) + " MiB"
  }

  function cpuTopologyText() {
    if (!cpuInfo) return ""
    var parts = []
    var cores = Number(cpuInfo.physicalCores)
    var threads = Number(cpuInfo.logicalProcessors)
    var sockets = Number(cpuInfo.sockets)
    if (isFinite(cores) && cores > 0)
      parts.push(Math.round(cores) + (Math.round(cores) === 1 ? " core" : " cores"))
    if (isFinite(threads) && threads > 0)
      parts.push(Math.round(threads) + (Math.round(threads) === 1 ? " thread" : " threads"))
    if (isFinite(sockets) && sockets > 1) parts.push(Math.round(sockets) + " sockets")
    return parts.join(" · ")
  }

  function swapText() {
    if (!memoryInfo) return ""
    var total = Number(memoryInfo.swapTotalBytes)
    var free = Number(memoryInfo.swapFreeBytes)
    if (!isFinite(total) || total <= 0) return "Not configured"
    var freeText = memoryText(free)
    return memoryText(total) + (freeText !== "" ? " · " + freeText + " free" : "")
  }

  function osDisplayText() {
    if (!osInfo) return ""
    var pretty = clean(osInfo.prettyName)
    if (pretty !== "") return pretty
    var name = clean(osInfo.name)
    var version = clean(osInfo.versionId)
    return name + (name !== "" && version !== "" ? " " : "") + version
  }

  function buildDisplayText() {
    if (!osInfo) return ""
    return clean(osInfo.buildId) !== "" ? clean(osInfo.buildId) : clean(osInfo.id)
  }

  function graphicsName(adapter) {
    if (!adapter) return "Not reported"
    var vendor = clean(adapter.vendor)
    var device = clean(adapter.device)
    if (device === "") return vendor !== "" ? vendor : "Not reported"
    if (vendor === "" || device.toLowerCase().indexOf(vendor.toLowerCase()) !== -1)
      return device
    return vendor + " · " + device
  }

  function updateDmiValue(key, value) {
    var next = ({})
    for (var existingKey in dmiValues) next[existingKey] = dmiValues[existingKey]
    next[key] = value
    dmiValues = next
  }

  function prepareFile(view) {
    view.awaiting = true
    view.generation = refreshGeneration
  }

  function completeInventoryFile(view, kind, raw, succeeded) {
    if (!active || !view.awaiting || view.generation !== refreshGeneration) return
    view.awaiting = false
    pendingFileReads = Math.max(0, pendingFileReads - 1)
    if (kind === "cpu") {
      cpuLoading = false
      cpuInfo = succeeded ? MonitorModel.parseCpuInfo(raw) : null
    } else if (kind === "memory") {
      memoryLoading = false
      memoryInfo = succeeded ? MonitorModel.parseMemInfo(raw) : null
    } else if (kind === "os") {
      osLoading = false
      osInfo = succeeded ? MonitorModel.parseOsRelease(raw) : null
    } else {
      dmiPendingReads = Math.max(0, dmiPendingReads - 1)
      if (!succeeded) dmiReadFailures++
      updateDmiValue(kind,
        succeeded ? MonitorModel.normalizeHardwareValue(clean(raw)) : "")
    }
    finishRefreshIfReady()
  }

  function completeNvidiaAvailability(succeeded) {
    if (!active || !nvidiaBinaryView.awaiting
        || nvidiaBinaryView.generation !== refreshGeneration) return
    nvidiaBinaryView.awaiting = false
    nvidiaAvailabilityKnown = true
    nvidiaCommandAvailable = succeeded
    if (!succeeded) nvidiaLoading = false
    startNextProbe()
    finishRefreshIfReady()
  }

  function beginRefresh() {
    if (!active || refreshing) return
    if (probeProcess.running || probeKind !== "") return

    refreshGeneration++
    refreshing = true
    pendingFileReads = 9
    dmiPendingReads = 6
    dmiReadFailures = 0
    cpuInfo = null
    memoryInfo = null
    osInfo = null
    kernelInfo = null
    graphicsAdapters = []
    nvidiaInfo = null
    dmiValues = ({})
    cpuLoading = true
    memoryLoading = true
    osLoading = true
    kernelLoading = true
    graphicsLoading = true
    nvidiaLoading = true
    graphicsFailed = false
    nvidiaAvailabilityKnown = false
    nvidiaCommandAvailable = false
    pendingProbeKinds = ["lspci", "uname"]
    probePipelineComplete = false
    nvidiaAttempted = false
    probeCancelled = false

    prepareFile(cpuInfoView)
    prepareFile(memoryInfoView)
    prepareFile(osReleaseView)
    prepareFile(boardVendorView)
    prepareFile(boardNameView)
    prepareFile(boardVersionView)
    prepareFile(biosVendorView)
    prepareFile(biosVersionView)
    prepareFile(biosDateView)
    prepareFile(nvidiaBinaryView)

    var generation = refreshGeneration
    Qt.callLater(function() {
      if (!root.active || generation !== root.refreshGeneration) return
      cpuInfoView.reload()
      memoryInfoView.reload()
      osReleaseView.reload()
      boardVendorView.reload()
      boardNameView.reload()
      boardVersionView.reload()
      biosVendorView.reload()
      biosVersionView.reload()
      biosDateView.reload()
      nvidiaBinaryView.reload()
      root.startNextProbe()
    })
  }

  function deactivate() {
    refreshGeneration++
    refreshing = false
    pendingFileReads = 0
    dmiPendingReads = 0
    cpuInfoView.awaiting = false
    memoryInfoView.awaiting = false
    osReleaseView.awaiting = false
    boardVendorView.awaiting = false
    boardNameView.awaiting = false
    boardVersionView.awaiting = false
    biosVendorView.awaiting = false
    biosVersionView.awaiting = false
    biosDateView.awaiting = false
    nvidiaBinaryView.awaiting = false
    pendingProbeKinds = []
    if (probeKind !== "") {
      probeCancelled = true
      if (probeProcess.running) probeProcess.running = false
    }
  }

  function startNextProbe() {
    if (!active || probeProcess.running || probeKind !== "") return
    if (pendingProbeKinds.length > 0) {
      var kind = pendingProbeKinds[0]
      pendingProbeKinds = pendingProbeKinds.slice(1)
      startProbe(kind)
      return
    }
    if (!nvidiaAvailabilityKnown) return
    if (nvidiaCommandAvailable && !nvidiaAttempted) {
      nvidiaAttempted = true
      startProbe("nvidia")
      return
    }
    probePipelineComplete = true
    finishRefreshIfReady()
  }

  function startProbe(kind) {
    if (!active || probeProcess.running || probeKind !== "") return
    probeKind = kind
    probeOutput = ""
    probeStreamFinished = false
    probeProcessExited = false
    probeExitCode = -1
    probeCancelled = false
    var argv = []
    var limitKind = "nvidiaInfo"
    if (kind === "lspci") {
      argv = ["timeout", "--kill-after=2", "5", "lspci", "-mm", "-D"]
      limitKind = "lspci"
    } else if (kind === "uname") {
      argv = ["timeout", "--kill-after=2", "5", "uname", "-srmo"]
      limitKind = "uname"
    } else {
      argv = [
        "timeout", "--kill-after=3", "10",
        "/usr/bin/nvidia-smi",
        "--query-gpu=name,driver_version,memory.total",
        "--format=csv,noheader,nounits"
      ]
    }
    probeProcess.command = MonitorModel.buildBoundedCommand(
      boundedCommandPath, MonitorModel.commandOutputLimit(limitKind), argv)
    probeProcess.generation = refreshGeneration
    probeProcess.running = true
  }

  function finishProbeIfReady() {
    if (!probeStreamFinished || !probeProcessExited || probeKind === "") return
    var kind = probeKind
    var output = probeOutput
    var exitCode = probeExitCode
    var generation = probeProcess.generation
    var cancelled = probeCancelled
    probeKind = ""
    probeOutput = ""
    probeStreamFinished = false
    probeProcessExited = false
    probeCancelled = false

    if (cancelled || !active || generation !== refreshGeneration) return
    if (kind === "lspci") {
      graphicsLoading = false
      graphicsFailed = exitCode !== 0
      graphicsAdapters = exitCode === 0 ? MonitorModel.parseLspciGraphics(output) : []
    } else if (kind === "uname") {
      kernelLoading = false
      kernelInfo = exitCode === 0 ? MonitorModel.parseKernelInfo(output) : null
    } else {
      nvidiaLoading = false
      nvidiaInfo = exitCode === 0 ? MonitorModel.parseNvidiaHardware(output) : null
    }
    startNextProbe()
  }

  function finishRefreshIfReady() {
    if (!refreshing || pendingFileReads > 0 || !probePipelineComplete) return
    refreshing = false
    hasCompletedRefresh = true
  }

  function scrollBy(amount) {
    inventoryScroll.contentY = Math.max(0, Math.min(
      inventoryScroll.contentHeight - inventoryScroll.height,
      inventoryScroll.contentY + amount))
  }

  onActiveChanged: {
    if (active) {
      Qt.callLater(function() {
        root.forceActiveFocus()
        root.beginRefresh()
      })
    } else {
      deactivate()
    }
  }

  Keys.onPressed: function(event) {
    if (!root.active) return
    if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
      root.scrollBy(-Style.space(36)); event.accepted = true
    } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
      root.scrollBy(Style.space(36)); event.accepted = true
    } else if (event.key === Qt.Key_PageUp) {
      root.scrollBy(-inventoryScroll.height); event.accepted = true
    } else if (event.key === Qt.Key_PageDown) {
      root.scrollBy(inventoryScroll.height); event.accepted = true
    } else if (event.key === Qt.Key_Home) {
      inventoryScroll.contentY = 0; event.accepted = true
    } else if (event.key === Qt.Key_End) {
      inventoryScroll.contentY = Math.max(0,
        inventoryScroll.contentHeight - inventoryScroll.height)
      event.accepted = true
    }
  }

  Process {
    id: probeProcess
    property int generation: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.probeOutput = String(text || "")
        root.probeStreamFinished = true
        root.finishProbeIfReady()
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.probeExitCode = exitCode
      root.probeProcessExited = true
      root.finishProbeIfReady()
    }
  }

  FileView {
    id: cpuInfoView
    property bool awaiting: false
    property int generation: 0
    path: root.active ? "/proc/cpuinfo" : ""
    watchChanges: false; printErrors: false
    onLoaded: root.completeInventoryFile(cpuInfoView, "cpu", text(), true)
    onLoadFailed: root.completeInventoryFile(cpuInfoView, "cpu", "", false)
  }
  FileView {
    id: memoryInfoView
    property bool awaiting: false
    property int generation: 0
    path: root.active ? "/proc/meminfo" : ""
    watchChanges: false; printErrors: false
    onLoaded: root.completeInventoryFile(memoryInfoView, "memory", text(), true)
    onLoadFailed: root.completeInventoryFile(memoryInfoView, "memory", "", false)
  }
  FileView {
    id: osReleaseView
    property bool awaiting: false
    property int generation: 0
    path: root.active ? "/etc/os-release" : ""
    watchChanges: false; printErrors: false
    onLoaded: root.completeInventoryFile(osReleaseView, "os", text(), true)
    onLoadFailed: root.completeInventoryFile(osReleaseView, "os", "", false)
  }
  FileView {
    id: boardVendorView
    property bool awaiting: false
    property int generation: 0
    path: root.active ? "/sys/class/dmi/id/board_vendor" : ""
    watchChanges: false; printErrors: false
    onLoaded: root.completeInventoryFile(boardVendorView, "boardVendor", text(), true)
    onLoadFailed: root.completeInventoryFile(boardVendorView, "boardVendor", "", false)
  }
  FileView {
    id: boardNameView
    property bool awaiting: false
    property int generation: 0
    path: root.active ? "/sys/class/dmi/id/board_name" : ""
    watchChanges: false; printErrors: false
    onLoaded: root.completeInventoryFile(boardNameView, "boardName", text(), true)
    onLoadFailed: root.completeInventoryFile(boardNameView, "boardName", "", false)
  }
  FileView {
    id: boardVersionView
    property bool awaiting: false
    property int generation: 0
    path: root.active ? "/sys/class/dmi/id/board_version" : ""
    watchChanges: false; printErrors: false
    onLoaded: root.completeInventoryFile(boardVersionView, "boardVersion", text(), true)
    onLoadFailed: root.completeInventoryFile(boardVersionView, "boardVersion", "", false)
  }
  FileView {
    id: biosVendorView
    property bool awaiting: false
    property int generation: 0
    path: root.active ? "/sys/class/dmi/id/bios_vendor" : ""
    watchChanges: false; printErrors: false
    onLoaded: root.completeInventoryFile(biosVendorView, "biosVendor", text(), true)
    onLoadFailed: root.completeInventoryFile(biosVendorView, "biosVendor", "", false)
  }
  FileView {
    id: biosVersionView
    property bool awaiting: false
    property int generation: 0
    path: root.active ? "/sys/class/dmi/id/bios_version" : ""
    watchChanges: false; printErrors: false
    onLoaded: root.completeInventoryFile(biosVersionView, "biosVersion", text(), true)
    onLoadFailed: root.completeInventoryFile(biosVersionView, "biosVersion", "", false)
  }
  FileView {
    id: biosDateView
    property bool awaiting: false
    property int generation: 0
    path: root.active ? "/sys/class/dmi/id/bios_date" : ""
    watchChanges: false; printErrors: false
    onLoaded: root.completeInventoryFile(biosDateView, "biosDate", text(), true)
    onLoadFailed: root.completeInventoryFile(biosDateView, "biosDate", "", false)
  }
  FileView {
    id: nvidiaBinaryView
    property bool awaiting: false
    property int generation: 0
    path: root.active ? "/usr/bin/nvidia-smi" : ""
    watchChanges: false; printErrors: false
    onLoaded: root.completeNvidiaAvailability(true)
    onLoadFailed: root.completeNvidiaAvailability(false)
  }

  component LabelValueRow: Item {
    id: valueRow
    required property string labelText
    required property string valueText
    property color valueColor: theme.foreground
    implicitHeight: Style.space(24)
    Accessible.name: labelText + ": " + valueText

    Text {
      id: rowLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(parent.width * 0.38, Style.space(92))
      text: valueRow.labelText
      textFormat: Text.PlainText
      color: theme.muted
      font.family: theme.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
    Text {
      id: rowValue
      anchors.left: rowLabel.right
      anchors.leftMargin: Style.spacing.md
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: valueRow.valueText
      textFormat: Text.PlainText
      color: valueRow.valueColor
      font.family: theme.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
    }
    Rectangle {
      anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
      height: Style.spacing.hairline
      color: theme.cardBorder
    }
    MouseArea {
      id: valueHover
      anchors.fill: parent
      acceptedButtons: Qt.NoButton
      hoverEnabled: true
    }
    PanelToolTip {
      visible: rowValue.truncated && valueHover.containsMouse
      text: valueRow.labelText + ": " + valueRow.valueText
      fontFamily: theme.fontFamily
    }
  }

  component FlatSection: Rectangle {
    id: section
    required property string title
    property color accentColor: theme.accentColor
    default property alias content: sectionBody.data
    implicitHeight: sectionColumn.implicitHeight + Style.spacing.lg * 2
    color: theme.cardFill
    border.width: Style.spacing.hairline
    border.color: theme.cardBorder
    radius: 0
    Rectangle {
      anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
      width: Style.spacing.xs
      color: section.accentColor
    }
    Column {
      id: sectionColumn
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.xl
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.lg
      anchors.top: parent.top
      anchors.topMargin: Style.spacing.lg
      spacing: Style.spacing.xs
      Text {
        width: parent.width
        text: section.title
        textFormat: Text.PlainText
        color: section.accentColor
        font.family: theme.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideRight
      }
      Column { id: sectionBody; width: parent.width; spacing: 0 }
    }
  }

  Flickable {
    id: inventoryScroll
    anchors.fill: parent
    contentWidth: width
    contentHeight: inventoryContent.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height
    QQC.ScrollBar.vertical: QQC.ScrollBar {}

    Column {
      id: inventoryContent
      width: inventoryScroll.width
      spacing: Style.spacing.lg

      Item {
        width: parent.width
        height: Style.space(32)
        Row {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.md
          Rectangle { width: Style.spacing.sm; height: Style.space(20); color: theme.gpuColor }
          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxs
            Text {
              text: "HARDWARE INVENTORY"
              color: theme.foreground
              font.family: theme.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
            Text {
              text: root.headerStatus
              textFormat: Text.PlainText
              color: root.refreshing ? theme.warningColor : theme.muted
              font.family: theme.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }
        }
        PanelActionButton {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰑐"
          tooltipText: root.refreshing ? "Hardware inventory is refreshing" : "Refresh hardware inventory"
          foreground: theme.foreground
          hoverColor: theme.accentColor
          fontFamily: theme.fontFamily
          bordered: true
          enabled: root.active && !root.refreshing
          onClicked: root.beginRefresh()
          Accessible.role: Accessible.Button
          Accessible.name: "Refresh hardware inventory"
        }
      }

      FlatSection {
        width: parent.width
        title: "GRAPHICS"
        accentColor: theme.gpuColor
        LabelValueRow {
          width: parent.width; visible: root.graphicsLoading
          labelText: "Status"; valueText: "Scanning PCI adapters…"; valueColor: theme.muted
        }
        LabelValueRow {
          width: parent.width; visible: !root.graphicsLoading && root.graphicsFailed
          labelText: "PCI inventory"; valueText: "Unavailable"; valueColor: theme.warningColor
        }
        LabelValueRow {
          width: parent.width
          visible: !root.graphicsLoading && !root.graphicsFailed
            && root.graphicsAdapters.length === 0 && !root.nvidiaInfo
          labelText: "Status"; valueText: "No display adapters reported"; valueColor: theme.muted
        }
        Repeater {
          model: root.graphicsAdapters
          delegate: Column {
            required property int index
            required property var modelData
            property var adapter: modelData || ({})
            width: parent.width
            LabelValueRow {
              width: parent.width
              labelText: "GPU " + (parent.index + 1)
              valueText: root.graphicsName(parent.adapter)
              valueColor: theme.gpuColor
            }
            LabelValueRow {
              width: parent.width
              labelText: "Bus"
              valueText: root.clean(parent.adapter.address)
                + (root.clean(parent.adapter.className) !== ""
                  ? " · " + root.clean(parent.adapter.className) : "")
              valueColor: theme.muted
            }
          }
        }
        LabelValueRow {
          width: parent.width; visible: !!root.nvidiaInfo
          labelText: "NVIDIA"; valueText: root.nvidiaInfo ? root.clean(root.nvidiaInfo.name) : ""
          valueColor: theme.gpuColor
        }
        LabelValueRow {
          width: parent.width
          visible: !!root.nvidiaInfo && root.clean(root.nvidiaInfo.driverVersion) !== ""
          labelText: "Driver"; valueText: root.nvidiaInfo ? root.clean(root.nvidiaInfo.driverVersion) : ""
        }
        LabelValueRow {
          width: parent.width
          visible: !!root.nvidiaInfo && root.vramText(root.nvidiaInfo.memoryTotalMiB) !== ""
          labelText: "VRAM"; valueText: root.nvidiaInfo ? root.vramText(root.nvidiaInfo.memoryTotalMiB) : ""
        }
        LabelValueRow {
          width: parent.width; visible: root.hasNvidiaAdapter && root.nvidiaLoading
          labelText: "NVIDIA details"; valueText: "Reading…"; valueColor: theme.muted
        }
        LabelValueRow {
          width: parent.width
          visible: root.hasNvidiaAdapter && !root.nvidiaLoading
            && root.nvidiaAvailabilityKnown && !root.nvidiaInfo
          labelText: "NVIDIA details"; valueText: "Unavailable"; valueColor: theme.warningColor
        }
      }

      Grid {
        id: cpuMemoryGrid
        width: parent.width
        columns: root.narrowLayout ? 1 : 2
        columnSpacing: Style.spacing.lg
        rowSpacing: Style.spacing.lg
        readonly property real sectionHeight: Math.max(
          cpuSection.implicitHeight, memorySection.implicitHeight)
        FlatSection {
          id: cpuSection
          height: root.narrowLayout ? implicitHeight : cpuMemoryGrid.sectionHeight
          width: root.narrowLayout ? cpuMemoryGrid.width
            : Math.floor((cpuMemoryGrid.width - cpuMemoryGrid.columnSpacing) / 2)
          title: "PROCESSOR"
          accentColor: theme.cpuColor
          LabelValueRow {
            width: parent.width; visible: root.cpuLoading
            labelText: "Status"; valueText: "Reading processor…"; valueColor: theme.muted
          }
          LabelValueRow {
            width: parent.width; visible: !root.cpuLoading && !root.cpuInfo
            labelText: "Status"; valueText: "Processor inventory unavailable"; valueColor: theme.warningColor
          }
          LabelValueRow {
            width: parent.width; visible: !root.cpuLoading && !!root.cpuInfo
            labelText: "Model"
            valueText: root.cpuInfo && root.clean(root.cpuInfo.model) !== ""
              ? root.clean(root.cpuInfo.model) : "Not reported"
            valueColor: theme.cpuColor
          }
          LabelValueRow {
            width: parent.width; visible: !!root.cpuInfo && root.clean(root.cpuInfo.vendor) !== ""
            labelText: "Vendor"; valueText: root.cpuInfo ? root.clean(root.cpuInfo.vendor) : ""
          }
          LabelValueRow {
            width: parent.width; visible: !!root.cpuInfo && root.cpuTopologyText() !== ""
            labelText: "Topology"; valueText: root.cpuTopologyText()
          }
          LabelValueRow {
            width: parent.width; visible: !!root.cpuInfo && root.clean(root.cpuInfo.cache) !== ""
            labelText: "Cache"; valueText: root.cpuInfo ? root.clean(root.cpuInfo.cache) : ""
          }
        }
        FlatSection {
          id: memorySection
          height: root.narrowLayout ? implicitHeight : cpuMemoryGrid.sectionHeight
          width: root.narrowLayout ? cpuMemoryGrid.width
            : Math.floor((cpuMemoryGrid.width - cpuMemoryGrid.columnSpacing) / 2)
          title: "MEMORY"
          accentColor: theme.memoryColor
          LabelValueRow {
            width: parent.width; visible: root.memoryLoading
            labelText: "Status"; valueText: "Reading memory…"; valueColor: theme.muted
          }
          LabelValueRow {
            width: parent.width; visible: !root.memoryLoading && !root.memoryInfo
            labelText: "Status"; valueText: "Memory inventory unavailable"; valueColor: theme.warningColor
          }
          LabelValueRow {
            width: parent.width; visible: !!root.memoryInfo
            labelText: "Installed"
            valueText: root.memoryInfo && root.memoryText(root.memoryInfo.totalBytes) !== ""
              ? root.memoryText(root.memoryInfo.totalBytes) : "Not reported"
            valueColor: theme.memoryColor
          }
          LabelValueRow {
            width: parent.width
            visible: !!root.memoryInfo && root.memoryText(root.memoryInfo.availableBytes) !== ""
            labelText: "Available"
            valueText: root.memoryInfo ? root.memoryText(root.memoryInfo.availableBytes) : ""
          }
          LabelValueRow {
            width: parent.width; visible: !!root.memoryInfo
            labelText: "Swap"; valueText: root.swapText()
          }
        }
      }

      Grid {
        id: platformGrid
        width: parent.width
        columns: root.narrowLayout ? 1 : 2
        columnSpacing: Style.spacing.lg
        rowSpacing: Style.spacing.lg
        readonly property real sectionHeight: Math.max(
          motherboardSection.implicitHeight, systemSection.implicitHeight)
        FlatSection {
          id: motherboardSection
          height: root.narrowLayout ? implicitHeight : platformGrid.sectionHeight
          width: root.narrowLayout ? platformGrid.width
            : Math.floor((platformGrid.width - platformGrid.columnSpacing) / 2)
          title: "MOTHERBOARD / BIOS"
          accentColor: theme.loadColor
          LabelValueRow {
            width: parent.width; visible: root.dmiPendingReads > 0
            labelText: "Status"; valueText: "Reading firmware tables…"; valueColor: theme.muted
          }
          LabelValueRow {
            width: parent.width; visible: root.dmiPendingReads === 0 && !root.hasDmiData
            labelText: "Status"
            valueText: root.dmiReadFailures >= 6 ? "DMI inventory unavailable" : "Not exposed by firmware"
            valueColor: theme.warningColor
          }
          LabelValueRow {
            width: parent.width; visible: root.dmiPendingReads === 0 && root.hasDmiData
            labelText: "Model"
            valueText: root.clean(root.dmiValues.boardName) !== ""
              ? root.clean(root.dmiValues.boardName) : "Not reported"
            valueColor: theme.loadColor
          }
          LabelValueRow {
            width: parent.width; visible: root.clean(root.dmiValues.boardVendor) !== ""
            labelText: "Manufacturer"; valueText: root.clean(root.dmiValues.boardVendor)
          }
          LabelValueRow {
            width: parent.width; visible: root.clean(root.dmiValues.boardVersion) !== ""
            labelText: "Revision"; valueText: root.clean(root.dmiValues.boardVersion)
          }
          LabelValueRow {
            width: parent.width
            visible: root.clean(root.dmiValues.biosVersion) !== ""
              || root.clean(root.dmiValues.biosVendor) !== ""
            labelText: "BIOS"
            valueText: root.clean(root.dmiValues.biosVersion) !== ""
              ? root.clean(root.dmiValues.biosVersion)
                + (root.clean(root.dmiValues.biosVendor) !== ""
                  ? " · " + root.clean(root.dmiValues.biosVendor) : "")
              : root.clean(root.dmiValues.biosVendor)
          }
          LabelValueRow {
            width: parent.width; visible: root.clean(root.dmiValues.biosDate) !== ""
            labelText: "BIOS date"; valueText: root.clean(root.dmiValues.biosDate)
          }
        }
        FlatSection {
          id: systemSection
          height: root.narrowLayout ? implicitHeight : platformGrid.sectionHeight
          width: root.narrowLayout ? platformGrid.width
            : Math.floor((platformGrid.width - platformGrid.columnSpacing) / 2)
          title: "SYSTEM / KERNEL"
          accentColor: theme.uptimeColor
          LabelValueRow {
            width: parent.width; visible: root.osLoading || root.kernelLoading
            labelText: "Status"; valueText: "Reading system metadata…"; valueColor: theme.muted
          }
          LabelValueRow {
            width: parent.width; visible: !root.osLoading
            labelText: "OS"
            valueText: root.osDisplayText() !== "" ? root.osDisplayText() : "OS metadata unavailable"
            valueColor: root.osInfo ? theme.uptimeColor : theme.warningColor
          }
          LabelValueRow {
            width: parent.width; visible: !root.kernelLoading
            labelText: "Kernel"
            valueText: root.kernelInfo && root.clean(root.kernelInfo.kernel) !== ""
              ? root.clean(root.kernelInfo.kernel) : "Kernel metadata unavailable"
            valueColor: root.kernelInfo ? theme.foreground : theme.warningColor
          }
          LabelValueRow {
            width: parent.width
            visible: !!root.kernelInfo && root.clean(root.kernelInfo.architecture) !== ""
            labelText: "Architecture"
            valueText: root.kernelInfo ? root.clean(root.kernelInfo.architecture) : ""
          }
          LabelValueRow {
            width: parent.width; visible: !!root.osInfo && root.buildDisplayText() !== ""
            labelText: "Build"; valueText: root.buildDisplayText()
          }
          LabelValueRow {
            width: parent.width
            visible: !!root.kernelInfo && root.clean(root.kernelInfo.full) !== ""
              && root.clean(root.kernelInfo.full) !== root.clean(root.kernelInfo.kernel)
            labelText: "Kernel details"
            valueText: root.kernelInfo ? root.clean(root.kernelInfo.full) : ""
          }
        }
      }
    }
  }
}
