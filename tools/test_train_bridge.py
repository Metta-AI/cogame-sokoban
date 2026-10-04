"""Play both distinct tasks and preserve production parser repair semantics."""

import json
import random
import subprocess
import sys
from pathlib import Path


def play(binary: Path, manifest: Path, variant: str, teacher: bool, language: bool) -> None:
    process = subprocess.Popen(
        [str(binary), str(manifest), variant, *( ["--language"] if language else [])],
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
        assert observation["inference_mode"] == ("text_action" if language else None)
        if language and teacher:
            frozen = observation
            result = request({"kind": "step", "decision_id": frozen["decision_id"],
                              "response": "private malformed reply"})
            assert result["kind"] == "rejected" and result["observation"] == frozen
            expected = json.loads(request({"kind": "teacher"})["response"])
            result = request({"kind": "step", "decision_id": frozen["decision_id"],
                              "response": "{private invalid JSON}"})
            assert result["kind"] == "consumed_rejection" and result["action"] == expected
            observation = result["observation"]
            for actions in ([{"do": "invalid"}, {"do": "wait"}], [{"do": "wait"}] * 9):
                result = request({"kind": "step", "decision_id": observation["decision_id"],
                                  "response": json.dumps({"actions": actions})})
                assert result["kind"] == "consumed_rejection"
                assert len(result["action"]["actions"]) == (1 if len(actions) == 2 else 8)
                observation = result["observation"]
                assert observation["semantic_view"]["last_turn"]["dropped"] == 1
        widths = set()
        decisions = 0
        while observation["kind"] == "decision":
            if language:
                action = (json.loads(request({"kind": "teacher"})["response"]) if teacher
                          else {"actions": [{"do": "wait"}], "say": "", "notes": ""})
                assert observation["inference_mode"] == "text_action"
                assert set(action) == {"actions", "say", "notes"}
            else:
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
        assert len(widths) == (0 if language else 1)
        print(
            variant,
            "teacher" if teacher else "random",
            decisions,
            "decisions",
            "text_action" if language else str(widths.pop()) + " features",
        )
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    language = len(sys.argv) == 3
    if language: assert sys.argv[2] == "--language"
    for variant in ("ladder", "hard"):
        for teacher in (True, False):
            play(binary, manifest, variant, teacher, language)
