# Metta post-training data

The maintained native simulator and its bounded `pusher` search policy can
produce supervised fine-tuning examples without a model provider:

```sh
nimby sync nimby.lock
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/sokoban-posttrain 10
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/sokoban-hard-posttrain 10 0 hard
```

The exporter covers the certified tier and hard ladder variants. It runs
complete seeded six-level games. Every row contains the
system prompt used by the hosted game, the full player-visible observation,
and a search-policy action that round-trips through the game's reply parser.
Train and validation split by episode seed, so turns from one game cannot
cross splits. `manifest.json` records the source revision, teacher, per-seed
scores and solved levels, and row counts. The exporter refuses to overwrite
an existing output directory.

From Metta, train the shared post-training pipeline on the resulting JSONL:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/sokoban-posttrain \
  --output /tmp/sokoban-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 2048
```

This dataset distills the scripted search teacher. It does not claim that a
model found a plan, that a rejected reply was accepted, or that a higher
league score will follow. The exported prompts contain only the observation
the search policy received; episode seeds and later levels stay hidden.

A local 10-game tier-ladder proof exported 274 train and 60 validation examples. All 334
fit a 2048-token smoke model; one CPU optimizer update reduced validation
loss from 1.7506 to 1.7441. The 10 games solved 1–4 levels each.
The hard ladder exported 277 train and 80 validation examples from 10 games.
All 357 fit the same model; one CPU update reduced validation loss from
1.7513 to 1.7449.
