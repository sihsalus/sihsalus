package org.openmrs.module.sihsalusaudit.api.impl;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import java.util.Arrays;
import java.util.Collections;
import java.util.Date;
import java.util.List;

import org.junit.Before;
import org.junit.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.MockitoAnnotations;
import org.openmrs.User;
import org.openmrs.api.APIAuthenticationException;
import org.openmrs.api.ValidationException;
import org.openmrs.module.sihsalusaudit.ClinicalAuditConstants;
import org.openmrs.module.sihsalusaudit.api.AuditClock;
import org.openmrs.module.sihsalusaudit.api.AuditSecurityContext;
import org.openmrs.module.sihsalusaudit.api.ClinicalAuditSubmission;
import org.openmrs.module.sihsalusaudit.api.db.ClinicalAuditDao;
import org.openmrs.module.sihsalusaudit.model.ClinicalAuditEvent;
import org.openmrs.util.PrivilegeConstants;

public class ClinicalAuditServiceImplTest {

    @Mock
    private ClinicalAuditDao dao;

    @Mock
    private AuditSecurityContext securityContext;

    @Mock
    private AuditClock clock;

    private ClinicalAuditServiceImpl service;

    private User serverActor;

    @Before
    public void setUp() {
        MockitoAnnotations.openMocks(this);
        service = new ClinicalAuditServiceImpl();
        service.setDao(dao);
        service.setSecurityContext(securityContext);
        service.setClock(clock);

        serverActor = new User();
        serverActor.setUserId(42);
        serverActor.setUuid("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
        when(securityContext.requireAuthenticatedUserWithPrivilege(ClinicalAuditConstants.PRIVILEGE_RECORD))
                .thenReturn(serverActor);
        when(clock.now()).thenReturn(new Date(1_787_099_696_000L));
        when(dao.appendIdempotently(any(ClinicalAuditEvent.class))).thenAnswer(invocation -> invocation.getArgument(0));
    }

    @Test
    public void recordEventsUsesOnlyServerActorAndTimestamp() {
        ClinicalAuditSubmission submission = submission("11111111-1111-4111-8111-111111111111");

        List<String> confirmed = service.recordEvents(Collections.singletonList(submission));

        assertEquals(Collections.singletonList(submission.getClientEventId()), confirmed);
        ArgumentCaptor<ClinicalAuditEvent> eventCaptor = ArgumentCaptor.forClass(ClinicalAuditEvent.class);
        verify(dao).appendIdempotently(eventCaptor.capture());
        ClinicalAuditEvent stored = eventCaptor.getValue();
        assertSame(serverActor, stored.getActor());
        assertEquals(new Date(1_787_099_696_000L), stored.getServerTimestamp());
        assertEquals(submission.getClientOccurredAt(), stored.getClientOccurredAt());
        assertEquals("PATIENT_VIEW", stored.getEventType());
    }

    @Test
    public void recordEventsConfirmsIdempotentRetryWithoutAppendingAgain() {
        ClinicalAuditSubmission submission = submission("22222222-2222-4222-8222-222222222222");
        ClinicalAuditEvent stored = storedEvent(submission);
        when(dao.appendIdempotently(any(ClinicalAuditEvent.class))).thenReturn(stored);

        assertEquals(Collections.singletonList(submission.getClientEventId()),
                service.recordEvents(Collections.singletonList(submission)));

        verify(dao).appendIdempotently(any(ClinicalAuditEvent.class));
    }

    @Test
    public void recordEventsRejectsAnIdempotencyIdReusedForDifferentData() {
        ClinicalAuditSubmission submission = submission("77777777-7777-4777-8777-777777777777");
        ClinicalAuditEvent stored = storedEvent(submission);
        stored.setEventType("ENCOUNTER_VIEW");
        when(dao.appendIdempotently(any(ClinicalAuditEvent.class))).thenReturn(stored);

        assertThrows(ValidationException.class,
                () -> service.recordEvents(Collections.singletonList(submission)));

        verify(dao).appendIdempotently(any(ClinicalAuditEvent.class));
    }

    @Test
    public void recordEventsRejectsAnonymousActorBeforePersistence() {
        when(securityContext.requireAuthenticatedUserWithPrivilege(ClinicalAuditConstants.PRIVILEGE_RECORD))
                .thenThrow(new APIAuthenticationException("anonymous"));

        assertThrows(APIAuthenticationException.class,
                () -> service.recordEvents(Collections.singletonList(submission(
                        "33333333-3333-4333-8333-333333333333"))));

        verifyNoInteractions(dao);
    }

    @Test
    public void recordEventsRejectsAuthenticatedActorWithoutRecordPrivilege() {
        when(securityContext.requireAuthenticatedUserWithPrivilege(ClinicalAuditConstants.PRIVILEGE_RECORD))
                .thenThrow(new APIAuthenticationException("forbidden"));

        assertThrows(APIAuthenticationException.class,
                () -> service.recordEvents(Collections.singletonList(submission(
                        "44444444-4444-4444-8444-444444444444"))));

        verifyNoInteractions(dao);
    }

    @Test
    public void reviewUsesIndependentReviewPrivilege() {
        when(securityContext.requireAuthenticatedUserWithPrivilege(ClinicalAuditConstants.PRIVILEGE_VIEW))
                .thenReturn(serverActor);
        ClinicalAuditEvent event = new ClinicalAuditEvent();
        when(dao.getEvents(0, 50)).thenReturn(Collections.singletonList(event));

        assertEquals(Collections.singletonList(event), service.getEvents(0, 50));

        verify(securityContext).requireAuthenticatedUserWithPrivilege(ClinicalAuditConstants.PRIVILEGE_VIEW);
    }

    @Test
    public void permissionChangeRequiresTheOpenmrsTargetPrivilege() {
        ClinicalAuditSubmission submission = new ClinicalAuditSubmission(
                "88888888-8888-4888-8888-888888888888", "PERMISSION_CHANGE",
                null, null, "Role", null, new Date(1_787_099_690_000L));
        when(securityContext.requireAuthenticatedUserWithPrivilege(PrivilegeConstants.MANAGE_ROLES))
                .thenReturn(serverActor);

        service.recordEvents(Collections.singletonList(submission));

        verify(securityContext).requireAuthenticatedUserWithPrivilege(PrivilegeConstants.MANAGE_ROLES);
        verify(dao).appendIdempotently(any(ClinicalAuditEvent.class));
    }

    @Test
    public void permissionChangeIsRejectedWithoutTheOpenmrsTargetPrivilege() {
        ClinicalAuditSubmission submission = new ClinicalAuditSubmission(
                "99999999-9999-4999-8999-999999999999", "PERMISSION_CHANGE",
                null, null, "User", null, new Date(1_787_099_690_000L));
        when(securityContext.requireAuthenticatedUserWithPrivilege(PrivilegeConstants.EDIT_USERS))
                .thenThrow(new APIAuthenticationException("forbidden"));

        assertThrows(APIAuthenticationException.class,
                () -> service.recordEvents(Collections.singletonList(submission)));

        verify(dao, never()).appendIdempotently(any(ClinicalAuditEvent.class));
    }

    @Test
    public void recordEventsRejectsDuplicateIdsAsAnAtomicInvalidBatch() {
        ClinicalAuditSubmission duplicate = submission("55555555-5555-4555-8555-555555555555");

        assertThrows(IllegalArgumentException.class,
                () -> service.recordEvents(Arrays.asList(duplicate, duplicate)));

        verify(dao, never()).appendIdempotently(any(ClinicalAuditEvent.class));
    }

    private ClinicalAuditSubmission submission(String id) {
        return new ClinicalAuditSubmission(id, "PATIENT_VIEW",
                "66666666-6666-4666-8666-666666666666", null, "Patient", "{\"offline\":false}",
                new Date(1_787_099_690_000L));
    }

    private ClinicalAuditEvent storedEvent(ClinicalAuditSubmission submission) {
        ClinicalAuditEvent event = new ClinicalAuditEvent();
        event.setClientEventId(submission.getClientEventId());
        event.setEventType(submission.getEventType());
        event.setPatientUuid(submission.getPatientUuid());
        event.setEncounterUuid(submission.getEncounterUuid());
        event.setResourceType(submission.getResourceType());
        event.setMetadataJson(submission.getMetadataJson());
        event.setClientOccurredAt(submission.getClientOccurredAt());
        event.setActor(serverActor);
        event.setServerTimestamp(new Date(1_787_099_696_000L));
        return event;
    }
}
