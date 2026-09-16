#!/usr/bin/env python3
"""Lean Review Auto-Check — 发现未审 / 已过期的 lean review 并要求补做。

不保证审查结论正确，也不是不可绕过的门禁：Stop hook 是补救型 continuation 机制。

子命令：
  session-start  SessionStart hook：记录本轮基线
  review-start   审查开始前调用，打印一个 token（当时的代码指纹）
  receipt        审查结束后凭 token 签发回执；期间代码变了则拒签
  pause          声明「等待用户」，下一次 Stop 放行但不清除未完成义务
  stop           Stop hook：判定 PASS / SKIP / BLOCK
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
STATE_DIR = REPO / ".agent" / "lean-review"
STATE_FILE = STATE_DIR / "state.json"
RECEIPT_FILE = STATE_DIR / "receipt.json"
LOG_FILE = STATE_DIR / "log.jsonl"

# 指纹与「本轮变更」都必须排除这些路径，否则写 receipt / 写日志会让上一次审查立刻失效。
EXCLUDED_PREFIXES = (".agent/lean-review/",)
# 文档与任务记录不触发审查义务；其余一律算代码。宁可多拦，不可漏拦。
NON_CODE_SUFFIXES = (".md",)
NON_CODE_PREFIXES = (".agent/",)

MAX_BLOCKS = 2  # 自有上限，必须早于 Claude 官方的 8 次连续 block 上限


def git(*args: str) -> str:
    out = subprocess.run(("git", "-C", str(REPO)) + args, capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {out.stderr.strip()}")
    return out.stdout


def is_excluded(path: str) -> bool:
    # __pycache__ 会随每次 hook 运行变化，算进指纹会自发让 receipt 过期。
    return path.startswith(EXCLUDED_PREFIXES) or "__pycache__/" in path


def is_code(path: str) -> bool:
    if is_excluded(path) or path.startswith(NON_CODE_PREFIXES):
        return False
    return not path.endswith(NON_CODE_SUFFIXES)


def worktree_entries() -> list[tuple[str, str]]:
    """(path, content-hash)，覆盖已暂存、未暂存与未跟踪文件。新增文件必须能被发现。"""
    entries: list[tuple[str, str]] = []
    raw = git("status", "--porcelain=v1", "-z", "--untracked-files=all")
    for item in raw.split("\0"):
        if len(item) < 4:
            continue
        path = item[3:]
        if is_excluded(path):
            continue
        full = REPO / path
        if full.is_file():
            digest = hashlib.sha256(full.read_bytes()).hexdigest()[:16]
        else:
            digest = "missing"  # 删除也是变更
        entries.append((path, digest))
    return sorted(entries)


def fingerprint() -> str:
    head = git("rev-parse", "HEAD").strip()
    payload = head + "".join(f"{p}:{d}" for p, d in worktree_entries())
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


def changed_scope(baseline_head: str, baseline_entries: dict[str, str]) -> list[str]:
    """本轮变更 = 相对会话基线新增的改动，跨越提交边界。

    必须减去基线：会话开始前就存在的未提交改动是历史欠账，算进来会产生误拦。
    比较的是 (path, content-hash)，所以「改了又改回去」不算变更，新增文件算。
    """
    current = dict(worktree_entries())
    paths = {p for p in set(current) | set(baseline_entries)
             if current.get(p) != baseline_entries.get(p)}
    try:
        committed = git("diff", "--name-only", f"{baseline_head}..HEAD")
        paths.update(line for line in committed.splitlines() if line)
    except RuntimeError:
        pass  # 基线提交不可达（rebase / reset）时退化为只看工作区，日志里可见
    return sorted(p for p in paths if is_code(p))


def load(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return {}


def save(path: Path, data: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2))


def log(decision: str, reason: str, scope_count: int, receipt_match, started: float, session: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    row = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "platform": "claude",
        "project": REPO.name,
        "session": session[:8],
        "decision": decision,
        "reason": reason,
        "changed_scope_count": scope_count,
        "receipt_match": receipt_match,
        "duration_ms": int((time.time() - started) * 1000),
    }
    with LOG_FILE.open("a") as handle:
        handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def cmd_session_start(payload: dict) -> int:
    session = payload.get("session_id", "")
    state = load(STATE_FILE)
    # 同一 session 重复触发（resume/compact）不覆盖基线，否则本轮已有的变更会被当成历史。
    if state.get("session_id") != session:
        save(STATE_FILE, {
            "session_id": session,
            "baseline_head": git("rev-parse", "HEAD").strip(),
            "baseline_fp": fingerprint(),
            "baseline_entries": dict(worktree_entries()),
            "pending": False,
            "block_count": 0,
            "paused": False,
        })
    return 0


def cmd_review_start(_: dict) -> int:
    print(fingerprint())
    return 0


def cmd_receipt(_: dict) -> int:
    import argparse

    parser = argparse.ArgumentParser(prog="lean_review.py receipt")
    parser.add_argument("--token", required=True, help="review-start 打印的指纹")
    parser.add_argument("--review-file", required=True, help="实际审查输出文件")
    parser.add_argument("--outcome", required=True, choices=["deleted", "reused", "kept", "unverified", "none"])
    parser.add_argument("--validation", required=True, help="实际执行的检查与结果")
    args = parser.parse_args(sys.argv[2:])

    review = Path(args.review_file)
    if not review.is_absolute():
        review = REPO / review
    if not review.is_file() or review.stat().st_size == 0:
        print(f"拒签：审查输出文件不存在或为空：{review}", file=sys.stderr)
        return 1

    current = fingerprint()
    if current != args.token:
        print(f"拒签：审查期间代码已变化（token={args.token} 现在={current}）。"
              f"请对受影响范围补审后重新 review-start。", file=sys.stderr)
        return 1

    state = load(STATE_FILE)
    save(RECEIPT_FILE, {
        "issued_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "session_id": state.get("session_id"),
        "fingerprint": current,
        "scope": changed_scope(state.get("baseline_head", "HEAD"), state.get("baseline_entries", {})),
        "outcome": args.outcome,
        "validation": args.validation,
        "review_file": str(review.relative_to(REPO)),
    })
    state["pending"] = False
    state["block_count"] = 0
    save(STATE_FILE, state)
    print(f"receipt 已签发，fingerprint={current}")
    return 0


def cmd_pause(_: dict) -> int:
    reason = sys.argv[2] if len(sys.argv) > 2 else "等待用户确认"
    state = load(STATE_FILE)
    state["paused"] = True
    state["pause_reason"] = reason
    save(STATE_FILE, state)
    print(f"已标记为等待用户：{reason}（未完成义务保留）")
    return 0


def cmd_stop(payload: dict) -> int:
    started = time.time()
    session = payload.get("session_id", "")
    state = load(STATE_FILE)

    if not state or state.get("session_id") != session:
        # 没有基线（例如 SessionStart 未触发）：不伪装成通过，放行但记 error 供试点排查。
        log("error", "无本轮基线，无法判定", 0, None, started, session)
        return 0

    scope = changed_scope(state.get("baseline_head", "HEAD"), state.get("baseline_entries", {}))
    if not scope and not state.get("pending"):
        log("skip", "本轮无代码变更", 0, None, started, session)
        return 0

    if state.get("paused"):
        state["paused"] = False          # 只放行一次
        state["pending"] = True          # SKIP 不清除未完成义务
        save(STATE_FILE, state)
        log("skip", f"等待用户：{state.get('pause_reason', '')}（义务保留）", len(scope), None, started, session)
        return 0

    receipt = load(RECEIPT_FILE)
    current = fingerprint()
    match = bool(receipt) and receipt.get("fingerprint") == current and receipt.get("session_id") == session

    if match:
        state["pending"] = False
        state["block_count"] = 0
        save(STATE_FILE, state)
        log("pass", "receipt 覆盖当前状态", len(scope), True, started, session)
        return 0

    blocks = state.get("block_count", 0)
    if blocks >= MAX_BLOCKS:
        state["pending"] = True
        save(STATE_FILE, state)
        log("block", f"达到自有上限 {MAX_BLOCKS} 次，有界退出，仍未完成审查", len(scope), False, started, session)
        print(f"⚠️ lean review 仍未完成（已连续要求 {blocks} 次）。本轮以**未完成**状态结束，"
              f"未审范围：{', '.join(scope[:10])}", file=sys.stderr)
        return 0

    state["block_count"] = blocks + 1
    state["pending"] = True
    save(STATE_FILE, state)
    why = "本轮有代码变更但没有 receipt" if not receipt else "receipt 已过期（审查后代码又变了）"
    log("block", why, len(scope), False, started, session)
    print(json.dumps({
        "decision": "block",
        "reason": (
            f"{why}。本轮变更 {len(scope)} 个文件：{', '.join(scope[:10])}。\n"
            f"请按 ~/.codex/skills/dev-workflow/SKILL.md 的「瘦身判据」与「末次审查」审这些变更，"
            f"然后：\n"
            f"1) TOKEN=$(python3 .claude/hooks/lean_review.py review-start)\n"
            f"2) 把审查结论写进一个文件（例如 .agent/lean-review/review-latest.md）\n"
            f"3) python3 .claude/hooks/lean_review.py receipt --token $TOKEN "
            f"--review-file .agent/lean-review/review-latest.md --outcome none --validation '<实际跑的检查与结果>'\n"
            f"「无需简化」是合法结论；强制的是检查，不是强制改代码。"
            f"若在等待我确认，改为执行：python3 .claude/hooks/lean_review.py pause '<原因>'"
        ),
    }, ensure_ascii=False))
    return 0


COMMANDS = {
    "session-start": cmd_session_start,
    "review-start": cmd_review_start,
    "receipt": cmd_receipt,
    "pause": cmd_pause,
    "stop": cmd_stop,
}


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(__doc__, file=sys.stderr)
        return 2
    command = sys.argv[1]
    payload = {}
    if command in ("session-start", "stop") and not sys.stdin.isatty():
        try:
            payload = json.loads(sys.stdin.read() or "{}")
        except json.JSONDecodeError:
            payload = {}
    return COMMANDS[command](payload)


if __name__ == "__main__":
    sys.exit(main())
