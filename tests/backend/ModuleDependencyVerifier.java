import java.io.InputStream;
import java.io.StringReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;
import javax.xml.XMLConstants;
import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import org.openmrs.module.ModuleUtil;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.xml.sax.InputSource;

/** Offline distribution contract. Does not load module code or initialize OpenMRS. */
public final class ModuleDependencyVerifier {
    private static final String O3_PACKAGE = "org.openmrs.module.o3forms";

    private static final class Descriptor {
        final String id;
        final String version;
        final String packageName;
        final Map<String, String> required;

        Descriptor(Element module) {
            require("module".equals(module.getTagName()), "config.xml root must be module");
            id = requiredText(module, "id");
            version = requiredText(module, "version");
            packageName = requiredText(module, "package");
            required = new LinkedHashMap<>();
            List<Element> wrappers = children(module, "require_modules");
            require(wrappers.size() <= 1 && module.getElementsByTagName("require_modules").getLength() == wrappers.size(),
                    "required modules must have at most one direct wrapper in " + id);
            for (Element requirements : wrappers) {
                List<Element> dependencies = children(requirements, "require_module");
                require(requirements.getElementsByTagName("require_module").getLength() == dependencies.size(),
                        "required modules must be direct wrapper children in " + id);
                for (Element dependency : dependencies) {
                    String name = dependency.getTextContent().trim();
                    require(!name.isEmpty(), "empty required package in " + id);
                    require(!required.containsKey(name), "duplicate required package in " + id + ": " + name);
                    // Core's ModuleFileParser preserves an absent version as null.
                    required.put(name, dependency.hasAttribute("version") ? dependency.getAttribute("version") : null);
                }
            }
        }
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new IllegalArgumentException(message);
        }
    }

    private static List<Element> children(Element parent, String name) {
        List<Element> result = new ArrayList<>();
        for (Node node = parent.getFirstChild(); node != null; node = node.getNextSibling()) {
            if (node instanceof Element && name.equals(node.getNodeName())) {
                result.add((Element) node);
            }
        }
        return result;
    }

    private static String requiredText(Element module, String name) {
        List<Element> values = children(module, name);
        require(values.size() == 1, "expected exactly one module " + name);
        // Core reads the first matching descendant. A nested earlier value must
        // not shadow the direct identity; later conditional-resource values are valid.
        require(module.getElementsByTagName(name).item(0) == values.get(0), "nested value shadows module " + name);
        String value = values.get(0).getTextContent().trim();
        require(!value.isEmpty(), "empty module " + name);
        return value;
    }

    private static Descriptor read(Path artifact) throws Exception {
        require(Files.isRegularFile(artifact) && !Files.isSymbolicLink(artifact), "OMOD must be a regular file");
        try (ZipFile archive = new ZipFile(artifact.toFile())) {
            Set<String> entries = new HashSet<>();
            for (ZipEntry entry : Collections.list(archive.entries())) {
                require(entries.add(entry.getName()), "duplicate OMOD entry in " + artifact.getFileName());
            }
            ZipEntry config = archive.getEntry("config.xml");
            require(config != null && !config.isDirectory(), "missing config.xml in " + artifact.getFileName());
            require(config.getSize() >= 0 && config.getSize() <= 1024 * 1024, "config.xml exceeds 1 MiB");
            DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
            factory.setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true);
            factory.setFeature("http://xml.org/sax/features/external-general-entities", false);
            factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
            factory.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false);
            factory.setAttribute(XMLConstants.ACCESS_EXTERNAL_DTD, "");
            factory.setAttribute(XMLConstants.ACCESS_EXTERNAL_SCHEMA, "");
            factory.setXIncludeAware(false);
            factory.setExpandEntityReferences(false);
            DocumentBuilder builder = factory.newDocumentBuilder();
            builder.setEntityResolver((publicId, systemId) -> new InputSource(new StringReader("")));
            try (InputStream input = archive.getInputStream(config)) {
                Document document = builder.parse(input);
                // Published OpenMRS descriptors reference a DTD. Do not fetch it;
                // reject internal declarations instead of expanding custom entities.
                require(document.getDoctype() == null || document.getDoctype().getInternalSubset() == null,
                        "internal XML declarations are not permitted in config.xml");
                return new Descriptor(document.getDocumentElement());
            }
        }
    }

    private static int verify(Path modules) throws Exception {
        require(Files.isDirectory(modules), "module directory is missing");
        List<Path> artifacts = new ArrayList<>();
        try (var files = Files.newDirectoryStream(modules, "*.omod")) {
            files.forEach(artifacts::add);
        }
        Collections.sort(artifacts);
        require(!artifacts.isEmpty(), "no OMODs found");
        Map<String, Descriptor> packages = new LinkedHashMap<>();
        Set<String> identities = new HashSet<>();
        for (Path artifact : artifacts) {
            Descriptor module = read(artifact);
            require(identities.add(module.id), "duplicate module identity: " + module.id);
            require(!packages.containsKey(module.packageName), "duplicate module package: " + module.packageName);
            packages.put(module.packageName, module);
        }
        List<String> failures = new ArrayList<>();
        for (Descriptor consumer : packages.values()) {
            for (Map.Entry<String, String> dependency : consumer.required.entrySet()) {
                Descriptor provider = packages.get(dependency.getKey());
                String minimum = dependency.getValue();
                if (provider == null) {
                    failures.add(consumer.id + " requires missing package " + dependency.getKey());
                } else if (minimum != null && ModuleUtil.compareVersion(provider.version, minimum) < 0) {
                    // Same predicate as Core ModuleFactory.requiredModulesStarted:
                    // package identity plus compareVersion(actual, minimum) >= 0.
                    failures.add(consumer.id + " requires " + dependency.getKey() + " >= " + minimum
                            + "; packaged " + provider.version);
                }
            }
        }
        require(failures.isEmpty(), String.join("\n[FAIL] ", failures));
        return artifacts.size();
    }

    private static String descriptor(String id, String version, String packageName, String extra) {
        return "<module><id>" + id + "</id><version>" + version + "</version><package>"
                + packageName + "</package>" + extra + "</module>";
    }

    private static String dependency(String packageName, String version) {
        return "<require_modules><require_module" + (version == null ? "" : " version=\"" + version + "\"")
                + ">" + packageName + "</require_module></require_modules>";
    }

    private static void fixture(Path directory, String fileName, String xml) throws Exception {
        Files.createDirectories(directory);
        try (ZipOutputStream zip = new ZipOutputStream(Files.newOutputStream(directory.resolve(fileName)))) {
            zip.putNextEntry(new ZipEntry("config.xml"));
            zip.write(xml.getBytes(StandardCharsets.UTF_8));
            zip.closeEntry();
        }
    }

    private static void expectFailure(Path directory, String expected) throws Exception {
        try {
            verify(directory);
        } catch (IllegalArgumentException failure) {
            require(failure.getMessage().contains(expected), "wrong failure: " + failure.getMessage());
            return;
        }
        throw new IllegalArgumentException("invalid fixture accepted: " + directory.getFileName());
    }

    private static void selfTest(Path root) throws Exception {
        String patientDocuments = descriptor("patientdocuments", "1.2.0-sihsalus.1",
                "org.openmrs.module.patientdocuments", dependency(O3_PACKAGE, "2.3.0"));
        int cases = 0;
        for (String version : List.of("2.3.0-sihsalus.1", "2.3.0", "2.3.1-sihsalus.1", "2.4.0")) {
            Path directory = root.resolve("version-" + version);
            fixture(directory, "consumer.omod", patientDocuments);
            fixture(directory, "provider.omod", descriptor("o3forms", version, O3_PACKAGE, ""));
            if (version.equals("2.3.0-sihsalus.1")) {
                expectFailure(directory, "patientdocuments requires " + O3_PACKAGE + " >= 2.3.0; packaged " + version);
            } else {
                verify(directory);
            }
            cases++;
        }
        Path unversioned = root.resolve("unversioned");
        fixture(unversioned, "consumer.omod", descriptor("consumer", "1.0", "example.consumer", dependency(O3_PACKAGE, null)));
        fixture(unversioned, "provider.omod", descriptor("o3forms", "0.1", O3_PACKAGE, ""));
        verify(unversioned);
        cases++;
        for (String minimum : List.of("2.3.1", "2.4.0")) {
            Path directory = root.resolve("higher-minimum-" + minimum);
            fixture(directory, "consumer.omod", descriptor("consumer", "1.0", "example.consumer", dependency(O3_PACKAGE, minimum)));
            fixture(directory, "provider.omod", descriptor("o3forms", "2.3.1-sihsalus.1", O3_PACKAGE, ""));
            expectFailure(directory, "requires " + O3_PACKAGE + " >= " + minimum);
            cases++;
        }
        Path optional = root.resolve("optional");
        fixture(optional, "module.omod", descriptor("optional", "1.0", "example.optional",
                "<aware_of_modules><aware_of_module version=\"99.0\">missing.optional</aware_of_module></aware_of_modules>"));
        verify(optional);
        cases++;
        Path dtd = root.resolve("external-dtd-not-fetched");
        fixture(dtd, "module.omod", "<!DOCTYPE module SYSTEM \"file:///nonexistent-config.dtd\">"
                + descriptor("dtd", "1.0", "example.dtd", ""));
        verify(dtd);
        cases++;
        Path conditional = root.resolve("later-conditional-resource-version");
        fixture(conditional, "module.omod", descriptor("conditional", "1.0", "example.conditional",
                "<conditional_resources><conditionalResource><modules><module><version>99.0</version>"
                + "</module></modules></conditionalResource></conditional_resources>"));
        verify(conditional);
        cases++;
        Map<String, String[]> invalid = new LinkedHashMap<>();
        invalid.put("missing-package", new String[] {patientDocuments, "requires missing package"});
        invalid.put("empty-id", new String[] {descriptor("", "1.0", "example.module", ""), "empty module id"});
        invalid.put("empty-version", new String[] {descriptor("module", "", "example.module", ""), "empty module version"});
        invalid.put("empty-package", new String[] {descriptor("module", "1.0", "", ""), "empty module package"});
        invalid.put("missing-id", new String[] {"<module><version>1</version><package>example.module</package></module>", "exactly one module id"});
        invalid.put("duplicate-id-element", new String[] {descriptor("module", "1.0", "example.module", "<id>other</id>"), "exactly one module id"});
        invalid.put("empty-required-package", new String[] {descriptor("module", "1.0", "example.module", dependency("", null)), "empty required package"});
        invalid.put("duplicate-required-package", new String[] {descriptor("module", "1.0", "example.module",
                "<require_modules><require_module>missing</require_module><require_module version=\"1\">missing</require_module></require_modules>"), "duplicate required package"});
        invalid.put("duplicate-required-wrapper", new String[] {descriptor("module", "1.0", "example.module", dependency("one", null) + dependency("two", null)), "at most one direct wrapper"});
        invalid.put("nested-required-wrapper", new String[] {descriptor("module", "1.0", "example.module", "<wrapper>" + dependency("missing", null) + "</wrapper>"), "at most one direct wrapper"});
        invalid.put("nested-required-module", new String[] {descriptor("module", "1.0", "example.module",
                "<require_modules><wrapper><require_module version=\"99\">" + O3_PACKAGE + "</require_module></wrapper></require_modules>"), "direct wrapper children"});
        for (String name : List.of("id", "version", "package")) {
            invalid.put("shadow-" + name, new String[] {descriptor("module", "1.0", "example.module", "")
                    .replace("<module>", "<module><wrapper><" + name + ">0.1</" + name + "></wrapper>"), "nested value shadows module " + name});
        }
        invalid.put("internal-entity", new String[] {"<!DOCTYPE module [<!ENTITY version SYSTEM \"file:///nonexistent-secret\">]>"
                + descriptor("module", "&version;", "example.module", ""), "internal XML declarations"});
        for (Map.Entry<String, String[]> test : invalid.entrySet()) {
            Path directory = root.resolve(test.getKey());
            fixture(directory, "module.omod", test.getValue()[0]);
            expectFailure(directory, test.getValue()[1]);
            cases++;
        }
        for (boolean sameId : List.of(true, false)) {
            Path directory = root.resolve(sameId ? "duplicate-identity" : "duplicate-package");
            fixture(directory, "one.omod", descriptor("one", "1.0", "example.one", ""));
            fixture(directory, "two.omod", descriptor(sameId ? "one" : "two", "2.0", sameId ? "example.two" : "example.one", ""));
            expectFailure(directory, sameId ? "duplicate module identity" : "duplicate module package");
            cases++;
        }
        Path wrongPackage = root.resolve("id-is-not-package");
        fixture(wrongPackage, "consumer.omod", patientDocuments);
        fixture(wrongPackage, "provider.omod", descriptor("o3forms", "2.3.1-sihsalus.1", "example.wrong", ""));
        expectFailure(wrongPackage, "requires missing package");
        cases++;
        Path empty = Files.createDirectories(root.resolve("empty"));
        expectFailure(empty, "no OMODs found");
        cases++;
        System.out.println("[OK] Required OMOD dependency verifier: " + cases + " synthetic cases using packaged Core comparator");
    }

    public static void main(String[] args) throws Exception {
        try {
            if (args.length == 2 && "--self-test".equals(args[0])) {
                selfTest(Path.of(args[1]));
            } else {
                require(args.length == 1, "supply the packaged modules directory");
                int count = verify(Path.of(args[0]));
                System.out.println("[OK] All " + count + " OMOD identities/packages are unique and required module versions are compatible");
                System.out.println("[INFO] Static dependency contract only; module startup and clinical acceptance are NOT RUN");
            }
        } catch (Exception failure) {
            System.err.println("[FAIL] " + failure.getMessage());
            System.exit(1);
        }
    }
}
