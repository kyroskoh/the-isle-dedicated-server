"""offsite-backup: copy the newest backup to DEST_DIR and/or run COMMAND, with retention."""
import glob
import os
import shlex
import shutil
import subprocess
import sys
import tempfile

import isle_sdk as isle


def newest_backup():
    """Path of the newest backup on the host (copied out of the container in docker mode)."""
    if isle.runtime() == "docker":
        name = subprocess.check_output(
            ["docker", "exec", "theisle", "sh", "-c", "ls -t /data/backups/theisle-*.tar.gz 2>/dev/null | head -n1"]
        ).decode().strip()
        if not name:
            return None
        local = os.path.join(tempfile.gettempdir(), os.path.basename(name))
        subprocess.check_call(["docker", "cp", "theisle:" + name, local])
        return local
    backup_dir = isle.conf("BACKUP_DIR") or os.path.join(os.path.expanduser("~"), "theisle-backups")
    files = glob.glob(os.path.join(backup_dir, "theisle-*.tar.gz")) + glob.glob(os.path.join(backup_dir, "theisle-*.zip"))
    return max(files, key=os.path.getmtime) if files else None


def main(argv):
    dest, command = isle.setting("DEST_DIR"), isle.setting("COMMAND")
    if not dest and not command:
        isle.log("set DEST_DIR and/or COMMAND first: isle-server plugins config offsite-backup DEST_DIR=...")
        return 0 if os.environ.get("ISLE_EVENT") else 1
    src = newest_backup()
    if not src:
        isle.log("no backup found")
        return 0
    if dest:
        os.makedirs(dest, exist_ok=True)
        shutil.copy2(src, os.path.join(dest, os.path.basename(src)))
        isle.log("copied %s -> %s" % (os.path.basename(src), dest))
        keep = int(isle.setting("KEEP", "14") or 0)
        if keep > 0:
            old = sorted(glob.glob(os.path.join(dest, "theisle-*")), key=os.path.getmtime, reverse=True)[keep:]
            for path in old:
                os.remove(path)
                isle.log("pruned " + os.path.basename(path))
    if command:
        args = [a.replace("{file}", src) for a in shlex.split(command, posix=not sys.platform.startswith("win"))]
        rc = subprocess.call(args)
        isle.log("command exited %s" % rc)
        return rc
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
