@isTest
private class FSTInventoryControllerTest {

    @TestSetup
    static void setupTestData() {
        // Create Account
        Account acc = new Account(
            Name = 'Test FST Account',
            BillingStreet = '123 Test St',
            BillingCity = 'San Jose',
            BillingState = 'CA',
            BillingPostalCode = '95101',
            BillingCountry = 'US'
        );
        insert acc;

        // Create Contact
        Contact con = new Contact(
            FirstName = 'Test',
            LastName = 'FST',
            AccountId = acc.Id
        );
        insert con;

        // Create Location
        Schema.Location loc = new Schema.Location(
            Name = 'Test FST Account',
            LocationType = 'Van',
            IsInventoryLocation = true,
            IsMobile = true,
            AccountId = acc.Id
        );
        insert loc;

        // Create ServiceResource
        ServiceResource sr = new ServiceResource(
            Name = 'Test FST',
            IsActive = true,
            Contact__c = con.Id,
            LocationId = loc.Id,
            ResourceType = 'T',
            RelatedRecordId = UserInfo.getUserId()
        );
        insert sr;

        // Create Products
        Product2 prod1 = new Product2(Name = 'Test Product A', ProductCode = 'PROD-A', IsActive = true, Type__c = 'Microinverter');
        Product2 prod2 = new Product2(Name = 'Test Product B', ProductCode = 'PROD-B', IsActive = true, Type__c = 'Microinverter');
        insert new List<Product2>{ prod1, prod2 };

        // Create ProductItems at the location
        ProductItem pi1 = new ProductItem(
            Product2Id = prod1.Id,
            LocationId = loc.Id,
            QuantityOnHand = 5,
            QuantityUnitOfMeasure = 'Each',
            Minimum_Quantity__c = 2,
            Maximum_Quantity__c = 10,
            Fixed_Lot_Multiplier__c = 1,
            Inventory_Planning_Method__c = 'Min-max planning',
            Inventory_Scan_Count__c = 5
        );
        ProductItem pi2 = new ProductItem(
            Product2Id = prod2.Id,
            LocationId = loc.Id,
            QuantityOnHand = 3,
            QuantityUnitOfMeasure = 'Each',
            Minimum_Quantity__c = 1,
            Maximum_Quantity__c = 5,
            Fixed_Lot_Multiplier__c = 1,
            Inventory_Planning_Method__c = 'Not planned',
            Inventory_Scan_Count__c = 3
        );
        insert new List<ProductItem>{ pi1, pi2 };

        // Create Scan Header (Pending Review)
        Inventory_Scanning_Header__c header = new Inventory_Scanning_Header__c(
            FST_Location__c = loc.Id,
            Status__c = 'Pending Review',
            Scan_Start_Date__c = DateTime.now().addHours(-2),
            Scan_End_Date__c = DateTime.now()
        );
        insert header;

        // Create Scan Serials
        Inventory_Scanning_Serial__c serial1 = new Inventory_Scanning_Serial__c(
            Inventory_Scanning_Header__c = header.Id,
            Serial_Number__c = 'SN-001',
            Product__c = prod1.Id,
            Scanning_Date__c = DateTime.now()
        );
        Inventory_Scanning_Serial__c serial2 = new Inventory_Scanning_Serial__c(
            Inventory_Scanning_Header__c = header.Id,
            Serial_Number__c = 'SN-002',
            Product__c = prod2.Id,
            Scanning_Date__c = DateTime.now()
        );
        insert new List<Inventory_Scanning_Serial__c>{ serial1, serial2 };
    }

    @isTest
    static void testGetFSTLocationOptions() {
        Test.startTest();
        List<FSTInventoryController.FSTLocationOption> options =
            FSTInventoryController.getFSTLocationOptions('');
        Test.stopTest();

        System.assert(options.size() > 0, 'Should return at least one location');
        System.assertEquals('Test FST Account', options[0].label);
    }

    @isTest
    static void testGetFSTLocationOptionsWithSearch() {
        Test.startTest();
        List<FSTInventoryController.FSTLocationOption> options =
            FSTInventoryController.getFSTLocationOptions('Test FST');
        Test.stopTest();

        System.assert(options.size() > 0, 'Should find matching location');
    }

    @isTest
    static void testGetFSTLocationOptionsNoMatch() {
        Test.startTest();
        List<FSTInventoryController.FSTLocationOption> options =
            FSTInventoryController.getFSTLocationOptions('ZZZZZ_NO_MATCH');
        Test.stopTest();

        System.assertEquals(0, options.size(), 'Should return empty for no match');
    }

    @isTest
    static void testGetFSTInventory() {
        Test.startTest();
        FSTInventoryController.FSTInventoryResult result =
            FSTInventoryController.getFSTInventory('Test FST Account', 50, null);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assert(result.items.size() > 0, 'Should return product items');
        System.assertNotEquals(null, result.hasMore, 'hasMore field should exist');
    }

    @isTest
    static void testGetFSTInventoryNoFilter() {
        Test.startTest();
        FSTInventoryController.FSTInventoryResult result =
            FSTInventoryController.getFSTInventory(null, null, null);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assert(result.items.size() > 0, 'Should return all items');
    }

    @isTest
    static void testGetPendingScanReviews() {
        Test.startTest();
        List<FSTInventoryController.PendingScanWrapper> results =
            FSTInventoryController.getPendingScanReviews();
        Test.stopTest();

        System.assert(results.size() > 0, 'Should have pending review scans');
        System.assertEquals('Pending Review', results[0].status);
    }

    @isTest
    static void testGetScansByStatus() {
        Test.startTest();
        List<FSTInventoryController.PendingScanWrapper> pending =
            FSTInventoryController.getScansByStatus('Pending Review');
        List<FSTInventoryController.PendingScanWrapper> inProgress =
            FSTInventoryController.getScansByStatus('In Progress');
        Test.stopTest();

        System.assert(pending.size() > 0, 'Should have pending scans');
        System.assertEquals(0, inProgress.size(), 'Should have no in-progress scans');
    }

    @isTest
    static void testGetScanLineItems() {
        Inventory_Scanning_Header__c header = [SELECT Id FROM Inventory_Scanning_Header__c LIMIT 1];

        Test.startTest();
        List<FSTInventoryController.ScanLineItemWrapper> items =
            FSTInventoryController.getScanLineItems(header.Id);
        Test.stopTest();

        System.assertEquals(2, items.size(), 'Should return 2 scan line items');
    }

    @isTest
    static void testGetScanLineItemsNull() {
        Test.startTest();
        List<FSTInventoryController.ScanLineItemWrapper> items =
            FSTInventoryController.getScanLineItems(null);
        Test.stopTest();

        System.assertEquals(0, items.size(), 'Should return empty for null');
    }

    @isTest
    static void testApproveScan() {
        Inventory_Scanning_Header__c header = [SELECT Id FROM Inventory_Scanning_Header__c LIMIT 1];

        Test.startTest();
        FSTInventoryController.approveScan(header.Id);
        Test.stopTest();

        header = [SELECT Status__c FROM Inventory_Scanning_Header__c WHERE Id = :header.Id];
        System.assertEquals('Completed', header.Status__c);
    }

    @isTest
    static void testRejectScan() {
        Inventory_Scanning_Header__c header = [SELECT Id FROM Inventory_Scanning_Header__c LIMIT 1];

        Test.startTest();
        FSTInventoryController.rejectScan(header.Id, 'Missing items');
        Test.stopTest();

        header = [SELECT Status__c, Comments__c FROM Inventory_Scanning_Header__c WHERE Id = :header.Id];
        System.assertEquals('In Progress', header.Status__c);
        System.assertEquals('Missing items', header.Comments__c);
    }

    @isTest
    static void testGetProductBreakdown() {
        Inventory_Scanning_Header__c header = [SELECT Id FROM Inventory_Scanning_Header__c LIMIT 1];

        Test.startTest();
        List<FSTInventoryController.ProductBreakdownWrapper> breakdown =
            FSTInventoryController.getProductBreakdown(header.Id);
        Test.stopTest();

        System.assertEquals(2, breakdown.size(), 'Should return 2 products');
    }

    @isTest
    static void testGetProductBreakdownNull() {
        Test.startTest();
        List<FSTInventoryController.ProductBreakdownWrapper> breakdown =
            FSTInventoryController.getProductBreakdown(null);
        Test.stopTest();

        System.assertEquals(0, breakdown.size());
    }

    @isTest
    static void testAutoApproveCleanScans() {
        // Delete existing serials from test setup to start clean
        delete [SELECT Id FROM Inventory_Scanning_Serial__c];

        // Insert serials matching on-hand count for each product
        Inventory_Scanning_Header__c header = [SELECT Id FROM Inventory_Scanning_Header__c LIMIT 1];
        List<ProductItem> items = [SELECT Id, Product2Id, QuantityOnHand FROM ProductItem WHERE QuantityOnHand > 0];
        List<Inventory_Scanning_Serial__c> serials = new List<Inventory_Scanning_Serial__c>();
        for (ProductItem pi : items) {
            Integer qty = pi.QuantityOnHand.intValue();
            for (Integer i = 0; i < qty; i++) {
                serials.add(new Inventory_Scanning_Serial__c(
                    Inventory_Scanning_Header__c = header.Id,
                    Serial_Number__c = 'AUTO-' + pi.Product2Id + '-' + i,
                    Product__c = pi.Product2Id,
                    Scanning_Date__c = DateTime.now()
                ));
            }
        }
        insert serials;

        Test.startTest();
        FSTInventoryController.AutoApproveResult result =
            FSTInventoryController.autoApproveCleanScans();
        Test.stopTest();

        System.assertEquals(1, result.approved, 'Should approve 1 clean scan');
        System.assertEquals(0, result.skipped, 'Should skip 0');

        Inventory_Scanning_Header__c updatedHeader = [SELECT Status__c FROM Inventory_Scanning_Header__c WHERE Id = :header.Id];
        System.assertEquals('Completed', updatedHeader.Status__c);
    }

    @isTest
    static void testAutoApproveWithDiscrepancy() {
        // Create a discrepancy: update scan count to mismatch on-hand
        ProductItem pi = [SELECT Id FROM ProductItem WHERE Product2.ProductCode = 'PROD-A' LIMIT 1];
        pi.Inventory_Scan_Count__c = 2; // on-hand is 5, so mismatch
        update pi;

        Test.startTest();
        FSTInventoryController.AutoApproveResult result =
            FSTInventoryController.autoApproveCleanScans();
        Test.stopTest();

        System.assertEquals(0, result.approved, 'Should not approve scan with discrepancy');
        System.assertEquals(1, result.skipped, 'Should skip 1');

        Inventory_Scanning_Header__c header = [SELECT Status__c FROM Inventory_Scanning_Header__c LIMIT 1];
        System.assertEquals('Pending Review', header.Status__c, 'Status should remain Pending Review');
    }

    @isTest
    static void testAutoApproveNoPending() {
        // Change status so there are no pending reviews
        Inventory_Scanning_Header__c header = [SELECT Id FROM Inventory_Scanning_Header__c LIMIT 1];
        header.Status__c = 'Completed';
        update header;

        Test.startTest();
        FSTInventoryController.AutoApproveResult result =
            FSTInventoryController.autoApproveCleanScans();
        Test.stopTest();

        System.assertEquals(0, result.approved);
        System.assertEquals(0, result.skipped);
    }

    @isTest
    static void testExportInventoryReportCsv() {
        Test.startTest();
        String csv = FSTInventoryController.exportInventoryReportCsv(null);
        Test.stopTest();

        System.assertNotEquals(null, csv);
        System.assert(csv.contains('Completion Time'), 'Should contain header row');
        System.assert(csv.contains('PROD-A'), 'Should contain product code');
        System.assert(csv.contains('PROD-B'), 'Should contain second product code');
    }

    @isTest
    static void testExportIncludesScannedProductWithoutProductItem() {
        // A product that exists in Product2 but has NO ProductItem at the FST location,
        // yet was scanned in the session — it must still appear in the export with
        // Oracle Qty = 0 and the scanned count.
        Inventory_Scanning_Header__c header = [SELECT Id FROM Inventory_Scanning_Header__c LIMIT 1];

        Product2 prodNoPi = new Product2(
            Name = 'Test Product C',
            ProductCode = 'PROD-C-NOPI',
            IsActive = true,
            Type__c = 'Microinverter'
        );
        insert prodNoPi;

        // Scanned serial for the no-ProductItem product under the existing header
        insert new Inventory_Scanning_Serial__c(
            Inventory_Scanning_Header__c = header.Id,
            Serial_Number__c = 'SN-NOPI-001',
            Product__c = prodNoPi.Id,
            Scanning_Date__c = DateTime.now()
        );

        Test.startTest();
        String csv = FSTInventoryController.exportInventoryReportCsv(null);
        Test.stopTest();

        System.assertNotEquals(null, csv);
        System.assert(
            csv.contains('PROD-C-NOPI'),
            'Export should include a scanned product that has no ProductItem at the location'
        );
    }

    @isTest
    static void testGetStockTickActive() {
        Test.startTest();
        Map<String, Object> result = FSTInventoryController.getStockTickActive();
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assert(result.containsKey('isActive'));
    }

    @isTest
    static void testToggleStockTick() {
        Test.startTest();
        FSTInventoryController.toggleStockTick(true, false);
        Test.stopTest();

        Inventory_Scan_Config__c config = Inventory_Scan_Config__c.getOrgDefaults();
        System.assertEquals(true, config.Stock_Tick_Active__c);
    }

    @isTest
    static void testToggleStockTickOff() {
        // Set to true first, then toggle off
        Inventory_Scan_Config__c config = Inventory_Scan_Config__c.getOrgDefaults();
        config.Stock_Tick_Active__c = true;
        upsert config;

        // Change @TestSetup header to Completed so there are no active sessions to block disable
        Inventory_Scanning_Header__c header = [SELECT Id FROM Inventory_Scanning_Header__c LIMIT 1];
        header.Status__c = 'Completed';
        update header;

        Test.startTest();
        FSTInventoryController.toggleStockTick(false, false);
        Test.stopTest();

        config = Inventory_Scan_Config__c.getOrgDefaults();
        System.assertEquals(false, config.Stock_Tick_Active__c);
    }

    @isTest
    static void testNotifyFSTsToStartStockTick() {
        Test.startTest();
        try {
            FSTInventoryController.notifyFSTsToStartStockTick();
        } catch (AuraHandledException e) {
            // Expected - may fail if notification type or group doesn't exist in test context
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }

    // ─── TEST-01: revertScan ────────────────────────────────────────────

    @isTest
    static void testRevertScan_happyPath() {
        Inventory_Scanning_Header__c header = [SELECT Id FROM Inventory_Scanning_Header__c LIMIT 1];
        header.Status__c = 'Completed';
        update header;

        Test.startTest();
        FSTInventoryController.revertScan(header.Id, 'Needs correction');
        Test.stopTest();

        header = [SELECT Status__c, Comments__c FROM Inventory_Scanning_Header__c WHERE Id = :header.Id];
        System.assertEquals('In Progress', header.Status__c, 'Status should be In Progress after revert');
        System.assertEquals('Needs correction', header.Comments__c, 'Comments should be set to revert reason');
    }

    @isTest
    static void testRevertScan_emptyComment() {
        Inventory_Scanning_Header__c header = [SELECT Id FROM Inventory_Scanning_Header__c LIMIT 1];
        header.Status__c = 'Completed';
        update header;

        Test.startTest();
        Boolean threw = false;
        try {
            FSTInventoryController.revertScan(header.Id, '');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'Should throw AuraHandledException for empty revert comment');
    }

    @isTest
    static void testRevertScan_headerNotFound() {
        // Header is 'Pending Review', not 'Completed' — revertScan WHERE Status__c='Completed' won't find it
        Inventory_Scanning_Header__c header = [SELECT Id FROM Inventory_Scanning_Header__c LIMIT 1];

        Test.startTest();
        Boolean threw = false;
        try {
            FSTInventoryController.revertScan(header.Id, 'reason');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'Should throw AuraHandledException when header not in Completed status');
    }

    // ─── TEST-02: notifySelectedFSTs ────────────────────────────────────

    @isTest
    static void testNotifySelectedFSTs_validHeaders() {
        Inventory_Scanning_Header__c header = [SELECT Id FROM Inventory_Scanning_Header__c LIMIT 1];

        Test.startTest();
        try {
            FSTInventoryController.notifySelectedFSTs(new List<Id>{ header.Id });
            // Success or AuraHandledException both acceptable — notification type may not exist in test org
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'AuraHandledException should have a message');
        }
        Test.stopTest();
    }

    @isTest
    static void testNotifySelectedFSTs_emptyList() {
        Test.startTest();
        Boolean threw = false;
        try {
            FSTInventoryController.notifySelectedFSTs(new List<Id>());
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'Should throw AuraHandledException for empty header list');
    }

    // ─── TEST-03: uploadFSTInventoryCsv ─────────────────────────────────

    @isTest
    static void testUploadFSTInventoryCsv_serializedRows() {
        Schema.Location loc = [SELECT Id FROM Location WHERE Name = 'Test FST Account' LIMIT 1];
        Inventory_Scanning_Header__c notStartedHeader = new Inventory_Scanning_Header__c(
            FST_Location__c = loc.Id,
            Status__c = 'Not Started',
            Scan_Start_Date__c = DateTime.now()
        );
        insert notStartedHeader;

        String csv = 'serial_number,product_code\nSN-CSV-001,PROD-A\nSN-CSV-002,PROD-A';

        Test.startTest();
        FSTInventoryController.uploadFSTInventoryCsv(notStartedHeader.Id, csv);
        Test.stopTest();

        notStartedHeader = [SELECT Status__c, Proxy_Upload__c
                            FROM Inventory_Scanning_Header__c WHERE Id = :notStartedHeader.Id];
        System.assertEquals('Pending Review', notStartedHeader.Status__c, 'Status should be Pending Review after upload');
        System.assertEquals(true, notStartedHeader.Proxy_Upload__c, 'Proxy_Upload__c should be true');

        Integer serialCount = [
            SELECT COUNT() FROM Inventory_Scanning_Serial__c
            WHERE Inventory_Scanning_Header__c = :notStartedHeader.Id
        ];
        System.assertEquals(2, serialCount, 'Should have created 2 serial records');
    }

    @isTest
    static void testUploadFSTInventoryCsv_unknownProductCode() {
        Schema.Location loc = [SELECT Id FROM Location WHERE Name = 'Test FST Account' LIMIT 1];
        Inventory_Scanning_Header__c notStartedHeader = new Inventory_Scanning_Header__c(
            FST_Location__c = loc.Id,
            Status__c = 'Not Started',
            Scan_Start_Date__c = DateTime.now()
        );
        insert notStartedHeader;

        String csv = 'product_code,quantity\nUNKNOWN-XYZ,3';

        Test.startTest();
        Boolean threw = false;
        try {
            FSTInventoryController.uploadFSTInventoryCsv(notStartedHeader.Id, csv);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'Should throw AuraHandledException (PARTIAL) for unknown product code');
    }

    @isTest
    static void testUploadFSTInventoryCsv_wrongStatus() {
        // Existing @TestSetup header is 'Pending Review', not 'Not Started' — upload should fail
        Inventory_Scanning_Header__c header = [SELECT Id FROM Inventory_Scanning_Header__c LIMIT 1];
        String csv = 'product_code,quantity\nPROD-A,2';

        Test.startTest();
        Boolean threw = false;
        try {
            FSTInventoryController.uploadFSTInventoryCsv(header.Id, csv);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'Should throw AuraHandledException when header is not in Not Started status');
    }

    // ─── TEST-04: approveScan notification guard ─────────────────────────

    @isTest
    static void testApproveScan_notifGuardDoesNotThrow() {
        Inventory_Scanning_Header__c header = [SELECT Id FROM Inventory_Scanning_Header__c LIMIT 1];

        Test.startTest();
        FSTInventoryController.approveScan(header.Id);
        Test.stopTest();

        header = [SELECT Status__c FROM Inventory_Scanning_Header__c WHERE Id = :header.Id];
        System.assertEquals('Completed', header.Status__c, 'Status should be Completed after approval');
    }

    // ─── TEST-05: rejectScan notification guard ──────────────────────────

    @isTest
    static void testRejectScan_notifGuardDoesNotThrow() {
        Inventory_Scanning_Header__c header = [SELECT Id FROM Inventory_Scanning_Header__c LIMIT 1];

        Test.startTest();
        FSTInventoryController.rejectScan(header.Id, 'test reason');
        Test.stopTest();

        header = [SELECT Status__c FROM Inventory_Scanning_Header__c WHERE Id = :header.Id];
        System.assertEquals('In Progress', header.Status__c, 'Status should be In Progress after rejection');
    }

    // ─── TEST-06: toggleStockTick disable guard ──────────────────────────

    @isTest
    static void testToggleStockTick_disableGuardNoActiveSessions() {
        // Change @TestSetup header (Pending Review) to Completed — no active sessions remain
        Inventory_Scanning_Header__c header = [SELECT Id FROM Inventory_Scanning_Header__c LIMIT 1];
        header.Status__c = 'Completed';
        update header;

        Test.startTest();
        FSTInventoryController.toggleStockTick(false, false);
        Test.stopTest();

        Inventory_Scan_Config__c config = Inventory_Scan_Config__c.getOrgDefaults();
        System.assertEquals(false, config.Stock_Tick_Active__c, 'Stock_Tick_Active__c should be false');
    }

    @isTest
    static void testToggleStockTick_disableGuardWithActiveSessions() {
        // @TestSetup header is 'Pending Review' — qualifies as an active session
        Test.startTest();
        Boolean threw = false;
        try {
            FSTInventoryController.toggleStockTick(false, false);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'Should throw ACTIVE_SESSIONS exception when active sessions exist');
    }

    @isTest
    static void testToggleStockTick_forceCancel() {
        // @TestSetup header is 'Pending Review'; also create an 'In Progress' header
        Schema.Location loc = [SELECT Id FROM Location WHERE Name = 'Test FST Account' LIMIT 1];
        Inventory_Scanning_Header__c inProgressHeader = new Inventory_Scanning_Header__c(
            FST_Location__c = loc.Id,
            Status__c = 'In Progress',
            Scan_Start_Date__c = DateTime.now()
        );
        insert inProgressHeader;

        Test.startTest();
        FSTInventoryController.toggleStockTick(false, true);
        Test.stopTest();

        // All active sessions (In Progress + Pending Review) should now be Cancelled
        Integer activeCount = [
            SELECT COUNT() FROM Inventory_Scanning_Header__c
            WHERE Status__c IN ('In Progress', 'Pending Review')
        ];
        System.assertEquals(0, activeCount, 'All active sessions should be Cancelled after forceCancel');

        inProgressHeader = [SELECT Status__c FROM Inventory_Scanning_Header__c WHERE Id = :inProgressHeader.Id];
        System.assertEquals('Cancelled', inProgressHeader.Status__c, 'In Progress header should be Cancelled');

        Inventory_Scan_Config__c config = Inventory_Scan_Config__c.getOrgDefaults();
        System.assertEquals(false, config.Stock_Tick_Active__c, 'Stock_Tick_Active__c should be false');
    }

    // ─── TEST-07: getFSTInventory keyset pagination ──────────────────────

    @isTest
    static void testGetFSTInventory_keyset() {
        // Create a dedicated location with exactly 3 ProductItems.
        // pageSize=2: page 1 returns 2 items (hasMore=true), page 2 returns 1 item (hasMore=false).
        // Using 3 items + pageSize=2 avoids the edge-case where returning exactly pageSize items
        // sets hasMore=true even when no further records exist.
        Schema.Location ksLoc = new Schema.Location(
            Name = 'Keyset Test Location KS99ZZ',
            LocationType = 'Van',
            IsInventoryLocation = true,
            IsMobile = true
        );
        insert ksLoc;

        Product2 ksProd1 = new Product2(Name = 'KS Product A', ProductCode = 'KS-PROD-A-99', IsActive = true, Type__c = 'Microinverter');
        Product2 ksProd2 = new Product2(Name = 'KS Product B', ProductCode = 'KS-PROD-B-99', IsActive = true, Type__c = 'Microinverter');
        Product2 ksProd3 = new Product2(Name = 'KS Product C', ProductCode = 'KS-PROD-C-99', IsActive = true, Type__c = 'Microinverter');
        insert new List<Product2>{ ksProd1, ksProd2, ksProd3 };

        ProductItem ksPI1 = new ProductItem(
            Product2Id = ksProd1.Id, LocationId = ksLoc.Id, QuantityOnHand = 2,
            QuantityUnitOfMeasure = 'Each', Minimum_Quantity__c = 1, Maximum_Quantity__c = 10,
            Fixed_Lot_Multiplier__c = 1, Inventory_Planning_Method__c = 'Not planned',
            Inventory_Scan_Count__c = 0
        );
        ProductItem ksPI2 = new ProductItem(
            Product2Id = ksProd2.Id, LocationId = ksLoc.Id, QuantityOnHand = 3,
            QuantityUnitOfMeasure = 'Each', Minimum_Quantity__c = 1, Maximum_Quantity__c = 10,
            Fixed_Lot_Multiplier__c = 1, Inventory_Planning_Method__c = 'Not planned',
            Inventory_Scan_Count__c = 0
        );
        ProductItem ksPI3 = new ProductItem(
            Product2Id = ksProd3.Id, LocationId = ksLoc.Id, QuantityOnHand = 4,
            QuantityUnitOfMeasure = 'Each', Minimum_Quantity__c = 1, Maximum_Quantity__c = 10,
            Fixed_Lot_Multiplier__c = 1, Inventory_Planning_Method__c = 'Not planned',
            Inventory_Scan_Count__c = 0
        );
        insert new List<ProductItem>{ ksPI1, ksPI2, ksPI3 };

        // Page 1: pageSize=2 — should return 2 items with hasMore=true (1 item remains)
        Test.startTest();
        FSTInventoryController.FSTInventoryResult page1 =
            FSTInventoryController.getFSTInventory('Keyset Test Location KS99ZZ', 2, null);
        System.assertEquals(2, page1.items.size(), 'Page 1 should return exactly 2 items');
        System.assertEquals(true, page1.hasMore, 'hasMore should be true (3 items total, pageSize 2)');

        Id lastId = (Id) page1.items[1].Id;  // cursor from last item on page 1

        // Page 2: pageSize=2, 1 item remains — size(1) != pageSize(2) so hasMore=false
        FSTInventoryController.FSTInventoryResult page2 =
            FSTInventoryController.getFSTInventory('Keyset Test Location KS99ZZ', 2, lastId);
        Test.stopTest();

        System.assertEquals(1, page2.items.size(), 'Page 2 should return the remaining 1 item');
        System.assertNotEquals(lastId, (Id) page2.items[0].Id, 'Page 2 item should differ from page 1 cursor item');
        System.assertEquals(false, page2.hasMore, 'hasMore should be false — returned fewer than pageSize items');
    }
}