package org.openmrs.module.sihsalusaudit.web;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

import java.nio.charset.StandardCharsets;
import java.util.List;

import org.junit.Test;
import org.openmrs.module.sihsalusaudit.api.ClinicalAuditSubmission;

public class AuditPayloadParserTest {

    private final AuditPayloadParser parser = new AuditPayloadParser();

    @Test
    public void acceptsFrontendEnvelopeButDropsClientActorSessionAndTimestamp() {
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
    public void rejectsBatchLargerThanFrontendFlushLimit() {
        StringBuilder json = new StringBuilder("[");
        for (int i = 0; i < 51; i++) {
            if (i > 0) {
                json.append(',');
            }
            json.append("{\"id\":\"")
                    .append(String.format("00000000-0000-4000-8000-%012d", i))
                    .append("\",\"eventType\":\"PATIENT_VIEW\"}");
        }
        json.append(']');

        assertThrows(AuditValidationException.class, () -> parse(json.toString()));
    }

    @Test
    public void acceptsAbsentOptionalClinicalReferencesAndMetadata() {
        ClinicalAuditSubmission submission = parse(baseEvent()).get(0);
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
                + "\"eventType\":\"PATIENT_VIEW\"}]";
    }
}
