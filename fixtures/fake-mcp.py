#!/usr/bin/env python3
"""Deterministic fake stdio MCP server for cntctr code-mode Phase 5+ tests."""

import argparse
import fcntl
import json
import os
import re
import signal
import stat
import sys
import threading
import time


def bump_counter(path):
    lock_path = path + ".lock"
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(lock_path, "a+") as lf:
        fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
        try:
            count = 0
            if os.path.exists(path):
                with open(path, "r") as f:
                    raw = f.read().strip()
                    if raw:
                        count = int(raw)
            count += 1
            tmp = path + f".tmp.{os.getpid()}"
            with open(tmp, "w") as f:
                f.write(f"{count}\n")
                f.flush()
            os.replace(tmp, path)
            return count
        finally:
            fcntl.flock(lf.fileno(), fcntl.LOCK_UN)


def atomic_touch(path, text="ready\n"):
    tmp = path + f".tmp.{os.getpid()}.{threading.get_ident()}"
    with open(tmp, "w") as f:
        f.write(text)
        f.flush()
    os.replace(tmp, path)


def count_socket_fds():
    n = 0
    for fd in range(3, 256):
        try:
            st = os.fstat(fd)
            if stat.S_ISSOCK(st.st_mode):
                n += 1
        except OSError:
            pass
    return n


def spam_stderr(nbytes):
    chunk = ("E" * 4095 + "\n").encode("ascii")
    rem = nbytes
    while rem > 0:
        w = chunk if rem >= len(chunk) else chunk[:rem]
        try:
            os.write(2, w)
        except OSError:
            break
        rem -= len(w)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paginate", action="store_true")
    ap.add_argument("--both-hints", action="store_true")
    ap.add_argument("--mutate-class-on-restart", default=None)
    ap.add_argument("--mutate-schema-on-restart", default=None)
    ap.add_argument("--isolated-tag", action="store_true")
    ap.add_argument("--banner", action="store_true")
    ap.add_argument("--spam-stderr", action="store_true")
    ap.add_argument("--hang-init", action="store_true")
    ap.add_argument("--tag", default="")
    ap.add_argument("--init-barrier", default=None)
    ap.add_argument("--mutate-on-list-barrier", default=None)
    ap.add_argument("--proto-version", default=None)
    ap.add_argument("--method-log", default=None)
    ap.add_argument("--server-requests", default=None)
    ap.add_argument("--call-log", default=None)
    ap.add_argument("--pid-file", default=None)
    ap.add_argument("--fail-list-after-changed", type=int, default=0)
    ap.add_argument("--evil-tool-names", action="store_true")
    args = ap.parse_args()

    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))

    if args.pid_file:
        atomic_touch(args.pid_file, f"{os.getpid()}\n")

    class_start_num = bump_counter(args.mutate_class_on_restart) if args.mutate_class_on_restart else 1
    schema_start_num = bump_counter(args.mutate_schema_on_restart) if args.mutate_schema_on_restart else 1

    if args.banner:
        sys.stdout.write("fake-mcp starting up (non-JSON banner line 1)\n")
        sys.stdout.write("fake-mcp ready for stdio JSON-RPC\n")
        sys.stdout.flush()

    if args.spam_stderr:
        spam_stderr(300 * 1024)

    write_lock = threading.Lock()
    state_lock = threading.Lock()
    dynamic_tools = []
    dyn_seq = 0
    echo_mutated_int = False
    list_count = 0
    fail_list_left = 0  # tools/list requests still to fail after an emit_changed (per process)
    srv_reply_events = {}
    srv_replies = {}

    def send_json(obj):
        line = json.dumps(obj, separators=(",", ":")) + "\n"
        with write_lock:
            sys.stdout.write(line)
            sys.stdout.flush()

    def log_method(name):
        if args.method_log and name:
            with state_lock:
                with open(args.method_log, "a") as f:
                    f.write(str(name) + "\n")
                    f.flush()

    def log_srv_reply(msg):
        if args.server_requests:
            with state_lock:
                with open(args.server_requests, "a") as f:
                    f.write(json.dumps(msg, separators=(",", ":")) + "\n")
                    f.flush()

    def send_server_request_and_wait(sreq_id, method_name, params_obj=None, timeout_s=2.0):
        ev = threading.Event()
        with state_lock:
            srv_reply_events[sreq_id] = ev
            srv_replies.pop(sreq_id, None)
        req_obj = {"jsonrpc": "2.0", "id": sreq_id, "method": method_name}
        if params_obj is not None:
            req_obj["params"] = params_obj
        send_json(req_obj)
        ev.wait(timeout_s)
        with state_lock:
            srv_reply_events.pop(sreq_id, None)
            return srv_replies.pop(sreq_id, None)

    def build_tools(force_echo_type=None):
        with state_lock:
            mut_int = echo_mutated_int
            dyn_copy = list(dynamic_tools)
        ping_ann = {"destructiveHint": True} if class_start_num >= 2 else {"readOnlyHint": True}
        if force_echo_type is not None:
            echo_msg_type = force_echo_type
        else:
            echo_msg_type = "integer" if (schema_start_num >= 2 or mut_int) else "string"
        nuke_ann = {"readOnlyHint": True, "destructiveHint": True} if args.both_hints else {"destructiveHint": True}

        tools = [
            {
                "name": "ping",
                "description": "Return server pid, cwd, and env_tag",
                "inputSchema": {"type": "object", "properties": {}},
                "annotations": ping_ann,
            },
            {
                "name": "echo",
                "description": "Echo a message",
                "inputSchema": {
                    "type": "object",
                    "properties": {"msg": {"type": echo_msg_type}},
                    "required": ["msg"],
                },
                "annotations": {"readOnlyHint": True},
            },
            {
                "name": "sleep_tool",
                "description": "Sleep for ms or until go_file appears",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "ms": {"type": "integer", "minimum": 0},
                        "ready_file": {"type": "string"},
                        "go_file": {"type": "string"},
                    },
                    "required": ["ms"],
                },
                "annotations": {"readOnlyHint": True},
            },
            {
                "name": "write_item",
                "description": "Write an item with a title",
                "inputSchema": {
                    "type": "object",
                    "properties": {"title": {"type": "string"}},
                    "required": ["title"],
                },
                "annotations": {"readOnlyHint": False},
            },
            {
                "name": "unannotated_op",
                "description": "Operation without annotations (must default to write)",
                "inputSchema": {"type": "object", "properties": {}},
            },
            {
                "name": "nuke",
                "description": "Destructive operation",
                "inputSchema": {"type": "object", "properties": {}},
                "annotations": nuke_ann,
            },
            {
                "name": "big_result",
                "description": "Return a large payload of bytes length",
                "inputSchema": {
                    "type": "object",
                    "properties": {"bytes": {"type": "integer", "minimum": 0}},
                    "required": ["bytes"],
                },
                "annotations": {"readOnlyHint": True},
            },
            {
                "name": "crash_now",
                "description": "Exit immediately with status 1 before replying",
                "inputSchema": {
                    "type": "object",
                    "properties": {"delay_ms": {"type": "integer", "minimum": 0}},
                },
                "annotations": {"readOnlyHint": True},
            },
            {
                "name": "emit_changed",
                "description": "Emit notifications/tools/list_changed",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "add_tool": {"type": "string"},
                        "mutate_echo_int": {"type": "boolean"},
                    },
                },
                "annotations": {"readOnlyHint": True},
            },
        ]

        if args.isolated_tag:
            base = os.path.basename(os.getcwd()) or "root"
            safe_base = re.sub(r"[^a-zA-Z0-9_]", "_", base)
            tools.append(
                {
                    "name": f"tag_{safe_base}",
                    "description": f"Isolated tag tool for {base}",
                    "inputSchema": {"type": "object", "properties": {}},
                    "annotations": {"readOnlyHint": True},
                }
            )

        if args.evil_tool_names:
            for evil in ("bad\ntool", "ctl\x7fname", "x" * 200):
                tools.append({"name": evil, "description": "name with control bytes or too long",
                              "inputSchema": {"type": "object", "properties": {}}, "annotations": {"readOnlyHint": True}})

        for dname in dyn_copy:
            tools.append(
                {
                    "name": dname,
                    "description": f"Dynamically added tool {dname}",
                    "inputSchema": {"type": "object", "properties": {}},
                    "annotations": {"readOnlyHint": True},
                }
            )
        return tools

    def log_tool_call(name):
        if args.call_log:
            with state_lock:
                with open(args.call_log, "a") as f:
                    f.write(name + "\n")
                    f.flush()

    def run_sleep_tool(req_id, targs):
        ms = int(targs.get("ms", 0))
        rf = targs.get("ready_file")
        gf = targs.get("go_file")
        if rf:
            atomic_touch(rf, f"{os.getpid()}\n")
        deadline = time.monotonic() + (ms / 1000.0)
        if gf:
            while not os.path.exists(gf) and time.monotonic() < deadline:
                time.sleep(0.01)
        else:
            rem = deadline - time.monotonic()
            if rem > 0:
                time.sleep(rem)
        payload = {"slept_ms": ms, "pid": os.getpid()}
        send_json(
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [{"type": "text", "text": json.dumps(payload)}],
                },
            }
        )

    def run_delayed_crash(delay_ms):
        time.sleep(delay_ms / 1000.0)
        os._exit(1)

    init_done = False
    initialized_done = False

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        if not isinstance(msg, dict):
            continue

        method = msg.get("method")
        req_id = msg.get("id")
        params = msg.get("params") if isinstance(msg.get("params"), dict) else {}

        # Response from client to a server-initiated request (has id, no method)
        if method is None and "id" in msg:
            log_srv_reply(msg)
            with state_lock:
                srv_replies[req_id] = msg
                ev = srv_reply_events.get(req_id)
            if ev is not None:
                ev.set()
            continue

        log_method(method)

        if method == "initialize":
            if args.init_barrier:
                atomic_touch(args.init_barrier + ".ready", f"{os.getpid()}\n")
                while not os.path.exists(args.init_barrier + ".go"):
                    time.sleep(0.01)
            if args.hang_init:
                while True:
                    time.sleep(1.0)
            if args.proto_version is not None:
                req_ver = args.proto_version
            else:
                req_ver = params.get("protocolVersion", "2024-11-05")
                if req_ver not in ("2025-06-18", "2025-03-26", "2024-11-05"):
                    req_ver = "2024-11-05"
            init_done = True
            send_json(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "protocolVersion": req_ver,
                        "capabilities": {"tools": {"listChanged": True}},
                        "serverInfo": {"name": "fake-mcp", "version": "1.0.0"},
                    },
                }
            )
            continue

        if method == "notifications/initialized":
            if init_done:
                initialized_done = True
            continue

        if method == "ping":
            if req_id is not None:
                send_json({"jsonrpc": "2.0", "id": req_id, "result": {}})
            continue

        if method in ("tools/list", "tools/call"):
            if not (init_done and initialized_done):
                if req_id is not None:
                    send_json(
                        {
                            "jsonrpc": "2.0",
                            "id": req_id,
                            "error": {
                                "code": -32002,
                                "message": "server not initialized: complete initialize and notifications/initialized first",
                            },
                        }
                    )
                continue

        if method == "tools/list":
            with state_lock:
                failing = fail_list_left > 0
                if failing:
                    fail_list_left -= 1
            if failing:
                send_json({"jsonrpc": "2.0", "id": req_id,
                           "error": {"code": -32603, "message": "injected tools/list failure"}})
                continue
            list_count += 1
            cursor = params.get("cursor")
            cur_list_num = list_count

            def finish_tools_list(rid=req_id, cur=cursor, lnum=cur_list_num):
                nonlocal echo_mutated_int
                force_type = None
                if args.mutate_on_list_barrier and lnum == 2 and not cur:
                    atomic_touch(args.mutate_on_list_barrier + ".ready", f"{os.getpid()}\n")
                    while not os.path.exists(args.mutate_on_list_barrier + ".go"):
                        time.sleep(0.01)
                    with state_lock:
                        echo_mutated_int = True
                    # Emit list_changed BEFORE returning old schema so any queued CTRL_CALL
                    # ahead of CTRL_REFRESH must drain the pending refresh & recheck meta_gen.
                    send_json({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
                    force_type = "string"
                if args.server_requests and lnum == 1 and not cur:
                    send_server_request_and_wait(9000, "ping", None, 2.0)
                tools = build_tools(force_echo_type=force_type)
                if args.paginate:
                    mid = max(1, len(tools) // 2)
                    if not cur:
                        result = {"tools": tools[:mid], "nextCursor": "page2"}
                    elif cur == "page2":
                        result = {"tools": tools[mid:]}
                    else:
                        send_json(
                            {
                                "jsonrpc": "2.0",
                                "id": rid,
                                "error": {"code": -32602, "message": f"invalid cursor: {cur}"},
                            }
                        )
                        return
                else:
                    result = {"tools": tools}
                send_json({"jsonrpc": "2.0", "id": rid, "result": result})

            if (args.mutate_on_list_barrier and cur_list_num == 2 and not cursor) or (
                args.server_requests and cur_list_num == 1 and not cursor
            ):
                th = threading.Thread(target=finish_tools_list, daemon=True)
                th.start()
            else:
                finish_tools_list()
            continue

        if method == "tools/call":
            tname = params.get("name", "")
            targs = params.get("arguments") if isinstance(params.get("arguments"), dict) else {}
            log_tool_call(tname)
            if args.spam_stderr:
                spam_stderr(16 * 1024)

            if tname == "ping":
                def finish_ping(rid=req_id):
                    payload = {
                        "ok": True,
                        "pid": os.getpid(),
                        "cwd": os.getcwd(),
                        "env_tag": os.environ.get("FAKE_ENV_TAG", args.tag),
                        "leaked_secret": "SECRET_DOWNSTREAM_LEAK" in os.environ,
                        "leaked_sock_fds": count_socket_fds(),
                    }
                    if args.server_requests:
                        ping_rep = send_server_request_and_wait(9001, "ping", None, 2.0)
                        unk_rep = send_server_request_and_wait(
                            "srv-req-2", "sampling/createMessage", {"messages": []}, 2.0
                        )
                        payload["srv_ping_reply"] = ping_rep
                        payload["srv_unknown_reply"] = unk_rep
                    send_json(
                        {
                            "jsonrpc": "2.0",
                            "id": rid,
                            "result": {
                                "structuredContent": payload,
                                "content": [{"type": "text", "text": json.dumps(payload)}],
                            },
                        }
                    )

                if args.server_requests:
                    th = threading.Thread(target=finish_ping, daemon=True)
                    th.start()
                else:
                    finish_ping()
            elif tname == "echo":
                payload = {"msg": targs.get("msg")}
                send_json(
                    {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"content": [{"type": "text", "text": json.dumps(payload)}]},
                    }
                )
            elif tname == "sleep_tool":
                th = threading.Thread(target=run_sleep_tool, args=(req_id, targs), daemon=True)
                th.start()
            elif tname == "write_item":
                payload = {"written": targs.get("title", "")}
                send_json(
                    {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"content": [{"type": "text", "text": json.dumps(payload)}]},
                    }
                )
            elif tname == "unannotated_op":
                send_json(
                    {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"content": [{"type": "text", "text": json.dumps({"ok": True})}]},
                    }
                )
            elif tname == "nuke":
                send_json(
                    {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"content": [{"type": "text", "text": json.dumps({"nuked": True})}]},
                    }
                )
            elif tname == "big_result":
                nbytes = max(0, int(targs.get("bytes", 0)))
                send_json(
                    {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"content": [{"type": "text", "text": "x" * nbytes}]},
                    }
                )
            elif tname == "crash_now":
                delay_ms = int(targs.get("delay_ms", 0))
                if delay_ms > 0:
                    th = threading.Thread(target=run_delayed_crash, args=(delay_ms,), daemon=True)
                    th.start()
                else:
                    os._exit(1)
            elif tname == "emit_changed":
                with state_lock:
                    dyn_seq += 1
                    add_tool = targs.get("add_tool") or f"dyn_tool_{dyn_seq}"
                    if add_tool not in dynamic_tools:
                        dynamic_tools.append(add_tool)
                    if targs.get("mutate_echo_int"):
                        echo_mutated_int = True
                    fail_list_left = args.fail_list_after_changed
                send_json({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
                send_json(
                    {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"content": [{"type": "text", "text": json.dumps({"emitted": True, "added": add_tool})}]},
                    }
                )
            elif tname.startswith("tag_") or tname in dynamic_tools:
                payload = {"tool": tname, "pid": os.getpid(), "cwd": os.getcwd()}
                send_json(
                    {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"content": [{"type": "text", "text": json.dumps(payload)}]},
                    }
                )
            else:
                send_json(
                    {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {
                            "isError": True,
                            "content": [{"type": "text", "text": f"unknown tool: {tname}"}],
                        },
                    }
                )
            continue

        if req_id is not None:
            send_json(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {"code": -32601, "message": f"method not found: {method}"},
                }
            )


if __name__ == "__main__":
    main()
