package org.openmrs.module.sihsalusaudit.api.impl;

import static org.junit.Assert.assertEquals;

import java.util.Collections;
import java.util.Date;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import org.junit.Test;
import org.openmrs.User;
import org.openmrs.module.sihsalusaudit.api.ClinicalAuditSubmission;
import org.openmrs.module.sihsalusaudit.api.db.ClinicalAuditDao;
import org.openmrs.module.sihsalusaudit.model.ClinicalAuditEvent;

public class ClinicalAuditServiceConcurrencyTest {

    @Test
    public void concurrentIdenticalRetriesBothSucceedAndStoreOneEvent() throws Exception {
        User actor = new User();
        actor.setUserId(42);
        actor.setUuid("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
        RacingIdempotentDao dao = new RacingIdempotentDao();
        ClinicalAuditServiceImpl firstService = service(dao, actor);
        ClinicalAuditServiceImpl secondService = service(dao, actor);
        ClinicalAuditSubmission submission = new ClinicalAuditSubmission(
                "11111111-1111-4111-8111-111111111111", "PATIENT_VIEW",
                "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", null, "Patient", "{\"offline\":true}",
                new Date(1_787_099_690_000L));

        ExecutorService executor = Executors.newFixedThreadPool(2);
        try {
            Future<List<String>> first = executor.submit(
                    () -> firstService.recordEvents(Collections.singletonList(submission)));
            Future<List<String>> second = executor.submit(
                    () -> secondService.recordEvents(Collections.singletonList(submission)));

            assertEquals(Collections.singletonList(submission.getClientEventId()), first.get(5, TimeUnit.SECONDS));
            assertEquals(Collections.singletonList(submission.getClientEventId()), second.get(5, TimeUnit.SECONDS));
            assertEquals(1, dao.stored.size());
            assertEquals(2, dao.attempts.get());
        }
        finally {
            executor.shutdownNow();
        }
    }

    private ClinicalAuditServiceImpl service(ClinicalAuditDao dao, User actor) {
        ClinicalAuditServiceImpl service = new ClinicalAuditServiceImpl();
        service.setDao(dao);
        service.setSecurityContext(privilege -> actor);
        service.setClock(() -> new Date(1_787_099_696_000L));
        return service;
    }

    private static final class RacingIdempotentDao implements ClinicalAuditDao {

        private final ConcurrentMap<String, ClinicalAuditEvent> stored =
                new ConcurrentHashMap<String, ClinicalAuditEvent>();

        private final AtomicInteger attempts = new AtomicInteger();

        private final CountDownLatch bothAttemptsStarted = new CountDownLatch(2);

        @Override
        public ClinicalAuditEvent appendIdempotently(ClinicalAuditEvent event) {
            attempts.incrementAndGet();
            bothAttemptsStarted.countDown();
            try {
                if (!bothAttemptsStarted.await(5, TimeUnit.SECONDS)) {
                    throw new IllegalStateException("Concurrent test did not overlap");
                }
            }
            catch (InterruptedException ex) {
                Thread.currentThread().interrupt();
                throw new IllegalStateException(ex);
            }
            String key = event.getActor().getUserId() + ":" + event.getClientEventId();
            ClinicalAuditEvent winner = stored.putIfAbsent(key, event);
            return winner == null ? event : winner;
        }

        @Override
        public List<ClinicalAuditEvent> getEvents(int startIndex, int limit) {
            return Collections.emptyList();
        }
    }
}
