package org.openmrs.module.sihsalusaudit.api.db.hibernate;

import java.util.List;

import org.hibernate.LockMode;
import org.hibernate.LockOptions;
import org.hibernate.criterion.Order;
import org.openmrs.User;
import org.openmrs.api.db.hibernate.DbSessionFactory;
import org.openmrs.module.sihsalusaudit.api.db.ClinicalAuditDao;
import org.openmrs.module.sihsalusaudit.model.ClinicalAuditEvent;

public class HibernateClinicalAuditDao implements ClinicalAuditDao {

    private DbSessionFactory sessionFactory;

    @Override
    public ClinicalAuditEvent appendIdempotently(ClinicalAuditEvent event) {
        if (event == null || event.getActor() == null || event.getActor().getUserId() == null) {
            throw new IllegalArgumentException("Audit event actor is required");
        }

        // A row lock on the authenticated actor makes the following lookup/insert sequence
        // atomic for the (actor_id, client_event_id) idempotency key. Unlike recovering from a
        // unique-constraint exception, this does not leave the Hibernate transaction unusable.
        User lockedActor = (User) sessionFactory.getCurrentSession().get(User.class,
                event.getActor().getUserId(), new LockOptions(LockMode.PESSIMISTIC_WRITE));
        if (lockedActor == null) {
            throw new IllegalStateException("Authenticated audit actor is unavailable");
        }

        ClinicalAuditEvent existing = (ClinicalAuditEvent) sessionFactory.getCurrentSession()
                .createQuery("from ClinicalAuditEvent e where e.actor = :actor and e.clientEventId = :clientEventId")
                .setParameter("actor", lockedActor)
                .setParameter("clientEventId", event.getClientEventId())
                .uniqueResult();
        if (existing != null) {
            return existing;
        }

        event.setActor(lockedActor);
        sessionFactory.getCurrentSession().save(event);
        return event;
    }

    @Override
    @SuppressWarnings("unchecked")
    public List<ClinicalAuditEvent> getEvents(int startIndex, int limit) {
        return sessionFactory.getCurrentSession()
                .createCriteria(ClinicalAuditEvent.class)
                .addOrder(Order.desc("serverTimestamp"))
                .addOrder(Order.desc("auditEventId"))
                .setFirstResult(startIndex)
                .setMaxResults(limit)
                .list();
    }

    public void setSessionFactory(DbSessionFactory sessionFactory) {
        this.sessionFactory = sessionFactory;
    }
}
