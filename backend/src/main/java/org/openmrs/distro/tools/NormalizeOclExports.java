package org.openmrs.distro.tools;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.attribute.PosixFilePermission;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.zip.ZipOutputStream;

public final class NormalizeOclExports {

  private static final Pattern STRING_BOOLEAN_ALLOW_DECIMAL =
      Pattern.compile("(\"allow_decimal\"\\s*:\\s*)\"(True|False)\"");

  private NormalizeOclExports() {}

  public static void main(String[] args) throws IOException {
    if (args.length != 1) {
      throw new IllegalArgumentException("Usage: NormalizeOclExports <openmrs_config/ocl directory>");
    }

    Path oclDir = Paths.get(args[0]);
    if (!Files.exists(oclDir)) {
      System.out.println("[normalize-ocl] No OCL directory found: " + oclDir);
      return;
    }

    AtomicInteger scanned = new AtomicInteger();
    AtomicInteger patched = new AtomicInteger();

    Files.walkFileTree(
        oclDir,
        new SimpleFileVisitor<Path>() {
          @Override
          public FileVisitResult visitFile(Path file, BasicFileAttributes attrs) throws IOException {
            if (file.getFileName().toString().endsWith(".zip")) {
              scanned.incrementAndGet();
              if (normalizeZip(file)) {
                patched.incrementAndGet();
              }
            }
            return FileVisitResult.CONTINUE;
          }
        });

    System.out.println(
        "[normalize-ocl] Scanned " + scanned.get() + " OCL export zip(s), patched " + patched.get() + ".");
  }

  private static boolean normalizeZip(Path zipPath) throws IOException {
    Path tempZip = Files.createTempFile(zipPath.getParent(), zipPath.getFileName().toString(), ".tmp");
    boolean patched = false;

    try (ZipInputStream in = new ZipInputStream(Files.newInputStream(zipPath));
        ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(tempZip))) {
      ZipEntry entry;
      while ((entry = in.getNextEntry()) != null) {
        ZipEntry nextEntry = new ZipEntry(entry.getName());
        nextEntry.setTime(entry.getTime());
        out.putNextEntry(nextEntry);

        if (!entry.isDirectory()) {
          byte[] bytes = readAll(in);
          if ("export.json".equals(entry.getName())) {
            String original = new String(bytes, StandardCharsets.UTF_8);
            String normalized = normalizeExportJson(original);
            if (!normalized.equals(original)) {
              patched = true;
              bytes = normalized.getBytes(StandardCharsets.UTF_8);
            }
          }
          out.write(bytes);
        }

        out.closeEntry();
        in.closeEntry();
      }
    }

    if (patched) {
      preservePermissions(zipPath, tempZip);
      Files.move(tempZip, zipPath, StandardCopyOption.REPLACE_EXISTING);
      System.out.println("[normalize-ocl] Patched " + zipPath);
    } else {
      Files.deleteIfExists(tempZip);
    }

    return patched;
  }

  private static void preservePermissions(Path original, Path replacement) {
    try {
      Set<PosixFilePermission> permissions = Files.getPosixFilePermissions(original);
      Files.setPosixFilePermissions(replacement, permissions);
    } catch (UnsupportedOperationException | IOException e) {
      replacement.toFile().setReadable(true, false);
      replacement.toFile().setWritable(true, true);
      System.out.println(
          "[normalize-ocl] Could not preserve POSIX permissions for "
              + original
              + "; using readable fallback permissions.");
    }
  }

  private static String normalizeExportJson(String json) {
    Matcher matcher = STRING_BOOLEAN_ALLOW_DECIMAL.matcher(json);
    StringBuffer normalized = new StringBuffer();

    while (matcher.find()) {
      matcher.appendReplacement(normalized, matcher.group(1) + matcher.group(2).toLowerCase());
    }

    matcher.appendTail(normalized);
    return normalized.toString();
  }

  private static byte[] readAll(InputStream input) throws IOException {
    ByteArrayOutputStream output = new ByteArrayOutputStream();
    copy(input, output);
    return output.toByteArray();
  }

  private static void copy(InputStream input, OutputStream output) throws IOException {
    byte[] buffer = new byte[8192];
    int count;
    while ((count = input.read(buffer)) != -1) {
      output.write(buffer, 0, count);
    }
  }
}
