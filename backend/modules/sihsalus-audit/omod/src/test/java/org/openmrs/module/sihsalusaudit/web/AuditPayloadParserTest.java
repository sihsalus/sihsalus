package org.openmrs.module.sihsalusaudit.web;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.List;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.Test;
import org.openmrs.module.sihsalusaudit.api.ClinicalAuditSubmission;

public class AuditPayloadParserTest {

    private final AuditPayloadParser parser = new AuditPayloadParser();

    @Test
    public void acceptsFrontendEnvelopeAndKeepsClientTimeAsASeparateClaim() {
        String json = "[{"
                + "\"id\":\"11111111-1111-4111-8111-111111111111\","
                + "\"eventType\":\"UNHANDLED_ERROR\","
                + "\"resourceType\":\"Patient\","
                + "\"metadata\":{\"appName\":\"patient-chart\",\"offline\":false},"
                + "\"timestamp\":\"2020-01-01T00:00:00Z\","
                + "\"userUuid\":\"22222222-2222-4222-8222-222222222222\","
                + "\"sessionId\":\"attacker-controlled-session\""
                + "}]";

        List<ClinicalAuditSubmission> result = parse(json);

        assertEquals(1, result.size());
        ClinicalAuditSubmission submission = result.get(0);
        assertEquals("11111111-1111-4111-8111-111111111111", submission.getClientEventId());
        assertEquals("UNHANDLED_ERROR", submission.getEventType());
        assertTrue(submission.getMetadataJson().contains("patient-chart"));
        assertFalse(submission.getMetadataJson().contains("attacker-controlled-session"));
        assertEquals(Instant.parse("2020-01-01T00:00:00Z").toEpochMilli(),
                submission.getClientOccurredAt().getTime());
    }

    @Test
    public void rejectsUnknownTopLevelField() {
        assertThrows(AuditValidationException.class, () -> parse(baseEvent("\"actor\":\"admin\",")));
    }

    @Test
    public void rejectsUnknownEventType() {
        assertThrows(AuditValidationException.class,
                () -> parse(baseEvent().replace("PATIENT_VIEW", "ARBITRARY_EVENT")));
    }

    @Test
    public void rejectsNestedOrUnknownMetadata() {
        assertThrows(AuditValidationException.class,
                () -> parse(baseEvent("\"metadata\":{\"payload\":{\"secret\":true}},")));
    }

    @Test
    public void rejectsDuplicateClientIds() {
        String event = baseEvent().substring(1, baseEvent().length() - 1);
        assertThrows(AuditValidationException.class, () -> parse("[" + event + "," + event + "]"));
    }

    @Test
    public void rejectsDuplicateJsonFields() {
        assertThrows(AuditValidationException.class, () -> parse("[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"PATIENT_VIEW\","
                + "\"eventType\":\"ENCOUNTER_VIEW\"}]"));
    }

    @Test
    public void rejectsTrailingJsonDocuments() {
        assertThrows(AuditValidationException.class, () -> parse(baseEvent() + " {}"));
    }

    @Test
    public void validationExceptionsDoNotRetainUntrustedInputInTheirCause() {
        AuditValidationException exception = assertThrows(AuditValidationException.class, () -> parse("[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"PATIENT_SEARCH\","
                + "\"unexpected\":\"patient-name-secret-token\"}]"));

        assertNull(exception.getCause());
        assertFalse(exception.getMessage().contains("patient-name"));
        assertFalse(exception.getMessage().contains("secret-token"));
    }

    @Test
    public void discardsMalformedCompatibilityEnvelopeFieldsWithoutPoisoningTheBatch() {
        ClinicalAuditSubmission submission = parse("[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"PATIENT_SEARCH\","
                + "\"userUuid\":{\"legacy\":\"patient-name-secret-token\"},"
                + "\"sessionId\":[\"unexpected\",\"shape\"]}]").get(0);

        assertNull(submission.getClientOccurredAt());
        assertNull(submission.getMetadataJson());
    }

    @Test
    public void discardsInvalidClientTimesWithoutPoisoningTheBatch() {
        ClinicalAuditSubmission tooEarly = parse("[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"PATIENT_SEARCH\","
                + "\"timestamp\":\"0001-01-01T00:00:00Z\"}]").get(0);
        ClinicalAuditSubmission tooLate = parse("[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"PATIENT_SEARCH\","
                + "\"timestamp\":\"9999-12-31T23:59:59Z\"}]").get(0);
        ClinicalAuditSubmission malformed = parse("[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"PATIENT_SEARCH\","
                + "\"timestamp\":\"not-a-time\"}]").get(0);
        ClinicalAuditSubmission wrongType = parse("[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"PATIENT_SEARCH\","
                + "\"timestamp\":42}]").get(0);

        assertNull(tooEarly.getClientOccurredAt());
        assertNull(tooLate.getClientOccurredAt());
        assertNull(malformed.getClientOccurredAt());
        assertNull(wrongType.getClientOccurredAt());
    }

    @Test
    public void canonicalizesMetadataForSafeIdempotentRetries() {
        ClinicalAuditSubmission first = parse("[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"UNHANDLED_ERROR\","
                + "\"metadata\":{\"message\":\"failure\",\"appName\":\"patient-chart\"}}]").get(0);
        ClinicalAuditSubmission reordered = parse("[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"UNHANDLED_ERROR\","
                + "\"metadata\":{\"appName\":\"patient-chart\",\"message\":\"failure\"}}]").get(0);

        assertEquals(first.getMetadataJson(), reordered.getMetadataJson());
    }

    @Test
    public void acceptsButDiscardsFreeTextThatCouldContainPhiOrSecrets() {
        ClinicalAuditSubmission submission = parse("[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"UNHANDLED_ERROR\","
                + "\"metadata\":{"
                + "\"appName\":\"patient-chart\","
                + "\"message\":\"patient-name secret-token\","
                + "\"componentStack\":\"/srv/openmrs/PatientChart.java:42\"}}]").get(0);

        assertEquals("{\"appName\":\"patient-chart\"}", submission.getMetadataJson());
        assertFalse(submission.getMetadataJson().contains("message"));
        assertFalse(submission.getMetadataJson().contains("componentStack"));
        assertFalse(submission.getMetadataJson().contains("patient-name"));
        assertFalse(submission.getMetadataJson().contains("secret-token"));
    }

    @Test
    public void acceptsLongCompatibilityFreeTextWithinTheGlobalRequestLimitAndDiscardsIt() {
        String message = repeat('m', 10_000);
        String componentStack = repeat('s', 40_000);
        String json = "[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"UNHANDLED_ERROR\","
                + "\"metadata\":{\"appName\":\"patient-chart\","
                + "\"message\":\"" + message + "\","
                + "\"componentStack\":\"" + componentStack + "\"}}]";

        assertTrue(json.getBytes(StandardCharsets.UTF_8).length < AuditRequestBodyReader.MAX_REQUEST_BYTES);
        ClinicalAuditSubmission submission = parse(json).get(0);

        assertEquals("{\"appName\":\"patient-chart\"}", submission.getMetadataJson());
    }

    @Test
    public void discardsMalformedAllowedMetadataValuesWithoutPoisoningTheBatch() {
        ClinicalAuditSubmission submission = parse("[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"UNHANDLED_ERROR\","
                + "\"metadata\":{"
                + "\"appName\":{\"legacy\":true},"
                + "\"module\":[\"patient-name-secret-token\"],"
                + "\"action\":42,"
                + "\"outcome\":{\"legacy\":true},"
                + "\"offline\":\"true\","
                + "\"reasonCode\":null,"
                + "\"message\":{\"patient\":\"patient-name\"},"
                + "\"componentStack\":42,"
                + "\"locationUuid\":\"not-a-uuid\"}}]").get(0);

        assertNull(submission.getMetadataJson());
    }

    @Test
    public void redactsMetadataStoredByTheInitial17aFormatDuringReview() {
        JsonNode metadata = parser.parseStoredMetadata("{"
                + "\"appName\":\"patient-chart\","
                + "\"module\":\"patient-name secret-token\","
                + "\"action\":\"patient-name secret-token\","
                + "\"outcome\":\"SUCCESS\","
                + "\"offline\":true,"
                + "\"reasonCode\":\"patient-name secret-token\","
                + "\"message\":\"patient-name secret-token\","
                + "\"componentStack\":\"/srv/openmrs/PatientChart.java:42\","
                + "\"locationUuid\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\"}");

        assertEquals("{\"appName\":\"patient-chart\",\"outcome\":\"SUCCESS\","
                + "\"offline\":true,\"locationUuid\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\"}",
                metadata.toString());
        assertFalse(metadata.toString().contains("patient-name"));
        assertFalse(metadata.toString().contains("secret-token"));
        assertFalse(metadata.has("message"));
        assertFalse(metadata.has("componentStack"));
    }

    @Test
    public void redactsMetadataStoredByThe26dFormatDuringReview() {
        JsonNode metadata = parser.parseStoredMetadata("{"
                + "\"appName\":\"patient-name\","
                + "\"module\":\"patient-name secret-token\","
                + "\"action\":\"patient-name secret-token\","
                + "\"outcome\":\"secret-token\","
                + "\"offline\":false,"
                + "\"reasonCode\":\"patient-name secret-token\","
                + "\"locationUuid\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\"}");

        assertEquals("{\"offline\":false,"
                + "\"locationUuid\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\"}", metadata.toString());
        assertFalse(metadata.toString().contains("patient-name"));
        assertFalse(metadata.toString().contains("secret-token"));
    }

    @Test
    public void omitsMalformedOrUnsafeStoredMetadataDuringReview() {
        assertNull(parser.parseStoredMetadata("{not-json"));
        assertNull(parser.parseStoredMetadata("[\"not-an-object\"]"));
        assertNull(parser.parseStoredMetadata("{\"appName\":{},\"offline\":\"true\","
                + "\"locationUuid\":\"not-a-uuid\"}"));
        assertNull(parser.parseStoredMetadata(repeat('x', 4097)));
    }

    @Test
    public void persistsOnlyEnumeratedMetadataValuesAndIdentifiers() {
        ClinicalAuditSubmission submission = parse("[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"UNHANDLED_ERROR\","
                + "\"metadata\":{"
                + "\"appName\":\"esm-patient-chart-app\","
                + "\"module\":\"patient-name secret-token\","
                + "\"action\":\"patient-name secret-token\","
                + "\"outcome\":\"SUCCESS\","
                + "\"reasonCode\":\"patient-name secret-token\","
                + "\"offline\":true,"
                + "\"locationUuid\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\"}}]").get(0);

        assertEquals("{\"appName\":\"esm-patient-chart-app\",\"outcome\":\"SUCCESS\","
                + "\"offline\":true,\"locationUuid\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\"}",
                submission.getMetadataJson());
        assertFalse(submission.getMetadataJson().contains("patient-name"));
        assertFalse(submission.getMetadataJson().contains("secret-token"));
    }

    @Test
    public void discardsUnknownMachineValuesRatherThanPersistingClientText() {
        ClinicalAuditSubmission submission = parse("[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"UNHANDLED_ERROR\","
                + "\"metadata\":{\"appName\":\"patient-name\",\"outcome\":\"secret-token\"}}]").get(0);

        assertNull(submission.getMetadataJson());
    }

    @Test
    public void requiresAndNormalizesClinicalTargetsByEventType() {
        ClinicalAuditSubmission patientView = parse("[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"PATIENT_VIEW\","
                + "\"patientUuid\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\"}]").get(0);
        assertEquals("Patient", patientView.getResourceType());

        assertThrows(AuditValidationException.class, () -> parse("[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"PATIENT_VIEW\"}]"));
        assertThrows(AuditValidationException.class, () -> parse("[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"PATIENT_VIEW\","
                + "\"patientUuid\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\","
                + "\"resourceType\":\"Order\"}]"));
    }

    @Test
    public void permissionChangesRequireAUserOrRoleTargetWithoutClinicalReferences() {
        ClinicalAuditSubmission permissionChange = parse("[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"PERMISSION_CHANGE\",\"resourceType\":\"Role\"}]").get(0);
        assertEquals("Role", permissionChange.getResourceType());

        assertThrows(AuditValidationException.class, () -> parse("[{"
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"PERMISSION_CHANGE\",\"resourceType\":\"Patient\"}]"));
    }

    @Test
    public void rejectsBatchLargerThanFrontendFlushLimit() {
        StringBuilder json = new StringBuilder("[");
        for (int i = 0; i < 51; i++) {
            if (i > 0) {
                json.append(',');
            }
            json.append("{\"id\":\"")
                    .append(String.format("00000000-0000-4000-8000-%012d", i))
                    .append("\",\"eventType\":\"PATIENT_SEARCH\"}");
        }
        json.append(']');

        assertThrows(AuditValidationException.class, () -> parse(json.toString()));
    }

    @Test
    public void acceptsAbsentOptionalClinicalReferencesAndMetadata() {
        ClinicalAuditSubmission submission = parse(baseEvent().replace("PATIENT_VIEW", "PATIENT_SEARCH")
                .replace(",\"patientUuid\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\"", "")).get(0);
        assertNull(submission.getPatientUuid());
        assertNull(submission.getMetadataJson());
    }

    private List<ClinicalAuditSubmission> parse(String json) {
        return parser.parse(json.getBytes(StandardCharsets.UTF_8));
    }

    private String baseEvent() {
        return baseEvent("");
    }

    private String baseEvent(String extraField) {
        return "[{" + extraField
                + "\"id\":\"99999999-9999-4999-8999-999999999999\","
                + "\"eventType\":\"PATIENT_VIEW\","
                + "\"patientUuid\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\"}]";
    }

    private String repeat(char value, int count) {
        char[] chars = new char[count];
        java.util.Arrays.fill(chars, value);
        return new String(chars);
    }
}
