package org.openmrs.module.sihsalusaudit.api;

/**
 * Validated, client-supplied audit data. Actor and timestamp are deliberately absent: the service
 * derives both from the authenticated OpenMRS context and the server clock.
 */
public class ClinicalAuditSubmission {

    private final String clientEventId;

    private final String eventType;

    private final String patientUuid;

    private final String encounterUuid;

    private final String resourceType;

    private final String metadataJson;

    public ClinicalAuditSubmission(String clientEventId, String eventType, String patientUuid, String encounterUuid,
            String resourceType, String metadataJson) {
        this.clientEventId = clientEventId;
        this.eventType = eventType;
        this.patientUuid = patientUuid;
        this.encounterUuid = encounterUuid;
        this.resourceType = resourceType;
        this.metadataJson = metadataJson;
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
}
