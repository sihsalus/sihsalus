package org.openmrs.module.sihsalusaudit.api.db;

import java.util.List;

import org.openmrs.User;
import org.openmrs.module.sihsalusaudit.model.ClinicalAuditEvent;

public interface ClinicalAuditDao {

    ClinicalAuditEvent getByClientEventId(User actor, String clientEventId);

    void append(ClinicalAuditEvent event);

    List<ClinicalAuditEvent> getEvents(int startIndex, int limit);
}
