"""Aggregate actual benchmark samples; validate Fluffy chunk and tick coverage."""
import csv
import json
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

root = Path(sys.argv[1])

def quantiles(values):
    values = sorted(values)
    assert values
    return {"n": len(values), "mean": statistics.mean(values),
            **{name: values[int((len(values) - 1) * p)]
               for name, p in [("p50", .5), ("p95", .95), ("p99", .99), ("max", 1)]}}

summary = {"tick_budget_ms": 1000 / 32, "timings": {}, "phases": {}, "coverage": {}}
all_rows = []
for directory in sorted(root.glob("release-*")) + [root / "trace"]:
    if not directory.is_dir():
        continue
    for case in ["low", "high"]:
        rows = json.loads((directory / f"{case}-samples.json").read_text())
        for r in rows:
            r["run"] = directory.name
        all_rows.extend(rows)
        for mode in ["session", "world", "replay", "hash"]:
            rr = [r for r in rows if r["mode"] == mode]
            assert len(rr) == 512
            assert [r["sample"] for r in rr] == list(range(512))
            if mode != "hash":
                assert [r["tick_before"] for r in rr] == list(range(512, 1024))
                assert all(r["tick_after"] == r["tick_before"] + 1 for r in rr)
            divisor = 32 if mode == "hash" else 1
            key = f"{directory.name}/{case}/{mode}"
            data = quantiles([r["tick_ns"] / 1e6 / divisor for r in rr])
            data.update({
                "active_min": min(r["active_before"] for r in rr),
                "active_max": max(r["active_before"] for r in rr),
                "pending_min": min(r["pending_before"] for r in rr),
                "pending_max": max(r["pending_before"] for r in rr),
                "over_budget": sum(r["tick_ns"] / 1e6 > 1000 / 32 for r in rr),
                "heap_delta_max": max(r["heap_delta"] for r in rr),
                "checkpoints_added": sum(r["checkpoint_added"] for r in rr),
                "order_ms": quantiles([r["order_ns"] / 1e6 for r in rr]),
                "checkpoint_ms": quantiles([r["checkpoint_ns"] / 1e6 for r in rr if r["checkpoint_added"]]) if mode in ["world", "replay"] else None,
                "top_ticks": sorted(rr, key=lambda r: r["tick_ns"], reverse=True)[:10],
            })
            summary["timings"][key] = data
            if mode == "hash":
                data["hashes_per_second"] = 512 * 32 * 1e9 / sum(r["tick_ns"] for r in rr)

for case in ["low", "high"]:
    for mode in ["session", "world", "replay", "hash"]:
        chunks = sorted((root / "trace").glob(f"{case}-{mode}-*.json"))
        assert len(chunks) == 8
        by_name = defaultdict(list)
        phase_rows = []
        for path in chunks:
            events = json.loads(path.read_text())["traceEvents"]
            assert len(events) < 10_000
            counts = Counter(e["name"] for e in events)
            assert counts["bench.tick"] == 64
            if mode in ["world", "session", "replay"]:
                assert counts["advance*"] == 64
            if mode == "session":
                assert counts["decide*"] == 64 * 16
                assert counts["step*"] == 64
            summary["coverage"][path.name] = dict(counts)
            for e in events:
                by_name[e["name"]].append(e["dur"] / 1000)
            # Exclusive advance remainder: drainLaunches plus winner/tick bookkeeping.
            # No production instrumentation changes; never label this drain alone.
            for advance in [e for e in events if e["name"] == "advance*"]:
                children = [e for e in events if e["name"] in ["moveBodies*", "produce*", "arrivals"] and e["ts"] >= advance["ts"] and e["ts"] + e["dur"] <= advance["ts"] + advance["dur"] + .001]
                assert len(children) == 3
                by_name["advance_remainder_drain_plus_bookkeeping"].append((advance["dur"] - sum(e["dur"] for e in children)) / 1000)
            if mode == "session":
                for step in [e for e in events if e["name"] == "step*"]:
                    decisions = [e for e in events if e["name"] == "decide*" and step["ts"] <= e["ts"] < step["ts"] + step["dur"]]
                    assert len(decisions) == 16
                    by_name["all_16_bot_decisions_including_launches"].append(sum(e["dur"] for e in decisions) / 1000)
        summary["phases"][f"{case}/{mode}"] = {n: quantiles(v) for n, v in by_name.items()}

with (root / "samples.csv").open("w") as f:
    writer = csv.DictWriter(f, fieldnames=list(all_rows[0]))
    writer.writeheader()
    writer.writerows(all_rows)
(root / "summary.json").write_text(json.dumps(summary, indent=2))
for key, value in summary["timings"].items():
    print(key, " ".join(f"{n}={value[n]:.5f}" for n in ["p50", "p95", "p99", "max"]), "over_budget=", value["over_budget"])
print("Verified", len(all_rows), "samples and", len(summary["coverage"]), "uncapped Fluffy chunks")
