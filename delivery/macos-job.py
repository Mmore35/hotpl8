"""Finite POSIX job guardian. No provider output leaves the containment boundary.

The parent owns a control pipe. Its death closes that pipe, so the guardian kills
its private process group, even when launchd stops the parent abruptly. The work
inherits this group and must not daemonize. A final SIGKILL includes the guardian;
the group ID cannot be reused before cleanup. Result JSON is flushed first.
"""
import json
import os
import selectors
import signal
import subprocess
import sys
import time


def guardian(arguments, seconds, limit):
    if os.name == "nt" or os.getpgrp() != os.getpid():
        raise SystemExit("Guardian requires its own POSIX session")
    # No work starts until its supervising parent confirms admission.
    if sys.stdin.buffer.read(1) != b"G":
        return
    state, code, count = "error", None, 0
    child = None
    canceled = False

    def cancel(*_):
        nonlocal canceled
        canceled = True

    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    deadline = time.monotonic() + seconds
    try:
        child = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, close_fds=True)
        with selectors.DefaultSelector() as selector:
            selector.register(sys.stdin.fileno(), selectors.EVENT_READ, "control")
            selector.register(child.stdout, selectors.EVENT_READ, "output")
            while True:
                if canceled:
                    state = "canceled"
                    break
                if time.monotonic() >= deadline:
                    state = "timeout"
                    break
                code = child.poll()
                if code is not None:
                    state = "complete" if code == 0 else "failed"
                    break
                for key, _ in selector.select(min(.1, max(0, deadline - time.monotonic()))):
                    data = os.read(key.fd, 65536)
                    if key.data == "control" and not data:
                        canceled = True
                    elif key.data == "output":
                        if not data:
                            selector.unregister(key.fd)
                        count += len(data)
                        if count > limit:
                            state = "output-limit"
                            break
                if state == "output-limit":
                    break
    finally:
        result = dict(state=state, exitCode=code, outputBytes=count)
        try:
            sys.stdout.write(json.dumps(result) + "\n")
            sys.stdout.flush()
        except BrokenPipeError:
            pass
        # Includes all non-daemonizing descendants and this session leader.
        os.killpg(os.getpid(), signal.SIGKILL)


def execute(arguments, seconds=540, limit=4 * 1024 * 1024):
    if os.name == "nt":
        raise RuntimeError("POSIX jobs require macOS")
    child = subprocess.Popen([sys.executable, __file__, str(seconds), str(limit), *arguments],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             start_new_session=True, close_fds=True)
    try:
        child.stdin.write(b"G")
        child.stdin.flush()
        # Keep stdin open while waiting: EOF is an explicit parent-death signal.
        child.wait(timeout=seconds + 10)
        result = json.loads(child.stdout.read(4096))
        if child.returncode != -signal.SIGKILL:
            raise RuntimeError("Guardian cleanup was not confirmed")
        return result
    except (subprocess.TimeoutExpired, ValueError, OSError, RuntimeError):
        # Only our at-creation session/group is targeted; never a discovered PID.
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
        child.wait(timeout=5)
        return dict(state="guardian-error", exitCode=None)
    finally:
        try:
            child.stdin.close()
        except BrokenPipeError:
            pass
        child.stdout.close()


if __name__ == "__main__":
    guardian(sys.argv[3:], float(sys.argv[1]), int(sys.argv[2]))
