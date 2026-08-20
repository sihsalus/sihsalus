package org.openmrs.module.sihsalusaudit.api;

import java.util.Date;

/**
 * Validated, client-supplied audit data. The authoritative actor and receive time are deliberately
 * absent: the service derives both from the authenticated OpenMRS context and server clock. The
 * optional occurrence time remains an explicitly non-authoritative client claim.
 */
public class ClinicalAuditSubmission {

    private final String clientEventId;

    private final String eventType;

    private final String patientUuid;

    private final String encounterUuid;

    private final String resourceType;

    private final String metadataJson;

    /**
     * Client-claimed occurrence time. This is useful for ordering offline events, but is never an
     * authoritative server timestamp.
     */
    private final Date clientOccurredAt;

    public ClinicalAuditSubmission(String clientEventId, String eventType, String patientUuid, String encounterUuid,
            String resourceType, String metadataJson, Date clientOccurredAt) {
        this.clientEventId = clientEventId;
        this.eventType = eventType;
        this.patientUuid = patientUuid;
        this.encounterUuid = encounterUuid;
        this.resourceType = resourceType;
        this.metadataJson = metadataJson;
        this.clientOccurredAt = clientOccurredAt == null ? null : new Date(clientOccurredAt.getTime());
    }

    public String getClientEventId() {
        return clientEventId;
    }

    public String getEventType() {
        return eventType;
    }

    public String getPatientUuid() {
        return patientUuid;
    }

    public String getEncounterUuid() {
        return encounterUuid;
    }

    public String getResourceType() {
        return resourceType;
    }

    public String getMetadataJson() {
        return metadataJson;
    }

    public Date getClientOccurredAt() {
        return clientOccurredAt == null ? null : new Date(clientOccurredAt.getTime());
    }
}
