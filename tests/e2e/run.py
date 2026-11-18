#!/usr/bin/env python3
"""Exercise save/restart/undo behavior with separate Neovim processes."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import time


REPO = Path(__file__).resolve().parents[2]
WORKER = REPO / "tests" / "e2e" / "worker.lua"
NVIM = os.environ.get("NVIM", "nvim")
PROCESS_TIMEOUT_SECONDS = 45


def run_worker(mode: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    worker_env = env | {"DIRECT_E2E_MODE": mode}
    result = subprocess.run(
        [NVIM, "--headless", "-u", "NONE", "-n", "-i", "NONE", "-l", str(WORKER)],
        cwd=REPO,
        env=worker_env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=PROCESS_TIMEOUT_SECONDS,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"Neovim phase {mode!r} failed with exit code {result.returncode}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def assert_file(path: Path, contents: str) -> None:
    if not path.is_file() or path.read_text(encoding="utf-8") != contents:
        raise AssertionError(f"expected {path} to contain {contents!r}")


def wait_for_file(path: Path, process: subprocess.Popen[str]) -> None:
    deadline = time.monotonic() + PROCESS_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if path.exists():
            return
        if process.poll() is not None:
            stdout, stderr = process.communicate()
            raise RuntimeError(
                f"stale-listing Neovim exited before creating {path.name}\n"
                f"stdout:\n{stdout}\nstderr:\n{stderr}"
            )
        time.sleep(0.02)
    process.kill()
    stdout, stderr = process.communicate()
    raise TimeoutError(
        f"timed out waiting for {path.name}\nstdout:\n{stdout}\nstderr:\n{stderr}"
    )


def make_directory_link(link: Path, target: Path) -> None:
    try:
        os.symlink(target, link, target_is_directory=True)
    except OSError:
        if os.name != "nt":
            raise
        # A directory junction gives Windows CI the same path-resolution
        # coverage without requiring Developer Mode or symlink privileges.
        result = subprocess.run(
            ["cmd.exe", "/c", "mklink", "/J", str(link), str(target)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"could not create a directory symlink/junction:\n"
                f"{result.stdout}\n{result.stderr}"
            )


def remove_directory_link(link: Path) -> None:
    if not link.exists() and not link.is_symlink():
        return
    if os.name == "nt":
        os.rmdir(link)
    else:
        link.unlink()


def run_stale_listing_case(env: dict[str, str], root: Path, tmp: Path) -> None:
    ready = tmp / "stale-ready"
    proceed = tmp / "stale-proceed"
    notification_log = tmp / "stale-notifications"
    stale_env = env | {
        "DIRECT_E2E_READY": str(ready),
        "DIRECT_E2E_PROCEED": str(proceed),
        "DIRECT_E2E_NOTIFICATION_LOG": str(notification_log),
    }
    stale_process = subprocess.Popen(
        [
            NVIM,
            "--headless",
            "-u",
            "NONE",
            "-n",
            "-i",
            "NONE",
            "-l",
            str(WORKER),
        ],
        cwd=REPO,
        env=stale_env | {"DIRECT_E2E_MODE": "stale_wait"},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    try:
        wait_for_file(ready, stale_process)
        run_worker("stale_fresh_save", env)
        proceed.write_text("save now\n", encoding="utf-8")
        stdout, stderr = stale_process.communicate(timeout=PROCESS_TIMEOUT_SECONDS)
        if stale_process.returncode != 0:
            raise RuntimeError(
                f"stale-listing Neovim failed with exit code {stale_process.returncode}\n"
                f"stdout:\n{stdout}\nstderr:\n{stderr}"
            )
    finally:
        if stale_process.poll() is None:
            stale_process.kill()
            stale_process.communicate()

    notifications = notification_log.read_text(encoding="utf-8") if notification_log.exists() else ""
    if "directory changed on disk since it was listed" not in notifications:
        raise AssertionError(
            "the second live process did not report the stale-listing refusal; "
            f"notifications were: {notifications!r}"
        )
    assert_file(root / "fresh-shared.txt", "shared\n")
    if (root / "stale-shared.txt").exists() or (root / "shared.txt").exists():
        raise AssertionError("a stale listing changed the filesystem")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="direct-e2e-") as temp_dir:
        tmp = Path(temp_dir)
        root = tmp / "workspace"
        folder = root / "folder"
        destination = root / "destination"
        special = root / ".hidden space-雪"
        root.mkdir()
        folder.mkdir()
        destination.mkdir()
        special.mkdir()

        (root / "alpha.txt").write_text("alpha\n", encoding="utf-8")
        (root / "remove.txt").write_text("remove me\n", encoding="utf-8")
        (folder / "payload.txt").write_text("payload\n", encoding="utf-8")
        (special / "note.txt").write_text("special path\n", encoding="utf-8")

        data = tmp / "data"
        config = tmp / "config"
        state = tmp / "state"
        cache = tmp / "cache"
        for directory in (data, config, state, cache):
            directory.mkdir()

        env = os.environ.copy()
        env.update(
            {
                "XDG_DATA_HOME": str(data),
                "XDG_CONFIG_HOME": str(config),
                "XDG_STATE_HOME": str(state),
                "XDG_CACHE_HOME": str(cache),
                "DIRECT_E2E_REPO": str(REPO),
                "DIRECT_E2E_ROOT": str(root),
                "DIRECT_E2E_DESTINATION": str(destination),
                "DIRECT_E2E_SPECIAL": str(special),
            }
        )

        run_worker("save", env)
        assert_file(root / "renamed.txt", "alpha\n")
        if (root / "alpha.txt").exists() or (root / "remove.txt").exists():
            raise AssertionError("the save did not apply the rename and delete")
        assert_file(destination / "folder" / "payload.txt", "payload\n")
        assert_file(folder / "payload.txt", "payload\n")

        run_worker("undo", env)
        assert_file(root / "alpha.txt", "alpha\n")
        assert_file(root / "remove.txt", "remove me\n")
        if (root / "renamed.txt").exists() or (destination / "folder").exists():
            raise AssertionError("three undos did not restore the original tree")

        run_worker("redo", env)
        assert_file(root / "renamed.txt", "alpha\n")
        if (root / "alpha.txt").exists() or (root / "remove.txt").exists():
            raise AssertionError("three redos did not reapply the saved changes")
        assert_file(destination / "folder" / "payload.txt", "payload\n")

        link = tmp / "directory-link"
        make_directory_link(link, special)
        try:
            run_worker("symlink_and_special_path", env | {"DIRECT_E2E_LINK": str(link)})
        finally:
            remove_directory_link(link)

        (root / "shared.txt").write_text("shared\n", encoding="utf-8")
        run_stale_listing_case(env, root, tmp)

    print("E2E_REAL_PROCESS_OK")


if __name__ == "__main__":
    main()
