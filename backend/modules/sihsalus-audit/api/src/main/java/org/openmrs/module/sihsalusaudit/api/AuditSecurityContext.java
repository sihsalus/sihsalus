package org.openmrs.module.sihsalusaudit.api;

import org.openmrs.User;

public interface AuditSecurityContext {

    User requireAuthenticatedUserWithPrivilege(String privilege);
}
