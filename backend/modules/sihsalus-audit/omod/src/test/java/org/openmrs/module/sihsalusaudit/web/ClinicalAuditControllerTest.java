package org.openmrs.module.sihsalusaudit.web;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Collections;
import java.util.Date;
import java.util.List;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.Test;
import org.mockito.ArgumentCaptor;
import org.openmrs.User;
import org.openmrs.api.APIAuthenticationException;
import org.openmrs.module.sihsalusaudit.api.AuditSecurityContext;
import org.openmrs.module.sihsalusaudit.api.ClinicalAuditService;
import org.openmrs.module.sihsalusaudit.api.ClinicalAuditSubmission;
import org.openmrs.module.sihsalusaudit.model.ClinicalAuditEvent;
import org.openmrs.module.webservices.rest.SimpleObject;
import org.springframework.mock.web.MockHttpServletRequest;

public class ClinicalAuditControllerTest {

    @Test
    @SuppressWarnings("unchecked")
    public void ingestReturnsOnlyIdsConfirmedByAtomicServiceCall() throws Exception {
        ClinicalAuditService service = mock(ClinicalAuditService.class);
        List<String> confirmed = Arrays.asList(
                "11111111-1111-4111-8111-111111111111",
                "22222222-2222-4222-8222-222222222222");
        when(service.recordEvents(anyList())).thenReturn(confirmed);
        AuditSecurityContext securityContext = authorizedSecurityContext();
        ClinicalAuditController controller = new ClinicalAuditController(
                service, new AuditPayloadParser(), new AuditRequestBodyReader(), securityContext);
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setContentType("application/json");
        request.setContent(("["
                + "{\"id\":\"11111111-1111-4111-8111-111111111111\",\"eventType\":\"PATIENT_VIEW\"},"
                + "{\"id\":\"22222222-2222-4222-8222-222222222222\",\"eventType\":\"ENCOUNTER_VIEW\"}"
                + "]").getBytes(StandardCharsets.UTF_8));

        SimpleObject response = controller.ingest(request);

        assertEquals(2, ((Number) response.get("count")).intValue());
        assertEquals(confirmed, (List<String>) response.get("accepted"));
        verify(service).recordEvents(anyList());
    }

    @Test
    public void ingestDoesNotReturnConfirmationWhenPersistenceFails() throws Exception {
        ClinicalAuditService service = mock(ClinicalAuditService.class);
        when(service.recordEvents(anyList())).thenThrow(new IllegalStateException("database unavailable"));
        ClinicalAuditController controller = new ClinicalAuditController(
                service, new AuditPayloadParser(), new AuditRequestBodyReader(), authorizedSecurityContext());
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setContent(("[{\"id\":\"33333333-3333-4333-8333-333333333333\","
                + "\"eventType\":\"PATIENT_VIEW\"}]").getBytes(StandardCharsets.UTF_8));

        try {
            controller.ingest(request);
        }
        catch (IllegalStateException expected) {
            assertEquals("database unavailable", expected.getMessage());
            return;
        }
        throw new AssertionError("Persistence failure must not produce a confirmation response");
    }

    @Test
    public void ingestRejectsUnauthorizedActorBeforeReadingOrParsingBody() throws Exception {
        ClinicalAuditService service = mock(ClinicalAuditService.class);
        AuditPayloadParser parser = mock(AuditPayloadParser.class);
        AuditRequestBodyReader bodyReader = mock(AuditRequestBodyReader.class);
        AuditSecurityContext securityContext = mock(AuditSecurityContext.class);
        when(securityContext.requireAuthenticatedUserWithPrivilege("Record Clinical Audit Events"))
                .thenThrow(new APIAuthenticationException("anonymous"));
        ClinicalAuditController controller = new ClinicalAuditController(
                service, parser, bodyReader, securityContext);

        try {
            controller.ingest(new MockHttpServletRequest());
        }
        catch (APIAuthenticationException expected) {
            verifyNoInteractions(bodyReader, parser, service);
            return;
        }
        throw new AssertionError("Anonymous request must be rejected before its body is read");
    }

    @Test
    @SuppressWarnings("unchecked")
    public void ingestAndReviewNeverExposeDiscardedFreeTextMetadata() throws Exception {
        String id = "88888888-8888-4888-8888-888888888888";
        ClinicalAuditService service = mock(ClinicalAuditService.class);
        when(service.recordEvents(anyList())).thenReturn(Collections.singletonList(id));
        AuditPayloadParser parser = new AuditPayloadParser();
        ClinicalAuditController controller = new ClinicalAuditController(
                service, parser, new AuditRequestBodyReader(), authorizedSecurityContext());
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setContent(("[{"
                + "\"id\":\"" + id + "\","
                + "\"eventType\":\"UNHANDLED_ERROR\","
                + "\"metadata\":{"
                + "\"appName\":\"patient-chart\","
                + "\"message\":\"patient-name secret-token\","
                + "\"componentStack\":\"/srv/openmrs/PatientChart.java:42\"}}]")
                        .getBytes(StandardCharsets.UTF_8));

        controller.ingest(request);

        ArgumentCaptor<List<ClinicalAuditSubmission>> submissions = ArgumentCaptor.forClass(List.class);
        verify(service).recordEvents(submissions.capture());
        ClinicalAuditSubmission sanitized = submissions.getValue().get(0);
        assertEquals("{\"appName\":\"patient-chart\"}", sanitized.getMetadataJson());

        ClinicalAuditEvent stored = new ClinicalAuditEvent();
        stored.setClientEventId(id);
        stored.setEventType("UNHANDLED_ERROR");
        stored.setMetadataJson(sanitized.getMetadataJson());
        stored.setServerTimestamp(new Date(1_787_099_696_000L));
        User actor = new User();
        actor.setUuid("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
        stored.setActor(actor);
        when(service.getEvents(0, 50)).thenReturn(Collections.singletonList(stored));

        SimpleObject review = controller.review(0, 50);
        List<SimpleObject> results = (List<SimpleObject>) review.get("results");
        JsonNode metadata = (JsonNode) results.get(0).get("metadata");
        assertEquals("patient-chart", metadata.get("appName").textValue());
        assertFalse(metadata.has("message"));
        assertFalse(metadata.has("componentStack"));
        assertFalse(review.toString().contains("patient-name"));
        assertFalse(review.toString().contains("secret-token"));
        assertEquals(1, results.size());
    }

    private AuditSecurityContext authorizedSecurityContext() {
        return mock(AuditSecurityContext.class);
    }
}
