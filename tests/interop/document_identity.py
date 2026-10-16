"""A narrow SIHSALUS safety check, separate from official FHIR validation.

Resolve only exact absolute fullUrl/URN references or #id in an already assembled
document. Relative references are unsupported. No network, identifier matching,
version resolution, or rewriting of clinical data is permitted.
"""

from urllib.parse import urlsplit


class DocumentIdentityError(ValueError):
    """Machine-only failure code; never include document data in diagnostics."""


SUBJECT_FIELDS = {
    "Condition": "subject",
    "AllergyIntolerance": "patient",
    "MedicationStatement": "subject",
}


def _require(condition, code):
    if not condition:
        raise DocumentIdentityError(code)


def _nonempty(value):
    return isinstance(value, str) and bool(value) and value == value.strip()


def assert_document_patient_identity(bundle):
    """Require every supported clinical resource to reference the document patient.

    Supported references: exact absolute fullUrl/URN and #id in the current
    containing resource. Relative references fail closed: this check does not
    implement FHIR base URL resolution. It does not replace profile validation.
    """
    _require(isinstance(bundle, dict) and bundle.get("resourceType") == "Bundle"
             and bundle.get("type") == "document", "identity_document_required")
    entries = bundle.get("entry")
    _require(isinstance(entries, list) and entries, "identity_entries_required")
    aliases = {}
    resources = []
    compositions = []

    def add_alias(alias, resource):
        _require(_nonempty(alias), "identity_alias_invalid")
        _require(alias not in aliases, "identity_alias_ambiguous")
        aliases[alias] = resource

    def contained_resources(container):
        children = container.get("contained", [])
        _require(isinstance(children, list), "identity_contained_invalid")
        result = {}
        for child in children:
            _require(isinstance(child, dict) and _nonempty(child.get("resourceType"))
                     and _nonempty(child.get("id")), "identity_contained_invalid")
            _require(not child.get("contained"), "identity_nested_contained_unsupported")
            _require(child["id"] not in result, "identity_contained_alias_ambiguous")
            result[child["id"]] = child
        return result

    for entry in entries:
        _require(isinstance(entry, dict), "identity_entry_invalid")
        resource = entry.get("resource")
        _require(isinstance(resource, dict) and _nonempty(resource.get("resourceType")),
                 "identity_resource_required")
        full_url = entry.get("fullUrl")
        _require(_nonempty(full_url), "identity_full_url_required")
        parsed = urlsplit(full_url)
        _require(parsed.scheme in ("urn", "http", "https") and not parsed.fragment
                 and not parsed.query and "/_history/" not in parsed.path,
                 "identity_full_url_unsupported")
        add_alias(full_url, resource)
        if "id" in resource:
            _require(_nonempty(resource["id"]) and "/" not in resource["id"]
                     and "#" not in resource["id"], "identity_resource_id_invalid")
        children = contained_resources(resource)
        resources.append((resource, children))
        resources.extend((child, children) for child in children.values())
        if resource["resourceType"] == "Composition":
            compositions.append((resource, children))

    _require(len(compositions) == 1, "identity_single_composition_required")

    def resolve(reference, children):
        _require(isinstance(reference, dict) and _nonempty(reference.get("reference")),
                 "identity_reference_required")
        target = reference["reference"]
        if target.startswith("#"):
            _require(len(target) > 1 and target[1:] in children,
                     "identity_contained_reference_unresolved")
            result = children[target[1:]]
        else:
            try:
                scheme = urlsplit(target).scheme
            except ValueError:
                raise DocumentIdentityError("identity_reference_unresolved") from None
            _require(scheme, "identity_relative_reference_unsupported")
            _require(target in aliases, "identity_reference_unresolved")
            result = aliases[target]
        _require(result.get("resourceType") == "Patient", "identity_reference_not_patient")
        return result

    composition, children = compositions[0]
    patient = resolve(composition.get("subject"), children)
    for resource, children in resources:
        field = SUBJECT_FIELDS.get(resource["resourceType"])
        if field:
            _require(resolve(resource.get(field), children) is patient,
                     "identity_patient_mismatch")
