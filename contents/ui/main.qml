// 7-Day Agenda: a small date icon in the panel whose popup shows a month grid
// with, below it, the events for the selected day and the 7 days after it
// (today by default). Events with a video meeting link get a Join button.
//
// Events come from the same plugins as the digital clock's calendar: PIM
// events (the accounts added in KOrganizer) and public holidays.

import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.ksvg as KSvg
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support
import org.kde.plasma.workspace.calendar as PlasmaCalendar

PlasmoidItem {
    id: root

    readonly property int daysAhead: 7
    property date today: new Date()
    property date startDate: today     // first day listed; set by clicking the grid
    readonly property bool startsToday: startDate.toDateString() === today.toDateString()
    property var rows: []              // flat list: day headers and events
    property int eventCount: 0
    property var meetingLinks: ({})    // event title -> video meeting URL
    // First day of the week (QML numbering: 0 = Sunday ... 6 = Saturday).
    // Taken from KOrganizer's "Weekly start day" setting, else the locale.
    property int firstDay: Qt.locale().firstDayOfWeek

    toolTipMainText: Qt.formatDate(today, "dddd, d MMMM yyyy")
    toolTipSubText: i18n("Click for the next %1 days", daysAhead)

    PlasmaCalendar.EventPluginsManager {
        id: pluginsManager
        enabledPlugins: ["pimevents", "holidaysevents"]
    }

    // Two month-sized windows (the start date's month and the one after) so
    // the listed days are always covered, even at the very end of a month.
    PlasmaCalendar.Calendar {
        id: calThis
        days: 7
        weeks: 6
        firstDayOfWeek: root.firstDay
        today: root.today
        Component.onCompleted: daysModel.setPluginsManager(pluginsManager)
    }
    PlasmaCalendar.Calendar {
        id: calNext
        days: 7
        weeks: 6
        firstDayOfWeek: root.firstDay
        today: root.today
        Component.onCompleted: daysModel.setPluginsManager(pluginsManager)
    }

    function pointBackends() {
        const next = new Date(startDate.getFullYear(), startDate.getMonth() + 1, 1);
        calThis.goToYearAndMonth(startDate.getFullYear(), startDate.getMonth() + 1);
        calNext.goToYearAndMonth(next.getFullYear(), next.getMonth() + 1);
        rebuildTimer.restart();
    }
    onStartDateChanged: pointBackends()

    Connections {
        target: calThis.daysModel
        function onAgendaUpdated() { rebuildTimer.restart(); }
    }
    Connections {
        target: calNext.daysModel
        function onAgendaUpdated() { rebuildTimer.restart(); }
    }

    // Meeting links are not part of the calendar API, so a small helper reads
    // them from the local calendar store and prints {title: url} as JSON.
    P5Support.DataSource {
        id: linkHelper
        engine: "executable"
        readonly property string command: "python3 -I '" + Qt.resolvedUrl("../tools/meeting-links.py").toString().replace(/^file:\/\//, "") + "'"
        function refresh() {
            if (connectedSources.length === 0) {
                connectSource(command);
            }
        }
        onNewData: (source, data) => {
            disconnectSource(source);
            try {
                root.meetingLinks = JSON.parse(data["stdout"] || "{}");
            } catch (e) {
                root.meetingLinks = {};
            }
            rebuildTimer.restart();
        }
    }

    // Reads KOrganizer's week start. KOrganizer stores it as 0 = Monday ...
    // 6 = Sunday; an empty result means it is unset, so the locale applies.
    P5Support.DataSource {
        id: weekStartReader
        engine: "executable"
        readonly property string command: "kreadconfig6 --file korganizerrc --group 'Time & Date' --key WeekStartDay"
        function refresh() {
            if (connectedSources.length === 0) {
                connectSource(command);
            }
        }
        onNewData: (source, data) => {
            disconnectSource(source);
            const value = parseInt((data["stdout"] || "").trim(), 10);
            root.firstDay = (value >= 0 && value <= 6) ? (value + 1) % 7 : Qt.locale().firstDayOfWeek;
        }
    }

    // Many updates arrive in bursts while calendars load; rebuild once after.
    Timer {
        id: rebuildTimer
        interval: 300
        onTriggered: root.rebuild()
    }

    // Notice when the date rolls over.
    Timer {
        interval: 60 * 1000
        running: true
        repeat: true
        onTriggered: {
            const now = new Date();
            if (now.toDateString() !== root.today.toDateString()) {
                const followToday = root.startsToday;
                root.today = now;
                if (followToday) {
                    root.startDate = now;
                }
            }
            rebuildTimer.restart();
        }
    }

    Timer {
        interval: 10 * 60 * 1000
        running: true
        repeat: true
        onTriggered: linkHelper.refresh()
    }

    onExpandedChanged: {
        if (root.expanded) {
            root.startDate = root.today;   // always open on today
            rebuild();
            linkHelper.refresh();
            weekStartReader.refresh();
        }
    }
    Component.onCompleted: {
        pointBackends();
        linkHelper.refresh();
        weekStartReader.refresh();
    }

    function dayLabel(date) {
        const text = Qt.formatDate(date, "dddd, d MMMM");
        const diff = Math.round((new Date(date.getFullYear(), date.getMonth(), date.getDate())
                               - new Date(today.getFullYear(), today.getMonth(), today.getDate())) / 86400000);
        if (diff === 0) {
            return i18n("Today · %1", text);
        }
        if (diff === 1) {
            return i18n("Tomorrow · %1", text);
        }
        return text;
    }

    function timeLabel(ev, day) {
        if (ev.isAllDay) {
            return i18n("All day");
        }
        const fmt = Qt.locale().timeFormat(Locale.ShortFormat);
        const sameDay = d => d.toDateString() === day.toDateString();
        const start = sameDay(ev.startDateTime) ? Qt.formatTime(ev.startDateTime, fmt) : "…";
        const end = sameDay(ev.endDateTime) ? Qt.formatTime(ev.endDateTime, fmt) : "…";
        return start === end ? start : start + " – " + end;
    }

    function rebuild() {
        const out = [];
        let count = 0;
        for (let offset = 0; offset <= daysAhead; ++offset) {
            const day = new Date(startDate.getFullYear(), startDate.getMonth(), startDate.getDate() + offset);
            const seen = {};
            const events = [];
            [calThis.daysModel, calNext.daysModel].forEach(model => {
                const list = model.eventsForDate(day);
                for (let i = 0; i < list.length; ++i) {
                    const ev = list[i];
                    const key = ev.title + "|" + ev.startDateTime + "|" + ev.endDateTime;
                    if (!seen[key]) {
                        seen[key] = true;
                        events.push({
                            title: ev.title,
                            time: timeLabel(ev, day),
                            allDay: ev.isAllDay,
                            start: ev.startDateTime.getTime(),
                            color: ev.eventColor || "",
                            minor: ev.isMinor,
                            link: meetingLinks[ev.title] || ""
                        });
                    }
                }
            });
            if (events.length === 0) {
                continue;   // days without events are not listed
            }
            events.sort((a, b) => (a.allDay === b.allDay) ? a.start - b.start : (a.allDay ? -1 : 1));
            out.push({ kind: "day", label: dayLabel(day), isToday: day.toDateString() === today.toDateString() });
            events.forEach(e => out.push(Object.assign({ kind: "event" }, e)));
            count += events.length;
        }
        rows = out;
        eventCount = count;
    }

    // Panel item: the time with the date under it, like the digital clock.
    property date now: new Date()
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: {
            const t = new Date();
            if (t.getMinutes() !== root.now.getMinutes() || t.getHours() !== root.now.getHours()) {
                root.now = t;
            }
        }
    }

    compactRepresentation: MouseArea {
        id: compact

        Layout.minimumWidth: clockColumn.implicitWidth + Kirigami.Units.smallSpacing * 2
        Layout.preferredWidth: Layout.minimumWidth
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded

        Column {
            id: clockColumn
            anchors.centerIn: parent
            spacing: 0

            PlasmaComponents.Label {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Qt.formatTime(root.now, Qt.locale().timeFormat(Locale.ShortFormat))
                font.pixelSize: Math.max(9, Math.round(compact.height * 0.60))
                lineHeight: 0.95
            }
            PlasmaComponents.Label {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Qt.formatDate(root.now, Qt.locale().dateFormat(Locale.ShortFormat))
                font.pixelSize: Math.max(8, Math.round(compact.height * 0.52))
                opacity: 0.9
                lineHeight: 0.95
            }
        }
    }

    fullRepresentation: PlasmaExtras.Representation {
        id: full

        Layout.minimumWidth: Kirigami.Units.gridUnit * 24
        Layout.minimumHeight: Kirigami.Units.gridUnit * 34
        Layout.preferredWidth: Kirigami.Units.gridUnit * 26
        Layout.preferredHeight: Kirigami.Units.gridUnit * 40
        collapseMarginsHint: true

        // Re-open on the current month with today selected.
        Connections {
            target: root
            function onExpandedChanged() {
                if (root.expanded) {
                    monthView.resetToToday();
                    monthView.currentDate = root.today;
                }
            }
        }

        contentItem: ColumnLayout {
            spacing: 0

            PlasmaCalendar.MonthView {
                id: monthView
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 21
                Layout.margins: Kirigami.Units.smallSpacing

                today: root.today
                currentDate: root.today
                firstDayOfWeek: root.firstDay
                eventPluginsManager: pluginsManager
                borderOpacity: 0

                onCurrentDateChanged: {
                    if (!isNaN(currentDate.getTime())) {
                        root.startDate = currentDate;
                    }
                }
            }

            KSvg.SvgItem {
                Layout.fillWidth: true
                imagePath: "widgets/line"
                elementId: "horizontal-line"
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                Layout.bottomMargin: 0
                Kirigami.Heading {
                    Layout.fillWidth: true
                    level: 4
                    elide: Text.ElideRight
                    text: root.startsToday ? i18n("Next %1 days", root.daysAhead)
                                           : i18n("%1 days from %2", root.daysAhead, Qt.formatDate(root.startDate, "d MMM"))
                }
                PlasmaComponents.Label {
                    opacity: 0.7
                    text: root.eventCount === 0 ? i18n("No events") : i18np("%1 event", "%1 events", root.eventCount)
                }
            }

            PlasmaComponents.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                PlasmaComponents.ScrollBar.horizontal.policy: PlasmaComponents.ScrollBar.AlwaysOff

                ListView {
                    id: list
                    clip: true
                    model: root.rows
                    topMargin: Kirigami.Units.smallSpacing
                    bottomMargin: Kirigami.Units.largeSpacing

                    PlasmaExtras.PlaceholderMessage {
                        anchors.centerIn: parent
                        width: parent.width - Kirigami.Units.gridUnit * 4
                        visible: root.rows.length === 0
                        text: i18n("Nothing scheduled")
                    }

                    delegate: Item {
                        id: row
                        required property var modelData
                        readonly property bool isDay: modelData.kind === "day"

                        width: ListView.view ? ListView.view.width : 0
                        height: (isDay ? dayHeader.implicitHeight : eventRow.implicitHeight) + Kirigami.Units.smallSpacing * 2

                        // Day header
                        PlasmaComponents.Label {
                            id: dayHeader
                            visible: row.isDay
                            anchors {
                                left: parent.left
                                right: parent.right
                                bottom: parent.bottom
                                leftMargin: Kirigami.Units.largeSpacing
                                rightMargin: Kirigami.Units.largeSpacing
                                bottomMargin: Kirigami.Units.smallSpacing
                            }
                            text: row.isDay ? row.modelData.label : ""
                            font.bold: true
                            color: row.isDay && row.modelData.isToday ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                            elide: Text.ElideRight
                        }

                        // Event
                        RowLayout {
                            id: eventRow
                            visible: !row.isDay
                            spacing: Kirigami.Units.largeSpacing
                            anchors {
                                left: parent.left
                                right: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: Kirigami.Units.largeSpacing * 2
                                rightMargin: Kirigami.Units.largeSpacing
                            }
                            Rectangle {
                                Layout.preferredWidth: 4
                                Layout.fillHeight: true
                                Layout.minimumHeight: Kirigami.Units.gridUnit
                                radius: 2
                                color: !row.isDay && row.modelData.color ? row.modelData.color : Kirigami.Theme.highlightColor
                            }
                            PlasmaComponents.Label {
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 6
                                text: row.isDay ? "" : row.modelData.time
                                opacity: 0.75
                                font: Kirigami.Theme.smallFont
                            }
                            PlasmaComponents.Label {
                                Layout.fillWidth: true
                                text: row.isDay ? "" : row.modelData.title
                                opacity: !row.isDay && row.modelData.minor ? 0.6 : 1
                                wrapMode: Text.Wrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                            }
                            PlasmaComponents.ToolButton {
                                visible: !row.isDay && !!row.modelData.link
                                icon.name: "camera-video"
                                text: i18n("Join")
                                display: PlasmaComponents.AbstractButton.TextBesideIcon
                                onClicked: {
                                    Qt.openUrlExternally(row.modelData.link);
                                    root.expanded = false;
                                }
                                PlasmaComponents.ToolTip {
                                    text: row.isDay ? "" : (row.modelData.link || "")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
