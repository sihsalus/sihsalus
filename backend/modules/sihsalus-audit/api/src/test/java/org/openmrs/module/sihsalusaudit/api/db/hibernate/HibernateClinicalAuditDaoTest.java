package org.openmrs.module.sihsalusaudit.api.db.hibernate;

import static org.junit.Assert.assertSame;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import org.hibernate.LockMode;
import org.hibernate.LockOptions;
import org.hibernate.Query;
import org.junit.Test;
import org.mockito.ArgumentCaptor;
import org.openmrs.User;
import org.openmrs.api.db.hibernate.DbSession;
import org.openmrs.api.db.hibernate.DbSessionFactory;
import org.openmrs.module.sihsalusaudit.model.ClinicalAuditEvent;

public class HibernateClinicalAuditDaoTest {

    @Test
    public void locksActorBeforeLookupAndAppend() {
        Fixture fixture = new Fixture();
        when(fixture.query.uniqueResult()).thenReturn(null);

        ClinicalAuditEvent result = fixture.dao.appendIdempotently(fixture.candidate);

        assertSame(fixture.candidate, result);
        ArgumentCaptor<LockOptions> lock = ArgumentCaptor.forClass(LockOptions.class);
        verify(fixture.session).get(eq(User.class), eq(42), lock.capture());
        assertSame(LockMode.PESSIMISTIC_WRITE, lock.getValue().getLockMode());
        verify(fixture.session).save(fixture.candidate);
    }

    @Test
    public void returnsWinnerAfterActorLockWithoutSecondInsert() {
        Fixture fixture = new Fixture();
        ClinicalAuditEvent winner = new ClinicalAuditEvent();
        when(fixture.query.uniqueResult()).thenReturn(winner);

        assertSame(winner, fixture.dao.appendIdempotently(fixture.candidate));

        verify(fixture.session, never()).save(any(ClinicalAuditEvent.class));
    }

    private static final class Fixture {

        private final HibernateClinicalAuditDao dao = new HibernateClinicalAuditDao();

        private final DbSessionFactory sessionFactory = mock(DbSessionFactory.class);

        private final DbSession session = mock(DbSession.class);

        private final Query query = mock(Query.class);

        private final User actor = new User();

        private final ClinicalAuditEvent candidate = new ClinicalAuditEvent();

        private Fixture() {
            actor.setUserId(42);
            actor.setUuid("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
            candidate.setActor(actor);
            candidate.setClientEventId("11111111-1111-4111-8111-111111111111");
            dao.setSessionFactory(sessionFactory);
            when(sessionFactory.getCurrentSession()).thenReturn(session);
            when(session.get(eq(User.class), eq(42), any(LockOptions.class))).thenReturn(actor);
            when(session.createQuery(any(String.class))).thenReturn(query);
            when(query.setParameter(any(String.class), any())).thenReturn(query);
        }
    }
}
