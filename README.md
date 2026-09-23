# solana-failover

A script to fail over a Solana validator's staked identity **away from the currently active node, onto its paired spare node**.

It is meant to be deployed identically on both nodes of an active/spare pair (with the `SELF_*`/`SPARE_*` config swapped between the two copies). You always run it on whichever node currently holds the staked identity — it detects this itself via gossip and refuses to run on the spare. Since roles flip after every failover, the same two script copies are used to fail over back and forth indefinitely; which node is "active" is never hardcoded, only which physical host each copy runs on.

## What it does

1. Confirms this host is the one currently active for the configured pubkey (checked via `solana gossip`). If it isn't, it exits immediately without touching anything.
2. Runs pre-flight checks: SSH reachability to the spare, the spare's RPC health, that all required directories/keypair/tower files actually exist on both nodes, and that the validator binary can be found on both sides.
3. Waits for a safe moment to switch identity — either the client's own restart-window check (agave) or a manual leader-schedule check (fd/firedancer) — so the switch doesn't happen mid-leader-slot.
4. Asks for confirmation, then:
   - Deactivates this node (symlinks its identity to a junk keypair, sets identity).
   - Copies the tower file to the spare.
   - Activates the spare (symlinks its identity to the staked keypair, sets identity).
   - Verifies the identity is now visible on the spare via gossip.

## Requirements

- The `solana` CLI installed and on `PATH` on both nodes.
- Passwordless SSH from the active node to the spare, as the configured user/port.
- `curl` available on the spare (used for its RPC health check).
- **The validator on both nodes must be started so that switching the identity symlink actually takes effect.** Typically that means launching with:
  ```
  --identity /home/sol/identity.json \
  --vote-account /home/sol/vote.json \
  --authorized-voter /home/sol/staked-identity.json
  ```
  where `--identity` points at the same path this script manages as `SELF_IDENTITY_KEYPAIR` / `SPARE_IDENTITY_KEYPAIR`.
- This script assumes the staked identity keypair already exists as a file on the spare node (`SPARE_STAKED_KEYPAIR`). It works by symlinking to that file, so a keyless setup (no keypair files on disk, authorized voter registered at runtime) is not supported.

## Configuration

All configuration lives in the `CONFIG` section near the top of the script. Edit it per-deployment before running.

| Variable | Purpose |
|---|---|
| `SSH_PORT` | SSH port used to reach the spare node. |
| `SSH_USER` | SSH user used to reach the spare node. |
| `SLOT_TIME_MS` | Current network slot time in milliseconds. Used to convert `SAFE_WINDOW_MINUTES` into a slot count for the fd/firedancer leader-slot check. |
| `SAFE_WINDOW_MINUTES` | Minutes before failover during which this validator must have no leader slot (fd/firedancer). For agave, passed as `--min-idle-time` to `wait-for-restart-window`. |
| `PUBKEY` | The validator identity pubkey being failed over. |
| `SELF_NAME` | Human-readable name for this host, used in log output. |
| `SELF_IP` | This host's IP. Used to detect whether this host is currently active (compared against gossip). Never changes, regardless of active/spare role. |
| `SELF_CLIENT` | This host's validator client: `fd`, `agave`, or `firedancer`. |
| `SELF_RPC_PORT` | This host's local RPC port. |
| `SELF_LEDGER_DIR` | This host's validator ledger directory. |
| `SELF_FD_CONFIG` | This host's firedancer `config.toml` path. Only needed if `SELF_CLIENT` is `fd`/`firedancer` — leave commented out otherwise (the example has it commented out since it uses `agave`). |
| `SELF_JUNK_KEYPAIR` | Full path to the junk (unstaked) keypair used to deactivate this host. |
| `SELF_IDENTITY_KEYPAIR` | Full path to the symlink this host's validator process reads its identity from. |
| `SPARE_NAME` | Human-readable name for the paired node. |
| `SPARE_IP` | The spare node's IP. Never changes, regardless of active/spare role. |
| `SPARE_RPC_PORT` | The spare node's RPC port (checked over SSH for health). |
| `SPARE_CLIENT` | The spare node's validator client: `fd`, `agave`, or `firedancer`. |
| `SPARE_LEDGER_DIR` | The spare node's validator ledger directory. |
| `SPARE_FD_CONFIG` | The spare node's firedancer `config.toml` path. Only needed if `SPARE_CLIENT` is `fd`/`firedancer` — leave commented out otherwise (the example has it commented out since it uses `agave`). |
| `SPARE_STAKED_KEYPAIR` | Full path to the staked keypair used to activate the spare. |
| `SPARE_IDENTITY_KEYPAIR` | Full path to the symlink the spare's validator process reads its identity from. |
| `CLUSTER` | `mainnet` or `testnet`. Selects a public fallback RPC, used only if the local RPC can't answer a leader-schedule/epoch-info query (e.g. firedancer not implementing `getLeaderSchedule`). Must match the actual cluster this pair runs on. |

`SOLANA_URL` is derived automatically from `SELF_RPC_PORT` and shouldn't need editing.

Filesystem paths and RPC ports are configured separately for `SELF` and `SPARE` since the two nodes aren't guaranteed to be laid out identically.

## Usage

Run on the node you believe is currently active:

```
./solana-failover.sh
```

It will detect whether this host is actually active, run pre-flight checks, show a summary, and ask for confirmation before making any changes.

Options:

- `-h`, `--help` — show usage and exit.
- `--force` — skip safety checks that would otherwise block or wait for the failover. Each check that would normally block still prints a warning explaining why, then proceeds anyway instead of stopping. Specifically it skips:
  - **fd/firedancer leader-slot safety window** — normally the script waits until this validator has no leader slot coming up within `SAFE_WINDOW_MINUTES`. With `--force`, it proceeds even if a leader slot is imminent.
  - **agave's `wait-for-restart-window`** — normally the script waits for `agave-validator wait-for-restart-window` to confirm it's safe to restart. With `--force`, this wait is skipped entirely.
  - **Spare node's RPC health check** — normally the failover aborts if the spare's RPC doesn't report healthy. With `--force`, it proceeds anyway.

  It does **not** skip SSH connectivity to the spare or the required-files/paths check — those are hard requirements regardless, since the failover can't functionally succeed without them.

  Use `--force` only when you're certain it's safe to proceed despite what it's bypassing — e.g. an emergency failover where waiting isn't an option.
