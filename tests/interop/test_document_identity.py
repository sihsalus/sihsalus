import copy
import json
from pathlib import Path
import unittest

from document_identity import DocumentIdentityError, assert_document_patient_identity


FIXTURES = Path(__file__).parent / "fixtures"


def positive():
    return json.loads((FIXTURES / "positive-corepe-document.json").read_text())


class DocumentPatientIdentityTests(unittest.TestCase):
    def assert_rejected(self, document, code):
        with self.assertRaises(DocumentIdentityError) as raised:
            assert_document_patient_identity(document)
        self.assertEqual(str(raised.exception), code)

    def test_accepts_urn_document_without_changing_any_data(self):
        document = positive()
        original = copy.deepcopy(document)
        assert_document_patient_identity(document)
        self.assertEqual(document, original)

    def test_rejects_relative_patient_references_in_every_subject_field(self):
        for index, field in ((0, "subject"), (4, "subject"), (5, "patient"), (6, "subject")):
            with self.subTest(index=index, field=field):
                document = positive()
                patient = document["entry"][1]["resource"]
                document["entry"][index]["resource"][field] = {"reference": "Patient/" + patient["id"]}
                self.assert_rejected(document, "identity_relative_reference_unsupported")

    def test_rejects_relative_reference_across_different_absolute_bases(self):
        document = positive()
        composition = document["entry"][0]
        patient = document["entry"][1]
        composition["fullUrl"] = "https://a.example.invalid/fhir/Composition/" + composition["resource"]["id"]
        patient["fullUrl"] = "https://b.example.invalid/fhir/Patient/" + patient["resource"]["id"]
        composition["resource"]["subject"] = {"reference": "Patient/" + patient["resource"]["id"]}
        self.assert_rejected(document, "identity_relative_reference_unsupported")

    def test_rejects_relative_reference_even_with_matching_absolute_base(self):
        document = positive()
        composition = document["entry"][0]
        patient = document["entry"][1]
        composition["fullUrl"] = "https://example.invalid/fhir/Composition/" + composition["resource"]["id"]
        patient["fullUrl"] = "https://example.invalid/fhir/Patient/" + patient["resource"]["id"]
        composition["resource"]["subject"] = {"reference": "Patient/" + patient["resource"]["id"]}
        self.assert_rejected(document, "identity_relative_reference_unsupported")

    def test_accepts_exact_absolute_full_urls(self):
        document = positive()
        entry = document["entry"][1]
        entry["fullUrl"] = "https://example.invalid/fhir/Patient/" + entry["resource"]["id"]
        for index, field in ((0, "subject"), (4, "subject"), (5, "patient"), (6, "subject")):
            document["entry"][index]["resource"][field] = {"reference": entry["fullUrl"]}
        assert_document_patient_identity(document)

    def test_compares_contained_resources_in_their_owner_scope(self):
        # Tests the identity rule only, not the CorePE Bundle cardinalities.
        document = positive()
        composition = document["entry"][0]["resource"]
        patient = document["entry"][1]["resource"]
        condition = document["entry"][4]["resource"]
        patient["id"] = "patient"
        condition["id"] = "condition"
        composition["contained"] = [patient, condition]
        composition["subject"] = {"reference": "#patient"}
        condition["subject"] = {"reference": "#patient"}
        document["entry"] = [document["entry"][0]]
        assert_document_patient_identity(document)

    def test_rejects_cross_patient_even_with_a_resolvable_contained_patient(self):
        document = json.loads((FIXTURES / "semantic-cross-patient.json").read_text())
        self.assert_rejected(document, "identity_patient_mismatch")

    def test_rejects_each_clinical_resource_for_another_patient(self):
        for index, field in ((4, "subject"), (5, "patient"), (6, "subject")):
            with self.subTest(field=field, index=index):
                document = positive()
                other = copy.deepcopy(document["entry"][1])
                other["fullUrl"] = "urn:uuid:30000000-0000-4000-8000-000000000003"
                other["resource"]["id"] = "other-patient"
                document["entry"].append(other)
                document["entry"][index]["resource"][field] = {"reference": other["fullUrl"]}
                self.assert_rejected(document, "identity_patient_mismatch")

    def test_rejects_missing_null_empty_or_identifier_only_subject(self):
        for reference in (None, {}, {"reference": ""}, {"reference": " "},
                          {"identifier": {"value": "DO-NOT-MATCH-IDENTIFIERS"}}):
            with self.subTest(reference=reference):
                document = positive()
                document["entry"][4]["resource"]["subject"] = reference
                self.assert_rejected(document, "identity_reference_required")

    def test_rejects_unresolved_reference_without_network(self):
        document = positive()
        document["entry"][4]["resource"]["subject"] = {
            "reference": "https://example.invalid/Patient/never-fetch"}
        self.assert_rejected(document, "identity_reference_unresolved")

    def test_rejects_wrong_resource_type(self):
        document = positive()
        document["entry"][4]["resource"]["subject"] = {
            "reference": document["entry"][2]["fullUrl"]}
        self.assert_rejected(document, "identity_reference_not_patient")

    def test_exact_full_urls_do_not_alias_same_resource_id_from_another_base(self):
        document = positive()
        patient = document["entry"][1]
        patient["fullUrl"] = "https://a.example.invalid/fhir/Patient/" + patient["resource"]["id"]
        for index, field in ((0, "subject"), (4, "subject"), (5, "patient"), (6, "subject")):
            document["entry"][index]["resource"][field] = {"reference": patient["fullUrl"]}
        duplicate = copy.deepcopy(document["entry"][1])
        duplicate["fullUrl"] = "https://b.example.invalid/fhir/Patient/" + duplicate["resource"]["id"]
        document["entry"].append(duplicate)
        # Only the SIHSALUS identity check is exercised here, not CorePE's
        # cardinality of exactly one top-level Patient in a Bundle.
        assert_document_patient_identity(document)
        document["entry"][4]["resource"]["subject"] = {"reference": duplicate["fullUrl"]}
        self.assert_rejected(document, "identity_patient_mismatch")

    def test_rejects_duplicate_full_url(self):
        document = positive()
        duplicate = copy.deepcopy(document["entry"][1])
        duplicate["resource"]["id"] = "another-id"
        document["entry"].append(duplicate)
        self.assert_rejected(document, "identity_alias_ambiguous")

    def test_rejects_missing_or_ambiguous_contained_reference(self):
        document = positive()
        resource = document["entry"][4]["resource"]
        resource["subject"] = {"reference": "#missing"}
        self.assert_rejected(document, "identity_contained_reference_unresolved")
        child = copy.deepcopy(document["entry"][1]["resource"])
        resource["contained"] = [child, copy.deepcopy(child)]
        self.assert_rejected(document, "identity_contained_alias_ambiguous")

    def test_rejects_non_document_or_missing_composition(self):
        document = positive()
        document["type"] = "collection"
        self.assert_rejected(document, "identity_document_required")
        document = positive()
        document["entry"] = document["entry"][1:]
        self.assert_rejected(document, "identity_single_composition_required")

    def test_rejects_history_full_url_instead_of_resolving_versions(self):
        document = positive()
        document["entry"][1]["fullUrl"] = "https://example.invalid/Patient/p/_history/1"
        self.assert_rejected(document, "identity_full_url_unsupported")


if __name__ == "__main__":
    unittest.main()
