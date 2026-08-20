package org.openmrs.module.sihsalusaudit.api;

import java.util.List;

import org.openmrs.module.sihsalusaudit.model.ClinicalAuditEvent;

public interface ClinicalAuditService {

    /**
     * Atomically records a validated batch and returns every confirmed client event id. Existing
     * ids from the same actor are treated as successful idempotent retries.
     */
    List<String> recordEvents(List<ClinicalAuditSubmission> submissions);

    /**
     * Returns the newest records first. The service enforces the review privilege independently
     * from the REST controller.
     */
    List<ClinicalAuditEvent> getEvents(int startIndex, int limit);
}
