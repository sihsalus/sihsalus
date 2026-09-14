-- MariaDB operator migration for installations with binary logging enabled and
-- log_bin_trust_function_creators=OFF. Run against the OpenMRS database after
-- the module has created sihsalus_clinical_audit_event, then restart the backend.
-- Source: sihsalusaudit 1.0.0, revision 49c72a6a1fdddb37bc2272a2484dd68aebc36dec,
-- api/src/main/resources/liquibase.xml, changes 07 and 08.
-- Existing triggers are preserved; the module validates their exact definitions
-- on startup. This migration grants no privileges and changes no server settings.

CREATE TRIGGER IF NOT EXISTS sihsalus_audit_no_update
BEFORE UPDATE ON sihsalus_clinical_audit_event
FOR EACH ROW SIGNAL SQLSTATE '45000'
SET MESSAGE_TEXT = 'Clinical audit rows are append-only';

CREATE TRIGGER IF NOT EXISTS sihsalus_audit_no_delete
BEFORE DELETE ON sihsalus_clinical_audit_event
FOR EACH ROW SIGNAL SQLSTATE '45000'
SET MESSAGE_TEXT = 'Clinical audit rows are append-only';
