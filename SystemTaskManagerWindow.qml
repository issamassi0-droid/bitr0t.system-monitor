import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
  id: root

  property QtObject bar: null
  readonly property bool opened: window.visible

  readonly property string windowTitle: "System Task Manager"
  readonly property int preferredWindowWidth: 1100
  readonly property int preferredWindowHeight: 720
  readonly property int minimumWindowWidth: 760
  readonly property int minimumWindowHeight: 480
  readonly property int activationAttemptLimit: 8
  readonly property int activationRetryInterval: 75
  readonly property color windowBackground:
    theme.flatColorToken("window-background", Color.background)

  property int activationAttempt: 0

  SystemMonitorTheme {
    id: theme
    bar: root.bar
  }

  function normalizedIdentity(value) {
    return String(value || "").toLowerCase().replace(/[^a-z0-9]+/g, "")
  }

  function matchingToplevel() {
    var values = []
    try {
      values = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    } catch (error) {
      return null
    }

    var wanted = normalizedIdentity(root.windowTitle)
    for (var index = 0; index < values.length; index++) {
      var candidate = values[index]
      if (!candidate) continue

      var titleMatches = String(candidate.title || "") === root.windowTitle
      var appId = normalizedIdentity(candidate.appId)
      var appIdMatches = appId === wanted
        || (appId.length > wanted.length
          && appId.lastIndexOf(wanted) === appId.length - wanted.length)
      if (titleMatches || appIdMatches) return candidate
    }
    return null
  }

  function activateMatchingToplevel() {
    var candidate = matchingToplevel()
    if (!candidate) return false

    try {
      if (candidate.minimized) candidate.minimized = false
      candidate.activate()
      return true
    } catch (error) {
      return false
    }
  }

  function cancelActivationRetries() {
    activationRetry.stop()
    activationAttempt = 0
  }

  function tryActivation() {
    if (!window.visible) {
      cancelActivationRetries()
      return false
    }

    if (window.minimized) window.minimized = false
    activationAttempt = activationAttempt + 1
    var activated = activateMatchingToplevel()
    if (activationAttempt < activationAttemptLimit) activationRetry.restart()
    return activated
  }

  function startActivationCycle() {
    cancelActivationRetries()
    tryActivation()
  }

  function open() {
    var alreadyVisible = window.visible
    window.visible = true
    if (window.minimized) window.minimized = false

    if (alreadyVisible) {
      focusScope.forceActiveFocus()
      startActivationCycle()
      return
    }

    // The Wayland toplevel appears after the backing window is shown. Defer
    // once, then let the short retry timer cover that bounded registration
    // gap without ever creating or searching for another window instance.
    Qt.callLater(function() {
      if (!window.visible) return
      focusScope.forceActiveFocus()
      root.startActivationCycle()
    })
  }

  function close() {
    cancelActivationRetries()
    window.visible = false
  }

  function focusWindow() {
    if (!window.visible) {
      open()
      return
    }
    focusScope.forceActiveFocus()
    startActivationCycle()
  }

  function openBtop() {
    if (root.bar && typeof root.bar.run === "function")
      root.bar.run("omarchy-launch-or-focus-tui btop")
    root.close()
  }

  Timer {
    id: activationRetry
    interval: root.activationRetryInterval
    repeat: false
    onTriggered: root.tryActivation()
  }

  FloatingWindow {
    id: window

    title: root.windowTitle
    visible: false
    color: root.windowBackground
    implicitWidth: root.preferredWindowWidth
    implicitHeight: root.preferredWindowHeight
    minimumSize: Qt.size(root.minimumWindowWidth, root.minimumWindowHeight)

    onClosed: root.close()
    onVisibleChanged: {
      if (!visible) root.cancelActivationRetries()
    }
    onMinimizedChanged: {
      if (minimized) root.cancelActivationRetries()
    }

    FocusScope {
      id: focusScope

      anchors.fill: parent
      focus: window.visible

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (processView.handleKey(event)) {
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Escape
            || (event.key === Qt.Key_W
              && (event.modifiers & Qt.ControlModifier))) {
          root.close()
          event.accepted = true
        } else if (event.key === Qt.Key_F5) {
          processView.refresh()
          event.accepted = true
        }
      }

      Rectangle {
        anchors.fill: parent
        color: root.windowBackground

        Rectangle {
          id: header

          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          height: Style.space(52)
          color: theme.cardFill

          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            cursorShape: window.maximized ? Qt.ArrowCursor : Qt.SizeAllCursor
            onPressed: {
              if (!window.maximized)
                window.startSystemMove()
            }
            onDoubleClicked: window.maximized = !window.maximized
          }

          Rectangle {
            id: titleAccent

            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.panelPadding
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(2)
            height: Style.space(30)
            color: theme.cpuColor
          }

          Column {
            anchors.left: titleAccent.right
            anchors.leftMargin: Style.spacing.xxl
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.panelPadding
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs

            Text {
              width: parent.width
              text: root.windowTitle
              color: theme.foreground
              font.family: theme.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Row {
              width: parent.width
              spacing: Style.spacing.md

              Rectangle {
                width: Style.space(6)
                height: width
                radius: width / 2
                anchors.verticalCenter: parent.verticalCenter
                color: theme.uploadColor
              }

              Text {
                width: parent.width - Style.space(6) - parent.spacing
                text: "Live processes · refreshes every 2 seconds"
                color: theme.muted
                font.family: theme.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }


          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.spacing.hairline
            color: theme.cardBorder
          }
        }

        SystemProcessView {
          id: processView

          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: header.bottom
          anchors.bottom: parent.bottom
          anchors.margins: Style.spacing.panelPadding
          bar: root.bar
          active: window.visible && !window.minimized
          fullViewAvailable: false
          onOpenBtopRequested: root.openBtop()
        }
      }
    }
  }

}
