#!/usr/bin/env python3
"""Exercise Direct write/quit regressions in isolated Neovim processes."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import time


REPO = Path(__file__).resolve().parents[2]
WORKER = REPO / "tests" / "e2e" / "write_quit_worker.lua"
NVIM = os.environ.get("NVIM", "nvim")
PROCESS_TIMEOUT_SECONDS = 30
SLOW_MS = 1800


def create_workspace(base: Path, files: dict[str, str]) -> Path:
    root = base / "workspace"
    root.mkdir(parents=True)
    for name, contents in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
    return root


def make_env(base: Path, mode: str, root: Path) -> dict[str, str]:
    xdg = base / "xdg"
    paths = {
        "XDG_CONFIG_HOME": xdg / "config",
        "XDG_DATA_HOME": xdg / "data",
        "XDG_STATE_HOME": xdg / "state",
        "XDG_CACHE_HOME": xdg / "cache",
    }
    for path in paths.values():
        path.mkdir(parents=True, exist_ok=True)
    return os.environ.copy() | {
        **{key: str(path) for key, path in paths.items()},
        "DIRECT_E2E_REPO": str(REPO),
        "DIRECT_E2E_ROOT": str(root),
        "DIRECT_E2E_MODE": mode,
    }


def start_worker(mode: str, env: dict[str, str]) -> subprocess.Popen[str]:
    command = [NVIM, "--headless", "-u", "NONE", "-n", "-i", "NONE"]
    command.extend(["-l", str(WORKER)])
    return subprocess.Popen(
        command,
        cwd=REPO,
        env=env | {"DIRECT_E2E_MODE": mode},
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )


def finish_worker(process: subprocess.Popen[str], mode: str) -> tuple[str, str]:
    try:
        stdout, stderr = process.communicate(timeout=PROCESS_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
        raise TimeoutError(
            f"Neovim phase {mode!r} did not exit\nstdout:\n{stdout}\nstderr:\n{stderr}"
        )
    if process.returncode != 0:
        raise RuntimeError(
            f"Neovim phase {mode!r} failed with exit code {process.returncode}\n"
            f"stdout:\n{stdout}\nstderr:\n{stderr}"
        )
    return stdout, stderr


def run_worker(mode: str, env: dict[str, str]) -> tuple[str, str]:
    return finish_worker(start_worker(mode, env), mode)


def wait_for_marker(path: Path, process: subprocess.Popen[str], mode: str) -> None:
    deadline = time.monotonic() + PROCESS_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if path.is_file():
            return
        if process.poll() is not None:
            stdout, stderr = process.communicate()
            raise RuntimeError(
                f"Neovim phase {mode!r} exited before creating {path.name}\n"
                f"stdout:\n{stdout}\nstderr:\n{stderr}"
            )
        time.sleep(0.02)
    process.kill()
    stdout, stderr = process.communicate()
    raise TimeoutError(
        f"timed out waiting for {path.name} in phase {mode!r}\n"
        f"stdout:\n{stdout}\nstderr:\n{stderr}"
    )


def assert_waiting(process: subprocess.Popen[str], source: Path, destination: Path, mode: str) -> None:
    if process.poll() is not None:
        stdout, stderr = process.communicate()
        raise AssertionError(
            f"{mode} exited before its delayed save finished\n"
            f"stdout:\n{stdout}\nstderr:\n{stderr}"
        )
    if not source.exists() or destination.exists():
        raise AssertionError(
            f"{mode} did not remain inside the delayed move "
            f"(source={source.exists()}, destination={destination.exists()})"
        )


def delayed_env(base: Path, root: Path, source_name: str = "before.txt") -> tuple[dict[str, str], Path, Path]:
    env = make_env(base, "", root)
    source = root / source_name
    destination = root / "after.txt"
    env.update(
        {
            "DIRECT_E2E_SLOW_SRC": str(source),
            "DIRECT_E2E_SLOW_DST": str(destination),
            "DIRECT_E2E_SLOW_MS": str(SLOW_MS),
            "DIRECT_E2E_STARTED": str(base / "move-started"),
            "DIRECT_E2E_NOTIFICATION_LOG": str(base / "notifications.log"),
            "DIRECT_E2E_EXPECTED_DST": str(destination),
        }
    )
    return env, source, destination


def run_delayed_quit_case(base: Path, mode: str) -> None:
    root = create_workspace(base, {"before.txt": "payload\n"})
    env, source, destination = delayed_env(base, root)
    process = start_worker(mode, env)
    try:
        wait_for_marker(Path(env["DIRECT_E2E_STARTED"]), process, mode)
        assert_waiting(process, source, destination, mode)
        finish_worker(process, mode)
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()
    assert destination.read_text(encoding="utf-8") == "payload\n"
    if source.exists():
        raise AssertionError(f"{mode} left the original path behind")
    assert_copy_progress(env, source, destination, mode)
    assert_undo_restored(env, root, mode)


def run_write_and_history_case(base: Path) -> None:
    root = create_workspace(base, {"before.txt": "payload\n"})
    env = make_env(base, "write", root)
    returned = base / "write-returned"
    env["DIRECT_E2E_RETURNED"] = str(returned)
    run_worker("write", env)
    if not returned.is_file():
        raise AssertionError(":write did not return to the worker")
    assert_saved(root)
    run_worker("undo", env)
    if not (root / "before.txt").is_file() or (root / "after.txt").exists():
        raise AssertionError(":write did not commit undoable history")


def assert_saved(root: Path) -> None:
    if (root / "before.txt").exists() or not (root / "after.txt").is_file():
        raise AssertionError(f"expected completed rename in {root}")
    if (root / "after.txt").read_text(encoding="utf-8") != "payload\n":
        raise AssertionError("the saved file contents changed")


def assert_copy_progress(env: dict[str, str], source: Path, destination: Path, context: str) -> None:
    notifications = Path(env["DIRECT_E2E_NOTIFICATION_LOG"]).read_text(encoding="utf-8").lower()
    if (
        "copying " not in notifications
        or source.name.lower() not in notifications
        or destination.name.lower() not in notifications
        or "across filesystems" not in notifications
    ):
        raise AssertionError(f"{context} did not report cross-filesystem copy progress:\n{notifications}")


def assert_undo_restored(env: dict[str, str], root: Path, context: str) -> None:
    run_worker("undo", env)
    if not (root / "before.txt").is_file() or (root / "after.txt").exists():
        raise AssertionError(f"{context} did not leave undoable committed history")


def run_ctrl_c_case(base: Path) -> None:
    root = create_workspace(base, {"before.txt": "payload\n"})
    env, source, destination = delayed_env(base, root)
    returned = base / "write-returned"
    env["DIRECT_E2E_RETURNED"] = str(returned)
    process = start_worker("ctrl_c", env)
    try:
        wait_for_marker(Path(env["DIRECT_E2E_STARTED"]), process, "ctrl_c")
        wait_for_marker(returned, process, "ctrl_c")
        assert_waiting(process, source, destination, "Ctrl-C")
        finish_worker(process, "ctrl_c")
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()
    assert_saved(root)
    assert_copy_progress(env, source, destination, "Ctrl-C save")
    notifications = Path(env["DIRECT_E2E_NOTIFICATION_LOG"]).read_text(encoding="utf-8").lower()
    if "stopped waiting for the save" not in notifications or "continues in the background" not in notifications:
        raise AssertionError(f"Ctrl-C did not report that the save continues:\n{notifications}")
    assert_undo_restored(env, root, "Ctrl-C save")


def run_write_all_case(base: Path) -> None:
    root_a = create_workspace(base / "a", {"one-before.txt": "one\n"})
    root_b = create_workspace(base / "b", {"two-before.txt": "two\n"})
    env = make_env(base, "write_all", root_a)
    env["DIRECT_E2E_ROOT_A"] = str(root_a)
    env["DIRECT_E2E_ROOT_B"] = str(root_b)
    run_worker("write_all", env)
    if (root_a / "one-before.txt").exists() or not (root_a / "one-after.txt").exists():
        raise AssertionError(":wa did not save the first Direct listing")
    if (root_b / "two-before.txt").exists() or not (root_b / "two-after.txt").exists():
        raise AssertionError(":wa did not save the second Direct listing")
    run_worker("undo", env)
    run_worker("undo", env)
    if not (root_a / "one-before.txt").is_file() or (root_a / "one-after.txt").exists():
        raise AssertionError(":wa did not commit undoable history for the first listing")
    if not (root_b / "two-before.txt").is_file() or (root_b / "two-after.txt").exists():
        raise AssertionError(":wa did not commit undoable history for the second listing")


def run_qa_case(base: Path) -> None:
    root = create_workspace(base, {"before.txt": "payload\n"})
    env, source, destination = delayed_env(base, root)
    process = start_worker("qa_pending", env)
    try:
        wait_for_marker(Path(env["DIRECT_E2E_STARTED"]), process, "qa_pending")
        assert_waiting(process, source, destination, ":qa")
        finish_worker(process, "qa_pending")
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()
    assert_saved(root)
    assert_copy_progress(env, source, destination, ":qa")
    assert_undo_restored(env, root, ":qa")


def run_qa_ctrl_c_recovery_case(base: Path) -> None:
    root = create_workspace(base, {"before.txt": "payload\n"})
    env, source, destination = delayed_env(base, root)
    process = start_worker("qa_ctrl_c", env)
    try:
        wait_for_marker(Path(env["DIRECT_E2E_STARTED"]), process, "qa_ctrl_c")
        assert_waiting(process, source, destination, ":qa before Ctrl-C")
        finish_worker(process, "qa_ctrl_c")
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()

    notifications = Path(env["DIRECT_E2E_NOTIFICATION_LOG"]).read_text(encoding="utf-8").lower()
    assert_copy_progress(env, source, destination, ":qa Ctrl-C")
    if "stopped waiting for the save" not in notifications or "continues in the background" not in notifications:
        raise AssertionError(f":qa Ctrl-C did not report the stopped wait:\n{notifications}")
    if "stopped waiting" not in notifications or "journal will recover an interrupted operation" not in notifications:
        raise AssertionError(f":qa Ctrl-C did not report background save and journal recovery:\n{notifications}")
    if not source.is_file() or destination.exists():
        raise AssertionError("interrupted cross-filesystem save unexpectedly changed the source/destination")

    transaction = Path(env["XDG_DATA_HOME"]) / "direct" / "history" / "transaction.json"
    if not transaction.is_file():
        raise AssertionError(":qa Ctrl-C did not leave an interrupted-operation journal")

    recovery_env = env.copy()
    for key in ("DIRECT_E2E_SLOW_SRC", "DIRECT_E2E_SLOW_DST", "DIRECT_E2E_SLOW_MS", "DIRECT_E2E_STARTED"):
        recovery_env.pop(key, None)
    run_worker("undo", recovery_env)
    if not source.is_file() or destination.exists():
        raise AssertionError("fresh-process journal recovery/undo did not restore the original source safely")
    if transaction.exists():
        raise AssertionError("fresh-process journal recovery left transaction.json behind")


def run_bw_case(base: Path) -> None:
    root = create_workspace(base, {"before.txt": "payload\n"})
    env, source, destination = delayed_env(base, root)
    wiped = base / "buffer-wiped"
    finished = base / "save-finished"
    env["DIRECT_E2E_WIPED"] = str(wiped)
    env["DIRECT_E2E_FINISHED"] = str(finished)
    process = start_worker("bw_pending", env)
    try:
        wait_for_marker(Path(env["DIRECT_E2E_STARTED"]), process, "bw_pending")
        wait_for_marker(wiped, process, "bw_pending")
        assert_waiting(process, source, destination, ":bw!")
        wait_for_marker(finished, process, "bw_pending")
        finish_worker(process, "bw_pending")
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()
    assert_saved(root)
    assert_copy_progress(env, source, destination, ":bw!")
    notifications = Path(env["DIRECT_E2E_NOTIFICATION_LOG"]).read_text(encoding="utf-8")
    if "save continues" not in notifications.lower():
        raise AssertionError(f":bw! did not report that the save continues:\n{notifications}")
    run_worker("undo", env)
    if not (root / "before.txt").is_file() or (root / "after.txt").exists():
        raise AssertionError(":bw! save did not leave safely committed, undoable history")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="direct-a49-e2e-") as temp_dir:
        base = Path(temp_dir)
        run_write_and_history_case(base / "write")
        run_delayed_quit_case(base / "wq", "wq")
        run_delayed_quit_case(base / "x", "x")
        run_ctrl_c_case(base / "ctrl-c")
        run_write_all_case(base / "write-all")
        run_qa_case(base / "qa")
        run_qa_ctrl_c_recovery_case(base / "qa-ctrl-c")
        run_bw_case(base / "bw")
    print("E2E_A49_REAL_PROCESS_OK")


if __name__ == "__main__":
    main()
