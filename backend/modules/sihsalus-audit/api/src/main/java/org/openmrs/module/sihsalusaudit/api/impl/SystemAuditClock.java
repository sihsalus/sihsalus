package org.openmrs.module.sihsalusaudit.api.impl;

import java.util.Date;

import org.openmrs.module.sihsalusaudit.api.AuditClock;

public class SystemAuditClock implements AuditClock {

    @Override
    public Date now() {
        return new Date();
    }
}
