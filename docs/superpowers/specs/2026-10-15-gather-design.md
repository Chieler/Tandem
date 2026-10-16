# Gather delegated worker replies

## Purpose

A leader sometimes needs several worker answers before making a decision. `send` and `spawn` can wait for one answer each, but do not return a single completion boundary for a set of tasks. Add a `gather` MCP call for work the leader explicitly delegates. Unsolicited messages remain ordinary pane messages.

## Interface

`gather({tasks: [...], timeout?: seconds, from?: agent})` accepts a nonempty ordered array. Each task has `kind: "send"` with `to` and `text`, or `kind: "spawn"` with the existing spawn fields (`harness`, `name`, `task`, and optional `cwd`, `tier`, `model`, `effort`). The batch has one deadline; task-level `wait` and `timeout` are not used. The default deadline is the existing 600 seconds.

The MCP text result is JSON with `complete` and a `results` array in input order. Every result has `kind`, `agent`, `status`, and, when dispatched, `id`. An answered result has `status: "answered"` and `text`; a timeout has `status: "timed_out"`; a dispatch or worker failure has `status: "failed"` and `error`. `complete` is true only when every task answered.

## Delivery and failure behavior

Register each task as waiting before dispatch, then dispatch all tasks before waiting for replies. Preserve the existing per-message reply IDs and `reply` tool; workers need no new protocol. Buffer early answers as the current blocking send does. Collect replies until all have answered or the shared deadline expires. Return available answers and identify every missing or failed task. Late replies after the deadline use the existing pane delivery path with their IDs. If a client cancels the call, preserve the existing reply handoff to the leader's pane.

The pane input lock continues to keep individual messages separate. `gather` provides the leader's decision boundary. It makes no claim about reports that were not named in the batch.

## Verification

Test two sends to distinct workers with replies in reverse order; the call must remain pending until both answer and return input order. Test early reply buffering, partial timeout, and a failed task. Test a spawn task through the existing fake harness setup. Existing send, spawn, and reply tests must continue to pass.
