/**
 * @description Controller for the My Day LWC component in FSL Mobile App.
 *              Provides today's service appointments, location details, and inventory
 *              with RMA data for the logged-in technician.
 */
public with sharing class FSL_MyDayController {

    /**
     * @description Gets the ServiceResource for the current user with all needed fields
     * @return ServiceResource record or null if not found
     */
    private static ServiceResource getCurrentServiceResource() {
        Id userId = UserInfo.getUserId();
        List<ServiceResource> resources = [
            SELECT Id, Name, LocationId, Contact__c
            FROM ServiceResource
            WHERE RelatedRecordId = :userId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];
        return resources.isEmpty() ? null : resources[0];
    }

    /**
     * @description Gets today's service appointments for the current user's service resource
     * @return List of AppointmentWrapper containing appointment details
     */
    @AuraEnabled(cacheable=true)
    public static List<AppointmentWrapper> getTodayAppointments() {
        try {
            ServiceResource sr = getCurrentServiceResource();
            if (sr == null) {
                return new List<AppointmentWrapper>();
            }

            Date today = Date.today();
            DateTime startOfDay = DateTime.newInstance(today, Time.newInstance(0, 0, 0, 0));
            DateTime endOfDay = DateTime.newInstance(today, Time.newInstance(23, 59, 59, 0));

            List<ServiceAppointment> appointments = [
                SELECT Id, AppointmentNumber, Subject, Status,
                       SchedStartTime, SchedEndTime,
                       Street, City, State, PostalCode, Country,
                       Latitude, Longitude,
                       ParentRecordId
                FROM ServiceAppointment
                WHERE Id IN (
                    SELECT ServiceAppointmentId
                    FROM AssignedResource
                    WHERE ServiceResourceId = :sr.Id
                )
                AND SchedStartTime >= :startOfDay
                AND SchedStartTime <= :endOfDay
                WITH SECURITY_ENFORCED
                ORDER BY SchedStartTime ASC
            ];

            List<AppointmentWrapper> results = new List<AppointmentWrapper>();
            for (ServiceAppointment sa : appointments) {
                results.add(new AppointmentWrapper(sa));
            }
            return results;

        } catch (Exception e) {
            throw new AuraHandledException('Error loading appointments: ' + e.getMessage());
        }
    }

    /**
     * @description Gets the inventory (product items) with RMA data for the current user's service resource.
     *              Includes ReturnOrder data from the last 30 days grouped by Product2Id.
     * @return List of InventoryWrapper containing product item and RMA details
     */
    @AuraEnabled
    public static List<InventoryWrapper> getMyInventory() {
        try {
            ServiceResource sr = getCurrentServiceResource();
            if (sr == null) {
                return new List<InventoryWrapper>();
            }

            // Build set of location IDs from the service resource's primary location
            Set<Id> locationIds = new Set<Id>();
            if (sr.LocationId != null) {
                locationIds.add(sr.LocationId);
            }

            // Fallback: try locations owned by the user
            if (locationIds.isEmpty()) {
                Id userId = UserInfo.getUserId();
                List<Schema.Location> ownedLocations = [
                    SELECT Id FROM Location
                    WHERE OwnerId = :userId
                    WITH SECURITY_ENFORCED
                    LIMIT 5
                ];
                for (Schema.Location loc : ownedLocations) {
                    locationIds.add(loc.Id);
                }
            }

            if (locationIds.isEmpty()) {
                return new List<InventoryWrapper>();
            }

            // Get product items from the service resource's locations
            List<ProductItem> items = [
                SELECT Id, ProductName, QuantityOnHand, QuantityUnitOfMeasure,
                       Product2Id, Product2.Name, Product2.ProductCode, Product2.Family,
                       Product2.Description, Product2.IsSerialized,
                       Location.Name
                FROM ProductItem
                WHERE LocationId IN :locationIds
                AND QuantityOnHand > 0
                WITH SECURITY_ENFORCED
                ORDER BY Product2.Name ASC
                LIMIT 100
            ];

            if (items.isEmpty()) {
                return new List<InventoryWrapper>();
            }

            // Collect Product2 IDs for RMA lookup
            Set<Id> productIds = new Set<Id>();
            for (ProductItem pi : items) {
                if (pi.Product2Id != null) {
                    productIds.add(pi.Product2Id);
                }
            }

            // Query RMA data: ReturnOrderLineItems from last 30 days linked to FST's contact
            Map<Id, List<RMAWrapper>> rmasByProductId = new Map<Id, List<RMAWrapper>>();

            if (sr.Contact__c != null && !productIds.isEmpty()) {
                List<ReturnOrderLineItem> rmaLines = [
                    SELECT Id, Product2Id, QuantityReturned,
                           ReturnOrder.ReturnOrderNumber, ReturnOrder.Final_RMA_Number__c,
                           ReturnOrder.Status, ReturnOrder.CreatedDate
                    FROM ReturnOrderLineItem
                    WHERE ReturnOrder.ContactId = :sr.Contact__c
                    AND ReturnOrder.CreatedDate >= LAST_N_DAYS:30
                    AND Product2Id IN :productIds
                    WITH SECURITY_ENFORCED
                    ORDER BY ReturnOrder.CreatedDate DESC
                ];

                for (ReturnOrderLineItem roli : rmaLines) {
                    if (!rmasByProductId.containsKey(roli.Product2Id)) {
                        rmasByProductId.put(roli.Product2Id, new List<RMAWrapper>());
                    }
                    rmasByProductId.get(roli.Product2Id).add(new RMAWrapper(roli));
                }
            }

            // Build results with RMA data
            List<InventoryWrapper> results = new List<InventoryWrapper>();
            for (ProductItem pi : items) {
                List<RMAWrapper> rmas = rmasByProductId.containsKey(pi.Product2Id)
                    ? rmasByProductId.get(pi.Product2Id)
                    : new List<RMAWrapper>();
                results.add(new InventoryWrapper(pi, rmas));
            }
            return results;

        } catch (Exception e) {
            throw new AuraHandledException('Error loading inventory: ' + e.getMessage());
        }
    }

    /**
     * @description Validates a scanned serial number via the Geofencing API and returns the product details.
     *              Does NOT write to ProductItem — that happens on submit.
     * @param scannedSerial The barcode-scanned serial number
     * @return ScanInventoryResult with product match details
     */
    @AuraEnabled
    public static ScanInventoryResult scanAndValidateInventory(String scannedSerial, String scanMode) {
        try {
            if (String.isBlank(scannedSerial)) {
                throw new AuraHandledException('Serial number is required.');
            }

            // Get current FST's service resource
            ServiceResource sr = getCurrentServiceResource();
            if (sr == null) {
                return new ScanInventoryResult(scannedSerial, false, 'No active Service Resource found.', null, null, null);
            }

            // Get country from ServiceTerritory
            String country = 'US'; // default
            List<ServiceTerritoryMember> stmList = [
                SELECT ServiceTerritory.Country
                FROM ServiceTerritoryMember
                WHERE ServiceResourceId = :sr.Id
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (!stmList.isEmpty() && stmList[0].ServiceTerritory?.Country != null) {
                country = stmList[0].ServiceTerritory.Country;
            }

            // Call Geofencing API to validate serial and get modelNumber
            Map<String, Object> apiResponse = GeoFencingApiCallout.submitSerialNumbersV2(
                new List<String>{ scannedSerial }, country
            );

            String status = (String) apiResponse.get('status');
            String modelNumber = null;

            if (status == 'SUCCESS' && apiResponse.get('data') != null && String.isNotBlank((String) apiResponse.get('data'))) {
                String responseData = (String) apiResponse.get('data');
                List<Object> results = (List<Object>) JSON.deserializeUntyped(responseData);
                if (!results.isEmpty()) {
                    Map<String, Object> firstResult = (Map<String, Object>) results[0];
                    modelNumber = (String) firstResult.get('modelNumber');
                }
            }

            if (String.isBlank(modelNumber)) {
                logScanEvent('FSL_MyDayController.scanAndValidateInventory',
                    'GeoFencing API Failure', 'Failed',
                    'Serial: ' + scannedSerial + ', FST: ' + sr.Name,
                    'API Status: ' + status + ', Response: ' + (String) apiResponse.get('data'));
                return new ScanInventoryResult(scannedSerial, false, 'Serial number not recognized by the system.', null, null, null);
            }

            // Build location set for the FST
            Set<Id> locationIds = new Set<Id>();
            if (sr.LocationId != null) {
                locationIds.add(sr.LocationId);
            }
            if (locationIds.isEmpty()) {
                Id userId = UserInfo.getUserId();
                for (Schema.Location loc : [SELECT Id FROM Location WHERE OwnerId = :userId WITH SECURITY_ENFORCED LIMIT 5]) {
                    locationIds.add(loc.Id);
                }
            }

            if (locationIds.isEmpty()) {
                return new ScanInventoryResult(scannedSerial, false, 'No inventory location found for technician.', null, modelNumber, null);
            }

            // Match modelNumber to ProductItem via Product2.ProductCode (include zero-quantity items)
            List<ProductItem> matchingItems = [
                SELECT Id, Product2Id, ProductName, Product2.Name, Product2.ProductCode, QuantityOnHand, Scanned_Items__c
                FROM ProductItem
                WHERE Product2.ProductCode = :modelNumber
                AND LocationId IN :locationIds
                WITH SECURITY_ENFORCED
                ORDER BY QuantityOnHand DESC
                LIMIT 1
            ];

            // If no ProductItem exists at the FST's location at all, look up Product2 directly
            // so we can still record the scan (FST physically has the product but Oracle shows 0)
            String productItemId = null;
            String productName = null;
            Id product2Id = null;

            if (!matchingItems.isEmpty()) {
                ProductItem pi = matchingItems[0];
                productItemId = pi.Id;
                productName = pi.Product2.Name;
                product2Id = pi.Product2Id;
            } else {
                // No ProductItem at this location — resolve Product2 by ProductCode
                List<Product2> products = [
                    SELECT Id, Name FROM Product2
                    WHERE ProductCode = :modelNumber AND IsActive = true
                    WITH SECURITY_ENFORCED
                    LIMIT 1
                ];
                if (!products.isEmpty()) {
                    productName = products[0].Name;
                    product2Id = products[0].Id;
                } else {
                    return new ScanInventoryResult(scannedSerial, false,
                        'Product "' + modelNumber + '" not recognized in the system.', null, modelNumber, null);
                }
            }

            // Check for duplicate - query Inventory_Scanning_Serial__c under open header
            if (scanMode != 'new') {
                List<Inventory_Scanning_Serial__c> existingScans = [
                    SELECT Id
                    FROM Inventory_Scanning_Serial__c
                    WHERE Serial_Number__c = :scannedSerial
                    AND Inventory_Scanning_Header__c IN (
                        SELECT Id FROM Inventory_Scanning_Header__c
                        WHERE FST_Location__c = :sr.LocationId
                        AND Status__c = 'In Progress'
                    )
                    WITH SECURITY_ENFORCED
                    LIMIT 1
                ];
                if (!existingScans.isEmpty()) {
                    return new ScanInventoryResult(scannedSerial, false,
                        'Duplicate: ' + scannedSerial + ' was already scanned.', productItemId, modelNumber, productName);
                }
            }

            String matchMessage = productItemId != null
                ? 'Matched: ' + productName
                : 'Matched: ' + productName + ' (not in Oracle inventory)';
            ScanInventoryResult matchResult = new ScanInventoryResult(scannedSerial, true,
                matchMessage, productItemId, modelNumber, productName);
            matchResult.product2Id = product2Id;
            return matchResult;

        } catch (AuraHandledException ae) {
            throw ae;
        } catch (Exception e) {
            throw new AuraHandledException('Error during scan: ' + e.getMessage());
        }
    }

    /**
     * @description Commits scanned serial numbers to ProductItem.Scanned_Items__c
     *              and creates Inventory_Scanning_Serial__c records linked to a header.
     * @param productItemId The ProductItem to update
     * @param serialNumbers Comma-separated list of scanned serial numbers
     * @param scanMode 'new' to overwrite Scanned_Items__c, 'add' to append
     * @param scanDetails JSON array of [{serialNumber, product2Id}]
     */
    @AuraEnabled
    public static void commitScanResults(Id productItemId, String serialNumbers, String scanMode, String scanDetails, Id headerId) {
        try {
            if (productItemId == null || String.isBlank(serialNumbers)) {
                throw new AuraHandledException('Product Item and serial numbers are required.');
            }

            ProductItem pi = [
                SELECT Id, Scanned_Items__c, Last_Scanned__c
                FROM ProductItem
                WHERE Id = :productItemId
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];

            if (scanMode == 'new') {
                pi.Scanned_Items__c = serialNumbers;
            } else {
                String existing = String.isNotBlank(pi.Scanned_Items__c) ? pi.Scanned_Items__c : '';
                pi.Scanned_Items__c = String.isNotBlank(existing) ? existing + ',' + serialNumbers : serialNumbers;
            }
            pi.Last_Scanned__c = DateTime.now();
            pi.Scanned_Item_Count__c = String.isNotBlank(pi.Scanned_Items__c) ? pi.Scanned_Items__c.split(',').size() : 0;
            update pi;

            // Create Inventory_Scanning_Serial__c records linked to header
            if (String.isNotBlank(scanDetails) && headerId != null) {
                List<ScanDetailInput> details = (List<ScanDetailInput>) JSON.deserialize(
                    scanDetails, List<ScanDetailInput>.class
                );
                List<Inventory_Scanning_Serial__c> scanRecords = new List<Inventory_Scanning_Serial__c>();
                for (ScanDetailInput detail : details) {
                    Inventory_Scanning_Serial__c rec = new Inventory_Scanning_Serial__c();
                    rec.Inventory_Scanning_Header__c = headerId;
                    rec.Serial_Number__c = detail.serialNumber;
                    rec.Scanning_Date__c = DateTime.now();
                    if (String.isNotBlank(detail.product2Id)) {
                        rec.Product__c = detail.product2Id;
                    }
                    scanRecords.add(rec);
                }
                if (!scanRecords.isEmpty()) {
                    insert scanRecords;
                }
            }

        } catch (AuraHandledException ae) {
            throw ae;
        } catch (Exception e) {
            throw new AuraHandledException('Error saving scans: ' + e.getMessage() + ' | Line: ' + e.getLineNumber());
        }
    }

    /**
     * @description Bulk version of commitScanResults — processes all ProductItems in one transaction.
     * @param bulkPayload JSON array of [{productItemId, serialNumbers, scanDetails}]
     * @param scanMode 'new' or 'add'
     * @param headerId The scan session header Id
     */
    @AuraEnabled
    public static void commitAllScanResults(String bulkPayload, String scanMode, Id headerId) {
        try {
            if (String.isBlank(bulkPayload) || headerId == null) {
                throw new AuraHandledException('Payload and header ID are required.');
            }

            List<Object> rawItems = (List<Object>) JSON.deserializeUntyped(bulkPayload);

            // Collect all ProductItem IDs (skip nulls from scans without a ProductItem)
            Set<Id> piIds = new Set<Id>();
            for (Object obj : rawItems) {
                Map<String, Object> item = (Map<String, Object>) obj;
                Object piIdObj = item.get('productItemId');
                if (piIdObj != null && String.isNotBlank(String.valueOf(piIdObj))) {
                    piIds.add((Id) piIdObj);
                }
            }

            // Single query for all ProductItems
            Map<Id, ProductItem> piMap = new Map<Id, ProductItem>();
            if (!piIds.isEmpty()) {
                piMap = new Map<Id, ProductItem>([
                    SELECT Id, Scanned_Items__c, Last_Scanned__c
                    FROM ProductItem
                    WHERE Id IN :piIds
                    WITH SECURITY_ENFORCED
                ]);
            }

            List<ProductItem> itemsToUpdate = new List<ProductItem>();
            List<Inventory_Scanning_Serial__c> allScanRecords = new List<Inventory_Scanning_Serial__c>();

            for (Object obj : rawItems) {
                Map<String, Object> item = (Map<String, Object>) obj;
                Object piIdObj = item.get('productItemId');
                Id piId = (piIdObj != null && String.isNotBlank(String.valueOf(piIdObj)))
                    ? (Id) piIdObj : null;
                String serialNumbers = (String) item.get('serialNumbers');
                String scanDetails = (String) item.get('scanDetails');

                // Update ProductItem scanned items (only if a ProductItem exists)
                if (piId != null && String.isNotBlank(serialNumbers)) {
                    ProductItem pi = piMap.get(piId);
                    if (pi != null) {
                        if (scanMode == 'new') {
                            pi.Scanned_Items__c = serialNumbers;
                        } else {
                            String existing = String.isNotBlank(pi.Scanned_Items__c) ? pi.Scanned_Items__c : '';
                            pi.Scanned_Items__c = String.isNotBlank(existing) ? existing + ',' + serialNumbers : serialNumbers;
                        }
                        pi.Last_Scanned__c = DateTime.now();
                        pi.Scanned_Item_Count__c = String.isNotBlank(pi.Scanned_Items__c) ? pi.Scanned_Items__c.split(',').size() : 0;
                        itemsToUpdate.add(pi);
                    }
                }

                // Build serial records
                if (String.isNotBlank(scanDetails)) {
                    List<ScanDetailInput> details = (List<ScanDetailInput>) JSON.deserialize(
                        scanDetails, List<ScanDetailInput>.class
                    );
                    for (ScanDetailInput detail : details) {
                        Inventory_Scanning_Serial__c rec = new Inventory_Scanning_Serial__c();
                        rec.Inventory_Scanning_Header__c = headerId;
                        rec.Serial_Number__c = detail.serialNumber;
                        rec.Scanning_Date__c = DateTime.now();
                        if (String.isNotBlank(detail.product2Id)) {
                            rec.Product__c = detail.product2Id;
                        }
                        allScanRecords.add(rec);
                    }
                }
            }

            // Single bulk DML operations
            if (!itemsToUpdate.isEmpty()) {
                update itemsToUpdate;
            }
            if (!allScanRecords.isEmpty()) {
                insert allScanRecords;
            }

        } catch (AuraHandledException ae) {
            throw ae;
        } catch (Exception e) {
            throw new AuraHandledException('Error saving scans: ' + e.getMessage());
        }
    }

    /**
     * @description Gets or creates a scan header. Called once before submitting scans.
     * @param scanMode 'new' creates a new header; 'add' finds existing open one
     * @return Id of the scan header
     */
    @AuraEnabled
    public static Id getOrCreateScanHeader(String scanMode) {
        ServiceResource sr = getCurrentServiceResource();
        Id locationId = sr != null ? sr.LocationId : null;
        return getOrCreateScanHeaderInternal(scanMode, locationId);
    }

    /**
     * @description Gets an existing open scan header or creates a new one.
     * @param scanMode 'new' always creates a new header; 'add' finds existing open one
     * @param locationId The FST's location Id
     * @return Id of the scan header
     */
    private static Id getOrCreateScanHeaderInternal(String scanMode, Id locationId) {
        // For 'add' mode, look for an existing open header for this FST's location
        if (scanMode != 'new' && locationId != null) {
            List<Inventory_Scanning_Header__c> openHeaders = [
                SELECT Id
                FROM Inventory_Scanning_Header__c
                WHERE FST_Location__c = :locationId
                AND Status__c = 'In Progress'
                WITH SECURITY_ENFORCED
                ORDER BY Scan_Start_Date__c DESC
                LIMIT 1
            ];
            if (!openHeaders.isEmpty()) {
                return openHeaders[0].Id;
            }
        }

        // Create new header
        Inventory_Scanning_Header__c header = new Inventory_Scanning_Header__c();
        header.Scan_Start_Date__c = DateTime.now();
        header.Status__c = 'In Progress';
        if (locationId != null) {
            header.FST_Location__c = locationId;
        }
        insert header;
        return header.Id;
    }

    /**
     * @description Gets the latest scan header summary for the current FST.
     *              Returns null if no open scan exists.
     * @return ScanHeaderSummary with status, count, and start date
     */
    @AuraEnabled
    public static ScanHeaderSummary getOpenScanSummary() {
        try {
            ServiceResource sr = getCurrentServiceResource();
            if (sr == null || sr.LocationId == null) {
                return null;
            }

            List<Inventory_Scanning_Header__c> headers = [
                SELECT Id, Status__c, Scan_Start_Date__c, Total_Serial_Numbers_Scanned__c
                FROM Inventory_Scanning_Header__c
                WHERE FST_Location__c = :sr.LocationId
                WITH SECURITY_ENFORCED
                ORDER BY Scan_Start_Date__c DESC
                LIMIT 1
            ];

            if (headers.isEmpty()) {
                return null;
            }

            Inventory_Scanning_Header__c header = headers[0];
            ScanHeaderSummary summary = new ScanHeaderSummary();
            summary.headerId = header.Id;
            summary.status = header.Status__c;
            summary.isInProgress = header.Status__c == 'In Progress';
            summary.totalScanned = header.Total_Serial_Numbers_Scanned__c != null
                ? Integer.valueOf(header.Total_Serial_Numbers_Scanned__c) : 0;
            summary.scanStartDate = header.Scan_Start_Date__c;

            // Get the most recent scan date from serials
            List<AggregateResult> lastScan = [
                SELECT MAX(Scanning_Date__c) latestScan
                FROM Inventory_Scanning_Serial__c
                WHERE Inventory_Scanning_Header__c = :header.Id
                WITH SECURITY_ENFORCED
            ];
            if (!lastScan.isEmpty() && lastScan[0].get('latestScan') != null) {
                summary.lastScanDate = (DateTime) lastScan[0].get('latestScan');
            }

            return summary;

        } catch (Exception e) {
            return null;
        }
    }

    public class ScanHeaderSummary {
        @AuraEnabled public String headerId;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean isInProgress;
        @AuraEnabled public Integer totalScanned;
        @AuraEnabled public DateTime scanStartDate;
        @AuraEnabled public DateTime lastScanDate;
    }

    /**
     * @description Gets scan details grouped by product for the current open scan session.
     * @return List of ScanDetailItem with product name and count
     */
    @AuraEnabled
    public static List<ScanDetailItem> getScanSessionDetails() {
        try {
            ServiceResource sr = getCurrentServiceResource();
            if (sr == null || sr.LocationId == null) {
                return new List<ScanDetailItem>();
            }

            List<Inventory_Scanning_Header__c> headers = [
                SELECT Id FROM Inventory_Scanning_Header__c
                WHERE FST_Location__c = :sr.LocationId
                AND Status__c = 'In Progress'
                WITH SECURITY_ENFORCED
                ORDER BY Scan_Start_Date__c DESC
                LIMIT 1
            ];

            // Get scan counts grouped by Product (from current session)
            Map<Id, Integer> scanCountByProduct = new Map<Id, Integer>();
            if (!headers.isEmpty()) {
                for (AggregateResult ar : [
                    SELECT Product__c productId, COUNT(Id) scanCount
                    FROM Inventory_Scanning_Serial__c
                    WHERE Inventory_Scanning_Header__c = :headers[0].Id
                    AND Product__c != null
                    WITH SECURITY_ENFORCED
                    GROUP BY Product__c
                ]) {
                    scanCountByProduct.put((Id) ar.get('productId'), (Integer) ar.get('scanCount'));
                }
            }

            // Get ALL ProductItems at the FST's location (including zero qty)
            List<ScanDetailItem> details = new List<ScanDetailItem>();
            Set<Id> coveredProductIds = new Set<Id>();
            for (ProductItem pi : [
                SELECT Id, Product2Id, Product2.Name, QuantityOnHand
                FROM ProductItem
                WHERE LocationId = :sr.LocationId
                AND QuantityOnHand > 0
                WITH SECURITY_ENFORCED
                ORDER BY Product2.Name
            ]) {
                ScanDetailItem item = new ScanDetailItem();
                item.productName = pi.Product2?.Name;
                item.count = scanCountByProduct.containsKey(pi.Product2Id)
                    ? scanCountByProduct.get(pi.Product2Id) : 0;
                item.onHand = pi.QuantityOnHand != null ? Integer.valueOf(pi.QuantityOnHand) : 0;
                details.add(item);
                coveredProductIds.add(pi.Product2Id);
            }

            // Add scanned products that have no ProductItem at this location (Oracle count = 0)
            Set<Id> uncoveredProductIds = new Set<Id>();
            for (Id prodId : scanCountByProduct.keySet()) {
                if (!coveredProductIds.contains(prodId)) {
                    uncoveredProductIds.add(prodId);
                }
            }
            if (!uncoveredProductIds.isEmpty()) {
                Map<Id, String> productNames = new Map<Id, String>();
                for (Product2 p : [SELECT Id, Name FROM Product2 WHERE Id IN :uncoveredProductIds WITH SECURITY_ENFORCED]) {
                    productNames.put(p.Id, p.Name);
                }
                for (Id prodId : uncoveredProductIds) {
                    ScanDetailItem item = new ScanDetailItem();
                    item.productName = productNames.containsKey(prodId) ? productNames.get(prodId) : 'Unknown Product';
                    item.count = scanCountByProduct.get(prodId);
                    item.onHand = 0;
                    details.add(item);
                }
            }
            return details;
        } catch (Exception e) {
            return new List<ScanDetailItem>();
        }
    }

    public class ScanDetailItem {
        @AuraEnabled public String productName;
        @AuraEnabled public Integer count;
        @AuraEnabled public Integer onHand;
    }

    /**
     * @description Checks for discrepancies between scanned counts and on-hand quantities
     *              for all products at the FST's location before final submission.
     * @return DiscrepancyCheckResult with total products and discrepancy count
     */
    @AuraEnabled
    public static DiscrepancyCheckResult checkDiscrepanciesBeforeSubmit() {
        try {
            ServiceResource sr = getCurrentServiceResource();
            if (sr == null || sr.LocationId == null) {
                return new DiscrepancyCheckResult(0, 0);
            }

            // Get all ProductItems at the FST's location
            List<ProductItem> allItems = [
                SELECT Id, Product2Id, QuantityOnHand
                FROM ProductItem
                WHERE LocationId = :sr.LocationId
                AND QuantityOnHand > 0
                WITH SECURITY_ENFORCED
            ];

            // Get open header
            List<Inventory_Scanning_Header__c> headers = [
                SELECT Id FROM Inventory_Scanning_Header__c
                WHERE FST_Location__c = :sr.LocationId
                AND Status__c = 'In Progress'
                WITH SECURITY_ENFORCED
                ORDER BY Scan_Start_Date__c DESC
                LIMIT 1
            ];

            // Get scan counts grouped by Product2Id
            Map<Id, Integer> scanCountByProduct = new Map<Id, Integer>();
            if (!headers.isEmpty()) {
                for (AggregateResult ar : [
                    SELECT Product__c productId, COUNT(Id) scanCount
                    FROM Inventory_Scanning_Serial__c
                    WHERE Inventory_Scanning_Header__c = :headers[0].Id
                    AND Product__c != null
                    WITH SECURITY_ENFORCED
                    GROUP BY Product__c
                ]) {
                    scanCountByProduct.put((Id) ar.get('productId'), (Integer) ar.get('scanCount'));
                }
            }

            // Compare scanned vs on-hand for ProductItems in Oracle
            Set<Id> coveredProductIds = new Set<Id>();
            Integer discrepancyCount = 0;
            for (ProductItem pi : allItems) {
                coveredProductIds.add(pi.Product2Id);
                Integer scanned = scanCountByProduct.containsKey(pi.Product2Id)
                    ? scanCountByProduct.get(pi.Product2Id) : 0;
                if (scanned != Integer.valueOf(pi.QuantityOnHand)) {
                    discrepancyCount++;
                }
            }

            // Count scanned products not in Oracle (scanned > 0, expected = 0 → always a discrepancy)
            Integer extraProducts = 0;
            for (Id prodId : scanCountByProduct.keySet()) {
                if (!coveredProductIds.contains(prodId)) {
                    extraProducts++;
                    discrepancyCount++;
                }
            }

            Integer totalProducts = allItems.size() + extraProducts;
            return new DiscrepancyCheckResult(totalProducts, discrepancyCount);
        } catch (Exception e) {
            throw new AuraHandledException('Discrepancy check failed: ' + e.getMessage() + '. Please try again or contact your supervisor.');
        }
    }

    public class DiscrepancyCheckResult {
        @AuraEnabled public Integer totalProducts;
        @AuraEnabled public Integer discrepancyCount;

        public DiscrepancyCheckResult(Integer total, Integer discrepancies) {
            this.totalProducts = total;
            this.discrepancyCount = discrepancies;
        }
    }

    /**
     * @description Marks the current open scan as completed.
     *              Sets Scan_End_Date__c and Status__c = 'Completed'.
     */
    @AuraEnabled
    public static void completeScan() {
        try {
            ServiceResource sr = getCurrentServiceResource();
            if (sr == null || sr.LocationId == null) {
                throw new AuraHandledException('No active Service Resource or location found.');
            }

            List<Inventory_Scanning_Header__c> openHeaders = [
                SELECT Id, Status__c, Scan_End_Date__c
                FROM Inventory_Scanning_Header__c
                WHERE FST_Location__c = :sr.LocationId
                AND Status__c = 'In Progress'
                WITH SECURITY_ENFORCED
                ORDER BY Scan_Start_Date__c DESC
                LIMIT 1
            ];

            if (openHeaders.isEmpty()) {
                throw new AuraHandledException('No open scan found to complete.');
            }

            Inventory_Scanning_Header__c header = openHeaders[0];
            header.Status__c = 'Pending Review';
            header.Scan_End_Date__c = DateTime.now();
            update header;

            // Update Inventory_Scan_Count__c on each ProductItem
            List<AggregateResult> scanCounts = [
                SELECT Product__c productId, COUNT(Id) scanCount
                FROM Inventory_Scanning_Serial__c
                WHERE Inventory_Scanning_Header__c = :header.Id
                AND Product__c != null
                WITH SECURITY_ENFORCED
                GROUP BY Product__c
            ];

            if (!scanCounts.isEmpty()) {
                Set<Id> productIds = new Set<Id>();
                Map<Id, Integer> countByProduct = new Map<Id, Integer>();
                for (AggregateResult ar : scanCounts) {
                    Id prodId = (Id) ar.get('productId');
                    Integer cnt = (Integer) ar.get('scanCount');
                    productIds.add(prodId);
                    countByProduct.put(prodId, cnt);
                }

                List<ProductItem> itemsToUpdate = [
                    SELECT Id, Product2Id, Inventory_Scan_Count__c
                    FROM ProductItem
                    WHERE Product2Id IN :productIds
                    AND LocationId = :sr.LocationId
                    WITH SECURITY_ENFORCED
                ];

                for (ProductItem pi : itemsToUpdate) {
                    if (countByProduct.containsKey(pi.Product2Id)) {
                        pi.Inventory_Scan_Count__c = countByProduct.get(pi.Product2Id);
                        pi.Inventory_Scan__c = header.Id;
                    }
                }

                if (!itemsToUpdate.isEmpty()) {
                    update itemsToUpdate;
                }
            }

            // Send notification to reviewers
            sendScanReviewNotification(header.Id);

            // Log scan submission
            logScanEvent('FSL_MyDayController.completeScan',
                'Scan Submission', 'Success',
                'FST: ' + sr.Name + ', Location: ' + sr.LocationId,
                'Items scanned: ' + (scanCounts.isEmpty() ? '0' : String.valueOf(scanCounts.size()) + ' products'));

        } catch (AuraHandledException ae) {
            throw ae;
        } catch (Exception e) {
            throw new AuraHandledException('Error completing scan: ' + e.getMessage());
        }
    }

    /**
     * @description Sends a custom notification to the Inventory Scan Reviewers group.
     * @param headerId The scan header record to link in the notification
     */
    private static void sendScanReviewNotification(Id headerId) {
        try {
            // Get notification type by developer name
            List<CustomNotificationType> notifTypes = [
                SELECT Id FROM CustomNotificationType
                WHERE DeveloperName = 'Inventory_Scan_Pending_Review'
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (notifTypes.isEmpty()) {
                System.debug(LoggingLevel.WARN, 'CustomNotificationType Inventory_Scan_Pending_Review not found. Notification skipped.');
                return;
            }

            // Get group members by group developer name
            List<Group> groups = [
                SELECT Id FROM Group
                WHERE DeveloperName = 'Inventory_Scan_Reviewers'
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (groups.isEmpty()) {
                System.debug(LoggingLevel.WARN, 'Group Inventory_Scan_Reviewers not found. Notification skipped.');
                return;
            }

            CustomNotificationType notifType = notifTypes[0];
            Group reviewerGroup = groups[0];

            Set<String> recipientIds = new Set<String>();
            for (GroupMember gm : [SELECT UserOrGroupId FROM GroupMember WHERE GroupId = :reviewerGroup.Id WITH SECURITY_ENFORCED]) {
                recipientIds.add(gm.UserOrGroupId);
            }

            if (!recipientIds.isEmpty()) {
                Messaging.CustomNotification notification = new Messaging.CustomNotification();
                notification.setTitle('Stock Check Pending Review');
                notification.setBody(UserInfo.getName() + ' has submitted a stock check. Tap to review.');
                notification.setNotificationTypeId(notifType.Id);
                notification.setTargetPageRef('{"type":"standard__navItemPage","attributes":{"apiName":"FST_Inventory"}}');
                notification.send(recipientIds);
            }
        } catch (Exception e) {
            // Don't fail the entire transaction if notification fails
            System.debug(LoggingLevel.ERROR, 'Notification error: ' + e.getMessage());
        }
    }

    /**
     * @description Cancels the current open scan.
     *              Sets Scan_End_Date__c and Status__c = 'Cancelled'.
     */
    @AuraEnabled
    public static void cancelScan() {
        try {
            ServiceResource sr = getCurrentServiceResource();
            if (sr == null || sr.LocationId == null) {
                throw new AuraHandledException('No active Service Resource or location found.');
            }

            List<Inventory_Scanning_Header__c> openHeaders = [
                SELECT Id, Status__c, Scan_End_Date__c
                FROM Inventory_Scanning_Header__c
                WHERE FST_Location__c = :sr.LocationId
                AND Status__c = 'In Progress'
                WITH SECURITY_ENFORCED
                ORDER BY Scan_Start_Date__c DESC
                LIMIT 1
            ];

            if (openHeaders.isEmpty()) {
                throw new AuraHandledException('No open scan found to cancel.');
            }

            Inventory_Scanning_Header__c header = openHeaders[0];
            header.Status__c = 'Cancelled';
            header.Scan_End_Date__c = DateTime.now();
            update header;

        } catch (AuraHandledException ae) {
            throw ae;
        } catch (Exception e) {
            throw new AuraHandledException('Error cancelling scan: ' + e.getMessage());
        }
    }

    private class ScanDetailInput {
        public String serialNumber;
        public String product2Id;
    }

    // ─── Scan Inventory Wrapper ────────────────────────────────────────

    public class ScanInventoryResult {
        @AuraEnabled public String serialNumber;
        @AuraEnabled public Boolean isValid;
        @AuraEnabled public String message;
        @AuraEnabled public String productItemId;
        @AuraEnabled public String modelNumber;
        @AuraEnabled public String productName;
        @AuraEnabled public String product2Id;

        public ScanInventoryResult(String serial, Boolean valid, String msg, String piId, String model, String pName) {
            this.serialNumber = serial;
            this.isValid = valid;
            this.message = msg;
            this.productItemId = piId;
            this.modelNumber = model;
            this.productName = pName;
            this.product2Id = null;
        }
    }

    /**
     * @description Gets the last sync timestamp for inventory data
     * @return DateTime of the most recent ProductItem modification by Data Migration User
     */
    @AuraEnabled
    public static DateTime getLastSyncTime() {
        try {
            List<ProductItem> items = [
                SELECT Id, LastModifiedDate
                FROM ProductItem
                WHERE LastModifiedBy.Username = 'datamigration@enphase.com.prod'
                WITH SECURITY_ENFORCED
                ORDER BY LastModifiedDate DESC
                LIMIT 1
            ];
            return items.isEmpty() ? null : items[0].LastModifiedDate;
        } catch (Exception e) {
            return null;
        }
    }

    // ─── Wrapper Classes ───────────────────────────────────────────────

    public class AppointmentWrapper {
        @AuraEnabled public String id;
        @AuraEnabled public String appointmentNumber;
        @AuraEnabled public String subject;
        @AuraEnabled public String status;
        @AuraEnabled public DateTime schedStartTime;
        @AuraEnabled public DateTime schedEndTime;
        @AuraEnabled public String formattedStartTime;
        @AuraEnabled public String formattedEndTime;
        @AuraEnabled public String street;
        @AuraEnabled public String city;
        @AuraEnabled public String state;
        @AuraEnabled public String postalCode;
        @AuraEnabled public String country;
        @AuraEnabled public Decimal latitude;
        @AuraEnabled public Decimal longitude;
        @AuraEnabled public String workOrderNumber;
        @AuraEnabled public String workOrderSubject;
        @AuraEnabled public String caseNumber;
        @AuraEnabled public String fullAddress;

        public AppointmentWrapper(ServiceAppointment sa) {
            this.id = sa.Id;
            this.appointmentNumber = sa.AppointmentNumber;
            this.subject = sa.Subject;
            this.status = sa.Status;
            this.schedStartTime = sa.SchedStartTime;
            this.schedEndTime = sa.SchedEndTime;

            String userTZ = UserInfo.getTimeZone().getID();
            String tzAbbr = UserInfo.getTimeZone().getDisplayName();
            // Extract abbreviation from timezone ID (e.g., "Europe/Rome" -> "CET")
            if (tzAbbr.length() > 5) {
                tzAbbr = userTZ.substringAfterLast('/');
            }
            if (sa.SchedStartTime != null) {
                this.formattedStartTime = sa.SchedStartTime.format('hh:mm a z', userTZ);
            }
            if (sa.SchedEndTime != null) {
                this.formattedEndTime = sa.SchedEndTime.format('hh:mm a z', userTZ);
            }

            this.street = sa.Street;
            this.city = sa.City;
            this.state = sa.State;
            this.postalCode = sa.PostalCode;
            this.country = sa.Country;
            this.latitude = sa.Latitude;
            this.longitude = sa.Longitude;
            this.workOrderNumber = '';
            this.workOrderSubject = '';
            this.caseNumber = '';

            List<String> addressParts = new List<String>();
            if (String.isNotBlank(sa.Street)) addressParts.add(sa.Street);
            if (String.isNotBlank(sa.City)) addressParts.add(sa.City);
            if (String.isNotBlank(sa.State)) addressParts.add(sa.State);
            if (String.isNotBlank(sa.PostalCode)) addressParts.add(sa.PostalCode);
            this.fullAddress = String.join(addressParts, ', ');
        }
    }

    public class InventoryWrapper {
        @AuraEnabled public String id;
        @AuraEnabled public String productName;
        @AuraEnabled public String productCode;
        @AuraEnabled public String productFamily;
        @AuraEnabled public String productDescription;
        @AuraEnabled public Decimal quantityOnHand;
        @AuraEnabled public String unitOfMeasure;
        @AuraEnabled public String locationName;
        @AuraEnabled public Integer rmaCount;
        @AuraEnabled public List<RMAWrapper> rmas;
        @AuraEnabled public Boolean isSerialized;
        @AuraEnabled public String serializationLabel;

        public InventoryWrapper(ProductItem pi, List<RMAWrapper> rmaList) {
            this.id = pi.Id;
            this.productName = pi.Product2?.Name;
            this.productCode = pi.Product2?.ProductCode;
            this.productFamily = pi.Product2?.Family;
            this.productDescription = pi.Product2?.Description;
            this.quantityOnHand = pi.QuantityOnHand;
            this.unitOfMeasure = pi.QuantityUnitOfMeasure;
            this.locationName = pi.Location?.Name;
            this.rmaCount = rmaList.size();
            this.rmas = rmaList;
            this.isSerialized = pi.Product2?.IsSerialized == true;
            this.serializationLabel = this.isSerialized ? 'Serialized' : 'Non-Serialized';
        }
    }

    public class RMAWrapper {
        @AuraEnabled public String returnOrderNumber;
        @AuraEnabled public String status;
        @AuraEnabled public DateTime createdDate;
        @AuraEnabled public Decimal quantityReturned;

        public RMAWrapper(ReturnOrderLineItem roli) {
            this.returnOrderNumber = String.isNotBlank(roli.ReturnOrder?.Final_RMA_Number__c)
                ? roli.ReturnOrder.Final_RMA_Number__c
                : roli.ReturnOrder?.ReturnOrderNumber;
            this.status = roli.ReturnOrder?.Status;
            this.createdDate = roli.ReturnOrder?.CreatedDate;
            this.quantityReturned = roli.QuantityReturned;
        }
    }

    // ─── Non-Serialized SKU Methods ────────────────────────────────────

    /**
     * @description Validates a non-serialized SKU against the FST's inventory.
     * @param sku The product code to validate
     * @return Map with valid, productName, product2Id, existingQty
     */
    @AuraEnabled
    public static Map<String, Object> validateNonSerializedSku(String sku) {
        Map<String, Object> result = new Map<String, Object>();
        try {
            if (String.isBlank(sku)) {
                result.put('valid', false);
                result.put('message', 'Please enter a SKU.');
                return result;
            }

            ServiceResource sr = getCurrentServiceResource();
            if (sr == null || sr.LocationId == null) {
                result.put('valid', false);
                result.put('message', 'No active location found.');
                return result;
            }

            List<ProductItem> items = [
                SELECT Id, Product2Id, Product2.Name, QuantityOnHand
                FROM ProductItem
                WHERE Product2.ProductCode = :sku.trim()
                AND LocationId = :sr.LocationId
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];

            Id resolvedProduct2Id;

            if (!items.isEmpty()) {
                ProductItem pi = items[0];
                result.put('valid', true);
                result.put('productName', pi.Product2.Name);
                result.put('product2Id', pi.Product2Id);
                result.put('onHand', pi.QuantityOnHand);
                resolvedProduct2Id = pi.Product2Id;
            } else {
                // No ProductItem at this location (Oracle count = 0) — resolve Product2 directly
                List<Product2> products = [
                    SELECT Id, Name FROM Product2
                    WHERE ProductCode = :sku.trim() AND IsActive = true
                    WITH SECURITY_ENFORCED
                    LIMIT 1
                ];
                if (products.isEmpty()) {
                    result.put('valid', false);
                    result.put('message', 'This SKU is not recognized in the system.');
                    return result;
                }
                result.put('valid', true);
                result.put('productName', products[0].Name);
                result.put('product2Id', products[0].Id);
                result.put('onHand', 0);
                resolvedProduct2Id = products[0].Id;
            }

            // Check existing non-serial quantity in current session
            List<Inventory_Scanning_Header__c> headers = [
                SELECT Id FROM Inventory_Scanning_Header__c
                WHERE FST_Location__c = :sr.LocationId
                AND Status__c = 'In Progress'
                WITH SECURITY_ENFORCED
                ORDER BY Scan_Start_Date__c DESC
                LIMIT 1
            ];

            Integer existingQty = 0;
            if (!headers.isEmpty()) {
                AggregateResult[] counts = [
                    SELECT COUNT(Id) cnt FROM Inventory_Scanning_Serial__c
                    WHERE Inventory_Scanning_Header__c = :headers[0].Id
                    AND Product__c = :resolvedProduct2Id
                    AND Serial_Number__c = null
                    WITH SECURITY_ENFORCED
                ];
                if (!counts.isEmpty()) {
                    existingQty = (Integer) counts[0].get('cnt');
                }
            }
            result.put('existingQty', existingQty);

        } catch (Exception e) {
            result.put('valid', false);
            result.put('message', 'Error validating SKU: ' + e.getMessage());
        }
        return result;
    }

    /**
     * @description Saves non-serialized SKU quantities. Deletes old non-serial records and inserts new ones.
     * @param itemsJson JSON array of [{product2Id, quantity}]
     * @param headerId The scan session header Id (null to auto-create)
     * @param scanMode 'new' or 'add'
     * @return Total items inserted
     */
    @AuraEnabled
    public static Integer addNonSerializedSkus(String itemsJson, Id headerId, String scanMode) {
        try {
            if (String.isBlank(itemsJson)) {
                throw new AuraHandledException('No items to save.');
            }

            // Get or create header if not provided
            if (headerId == null) {
                ServiceResource sr = getCurrentServiceResource();
                Id locationId = sr != null ? sr.LocationId : null;
                headerId = getOrCreateScanHeaderInternal(scanMode != null ? scanMode : 'add', locationId);
            }

            List<Object> rawItems = (List<Object>) JSON.deserializeUntyped(itemsJson);

            // Collect product Ids and quantities
            Set<Id> productIds = new Set<Id>();
            Map<Id, Integer> quantityByProduct = new Map<Id, Integer>();
            for (Object obj : rawItems) {
                Map<String, Object> item = (Map<String, Object>) obj;
                Id prodId = (Id) item.get('product2Id');
                Integer qty = (Integer) item.get('quantity');
                productIds.add(prodId);
                quantityByProduct.put(prodId, qty);
            }

            // Delete existing non-serial records for these products in this header
            List<Inventory_Scanning_Serial__c> toDelete = [
                SELECT Id FROM Inventory_Scanning_Serial__c
                WHERE Inventory_Scanning_Header__c = :headerId
                AND Product__c IN :productIds
                AND Serial_Number__c = null
                WITH SECURITY_ENFORCED
            ];
            if (!toDelete.isEmpty()) {
                delete toDelete;
            }

            // Insert new records
            List<Inventory_Scanning_Serial__c> toInsert = new List<Inventory_Scanning_Serial__c>();
            for (Id prodId : quantityByProduct.keySet()) {
                Integer qty = quantityByProduct.get(prodId);
                for (Integer i = 0; i < qty; i++) {
                    toInsert.add(new Inventory_Scanning_Serial__c(
                        Inventory_Scanning_Header__c = headerId,
                        Serial_Number__c = null,
                        Product__c = prodId,
                        Scanning_Date__c = DateTime.now()
                    ));
                }
            }

            if (!toInsert.isEmpty()) {
                insert toInsert;
            }

            return toInsert.size();
        } catch (AuraHandledException ae) {
            throw ae;
        } catch (Exception e) {
            throw new AuraHandledException('Error saving non-serialized items: ' + e.getMessage());
        }
    }

    // ─── Product Search (Non-Serialized) ──────────────────────────────

    /**
     * @description Searches ProductItems at a given location by name or product code.
     * @param searchTerm At least 2 characters to search against Product2.Name or ProductCode
     * @param locationId The inventory location to search within
     * @return List of ProductSearchResult matching the search term
     */
    @AuraEnabled
    public static List<ProductSearchResult> searchInventoryProducts(String searchTerm, Id locationId) {
        try {
            if (String.isBlank(searchTerm) || searchTerm.trim().length() < 2) {
                return new List<ProductSearchResult>();
            }
            String term = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
            List<ProductItem> items = [
                SELECT Id, Product2Id, Product2.Name, Product2.ProductCode, Product2.IsSerialized, QuantityOnHand
                FROM ProductItem
                WHERE LocationId = :locationId
                AND QuantityOnHand > 0
                AND (Product2.Name LIKE :term OR Product2.ProductCode LIKE :term)
                WITH SECURITY_ENFORCED
                ORDER BY Product2.Name
                LIMIT 10
            ];
            List<ProductSearchResult> results = new List<ProductSearchResult>();
            for (ProductItem pi : items) {
                ProductSearchResult r = new ProductSearchResult();
                r.productId = pi.Product2Id;
                r.productName = pi.Product2?.Name;
                r.productCode = pi.Product2?.ProductCode;
                r.isSerialized = pi.Product2?.IsSerialized == true;
                r.serializationLabel = r.isSerialized ? 'Serialized' : 'Non-Serialized';
                r.quantityOnHand = pi.QuantityOnHand;
                results.add(r);
            }
            return results;
        } catch (Exception e) {
            throw new AuraHandledException('Error searching products: ' + e.getMessage());
        }
    }

    public class ProductSearchResult {
        @AuraEnabled public Id productId;
        @AuraEnabled public String productName;
        @AuraEnabled public String productCode;
        @AuraEnabled public Boolean isSerialized;
        @AuraEnabled public String serializationLabel;
        @AuraEnabled public Decimal quantityOnHand;
    }

    // ─── API Logger Utility ─────────────────────────────────────────────
    private static void logScanEvent(String classMethod, String operationType, String status, String request, String response) {
        try {
            API_Logger__c log = new API_Logger__c();
            log.Class_and_method__c = classMethod;
            log.Operation_Type__c = operationType;
            log.Status__c = status;
            log.Request__c = request != null && request.length() > 131072 ? request.substring(0, 131072) : request;
            log.Response__c = response != null && response.length() > 131072 ? response.substring(0, 131072) : response;
            log.UniqueIdentifier__c = operationType.replaceAll(' ', '_') + '_' + DateTime.now().format('yyyyMMdd_HHmmss');
            insert log;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'API Logger insert failed: ' + e.getMessage());
        }
    }
}