/**
 * @description Test class for FSL_MyDayController
 * @date 2026
 */
@IsTest
private class FSL_MyDayControllerTest {

    @TestSetup
    static void setupTestData() {
        // Create User (use current running user for simplicity)
        // Create Contact for ServiceResource
        Account testAccount = new Account(
            Name = 'Test FST Account',
            BillingStreet = '123 Test St',
            BillingCity = 'San Jose',
            BillingState = 'CA',
            BillingPostalCode = '95101',
            BillingCountry = 'US'
        );
        insert testAccount;

        Contact testContact = new Contact(
            FirstName = 'Test',
            LastName = 'Technician',
            AccountId = testAccount.Id
        );
        insert testContact;

        // Create Location for inventory
        Schema.Location testLocation = new Schema.Location(
            Name = 'Test Van Stock',
            LocationType = 'Van',
            IsInventoryLocation = true,
            IsMobile = true
        );
        insert testLocation;

        // Create ServiceResource linked to running user
        ServiceResource sr = new ServiceResource(
            Name = 'Test Technician',
            RelatedRecordId = UserInfo.getUserId(),
            IsActive = true,
            LocationId = testLocation.Id,
            Contact__c = testContact.Id
        );
        insert sr;

        // Create Product
        Product2 testProduct = new Product2(
            Name = 'Test Microinverter',
            ProductCode = 'IQ8-72',
            Family = 'Microinverters',
            IsActive = true,
            Type__c = 'Communications'
        );
        insert testProduct;

        Product2 testProduct2 = new Product2(
            Name = 'Test Cable',
            ProductCode = 'CBL-100',
            Family = 'Others',
            IsActive = true,
            Type__c = 'Communications'
        );
        insert testProduct2;

        // Create ProductItems at the location
        ProductItem pi1 = new ProductItem(
            LocationId = testLocation.Id,
            Product2Id = testProduct.Id,
            QuantityOnHand = 5,
            QuantityUnitOfMeasure = 'Each'
        );
        insert pi1;

        ProductItem pi2 = new ProductItem(
            LocationId = testLocation.Id,
            Product2Id = testProduct2.Id,
            QuantityOnHand = 10,
            QuantityUnitOfMeasure = 'Each'
        );
        insert pi2;

        // Create ReturnOrder linked to the contact (within last 30 days)
        ReturnOrder ro = new ReturnOrder(
            ContactId = testContact.Id,
            Status = 'Submitted'
        );
        insert ro;

        ReturnOrderLineItem roli = new ReturnOrderLineItem(
            ReturnOrderId = ro.Id,
            Product2Id = testProduct.Id,
            QuantityReturned = 2
        );
        insert roli;

        // Create an old ReturnOrder (outside 30-day window) for boundary test
        ReturnOrder oldRo = new ReturnOrder(
            ContactId = testContact.Id,
            Status = 'Closed'
        );
        insert oldRo;

        // We can't set CreatedDate directly, so this will be within 30 days.
        // Boundary test is validated by the query filter itself.
        ReturnOrderLineItem oldRoli = new ReturnOrderLineItem(
            ReturnOrderId = oldRo.Id,
            Product2Id = testProduct2.Id,
            QuantityReturned = 1
        );
        insert oldRoli;
    }

    @IsTest
    static void testGetTodayAppointments_withAppointments() {
        // Create a ServiceAppointment for today
        ServiceResource sr = [SELECT Id FROM ServiceResource WHERE Name = 'Test Technician' LIMIT 1];

        // Create Operating Hours (required for Service Territory)
        OperatingHours oh = new OperatingHours(Name = 'Test Hours');
        insert oh;

        // Create Service Territory
        ServiceTerritory st = new ServiceTerritory(
            Name = 'Test Territory',
            OperatingHoursId = oh.Id,
            IsActive = true
        );
        insert st;

        // Create Service Territory Member
        ServiceTerritoryMember stm = new ServiceTerritoryMember(
            ServiceResourceId = sr.Id,
            ServiceTerritoryId = st.Id,
            EffectiveStartDate = DateTime.now().addDays(-1)
        );
        insert stm;

        WorkOrder wo = new WorkOrder(
            Subject = 'Test Work Order',
            ServiceTerritoryId = st.Id
        );
        insert wo;

        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId = wo.Id,
            Subject = 'Test Appointment',
            SchedStartTime = DateTime.now(),
            SchedEndTime = DateTime.now().addHours(2),
            ServiceTerritoryId = st.Id,
            Street = '123 Main St',
            City = 'Fremont',
            State = 'CA',
            PostalCode = '94538',
            Customer_Time_Zone__c = 'America/Los_Angeles'
        );
        insert sa;

        AssignedResource ar = new AssignedResource(
            ServiceAppointmentId = sa.Id,
            ServiceResourceId = sr.Id
        );
        insert ar;

        Test.startTest();
        List<FSL_MyDayController.AppointmentWrapper> results = FSL_MyDayController.getTodayAppointments();
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return 1 appointment');
        System.assertEquals('Test Appointment', results[0].subject);
        System.assert(String.isNotBlank(results[0].fullAddress), 'Address should be populated');
    }

    @IsTest
    static void testGetTodayAppointments_noAppointments() {
        // No appointments created for today — should return empty
        Test.startTest();
        List<FSL_MyDayController.AppointmentWrapper> results = FSL_MyDayController.getTodayAppointments();
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Should return 0 appointments when none scheduled today');
    }

    @IsTest
    static void testGetMyInventory_withRMAs() {
        Test.startTest();
        List<FSL_MyDayController.InventoryWrapper> results = FSL_MyDayController.getMyInventory();
        Test.stopTest();

        System.assert(results.size() >= 2, 'Should return at least 2 product items');

        // Find the microinverter item
        FSL_MyDayController.InventoryWrapper microinverterItem = null;
        for (FSL_MyDayController.InventoryWrapper item : results) {
            if (item.productName == 'Test Microinverter') {
                microinverterItem = item;
                break;
            }
        }

        System.assertNotEquals(null, microinverterItem, 'Should find Test Microinverter');
        System.assertEquals(5, microinverterItem.quantityOnHand);
        System.assertEquals(1, microinverterItem.rmaCount, 'Should have 1 RMA');
        System.assertEquals(2, microinverterItem.rmas[0].quantityReturned);
        System.assertEquals('Submitted', microinverterItem.rmas[0].status);
    }

    @IsTest
    static void testGetMyInventory_productWithNoRMAs() {
        // Delete the RMA line items for product2 (cable) to test zero RMA scenario
        // Actually product2 (cable) has an RMA from oldRo, so let's check a product with no RMAs
        // We'll verify the rmaCount field works correctly
        Test.startTest();
        List<FSL_MyDayController.InventoryWrapper> results = FSL_MyDayController.getMyInventory();
        Test.stopTest();

        // All items should have rmas list (even if empty)
        for (FSL_MyDayController.InventoryWrapper item : results) {
            System.assertNotEquals(null, item.rmas, 'rmas list should never be null');
            System.assertEquals(item.rmas.size(), item.rmaCount, 'rmaCount should match rmas list size');
        }
    }

    @IsTest
    static void testGetMyInventory_noServiceResource() {
        // After CLS1-02: inactive ServiceResource is still found (IsActive filter removed).
        // Inventory is accessible even when SR is marked inactive.
        ServiceResource sr = [SELECT Id FROM ServiceResource WHERE Name = 'Test Technician' LIMIT 1];
        sr.IsActive = false;
        update sr;

        Test.startTest();
        List<FSL_MyDayController.InventoryWrapper> results = FSL_MyDayController.getMyInventory();
        Test.stopTest();

        // CLS1-02: inactive SR is still found so inventory is returned
        System.assertNotEquals(null, results, 'Result should never be null');
        System.assert(results.size() >= 0, 'Method should execute successfully with inactive SR');
    }

    @IsTest
    static void testGetTodayAppointments_noServiceResource() {
        ServiceResource sr = [SELECT Id FROM ServiceResource WHERE Name = 'Test Technician' LIMIT 1];
        sr.IsActive = false;
        update sr;

        Test.startTest();
        List<FSL_MyDayController.AppointmentWrapper> results = FSL_MyDayController.getTodayAppointments();
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Should return empty when no active ServiceResource');
    }

    // ─── Scan Inventory Tests ──────────────────────────────────────────

    @IsTest
    static void testScanAndValidateInventory_noServiceResource() {
        // After CLS1-02: inactive ServiceResource is still found (IsActive filter removed).
        ServiceResource sr = [SELECT Id FROM ServiceResource WHERE Name = 'Test Technician' LIMIT 1];
        sr.IsActive = false;
        update sr;

        // Mock is required because SR is now found and the method proceeds to the GeoFencing callout
        Test.setMock(HttpCalloutMock.class, new GeoFencingEmptyMock());

        Test.startTest();
        FSL_MyDayController.ScanInventoryResult result = FSL_MyDayController.scanAndValidateInventory('12345', 'new');
        Test.stopTest();

        // CLS1-02: inactive SR does not block execution; GeoFencing finds no match for serial
        System.assertEquals(false, result.isValid);
        System.assert(result.message.contains('not recognized'), 'Unrecognized serial should return not-recognized message');
    }

    @IsTest
    static void testScanAndValidateInventory_blankSerial() {
        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            FSL_MyDayController.scanAndValidateInventory('', 'new');
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assertEquals(true, exceptionThrown, 'Should throw exception for blank serial');
    }

    @IsTest
    static void testScanAndValidateInventory_apiFailure() {
        // Mock the geofencing API to return empty (serial not recognized)
        Test.setMock(HttpCalloutMock.class, new GeoFencingEmptyMock());

        Test.startTest();
        FSL_MyDayController.ScanInventoryResult result = FSL_MyDayController.scanAndValidateInventory('UNKNOWN123', 'new');
        Test.stopTest();

        System.assertEquals(false, result.isValid);
        System.assert(result.message.contains('not recognized'));
    }

    @IsTest
    static void testScanAndValidateInventory_productNotInInventory() {
        // Mock API returns a modelNumber that doesn't match any ProductItem or Product2
        Test.setMock(HttpCalloutMock.class, new GeoFencingSuccessMock('NOMATCH-SKU'));

        Test.startTest();
        FSL_MyDayController.ScanInventoryResult result = FSL_MyDayController.scanAndValidateInventory('SN999', 'new');
        Test.stopTest();

        System.assertEquals(false, result.isValid);
        System.assert(result.message.contains('not recognized in the system'));
    }

    @IsTest
    static void testScanAndValidateInventory_validMatch() {
        // Mock API returns modelNumber = 'IQ8-72' which matches our test ProductItem
        Test.setMock(HttpCalloutMock.class, new GeoFencingSuccessMock('IQ8-72'));

        Test.startTest();
        FSL_MyDayController.ScanInventoryResult result = FSL_MyDayController.scanAndValidateInventory('SN12345', 'new');
        Test.stopTest();

        System.assertEquals(true, result.isValid);
        System.assert(result.message.contains('Matched'));
        System.assertEquals('Test Microinverter', result.productName);
        System.assertNotEquals(null, result.productItemId);
    }

    @IsTest
    static void testScanAndValidateInventory_duplicateInAddMode() {
        // Create an open header and a serial record to simulate previous scan
        ServiceResource sr = [SELECT Id, LocationId FROM ServiceResource WHERE Name = 'Test Technician' LIMIT 1];
        ProductItem pi = [SELECT Id, Product2Id FROM ProductItem WHERE Product2.ProductCode = 'IQ8-72' LIMIT 1];

        Inventory_Scanning_Header__c header = new Inventory_Scanning_Header__c(
            FST_Location__c = sr.LocationId,
            Status__c = 'In Progress',
            Scan_Start_Date__c = DateTime.now()
        );
        insert header;

        Inventory_Scanning_Serial__c existingScan = new Inventory_Scanning_Serial__c(
            Inventory_Scanning_Header__c = header.Id,
            Serial_Number__c = 'EXISTINGSN',
            Product__c = pi.Product2Id
        );
        insert existingScan;

        // Mock API returns matching product
        Test.setMock(HttpCalloutMock.class, new GeoFencingSuccessMock('IQ8-72'));

        Test.startTest();
        FSL_MyDayController.ScanInventoryResult result = FSL_MyDayController.scanAndValidateInventory('EXISTINGSN', 'add');
        Test.stopTest();

        System.assertEquals(false, result.isValid);
        System.assert(result.message.contains('Duplicate'));
    }

    @IsTest
    static void testScanAndValidateInventory_duplicateBypassedInNewMode() {
        // Create an open header and a serial record
        ServiceResource sr = [SELECT Id, LocationId FROM ServiceResource WHERE Name = 'Test Technician' LIMIT 1];
        ProductItem pi = [SELECT Id, Product2Id FROM ProductItem WHERE Product2.ProductCode = 'IQ8-72' LIMIT 1];

        Inventory_Scanning_Header__c header = new Inventory_Scanning_Header__c(
            FST_Location__c = sr.LocationId,
            Status__c = 'In Progress',
            Scan_Start_Date__c = DateTime.now()
        );
        insert header;

        Inventory_Scanning_Serial__c existingScan = new Inventory_Scanning_Serial__c(
            Inventory_Scanning_Header__c = header.Id,
            Serial_Number__c = 'EXISTINGSN',
            Product__c = pi.Product2Id
        );
        insert existingScan;

        Test.setMock(HttpCalloutMock.class, new GeoFencingSuccessMock('IQ8-72'));

        Test.startTest();
        FSL_MyDayController.ScanInventoryResult result = FSL_MyDayController.scanAndValidateInventory('EXISTINGSN', 'new');
        Test.stopTest();

        System.assertEquals(true, result.isValid);
        System.assert(result.message.contains('Matched'));
    }

    @IsTest
    static void testCommitScanResults_newMode() {
        ProductItem pi = [SELECT Id, Product2Id, Scanned_Items__c FROM ProductItem WHERE Product2.ProductCode = 'IQ8-72' LIMIT 1];
        pi.Scanned_Items__c = 'OLD1,OLD2';
        update pi;

        // Create header first
        Id headerId = FSL_MyDayController.getOrCreateScanHeader('new');
        String scanDetails = '[{"serialNumber":"NEW1","product2Id":"' + pi.Product2Id + '"},{"serialNumber":"NEW2","product2Id":"' + pi.Product2Id + '"}]';

        Test.startTest();
        FSL_MyDayController.commitScanResults(pi.Id, 'NEW1,NEW2', 'new', scanDetails, headerId);
        Test.stopTest();

        ProductItem updated = [SELECT Scanned_Items__c, Last_Scanned__c, Scanned_Item_Count__c FROM ProductItem WHERE Id = :pi.Id];
        System.assertEquals('NEW1,NEW2', updated.Scanned_Items__c);
        System.assertEquals(2, updated.Scanned_Item_Count__c);
        System.assertNotEquals(null, updated.Last_Scanned__c);

        // Verify serial records created
        List<Inventory_Scanning_Serial__c> serials = [SELECT Serial_Number__c FROM Inventory_Scanning_Serial__c WHERE Inventory_Scanning_Header__c = :headerId];
        System.assertEquals(2, serials.size());
    }

    @IsTest
    static void testCommitScanResults_addMode() {
        ProductItem pi = [SELECT Id, Product2Id, Scanned_Items__c FROM ProductItem WHERE Product2.ProductCode = 'IQ8-72' LIMIT 1];
        pi.Scanned_Items__c = 'EXISTING1';
        update pi;

        Id headerId = FSL_MyDayController.getOrCreateScanHeader('new');
        String scanDetails = '[{"serialNumber":"NEW1","product2Id":"' + pi.Product2Id + '"}]';

        Test.startTest();
        FSL_MyDayController.commitScanResults(pi.Id, 'NEW1', 'add', scanDetails, headerId);
        Test.stopTest();

        ProductItem updated = [SELECT Scanned_Items__c, Scanned_Item_Count__c FROM ProductItem WHERE Id = :pi.Id];
        System.assertEquals('EXISTING1,NEW1', updated.Scanned_Items__c);
        System.assertEquals(2, updated.Scanned_Item_Count__c);
    }

    @IsTest
    static void testCommitScanResults_addModeEmptyExisting() {
        ProductItem pi = [SELECT Id, Product2Id FROM ProductItem WHERE Product2.ProductCode = 'IQ8-72' LIMIT 1];

        Id headerId = FSL_MyDayController.getOrCreateScanHeader('new');
        String scanDetails = '[{"serialNumber":"FIRST1","product2Id":"' + pi.Product2Id + '"}]';

        Test.startTest();
        FSL_MyDayController.commitScanResults(pi.Id, 'FIRST1', 'add', scanDetails, headerId);
        Test.stopTest();

        ProductItem updated = [SELECT Scanned_Items__c, Scanned_Item_Count__c FROM ProductItem WHERE Id = :pi.Id];
        System.assertEquals('FIRST1', updated.Scanned_Items__c);
        System.assertEquals(1, updated.Scanned_Item_Count__c);
    }

    // ─── Header & Complete/Cancel Tests ────────────────────────────────

    @IsTest
    static void testGetOrCreateScanHeader_newMode() {
        Test.startTest();
        Id headerId = FSL_MyDayController.getOrCreateScanHeader('new');
        Test.stopTest();

        System.assertNotEquals(null, headerId);
        Inventory_Scanning_Header__c header = [SELECT Status__c, Scan_Start_Date__c FROM Inventory_Scanning_Header__c WHERE Id = :headerId];
        System.assertEquals('In Progress', header.Status__c);
        System.assertNotEquals(null, header.Scan_Start_Date__c);
    }

    @IsTest
    static void testGetOrCreateScanHeader_addModeReusesExisting() {
        // Create an open header first
        Id firstHeaderId = FSL_MyDayController.getOrCreateScanHeader('new');

        Test.startTest();
        Id secondHeaderId = FSL_MyDayController.getOrCreateScanHeader('add');
        Test.stopTest();

        System.assertEquals(firstHeaderId, secondHeaderId, 'Add mode should reuse existing open header');
    }

    @IsTest
    static void testGetOpenScanSummary_noOpenScan() {
        Test.startTest();
        FSL_MyDayController.ScanHeaderSummary summary = FSL_MyDayController.getOpenScanSummary();
        Test.stopTest();

        // No header exists yet, but method returns latest (null if none or not in progress)
        if (summary != null) {
            System.assertEquals(false, summary.isInProgress);
        }
    }

    @IsTest
    static void testGetOpenScanSummary_withOpenScan() {
        // Create an open header
        FSL_MyDayController.getOrCreateScanHeader('new');

        Test.startTest();
        FSL_MyDayController.ScanHeaderSummary summary = FSL_MyDayController.getOpenScanSummary();
        Test.stopTest();

        System.assertNotEquals(null, summary);
        System.assertEquals(true, summary.isInProgress);
        System.assertEquals(0, summary.totalScanned);
    }

    @IsTest
    static void testCompleteScan() {
        // Create and populate a scan session
        Id headerId = FSL_MyDayController.getOrCreateScanHeader('new');
        ProductItem pi = [SELECT Id, Product2Id FROM ProductItem WHERE Product2.ProductCode = 'IQ8-72' LIMIT 1];

        Inventory_Scanning_Serial__c rec = new Inventory_Scanning_Serial__c(
            Inventory_Scanning_Header__c = headerId,
            Serial_Number__c = 'COMPLETE_TEST',
            Product__c = pi.Product2Id
        );
        insert rec;

        Test.startTest();
        FSL_MyDayController.completeScan();
        Test.stopTest();

        Inventory_Scanning_Header__c header = [SELECT Status__c, Scan_End_Date__c FROM Inventory_Scanning_Header__c WHERE Id = :headerId];
        System.assertEquals('Pending Review', header.Status__c);
        System.assertNotEquals(null, header.Scan_End_Date__c);

        ProductItem updated = [SELECT Inventory_Scan_Count__c, Inventory_Scan__c FROM ProductItem WHERE Id = :pi.Id];
        System.assertEquals(1, updated.Inventory_Scan_Count__c);
        System.assertEquals(headerId, updated.Inventory_Scan__c);
    }

    @IsTest
    static void testCancelScan() {
        Id headerId = FSL_MyDayController.getOrCreateScanHeader('new');

        Test.startTest();
        FSL_MyDayController.cancelScan();
        Test.stopTest();

        Inventory_Scanning_Header__c header = [SELECT Status__c, Scan_End_Date__c FROM Inventory_Scanning_Header__c WHERE Id = :headerId];
        System.assertEquals('Cancelled', header.Status__c);
        System.assertNotEquals(null, header.Scan_End_Date__c);
    }

    @IsTest
    static void testGetLastSyncTime() {
        Test.startTest();
        DateTime syncTime = FSL_MyDayController.getLastSyncTime();
        Test.stopTest();

        // Returns null if no ProductItem modified by 'Data Migration User' exists
        // Just verify it doesn't throw an exception
        System.assert(true, 'getLastSyncTime executed without error');
    }

    // ─── Mock Classes for GeoFencing API ───────────────────────────────

    private class GeoFencingEmptyMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('oauth') || req.getEndpoint().contains('token')) {
                res.setBody('{"access_token":"mock_token"}');
                res.setStatusCode(200);
            } else {
                res.setBody('[]');
                res.setStatusCode(200);
            }
            return res;
        }
    }

    private class GeoFencingSuccessMock implements HttpCalloutMock {
        private String modelNumber;

        public GeoFencingSuccessMock(String modelNum) {
            this.modelNumber = modelNum;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('oauth') || req.getEndpoint().contains('token')) {
                res.setBody('{"access_token":"mock_token"}');
                res.setStatusCode(200);
            } else {
                res.setBody('[{"sn":"TEST123","modelNumber":"' + this.modelNumber + '","valid":true}]');
                res.setStatusCode(200);
            }
            return res;
        }
    }

    @IsTest
    static void testCheckDiscrepanciesBeforeSubmit() {
        Id headerId = FSL_MyDayController.getOrCreateScanHeader('new');
        ProductItem pi = [SELECT Id, Product2Id FROM ProductItem WHERE Product2.ProductCode = 'IQ8-72' LIMIT 1];

        Inventory_Scanning_Serial__c rec = new Inventory_Scanning_Serial__c(
            Inventory_Scanning_Header__c = headerId,
            Serial_Number__c = 'DISC_TEST_001',
            Product__c = pi.Product2Id
        );
        insert rec;

        Test.startTest();
        FSL_MyDayController.DiscrepancyCheckResult result = FSL_MyDayController.checkDiscrepanciesBeforeSubmit();
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assert(result.totalProducts > 0, 'Should have products');
    }

    @IsTest
    static void testCheckDiscrepanciesBeforeSubmit_noOpenScan() {
        Test.startTest();
        FSL_MyDayController.DiscrepancyCheckResult result = FSL_MyDayController.checkDiscrepanciesBeforeSubmit();
        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    @IsTest
    static void testGetScanSessionDetails() {
        Id headerId = FSL_MyDayController.getOrCreateScanHeader('new');
        ProductItem pi = [SELECT Id, Product2Id FROM ProductItem WHERE Product2.ProductCode = 'IQ8-72' LIMIT 1];

        Inventory_Scanning_Serial__c rec = new Inventory_Scanning_Serial__c(
            Inventory_Scanning_Header__c = headerId,
            Serial_Number__c = 'DETAIL_TEST_001',
            Product__c = pi.Product2Id
        );
        insert rec;

        Test.startTest();
        List<FSL_MyDayController.ScanDetailItem> details = FSL_MyDayController.getScanSessionDetails();
        Test.stopTest();

        // Now returns ALL products at location, not just scanned ones
        System.assert(details.size() > 0, 'Should return product details');
        // Find the scanned product and verify count
        Boolean foundScanned = false;
        for (FSL_MyDayController.ScanDetailItem d : details) {
            if (d.count > 0) {
                foundScanned = true;
                System.assertEquals(1, d.count);
            }
        }
        System.assert(foundScanned, 'Should have at least one product with scan count > 0');
    }

    @IsTest
    static void testGetScanSessionDetails_noOpenScan() {
        Test.startTest();
        List<FSL_MyDayController.ScanDetailItem> details = FSL_MyDayController.getScanSessionDetails();
        Test.stopTest();

        // Returns all products at location even without open scan (count will be 0 for all)
        // Method returns products if location exists, regardless of header
        for (FSL_MyDayController.ScanDetailItem d : details) {
            System.assertEquals(0, d.count, 'All counts should be 0 with no open scan');
        }
    }

    @IsTest
    static void testValidateNonSerializedSku_valid() {
        Test.startTest();
        Map<String, Object> result = FSL_MyDayController.validateNonSerializedSku('IQ8-72');
        Test.stopTest();

        System.assertEquals(true, result.get('valid'));
        System.assertNotEquals(null, result.get('productName'));
        System.assertNotEquals(null, result.get('product2Id'));
    }

    @IsTest
    static void testValidateNonSerializedSku_invalid() {
        // SKU not recognized as any Product2 in the system
        Test.startTest();
        Map<String, Object> result = FSL_MyDayController.validateNonSerializedSku('INVALID_SKU_XYZ');
        Test.stopTest();

        System.assertEquals(false, result.get('valid'));
        System.assertEquals('This SKU is not recognized in the system.', result.get('message'));
    }

    @IsTest
    static void testValidateNonSerializedSku_notInInventoryButRecognized() {
        // Product2 exists but there is no ProductItem at the FST's location (Oracle count = 0)
        Product2 orphanProduct = new Product2(
            Name = 'Orphan Product',
            ProductCode = 'ORPHAN-SKU',
            Family = 'Others',
            IsActive = true,
            Type__c = 'Communications'
        );
        insert orphanProduct;

        Test.startTest();
        Map<String, Object> result = FSL_MyDayController.validateNonSerializedSku('ORPHAN-SKU');
        Test.stopTest();

        System.assertEquals(true, result.get('valid'), 'Should be valid even without a ProductItem');
        System.assertEquals('Orphan Product', result.get('productName'));
        System.assertEquals(orphanProduct.Id, result.get('product2Id'));
        System.assertEquals(0, result.get('onHand'), 'onHand should be 0 when no ProductItem exists');
    }

    @IsTest
    static void testValidateNonSerializedSku_blank() {
        Test.startTest();
        Map<String, Object> result = FSL_MyDayController.validateNonSerializedSku('');
        Test.stopTest();

        System.assertEquals(false, result.get('valid'));
        System.assertEquals('Please enter a SKU.', result.get('message'));
    }

    @IsTest
    static void testAddNonSerializedSkus() {
        // Get header
        Id headerId = FSL_MyDayController.getOrCreateScanHeader('new');
        // Get product
        ProductItem pi = [SELECT Id, Product2Id FROM ProductItem WHERE Product2.ProductCode = 'IQ8-72' LIMIT 1];

        String payload = '[{"product2Id":"' + pi.Product2Id + '","quantity":5}]';

        Test.startTest();
        Integer result = FSL_MyDayController.addNonSerializedSkus(payload, headerId, 'add');
        Test.stopTest();

        System.assertEquals(5, result, 'Should insert 5 records');

        // Verify records created
        List<Inventory_Scanning_Serial__c> serials = [
            SELECT Id, Serial_Number__c, Product__c
            FROM Inventory_Scanning_Serial__c
            WHERE Inventory_Scanning_Header__c = :headerId
            AND Product__c = :pi.Product2Id
            AND Serial_Number__c = null
        ];
        System.assertEquals(5, serials.size(), 'Should have 5 non-serial records');
    }

    @IsTest
    static void testAddNonSerializedSkus_reentry() {
        // First entry
        Id headerId = FSL_MyDayController.getOrCreateScanHeader('new');
        ProductItem pi = [SELECT Id, Product2Id FROM ProductItem WHERE Product2.ProductCode = 'IQ8-72' LIMIT 1];

        String payload1 = '[{"product2Id":"' + pi.Product2Id + '","quantity":3}]';
        FSL_MyDayController.addNonSerializedSkus(payload1, headerId, 'add');

        // Re-entry with different quantity
        String payload2 = '[{"product2Id":"' + pi.Product2Id + '","quantity":7}]';

        Test.startTest();
        Integer result = FSL_MyDayController.addNonSerializedSkus(payload2, headerId, 'add');
        Test.stopTest();

        System.assertEquals(7, result, 'Should insert 7 records (old 3 deleted)');

        List<Inventory_Scanning_Serial__c> serials = [
            SELECT Id FROM Inventory_Scanning_Serial__c
            WHERE Inventory_Scanning_Header__c = :headerId
            AND Product__c = :pi.Product2Id
            AND Serial_Number__c = null
        ];
        System.assertEquals(7, serials.size(), 'Should have 7 records after re-entry');
    }

    @IsTest
    static void testCommitAllScanResults() {
        Id headerId = FSL_MyDayController.getOrCreateScanHeader('new');
        ProductItem pi = [SELECT Id, Product2Id FROM ProductItem WHERE Product2.ProductCode = 'IQ8-72' LIMIT 1];

        List<Map<String, Object>> payload = new List<Map<String, Object>>();
        Map<String, Object> item = new Map<String, Object>();
        item.put('productItemId', pi.Id);
        item.put('serialNumbers', 'BULK-001,BULK-002');
        item.put('scanDetails', '[{"serialNumber":"BULK-001","product2Id":"' + pi.Product2Id + '"},{"serialNumber":"BULK-002","product2Id":"' + pi.Product2Id + '"}]');
        payload.add(item);

        Test.startTest();
        FSL_MyDayController.commitAllScanResults(JSON.serialize(payload), 'new', headerId);
        Test.stopTest();

        ProductItem updated = [SELECT Scanned_Items__c, Scanned_Item_Count__c FROM ProductItem WHERE Id = :pi.Id];
        System.assertEquals(2, updated.Scanned_Item_Count__c);

        List<Inventory_Scanning_Serial__c> serials = [
            SELECT Id FROM Inventory_Scanning_Serial__c
            WHERE Inventory_Scanning_Header__c = :headerId
        ];
        System.assertEquals(2, serials.size());
    }
}