package org.openmrs.module.sihsalusaudit.api.impl;

import org.openmrs.User;
import org.openmrs.api.APIAuthenticationException;
import org.openmrs.api.context.Context;
import org.openmrs.module.sihsalusaudit.api.AuditSecurityContext;

public class OpenmrsAuditSecurityContext implements AuditSecurityContext {

    @Override
    public User requireAuthenticatedUserWithPrivilege(String privilege) {
        if (!Context.isAuthenticated()) {
            throw new APIAuthenticationException("Authentication is required");
        }

        User actor = Context.getAuthenticatedUser();
        if (actor == null || !actor.hasPrivilege(privilege)) {
            throw new APIAuthenticationException("The authenticated user is not authorized");
        }
        return actor;
    }
}
