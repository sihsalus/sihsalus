-- Operator recovery only after replacing a failed audit OMOD with a verified
-- image containing its activator and installing/validating both audit triggers.
-- OpenMRS can persist started=false after a lifecycle error. Change only that
-- failed-start flag, then restart the backend to retry the native module startup.
-- Do not use this to override an intentional operator stop or a clinical policy.
UPDATE global_property
SET property_value = 'true'
WHERE property = 'sihsalusaudit.started' AND property_value = 'false';
