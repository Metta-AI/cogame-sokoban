"""Play complete certified Sokoban ladders through the numeric JSONL bridge."""

import json
import random
import subprocess
import sys
from pathlib import Path


def play(binary: Path, manifest: Path, variant: str, teacher: bool) -> None:
    process = subprocess.Popen(
        [str(binary), str(manifest), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None and process.stdout is not None
    rng = random.Random(17)

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        observation = request(
            {"kind": "reset", "seed": f"sokoban-{variant}-{teacher}", "players": 1}
        )
        widths = set()
        decisions = 0
        while observation["kind"] == "decision":
            encoding = request({"kind": "encode"})
            widths.add(len(encoding["values"]))
            assert encoding["decision_id"] == observation["decision_id"]
            heads = encoding["action_heads"]
            assert len(heads) == 8
            assert [len(head["choices"]) for head in heads] == [18] * 8
            if teacher:
                action = json.loads(request({"kind": "teacher"})["response"])
                assert all(action[head["name"]] in head["choices"] for head in heads)
            else:
                action = {head["name"]: rng.choice(head["choices"]) for head in heads}
            result = request(
                {
                    "kind": "step",
                    "decision_id": observation["decision_id"],
                    "response": json.dumps(action),
                }
            )
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
            assert decisions <= 60
        assert observation["kind"] == "terminal"
        assert set(observation["scores"]) == {"0"}
        assert observation["scores"]["0"] >= 0
        assert -1 <= observation["utilities"]["0"] <= 1
        assert len(widths) == 1
        print(
            variant,
            "teacher" if teacher else "random",
            decisions,
            "decisions",
            widths.pop(),
            "features",
        )
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    for variant in ("ladder", "hard"):
        for teacher in (True, False):
            play(binary, manifest, variant, teacher)
