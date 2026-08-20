package org.openmrs.module.sihsalusaudit.web;

import java.io.IOException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

import javax.servlet.http.HttpServletRequest;

import com.fasterxml.jackson.databind.JsonNode;
import org.openmrs.module.sihsalusaudit.ClinicalAuditConstants;
import org.openmrs.module.sihsalusaudit.api.AuditSecurityContext;
import org.openmrs.module.sihsalusaudit.api.ClinicalAuditService;
import org.openmrs.module.sihsalusaudit.api.ClinicalAuditSubmission;
import org.openmrs.module.sihsalusaudit.model.ClinicalAuditEvent;
import org.openmrs.module.webservices.rest.SimpleObject;
import org.openmrs.module.webservices.rest.web.RestConstants;
import org.openmrs.module.webservices.rest.web.v1_0.controller.BaseRestController;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestMethod;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseBody;

@Controller("sihsalusClinicalAuditController")
@RequestMapping("/rest/" + RestConstants.VERSION_1 + "/sihsalus/audit")
public class ClinicalAuditController extends BaseRestController {

    private final ClinicalAuditService auditService;

    private final AuditPayloadParser payloadParser;

    private final AuditRequestBodyReader bodyReader;

    private final AuditSecurityContext securityContext;

    @Autowired
    public ClinicalAuditController(ClinicalAuditService auditService, AuditPayloadParser payloadParser,
            AuditRequestBodyReader bodyReader, AuditSecurityContext securityContext) {
        this.auditService = auditService;
        this.payloadParser = payloadParser;
        this.bodyReader = bodyReader;
        this.securityContext = securityContext;
    }

    @RequestMapping(method = RequestMethod.POST, consumes = MediaType.APPLICATION_JSON_VALUE,
            produces = MediaType.APPLICATION_JSON_VALUE)
    @ResponseBody
    public SimpleObject ingest(HttpServletRequest request) throws IOException {
        securityContext.requireAuthenticatedUserWithPrivilege(ClinicalAuditConstants.PRIVILEGE_RECORD);
        byte[] body = bodyReader.read(request);
        List<ClinicalAuditSubmission> submissions = payloadParser.parse(body);
        List<String> confirmedIds = auditService.recordEvents(submissions);
        return new SimpleObject().add("accepted", confirmedIds).add("count", confirmedIds.size());
    }

    @RequestMapping(method = RequestMethod.GET, produces = MediaType.APPLICATION_JSON_VALUE)
    @ResponseBody
    public SimpleObject review(@RequestParam(value = "startIndex", defaultValue = "0") int startIndex,
            @RequestParam(value = "limit", defaultValue = "50") int limit) {
        securityContext.requireAuthenticatedUserWithPrivilege(ClinicalAuditConstants.PRIVILEGE_VIEW);
        if (startIndex < 0 || limit < 1 || limit > ClinicalAuditConstants.MAX_REVIEW_PAGE_SIZE) {
            throw new AuditValidationException();
        }
        List<SimpleObject> results = new ArrayList<SimpleObject>();
        for (ClinicalAuditEvent event : auditService.getEvents(startIndex, limit)) {
            SimpleObject result = new SimpleObject()
                    .add("id", event.getClientEventId())
                    .add("eventType", event.getEventType())
                    .add("patientUuid", event.getPatientUuid())
                    .add("encounterUuid", event.getEncounterUuid())
                    .add("resourceType", event.getResourceType())
                    .add("actorUuid", event.getActor().getUuid())
                    .add("timestamp", Instant.ofEpochMilli(event.getServerTimestamp().getTime()).toString());
            JsonNode metadata = payloadParser.parseStoredMetadata(event.getMetadataJson());
            if (metadata != null) {
                result.add("metadata", metadata);
            }
            results.add(result);
        }
        return new SimpleObject().add("results", results)
                .add("startIndex", startIndex)
                .add("limit", limit);
    }
}
