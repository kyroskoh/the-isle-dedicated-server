"""discord-notify: lifecycle events -> Discord webhook."""
import json
import os
import sys
import urllib.request

import isle_sdk as isle

TEXT = {
    "post-start": ":green_circle: **{name}** is starting",
    "pre-stop": ":yellow_circle: **{name}** is shutting down",
    "post-stop": ":red_circle: **{name}** stopped",
    "post-backup": ":floppy_disk: **{name}** backup finished",
    "post-update": ":arrows_counterclockwise: **{name}** game files updated",
    "test": ":white_check_mark: Test message from **{name}**",
}


def post(text):
    url = isle.setting("DISCORD_WEBHOOK_URL")
    if not url:
        isle.log("DISCORD_WEBHOOK_URL is not set - nothing sent")
        return 0 if os.environ.get("ISLE_EVENT") else 1
    body = json.dumps({"username": isle.setting("USERNAME", "The Isle Server"), "content": text}).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json",
                                                          "User-Agent": "theisle-server-plugins/1"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        isle.log("posted to Discord (HTTP %s)" % resp.status)
    return 0


def main(argv):
    event = argv[0] if argv else "test"
    wanted = [e.strip() for e in isle.setting("EVENTS", "").split(",") if e.strip()]
    if event != "test" and wanted and event not in wanted:
        return 0
    name = isle.conf("SERVER_NAME", "The Isle server")
    return post(TEXT.get(event, event).format(name=name))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
