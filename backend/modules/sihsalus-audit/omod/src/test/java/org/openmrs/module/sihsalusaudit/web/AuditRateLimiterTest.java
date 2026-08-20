package org.openmrs.module.sihsalusaudit.web;

import static org.junit.Assert.assertEquals;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

import org.junit.Test;
import org.openmrs.User;

public class AuditRateLimiterTest {

    @Test
    public void limitsEachActorAndResetsAfterTheWindow() {
        AtomicLong now = new AtomicLong(1000L);
        AuditRateLimiter limiter = new AuditRateLimiter(now::get);
        User actor = actor("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");

        for (int i = 0; i < AuditRateLimiter.MAX_REQUESTS_PER_SECOND; i++) {
            assertEquals(0, limiter.acquire(actor));
        }
        assertEquals(1, limiter.acquire(actor));

        now.addAndGet(1000L);
        assertEquals(0, limiter.acquire(actor));
    }

    @Test
    public void actorsHaveIndependentWindows() {
        AuditRateLimiter limiter = new AuditRateLimiter(() -> 1000L);
        User first = actor("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
        User second = actor("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");

        for (int i = 0; i < AuditRateLimiter.MAX_REQUESTS_PER_SECOND; i++) {
            assertEquals(0, limiter.acquire(first));
        }
        assertEquals(1, limiter.acquire(first));
        assertEquals(0, limiter.acquire(second));
    }

    @Test
    public void concurrentRequestsCannotExceedTheWindowAllowance() throws Exception {
        AuditRateLimiter limiter = new AuditRateLimiter(() -> 1000L);
        User actor = actor("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
        ExecutorService executor = Executors.newFixedThreadPool(40);
        CountDownLatch start = new CountDownLatch(1);
        List<Future<Integer>> results = new ArrayList<Future<Integer>>();
        try {
            for (int i = 0; i < 40; i++) {
                results.add(executor.submit(() -> {
                    start.await(5, TimeUnit.SECONDS);
                    return limiter.acquire(actor);
                }));
            }
            start.countDown();

            int accepted = 0;
            for (Future<Integer> result : results) {
                if (result.get(5, TimeUnit.SECONDS) == 0) {
                    accepted++;
                }
            }
            assertEquals(AuditRateLimiter.MAX_REQUESTS_PER_SECOND, accepted);
        }
        finally {
            executor.shutdownNow();
        }
    }

    private User actor(String uuid) {
        User actor = new User();
        actor.setUuid(uuid);
        return actor;
    }
}
