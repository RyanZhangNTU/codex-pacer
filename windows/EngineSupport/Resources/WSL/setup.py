import select
import signal
import subprocess

route, home, root = checked_route(sys.argv[1])


def exact(n):
    data = b""
    while len(data) < n:
        part = os.read(0, n - len(data))
        if not part:
            raise SystemExit(2)
        data += part
    return data


digits = b""
while True:
    byte = exact(1)
    if byte == b"\n":
        break
    if not b"0" <= byte <= b"9" or len(digits) >= 7:
        raise SystemExit(2)
    digits += byte
size = int(digits)
if not 0 < size <= 1048576:
    raise SystemExit(2)
command = exact(size).decode("utf-8", errors="strict")
os.environ["HOME"] = str(home)
os.environ["CLAUDE_CONFIG_DIR"] = str(root)
child = subprocess.Popen(["/bin/sh", "-c", command], stdin=subprocess.DEVNULL, start_new_session=True)
try:
    while child.poll() is None:
        readable, _, _ = select.select([0], [], [], 0.2)
        if readable and not os.read(0, 4096):
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            raise SystemExit(2)
    raise SystemExit(child.returncode)
finally:
    if child.poll() is None:
        os.killpg(child.pid, signal.SIGKILL)
