package org.openmrs.module.sihsalusaudit.web;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertThrows;

import java.nio.charset.StandardCharsets;

import org.junit.Test;
import org.springframework.mock.web.MockHttpServletRequest;

public class AuditRequestBodyReaderTest {

    private final AuditRequestBodyReader reader = new AuditRequestBodyReader();

    @Test
    public void readsBodyWithinHardLimit() throws Exception {
        byte[] body = "[{\"eventType\":\"PATIENT_VIEW\"}]".getBytes(StandardCharsets.UTF_8);
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setContent(body);

        assertArrayEquals(body, reader.read(request));
    }

    @Test
    public void rejectsBodyAboveHardLimitBeforeJsonParsing() {
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setContent(new byte[AuditRequestBodyReader.MAX_REQUEST_BYTES + 1]);

        assertThrows(AuditPayloadTooLargeException.class, () -> reader.read(request));
    }
}
