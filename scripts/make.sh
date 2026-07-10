#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP="$ROOT/hello.go"
STAGING="$ROOT/manual-layer-rootfs"
LAYOUT="$ROOT/manual-oci"
BUNDLE="$ROOT/manual-bundle"

LAYER_TAR="$ROOT/layer.tar"
LAYER_GZIP="$ROOT/layer.tar.gz"
IMAGE_CONFIG="$ROOT/image-config.json"
MANIFEST="$ROOT/manifest.json"

REF="manual-image"
CONTAINER_ID="manual-image-container"

make_app() {
    rm -rf "$STAGING"
    mkdir -p "$STAGING/bin" "$STAGING/etc"

    CGO_ENABLED=0 go build \
        -o "$STAGING/bin/hello" \
        "$APP"

    printf '%s\n' \
        'this file came from the manually created filesystem layer' \
        > "$STAGING/etc/image-message.txt"

    find "$STAGING" -maxdepth 3 -print | sort
}

make_image() {
    make_app

    rm -rf "$LAYOUT"
    rm -f "$LAYER_TAR" "$LAYER_GZIP" "$IMAGE_CONFIG" "$MANIFEST"

    mkdir -p "$LAYOUT/blobs/sha256"

    tar \
        --sort=name \
        --mtime='UTC 1970-01-01' \
        --owner=0 \
        --group=0 \
        --numeric-owner \
        -C "$STAGING" \
        -cf "$LAYER_TAR" \
        .

    gzip -n -c "$LAYER_TAR" > "$LAYER_GZIP"

    local diff_id
    local layer_digest
    local layer_hex
    local layer_size

    diff_id="sha256:$(sha256sum "$LAYER_TAR" | awk '{print $1}')"
    layer_digest="sha256:$(sha256sum "$LAYER_GZIP" | awk '{print $1}')"
    layer_hex="${layer_digest#sha256:}"
    layer_size="$(stat -c '%s' "$LAYER_GZIP")"

    cp "$LAYER_GZIP" "$LAYOUT/blobs/sha256/$layer_hex"

    printf '%s\n' \
        '{"imageLayoutVersion":"1.0.0"}' \
        > "$LAYOUT/oci-layout"

    jq -n \
        --arg diff_id "$diff_id" \
        '{
            architecture: "amd64",
            os: "linux",
            config: {
                Env: [
                    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                ],
                Cmd: ["/bin/hello"],
                WorkingDir: "/"
            },
            rootfs: {
                type: "layers",
                diff_ids: [$diff_id]
            }
        }' > "$IMAGE_CONFIG"

    local config_digest
    local config_hex
    local config_size

    config_digest="sha256:$(sha256sum "$IMAGE_CONFIG" | awk '{print $1}')"
    config_hex="${config_digest#sha256:}"
    config_size="$(stat -c '%s' "$IMAGE_CONFIG")"

    cp "$IMAGE_CONFIG" "$LAYOUT/blobs/sha256/$config_hex"

    jq -n \
        --arg config_digest "$config_digest" \
        --argjson config_size "$config_size" \
        --arg layer_digest "$layer_digest" \
        --argjson layer_size "$layer_size" \
        '{
            schemaVersion: 2,
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            config: {
                mediaType: "application/vnd.oci.image.config.v1+json",
                digest: $config_digest,
                size: $config_size
            },
            layers: [
                {
                    mediaType: "application/vnd.oci.image.layer.v1.tar+gzip",
                    digest: $layer_digest,
                    size: $layer_size
                }
            ]
        }' > "$MANIFEST"

    local manifest_digest
    local manifest_hex
    local manifest_size

    manifest_digest="sha256:$(sha256sum "$MANIFEST" | awk '{print $1}')"
    manifest_hex="${manifest_digest#sha256:}"
    manifest_size="$(stat -c '%s' "$MANIFEST")"

    cp "$MANIFEST" "$LAYOUT/blobs/sha256/$manifest_hex"

    jq -n \
        --arg manifest_digest "$manifest_digest" \
        --argjson manifest_size "$manifest_size" \
        --arg ref "$REF" \
        '{
            schemaVersion: 2,
            mediaType: "application/vnd.oci.image.index.v1+json",
            manifests: [
                {
                    mediaType: "application/vnd.oci.image.manifest.v1+json",
                    digest: $manifest_digest,
                    size: $manifest_size,
                    platform: {
                        architecture: "amd64",
                        os: "linux"
                    },
                    annotations: {
                        "org.opencontainers.image.ref.name": $ref
                    }
                }
            ]
        }' > "$LAYOUT/index.json"

    umoci ls --layout "$LAYOUT"

    skopeo inspect "oci:$LAYOUT:$REF" \
        | jq '{Digest, Architecture, Os, Layers}'
}

unpack_image() {
    make_image

    rm -rf "$BUNDLE"

    umoci unpack \
        --rootless \
        --image "$LAYOUT:$REF" \
        "$BUNDLE"

    jq \
        '.process.args, .root.path, .linux.namespaces' \
        "$BUNDLE/config.json"
}

run_container() {
    unpack_image

    runc delete --force "$CONTAINER_ID" >/dev/null 2>&1 || true

    (
        cd "$BUNDLE"
        runc --rootless=true run "$CONTAINER_ID"
    )
}

clean() {
    runc delete --force "$CONTAINER_ID" >/dev/null 2>&1 || true

    rm -rf \
        "$STAGING" \
        "$LAYOUT" \
        "$BUNDLE"

    rm -f \
        "$LAYER_TAR" \
        "$LAYER_GZIP" \
        "$IMAGE_CONFIG" \
        "$MANIFEST"
}

case "${1:-}" in
    app)
        make_app
        ;;
    image)
        make_image
        ;;
    unpack-image)
        unpack_image
        ;;
    run-container)
        run_container
        ;;
    clean)
        clean
        ;;
    *)
        printf 'usage: %s {app|image|unpack-image|run-container|clean}\n' "$0" >&2
        exit 1
        ;;
esac
