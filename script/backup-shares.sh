#!/usr/bin/env bash
# Collects every operator's secrets into one encrypted archive.
#
#   FLEET=deployments/operators.mainnet.json ./script/backup-shares.sh
#
# Read this before running it.
#
# The archive contains all nine DKG shares. Five of them reconstruct the group
# secret, and the group secret signs any seed the deployed verifier will accept
# as genuine randomness. So this file is not a backup of the key — it *is* the
# key, and everything the networked ceremony was for is undone the moment it
# exists.
#
# It is still the right thing to make here, and the reason is specific: seven of
# the nine machines run on expiring cloud credit that can be withdrawn without
# notice. Losing five shares at once puts the group below its threshold, and
# below threshold there is no resharing and no recovery — the mainnet verifier
# is dead for good and every integration has to move to a new address. Against
# that, a file that must be guarded like a master key is the smaller loss.
#
# It stops being the right thing the moment the fleet is on permanent servers
# run by people who are not each other. Then this archive is the single point of
# failure the whole design exists to remove, and it should be destroyed rather
# than kept — see the note the script writes beside it.
set -euo pipefail
cd "$(dirname "$0")/.."

FLEET=${FLEET:-deployments/operators.mainnet.json}
OUT=${OUT:-$HOME/Desktop/vrf-operator-backup}
CEREMONY_DIR=${CEREMONY_DIR:-/tmp/vrf-ceremony}

die () { echo "!! $*" >&2; exit 1; }
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20"
[ -f "$FLEET" ] || die "no $FLEET"

STAMP=$(date +%Y%m%d-%H%M%S)
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
umask 077

echo "==> collecting from $(jq -r '.operators | length' "$FLEET") servers"
for i in $(jq -r '.operators | sort_by(.index)[] | .index' "$FLEET"); do
    t=$(jq -r --argjson i "$i" '.operators[] | select(.index==$i) | .ssh' "$FLEET")
    d="$STAGE/operator-$i"; mkdir -p "$d"

    # Each piece fetched separately, so a partial failure is visible rather than
    # leaving a quietly incomplete archive that looks like insurance.
    $SSH "$t" 'sudo -n cat /var/lib/vrfnode/keystore.json' > "$d/keystore.json" \
        || die "no keystore on $t"
    $SSH "$t" "sudo -n grep '^VRF_KEYSTORE_PASSPHRASE=' /etc/vrfnode/secrets.env | cut -d= -f2-" \
        > "$d/keystore-passphrase.txt" || die "no keystore passphrase on $t"
    $SSH "$t" "sudo -n grep '^VRF_ETH_PRIVATE_KEY=' /etc/vrfnode/secrets.env | cut -d= -f2-" \
        > "$d/publishing-key.txt" || die "no publishing key on $t"
    $SSH "$t" 'sudo -n cat /etc/vrfnode/address' > "$d/address.txt" || true

    for f in keystore.json keystore-passphrase.txt publishing-key.txt; do
        [ -s "$d/$f" ] || die "operator $i produced an empty $f"
    done
    printf '  %s ' "$i"
done
echo

cp "$FLEET" "$STAGE/fleet.json"
[ -f .mainnet/ceremony.json ] && cp .mainnet/ceremony.json "$STAGE/ceremony.json"
[ -f deployments/mainnet.json ] && cp deployments/mainnet.json "$STAGE/mainnet.json"

cat > "$STAGE/READ-ME-FIRST.txt" <<NOTE
This archive contains all nine DKG shares of the Robinhood Chain mainnet
deployment, together with the passphrase that decrypts each one.

Five of them reconstruct the group secret. The group secret signs any seed, and
the deployed VRFVerifier accepts that signature as genuine randomness. Anyone
holding this file can therefore decide the outcome of every request the service
will ever serve, and nothing on chain would look wrong.

Treat it as the master key, because it is one:
  - keep it offline, not in cloud storage, email or a chat;
  - keep the passphrase somewhere other than beside the archive;
  - do not copy it to a machine you do not control.

Why it exists: seven of the nine operators run on expiring cloud credit that can
be withdrawn without warning. If five shares disappear at once the group falls
below its 5-of-9 threshold, resharing becomes impossible, and the mainnet
verifier is permanently dead — every integration would have to move to a new
address. This file is insurance against exactly that.

Destroy it when the fleet moves to permanent servers. At that point resharing is
the recovery mechanism, it needs only five live nodes, and keeping this around
would reintroduce the single point of failure the threshold scheme exists to
remove.

Recovering one operator onto a new server:
  1. put keystore.json at /var/lib/vrfnode/keystore.json (root:vrf, mode 640)
  2. put VRF_KEYSTORE_PASSPHRASE and VRF_ETH_PRIVATE_KEY into
     /etc/vrfnode/secrets.env (root, mode 600)
  3. redeploy that index with KEYSTORE_ON_SERVER=1

Taken $STAMP.
NOTE

mkdir -p "$OUT"
ARCHIVE="$OUT/vrf-shares-$STAMP.tar.gz.enc"
PASSFILE="$OUT/PASSPHRASE-$STAMP.txt"

# Generated rather than chosen, and written to its own file rather than printed:
# a passphrase echoed to a terminal lives on in scrollback and in whatever is
# reading that terminal.
openssl rand -base64 32 > "$PASSFILE"
tar -czf - -C "$STAGE" . \
    | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass "file:$PASSFILE" \
    > "$ARCHIVE"
chmod 600 "$ARCHIVE" "$PASSFILE"

echo "==> $ARCHIVE"
echo "    $PASSFILE"
echo
echo "Move the passphrase into a password manager, then delete that file."
echo "Keep the archive offline. To open it:"
echo "  openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \\"
echo "    -in <archive> -pass file:<passphrase-file> | tar -xzf -"
