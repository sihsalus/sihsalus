#!/usr/bin/env bash

set +x
set -euo pipefail

umask 077

fail() {
  echo "[ocl-config] ERROR: $*" >&2
  exit 78
}

if [[ "$#" -eq 0 ]]; then
  CONFIGURATION_DIR="/openmrs/data/configuration"
  CHECKSUM_ROOT="/openmrs/data/configuration_checksums"
elif [[ "$#" -eq 2 ]]; then
  CONFIGURATION_DIR="$1"
  CHECKSUM_ROOT="$2"
else
  fail "expected either no arguments or the OpenMRS configuration and checksum directories"
fi

GLOBAL_PROPERTIES_DIR="${CONFIGURATION_DIR}/globalproperties"
CHECKSUM_DIR="${CHECKSUM_ROOT}/globalproperties"
OVERRIDE_NAME="zz-runtime-ocl-token"
OVERRIDE_FILE="${GLOBAL_PROPERTIES_DIR}/${OVERRIDE_NAME}.xml"
OVERRIDE_CHECKSUM="${CHECKSUM_DIR}/${OVERRIDE_NAME}.checksum"
OCL_TOKEN="${OMRS_OCL_TOKEN:-}"

if [[ -n "$OCL_TOKEN" && ! "$OCL_TOKEN" =~ ^[0-9a-f]{40}$ ]]; then
  fail "OMRS_OCL_TOKEN must be a raw 40-character lowercase hexadecimal OCL API token without an authorization prefix"
fi

case "$CONFIGURATION_DIR" in
  /*) ;;
  *) fail "the OpenMRS configuration directory must be an absolute path" ;;
esac
case "$CHECKSUM_ROOT" in
  /*) ;;
  *) fail "the OpenMRS checksum directory must be an absolute path" ;;
esac

mkdir -p "$GLOBAL_PROPERTIES_DIR"

# startup-init.sh copies the content package before this hook runs. Remove the
# unresolved token property from those copied XML files so Initializer can
# never persist the literal ${OMRS_OCL_TOKEN} placeholder. The dedicated
# runtime override below is the only supported file source for this property.
temporary_base=""
temporary_override=""

cleanup() {
  [[ -z "$temporary_base" ]] || rm -f "$temporary_base"
  [[ -z "$temporary_override" ]] || rm -f "$temporary_override"
}
trap cleanup EXIT

strip_ocl_property() {
  local source_file="$1"
  local target_file="$2"

  if ! awk '
    function reset_block() {
      block = ""
      in_block = 0
      is_ocl_property = 0
    }

    function finish_block() {
      if (!is_ocl_property) {
        printf "%s", block
      }
      reset_block()
    }

    BEGIN {
      reset_block()
      malformed = 0
      removed = 0
    }

    {
      if (!in_block) {
        if ($0 ~ /^[[:space:]]*<globalProperty>[[:space:]]*$/) {
          in_block = 1
          block = $0 ORS
        } else {
          print
        }
        next
      }

      block = block $0 ORS
      if (index($0, "<property>openconceptlab.token</property>") > 0) {
        is_ocl_property = 1
      }
      if ($0 ~ /^[[:space:]]*<\/globalProperty>[[:space:]]*$/) {
        if (is_ocl_property) {
          removed++
        }
        finish_block()
      }
    }

    END {
      if (in_block) {
        printf "%s", block
        malformed = 1
      }
      exit (malformed || removed != 1)
    }
  ' "$source_file" > "$target_file"; then
    fail "could not safely reconcile the copied global-properties XML"
  fi
}

managed_source=""
managed_occurrences=0
while IFS= read -r -d '' global_properties_file; do
  [[ "$global_properties_file" == "$OVERRIDE_FILE" ]] && continue

  occurrences="$(grep -Fc '<property>openconceptlab.token</property>' "$global_properties_file" || true)"
  if [[ "$occurrences" -gt 0 ]]; then
    managed_occurrences=$((managed_occurrences + occurrences))
    managed_source="$global_properties_file"
  elif grep -qF 'openconceptlab.token' "$global_properties_file" \
    || grep -qF '${OMRS_OCL_TOKEN}' "$global_properties_file"; then
    fail "an unresolved or unsupported OCL token property exists outside the managed format"
  fi
done < <(find "$GLOBAL_PROPERTIES_DIR" -type f -name '*.xml' -print0)

[[ "$managed_occurrences" -le 1 ]] \
  || fail "multiple file-based OCL token properties exist in the copied configuration"

if [[ "$managed_occurrences" -eq 1 ]]; then
  managed_source_dir="${managed_source%/*}"
  temporary_base="$(mktemp "${managed_source_dir}/.ocl-global-properties.XXXXXX")"
  strip_ocl_property "$managed_source" "$temporary_base"
  if grep -qF '<property>openconceptlab.token</property>' "$temporary_base" \
    || grep -qF '${OMRS_OCL_TOKEN}' "$temporary_base"; then
    fail "the copied OCL token property could not be removed safely"
  fi
  chmod 0600 "$temporary_base"
fi

if [[ -n "$OCL_TOKEN" ]]; then
  temporary_override="$(mktemp "${GLOBAL_PROPERTIES_DIR}/.${OVERRIDE_NAME}.XXXXXX")"
  # Initializer 2.12 orders global-properties XML by filename when no explicit
  # order exists, so the zz- override is applied after the content files.
  cat > "$temporary_override" <<EOF_XML
<config>
    <globalProperties>
        <globalProperty>
            <property>openconceptlab.token</property>
            <value>${OCL_TOKEN}</value>
        </globalProperty>
    </globalProperties>
</config>
EOF_XML
  chmod 0600 "$temporary_override"
fi

if [[ -n "$temporary_base" ]]; then
  mv -f "$temporary_base" "$managed_source"
  temporary_base=""
fi

if [[ -z "$OCL_TOKEN" ]]; then
  rm -f "$OVERRIDE_FILE"
  echo "[ocl-config] OMRS_OCL_TOKEN is empty; preserving any token already stored by OpenMRS"
  exit 0
fi

mv -f "$temporary_override" "$OVERRIDE_FILE"
temporary_override=""

# Initializer skips unchanged XML files. Removing only this checksum makes the
# runtime value authoritative on every boot, including token rotations and
# cases where another content file was reloaded in the same boot.
rm -f "$OVERRIDE_CHECKSUM"

echo "[ocl-config] configured the OCL API token from OMRS_OCL_TOKEN"
