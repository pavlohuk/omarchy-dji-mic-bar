import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// DJI Mic Mini receiver in the bar. A helper process owns the USB side and
// streams the decoded state as JSON lines; setting changes go back over its
// stdin. The widget only takes up bar space while the receiver is plugged in.
Panel {
  id: root
  moduleName: "huk.dji-mic"
  ipcTarget: "huk.dji-mic"

  // Everything except the live input level, which updates ten times a second
  // and lives in `levels` so it does not rebuild the whole panel.
  property var dev: ({ present: false, error: "", hasStatus: false, legacy: false, rx: {}, tx: [] })
  property var levels: ({})
  property string devKey: ""

  property bool showDetails: false
  property bool cursorActive: false
  property int cursorRow: 0
  property int cursorCol: 0

  readonly property bool present: dev.present === true
  readonly property bool usable: present && dev.error === "" && dev.hasStatus === true
  readonly property var transmitters: usable && dev.tx ? dev.tx : []
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar && bar.urgent ? bar.urgent : Commons.Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string helperPath: Qt.resolvedUrl("dji-mic-helper.py").toString().replace(/^file:\/\//, "")

  // Lit dots follow the weakest transmitter. Raw gauge: 1 full … 7 critical.
  readonly property int batteryDots: {
    var worst = 0
    for (var i = 0; i < transmitters.length; i++)
      if (transmitters[i].battery > worst) worst = transmitters[i].battery
    if (worst === 1) return 4
    if (worst === 2) return 3
    if (worst === 3) return 2
    if (worst === 4 || worst === 5) return 1
    return 0
  }

  // Keyboard cursor grid: one row of tones and one of toggles per
  // transmitter, then the receiver row.
  readonly property var grid: {
    var rows = []
    for (var i = 0; i < transmitters.length; i++) {
      var u = transmitters[i].unit
      rows.push(["tone:" + u + ":normal", "tone:" + u + ":rich", "tone:" + u + ":bright"])
      rows.push(["lowCut:" + u, "leds:" + u, "autoOff:" + u])
    }
    if (usable) rows.push(["limiter", "mono", "stereo"])
    return rows
  }
  readonly property string cursorId: {
    if (!cursorActive || cursorRow >= grid.length) return ""
    var row = grid[cursorRow]
    return row[Math.min(cursorCol, row.length - 1)]
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function handleLine(line) {
    var next
    try { next = JSON.parse(line) } catch (e) { return }
    if (!next || typeof next !== "object" || !Array.isArray(next.tx)) return
    var nextLevels = {}
    for (var i = 0; i < next.tx.length; i++) {
      nextLevels[next.tx[i].unit] = Number(next.tx[i].level) || 0
      next.tx[i].level = 0
    }
    levels = nextLevels
    var key = JSON.stringify(next)
    if (key === devKey) return
    devKey = key
    dev = next
  }

  function send(command) {
    if (helper.running) helper.write("set " + command + "\n")
  }

  function txByUnit(unit) {
    for (var i = 0; i < transmitters.length; i++)
      if (transmitters[i].unit === unit) return transmitters[i]
    return null
  }

  function activate(id) {
    var parts = String(id).split(":")
    var tx = parts.length > 1 ? txByUnit(Number(parts[1])) : null
    if (parts[0] === "tone" && tx) send("voiceTone " + tx.unit + " " + parts[2])
    else if (parts[0] === "lowCut" && tx) send("lowCut " + (tx.lowCut ? 0 : 1))
    else if (parts[0] === "leds" && tx) send("micLEDs " + (tx.ledsOn ? 0 : 1))
    else if (parts[0] === "autoOff" && tx) send("txAutoOff " + (tx.autoOff ? 0 : 1))
    else if (parts[0] === "limiter") send("clipLimiter " + (dev.rx.clipLimiter ? 0 : 1))
    else if (parts[0] === "mono") send("stereo 0")
    else if (parts[0] === "stereo") send("stereo 1")
  }

  function moveCursor(dx, dy) {
    if (grid.length === 0) return
    if (!cursorActive) { cursorActive = true; cursorRow = 0; cursorCol = 0; return }
    var row = Math.max(0, Math.min(grid.length - 1, cursorRow + dy))
    var col = Math.max(0, Math.min(grid[row].length - 1, cursorCol + dx))
    cursorRow = row
    cursorCol = col
  }

  function hover(id) {
    for (var r = 0; r < grid.length; r++) {
      var c = grid[r].indexOf(id)
      if (c >= 0) { cursorActive = true; cursorRow = r; cursorCol = c; return }
    }
  }

  function batteryGlyph(tx) {
    if (tx.charging) return "\u{f0084}"
    if (tx.battery === 1) return "\u{f0079}"
    if (tx.battery === 2) return "\u{f0080}"
    if (tx.battery === 3) return "\u{f007e}"
    if (tx.battery === 4 || tx.battery === 5) return "\u{f007c}"
    if (tx.battery === 6) return "\u{f007a}"
    return "\u{f0083}"
  }

  function batteryText(tx) {
    return tx.charging ? strings.t("charging") : strings.t("battery." + (tx.battery >= 0 && tx.battery <= 7 ? tx.battery : 0))
  }

  onOpenedChanged: if (opened) { cursorActive = false; showDetails = false }
  onPresentChanged: if (!present) close()

  visible: present
  implicitWidth: present ? button.implicitWidth : 0
  implicitHeight: present ? button.implicitHeight : 0

  Process {
    id: helper
    command: ["python3", root.helperPath]
    running: true
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
    onExited: {
      root.handleLine('{"present":false,"error":"","hasStatus":false,"legacy":false,"rx":{},"tx":[]}')
      restart.start()
    }
  }

  Timer { id: restart; interval: 3000; onTriggered: helper.running = true }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: ""
    iconComponent: Component {
      Item {
        MicIcon {
          x: (parent.width - width) / 2
          y: (parent.height - height) / 2
          iconSize: button.iconSize
          color: root.barForeground
          dots: root.batteryDots
          crossed: root.dev.error !== ""
          opacity: root.transmitters.length > 0 || root.dev.error !== "" ? 1.0 : 0.6
        }
      }
    }
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.present
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: if (root.cursorId !== "") root.activate(root.cursorId)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t, modifiers) { if (t === "i" || t === "I") root.showDetails = !root.showDetails }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- States without a usable status stream ----------
        Placeholder {
          visible: root.dev.error !== ""
          glyph: "\u{f036d}"
          title: strings.t("error.title")
          detail: root.dev.error === "permission" ? strings.t("error.permission")
            : root.dev.error === "busy" ? strings.t("error.busy") : String(root.dev.error)
        }

        Placeholder {
          visible: root.dev.error === "" && !root.dev.hasStatus
          glyph: "\u{f036c}"
          title: root.dev.legacy ? strings.t("legacy.title") : strings.t("reading.title")
          detail: root.dev.legacy ? strings.t("legacy.detail") : ""
        }

        Placeholder {
          visible: root.usable && root.transmitters.length === 0
          glyph: "\u{f036c}"
          title: strings.t("noTx.title")
          detail: strings.t("noTx.detail")
        }

        // ---------- Transmitters ----------
        Repeater {
          model: root.transmitters

          Column {
            id: txSection
            required property var modelData
            readonly property var tx: modelData
            readonly property real level: Math.max(0, Math.min(1, (root.levels[tx.unit] || 0) / 80))
            width: column.width
            spacing: Style.space(12)

            Hero {
              image: Qt.resolvedUrl(txSection.tx.name === "DJI Mic Mini 2" ? "assets/mic-mini-2-tx.png" : "assets/mic-mini-tx.png")
              title: txSection.tx.name || strings.t("transmitter").arg(txSection.tx.unit)
              statusGlyph: root.batteryGlyph(txSection.tx)
              statusUrgent: !txSection.tx.charging && txSection.tx.battery >= 6
              status: root.batteryText(txSection.tx) + " · TX" + txSection.tx.unit
            }

            Details {
              visible: root.showDetails
              firmware: txSection.tx.firmware
              serial: txSection.tx.serial
            }

            // Live input level
            Item {
              width: parent.width
              implicitHeight: Style.space(6)

              Rectangle {
                id: levelTrack
                anchors.fill: parent
                radius: height / 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
              }

              Rectangle {
                anchors.left: levelTrack.left
                anchors.verticalCenter: levelTrack.verticalCenter
                height: levelTrack.height
                radius: levelTrack.radius
                color: txSection.level > 0.85 ? root.urgent : root.foreground
                width: Math.max(levelTrack.height, levelTrack.width * txSection.level)
                Behavior on width { NumberAnimation { duration: Style.duration(100); easing.type: Easing.Linear } }
              }
            }

            // Display only: the Mic Mini 2 ignores noise-cancel commands over USB.
            InfoPair {
              label: strings.t("noiseCancel")
              value: root.dev.rx.ncEnabled ? (root.dev.rx.ncStrong ? strings.t("nc.high") : strings.t("nc.low")) : strings.t("nc.off")
            }

            Column {
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                text: strings.t("voiceTone")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Row {
                width: parent.width
                spacing: Style.space(6)

                Repeater {
                  model: ["normal", "rich", "bright"]
                  Chip {
                    required property string modelData
                    chipId: "tone:" + txSection.tx.unit + ":" + modelData
                    text: strings.t("tone." + modelData)
                    active: txSection.tx.voiceTone === modelData
                  }
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              Chip {
                chipId: "lowCut:" + txSection.tx.unit
                iconText: "\u{f0236}"
                text: strings.t("lowCut")
                active: txSection.tx.lowCut === true
              }
              Chip {
                chipId: "leds:" + txSection.tx.unit
                iconText: txSection.tx.ledsOn ? "\u{f0335}" : "\u{f0e4f}"
                text: strings.t("leds")
                active: txSection.tx.ledsOn === true
              }
              Chip {
                chipId: "autoOff:" + txSection.tx.unit
                iconText: "\u{f051b}"
                text: strings.t("autoOff")
                tooltipText: strings.t("autoOff.hint")
                active: txSection.tx.autoOff === true
              }
            }

            PanelSeparator { foreground: root.foreground }
          }
        }

        // ---------- Receiver ----------
        Column {
          visible: root.usable
          width: parent.width
          spacing: Style.space(12)

          Hero {
            image: Qt.resolvedUrl("assets/mic-mini-usb-rx.png")
            title: strings.t("receiver")
            status: strings.t("viaUsb")
          }

          Details {
            visible: root.showDetails
            firmware: root.dev.rx.firmware || ""
            serial: root.dev.rx.serial || ""
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Chip {
              chipId: "limiter"
              iconText: "\u{f147d}"
              text: strings.t("limiter")
              tooltipText: strings.t("limiter.hint")
              active: root.dev.rx.clipLimiter === true
            }
            Chip {
              chipId: "mono"
              iconText: "\u{f04c3}"
              text: strings.t("mono")
              active: root.dev.rx.stereo !== true
            }
            Chip {
              chipId: "stereo"
              iconText: "\u{f0d38}"
              text: strings.t("stereo")
              active: root.dev.rx.stereo === true
            }
          }
        }
      }
    }
  }

  // ---------- Pieces ----------

  FontMetrics {
    id: chipMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  // One of three equal cells in a row of settings.
  component Chip: Button {
    property string chipId: ""
    width: parent ? (parent.width - parent.spacing * 2) / 3 : implicitWidth
    // Icon chips would otherwise stand taller than the text-only tone chips.
    height: Math.ceil(chipMetrics.height) + verticalPadding * 2 + Style.space(2)
    iconSize: Style.font.title
    fontSize: Style.font.bodySmall
    foreground: root.foreground
    fontFamily: root.fontFamily
    horizontalPadding: Style.space(6)
    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
    bordered: true
    hasCursor: root.cursorId !== "" && root.cursorId === chipId
    onClicked: root.activate(chipId)
    onHovered: function(h) { if (h) root.hover(chipId) }
  }

  component Hero: Item {
    property url image: ""
    property string title: ""
    property string status: ""
    property string statusGlyph: ""
    property bool statusUrgent: false

    width: parent ? parent.width : 0
    implicitHeight: Math.max(art.height, labels.implicitHeight)

    Image {
      id: art
      source: parent.image
      width: Style.space(32)
      height: Style.space(32)
      sourceSize.width: 160
      sourceSize.height: 160
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Column {
      id: labels
      anchors.left: art.right
      anchors.leftMargin: Style.space(12)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      PlainText {
        text: parent.parent.title
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
        width: parent.width
      }

      Row {
        spacing: Style.space(5)

        PlainText {
          visible: text !== ""
          text: labels.parent.statusGlyph
          color: labels.parent.statusUrgent ? root.urgent : Qt.darker(root.foreground, 1.4)
          font.pixelSize: Style.font.body
          anchors.verticalCenter: parent.verticalCenter
        }

        PlainText {
          text: labels.parent.status.toUpperCase()
          color: Qt.darker(root.foreground, 1.4)
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
  }

  component Details: Column {
    property string firmware: ""
    property string serial: ""
    width: parent ? parent.width : 0
    spacing: Style.spacing.labelGap
    InfoPair { label: strings.t("firmware"); value: parent.firmware || "—" }
    InfoPair { label: strings.t("serial"); value: parent.serial || "—" }
  }

  component InfoPair: Item {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : 0
    implicitHeight: Math.max(pairLabel.implicitHeight, pairValue.implicitHeight)

    PlainText { id: pairLabel; text: parent.label; opacity: 0.6; anchors.left: parent.left }
    PlainText {
      id: pairValue
      text: parent.value
      anchors.right: parent.right
      anchors.left: pairLabel.right
      anchors.leftMargin: Style.space(8)
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
    }
  }

  component Placeholder: Column {
    property string glyph: ""
    property string title: ""
    property string detail: ""
    width: parent ? parent.width : 0
    spacing: Style.space(6)
    topPadding: Style.space(8)
    bottomPadding: Style.space(8)

    PlainText {
      text: parent.glyph
      font.pixelSize: Style.font.display
      opacity: 0.6
      anchors.horizontalCenter: parent.horizontalCenter
    }
    PlainText {
      text: parent.title
      font.pixelSize: Style.font.subtitle
      font.bold: true
      anchors.horizontalCenter: parent.horizontalCenter
    }
    PlainText {
      visible: text !== ""
      text: parent.detail
      opacity: 0.6
      width: parent.width
      wrapMode: Text.WordWrap
      horizontalAlignment: Text.AlignHCenter
    }
  }
}
