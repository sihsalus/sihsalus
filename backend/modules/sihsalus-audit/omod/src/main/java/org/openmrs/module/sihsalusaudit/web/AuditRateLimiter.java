package org.openmrs.module.sihsalusaudit.web;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.LongSupplier;

import org.openmrs.User;

/**
 * Per-node, per-actor defense-in-depth limiter. The bounded map prevents the limiter itself from
 * becoming an authenticated memory exhaustion vector. A gateway/distributed limit remains a
 * production requirement for multi-node deployments.
 */
public class AuditRateLimiter {

    static final int MAX_REQUESTS_PER_SECOND = 20;

    private static final long WINDOW_MILLIS = 1000L;

    private static final int MAX_TRACKED_ACTORS = 10000;

    private static final long CLEANUP_INTERVAL_MILLIS = 60000L;

    private final ConcurrentMap<String, Window> windows = new ConcurrentHashMap<String, Window>();

    private final AtomicLong lastCleanupAt = new AtomicLong();

    private final LongSupplier clock;

    public AuditRateLimiter() {
        this(System::currentTimeMillis);
    }

    AuditRateLimiter(LongSupplier clock) {
        this.clock = clock;
    }

    /**
     * @return zero when accepted, otherwise the Retry-After delay in whole seconds.
     */
    public int acquire(User actor) {
        if (actor == null || actor.getUuid() == null) {
            throw new IllegalArgumentException("Authenticated audit actor is required");
        }

        long now = clock.getAsLong();
        removeExpiredWindows(now);
        String key = actor.getUuid();
        if (!windows.containsKey(key) && windows.size() >= MAX_TRACKED_ACTORS) {
            return 1;
        }

        int[] retryAfter = new int[] { 0 };
        windows.compute(key, (ignored, current) -> {
            if (current == null || now - current.startedAt >= WINDOW_MILLIS) {
                return new Window(now, 1);
            }
            if (current.count >= MAX_REQUESTS_PER_SECOND) {
                retryAfter[0] = (int) Math.max(1L,
                        (current.startedAt + WINDOW_MILLIS - now + 999L) / 1000L);
                return current;
            }
            return new Window(current.startedAt, current.count + 1);
        });
        return retryAfter[0];
    }

    private void removeExpiredWindows(long now) {
        long previous = lastCleanupAt.get();
        if (now - previous < CLEANUP_INTERVAL_MILLIS
                || !lastCleanupAt.compareAndSet(previous, now)) {
            return;
        }
        for (Map.Entry<String, Window> entry : windows.entrySet()) {
            if (now - entry.getValue().startedAt >= WINDOW_MILLIS) {
                windows.remove(entry.getKey(), entry.getValue());
            }
        }
    }

    private static final class Window {

        private final long startedAt;

        private final int count;

        private Window(long startedAt, int count) {
            this.startedAt = startedAt;
            this.count = count;
        }
    }
}
