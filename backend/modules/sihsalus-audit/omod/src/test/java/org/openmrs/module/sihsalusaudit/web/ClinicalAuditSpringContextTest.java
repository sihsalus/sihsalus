package org.openmrs.module.sihsalusaudit.web;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;
import static org.mockito.Mockito.mock;

import java.util.List;
import java.util.Map;

import org.junit.Test;
import org.openmrs.api.db.hibernate.DbSessionFactory;
import org.openmrs.module.sihsalusaudit.api.ClinicalAuditService;
import org.springframework.aop.support.AopUtils;
import org.springframework.beans.factory.support.ManagedList;
import org.springframework.beans.factory.support.RootBeanDefinition;
import org.springframework.beans.factory.xml.XmlBeanDefinitionReader;
import org.springframework.context.support.GenericApplicationContext;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;

public class ClinicalAuditSpringContextTest {

    @Test
    public void controllerReceivesTheOnlyTransactionalClinicalAuditService() {
        GenericApplicationContext root = rootContext();
        GenericApplicationContext web = new GenericApplicationContext(root);
        try {
            new XmlBeanDefinitionReader(web).loadBeanDefinitions("classpath:webModuleApplicationContext.xml");
            web.refresh();

            Map<String, ClinicalAuditService> services = root.getBeansOfType(ClinicalAuditService.class);
            assertEquals(1, services.size());
            ClinicalAuditService transactionalService = services.get("sihsalusClinicalAuditService");
            assertTrue(AopUtils.isAopProxy(transactionalService));

            ClinicalAuditController controller = web.getBean(ClinicalAuditController.class);
            assertSame(transactionalService, ReflectionTestUtils.getField(controller, "auditService"));
        }
        finally {
            web.close();
            root.close();
        }
    }

    private GenericApplicationContext rootContext() {
        GenericApplicationContext context = new GenericApplicationContext();
        context.getBeanFactory().registerSingleton("dbSessionFactory", mock(DbSessionFactory.class));
        context.getBeanFactory().registerSingleton("transactionManager", mock(PlatformTransactionManager.class));
        context.getBeanFactory().registerSingleton("serviceInterceptors", new Object[0]);

        RootBeanDefinition serviceContext = new RootBeanDefinition(ModuleServiceRegistrar.class);
        serviceContext.setAbstract(true);
        serviceContext.getPropertyValues().add("moduleService", new ManagedList<Object>());
        context.registerBeanDefinition("serviceContext", serviceContext);

        new XmlBeanDefinitionReader(context).loadBeanDefinitions("classpath:moduleApplicationContext.xml");
        context.refresh();
        return context;
    }

    public static class ModuleServiceRegistrar {

        public void setModuleService(List<Object> moduleService) {
            // The production parent registers the interface/proxy pair with OpenMRS. This test
            // parent needs only the same writable property so the real module XML can be loaded.
        }
    }
}
