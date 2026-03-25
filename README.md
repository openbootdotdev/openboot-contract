# openboot-contract

Shared API contracts between [openboot](https://github.com/openbootdotdev/openboot) (Go CLI) and [openboot.dev](https://github.com/openbootdotdev/openboot.dev) (SvelteKit server).

## Why

The CLI is a binary on users' machines — it can't be updated instantly when the server changes. This repo defines the data shapes both sides agree on, and CI enforces they stay in sync.

## Structure

```
schemas/          JSON Schema definitions (source of truth)
  remote-config.json    GET /:user/:slug/config response
  snapshot.json         POST /api/configs/from-snapshot body
  packages.json         GET /api/packages response
  auth.json             CLI device auth flow

fixtures/         Example payloads that match the schemas
  config-v1.json
  snapshot-v1.json

golden-path/      End-to-end validation scripts
  test.sh               Full golden path: curl|bash + CLI dry-run + doctor (5 steps)
  contract-smoke.sh     Schema validation + live API format checks only
```

## How it works

1. **Contract changes** → PR to this repo → CI validates schemas + fixtures
2. **On merge** → CI triggers both consumer repos via `repository_dispatch`
3. **Consumer CI** → clones this repo, validates their responses against schemas
4. **Any mismatch** → CI fails → change must be coordinated across repos

## Local usage

```bash
# Prerequisites
pip install jsonschema          # for schema validation
cd ../openboot && make build    # build the CLI binary

# Full golden path (curl|bash + CLI dry-run + doctor)
# Spins up a mock server automatically
./golden-path/test.sh

# Schema + API format checks only
./golden-path/contract-smoke.sh

# Against a running local server
SERVER_URL=http://localhost:5173 ./golden-path/test.sh

# Against production
SERVER_URL=https://openboot.dev ./golden-path/contract-smoke.sh
```

## Rules

- **Only add fields, never remove** — CLI binaries in the wild depend on existing fields
- **Schema changes require a PR** — no direct pushes to main
- **Fixtures must always pass** — if you change a schema, update fixtures to match
