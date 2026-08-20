package org.openmrs.module.sihsalusaudit.web;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.ResponseStatus;

@ResponseStatus(HttpStatus.PAYLOAD_TOO_LARGE)
public class AuditPayloadTooLargeException extends RuntimeException {

    private static final long serialVersionUID = 1L;

    public AuditPayloadTooLargeException() {
        super("Audit request is too large");
    }
}
