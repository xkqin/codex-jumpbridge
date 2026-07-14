#!/usr/bin/env python3
"""Coordinate one shared Codex home across T-cluster SSH Hosts."""

from __future__ import print_function

import errno
import fcntl
import json
import os
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time


VERSION = "1.4.1"
ACTIVE_EXIT_CODE = 87
HISTORY_EXIT_CODE = 88
COORDINATION_EXIT_CODE = 89
COORDINATION_STATES = ("starting", "ready", "stopping", "recovering")
SHARED_HOME_LAYOUT = 2
THREAD_ID_RE = re.compile(
    r"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.jsonl$")
SHARED_ITEMS = (
    "auth.json",
    "config.toml",
    "AGENTS.md",
    "skills",
    "rules",
    "prompts",
)


def eprint(message):
    print(message, file=sys.stderr)


def ensure_dir(path, mode=0o700):
    if not os.path.isdir(path):
        try:
            os.makedirs(path, mode)
        except OSError as error:
            if error.errno != errno.EEXIST or not os.path.isdir(path):
                raise
    try:
        os.chmod(path, mode)
    except OSError:
        pass


def run_directory():
    configured = os.environ.get("CODEX_JUMPBRIDGE_RUN_DIR")
    if configured:
        return os.path.abspath(os.path.expanduser(configured))
    runtime_root = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    return os.path.join(
        runtime_root, "codex-jumpbridge-%d" % os.getuid())


def ensure_run_directory():
    path = run_directory()
    try:
        os.makedirs(path, 0o700)
    except OSError as error:
        if error.errno != errno.EEXIST:
            raise
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        details = os.fstat(descriptor)
        if not stat.S_ISDIR(details.st_mode):
            raise OSError("JumpBridge run path is not a directory: %s" % path)
        if details.st_uid != os.getuid():
            raise OSError("JumpBridge run directory has the wrong owner: %s" % path)
        os.fchmod(descriptor, 0o700)
        details = os.fstat(descriptor)
        if stat.S_IMODE(details.st_mode) & 0o077:
            raise OSError("JumpBridge run directory is not private: %s" % path)
    finally:
        os.close(descriptor)
    return path


def stat_clock(stat_result):
    mtime = getattr(
        stat_result, "st_mtime_ns", int(stat_result.st_mtime * 1000000000))
    ctime = getattr(
        stat_result, "st_ctime_ns", int(stat_result.st_ctime * 1000000000))
    return mtime, ctime, stat_result.st_size


def atomic_write(path, content, mode=0o600):
    ensure_dir(os.path.dirname(path))
    handle, temporary = tempfile.mkstemp(
        prefix=".%s." % os.path.basename(path), dir=os.path.dirname(path))
    try:
        with os.fdopen(handle, "wb") as stream:
            if not isinstance(content, bytes):
                content = content.encode("utf-8")
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def same_snapshot(source, destination):
    try:
        source_stat = os.stat(source)
        destination_stat = os.stat(destination)
    except OSError:
        return False
    return (
        source_stat.st_size == destination_stat.st_size
        and getattr(
            source_stat,
            "st_mtime_ns",
            int(source_stat.st_mtime * 1000000000),
        )
        == getattr(
            destination_stat,
            "st_mtime_ns",
            int(destination_stat.st_mtime * 1000000000),
        )
    )


def stable_copy(source, destination, attempts=4):
    ensure_dir(os.path.dirname(destination))
    for attempt in range(attempts):
        if same_snapshot(source, destination):
            return True
        try:
            before = os.stat(source)
        except OSError:
            return False
        handle, temporary = tempfile.mkstemp(
            prefix=".%s." % os.path.basename(destination),
            dir=os.path.dirname(destination))
        os.close(handle)
        try:
            shutil.copy2(source, temporary)
            after = os.stat(source)
            if stat_clock(before) != stat_clock(after):
                os.unlink(temporary)
                if attempt + 1 < attempts:
                    time.sleep(0.05 * (attempt + 1))
                    continue
                return False
            os.chmod(temporary, 0o600)
            os.replace(temporary, destination)
            return True
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    return False


def thread_key(path):
    match = THREAD_ID_RE.search(os.path.basename(path))
    if match:
        return match.group(1).lower()
    return os.path.basename(path)


def rollout_candidates(codex_home):
    roots = (
        (os.path.join(codex_home, "sessions"), False),
        (os.path.join(codex_home, "archived_sessions"), True),
    )
    result = []
    for root, archived in roots:
        if not os.path.isdir(root):
            continue
        for directory, _, files in os.walk(root):
            for name in files:
                if not name.endswith(".jsonl"):
                    continue
                path = os.path.join(directory, name)
                try:
                    clock = stat_clock(os.stat(path))
                except OSError:
                    continue
                result.append({
                    "key": thread_key(path),
                    "path": path,
                    "archived": archived,
                    "clock": clock,
                })
    return result


def choose_rollouts(homes):
    selected = {}
    for source_order, home in enumerate(homes):
        for candidate in rollout_candidates(home):
            rank = candidate["clock"] + (
                1 if candidate["archived"] else 0,
                source_order,
            )
            existing = selected.get(candidate["key"])
            if existing is None or rank > existing["rank"]:
                candidate["rank"] = rank
                selected[candidate["key"]] = candidate
    return selected


def rollout_destination(codex_home, candidate):
    if candidate["archived"]:
        return os.path.join(
            codex_home, "archived_sessions", os.path.basename(candidate["path"]))
    try:
        with open(candidate["path"], "rb") as stream:
            first_line = stream.readline(1024 * 1024).decode("utf-8", "replace")
        payload = json.loads(first_line)
        timestamp = payload.get("timestamp", "")
        date = timestamp[:10].split("-")
        if len(date) == 3 and all(part.isdigit() for part in date):
            return os.path.join(
                codex_home, "sessions", date[0], date[1], date[2],
                os.path.basename(candidate["path"]))
    except (IOError, OSError, ValueError, TypeError):
        pass
    return os.path.join(
        codex_home, "sessions", "unknown", os.path.basename(candidate["path"]))


def sync_rollouts(selected, destination_home, exact):
    wanted = {}
    for candidate in selected.values():
        destination = rollout_destination(destination_home, candidate)
        wanted[os.path.normpath(destination)] = candidate

    failed = []
    for destination, candidate in wanted.items():
        same_file = False
        try:
            same_file = os.path.samefile(candidate["path"], destination)
        except OSError:
            pass
        if not same_file and not stable_copy(candidate["path"], destination):
            failed.append((candidate["path"], destination))

    if failed:
        detail = "; ".join("%s -> %s" % pair for pair in failed[:3])
        raise IOError("history copy did not stabilize: %s" % detail)

    quarantine_root = os.path.join(
        destination_home,
        ".jumpbridge-quarantine",
        "%d-%d" % (int(time.time() * 1000000), os.getpid()))
    for candidate in rollout_candidates(destination_home):
        path = os.path.normpath(candidate["path"])
        should_remove = path not in wanted and (
            exact or candidate["key"] in selected)
        if should_remove:
            try:
                relative = os.path.relpath(path, destination_home)
                quarantine = os.path.join(quarantine_root, relative)
                ensure_dir(os.path.dirname(quarantine))
                os.replace(path, quarantine)
            except OSError:
                raise IOError("could not quarantine stale history: %s" % path)


def read_index_records(path, source_order):
    try:
        source_clock = stat_clock(os.stat(path))
        stream = open(path, "r", encoding="utf-8")
    except (IOError, OSError):
        return []
    records = []
    with stream:
        for line_number, line in enumerate(stream):
            try:
                payload = json.loads(line)
            except (TypeError, ValueError):
                continue
            key = payload.get("id") or payload.get("thread_id")
            if not key:
                continue
            updated = payload.get("updated_at") or payload.get("timestamp") or ""
            records.append((
                str(key),
                (str(updated),) + source_clock + (source_order, line_number),
                payload,
            ))
    return records


def merge_session_index(homes, master_home):
    selected = {}
    for source_order, home in enumerate(homes):
        path = os.path.join(home, "session_index.jsonl")
        for key, rank, payload in read_index_records(path, source_order):
            if key not in selected or rank > selected[key][0]:
                selected[key] = (rank, payload)
    if not selected:
        return
    lines = []
    for key in sorted(selected):
        lines.append(json.dumps(
            selected[key][1], ensure_ascii=False, separators=(",", ":")))
    atomic_write(
        os.path.join(master_home, "session_index.jsonl"),
        "\n".join(lines) + "\n")


def copy_session_index(source_home, destination_home):
    source = os.path.join(source_home, "session_index.jsonl")
    destination = os.path.join(destination_home, "session_index.jsonl")
    if os.path.isfile(source) and not stable_copy(source, destination):
        raise IOError(
            "session index copy did not stabilize: %s -> %s"
            % (source, destination))


def link_shared_items(legacy_home, host_home):
    for name in SHARED_ITEMS:
        source = os.path.join(legacy_home, name)
        destination = os.path.join(host_home, name)
        if not os.path.exists(source):
            continue
        if os.path.islink(destination):
            try:
                if os.path.realpath(destination) == os.path.realpath(source):
                    continue
                os.unlink(destination)
            except OSError:
                continue
        elif os.path.exists(destination):
            continue
        try:
            os.symlink(source, destination)
        except OSError:
            if os.path.isfile(source) and not stable_copy(source, destination):
                raise IOError(
                    "shared Codex file copy did not stabilize: %s -> %s"
                    % (source, destination))


def all_history_homes(root, legacy_home, master_home):
    homes = [legacy_home, master_home]
    host_root = os.path.join(root, "hosts")
    if os.path.isdir(host_root):
        for name in sorted(os.listdir(host_root)):
            home = os.path.join(host_root, name, "codex-home")
            if os.path.isdir(home):
                homes.append(home)
    result = []
    seen = set()
    for home in homes:
        canonical = os.path.realpath(home)
        if canonical not in seen:
            seen.add(canonical)
            result.append(home)
    return result


def synchronize_in(root, legacy_home, master_home, host_home):
    homes = all_history_homes(root, legacy_home, master_home)
    selected = choose_rollouts(homes)
    sync_rollouts(selected, master_home, exact=True)
    merge_session_index(homes, master_home)
    link_shared_items(legacy_home, master_home)


def shared_home_marker(root):
    return os.path.join(root, "shared-home-v%d.json" % SHARED_HOME_LAYOUT)


def shared_home_is_prepared(root):
    path = shared_home_marker(root)
    try:
        with open(path, "r", encoding="utf-8") as stream:
            payload = json.load(stream)
    except (IOError, OSError, TypeError, ValueError):
        return False
    return payload.get("layout") == SHARED_HOME_LAYOUT


def prepare_shared_home(
        root, legacy_home, master_home, host_home, force=False):
    """Import older homes once, then use the master home directly."""
    if force or not shared_home_is_prepared(root):
        synchronize_in(root, legacy_home, master_home, host_home)
        atomic_write(
            shared_home_marker(root),
            json.dumps({
                "layout": SHARED_HOME_LAYOUT,
                "prepared_at": int(time.time()),
            }, sort_keys=True, separators=(",", ":")) + "\n")
    else:
        link_shared_items(legacy_home, master_home)


def synchronize_out(root, legacy_home, master_home, host_home):
    homes = all_history_homes(root, legacy_home, master_home)
    selected = choose_rollouts(homes)
    sync_rollouts(selected, master_home, exact=True)
    merge_session_index(homes, master_home)
    # The legacy ~/.codex tree may be live in VS Code/Cursor. Treat it as an
    # import-only source: atomically replacing files there can detach an open
    # writer and lose later appends. JumpBridge history remains durable in the
    # master tree and is synchronized to every isolated Host on connect.


def read_pid(path):
    try:
        with open(path, "r") as stream:
            return int(stream.read().strip())
    except (IOError, OSError, TypeError, ValueError):
        return None


def process_matches(pid, socket_path):
    if not pid or pid <= 1:
        return False
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as stream:
            command = stream.read().replace(b"\0", b" ").decode("utf-8", "replace")
    except (IOError, OSError):
        return False
    return "app-server" in command and socket_path in command


def app_server_control_paths(host_token):
    control_directory = ensure_run_directory()
    socket_path = os.path.join(control_directory, "as-%s.sock" % host_token)
    pid_path = os.path.join(control_directory, "as-%s.pid" % host_token)
    if len(socket_path.encode("utf-8")) > 100:
        raise OSError(
            "JumpBridge app-server socket path is too long: %s" % socket_path)
    return socket_path, pid_path


def stop_app_server(host_token):
    socket_path, pid_path = app_server_control_paths(host_token)
    pid = read_pid(pid_path)
    if process_matches(pid, socket_path):
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
        deadline = time.time() + 5.0
        while time.time() < deadline and process_matches(pid, socket_path):
            time.sleep(0.1)
        if process_matches(pid, socket_path):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
    for path in (pid_path, socket_path):
        try:
            os.unlink(path)
        except OSError:
            pass
    try:
        os.rmdir(socket_path + ".lock")
    except OSError:
        pass


class CoordinationError(Exception):
    """Fail-closed error for an inconsistent shared history lease."""


def lock_is_busy(error):
    return error.errno in (errno.EACCES, errno.EAGAIN)


def set_close_on_exec(stream):
    os.set_inheritable(stream.fileno(), False)


def acquire_coordination_lock(root):
    ensure_dir(root)
    stream = open(os.path.join(root, "coord.lock"), "a+")
    set_close_on_exec(stream)
    try:
        fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
    except Exception:
        stream.close()
        raise
    return stream


def release_coordination_lock(stream):
    if stream is None:
        return
    try:
        fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
    finally:
        stream.close()


def active_state_path(root):
    return os.path.join(root, "active.json")


def read_active_state(root):
    path = active_state_path(root)
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as stream:
            payload = json.load(stream)
    except (IOError, OSError, TypeError, ValueError) as error:
        raise CoordinationError(
            "shared active state is unreadable: %s" % error)
    if not isinstance(payload, dict):
        raise CoordinationError("shared active state is not a JSON object")
    return payload


def write_active_state(root, payload):
    atomic_write(
        active_state_path(root),
        json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")


def clear_active_state(root):
    try:
        os.unlink(active_state_path(root))
    except OSError as error:
        if error.errno != errno.ENOENT:
            raise


def process_start_clock(pid):
    try:
        with open("/proc/%d/stat" % pid, "r") as stream:
            value = stream.read()
        fields = value[value.rfind(")") + 2:].split()
        return fields[19]
    except (IOError, OSError, IndexError, ValueError):
        return None


def make_generation():
    return "%d-%d-%s" % (
        int(time.time() * 1000000), os.getpid(), os.urandom(8).hex())


def lease_directory(root):
    return os.path.join(root, "leases")


def create_lease(root, host_token, generation, role):
    directory = lease_directory(root)
    ensure_dir(directory)
    lease_id = "%s-%d-%s" % (
        generation, os.getpid(), os.urandom(8).hex())
    path = os.path.join(directory, "lease-%s.json" % lease_id)
    descriptor = os.open(
        path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
    os.set_inheritable(descriptor, False)
    stream = os.fdopen(descriptor, "r+")
    try:
        fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        metadata = {
            "lease_id": lease_id,
            "host": host_token,
            "generation": generation,
            "role": role,
            "hostname": socket.gethostname(),
            "run_directory": ensure_run_directory(),
            "pid": os.getpid(),
            "process_start": process_start_clock(os.getpid()),
            "started_at": int(time.time()),
        }
        stream.write(json.dumps(metadata, sort_keys=True))
        stream.flush()
        os.fsync(stream.fileno())
    except Exception:
        try:
            stream.close()
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass
        raise
    return {
        "lease_id": lease_id,
        "path": path,
        "stream": stream,
        "metadata": metadata,
    }


def read_lease_metadata(stream, path):
    try:
        stream.seek(0)
        payload = json.load(stream)
    except (IOError, OSError, TypeError, ValueError) as error:
        raise CoordinationError(
            "live lease is unreadable (%s): %s" % (path, error))
    if not isinstance(payload, dict) or not payload.get("lease_id"):
        raise CoordinationError("live lease has invalid metadata: %s" % path)
    payload["_path"] = path
    return payload


def scan_live_leases(root, owned_lease=None):
    directory = lease_directory(root)
    if not os.path.isdir(directory):
        return []
    owned_path = None
    if owned_lease is not None:
        owned_path = os.path.normcase(os.path.abspath(owned_lease["path"]))
    live = []
    for name in sorted(os.listdir(directory)):
        if not name.startswith("lease-") or not name.endswith(".json"):
            continue
        path = os.path.join(directory, name)
        normalized = os.path.normcase(os.path.abspath(path))
        if normalized == owned_path:
            if not os.path.exists(path):
                raise CoordinationError("owned lease file disappeared: %s" % path)
            payload = dict(owned_lease["metadata"])
            payload["_path"] = path
            live.append(payload)
            continue
        try:
            stream = open(path, "r+")
        except OSError as error:
            if error.errno == errno.ENOENT:
                continue
            raise CoordinationError("could not inspect lease %s: %s" % (path, error))
        set_close_on_exec(stream)
        acquired = False
        try:
            try:
                fcntl.flock(
                    stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
            except (IOError, OSError) as error:
                if not lock_is_busy(error):
                    raise CoordinationError(
                        "shared filesystem lease check failed for %s: %s"
                        % (path, error))
            if acquired:
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
                stream.close()
                stream = None
                try:
                    os.unlink(path)
                except OSError as error:
                    if error.errno != errno.ENOENT:
                        raise CoordinationError(
                            "could not remove dead lease %s: %s" % (path, error))
            else:
                live.append(read_lease_metadata(stream, path))
        finally:
            if acquired and stream is not None:
                try:
                    fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
                except OSError:
                    pass
            if stream is not None:
                stream.close()
    return live


def release_lease(lease):
    if lease is None:
        return
    stream = lease.get("stream")
    try:
        if stream is not None:
            try:
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
            finally:
                stream.close()
            lease["stream"] = None
    finally:
        try:
            os.unlink(lease["path"])
        except OSError as error:
            if error.errno != errno.ENOENT:
                raise


def validate_active_state(active, live):
    required = (
        "host", "hostname", "generation", "status", "run_directory")
    if any(not isinstance(active.get(name), str) or not active.get(name)
           for name in required):
        raise CoordinationError("shared active state is missing required fields")
    if active["status"] not in COORDINATION_STATES:
        raise CoordinationError(
            "shared active state has an unknown status: %s" % active["status"])
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", active["host"]):
        raise CoordinationError("shared active state contains an invalid Host token")
    for lease in live:
        for field in (
                "lease_id", "host", "hostname", "generation", "run_directory"):
            if not isinstance(lease.get(field), str) or not lease.get(field):
                raise CoordinationError("live lease is missing %s" % field)
        if (lease["host"] != active["host"] or
                lease["hostname"] != active["hostname"] or
                lease["generation"] != active["generation"] or
                os.path.normpath(lease["run_directory"]) !=
                os.path.normpath(active["run_directory"])):
            raise CoordinationError(
                "live leases disagree with the shared active state")
    transition = active.get("transition_lease")
    if active["status"] == "ready":
        if transition:
            raise CoordinationError("ready state still has a transition owner")
    elif live:
        live_ids = set(item["lease_id"] for item in live)
        if not transition or transition not in live_ids:
            raise CoordinationError(
                "%s state has no live transition owner" % active["status"])


def legacy_lock_owner(root):
    path = os.path.join(root, "active.lock")
    if not os.path.exists(path):
        return None
    stream = open(path, "a+")
    set_close_on_exec(stream)
    try:
        try:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (IOError, OSError) as error:
            if not lock_is_busy(error):
                raise CoordinationError(
                    "legacy active-lock check failed: %s" % error)
            stream.seek(0)
            return stream.read().strip() or "unknown legacy owner"
        fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
        return None
    finally:
        stream.close()


def emit_busy(owner):
    detail = " Active owner: %s" % owner if owner else ""
    eprint(
        "Codex JumpBridge: another cluster Host is already serving Codex history."
        + detail)
    eprint("Disconnect it in Codex Desktop before enabling this Host.")
    marker = os.environ.get("CODEX_JUMPBRIDGE_BUSY_MARKER")
    if marker:
        print(marker)
        sys.stdout.flush()


def new_active_state(host_token, generation, status, transition_lease):
    return {
        "host": host_token,
        "hostname": socket.gethostname(),
        "generation": generation,
        "status": status,
        "run_directory": ensure_run_directory(),
        "transition_lease": transition_lease,
        "updated_at": int(time.time()),
    }


def coordination_timeout():
    raw = os.environ.get("CODEX_JUMPBRIDGE_COORD_TIMEOUT", "120")
    try:
        return max(1.0, float(raw))
    except (TypeError, ValueError):
        return 120.0


def release_transition_lease(root, lease):
    coordination = acquire_coordination_lock(root)
    try:
        release_lease(lease)
    finally:
        release_coordination_lock(coordination)


def recover_stale_active(
        root, legacy_home, master_home, active, recovery_lease):
    host_token = active["host"]
    host_home = os.path.join(root, "hosts", host_token, "codex-home")
    try:
        stop_app_server(host_token)
    except Exception as error:
        eprint(
            "Codex JumpBridge: stale Host recovery failed for %s: %s"
            % (host_token, error))
        try:
            release_transition_lease(root, recovery_lease)
        except Exception as release_error:
            eprint(
                "Codex JumpBridge: could not release recovery lease: %s"
                % release_error)
        return False

    coordination = acquire_coordination_lock(root)
    try:
        current = read_active_state(root)
        live = scan_live_leases(root, recovery_lease)
        if current is None:
            raise CoordinationError(
                "active state disappeared during stale Host recovery")
        validate_active_state(current, live)
        if (current["generation"] != active["generation"] or
                current["status"] != "recovering" or
                current.get("transition_lease") != recovery_lease["lease_id"]):
            raise CoordinationError(
                "active generation changed during stale Host recovery")
        clear_active_state(root)
        release_lease(recovery_lease)
    except Exception:
        if recovery_lease.get("stream") is not None:
            release_lease(recovery_lease)
        raise
    finally:
        release_coordination_lock(coordination)
    return True


def admit_connection(
        root, legacy_home, master_home, host_token, stopping):
    """Join a ready Host generation or become its one-time initializer."""
    deadline = time.time() + coordination_timeout()
    current_hostname = socket.gethostname()
    while True:
        action = None
        busy_owner = None
        coordination = acquire_coordination_lock(root)
        try:
            live = scan_live_leases(root)
            active = read_active_state(root)
            if active is None:
                if live:
                    raise CoordinationError(
                        "live leases exist without shared active state")
                old_owner = legacy_lock_owner(root)
                if old_owner:
                    busy_owner = old_owner
                else:
                    generation = make_generation()
                    lease = create_lease(
                        root, host_token, generation, "proxy")
                    starting = new_active_state(
                        host_token, generation, "starting", lease["lease_id"])
                    try:
                        write_active_state(root, starting)
                    except Exception:
                        release_lease(lease)
                        raise
                    return lease, True, 0
            else:
                validate_active_state(active, live)
                if not live:
                    if active["hostname"] != current_hostname:
                        raise CoordinationError(
                            "stale active Host %s belongs to node %s; current node "
                            "%s refuses cross-node recovery because app-server "
                            "liveness cannot be verified"
                            % (active["host"], active["hostname"], current_hostname))
                    if (os.path.normpath(active["run_directory"]) !=
                            os.path.normpath(ensure_run_directory())):
                        raise CoordinationError(
                            "stale active Host %s uses run directory %s; current "
                            "session uses %s and refuses recovery while the old "
                            "app-server location is uncertain"
                            % (
                                active["host"],
                                active["run_directory"],
                                ensure_run_directory()))
                    recovery_lease = create_lease(
                        root, active["host"], active["generation"], "recovery")
                    active["status"] = "recovering"
                    active["transition_lease"] = recovery_lease["lease_id"]
                    active["updated_at"] = int(time.time())
                    try:
                        write_active_state(root, active)
                    except Exception:
                        release_lease(recovery_lease)
                        raise
                    action = ("recover", dict(active), recovery_lease)
                elif active["host"] != host_token:
                    busy_owner = json.dumps(active, sort_keys=True)
                elif active["hostname"] != current_hostname:
                    busy_owner = (
                        "Host %s is active on node %s"
                        % (host_token, active["hostname"]))
                elif (os.path.normpath(active["run_directory"]) !=
                      os.path.normpath(ensure_run_directory())):
                    raise CoordinationError(
                        "active Host %s uses run directory %s; current session "
                        "uses %s and cannot safely share its app-server"
                        % (
                            host_token,
                            active["run_directory"],
                            ensure_run_directory()))
                elif active["status"] == "ready":
                    lease = create_lease(
                        root, host_token, active["generation"], "proxy")
                    return lease, False, 0
                else:
                    action = ("wait", active["status"], None)
        finally:
            release_coordination_lock(coordination)

        if busy_owner is not None:
            emit_busy(busy_owner)
            return None, False, ACTIVE_EXIT_CODE
        if action and action[0] == "recover":
            if not recover_stale_active(
                    root, legacy_home, master_home, action[1], action[2]):
                return None, False, COORDINATION_EXIT_CODE
            continue
        if stopping[0]:
            return None, False, 128 + 1
        if time.time() >= deadline:
            raise CoordinationError(
                "timed out waiting for same-Host history initialization")
        time.sleep(0.1)


def mark_connection_ready(root, lease):
    coordination = acquire_coordination_lock(root)
    try:
        live = scan_live_leases(root, lease)
        active = read_active_state(root)
        if active is None:
            raise CoordinationError(
                "active state disappeared during Host initialization")
        validate_active_state(active, live)
        if (active["host"] != lease["metadata"]["host"] or
                active["generation"] != lease["metadata"]["generation"] or
                active["status"] != "starting" or
                active.get("transition_lease") != lease["lease_id"]):
            raise CoordinationError(
                "active generation changed during Host initialization")
        active["status"] = "ready"
        active["transition_lease"] = None
        active["updated_at"] = int(time.time())
        write_active_state(root, active)
    finally:
        release_coordination_lock(coordination)


def leave_connection(
        root, legacy_home, master_home, host_token, host_home, lease):
    """Release one proxy and stop the shared app-server for the last one."""
    coordination = acquire_coordination_lock(root)
    try:
        live = scan_live_leases(root, lease)
        active = read_active_state(root)
        if active is None:
            eprint("Codex JumpBridge: active state disappeared before disconnect")
            release_lease(lease)
            return False
        validate_active_state(active, live)
        metadata = lease["metadata"]
        if (active["host"] != metadata["host"] or
                active["generation"] != metadata["generation"]):
            eprint(
                "Codex JumpBridge: active generation changed before disconnect; "
                "refusing to stop another app-server")
            release_lease(lease)
            return False
        own_ids = set([lease["lease_id"]])
        other_live = [
            item for item in live if item["lease_id"] not in own_ids]
        if other_live:
            if active["status"] != "ready":
                raise CoordinationError(
                    "another proxy remained during a non-ready transition")
            release_lease(lease)
            return True
        active["status"] = "stopping"
        active["transition_lease"] = lease["lease_id"]
        active["updated_at"] = int(time.time())
        write_active_state(root, active)
    except Exception:
        if lease.get("stream") is not None:
            release_lease(lease)
        raise
    finally:
        release_coordination_lock(coordination)

    synchronized = True
    try:
        stop_app_server(host_token)
    except Exception as error:
        synchronized = False
        eprint("Codex JumpBridge: app-server shutdown failed: %s" % error)

    coordination = acquire_coordination_lock(root)
    try:
        current = read_active_state(root)
        live = scan_live_leases(root, lease)
        if current is None:
            synchronized = False
            eprint("Codex JumpBridge: active state disappeared during disconnect")
        else:
            validate_active_state(current, live)
            if (current["generation"] != lease["metadata"]["generation"] or
                    current["status"] != "stopping" or
                    current.get("transition_lease") != lease["lease_id"]):
                synchronized = False
                eprint(
                    "Codex JumpBridge: active generation changed during disconnect")
            elif synchronized:
                clear_active_state(root)
        release_lease(lease)
    finally:
        release_coordination_lock(coordination)
    return synchronized


def preflight():
    control_directory = ensure_run_directory()
    socket_path = os.path.join(
        control_directory, "as-preflight-%d.sock" % os.getpid())
    encoded_length = len(socket_path.encode("utf-8"))
    if encoded_length > 100:
        eprint(
            "Codex JumpBridge: remote socket path is too long (%d bytes)"
            % encoded_length)
        return 1
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    bound = False
    try:
        probe.bind(socket_path)
        bound = True
    except OSError as error:
        eprint("Codex JumpBridge: remote socket preflight failed: %s" % error)
        return 1
    finally:
        probe.close()
        if bound:
            try:
                os.unlink(socket_path)
            except OSError:
                pass
    print("CODEX_JUMPBRIDGE_HISTORY_PREFLIGHT=READY")
    print("CODEX_JUMPBRIDGE_SOCKET_PATH_BYTES=%d" % encoded_length)
    return 0


def run(host_token, command):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", host_token):
        eprint("Codex JumpBridge: invalid Host token")
        return 2
    home = os.path.expanduser("~")
    root = os.environ.get(
        "CODEX_JUMPBRIDGE_HISTORY_ROOT",
        os.path.join(home, ".codex-jumpbridge", "history"))
    legacy_home = os.environ.get(
        "CODEX_JUMPBRIDGE_LEGACY_CODEX_HOME",
        os.path.join(home, ".codex"))
    master_home = os.path.join(root, "master")
    host_home = os.path.join(root, "hosts", host_token, "codex-home")
    ensure_dir(master_home)
    ensure_dir(host_home)
    app_server_control_paths(host_token)

    child = [None]
    stopping = [False]
    received_signal = [None]

    def handle_signal(signum, _frame):
        stopping[0] = True
        received_signal[0] = signum
        process = child[0]
        if process is not None and process.poll() is None:
            try:
                process.terminate()
            except OSError:
                pass

    previous_handlers = []
    handled_signals = [signal.SIGTERM, signal.SIGINT]
    if hasattr(signal, "SIGHUP"):
        handled_signals.append(signal.SIGHUP)
    for handled_signal in handled_signals:
        previous_handlers.append((
            handled_signal,
            signal.signal(handled_signal, handle_signal)))
    result = 1
    lease = None
    try:
        lease, is_starter, admission_result = admit_connection(
            root, legacy_home, master_home, host_token, stopping)
        if admission_result != 0:
            result = (128 + (received_signal[0] or 1)
                      if stopping[0] else admission_result)
        elif is_starter:
            stop_app_server(host_token)
            prepare_shared_home(
                root,
                legacy_home,
                master_home,
                host_home,
                force=(os.environ.get(
                    "CODEX_JUMPBRIDGE_FORCE_HISTORY_PREPARE", "0") == "1"))
            mark_connection_ready(root, lease)

        if lease is not None and stopping[0]:
            result = 128 + (received_signal[0] or 1)
        elif lease is not None:
            environment = os.environ.copy()
            # One active Host generation owns this shared home. Using it
            # directly removes thousands of NFS copies from every reconnect.
            environment["CODEX_HOME"] = master_home
            environment["CODEX_JUMPBRIDGE_LEGACY_CODEX_HOME"] = legacy_home
            environment["CODEX_JUMPBRIDGE_RUN_DIR"] = ensure_run_directory()
            child[0] = subprocess.Popen(
                command, env=environment, close_fds=True)
            while child[0].poll() is None:
                try:
                    child[0].wait()
                except KeyboardInterrupt:
                    handle_signal(signal.SIGINT, None)
            result = child[0].returncode
            if stopping[0]:
                result = 128 + (received_signal[0] or signal.SIGINT)
    except CoordinationError as error:
        eprint("Codex JumpBridge: history coordination failed: %s" % error)
        result = COORDINATION_EXIT_CODE
    except Exception as error:
        eprint("Codex JumpBridge: history setup failed: %s" % error)
        result = HISTORY_EXIT_CODE
    finally:
        process = child[0]
        if process is not None and process.poll() is None:
            try:
                process.terminate()
                process.wait(timeout=5)
            except Exception:
                try:
                    process.kill()
                except OSError:
                    pass
        if lease is not None and lease.get("stream") is not None:
            try:
                clean = leave_connection(
                    root,
                    legacy_home,
                    master_home,
                    host_token,
                    host_home,
                    lease)
                if not clean and result == 0:
                    result = HISTORY_EXIT_CODE
            except Exception as error:
                eprint(
                    "Codex JumpBridge: history disconnect coordination failed: %s"
                    % error)
                if lease.get("stream") is not None:
                    try:
                        release_lease(lease)
                    except Exception:
                        pass
                if result == 0:
                    result = COORDINATION_EXIT_CODE
        for handled_signal, previous_handler in previous_handlers:
            signal.signal(handled_signal, previous_handler)
    return result


def status():
    home = os.path.expanduser("~")
    root = os.environ.get(
        "CODEX_JUMPBRIDGE_HISTORY_ROOT",
        os.path.join(home, ".codex-jumpbridge", "history"))
    legacy_home = os.environ.get(
        "CODEX_JUMPBRIDGE_LEGACY_CODEX_HOME",
        os.path.join(home, ".codex"))
    print("CODEX_JUMPBRIDGE_HISTORY_SYNC=%s" % VERSION)
    print("CODEX_JUMPBRIDGE_HISTORY_ROOT=%s" % root)
    print("CODEX_JUMPBRIDGE_LEGACY_HISTORY=%s" % legacy_home)
    return 0


def prepare(host_token):
    previous = os.environ.get("CODEX_JUMPBRIDGE_FORCE_HISTORY_PREPARE")
    os.environ["CODEX_JUMPBRIDGE_FORCE_HISTORY_PREPARE"] = "1"
    try:
        result = run(host_token, ["/bin/sh", "-c", ":"])
    finally:
        if previous is None:
            os.environ.pop("CODEX_JUMPBRIDGE_FORCE_HISTORY_PREPARE", None)
        else:
            os.environ["CODEX_JUMPBRIDGE_FORCE_HISTORY_PREPARE"] = previous
    if result == 0:
        print("CODEX_JUMPBRIDGE_HISTORY_PREPARE=READY")
    return result


def main(arguments):
    if arguments in (["--version"], ["version"]):
        print("codex-jumpbridge-history-sync %s" % VERSION)
        return 0
    if arguments == ["status"]:
        return status()
    if arguments == ["preflight"]:
        return preflight()
    if len(arguments) == 2 and arguments[0] == "prepare":
        return prepare(arguments[1])
    if len(arguments) >= 4 and arguments[0] == "run" and arguments[2] == "--":
        return run(arguments[1], arguments[3:])
    eprint(
        "Usage: codex-jumpbridge-history-sync prepare <host-token> | "
        "run <host-token> -- <command> [args...]")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
