# Metta post-training data

The source-controlled `pusher-private-view` teacher uses the ordinary private
observation, prompt renderer, reply parser, and simulator. It requires no
model provider. Export complete games from a clean, committed checkout:

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/sokoban-export tools/export_posttrain.nim
revision=$(git rev-parse HEAD)
/tmp/sokoban-export /tmp/sokoban-ladder-events 20 1 ladder "source-$revision"
/tmp/sokoban-export /tmp/sokoban-hard-events 20 1 hard "source-$revision"
```

The five arguments are output directory, episode count, first seed, variant,
and game version. Each directory contains private `trajectories.jsonl` events
and `manifest.json`. The exporter refuses existing directories. Source versions
are diagnostic editions, not published package versions.

Convert event records using the shared Coworld SDK in Metta. Choose new output
paths and preserve the raw corpus and manifest:

```sh
nix develop -c uv run --package metta-posttrain python - <<'PY'
from pathlib import Path
from coworld.decision_trajectory import export_complete_episodes, read_trajectory_jsonl

for variant in ("ladder", "hard"):
    export_complete_episodes(
        read_trajectory_jsonl(Path(f"/tmp/sokoban-{variant}-events/trajectories.jsonl")),
        Path(f"/tmp/sokoban-{variant}-complete.jsonl"),
    )
PY
```

An independent reviewer must verify the exact source, private observations,
prompts, normal parsed and applied actions, and terminal engine outcomes.
The reviewer supplies `HostedImportAuthority` bound to the complete file's
SHA256. The game exporter cannot grant this authority. After review, import
one corpus using the reviewer-provided authority file:

```sh
nix develop -c uv run --package metta-posttrain python - <<'PY'
from pathlib import Path
from metta_posttrain.hosted import export_hosted
from metta_posttrain.hosted_receipts import HostedImportAuthority

export_hosted(
    Path("/tmp/sokoban-ladder-complete.jsonl"),
    Path("/tmp/sokoban-ladder-reviewed-dataset"),
    target_policy="pusher-private-view",
    authority=HostedImportAuthority.model_validate_json(
        Path("/tmp/sokoban-ladder-reviewed-authority.json").read_bytes()
    ),
)
PY
```

Repeat with the hard corpus and its own reviewed authority. The shared importer
owns train/validation splits by seed family. Never train directly from raw event
directories or create local modulo splits. Rejected and repaired proposals cannot
be accepted supervision. Scripted teachers have no model-serving metadata.
Model-derived labels additionally require authenticated platform receipts.

Use the resulting reviewed dataset as the training pipeline input. Its
`train.jsonl`, `validation.jsonl`, `manifest.json`, and `authority.json` preserve
label provenance and the reviewed split. Select the training command and model
profile from the current Metta post-training workflow; the historical
`python -m metta_posttrain.train` entrypoint is not maintained.

Historical CPU smoke results used an earlier exporter and ten-game profile:
344 tier-ladder labels changed validation loss from 1.7541 to 1.7477;
360 hard-ladder labels changed it from 1.7590 to 1.7526 after one update.
Those archived results lack a source revision recorded here. They do not qualify
the current source, reviewed importer, published runtime, or model strength.

# Numeric reinforcement learning

Compile the persistent bridge and pass the binary, manifest, and variant to
Metta's `recipes.external.coworld.train` (native PufferLib) or
`recipes.external.coworld_metta_rl.train` (Metta RL):

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/sokoban-train-bridge tools/train_bridge.nim
python tools/test_train_bridge.py /tmp/sokoban-train-bridge
```

Both certified ladders expose 274 numeric observation values from the hosted
player view: current board, dead squares, legal pushes, level progress, and
prior outcomes. Eight factorized action heads each choose stop, wait, or one
box-and-direction push. The native parser accepts every selected plan before
the simulator advances. The published pusher search policy supplies teacher
plans. Spectator text and private notes remain in the post-training path.

Sokoban has one seat, so the terminal result supplies its own utility. It maps
the native score to [-1, 1] using a fixed upper bound on the ladder score as
the denominator. Metta's single-seat utility support is required for numeric
training; a rank comparison has no opponent here.
