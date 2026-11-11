"""welcome-announcer: RCON announcement after start (the hook returns at once and waits in the background)."""
import sys
import time

import isle_sdk as isle


def announce():
    text = isle.setting("MESSAGE", "Welcome!").replace("{name}", isle.conf("SERVER_NAME", "the server"))
    try:
        isle.rcon("announce", text)
    except Exception as exc:
        isle.log("announce failed: %s (is the server running with RCON enabled?)" % exc)
        return 1
    isle.log("announced: " + text)
    return 0


def main(argv):
    mode = argv[0] if argv else "run"
    if mode == "post-start":          # hook: do not block the launcher
        isle.detach(["delayed"])
        return 0
    if mode == "delayed":
        time.sleep(int(isle.setting("DELAY_SECONDS", "180") or 0))
    return announce()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
