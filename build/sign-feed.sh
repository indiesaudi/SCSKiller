#!/usr/bin/env bash
# Signs an update feed the way the app checks it (FeedTrust in src/SCSKiller.Core/App/Updates.cs, the same as
# tools/release-sign's sign), with openssl only: writes <feed>.sig, {"v":1,"channel","signed_at","feed_sha256","kid","sig"},
# sig = Ed25519 over "scskiller-feed-v1\n" + channel + "\n" + signed_at + "\n" + feed_sha256.
#
# Usage: build/sign-feed.sh <releases.<channel>.json> <channel> <kid>
#   the private key: FEED_KEY, the base64 32-byte Ed25519 seed (tools/release-sign keygen's key file, or
#   `openssl pkey -in key.pem -outform DER | tail -c 32 | base64`), never a file in the repo
#   <channel>: the feed's signed channel, stable-linux or stable-linux-arm64 for the Linux ones
set -euo pipefail
die() { echo "sign-feed: $*" >&2; exit 1; }
(($# == 3)) || die "usage: build/sign-feed.sh <releases.<channel>.json> <channel> <kid>"
feed=$1 channel=$2 kid=$3
[[ -f $feed ]] || die "no $feed"
[[ $(basename "$feed") == "releases.$channel.json" ]] || die "$feed isn't releases.$channel.json"
[[ -n ${FEED_KEY:-} ]] || die "FEED_KEY isn't set"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# a raw seed into PKCS#8 for openssl: the fixed Ed25519 header, then the 32 bytes
seed=$(printf %s "$FEED_KEY" | base64 -d | od -An -v -tx1 | tr -d ' \n')
((${#seed} == 64)) || die "FEED_KEY isn't a base64 32-byte seed"
printf '302e020100300506032b657004220420%s' "$seed" | xxd -r -p > "$tmp/key.der"
openssl pkey -inform DER -in "$tmp/key.der" -out "$tmp/key.pem" 2>/dev/null || die "FEED_KEY isn't an Ed25519 seed"

at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sha=$(openssl dgst -sha256 -r "$feed" | cut -d' ' -f1)
printf 'scskiller-feed-v1\n%s\n%s\n%s' "$channel" "$at" "$sha" > "$tmp/msg"
sig=$(openssl pkeyutl -sign -inkey "$tmp/key.pem" -rawin -in "$tmp/msg" | base64 | tr -d '\n')
# the signature checks with the key's own public half before it's written
openssl pkey -in "$tmp/key.pem" -pubout -out "$tmp/pub.pem"
printf %s "$sig" | base64 -d > "$tmp/sig.bin"
openssl pkeyutl -verify -pubin -inkey "$tmp/pub.pem" -rawin -in "$tmp/msg" -sigfile "$tmp/sig.bin" >/dev/null || die "the signature doesn't verify"
printf '{"v":1,"channel":"%s","signed_at":"%s","feed_sha256":"%s","kid":"%s","sig":"%s"}' "$channel" "$at" "$sha" "$kid" "$sig" > "$feed.sig"
echo "signed $(basename "$feed") as $channel with $kid ($(openssl pkey -in "$tmp/key.pem" -pubout -outform DER | tail -c 32 | base64))"
