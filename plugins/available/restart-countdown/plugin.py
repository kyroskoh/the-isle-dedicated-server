"""restart-countdown: RCON countdown announcements, save, restart."""
import sys
import time

import isle_sdk as isle


def announce(text):
    try:
        isle.rcon("announce", text)
        isle.log("announced: " + text)
    except Exception as exc:  # the restart must still happen if RCON is down
        isle.log("announce failed (%s) - continuing" % exc)


def main(argv):
    marks = sorted({int(x) for x in isle.setting("WARNINGS", "15,10,5,1").split(",") if x.strip().isdigit()}, reverse=True)
    total = int(argv[1]) if len(argv) > 1 and argv[1].isdigit() else (marks[0] if marks else 0)
    marks = [m for m in marks if m <= total] or [total]
    message = isle.setting("MESSAGE", "Server restart in {minutes} minute(s)")
    remaining = total
    for mark in marks:
        if remaining > mark:
            time.sleep((remaining - mark) * 60)
            remaining = mark
        if mark > 0:
            announce(message.replace("{minutes}", str(mark)))
    if remaining > 0:
        time.sleep(remaining * 60)
    announce(isle.setting("FINAL_MESSAGE", "Restarting now."))
    try:
        isle.rcon("save")
    except Exception as exc:
        isle.log("save failed (%s) - the launcher saves again on stop" % exc)
    time.sleep(5)
    isle.log("restarting the server")
    return isle.launcher("restart")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
