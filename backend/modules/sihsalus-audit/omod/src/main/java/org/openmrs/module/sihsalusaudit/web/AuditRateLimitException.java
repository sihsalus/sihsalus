package org.openmrs.module.sihsalusaudit.web;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.ResponseStatus;

@ResponseStatus(HttpStatus.TOO_MANY_REQUESTS)
public class AuditRateLimitException extends RuntimeException {

    private static final long serialVersionUID = 1L;

    public AuditRateLimitException() {
        super("Audit request rate exceeded");
    }
}
