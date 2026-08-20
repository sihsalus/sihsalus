package org.openmrs.module.sihsalusaudit.web;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Date;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.openmrs.module.sihsalusaudit.ClinicalAuditConstants;
import org.openmrs.module.sihsalusaudit.api.ClinicalAuditSubmission;

public class AuditPayloadParser {

    private static final int MAX_STORED_METADATA_BYTES = 4096;

    private static final int MAX_METADATA_KEYS = 10;

    // Keep a parseable client claim inside a conservative range supported by the module's
    // MariaDB DATETIME column in every deployment timezone. Invalid client clocks are discarded
    // because this field is non-authoritative and must not block the offline queue.
    private static final Instant MIN_CLIENT_OCCURRED_AT = Instant.parse("2000-01-01T00:00:00Z");

    private static final Instant MAX_CLIENT_OCCURRED_AT = Instant.parse("2100-01-01T00:00:00Z");

    private static final Set<String> ROOT_FIELDS = immutableSet("id", "eventType", "patientUuid",
            "encounterUuid", "resourceType", "metadata", "timestamp", "userUuid", "sessionId");

    private static final Set<String> EVENT_TYPES = immutableSet(
            "PATIENT_SEARCH", "PATIENT_VIEW", "PATIENT_CREATE", "PATIENT_UPDATE",
            "ENCOUNTER_VIEW", "ENCOUNTER_CREATE", "ENCOUNTER_UPDATE", "ENCOUNTER_CLOSE",
            "OBS_VIEW", "OBS_CREATE", "OBS_UPDATE", "OBS_VOID",
            "ORDER_VIEW", "ORDER_CREATE", "ORDER_UPDATE", "ORDER_DISCONTINUE",
            "DOCUMENT_DOWNLOAD", "DOCUMENT_PRINT", "MEDICATION_DISPENSE",
            "PERMISSION_CHANGE", "INTEGRATION_ERROR", "UNHANDLED_ERROR");

    private static final Set<String> RESOURCE_TYPES = immutableSet(
            "Patient", "Encounter", "Visit", "Obs", "Order", "MedicationDispense",
            "DiagnosticReport", "DocumentReference", "ImagingStudy", "Invoice", "StockOperation", "User", "Role");

    private static final Set<String> METADATA_FIELDS = immutableSet(
            "appName", "module", "action", "outcome", "offline", "reasonCode", "message",
            "componentStack", "locationUuid");

    // Only values owned by the deployed frontend are persisted. Unknown values remain accepted
    // for forward-compatible ingestion but are discarded, preventing arbitrary strings from
    // becoming a durable PHI/secret side channel.
    private static final Set<String> APP_NAMES = immutableSet(
            "esm-appointments-app", "esm-bed-management-app", "esm-billing-app", "esm-care-logbook-app",
            "esm-coststructure-app", "esm-emergency-app", "esm-form-builder-app", "esm-fua-app",
            "esm-help-menu-app", "esm-home-app", "esm-indicadores-app", "esm-interconsultas-app",
            "esm-laboratory-app", "esm-login-app", "esm-odontologia-app", "esm-offline-tools-app",
            "esm-openconceptlab-app", "esm-patient-chart-app", "esm-patient-list-management-app",
            "esm-patient-registration-app", "esm-patient-search-app", "esm-primary-navigation-app",
            "esm-service-queues-app", "esm-system-admin-app", "esm-user-onboarding-app", "patient-chart");

    private static final Set<String> OUTCOMES = immutableSet(
            "SUCCESS", "FAILURE", "DENIED", "CANCELLED", "QUEUED", "SYNCED");

    private final ObjectMapper objectMapper;

    public AuditPayloadParser() {
        this(new ObjectMapper());
    }

    AuditPayloadParser(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper.enable(JsonParser.Feature.STRICT_DUPLICATE_DETECTION)
                .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS);
    }

    public List<ClinicalAuditSubmission> parse(byte[] body) {
        try {
            JsonNode root = objectMapper.readTree(body);
            if (root == null || !root.isArray() || root.size() < 1
                    || root.size() > ClinicalAuditConstants.MAX_BATCH_SIZE) {
                throw new AuditValidationException();
            }

            List<ClinicalAuditSubmission> submissions = new ArrayList<ClinicalAuditSubmission>(root.size());
            Set<String> ids = new HashSet<String>();
            for (JsonNode node : root) {
                ClinicalAuditSubmission submission = parseEvent(node);
                if (!ids.add(submission.getClientEventId())) {
                    throw new AuditValidationException();
                }
                submissions.add(submission);
            }
            return submissions;
        }
        catch (AuditValidationException ex) {
            throw ex;
        }
        catch (IOException | RuntimeException ex) {
            // Do not attach parser exceptions: UUID/date/JSON messages may echo untrusted input
            // into OpenMRS logs even though the HTTP response itself is sanitized.
            throw new AuditValidationException();
        }
    }

    public JsonNode parseStoredMetadata(String metadataJson) {
        if (metadataJson == null
                || metadataJson.getBytes(StandardCharsets.UTF_8).length > MAX_STORED_METADATA_BYTES) {
            return null;
        }
        try {
            JsonNode metadata = objectMapper.readTree(metadataJson);
            return canonicalizeMetadata(metadata);
        }
        catch (JsonProcessingException | RuntimeException ex) {
            // Rows created by an older or partially deployed module must never make review fail
            // or re-expose legacy free text. Review omits metadata that cannot be canonicalized.
            return null;
        }
    }

    private ClinicalAuditSubmission parseEvent(JsonNode node) throws JsonProcessingException {
        if (!node.isObject()) {
            throw new AuditValidationException();
        }
        rejectUnknownFields(node, ROOT_FIELDS);

        String id = requiredText(node, "id", 36);
        validateUuid(id);

        String eventType = requiredText(node, "eventType", 64);
        if (!EVENT_TYPES.contains(eventType)) {
            throw new AuditValidationException();
        }

        String patientUuid = optionalText(node, "patientUuid", 38);
        validateOptionalUuid(patientUuid);
        String encounterUuid = optionalText(node, "encounterUuid", 38);
        validateOptionalUuid(encounterUuid);

        String resourceType = optionalText(node, "resourceType", 64);
        if (resourceType != null && !RESOURCE_TYPES.contains(resourceType)) {
            throw new AuditValidationException();
        }
        resourceType = validateAndNormalizeClinicalTarget(eventType, patientUuid, encounterUuid, resourceType);

        Date clientOccurredAt = parseClientOccurredAt(node.get("timestamp"));
        String metadataJson = validateAndSerializeMetadata(node.get("metadata"));

        return new ClinicalAuditSubmission(id, eventType, patientUuid, encounterUuid, resourceType, metadataJson,
                clientOccurredAt);
    }

    private Date parseClientOccurredAt(JsonNode timestamp) {
        if (timestamp == null || timestamp.isNull() || !timestamp.isTextual()
                || timestamp.textValue().length() > 40) {
            return null;
        }
        try {
            Instant clientOccurredAt = Instant.parse(timestamp.textValue());
            if (clientOccurredAt.isBefore(MIN_CLIENT_OCCURRED_AT)
                    || !clientOccurredAt.isBefore(MAX_CLIENT_OCCURRED_AT)) {
                return null;
            }
            return Date.from(clientOccurredAt);
        }
        catch (DateTimeParseException ex) {
            return null;
        }
    }

    private String validateAndNormalizeClinicalTarget(String eventType, String patientUuid, String encounterUuid,
            String resourceType) {
        if ("PATIENT_SEARCH".equals(eventType) || "INTEGRATION_ERROR".equals(eventType)
                || "UNHANDLED_ERROR".equals(eventType)) {
            return resourceType;
        }
        if (eventType.startsWith("PATIENT_")) {
            requireReference(patientUuid);
            return requireOrDefaultResource(resourceType, "Patient");
        }
        if (eventType.startsWith("ENCOUNTER_")) {
            requireReference(encounterUuid);
            return requireOrDefaultResource(resourceType, "Encounter");
        }
        if (eventType.startsWith("OBS_")) {
            requireReference(patientUuid);
            requireReference(encounterUuid);
            return requireOrDefaultResource(resourceType, "Obs");
        }
        if (eventType.startsWith("ORDER_")) {
            requireReference(patientUuid);
            requireReference(encounterUuid);
            return requireOrDefaultResource(resourceType, "Order");
        }
        if (eventType.startsWith("DOCUMENT_")) {
            requireReference(patientUuid);
            if (resourceType == null) {
                return "DocumentReference";
            }
            if (!"DocumentReference".equals(resourceType) && !"DiagnosticReport".equals(resourceType)
                    && !"ImagingStudy".equals(resourceType)) {
                throw new AuditValidationException();
            }
            return resourceType;
        }
        if ("MEDICATION_DISPENSE".equals(eventType)) {
            requireReference(patientUuid);
            return requireOrDefaultResource(resourceType, "MedicationDispense");
        }
        if ("PERMISSION_CHANGE".equals(eventType)) {
            if (!"User".equals(resourceType) && !"Role".equals(resourceType)) {
                throw new AuditValidationException();
            }
            if (patientUuid != null || encounterUuid != null) {
                throw new AuditValidationException();
            }
            return resourceType;
        }
        throw new AuditValidationException();
    }

    private String requireOrDefaultResource(String resourceType, String requiredResourceType) {
        if (resourceType == null) {
            return requiredResourceType;
        }
        if (!requiredResourceType.equals(resourceType)) {
            throw new AuditValidationException();
        }
        return resourceType;
    }

    private void requireReference(String reference) {
        if (reference == null) {
            throw new AuditValidationException();
        }
    }

    private String validateAndSerializeMetadata(JsonNode metadata) throws JsonProcessingException {
        if (metadata == null || metadata.isNull()) {
            return null;
        }
        if (!metadata.isObject() || metadata.size() > MAX_METADATA_KEYS) {
            throw new AuditValidationException();
        }
        rejectUnknownFields(metadata, METADATA_FIELDS);

        // Metadata is non-authoritative telemetry. Canonicalization below persists only known,
        // type-safe machine values. Every other value for an allowed compatibility key is
        // discarded so a stale or malformed client field cannot poison an atomic offline batch.
        JsonNode canonicalMetadata = canonicalizeMetadata(metadata);
        if (canonicalMetadata == null) {
            return null;
        }
        String serializedMetadata = objectMapper.writeValueAsString(canonicalMetadata);
        if (serializedMetadata.getBytes(StandardCharsets.UTF_8).length > MAX_STORED_METADATA_BYTES) {
            throw new AuditValidationException();
        }
        return serializedMetadata;
    }

    private JsonNode canonicalizeMetadata(JsonNode metadata) {
        if (metadata == null || !metadata.isObject()) {
            return null;
        }

        ObjectNode canonicalMetadata = objectMapper.createObjectNode();
        JsonNode appName = metadata.get("appName");
        if (appName != null && appName.isTextual() && APP_NAMES.contains(appName.textValue())) {
            canonicalMetadata.set("appName", appName);
        }
        JsonNode outcome = metadata.get("outcome");
        if (outcome != null && outcome.isTextual() && OUTCOMES.contains(outcome.textValue())) {
            canonicalMetadata.set("outcome", outcome);
        }
        JsonNode offline = metadata.get("offline");
        if (offline != null && offline.isBoolean()) {
            canonicalMetadata.set("offline", offline);
        }
        JsonNode locationUuid = metadata.get("locationUuid");
        if (locationUuid != null && locationUuid.isTextual() && isUuid(locationUuid.textValue())) {
            canonicalMetadata.set("locationUuid", locationUuid);
        }
        return canonicalMetadata.isEmpty() ? null : canonicalMetadata;
    }

    private static void rejectUnknownFields(JsonNode object, Set<String> allowedFields) {
        Iterator<String> names = object.fieldNames();
        while (names.hasNext()) {
            if (!allowedFields.contains(names.next())) {
                throw new AuditValidationException();
            }
        }
    }

    private static String requiredText(JsonNode node, String field, int maxLength) {
        String value = optionalText(node, field, maxLength);
        if (value == null || value.isEmpty()) {
            throw new AuditValidationException();
        }
        return value;
    }

    private static String optionalText(JsonNode node, String field, int maxLength) {
        JsonNode value = node.get(field);
        if (value == null || value.isNull()) {
            return null;
        }
        if (!value.isTextual() || value.textValue().length() > maxLength) {
            throw new AuditValidationException();
        }
        return value.textValue();
    }

    private static void validateOptionalUuid(String value) {
        if (value != null) {
            validateUuid(value);
        }
    }

    private static void validateUuid(String value) {
        if (!isUuid(value)) {
            throw new AuditValidationException();
        }
    }

    private static boolean isUuid(String value) {
        if (value == null || value.length() != 36) {
            return false;
        }
        try {
            return UUID.fromString(value).toString().equalsIgnoreCase(value);
        }
        catch (IllegalArgumentException ex) {
            return false;
        }
    }

    private static Set<String> immutableSet(String... values) {
        return Collections.unmodifiableSet(new LinkedHashSet<String>(Arrays.asList(values)));
    }
}
