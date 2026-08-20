package org.openmrs.module.sihsalusaudit.api.db.hibernate;

import java.util.List;

import org.hibernate.criterion.Order;
import org.openmrs.User;
import org.openmrs.api.db.hibernate.DbSessionFactory;
import org.openmrs.module.sihsalusaudit.api.db.ClinicalAuditDao;
import org.openmrs.module.sihsalusaudit.model.ClinicalAuditEvent;

public class HibernateClinicalAuditDao implements ClinicalAuditDao {

    private DbSessionFactory sessionFactory;

    @Override
    public ClinicalAuditEvent getByClientEventId(User actor, String clientEventId) {
        return (ClinicalAuditEvent) sessionFactory.getCurrentSession()
                .createQuery("from ClinicalAuditEvent e where e.actor = :actor and e.clientEventId = :clientEventId")
                .setParameter("actor", actor)
                .setParameter("clientEventId", clientEventId)
                .uniqueResult();
    }

    @Override
    public void append(ClinicalAuditEvent event) {
        sessionFactory.getCurrentSession().save(event);
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
