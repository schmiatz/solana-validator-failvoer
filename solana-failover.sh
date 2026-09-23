#!/bin/bash
set -euo pipefail

#############################
### COLORS & FORMATTING #####
#############################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

#############################
### CONFIG ###################
#############################
# Everything you need to edit for this deployment lives here, up front.
# (CLUSTER is validated further down, after --help parsing, so a typo here
# doesn't prevent --help from working.)

SSH_PORT=22
SSH_USER="your-ssh-user"

SLOT_TIME_MS=200
# Minutes before failover during which this validator must have no leader
# slot (fd/firedancer safety wait; agave uses wait-for-restart-window instead).
SAFE_WINDOW_MINUTES=2

# This validator's vote account pubkey. The actual identity pubkey (PUBKEY)
# is NOT configured directly - it's derived from this at startup by looking
# up the vote account's currently-recognized validator identity on chain,
# then cross-checked against SELF_STAKED_KEYPAIR/SELF_JUNK_KEYPAIR below.
VOTE_PUBKEY="YOUR_VALIDATOR_VOTE_PUBKEY"

# CLIENT values: fd (fdctl), agave (agave-validator), firedancer (firedancer binary)
# SELF describes this host (wherever this script is deployed). SPARE describes
# the other node in the pair. Roles (active/spare) are NOT tied to these -
# whichever of the two currently holds the staked identity is "active", and
# that can flip after every failover; SELF_IP/SPARE_IP never change.
# RPC ports and filesystem paths are per-node since they are not guaranteed
# to match between the two hosts.

SELF_NAME="self-validator-name"
SELF_IP="0.0.0.0"
SELF_CLIENT="agave"
SELF_RPC_PORT=8899
SELF_LEDGER_DIR="/path/to/self/ledger"
# SELF_FD_CONFIG - only needed if SELF_CLIENT is "fd" or "firedancer". Not
# used here since SELF_CLIENT is "agave" in this example.
# SELF_FD_CONFIG="/path/to/self/firedancer-config.toml"
SELF_JUNK_KEYPAIR="/path/to/self/junk-identity-keypair.json"
SELF_STAKED_KEYPAIR="/path/to/self/staked-identity-keypair.json"
SELF_IDENTITY_KEYPAIR="/path/to/self/identity-keypair.json"

SPARE_NAME="spare-validator-name"
SPARE_IP="0.0.0.0"
SPARE_RPC_PORT=8899
SPARE_CLIENT="agave"
SPARE_LEDGER_DIR="/path/to/spare/ledger"
# SPARE_FD_CONFIG - only needed if SPARE_CLIENT is "fd" or "firedancer". Not
# used here since SPARE_CLIENT is "agave" in this example.
# SPARE_FD_CONFIG="/path/to/spare/firedancer-config.toml"
SPARE_STAKED_KEYPAIR="/path/to/spare/staked-identity-keypair.json"
SPARE_IDENTITY_KEYPAIR="/path/to/spare/identity-keypair.json"

SOLANA_URL="http://127.0.0.1:${SELF_RPC_PORT}"

# Cluster this pair runs on - "mainnet" or "testnet". Used only to pick a
# public fallback RPC for the leader-slot safety check (see solana_query),
# in case the local RPC can't answer (e.g. firedancer not implementing
# getLeaderSchedule). Must match the actual cluster this deployment is on.
CLUSTER="mainnet"

#############################
### LOGGING HELPERS #########
#############################
# Defined before argument parsing so --help and config errors can use them.

log_info()    { echo -e "${CYAN}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "\n${BOLD}>>> $*${NC}" >&2; }

#############################
### ARGUMENT PARSING ########
#############################
# Parsed before CLUSTER validation so --help always works, even if CONFIG
# has a mistake.

print_help() {
    cat <<EOF
Usage: $(basename "$0") [--force] [-h|--help]

Fails over this validator's staked identity to its paired spare node.
Must be run on the currently active node of the pair; if this host is
not active it exits immediately without making any changes.

Options:
  --force     Skip safety checks that would otherwise block or wait for
              the failover: the fd/firedancer leader-slot safety window,
              the agave wait-for-restart-window, and the spare node's RPC
              health check. Warnings are still printed for anything that
              would normally block, but the failover proceeds anyway.
              Use only when you are certain it is safe to proceed.
  -h, --help  Show this help message and exit.
EOF
}

FORCE=false
for arg in "$@"; do
    case "$arg" in
        --force)
            FORCE=true
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $arg"
            print_help
            exit 1
            ;;
    esac
done

#############################
### CLUSTER VALIDATION ######
#############################

case "$CLUSTER" in
    mainnet) FAILOVER_RPC_URL="https://api.mainnet.solana.com" ;;
    testnet) FAILOVER_RPC_URL="https://api.testnet.solana.com" ;;
    *)
        log_error "Unknown CLUSTER: $CLUSTER (expected 'mainnet' or 'testnet')"
        exit 1
        ;;
esac

#############################
### HELPER FUNCTIONS ########
#############################

run_ssh() {
    local ip="$1"
    shift
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p"$SSH_PORT" "${SSH_USER}@${ip}" "$@"
}

run_scp() {
    local src="$1"
    local dst="$2"
    scp -o ConnectTimeout=10 -P "$SSH_PORT" "$src" "$dst"
}

solana_query() {
    # Runs `solana "$@" -u <url>` against the local RPC, falling back to
    # FAILOVER_RPC_URL if the local RPC fails or doesn't support the call
    # (e.g. firedancer not implementing getLeaderSchedule).
    local output
    if output=$(solana "$@" -u "$SOLANA_URL" 2>&1); then
        echo "$output"
        return 0
    fi
    log_warn "Local RPC (${SOLANA_URL}) failed for 'solana $*':"
    log_warn "$output"
    log_warn "Falling back to ${FAILOVER_RPC_URL}..."

    if output=$(solana "$@" -u "$FAILOVER_RPC_URL" 2>&1); then
        echo "$output"
        return 0
    fi
    log_error "Failover RPC (${FAILOVER_RPC_URL}) also failed for 'solana $*':"
    log_error "$output"
    return 1
}

check_ssh_connectivity() {
    local ip="$1"
    local name="$2"
    log_info "Testing SSH to ${name} (${ip})..."
    if run_ssh "$ip" "echo ok" &>/dev/null; then
        log_success "SSH to ${name} OK"
        return 0
    else
        log_error "Cannot SSH to ${name} (${ip})"
        return 1
    fi
}

check_target_health() {
    local ip="$1"
    local name="$2"
    local rpc_port="$3"
    log_info "Checking RPC health on ${name} (${ip})..."
    local health
    health=$(run_ssh "$ip" "curl -s --max-time 3 http://127.0.0.1:${rpc_port}/health" 2>/dev/null || true)
    if [[ "$health" == "ok" ]]; then
        log_success "${name} RPC health OK"
        return 0
    else
        log_error "${name} RPC health check failed (got: '${health}')"
        return 1
    fi
}

derive_and_verify_identity() {
    # Derives the validator identity pubkey from the chain (via VOTE_PUBKEY's
    # currently-recognized validator identity) rather than trusting a
    # hardcoded config value, then cross-checks it against the local keypair
    # files: SELF_STAKED_KEYPAIR must match it, SELF_JUNK_KEYPAIR must not.
    # Prints the derived pubkey on stdout on success.
    local vote_pubkey="$1"

    log_info "Deriving validator identity from vote account ${vote_pubkey:0:8}..."
    local vote_json
    if ! vote_json=$(solana_query vote-account "$vote_pubkey" --output json-compact); then
        log_error "Failed to query vote account ${vote_pubkey}"
        return 1
    fi

    local chain_pubkey
    chain_pubkey=$(echo "$vote_json" | grep -oE '"validatorIdentity":"[^"]+"' | cut -d'"' -f4 || true)
    if [[ -z "$chain_pubkey" ]]; then
        log_error "Could not parse validatorIdentity from vote-account output"
        return 1
    fi
    log_success "Chain reports current validator identity: ${chain_pubkey}"

    # Local calls run plain (no bash -ic): PATH is already inherited from
    # the interactive shell this script itself was launched from, and
    # bash -ic here risks the process getting SIGTTIN/SIGTTOU-stopped by
    # the terminal (nested interactive bash fighting for job control while
    # not the foreground process of its pipeline). That's only a real
    # problem over SSH (a fresh, non-interactive session - see run_ssh
    # call sites), never for local invocations here.
    local staked_pubkey
    staked_pubkey=$(solana address -k "$SELF_STAKED_KEYPAIR" 2>/dev/null | tr -d '\r' || true)
    if [[ -z "$staked_pubkey" ]]; then
        log_error "Could not read pubkey from SELF_STAKED_KEYPAIR (${SELF_STAKED_KEYPAIR})"
        return 1
    fi

    local junk_pubkey
    junk_pubkey=$(solana address -k "$SELF_JUNK_KEYPAIR" 2>/dev/null | tr -d '\r' || true)
    if [[ -z "$junk_pubkey" ]]; then
        log_error "Could not read pubkey from SELF_JUNK_KEYPAIR (${SELF_JUNK_KEYPAIR})"
        return 1
    fi

    if [[ "$staked_pubkey" != "$chain_pubkey" ]]; then
        log_error "SELF_STAKED_KEYPAIR (${staked_pubkey}) does not match the chain-derived identity (${chain_pubkey})"
        log_error "Check SELF_STAKED_KEYPAIR and VOTE_PUBKEY are configured correctly for this pair"
        return 1
    fi

    if [[ "$junk_pubkey" == "$chain_pubkey" ]]; then
        log_error "SELF_JUNK_KEYPAIR (${junk_pubkey}) matches the staked identity - this must never be the case"
        return 1
    fi

    log_success "SELF_STAKED_KEYPAIR matches chain identity, SELF_JUNK_KEYPAIR correctly does not"
    echo "$chain_pubkey"
}

check_required_files() {
    local pubkey="$1"
    log_info "Checking required files and paths exist..."
    local ok=true

    if [[ ! -d "$SELF_LEDGER_DIR" ]]; then
        log_error "Missing local directory: ${SELF_LEDGER_DIR}"
        ok=false
    fi

    if [[ "$SELF_CLIENT" == "fd" || "$SELF_CLIENT" == "firedancer" ]]; then
        if [[ ! -f "$SELF_FD_CONFIG" ]]; then
            log_error "Missing local file: ${SELF_FD_CONFIG}"
            ok=false
        fi
    fi

    if [[ ! -f "$SELF_JUNK_KEYPAIR" ]]; then
        log_error "Missing local file: ${SELF_JUNK_KEYPAIR}"
        ok=false
    fi

    local self_identity_dir
    self_identity_dir=$(dirname -- "$SELF_IDENTITY_KEYPAIR")
    if [[ ! -d "$self_identity_dir" ]]; then
        log_error "Missing local directory: ${self_identity_dir} (needed for SELF_IDENTITY_KEYPAIR)"
        ok=false
    fi

    local tower_path="${SELF_LEDGER_DIR}/tower-1_9-${pubkey}.bin"
    if [[ ! -f "$tower_path" ]]; then
        log_error "Missing local tower file: ${tower_path}"
        ok=false
    fi

    if ! run_ssh "$SPARE_IP" "test -d ${SPARE_LEDGER_DIR}"; then
        log_error "Missing directory on ${SPARE_NAME}: ${SPARE_LEDGER_DIR}"
        ok=false
    fi

    if [[ "$SPARE_CLIENT" == "fd" || "$SPARE_CLIENT" == "firedancer" ]]; then
        if ! run_ssh "$SPARE_IP" "test -f ${SPARE_FD_CONFIG}"; then
            log_error "Missing file on ${SPARE_NAME}: ${SPARE_FD_CONFIG}"
            ok=false
        fi
    fi

    if ! run_ssh "$SPARE_IP" "test -f ${SPARE_STAKED_KEYPAIR}"; then
        log_error "Missing file on ${SPARE_NAME}: ${SPARE_STAKED_KEYPAIR}"
        ok=false
    else
        # bash -ic: a plain SSH command doesn't source .bashrc, where PATH
        # is typically set up for solana - same reasoning as
        # discover_binary_remote.
        local spare_staked_pubkey
        spare_staked_pubkey=$(run_ssh "$SPARE_IP" "bash -ic 'solana address -k ${SPARE_STAKED_KEYPAIR}'" 2>/dev/null | tr -d '\r' || true)
        if [[ -z "$spare_staked_pubkey" ]]; then
            log_error "Could not read pubkey from SPARE_STAKED_KEYPAIR on ${SPARE_NAME} (${SPARE_STAKED_KEYPAIR})"
            ok=false
        elif [[ "$spare_staked_pubkey" != "$pubkey" ]]; then
            log_error "SPARE_STAKED_KEYPAIR on ${SPARE_NAME} (${spare_staked_pubkey}) does not match the chain-derived identity (${pubkey})"
            ok=false
        fi
    fi

    local spare_identity_dir
    spare_identity_dir=$(dirname -- "$SPARE_IDENTITY_KEYPAIR")
    if ! run_ssh "$SPARE_IP" "test -d ${spare_identity_dir}"; then
        log_error "Missing directory on ${SPARE_NAME}: ${spare_identity_dir} (needed for SPARE_IDENTITY_KEYPAIR)"
        ok=false
    fi

    if [[ "$ok" == "false" ]]; then
        return 1
    fi
    log_success "All required files and paths present"
}

discover_binary_local() {
    local client="$1"
    local binary_name
    case "$client" in
        fd)         binary_name="fdctl" ;;
        agave)      binary_name="agave-validator" ;;
        firedancer) binary_name="firedancer" ;;
        *)          log_error "Unknown client type: $client"; return 1 ;;
    esac
    # Plain invocation, no bash -ic - see the comment in
    # derive_and_verify_identity for why that's risky for local calls.
    local path
    path=$(which "$binary_name" 2>/dev/null | tr -d '\r' || true)
    if [[ -z "$path" ]]; then
        log_error "Could not find $binary_name locally"
        return 1
    fi
    echo "$path"
}

discover_binary_remote() {
    local ip="$1"
    local client="$2"
    local binary_name
    case "$client" in
        fd)         binary_name="fdctl" ;;
        agave)      binary_name="agave-validator" ;;
        firedancer) binary_name="firedancer" ;;
        *)          log_error "Unknown client type: $client"; return 1 ;;
    esac
    local path
    path=$(run_ssh "$ip" "bash -ic 'which $binary_name 2>/dev/null; exit'" 2>/dev/null | grep -E '^/' | tail -1 | tr -d '\r' || true)
    if [[ -z "$path" ]]; then
        log_error "Could not find $binary_name on $ip"
        return 1
    fi
    echo "$path"
}

detect_active_ip() {
    local pubkey="$1"

    log_info "Querying gossip for identity ${pubkey:0:8}..."
    local gossip_line
    gossip_line=$(solana gossip -u "$SOLANA_URL" 2>/dev/null | grep "$pubkey" || true)

    if [[ -z "$gossip_line" ]]; then
        log_error "Pubkey $pubkey not found in gossip network"
        return 1
    fi

    # gossip output format: IP:PORT  PUBKEY  ...
    local gossip_ip
    gossip_ip=$(echo "$gossip_line" | awk '{print $1}' | cut -d: -f1)
    log_info "Gossip shows identity at IP: ${gossip_ip}"
    echo "$gossip_ip"
}

check_leader_slots() {
    local pubkey="$1"
    local window_slots=$(( SAFE_WINDOW_MINUTES * 60 * 1000 / SLOT_TIME_MS ))
    log_info "Checking leader schedule for a ${SAFE_WINDOW_MINUTES}m safe window (${window_slots} slots @ ${SLOT_TIME_MS}ms/slot)..."

    # The leader schedule is fixed for an entire epoch, so it's only fetched
    # once and reused across loop iterations - refetched only if we cross
    # into a new epoch while waiting. getSlot is cheap and supported by every
    # client's RPC, so that's the only thing polled every iteration.
    #
    # Separately, whether the safe window reaches into NEXT epoch is checked
    # every iteration too (cheap, local comparison, no RPC call unless a
    # merge is actually needed) rather than only at fetch time - a busy
    # validator can keep this loop waiting right up to an epoch boundary,
    # and the window can start reaching past it before current_slot itself
    # crosses it. Checking only at fetch time would miss a real slot just
    # over the boundary during that gap.
    local leader_slots=""
    local epoch_end_slot=-1
    local current_epoch=-1
    local next_epoch_merged=false

    while true; do
        # NOTE: each solana_query call's own success/failure (local RPC,
        # then failover RPC) is checked separately from whether it matched
        # anything. A failure on BOTH RPCs must hard-stop the failover here -
        # it must NEVER be treated as "no leader slots found" (safe).
        local current_slot
        if ! current_slot=$(solana_query slot); then
            log_error "Could not determine current slot"
            return 1
        fi
        local target_threshold=$((current_slot + window_slots))

        if [[ "$epoch_end_slot" -eq -1 || "$current_slot" -ge "$epoch_end_slot" ]]; then
            local schedule_raw
            if ! schedule_raw=$(solana_query leader-schedule); then
                log_error "Leader-slot safety check failed"
                return 1
            fi
            leader_slots=$(echo "$schedule_raw" | grep "$pubkey" | awk '{print $1}' || true)

            local epoch_json
            if ! epoch_json=$(solana_query epoch-info --output json-compact); then
                log_error "Leader-slot safety check failed"
                return 1
            fi
            local epoch slot_index slots_in_epoch
            epoch=$(echo "$epoch_json" | grep -oE '"epoch":[0-9]+' | grep -oE '[0-9]+' || true)
            slot_index=$(echo "$epoch_json" | grep -oE '"slotIndex":[0-9]+' | grep -oE '[0-9]+' || true)
            slots_in_epoch=$(echo "$epoch_json" | grep -oE '"slotsInEpoch":[0-9]+' | grep -oE '[0-9]+' || true)

            if [[ -z "$epoch" || -z "$slot_index" || -z "$slots_in_epoch" ]]; then
                log_error "Could not parse epoch boundary info from epoch-info output: $epoch_json"
                return 1
            fi

            local epoch_start_slot=$((current_slot - slot_index))
            epoch_end_slot=$((epoch_start_slot + slots_in_epoch))
            current_epoch="$epoch"
            next_epoch_merged=false

            log_info "Fetched leader schedule for epoch ${epoch} (valid until slot ${epoch_end_slot})"
        fi

        # If the safe window can extend past the end of the current epoch,
        # also merge in next epoch's schedule so we don't miss a slot there.
        # Next epoch's schedule is always determinable (stake is frozen one
        # epoch ahead of when it takes effect), so this is safe. Checked
        # every iteration (not just at fetch time) so a slot just past the
        # boundary can't slip through while we're still waiting.
        if [[ "$next_epoch_merged" == "false" && "$target_threshold" -ge "$epoch_end_slot" ]]; then
            local next_schedule_raw
            if ! next_schedule_raw=$(solana_query leader-schedule --epoch "$((current_epoch + 1))"); then
                log_error "Leader-slot safety check failed"
                return 1
            fi
            local next_epoch_slots
            next_epoch_slots=$(echo "$next_schedule_raw" | grep "$pubkey" | awk '{print $1}' || true)
            if [[ -n "$next_epoch_slots" ]]; then
                leader_slots="${leader_slots}"$'\n'"${next_epoch_slots}"
            fi
            next_epoch_merged=true
            log_info "Merged in next epoch's (${current_epoch}+1) leader schedule - window now reaches slot ${target_threshold}"
        fi

        local found_match=false
        local matched_slot=""
        while read -r slot; do
            [[ -z "$slot" ]] && continue
            if [[ "$slot" -gt "$current_slot" ]] && [[ "$slot" -lt "$target_threshold" ]]; then
                found_match=true
                matched_slot="$slot"
                break
            fi
        done <<< "$leader_slots"

        if [[ "$found_match" == "false" ]]; then
            log_success "No leader slots in next ${window_slots} slots (~${SAFE_WINDOW_MINUTES}m) - safe to proceed"
            break
        fi

        local slots_away=$((matched_slot - current_slot))
        local eta_seconds=$(( slots_away * SLOT_TIME_MS / 1000 ))

        if [[ "$FORCE" == "true" ]]; then
            log_warn "Leader slot $matched_slot is ${slots_away} slots away (~${eta_seconds}s)"
            log_warn "--force was used - proceeding with failover anyway"
            break
        fi

        log_warn "Leader slot $matched_slot is ${slots_away} slots away (~${eta_seconds}s) - waiting..."
        sleep 1
    done
}

junk_self() {
    local client="$1"
    local binary="$2"
    local pubkey="$3"

    log_step "Junking local node [${client}]"

    # Safety wait
    case "$client" in
        agave)
            if [[ "$FORCE" == "true" ]]; then
                log_warn "Skipping wait-for-restart-window - --force was used"
            else
                log_info "Waiting for restart window on agave node..."
                "$binary" -l "$SELF_LEDGER_DIR" wait-for-restart-window --min-idle-time "$SAFE_WINDOW_MINUTES" --skip-new-snapshot-check \
                    || { log_error "wait-for-restart-window failed"; return 1; }
            fi
            ;;
        fd|firedancer)
            check_leader_slots "$pubkey" \
                || { log_error "Leader-slot safety check failed"; return 1; }
            ;;
    esac

    # Symlink to junk identity
    log_info "Switching identity symlink to junk..."
    ln -sf "$SELF_JUNK_KEYPAIR" "$SELF_IDENTITY_KEYPAIR" \
        || { log_error "Failed to symlink junk identity locally"; return 1; }
    log_success "Symlink updated to junk identity"

    # Set identity
    log_info "Setting validator identity to junk..."
    case "$client" in
        agave)
            "$binary" -l "$SELF_LEDGER_DIR" set-identity "$SELF_IDENTITY_KEYPAIR" \
                || { log_error "set-identity failed locally"; return 1; }
            ;;
        fd|firedancer)
            "$binary" set-identity --config "$SELF_FD_CONFIG" "$SELF_IDENTITY_KEYPAIR" \
                || { log_error "set-identity failed locally"; return 1; }
            ;;
    esac
    log_success "Identity set to junk locally"
}

transfer_tower() {
    local to_ip="$1"
    local pubkey="$2"

    local tower_file="tower-1_9-${pubkey}.bin"
    local self_tower_path="${SELF_LEDGER_DIR}/${tower_file}"
    local spare_tower_path="${SPARE_LEDGER_DIR}/${tower_file}"

    log_step "Transferring tower file"
    log_info "Copying ${tower_file} to ${to_ip}..."
    run_scp "${self_tower_path}" "${SSH_USER}@${to_ip}:${spare_tower_path}" \
        || { log_error "Tower file transfer failed"; return 1; }
    log_success "Tower file transferred"
}

unjunk_remote() {
    local ip="$1"
    local client="$2"
    local binary="$3"

    log_step "Activating node at ${ip} [${client}]"

    # Symlink to staked identity
    log_info "Switching identity symlink to staked..."
    run_ssh "$ip" "ln -sf ${SPARE_STAKED_KEYPAIR} ${SPARE_IDENTITY_KEYPAIR}" \
        || { log_error "Failed to symlink staked identity on ${ip}"; return 1; }
    log_success "Symlink updated to staked identity"

    # Set identity
    log_info "Setting validator identity to staked..."
    case "$client" in
        agave)
            run_ssh "$ip" "$binary -l $SPARE_LEDGER_DIR set-identity ${SPARE_IDENTITY_KEYPAIR}" \
                || { log_error "set-identity failed on ${ip}"; return 1; }
            ;;
        fd|firedancer)
            run_ssh "$ip" "$binary set-identity --config $SPARE_FD_CONFIG ${SPARE_IDENTITY_KEYPAIR}" \
                || { log_error "set-identity failed on ${ip}"; return 1; }
            ;;
    esac
    log_success "Identity set to staked on ${ip}"
}

verify_failover() {
    local pubkey="$1"
    local expected_ip="$2"
    local expected_name="$3"

    log_step "Verifying failover"
    log_info "Waiting 10 seconds for gossip propagation..."
    sleep 10

    local gossip_ip
    gossip_ip=$(detect_active_ip "$pubkey" || true)

    if [[ -z "$gossip_ip" ]]; then
        log_warn "Pubkey not yet visible in gossip - may need more time to propagate"
        return 0
    fi

    if [[ "$gossip_ip" == "$expected_ip" ]]; then
        log_success "Verified: identity is now on ${expected_name} (${expected_ip})"
    else
        log_warn "Gossip shows IP ${gossip_ip} but expected ${expected_ip} - may need more time"
    fi
}

#############################
### MAIN ####################
#############################

echo -e "\n${BOLD}=== Solana Validator Failover (local) ===${NC}\n"
if [[ "$FORCE" == "true" ]]; then
    log_warn "--force enabled: safety checks may be skipped with a warning instead of blocking"
fi

# Determine which configured node this host is
log_step "Local host"
log_success "Running on: ${SELF_NAME} (${SELF_IP}) [${SELF_CLIENT}]"
log_info "Spare node:  ${SPARE_NAME} (${SPARE_IP}) [${SPARE_CLIENT}]"

# Derive and verify validator identity against chain before doing anything else
echo ""
log_step "Deriving and verifying validator identity"
PUBKEY=$(derive_and_verify_identity "$VOTE_PUBKEY") || exit 1

# Detect active node
echo ""
log_step "Detecting active node"
active_ip=$(detect_active_ip "$PUBKEY") || exit 1

if [[ "$active_ip" != "$SELF_IP" ]]; then
    echo ""
    log_error "This node (${SELF_NAME}) is not active."
    log_error "Active identity is currently on ${SPARE_NAME} (${active_ip})."
    exit 1
fi

log_success "This node (${SELF_NAME}) is active."

# Pre-flight checks
echo ""
log_step "Pre-flight checks"

check_ssh_connectivity "$SPARE_IP" "$SPARE_NAME" || exit 1

if ! check_target_health "$SPARE_IP" "$SPARE_NAME" "$SPARE_RPC_PORT"; then
    if [[ "$FORCE" == "true" ]]; then
        log_warn "${SPARE_NAME} failed its health check - --force was used, proceeding anyway"
    else
        exit 1
    fi
fi

check_required_files "$PUBKEY" || exit 1

log_info "Discovering binary locally (${SELF_CLIENT})..."
SELF_BINARY=$(discover_binary_local "$SELF_CLIENT") || exit 1
log_success "Local binary: ${SELF_BINARY}"

log_info "Discovering binary on spare node (${SPARE_CLIENT})..."
SPARE_BINARY=$(discover_binary_remote "$SPARE_IP" "$SPARE_CLIENT") || exit 1
log_success "Spare binary: ${SPARE_BINARY}"

# Confirmation
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  FAILOVER SUMMARY${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "  Pubkey:     ${PUBKEY}"
echo ""
echo -e "  ${RED}Deactivate:${NC} ${SELF_NAME} (${SELF_IP}) [${SELF_CLIENT}]  (this host)"
echo -e "  ${GREEN}Activate:${NC}   ${SPARE_NAME} (${SPARE_IP}) [${SPARE_CLIENT}]"
if [[ "$FORCE" == "true" ]]; then
    echo -e "  ${YELLOW}${BOLD}--force enabled${NC} - safety checks will be skipped with a warning instead of blocking"
fi
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""
read -rp "Proceed with failover? [y/N] " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Execute failover
echo ""
log_step "Starting failover"

# Phase A+B: Junk this (active) node
junk_self "$SELF_CLIENT" "$SELF_BINARY" "$PUBKEY" || exit 1

# Phase C: Transfer tower
transfer_tower "$SPARE_IP" "$PUBKEY" || exit 1

# Phase D: Unjunk the spare node
unjunk_remote "$SPARE_IP" "$SPARE_CLIENT" "$SPARE_BINARY" || exit 1

# Phase E: Verify
verify_failover "$PUBKEY" "$SPARE_IP" "$SPARE_NAME"

echo ""
echo -e "${GREEN}${BOLD}=== Failover complete ===${NC}"
echo -e "Identity moved: ${RED}${SELF_NAME}${NC} -> ${GREEN}${SPARE_NAME}${NC}"
