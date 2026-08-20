package org.openmrs.module.sihsalusaudit.web.filter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

import javax.servlet.http.HttpServletResponse;
import javax.xml.parsers.DocumentBuilderFactory;

import org.junit.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.w3c.dom.NodeList;

public class RestErrorSanitizingFilterTest {

    private final RestErrorSanitizingFilter filter = new RestErrorSanitizingFilter();

    @Test
    public void moduleMapsSanitizerToAuditEndpointWithOrWithoutTrailingSlash() throws Exception {
        try (InputStream config = getClass().getResourceAsStream("/config.xml")) {
            assertTrue("Packaged config.xml must be available", config != null);
            NodeList patterns = DocumentBuilderFactory.newInstance().newDocumentBuilder()
                    .parse(config)
                    .getElementsByTagName("url-pattern");

            assertEquals(2, patterns.getLength());
            assertEquals("/ws/rest/v1/sihsalus/audit", patterns.item(0).getTextContent().trim());
            assertEquals("/ws/rest/v1/sihsalus/audit/*", patterns.item(1).getTextContent().trim());
        }
    }

    @Test
    public void replacesLeakingServerErrorBody() throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();

        filter.doFilter(new MockHttpServletRequest(), response, (request, wrappedResponse) -> {
            HttpServletResponse http = (HttpServletResponse) wrappedResponse;
            http.setHeader("Content-Encoding", "gzip");
            http.setHeader("ETag", "leaking-representation-tag");
            http.setStatus(500);
            http.getWriter().write("java.sql.SQLException at /srv/openmrs/PatientDao.java:77");
        });

        String body = response.getContentAsString(StandardCharsets.UTF_8);
        assertEquals(500, response.getStatus());
        assertTrue(body.contains("SERVER_ERROR"));
        assertFalse(body.contains("SQLException"));
        assertFalse(body.contains("/srv/openmrs"));
        assertEquals("no-store", response.getHeader("Cache-Control"));
        assertEquals("nosniff", response.getHeader("X-Content-Type-Options"));
        assertNull(response.getHeader("Content-Encoding"));
        assertNull(response.getHeader("ETag"));
    }

    @Test
    public void sanitizesSendErrorMessage() throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();

        filter.doFilter(new MockHttpServletRequest(), response,
                (request, wrappedResponse) -> ((HttpServletResponse) wrappedResponse)
                        .sendError(403, "Missing privilege: secret-role"));

        String body = response.getContentAsString(StandardCharsets.UTF_8);
        assertEquals(403, response.getStatus());
        assertTrue(body.contains("FORBIDDEN"));
        assertFalse(body.contains("secret-role"));
    }

    @Test
    public void preservesAuthenticationChallengeOnSanitizedUnauthorizedResponse() throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();

        filter.doFilter(new MockHttpServletRequest(), response, (request, wrappedResponse) -> {
            HttpServletResponse http = (HttpServletResponse) wrappedResponse;
            http.setHeader("WWW-Authenticate", "Basic realm=\"OpenMRS\"");
            http.sendError(401, "internal authentication detail");
        });

        assertEquals(401, response.getStatus());
        assertEquals("Basic realm=\"OpenMRS\"", response.getHeader("WWW-Authenticate"));
        assertFalse(response.getContentAsString().contains("internal authentication detail"));
    }

    @Test
    public void preservesSuccessfulResponseBody() throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();

        filter.doFilter(new MockHttpServletRequest(), response, (request, wrappedResponse) -> {
            HttpServletResponse http = (HttpServletResponse) wrappedResponse;
            http.setStatus(200);
            http.setContentType("application/json");
            http.getWriter().write("{\"ok\":true}");
        });

        assertEquals(200, response.getStatus());
        assertEquals("{\"ok\":true}", response.getContentAsString(StandardCharsets.UTF_8));
    }

    @Test
    public void preservesLargeSuccessfulResponseWithinSafetyBound() throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();
        byte[] payload = new byte[70 * 1024];
        Arrays.fill(payload, (byte) 'a');

        filter.doFilter(new MockHttpServletRequest(), response, (request, wrappedResponse) -> {
            HttpServletResponse http = (HttpServletResponse) wrappedResponse;
            http.setStatus(200);
            http.getOutputStream().write(payload);
        });

        assertEquals(payload.length, response.getContentAsByteArray().length);
        assertEquals('a', response.getContentAsByteArray()[0]);
    }

    @Test
    public void preservesLargeSuccessfulWriterResponseWithinSafetyBound() throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();
        char[] chars = new char[70 * 1024];
        Arrays.fill(chars, 'b');
        String payload = new String(chars);

        filter.doFilter(new MockHttpServletRequest(), response, (request, wrappedResponse) -> {
            HttpServletResponse http = (HttpServletResponse) wrappedResponse;
            http.setStatus(200);
            http.getWriter().write(payload);
        });

        assertEquals(payload, response.getContentAsString(StandardCharsets.UTF_8));
    }

    @Test
    public void sanitizesResponseThatExceedsTheEndpointSafetyBound() throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();
        byte[] payload = new byte[513 * 1024];
        Arrays.fill(payload, (byte) 's');

        filter.doFilter(new MockHttpServletRequest(), response, (request, wrappedResponse) ->
                ((HttpServletResponse) wrappedResponse).getOutputStream().write(payload));

        assertEquals(500, response.getStatus());
        assertTrue(response.getContentAsString(StandardCharsets.UTF_8).contains("SERVER_ERROR"));
        assertFalse(response.getContentAsString(StandardCharsets.UTF_8).contains("ssssssss"));
    }

    @Test
    public void resetBufferRemovesEarlierSuccessfulBody() throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();

        filter.doFilter(new MockHttpServletRequest(), response, (request, wrappedResponse) -> {
            HttpServletResponse http = (HttpServletResponse) wrappedResponse;
            http.getWriter().write("sensitive stale body");
            http.resetBuffer();
            http.getWriter().write("replacement");
        });

        assertEquals("replacement", response.getContentAsString(StandardCharsets.UTF_8));
    }

    @Test
    public void convertsUnhandledExceptionToSanitizedServerError() throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();

        filter.doFilter(new MockHttpServletRequest(), response, (request, wrappedResponse) -> {
            throw new IllegalStateException("jdbc:mysql://secret-host/openmrs");
        });

        String body = response.getContentAsString(StandardCharsets.UTF_8);
        assertEquals(500, response.getStatus());
        assertTrue(body.contains("SERVER_ERROR"));
        assertFalse(body.contains("secret-host"));
    }
}
