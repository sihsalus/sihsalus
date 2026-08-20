package org.openmrs.module.sihsalusaudit.api;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import java.io.InputStream;

import javax.xml.parsers.DocumentBuilderFactory;

import liquibase.changelog.ChangeLogParameters;
import liquibase.changelog.DatabaseChangeLog;
import liquibase.parser.ChangeLogParser;
import liquibase.parser.ChangeLogParserFactory;
import liquibase.resource.ClassLoaderResourceAccessor;
import org.junit.Test;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.NodeList;

public class ClinicalAuditLiquibaseTest {

    @Test
    public void parsesWithTheOpenmrsLiquibaseRuntime() throws Exception {
        try (ClassLoaderResourceAccessor resources = new ClassLoaderResourceAccessor(getClass().getClassLoader())) {
            ChangeLogParser parser = ChangeLogParserFactory.getInstance().getParser("liquibase.xml", resources);
            DatabaseChangeLog changeLog = parser.parse("liquibase.xml", new ChangeLogParameters(), resources);
            assertEquals(10, changeLog.getChangeSets().size());
        }
    }

    @Test
    public void usesRecoverableSingleOperationChangesetsAndFinalValidation() throws Exception {
        Document document = changelog();
        NodeList changeSets = document.getElementsByTagName("changeSet");
        assertEquals(10, changeSets.getLength());

        for (int i = 0; i < 8; i++) {
            Element changeSet = (Element) changeSets.item(i);
            NodeList preconditions = changeSet.getElementsByTagName("preConditions");
            assertEquals(1, preconditions.getLength());
            assertEquals("MARK_RAN", ((Element) preconditions.item(0)).getAttribute("onFail"));
        }

        Element validation = (Element) changeSets.item(8);
        assertEquals("true", validation.getAttribute("runAlways"));
        assertEquals("HALT", ((Element) validation.getElementsByTagName("preConditions").item(0))
                .getAttribute("onFail"));
        assertTrue(hasElementAttribute(document, "column", "name", "client_occurred_at"));
    }

    @Test
    public void installsMariaDbAppendOnlyTriggersAndRechecksThemOnStartup() throws Exception {
        Document document = changelog();
        String xmlText = document.getDocumentElement().getTextContent();
        assertTrue(xmlText.contains("CREATE TRIGGER sihsalus_audit_no_update"));
        assertTrue(xmlText.contains("CREATE TRIGGER sihsalus_audit_no_delete"));

        NodeList changeSets = document.getElementsByTagName("changeSet");
        for (int i = 6; i <= 7; i++) {
            Element trigger = (Element) changeSets.item(i);
            assertEquals("mysql,mariadb", trigger.getAttribute("dbms"));
            assertEquals("true", trigger.getAttribute("runAlways"));
        }
        Element databaseValidation = (Element) changeSets.item(9);
        assertEquals("mysql,mariadb", databaseValidation.getAttribute("dbms"));
        assertEquals("true", databaseValidation.getAttribute("runAlways"));
        assertEquals("HALT", ((Element) databaseValidation.getElementsByTagName("preConditions").item(0))
                .getAttribute("onFail"));
    }

    private Document changelog() throws Exception {
        try (InputStream input = getClass().getResourceAsStream("/liquibase.xml")) {
            assertNotNull("Packaged Liquibase changelog must be available", input);
            DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
            factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
            factory.setFeature("http://xml.org/sax/features/external-general-entities", false);
            factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
            return factory.newDocumentBuilder().parse(input);
        }
    }

    private boolean hasElementAttribute(Document document, String elementName, String attributeName,
            String expectedValue) {
        NodeList elements = document.getElementsByTagName(elementName);
        for (int i = 0; i < elements.getLength(); i++) {
            if (expectedValue.equals(((Element) elements.item(i)).getAttribute(attributeName))) {
                return true;
            }
        }
        return false;
    }
}
