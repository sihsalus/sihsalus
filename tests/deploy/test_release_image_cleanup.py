"""Image retention contracts, without Docker or network access."""

from copy import deepcopy
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from contextlib import ExitStack

from test_release_manifest import digest, fixture


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("cleanup", ROOT / "scripts/deploy/cleanup-release-images.py")
cleanup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cleanup)
NOW = datetime(2026, 10, 15, tzinfo=timezone.utc)
CUTOFF = datetime(2026, 10, 12, tzinfo=timezone.utc)


def release(name, date):
    result = fixture(name)
    result["createdAt"] = date + "T00:00:00Z"
    return result


class RetentionTests(unittest.TestCase):
    def test_docker_hub_digest_aliases_match_manifest_references(self):
        suffix = "@" + digest("alpine")
        for alias in ("alpine", "alpine:3", "library/alpine", "docker.io/alpine", "index.docker.io/library/alpine"):
            self.assertEqual(cleanup.normalize(alias + suffix), "docker.io/library/alpine" + suffix)
        self.assertEqual(cleanup.normalize("localhost:5000/team/image:tag" + suffix), "localhost:5000/team/image" + suffix)

    def test_count_is_a_floor_even_when_every_release_is_old(self):
        history = {str(i): release(str(i), f"2026-09-{i:02}") for i in range(1, 6)}
        self.assertEqual(cleanup.retained_releases(history, "5", 3, 2, NOW), {"4", "5"})

    def test_recent_releases_and_active_rollback_survive_count_limit(self):
        history = {str(i): release(str(i), f"2026-10-{i:02}") for i in range(10, 16)}
        self.assertEqual(cleanup.retained_releases(history, "10", 3, 2, NOW), {"10", "12", "13", "14", "15"})

    def setUp(self):
        self.old = release("old", "2026-10-01")
        self.current = release("current", "2026-10-14")
        self.history = {"old": self.old, "current": self.current}
        self.image_id = self.old["services"]["frontend"]["imageId"]
        self.images = {self.image_id: {"id": self.image_id, "created": "2026-10-01T00:00:00Z",
                                      "tags": ["sihsalus-release-retained:old-frontend"], "digests": []}}

    def plan(self, prepared=None, used=None):
        return cleanup.plan_images(self.images, self.history, {"current"}, prepared or [], used or set(), CUTOFF)

    def test_old_unused_image_is_eligible(self):
        self.assertEqual([item["id"] for item in self.plan()], [self.image_id])

    def test_untagged_image_referenced_by_expired_manifest_is_eligible(self):
        self.images[self.image_id]["tags"] = []
        self.assertEqual([item["id"] for item in self.plan()], [self.image_id])

    def test_any_container_including_stopped_protects_its_image(self):
        self.assertEqual(self.plan(used={self.image_id}), [])

    def test_image_shared_with_retained_release_is_preserved(self):
        self.current["services"]["frontend"] = deepcopy(self.old["services"]["frontend"])
        self.assertEqual(self.plan(), [])

    def test_prepared_manifest_protects_old_source_and_wrapper(self):
        self.assertEqual(self.plan(prepared=[self.old]), [])

    def test_prepared_tag_protects_image_without_staging_manifest(self):
        self.images[self.image_id]["tags"].append("sihsalus-frontend-prepared:qlty-candidate")
        self.assertEqual(self.plan(), [])

    def test_unknown_owner_tag_prevents_deletion(self):
        self.images[self.image_id]["tags"].append("another-project:important")
        self.assertEqual(self.plan(), [])

    def test_image_built_recently_is_preserved_despite_old_manifest(self):
        self.images[self.image_id]["created"] = "2026-10-14T23:00:00.123456789Z"
        self.assertEqual(self.plan(), [])

    def test_unmanaged_old_images_are_not_global_prune_candidates(self):
        self.images[digest("unrelated")] = {"id": digest("unrelated"), "tags": ["sihsalus-test:old"],
                                            "digests": [], "created": "2026-01-01T00:00:00Z"}
        self.assertEqual(len(self.plan()), 1)

    def test_tagged_digest_resolves_to_docker_repository_digest(self):
        source = self.old["sources"]["frontend"]["image"]
        source_id = digest("source")
        self.images[source_id] = {"id": source_id, "tags": [], "digests": [cleanup.normalize(source)],
                                  "created": "2026-10-01T00:00:00Z"}
        self.current["sources"]["frontend"]["image"] = source
        self.assertEqual([item["id"] for item in self.plan()], [self.image_id])


class CleanupExecutionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name) / "sihsalus"
        self.root.mkdir()
        self.state = self.root / ".env.release-state"
        self.state.mkdir(mode=0o700)
        self.release = cleanup.load_release(ROOT)
        self.old = release("old", "2020-01-01")
        self.previous = release("previous", "2020-01-02")
        self.current = release("current", "2020-01-03")
        self.images = {}
        for manifest in (self.old, self.previous, self.current):
            key = self.release.manifest_digest(manifest)
            self.release.write_new(self.state / (key + ".json"), manifest)
            for name, artifact in manifest["services"].items():
                image_id = artifact["imageId"]
                self.images[image_id] = {"id": image_id, "created": "2020-01-01T00:00:00Z",
                                        "tags": [f"sihsalus-release-retained:{key[:48]}-{name}"],
                                        "digests": [cleanup.normalize(artifact["image"])] if "@" in artifact["image"] else []}
            source = manifest["sources"]["frontend"]["image"]
            image_id = digest(source)
            self.images[image_id] = {"id": image_id, "created": "2020-01-01T00:00:00Z",
                                    "tags": [f"sihsalus-release-retained:{key[:48]}-source-frontend"],
                                    "digests": [cleanup.normalize(source)]}
        selected = self.state / (self.release.manifest_digest(self.current) + ".json")
        (self.root / ".env").write_text("SIHSALUS_RELEASE_MANIFEST=" + str(selected) + "\n")
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(self.release, "verify_selected_compose"))
        self.stack.enter_context(patch.object(self.release, "verify_runtime"))
        self.stack.enter_context(patch.object(cleanup, "image_inventory", side_effect=lambda *_: deepcopy(self.images)))
        self.used = self.stack.enter_context(patch.object(cleanup, "used_images", return_value=set()))
        self.commands = []
        self.leave_untagged = False

        def remove(command, **_):
            if command[:3] == ["docker", "image", "ls"]:
                self.assertIn("--all", command)
                return "\n".join(self.images)
            self.commands.append(command)
            self.assertEqual(command[:4], ["docker", "image", "rm", "--no-prune"])
            self.assertNotIn("--force", command)
            for key, image in list(self.images.items()):
                if command[4:] == [key]:
                    del self.images[key]
                    return ""
                if set(command[4:]) == set(image["tags"]):
                    if self.leave_untagged:
                        image["tags"] = []
                        image["digests"] = []
                    else:
                        del self.images[key]
                    return ""
            raise AssertionError("Unexpected deletion")

        self.stack.enter_context(patch.object(self.release, "run", side_effect=remove))

    def clean(self, apply=False):
        return cleanup.clean(self.release, self.root, 3, 2, apply)

    def test_preview_does_not_delete_or_write_journal(self):
        report = self.clean()
        self.assertTrue(report["candidate_images"])
        self.assertFalse(self.commands)
        self.assertFalse((self.state / "image-cleanup-latest.json").exists())

    def test_apply_removes_only_candidates_and_keeps_manifests(self):
        before = set(self.state.glob("*.json"))
        report = self.clean(apply=True)
        self.assertEqual(set(report["removed_images"]), {x["id"] for x in report["candidate_images"]})
        self.assertTrue(before <= set(self.state.glob("*.json")))
        self.assertEqual(report["status"], "completed")

    def test_new_container_stops_cleanup_before_first_removal(self):
        old_ids = {item["id"] for item in self.clean()["candidate_images"]}
        self.used.side_effect = [set(), old_ids]
        with self.assertRaisesRegex(self.release.ManifestError, "became used"):
            self.clean(apply=True)
        self.assertFalse(self.commands)

    def test_classic_store_untagged_intermediates_are_removed_by_exact_id(self):
        self.leave_untagged = True
        report = self.clean(apply=True)
        self.assertTrue(report["removed_images"])
        self.assertFalse(set(report["removed_images"]) & set(self.images))
        self.assertEqual(len(self.commands), 2 * len(report["removed_images"]))

    def test_missing_protected_image_blocks_cleanup(self):
        del self.images[self.current["services"]["frontend"]["imageId"]]
        with self.assertRaisesRegex(self.release.ManifestError, "missing images"):
            self.clean(apply=True)
        self.assertFalse(self.commands)

    def test_failed_deployment_blocks_cleanup(self):
        attempt = self.state / "attempt"
        attempt.mkdir()
        (attempt / "result.json").write_text('{"status":"failed-or-interrupted"}')
        with self.assertRaisesRegex(self.release.ManifestError, "recovery before cleanup"):
            self.clean(apply=True)
        self.assertFalse(self.commands)

    def test_cleanup_shares_lock_with_deploy_and_rollback(self):
        with self.release.release_lock(self.root):
            with self.assertRaisesRegex(self.release.ManifestError, "Another manifest operation"):
                self.clean(apply=True)
        self.assertFalse(self.commands)


if __name__ == "__main__":
    unittest.main()
