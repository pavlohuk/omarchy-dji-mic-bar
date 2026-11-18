import QtQuick
import qs.Commons
import qs.Commons as Commons

// Bar mark: a microphone with four dots beside it that double as a battery
// gauge for the weakest transmitter. Drawn from rectangles so it stays crisp
// in a tiny bar slot.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Commons.Color.foreground
  property int dots: 0          // lit dots, 0-4
  property bool crossed: false  // receiver present but unusable

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real stroke: Math.max(1.5, iconSize * 0.1)
  readonly property real dotSize: Math.max(2, iconSize * 0.15)
  readonly property real micCenter: iconSize * 0.64
  readonly property real arcSize: iconSize * 0.56

  Repeater {
    model: 4
    Rectangle {
      required property int index
      x: 0
      y: index * (root.iconSize - root.dotSize) / 3
      width: root.dotSize
      height: root.dotSize
      radius: width / 2
      color: root.color
      // Dots fill from the bottom, like a level meter.
      opacity: (3 - index) < root.dots ? 1.0 : 0.28
    }
  }

  // Capsule
  Rectangle {
    x: root.micCenter - width / 2
    y: 0
    width: root.iconSize * 0.3
    height: root.iconSize * 0.56
    radius: width / 2
    color: root.color
  }

  // Holder: the lower half of a ring
  Item {
    x: root.micCenter - root.arcSize / 2
    y: root.iconSize * 0.36
    width: root.arcSize
    height: root.arcSize * 0.62
    clip: true

    Rectangle {
      y: parent.height - height
      width: root.arcSize
      height: root.arcSize
      radius: width / 2
      color: "transparent"
      border.width: root.stroke
      border.color: root.color
    }
  }

  // Stem and foot
  Rectangle {
    x: root.micCenter - width / 2
    y: root.iconSize * 0.36 + root.arcSize * 0.62 - root.stroke / 2
    width: root.stroke
    height: root.iconSize - y
    color: root.color
  }

  Rectangle {
    x: root.micCenter - width / 2
    y: root.iconSize - height
    width: root.iconSize * 0.34
    height: root.stroke
    radius: height / 2
    color: root.color
  }

  Rectangle {
    visible: root.crossed
    anchors.centerIn: parent
    width: parent.width * 1.2
    height: root.stroke
    radius: height / 2
    rotation: 45
    color: root.color
  }
}
