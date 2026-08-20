package org.openmrs.module.sihsalusaudit.web;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;

import javax.servlet.http.HttpServletRequest;

public class AuditRequestBodyReader {

    public static final int MAX_REQUEST_BYTES = 64 * 1024;

    public byte[] read(HttpServletRequest request) throws IOException {
        int contentLength = request.getContentLength();
        if (contentLength > MAX_REQUEST_BYTES) {
            throw new AuditPayloadTooLargeException();
        }

        InputStream input = request.getInputStream();
        ByteArrayOutputStream output = new ByteArrayOutputStream(
                contentLength > 0 ? contentLength : Math.min(4096, MAX_REQUEST_BYTES));
        byte[] buffer = new byte[4096];
        int total = 0;
        int read;
        while ((read = input.read(buffer)) != -1) {
            total += read;
            if (total > MAX_REQUEST_BYTES) {
                throw new AuditPayloadTooLargeException();
            }
            output.write(buffer, 0, read);
        }
        return output.toByteArray();
    }
}
