package org.openmrs.module.sihsalusaudit.api.db;

import java.util.List;

import org.openmrs.User;
import org.openmrs.module.sihsalusaudit.model.ClinicalAuditEvent;

public interface ClinicalAuditDao {

    /**
     * Serializes writes for the event actor, appends when absent, and otherwise returns the row
     * which won the race. The surrounding service transaction holds the actor lock until commit.
     */
    ClinicalAuditEvent appendIdempotently(ClinicalAuditEvent event);

    List<ClinicalAuditEvent> getEvents(int startIndex, int limit);
}
