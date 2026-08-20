package org.openmrs.module.sihsalusaudit.api.impl;

import java.util.ArrayList;
import java.util.Date;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;

import org.openmrs.User;
import org.openmrs.api.ValidationException;
import org.openmrs.module.sihsalusaudit.ClinicalAuditConstants;
import org.openmrs.module.sihsalusaudit.api.AuditClock;
import org.openmrs.module.sihsalusaudit.api.AuditSecurityContext;
import org.openmrs.module.sihsalusaudit.api.ClinicalAuditService;
import org.openmrs.module.sihsalusaudit.api.ClinicalAuditSubmission;
import org.openmrs.module.sihsalusaudit.api.db.ClinicalAuditDao;
import org.openmrs.module.sihsalusaudit.model.ClinicalAuditEvent;

public class ClinicalAuditServiceImpl implements ClinicalAuditService {

    private ClinicalAuditDao dao;

    private AuditSecurityContext securityContext;

    private AuditClock clock;

    @Override
    public List<String> recordEvents(List<ClinicalAuditSubmission> submissions) {
        User actor = securityContext.requireAuthenticatedUserWithPrivilege(ClinicalAuditConstants.PRIVILEGE_RECORD);
        validateBatch(submissions);

        Date recordedAt = clock.now();
        List<String> confirmedIds = new ArrayList<String>(submissions.size());
        for (ClinicalAuditSubmission submission : submissions) {
            String clientEventId = submission.getClientEventId();
            ClinicalAuditEvent existing = dao.getByClientEventId(actor, clientEventId);
            if (existing == null) {
                ClinicalAuditEvent event = new ClinicalAuditEvent();
                event.setClientEventId(clientEventId);
                event.setEventType(submission.getEventType());
                event.setPatientUuid(submission.getPatientUuid());
                event.setEncounterUuid(submission.getEncounterUuid());
                event.setResourceType(submission.getResourceType());
                event.setMetadataJson(submission.getMetadataJson());
                event.setActor(actor);
                event.setServerTimestamp(new Date(recordedAt.getTime()));
                dao.append(event);
            }
            else if (!matches(existing, submission)) {
                throw new ValidationException("Audit event id conflicts with the stored event");
            }
            confirmedIds.add(clientEventId);
        }
        return confirmedIds;
    }

    private boolean matches(ClinicalAuditEvent existing, ClinicalAuditSubmission submission) {
        return Objects.equals(existing.getEventType(), submission.getEventType())
                && Objects.equals(existing.getPatientUuid(), submission.getPatientUuid())
                && Objects.equals(existing.getEncounterUuid(), submission.getEncounterUuid())
                && Objects.equals(existing.getResourceType(), submission.getResourceType())
                && Objects.equals(existing.getMetadataJson(), submission.getMetadataJson());
    }

    @Override
    public List<ClinicalAuditEvent> getEvents(int startIndex, int limit) {
        securityContext.requireAuthenticatedUserWithPrivilege(ClinicalAuditConstants.PRIVILEGE_VIEW);
        if (startIndex < 0 || limit < 1 || limit > ClinicalAuditConstants.MAX_REVIEW_PAGE_SIZE) {
            throw new IllegalArgumentException("Invalid audit review page");
        }
        return dao.getEvents(startIndex, limit);
    }

    private void validateBatch(List<ClinicalAuditSubmission> submissions) {
        if (submissions == null || submissions.isEmpty()
                || submissions.size() > ClinicalAuditConstants.MAX_BATCH_SIZE) {
            throw new IllegalArgumentException("Invalid audit batch");
        }

        Set<String> ids = new HashSet<String>();
        for (ClinicalAuditSubmission submission : submissions) {
            if (submission == null || submission.getClientEventId() == null || !ids.add(submission.getClientEventId())) {
                throw new IllegalArgumentException("Invalid audit batch");
            }
        }
    }

    public void setDao(ClinicalAuditDao dao) {
        this.dao = dao;
    }

    public void setSecurityContext(AuditSecurityContext securityContext) {
        this.securityContext = securityContext;
    }

    public void setClock(AuditClock clock) {
        this.clock = clock;
    }
}
