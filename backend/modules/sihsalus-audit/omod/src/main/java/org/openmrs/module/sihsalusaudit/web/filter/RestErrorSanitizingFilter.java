package org.openmrs.module.sihsalusaudit.web.filter;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;

import javax.servlet.Filter;
import javax.servlet.FilterChain;
import javax.servlet.FilterConfig;
import javax.servlet.ServletException;
import javax.servlet.ServletOutputStream;
import javax.servlet.ServletRequest;
import javax.servlet.ServletResponse;
import javax.servlet.http.HttpServletResponse;
import javax.servlet.http.HttpServletResponseWrapper;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Last-line response sanitizer for the clinical audit endpoint. Its exact URL mapping is defined
 * in config.xml; technical exceptions remain in server logs, while public 4xx/5xx responses are
 * replaced with a stable generic envelope.
 */
public class RestErrorSanitizingFilter implements Filter {

    private static final Logger log = LoggerFactory.getLogger(RestErrorSanitizingFilter.class);

    private static final int MAX_BUFFERED_SUCCESS_BYTES = 64 * 1024;

    @Override
    public void init(FilterConfig filterConfig) {
    }

    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {
        if (!(response instanceof HttpServletResponse)) {
            chain.doFilter(request, response);
            return;
        }

        HttpServletResponse httpResponse = (HttpServletResponse) response;
        BufferingResponseWrapper wrapper = new BufferingResponseWrapper(httpResponse);
        try {
            chain.doFilter(request, wrapper);
        }
        catch (IOException | ServletException | RuntimeException ex) {
            log.error("Unhandled REST request failure", ex);
            wrapper.resetBufferedBody();
            wrapper.setStatus(HttpServletResponse.SC_INTERNAL_SERVER_ERROR);
        }

        int status = wrapper.getCapturedStatus();
        if (status >= 400) {
            if (httpResponse.isCommitted()) {
                log.error("REST error response was committed before it could be sanitized");
            }
            else {
                writeSanitizedError(httpResponse, status, wrapper.getAuthenticateHeader(),
                        wrapper.getAllowedMethodsHeader(), wrapper.getRetryAfterHeader());
            }
        }
        else {
            wrapper.copyBodyToResponse();
        }
    }

    @Override
    public void destroy() {
    }

    private void writeSanitizedError(HttpServletResponse response, int status, String authenticate,
            String allowedMethods, String retryAfter) throws IOException {
        ErrorDescription error = describe(status);
        byte[] body = ("{\"error\":{\"code\":\"" + error.code + "\",\"message\":\""
                + error.message + "\"}}\n").getBytes(StandardCharsets.UTF_8);

        // Clear representation headers as well as the body. In particular, RESTWS' inner gzip
        // filter can leave Content-Encoding behind even when its original error body is discarded.
        response.reset();
        restoreHeader(response, "WWW-Authenticate", authenticate);
        restoreHeader(response, "Allow", allowedMethods);
        restoreHeader(response, "Retry-After", retryAfter);
        response.setStatus(status);
        response.setCharacterEncoding(StandardCharsets.UTF_8.name());
        response.setContentType("application/json");
        response.setHeader("Cache-Control", "no-store");
        response.setHeader("X-Content-Type-Options", "nosniff");
        response.setContentLength(body.length);
        response.getOutputStream().write(body);
    }

    private void restoreHeader(HttpServletResponse response, String name, String value) {
        if (value != null) {
            response.setHeader(name, value);
        }
    }

    private ErrorDescription describe(int status) {
        switch (status) {
            case HttpServletResponse.SC_BAD_REQUEST:
                return new ErrorDescription("INVALID_REQUEST", "The request could not be processed.");
            case HttpServletResponse.SC_UNAUTHORIZED:
                return new ErrorDescription("UNAUTHORIZED", "Authentication is required.");
            case HttpServletResponse.SC_FORBIDDEN:
                return new ErrorDescription("FORBIDDEN", "The request is not permitted.");
            case HttpServletResponse.SC_NOT_FOUND:
                return new ErrorDescription("NOT_FOUND", "The requested resource was not found.");
            case HttpServletResponse.SC_METHOD_NOT_ALLOWED:
                return new ErrorDescription("METHOD_NOT_ALLOWED", "The request method is not supported.");
            case HttpServletResponse.SC_REQUEST_ENTITY_TOO_LARGE:
                return new ErrorDescription("PAYLOAD_TOO_LARGE", "The request payload is too large.");
            case HttpServletResponse.SC_UNSUPPORTED_MEDIA_TYPE:
                return new ErrorDescription("UNSUPPORTED_MEDIA_TYPE", "The request media type is not supported.");
            case 429:
                return new ErrorDescription("TOO_MANY_REQUESTS", "Too many requests.");
            default:
                if (status >= 500) {
                    return new ErrorDescription("SERVER_ERROR", "The server could not process the request.");
                }
                return new ErrorDescription("REQUEST_REJECTED", "The request was rejected.");
        }
    }

    private static class ErrorDescription {

        private final String code;

        private final String message;

        private ErrorDescription(String code, String message) {
            this.code = code;
            this.message = message;
        }
    }

    private static class BufferingResponseWrapper extends HttpServletResponseWrapper {

        private final ByteArrayOutputStream buffer = new ByteArrayOutputStream();

        private ServletOutputStream outputStream;

        private PrintWriter writer;

        private int status = HttpServletResponse.SC_OK;

        private boolean errorBody;

        private boolean passthrough;

        private ServletOutputStream responseOutputStream;

        private String authenticateHeader;

        private String allowedMethodsHeader;

        private String retryAfterHeader;

        private BufferingResponseWrapper(HttpServletResponse response) {
            super(response);
        }

        @Override
        public ServletOutputStream getOutputStream() {
            if (writer != null) {
                throw new IllegalStateException("getWriter() has already been called");
            }
            if (outputStream == null) {
                outputStream = createBufferingOutputStream();
            }
            return outputStream;
        }

        @Override
        public PrintWriter getWriter() {
            if (outputStream != null) {
                throw new IllegalStateException("getOutputStream() has already been called");
            }
            if (writer == null) {
                writer = new PrintWriter(new OutputStreamWriter(createBufferingOutputStream(), StandardCharsets.UTF_8));
            }
            return writer;
        }

        @Override
        public void resetBuffer() {
            flushWriter();
            super.resetBuffer();
            buffer.reset();
        }

        @Override
        public void reset() {
            flushWriter();
            super.reset();
            buffer.reset();
            status = HttpServletResponse.SC_OK;
            errorBody = false;
            authenticateHeader = null;
            allowedMethodsHeader = null;
            retryAfterHeader = null;
        }

        @Override
        public void flushBuffer() {
            flushWriter();
        }

        @Override
        public void sendError(int status) {
            resetBufferedBody();
            setStatus(status);
        }

        @Override
        public void sendError(int status, String message) {
            resetBufferedBody();
            setStatus(status);
        }

        @Override
        public void setStatus(int status) {
            this.status = status;
            this.errorBody = status >= 400;
            if (errorBody && !passthrough) {
                buffer.reset();
            }
            super.setStatus(status);
        }

        @Override
        @SuppressWarnings("deprecation")
        public void setStatus(int status, String message) {
            this.status = status;
            this.errorBody = status >= 400;
            if (errorBody && !passthrough) {
                buffer.reset();
            }
            super.setStatus(status, message);
        }

        @Override
        public void sendRedirect(String location) {
            resetBufferedBody();
            setStatus(HttpServletResponse.SC_FOUND);
            setHeader("Location", location);
        }

        @Override
        public void setHeader(String name, String value) {
            captureSafeHeader(name, value);
            super.setHeader(name, value);
        }

        @Override
        public void addHeader(String name, String value) {
            captureSafeHeader(name, value);
            super.addHeader(name, value);
        }

        private int getCapturedStatus() {
            return status;
        }

        private String getAuthenticateHeader() {
            return authenticateHeader;
        }

        private String getAllowedMethodsHeader() {
            return allowedMethodsHeader;
        }

        private String getRetryAfterHeader() {
            return retryAfterHeader;
        }

        private void captureSafeHeader(String name, String value) {
            if ("WWW-Authenticate".equalsIgnoreCase(name)) {
                authenticateHeader = value;
            }
            else if ("Allow".equalsIgnoreCase(name)) {
                allowedMethodsHeader = value;
            }
            else if ("Retry-After".equalsIgnoreCase(name)) {
                retryAfterHeader = value;
            }
        }

        private void resetBufferedBody() {
            if (!passthrough) {
                buffer.reset();
            }
        }

        private void copyBodyToResponse() throws IOException {
            flushWriter();
            if (passthrough) {
                return;
            }
            byte[] body = buffer.toByteArray();
            HttpServletResponse response = (HttpServletResponse) getResponse();
            if (body.length > 0) {
                response.getOutputStream().write(body);
            }
        }

        private void writeBytes(byte[] bytes, int offset, int length) throws IOException {
            if (errorBody) {
                return;
            }
            if (passthrough) {
                getResponseOutputStream().write(bytes, offset, length);
                return;
            }
            if (buffer.size() + length <= MAX_BUFFERED_SUCCESS_BYTES) {
                buffer.write(bytes, offset, length);
                return;
            }

            ServletOutputStream target = getResponseOutputStream();
            buffer.writeTo(target);
            buffer.reset();
            passthrough = true;
            target.write(bytes, offset, length);
        }

        private ServletOutputStream createBufferingOutputStream() {
            return new ServletOutputStream() {
                @Override
                public void write(int value) throws IOException {
                    writeBytes(new byte[] { (byte) value }, 0, 1);
                }

                @Override
                public void write(byte[] bytes, int offset, int length) throws IOException {
                    writeBytes(bytes, offset, length);
                }
            };
        }

        private ServletOutputStream getResponseOutputStream() throws IOException {
            if (responseOutputStream == null) {
                responseOutputStream = ((HttpServletResponse) getResponse()).getOutputStream();
            }
            return responseOutputStream;
        }

        private void flushWriter() {
            if (writer != null) {
                writer.flush();
            }
        }
    }
}
