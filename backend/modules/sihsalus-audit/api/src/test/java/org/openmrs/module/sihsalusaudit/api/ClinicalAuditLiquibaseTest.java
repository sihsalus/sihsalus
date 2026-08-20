package org.openmrs.module.sihsalusaudit.api;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
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

        String[] recoverableChangeSets = {
                "sihsalusaudit-20260819-01-table",
                "sihsalusaudit-20260819-02-client-time",
                "sihsalusaudit-20260819-03-actor-fk",
                "sihsalusaudit-20260819-04-idempotency",
                "sihsalusaudit-20260819-05-timestamp-index",
                "sihsalusaudit-20260819-06-patient-index",
                "sihsalusaudit-20260819-07-no-update",
                "sihsalusaudit-20260819-08-no-delete"
        };
        for (String id : recoverableChangeSets) {
            Element changeSet = changeSet(document, id);
            NodeList preconditions = changeSet.getElementsByTagName("preConditions");
            assertEquals(1, preconditions.getLength());
            assertEquals("MARK_RAN", ((Element) preconditions.item(0)).getAttribute("onFail"));
        }

        Element validation = changeSet(document, "sihsalusaudit-20260819-09-validate");
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
        assertTrue(xmlText.contains("ACTION_STATEMENT"));
        assertTrue(xmlText.contains("signalsqlstate''45000''setmessage_text="));
        assertFalse(xmlText.contains("DROP TRIGGER"));

        String[] triggerChangeSets = {
                "sihsalusaudit-20260819-07-no-update",
                "sihsalusaudit-20260819-08-no-delete"
        };
        for (String id : triggerChangeSets) {
            Element trigger = changeSet(document, id);
            assertEquals("mysql,mariadb", trigger.getAttribute("dbms"));
            assertEquals("true", trigger.getAttribute("runAlways"));
        }
        Element databaseValidation = changeSet(document, "sihsalusaudit-20260819-10-mariadb-validate");
        assertEquals("mysql,mariadb", databaseValidation.getAttribute("dbms"));
        assertEquals("true", databaseValidation.getAttribute("runAlways"));
        assertEquals("HALT", ((Element) databaseValidation.getElementsByTagName("preConditions").item(0))
                .getAttribute("onFail"));
    }

    @Test
    public void validatesTheMariaDbPrimaryKeyByItsPortablePrimaryNameAndColumn() throws Exception {
        Document document = changelog();
        NodeList primaryKeyChecks = document.getElementsByTagName("primaryKeyExists");
        assertEquals(1, primaryKeyChecks.getLength());
        Element portableCheck = (Element) primaryKeyChecks.item(0);
        assertEquals("sihsalus_clinical_audit_event", portableCheck.getAttribute("tableName"));
        assertFalse(portableCheck.hasAttribute("primaryKeyName"));

        String xmlText = document.getDocumentElement().getTextContent();
        assertTrue(xmlText.contains("CONSTRAINT_NAME = 'PRIMARY'"));
        assertTrue(xmlText.contains("ORDINAL_POSITION = 1 AND COLUMN_NAME = 'audit_event_id'"));
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

    private Element changeSet(Document document, String id) {
        NodeList changeSets = document.getElementsByTagName("changeSet");
        for (int i = 0; i < changeSets.getLength(); i++) {
            Element changeSet = (Element) changeSets.item(i);
            if (id.equals(changeSet.getAttribute("id"))) {
                return changeSet;
            }
        }
        throw new AssertionError("Missing changeSet " + id);
    }
}
