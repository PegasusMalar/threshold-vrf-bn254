#!/usr/bin/env bash
# Rents the fleet from Google Cloud, for the rehearsal week.
#
#   ./script/gcp-fleet.sh create     # bring the machines up
#   ./script/gcp-fleet.sh firewall   # open the peer ports to the fleet only
#   ./script/gcp-fleet.sh json       # the operators.json fragment, ready to paste
#   ./script/gcp-fleet.sh destroy    # give it all back
#
# Deliberately not a Terraform module: these machines exist for a week, and the
# thing that has to survive is deployments/operators.json, not the tenancy.
#
# Indices start at 2 because operators 0 and 1 already run on OVH, and an index
# is bound to a DKG share — renumbering here would orphan a keystore.
set -euo pipefail
cd "$(dirname "$0")/.."

PREFIX=${PREFIX:-vrf}
FIRST=${FIRST:-2}
MACHINE=${MACHINE:-e2-micro}
DISK=${DISK:-pd-balanced}
FLEET=${FLEET:-deployments/operators.json}
SHARE_PORT=$(jq -r '.sharePort // 9100' "$FLEET" 2>/dev/null || echo 9100)
METRICS_PORT=$(jq -r '.metricsPort // 9600' "$FLEET" 2>/dev/null || echo 9600)

# Candidate zones, tried in order until COUNT machines stand. Spread is the
# point: the rehearsal exists to find out how the share exchange behaves across
# real inter-continental latency, which a single region would hide.
#
# It is a list of candidates rather than a list of assignments because a zone
# refusing a disk is routine, not exceptional — ZONE_RESOURCE_POOL_EXHAUSTED is
# a daily fact of a free-credit project, and it must not halt the run.
COUNT=${COUNT:-7}
ZONES=(
    us-central1-a
    us-east1-b
    us-west1-b
    europe-west1-b
    europe-west3-a
    europe-north1-a
    asia-southeast1-a
    europe-west2-c
    europe-west4-a
    europe-southwest1-a
    asia-northeast1-a
    us-east4-a
    northamerica-northeast1-a
    australia-southeast1-a
)

PUBKEY=${PUBKEY:-$HOME/.ssh/id_ed25519.pub}

die () { echo "!! $*" >&2; exit 1; }
command -v gcloud >/dev/null || die "gcloud not installed"
[ -f "$PUBKEY" ] || die "no public key at $PUBKEY"

name_of () { echo "$PREFIX-operator-$1"; }

# The login name comes from the part before the colon, so asking for "ubuntu"
# here is what keeps these boxes addressable the same way as the OVH ones.
ssh_metadata () { echo "ubuntu:$(cat "$PUBKEY")"; }

ips () {
    gcloud compute instances list \
        --filter="name~^$PREFIX-operator-" \
        --format="value(name,networkInterfaces[0].accessConfigs[0].natIP)" \
        | sort
}

case "${1:-}" in
create)
    META=$(mktemp); trap 'rm -f "$META"' EXIT
    ssh_metadata > "$META"

    # Which indices are missing, rather than how many exist: a fleet with a hole
    # in the middle — one machine deleted, or one zone that declined — is the
    # normal state of a resumed run, and counting would misplace every index
    # after the hole.
    last=$((FIRST + COUNT - 1))
    HAVE=$(ips | awk '{ n = split($1, a, "-"); print a[n] }')
    WANT=""
    for i in $(seq "$FIRST" "$last"); do
        echo "$HAVE" | grep -qx "$i" || WANT="$WANT $i"
    done
    [ -n "$WANT" ] || { echo "all $COUNT already up"; exit 0; }

    # Zones already occupied. Without this a resumed run walks the candidate
    # list from the top again and stacks the remainder onto the same few zones,
    # which silently costs exactly the geographic spread the list is for.
    USED=$(gcloud compute instances list --filter="name~^$PREFIX-operator-" \
        --format="value(zone)" | sort -u)

    for zone in "${ZONES[@]}"; do
        set -- $WANT
        [ $# -gt 0 ] || break
        echo "$USED" | grep -qx "$zone" && continue
        i=$1
        name=$(name_of "$i")
        echo "==> $name in $zone"
        # enable-oslogin=FALSE on purpose: OS Login rewrites the account name
        # per Google identity, and deploy-node.sh addresses ubuntu@host.
        if gcloud compute instances create "$name" \
            --zone="$zone" \
            --machine-type="$MACHINE" \
            --image-family=ubuntu-2404-lts-amd64 \
            --image-project=ubuntu-os-cloud \
            --boot-disk-size=20GB \
            --boot-disk-type="$DISK" \
            --metadata-from-file=ssh-keys="$META" \
            --metadata=enable-oslogin=FALSE \
            --labels=role=vrf-operator \
            --quiet 2>&1 | sed 's/^/    /'
        then
            shift; WANT="$*"
            USED="$USED
$zone"
        else
            echo "    $zone declined, trying the next one"
        fi
    done
    set -- $WANT
    [ $# -eq 0 ] || die "still missing:$WANT — re-run to keep trying"
    echo
    echo "give them a minute to boot, then: $0 firewall && $0 json"
    ;;

firewall)
    # Two rules, because the two ports are not the same kind of thing.
    #
    # The share port carries signature shares between operators and nothing
    # else; it is allow-listed in the node as well, and this is the second lock
    # on the same door. Every address in the fleet file plus everything just
    # created, recomputed from scratch each run, so a rule can never outlive the
    # machine it was cut for.
    SRC=$( { ips | awk '{print $2}'
             jq -r '.operators[].host' "$FLEET" 2>/dev/null || true
           } | grep -E '^[0-9.]+$' | sort -u | paste -sd, - )
    [ -n "$SRC" ] || die "no addresses to allow — create the machines first"
    echo "==> share port $SHARE_PORT from the fleet only: $SRC"
    gcloud compute firewall-rules delete "$PREFIX-shares" --quiet 2>/dev/null || true
    gcloud compute firewall-rules create "$PREFIX-shares" \
        --allow="tcp:$SHARE_PORT" \
        --source-ranges="$SRC" \
        --description="VRF operator share exchange" \
        --quiet | tail -1

    # Metrics are read-only counters and are meant to be read by anyone: the
    # status page cross-references all nine of them from the visitor's browser,
    # which is the only way an outsider can tell a live operator from a dead one
    # — a threshold signature does not say who signed it. Closing this port
    # would not harden anything, it would just make the fleet unauditable.
    echo "==> metrics port $METRICS_PORT open to the world"
    gcloud compute firewall-rules delete "$PREFIX-metrics" --quiet 2>/dev/null || true
    gcloud compute firewall-rules create "$PREFIX-metrics" \
        --allow="tcp:$METRICS_PORT" \
        --source-ranges=0.0.0.0/0 \
        --description="VRF operator metrics, public on purpose" \
        --quiet | tail -1
    ;;

json)
    # Printed, never written: operators.json holds the RPC keys, and clobbering
    # it from here would take them with it.
    ips | awk -v p="$FIRST" '
        BEGIN { print "  paste into deployments/operators.json, filling in .rpc:\n" }
        {
            split($1, a, "-"); idx = a[length(a)]
            printf "    { \"index\": %s, \"ssh\": \"ubuntu@%s\", \"host\": \"%s\", \"rpc\": \"\" },\n", idx, $2, $2
        }'
    ;;

destroy)
    NAMES=$(ips | awk '{print $1}')
    [ -n "$NAMES" ] || { echo "nothing to destroy"; exit 0; }
    echo "$NAMES"
    printf 'destroy these? [y/N] '; read -r yes
    [ "$yes" = "y" ] || exit 0
    for name in $NAMES; do
        zone=$(gcloud compute instances list --filter="name=$name" --format="value(zone)")
        gcloud compute instances delete "$name" --zone="$zone" --quiet
    done
    gcloud compute firewall-rules delete "$PREFIX-peers" --quiet 2>/dev/null || true
    ;;

*)
    die "usage: $0 create|firewall|json|destroy"
    ;;
esac
