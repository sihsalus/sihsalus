package org.openmrs.module.sihsalusaudit.web;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.openmrs.module.sihsalusaudit.ClinicalAuditConstants;
import org.openmrs.module.sihsalusaudit.api.ClinicalAuditSubmission;

public class AuditPayloadParser {

    private static final int MAX_METADATA_BYTES = 4096;

    private static final int MAX_METADATA_KEYS = 10;

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
            "DiagnosticReport", "ImagingStudy", "Invoice", "StockOperation", "User", "Role");

    private static final Set<String> METADATA_FIELDS = immutableSet(
            "appName", "module", "action", "outcome", "offline", "reasonCode", "message",
            "componentStack", "locationUuid");

    private final ObjectMapper objectMapper;

    public AuditPayloadParser() {
        this(new ObjectMapper());
    }

    AuditPayloadParser(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper.enable(JsonParser.Feature.STRICT_DUPLICATE_DETECTION);
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
            throw new AuditValidationException(ex);
        }
    }

    public JsonNode parseStoredMetadata(String metadataJson) {
        if (metadataJson == null) {
            return null;
        }
        try {
            return objectMapper.readTree(metadataJson);
        }
        catch (JsonProcessingException ex) {
            throw new IllegalStateException("Stored audit metadata is invalid", ex);
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

        validateUntrustedEnvelopeFields(node);
        String metadataJson = validateAndSerializeMetadata(node.get("metadata"));

        return new ClinicalAuditSubmission(id, eventType, patientUuid, encounterUuid, resourceType, metadataJson);
    }

    private void validateUntrustedEnvelopeFields(JsonNode node) {
        String userUuid = optionalText(node, "userUuid", 38);
        validateOptionalUuid(userUuid);

        String sessionId = optionalText(node, "sessionId", 128);
        if (sessionId != null && !sessionId.matches("[A-Za-z0-9._:-]+")) {
            throw new AuditValidationException();
        }

        String timestamp = optionalText(node, "timestamp", 40);
        if (timestamp != null) {
            try {
                Instant.parse(timestamp);
            }
            catch (DateTimeParseException ex) {
                throw new AuditValidationException(ex);
            }
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

        Iterator<Map.Entry<String, JsonNode>> fields = metadata.properties().iterator();
        while (fields.hasNext()) {
            Map.Entry<String, JsonNode> field = fields.next();
            JsonNode value = field.getValue();
            if ("offline".equals(field.getKey())) {
                if (!value.isBoolean()) {
                    throw new AuditValidationException();
                }
                continue;
            }
            if (!value.isTextual()) {
                throw new AuditValidationException();
            }
            int maxLength = "componentStack".equals(field.getKey()) ? 2048
                    : "message".equals(field.getKey()) ? 512 : 128;
            if (value.textValue().length() > maxLength) {
                throw new AuditValidationException();
            }
            if ("locationUuid".equals(field.getKey())) {
                validateUuid(value.textValue());
            }
        }

        String validatedMetadata = objectMapper.writeValueAsString(metadata);
        if (validatedMetadata.getBytes(StandardCharsets.UTF_8).length > MAX_METADATA_BYTES) {
            throw new AuditValidationException();
        }

        ObjectNode canonicalMetadata = objectMapper.createObjectNode();
        for (String field : METADATA_FIELDS) {
            if (metadata.has(field) && !isDiscardedFreeTextField(field)) {
                canonicalMetadata.set(field, metadata.get(field));
            }
        }
        if (canonicalMetadata.isEmpty()) {
            return null;
        }
        return objectMapper.writeValueAsString(canonicalMetadata);
    }

    private boolean isDiscardedFreeTextField(String field) {
        return "message".equals(field) || "componentStack".equals(field);
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
        if (value == null || value.length() != 36) {
            throw new AuditValidationException();
        }
        try {
            if (!UUID.fromString(value).toString().equalsIgnoreCase(value)) {
                throw new AuditValidationException();
            }
        }
        catch (IllegalArgumentException ex) {
            throw new AuditValidationException(ex);
        }
    }

    private static Set<String> immutableSet(String... values) {
        return Collections.unmodifiableSet(new LinkedHashSet<String>(Arrays.asList(values)));
    }
}
