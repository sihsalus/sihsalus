package org.openmrs.module.sihsalusaudit.web;

import static org.junit.Assert.assertEquals;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.List;

import org.junit.Test;
import org.openmrs.api.APIAuthenticationException;
import org.openmrs.module.sihsalusaudit.api.AuditSecurityContext;
import org.openmrs.module.sihsalusaudit.api.ClinicalAuditService;
import org.openmrs.module.sihsalusaudit.api.ClinicalAuditSubmission;
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

    private AuditSecurityContext authorizedSecurityContext() {
        return mock(AuditSecurityContext.class);
    }
}
