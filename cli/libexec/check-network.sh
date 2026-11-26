#!/usr/bin/env bash
# Setup step 2: does pod staging answer, is it the right chain, and is it open for writes?
# Run as: pod setup network

source "$(dirname "$0")/lib.sh"

status=$(rest /clob/status) || fail network "Pod staging does not answer at $POD_REST." "Try again later."
require_staging
state=$(rpc_result pod_status '[]') || fail network "Pod did not answer pod_status." "Try again later."

read_only=$(echo "$state" | jq '.read_only')
paused=$(echo "$state" | jq '.paused')

jq -n --arg name "$STAGING_NAME" --argjson chain "$STAGING_CHAIN_ID" \
  --argjson ro "$read_only" --argjson paused "$paused" \
  --argjson now "$(echo "$status" | jq '.solution_now')" '
  {ok: true, network: $name, chain_id: $chain, read_only: $ro, paused: $paused,
   writes_open: (($ro | not) and ($paused | not)), solution_now: $now}
  + (if $ro or $paused then {note: "Pod is paused or read-only right now, so nothing can be sent. Reading still works."} else {} end)'
