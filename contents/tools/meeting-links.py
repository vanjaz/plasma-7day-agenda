#!/usr/bin/env python3
"""Print a JSON map of {event title: video meeting link}.

The Plasma calendar API used by the widget does not expose meeting links, so
this helper reads them from the local Akonadi calendar store (read-only):
the Google Meet link that KDE's Google connector saves with each event, or a
Meet / Zoom / Teams / Webex link found in the event's location or description.
Nothing leaves this machine.
"""
import json
import os
import re
import sqlite3
import sys

BASE = os.path.expanduser("~/.local/share/akonadi")
DB = os.path.join(BASE, "akonadi.db")
FILES = os.path.join(BASE, "file_db_data")

LINK = re.compile(
    r"https://(?:meet\.google\.com/[a-z0-9-]+"
    r"|[\w.-]*zoom\.us/(?:j|my|w)/[^\s\"'<>\\]+"
    r"|teams\.microsoft\.com/l/meetup-join/[^\s\"'<>\\]+"
    r"|teams\.live\.com/meet/[^\s\"'<>\\]+"
    r"|[\w.-]*webex\.com/(?:meet|join|[\w.-]+/j\.php)[^\s\"'<>\\]*)",
    re.IGNORECASE,
)


def unescape(value):
    return (value.replace("\\n", "\n").replace("\\N", "\n")
                 .replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\"))


def external_files():
    index = {}
    for root, _dirs, names in os.walk(FILES):
        for name in names:
            index[name] = os.path.join(root, name)
    return index


def parse(ical):
    """Return (title, link) for the first event in an iCalendar payload."""
    text = re.sub(r"\r?\n[ \t]", "", ical)   # unfold continuation lines
    start = text.find("BEGIN:VEVENT")
    if start < 0:
        return None, None
    title, hangout, others = None, None, []
    for line in text[start:].splitlines():
        if line.startswith("END:VEVENT"):
            break
        name, _, value = line.partition(":")
        key = name.split(";", 1)[0].upper()
        if key == "SUMMARY":
            title = unescape(value).strip()
        elif key == "X-KDE-LIBKGAPI-EVENTHANGOUTLINK":
            hangout = value.strip()
        elif key in ("LOCATION", "DESCRIPTION", "URL", "X-GOOGLE-CONFERENCE"):
            match = LINK.search(unescape(value))
            if match:
                others.append(match.group(0))
    return title, hangout or (others[0] if others else None)


def main():
    links = {}
    try:
        db = sqlite3.connect("file:" + DB + "?mode=ro", uri=True, timeout=2)
        rows = db.execute(
            "SELECT p.data, p.storage FROM PartTable p"
            " JOIN PartTypeTable t ON t.id = p.partTypeId"
            " JOIN PimItemTable i ON i.id = p.pimItemId"
            " JOIN MimeTypeTable m ON m.id = i.mimeTypeId"
            " WHERE t.ns = 'PLD' AND t.name = 'RFC822'"
            " AND m.name = 'application/x-vnd.akonadi.calendar.event'"
            " ORDER BY i.datetime"          # later items win for a repeated title
        ).fetchall()
    except sqlite3.Error as error:
        print(json.dumps({}))
        print(error, file=sys.stderr)
        return
    files = None
    for data, storage in rows:
        if data is None:
            continue
        if isinstance(data, str):
            data = data.encode()
        if storage == 1:
            if files is None:
                files = external_files()
            path = files.get(os.path.basename(data.decode(errors="ignore")))
            if not path:
                continue
            try:
                with open(path, "rb") as handle:
                    data = handle.read()
            except OSError:
                continue
        title, link = parse(data.decode("utf-8", errors="ignore"))
        if title and link:
            links[title] = link
    print(json.dumps(links))


if __name__ == "__main__":
    main()
