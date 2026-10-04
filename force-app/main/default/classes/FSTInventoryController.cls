/**
 * @description Controller for FST Inventory LWC - handles FST inventory viewing and Stock Tick scan reviews.
 * @date 2026
 */
public with sharing class FSTInventoryController {

    // ═══════════════════════════════════════════════════════════════════
    // ─── FST INVENTORY ────────────────────────────────────────────────
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @description Returns distinct location names with inventory count for the location picker.
     * @param searchTerm Optional typeahead filter
     * @return List of FSTLocationOption
     */
    @AuraEnabled(cacheable=true)
    public static List<FSTLocationOption> getFSTLocationOptions(String searchTerm) {
        try {
            // CLS2-02: two static SOQL paths replacing Database.query()
            // CLS2-01: WITH SECURITY_ENFORCED on both paths
            List<AggregateResult> arList;
            if (String.isNotBlank(searchTerm)) {
                String filter = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
                arList = [
                    SELECT Location.Name locName, COUNT(Id) itemCount
                    FROM ProductItem
                    WHERE QuantityOnHand > 0 AND Location.Name LIKE :filter
                    WITH SECURITY_ENFORCED
                    GROUP BY Location.Name
                    ORDER BY Location.Name
                    LIMIT 500
                ];
            } else {
                arList = [
                    SELECT Location.Name locName, COUNT(Id) itemCount
                    FROM ProductItem
                    WHERE QuantityOnHand > 0
                    WITH SECURITY_ENFORCED
                    GROUP BY Location.Name
                    ORDER BY Location.Name
                    LIMIT 500
                ];
            }

            List<FSTLocationOption> options = new List<FSTLocationOption>();
            for (AggregateResult ar : arList) {
                FSTLocationOption opt = new FSTLocationOption();
                opt.label = (String) ar.get('locName');
                opt.value = (String) ar.get('locName');
                opt.itemCount = (Integer) ar.get('itemCount');
                options.add(opt);
            }
            return options;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to load FST locations: ' + e.getMessage());
        }
    }

    /**
     * @description Returns paginated FST inventory with server-side filtering by location.
     * @param locationFilter Location name filter
     * @param pageSize Number of records per page (default 50, max 200)
     * @param lastId Keyset cursor — null for first page, last Id from previous page for subsequent pages
     * @return FSTInventoryResult containing items + hasMore flag
     */
    @AuraEnabled
    public static FSTInventoryResult getFSTInventory(
        String locationFilter,
        Integer pageSize,
        Id lastId
    ) {
        try {
            if (pageSize == null || pageSize <= 0) pageSize = 50;
            if (pageSize > 200) pageSize = 200;

            String locFilter = String.isNotBlank(locationFilter)
                ? '%' + String.escapeSingleQuotes(locationFilter.trim()) + '%' : null;

            // CLS2-04: 4 static SOQL paths (2 filter cases × 2 cursor cases), no OFFSET, no COUNT
            // CLS2-01: WITH SECURITY_ENFORCED on all paths
            List<ProductItem> queryResults;

            if (locFilter != null) {
                if (lastId != null) {
                    queryResults = [
                        SELECT Id, Location.Name, Product2Id, Product2.Name, QuantityOnHand,
                            LastModifiedDate, Minimum_Quantity__c,
                            Fixed_Lot_Multiplier__c, Inventory_Planning_Method__c, Inventory_Scan_Count__c
                        FROM ProductItem
                        WHERE QuantityOnHand > 0
                        AND Location.Name LIKE :locFilter
                        AND Id > :lastId
                        WITH SECURITY_ENFORCED
                        ORDER BY Id ASC
                        LIMIT :pageSize
                    ];
                } else {
                    queryResults = [
                        SELECT Id, Location.Name, Product2Id, Product2.Name, QuantityOnHand,
                            LastModifiedDate, Minimum_Quantity__c,
                            Fixed_Lot_Multiplier__c, Inventory_Planning_Method__c, Inventory_Scan_Count__c
                        FROM ProductItem
                        WHERE QuantityOnHand > 0
                        AND Location.Name LIKE :locFilter
                        WITH SECURITY_ENFORCED
                        ORDER BY Id ASC
                        LIMIT :pageSize
                    ];
                }
            } else {
                if (lastId != null) {
                    queryResults = [
                        SELECT Id, Location.Name, Product2Id, Product2.Name, QuantityOnHand,
                            LastModifiedDate, Minimum_Quantity__c,
                            Fixed_Lot_Multiplier__c, Inventory_Planning_Method__c, Inventory_Scan_Count__c
                        FROM ProductItem
                        WHERE QuantityOnHand > 0
                        AND Id > :lastId
                        WITH SECURITY_ENFORCED
                        ORDER BY Id ASC
                        LIMIT :pageSize
                    ];
                } else {
                    queryResults = [
                        SELECT Id, Location.Name, Product2Id, Product2.Name, QuantityOnHand,
                            LastModifiedDate, Minimum_Quantity__c,
                            Fixed_Lot_Multiplier__c, Inventory_Planning_Method__c, Inventory_Scan_Count__c
                        FROM ProductItem
                        WHERE QuantityOnHand > 0
                        WITH SECURITY_ENFORCED
                        ORDER BY Id ASC
                        LIMIT :pageSize
                    ];
                }
            }

            List<FSTInventoryWrapper> items = new List<FSTInventoryWrapper>();
            Set<Id> productIds = new Set<Id>();
            Set<String> locationNames = new Set<String>();
            Map<String, Id> itemIdToProductId = new Map<String, Id>();

            for (ProductItem pi : queryResults) {
                FSTInventoryWrapper w = new FSTInventoryWrapper();
                w.Id = pi.Id;
                w.LocationName = pi.Location?.Name;
                w.ProductName = pi.Product2?.Name;
                w.QuantityOnHand = pi.QuantityOnHand;
                w.LastModifiedDate = pi.LastModifiedDate;
                w.MinimumQuantity = pi.Minimum_Quantity__c;
                w.FixedLotMultiplier = pi.Fixed_Lot_Multiplier__c;
                w.PlanningMethod = pi.Inventory_Planning_Method__c;
                w.ScanCount = pi.Inventory_Scan_Count__c;
                w.rmaCount = 0;
                w.rmas = new List<FSTRMADetail>();
                items.add(w);
                if (pi.Product2Id != null) {
                    productIds.add(pi.Product2Id);
                    itemIdToProductId.put(w.Id, pi.Product2Id);
                }
                if (pi.Location?.Name != null) locationNames.add(pi.Location.Name);
            }

            // CLS2-05: removed AND IsActive = true; CLS2-01: WITH SECURITY_ENFORCED
            Id fstContactId = null;
            if (!locationNames.isEmpty()) {
                List<ServiceResource> srs = [
                    SELECT Id, Contact__c
                    FROM ServiceResource
                    WHERE Location.Name IN :locationNames
                    AND Contact__c != null
                    WITH SECURITY_ENFORCED
                    LIMIT 1
                ];
                if (!srs.isEmpty()) {
                    fstContactId = srs[0].Contact__c;
                }
            }

            // Query RMAs from last 30 days for the FST contact's products
            if (fstContactId != null && !productIds.isEmpty()) {
                Map<Id, List<FSTRMADetail>> rmasByProduct = new Map<Id, List<FSTRMADetail>>();
                for (ReturnOrderLineItem roli : [
                    SELECT Id, Product2Id, QuantityReturned,
                           ReturnOrder.ReturnOrderNumber, ReturnOrder.Final_RMA_Number__c,
                           ReturnOrder.Status, ReturnOrder.CreatedDate, ReturnOrder.Legacy_RMA_Issued_Date__c
                    FROM ReturnOrderLineItem
                    WHERE ReturnOrder.ContactId = :fstContactId
                    AND ReturnOrder.CreatedDate >= LAST_N_DAYS:30
                    AND Product2Id IN :productIds
                    WITH SECURITY_ENFORCED
                    ORDER BY ReturnOrder.CreatedDate DESC
                ]) {
                    FSTRMADetail detail = new FSTRMADetail();
                    detail.rmaNumber = String.isNotBlank(roli.ReturnOrder?.Final_RMA_Number__c)
                        ? roli.ReturnOrder.Final_RMA_Number__c
                        : roli.ReturnOrder?.ReturnOrderNumber;
                    detail.status = roli.ReturnOrder?.Status;
                    detail.createdDate = roli.ReturnOrder?.CreatedDate;
                    detail.approvalDate = roli.ReturnOrder?.Legacy_RMA_Issued_Date__c;
                    detail.quantityReturned = roli.QuantityReturned;

                    if (!rmasByProduct.containsKey(roli.Product2Id)) {
                        rmasByProduct.put(roli.Product2Id, new List<FSTRMADetail>());
                    }
                    rmasByProduct.get(roli.Product2Id).add(detail);
                }

                for (FSTInventoryWrapper w : items) {
                    Id pid = itemIdToProductId.get(w.Id);
                    if (pid != null && rmasByProduct.containsKey(pid)) {
                        w.rmas = rmasByProduct.get(pid);
                        w.rmaCount = w.rmas.size();
                    }
                }
            }

            // CLS2-04: hasMore replaces totalPages/pageNumber/totalCount
            FSTInventoryResult result = new FSTInventoryResult();
            result.items = items;
            result.hasMore = (queryResults.size() == pageSize);
            return result;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to load FST inventory: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // ─── STOCK TICK (Scan Reviews) ────────────────────────────────────
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @description Gets all scan sessions with status 'Pending Review' for manager review.
     * @return List of PendingScanWrapper
     */
    @AuraEnabled
    public static List<PendingScanWrapper> getPendingScanReviews() {
        return getScansByStatus('Pending Review');
    }

    /**
     * @description Gets scan sessions filtered by status.
     * @param statusFilter The status to filter by
     * @return List of PendingScanWrapper
     */
    @AuraEnabled
    public static List<PendingScanWrapper> getScansByStatus(String statusFilter) {
        List<PendingScanWrapper> results = new List<PendingScanWrapper>();
        try {
            for (Inventory_Scanning_Header__c header : [
                SELECT Id, Name, FST_Location__c, FST_Location__r.Name, Status__c,
                       Scan_Start_Date__c, Scan_End_Date__c, Total_Serial_Numbers_Scanned__c,
                       CreatedBy.Name, CreatedDate
                FROM Inventory_Scanning_Header__c
                WHERE Status__c = :statusFilter
                WITH SECURITY_ENFORCED
                ORDER BY Scan_End_Date__c DESC
                LIMIT 200
            ]) {
                PendingScanWrapper w = new PendingScanWrapper();
                w.headerId = header.Id;
                w.headerName = header.Name;
                w.fstName = header.FST_Location__r?.Name;
                w.totalScanned = header.Total_Serial_Numbers_Scanned__c != null
                    ? Integer.valueOf(header.Total_Serial_Numbers_Scanned__c) : 0;
                w.submittedDate = header.Scan_End_Date__c;
                w.createdByName = header.CreatedBy?.Name;
                w.status = header.Status__c;
                results.add(w);
            }
        } catch (Exception e) {
            throw new AuraHandledException('Failed to load scans: ' + e.getMessage());
        }
        return results;
    }

    /**
     * @description Gets scan line items for a specific scan session header.
     * @param headerId The scan session header Id
     * @return List of ScanLineItemWrapper
     */
    @AuraEnabled(cacheable=true)
    public static List<ScanLineItemWrapper> getScanLineItems(Id headerId) {
        List<ScanLineItemWrapper> results = new List<ScanLineItemWrapper>();
        if (headerId == null) return results;
        try {
            for (Inventory_Scanning_Serial__c item : [
                SELECT Id, Serial_Number__c, Product__r.Name, Product__r.ProductCode, Scanning_Date__c
                FROM Inventory_Scanning_Serial__c
                WHERE Inventory_Scanning_Header__c = :headerId
                WITH SECURITY_ENFORCED
                ORDER BY Scanning_Date__c DESC
            ]) {
                ScanLineItemWrapper w = new ScanLineItemWrapper();
                w.id = item.Id;
                w.serialNumber = item.Serial_Number__c;
                w.productName = item.Product__r?.Name;
                w.productCode = item.Product__r?.ProductCode;
                w.scanDate = item.Scanning_Date__c;
                results.add(w);
            }
        } catch (Exception e) {
            throw new AuraHandledException('Failed to load scan line items: ' + e.getMessage());
        }
        return results;
    }

    /**
     * @description Approves a scan session - changes status to 'Completed'.
     * @param headerId The scan session header Id
     */
    @AuraEnabled
    public static void approveScan(Id headerId) {
        try {
            // CLS2-07: List<>+isEmpty() guard; CLS2-01: WITH SECURITY_ENFORCED
            List<Inventory_Scanning_Header__c> headers = [
                SELECT Id, Status__c, FST_Location__c, FST_Location__r.Name
                FROM Inventory_Scanning_Header__c
                WHERE Id = :headerId
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (headers.isEmpty()) {
                throw new AuraHandledException('Scan session not found. Please refresh.');
            }
            Inventory_Scanning_Header__c header = headers[0];
            header.Status__c = 'Completed';
            update header;
            logToApiLogger('FSTInventoryController.approveScan',
                'Manager Approves',
                'Success',
                'Approved by: ' + UserInfo.getName(),
                'Header: ' + headerId + ', FST: ' + header.FST_Location__r?.Name);

            // CLS2-14: FST push notification after approval
            List<CustomNotificationType> notifTypes = [
                SELECT Id FROM CustomNotificationType
                WHERE DeveloperName = 'Inventory_Scan_Completed'
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (!notifTypes.isEmpty()) {
                List<ServiceResource> srs = [
                    SELECT RelatedRecordId FROM ServiceResource
                    WHERE LocationId = :header.FST_Location__c
                    AND RelatedRecordId != null
                    WITH SECURITY_ENFORCED
                    LIMIT 1
                ];
                if (!srs.isEmpty()) {
                    Messaging.CustomNotification notif = new Messaging.CustomNotification();
                    notif.setTitle('Scan Approved');
                    notif.setBody('Your inventory scan has been approved.');
                    notif.setNotificationTypeId(notifTypes[0].Id);
                    notif.setTargetPageRef('{"type":"standard__namedPage","attributes":{"pageName":"home"}}');
                    notif.send(new Set<String>{ srs[0].RelatedRecordId });
                }
            }
        } catch (AuraHandledException ae) {
            throw ae;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to approve scan: ' + e.getMessage());
        }
    }

    /**
     * @description Rejects a scan session - changes status to 'In Progress' with comments.
     * @param headerId The scan session header Id
     * @param comments Rejection reason
     */
    @AuraEnabled
    public static void rejectScan(Id headerId, String comments) {
        try {
            // CLS2-07: List<>+isEmpty() guard; CLS2-01: WITH SECURITY_ENFORCED
            List<Inventory_Scanning_Header__c> headers = [
                SELECT Id, Status__c, Comments__c, FST_Location__c, FST_Location__r.Name
                FROM Inventory_Scanning_Header__c
                WHERE Id = :headerId
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (headers.isEmpty()) {
                throw new AuraHandledException('Scan session not found. Please refresh.');
            }
            Inventory_Scanning_Header__c header = headers[0];
            header.Status__c = 'In Progress';
            header.Comments__c = comments;
            update header;
            logToApiLogger('FSTInventoryController.rejectScan',
                'Manager Rejects',
                'Success',
                'Rejected by: ' + UserInfo.getName() + ', Comment: ' + comments,
                'Header: ' + headerId + ', FST: ' + header.FST_Location__r?.Name);

            // CLS2-15: FST push notification after rejection
            List<CustomNotificationType> notifTypes = [
                SELECT Id FROM CustomNotificationType
                WHERE DeveloperName = 'Inventory_Scan_Rejected'
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (!notifTypes.isEmpty()) {
                List<ServiceResource> srs = [
                    SELECT RelatedRecordId FROM ServiceResource
                    WHERE LocationId = :header.FST_Location__c
                    AND RelatedRecordId != null
                    WITH SECURITY_ENFORCED
                    LIMIT 1
                ];
                if (!srs.isEmpty()) {
                    Messaging.CustomNotification notif = new Messaging.CustomNotification();
                    notif.setTitle('Scan Rejected');
                    notif.setBody('Your scan was rejected. Please review comments and resubmit.');
                    notif.setNotificationTypeId(notifTypes[0].Id);
                    notif.setTargetPageRef('{"type":"standard__namedPage","attributes":{"pageName":"home"}}');
                    notif.send(new Set<String>{ srs[0].RelatedRecordId });
                }
            }
        } catch (AuraHandledException ae) {
            throw ae;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to reject scan: ' + e.getMessage());
        }
    }

    /**
     * @description Gets product breakdown for an FST's scan session - shows all products
     *              at the FST's location with their scan count vs on-hand quantity.
     * @param headerId The scan session header Id
     * @return List of ProductBreakdownWrapper
     */
    @AuraEnabled(cacheable=true)
    public static List<ProductBreakdownWrapper> getProductBreakdown(Id headerId) {
        List<ProductBreakdownWrapper> results = new List<ProductBreakdownWrapper>();
        if (headerId == null) return results;
        try {
            // CLS2-01: WITH SECURITY_ENFORCED
            Inventory_Scanning_Header__c header = [
                SELECT Id, FST_Location__c FROM Inventory_Scanning_Header__c
                WHERE Id = :headerId
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (header.FST_Location__c == null) return results;

            // Live count from serial records for this specific session
            Map<Id, Integer> scanCountByProduct = new Map<Id, Integer>();
            for (AggregateResult ar : [
                SELECT Product__c productId, COUNT(Id) scanCount
                FROM Inventory_Scanning_Serial__c
                WHERE Inventory_Scanning_Header__c = :headerId
                AND Product__c != null
                WITH SECURITY_ENFORCED
                GROUP BY Product__c
            ]) {
                scanCountByProduct.put((Id) ar.get('productId'), (Integer) ar.get('scanCount'));
            }

            Set<Id> coveredProductIds = new Set<Id>();
            for (ProductItem pi : [
                SELECT Id, Product2Id, Product2.Name, QuantityOnHand
                FROM ProductItem
                WHERE LocationId = :header.FST_Location__c
                AND QuantityOnHand > 0
                WITH SECURITY_ENFORCED
                ORDER BY Product2.Name
            ]) {
                ProductBreakdownWrapper w = new ProductBreakdownWrapper();
                w.productName = pi.Product2?.Name;
                w.scanned = scanCountByProduct.containsKey(pi.Product2Id)
                    ? scanCountByProduct.get(pi.Product2Id) : 0;
                w.expected = pi.QuantityOnHand != null ? Integer.valueOf(pi.QuantityOnHand) : 0;
                w.hasMismatch = w.scanned != w.expected;
                results.add(w);
                coveredProductIds.add(pi.Product2Id);
            }

            // Add scanned products not in Oracle inventory (expected = 0, surplus)
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
                    ProductBreakdownWrapper w = new ProductBreakdownWrapper();
                    w.productName = productNames.containsKey(prodId) ? productNames.get(prodId) : 'Unknown Product';
                    w.scanned = scanCountByProduct.get(prodId);
                    w.expected = 0;
                    w.hasMismatch = true;
                    results.add(w);
                }
            }
        } catch (Exception e) {
            throw new AuraHandledException('Failed to load product breakdown: ' + e.getMessage());
        }
        return results;
    }

    /**
     * @description Auto-approves all Pending Review scans that have no discrepancies.
     * Checks each header's location: if all ProductItems have Inventory_Scan_Count__c == QuantityOnHand, approves it.
     * @return AutoApproveResult with counts of approved and skipped
     */
    @AuraEnabled
    public static AutoApproveResult autoApproveCleanScans() {
        Integer approved = 0;
        Integer skipped = 0;
        try {
            List<Inventory_Scanning_Header__c> pendingHeaders = [
                SELECT Id, FST_Location__c, Status__c
                FROM Inventory_Scanning_Header__c
                WHERE Status__c = 'Pending Review'
                WITH SECURITY_ENFORCED
                ORDER BY Scan_End_Date__c DESC
                LIMIT 200
            ];

            if (pendingHeaders.isEmpty()) {
                return new AutoApproveResult(0, 0);
            }

            // Collect header IDs and location IDs
            Set<Id> headerIds = new Set<Id>();
            Set<Id> locationIds = new Set<Id>();
            for (Inventory_Scanning_Header__c h : pendingHeaders) {
                headerIds.add(h.Id);
                if (h.FST_Location__c != null) locationIds.add(h.FST_Location__c);
            }

            // Live serial counts per header per product, tallied in Apex WITHOUT a
            // GROUP BY aggregate. Aggregate queries cannot use queryMore(), so a single
            // grouped query over many headers/products throws once distinct
            // (header, product) groups exceed 2000. A plain SOQL for-loop pages in
            // chunks of 200 and supports queryMore, so it scales safely.
            Map<Id, Map<Id, Integer>> scansByHeader = new Map<Id, Map<Id, Integer>>();
            for (Inventory_Scanning_Serial__c srl : [
                SELECT Inventory_Scanning_Header__c, Product__c
                FROM Inventory_Scanning_Serial__c
                WHERE Inventory_Scanning_Header__c IN :headerIds
                AND Product__c != null
                WITH SECURITY_ENFORCED
            ]) {
                Id hId = srl.Inventory_Scanning_Header__c;
                Id pId = srl.Product__c;
                if (!scansByHeader.containsKey(hId)) scansByHeader.put(hId, new Map<Id, Integer>());
                Map<Id, Integer> byProduct = scansByHeader.get(hId);
                byProduct.put(pId, (byProduct.containsKey(pId) ? byProduct.get(pId) : 0) + 1);
            }

            // Query all ProductItems at those locations
            Map<Id, List<ProductItem>> itemsByLocation = new Map<Id, List<ProductItem>>();
            for (ProductItem pi : [
                SELECT Id, LocationId, Product2Id, QuantityOnHand
                FROM ProductItem
                WHERE LocationId IN :locationIds
                AND QuantityOnHand > 0
                WITH SECURITY_ENFORCED
            ]) {
                if (!itemsByLocation.containsKey(pi.LocationId)) {
                    itemsByLocation.put(pi.LocationId, new List<ProductItem>());
                }
                itemsByLocation.get(pi.LocationId).add(pi);
            }

            // Check each header for discrepancies
            List<Inventory_Scanning_Header__c> toApprove = new List<Inventory_Scanning_Header__c>();
            for (Inventory_Scanning_Header__c h : pendingHeaders) {
                List<ProductItem> items = itemsByLocation.get(h.FST_Location__c);
                Map<Id, Integer> headerScans = scansByHeader.get(h.Id);
                Boolean hasDiscrepancy = false;

                // Check ProductItems in Oracle
                Set<Id> coveredProductIds = new Set<Id>();
                if (items != null && !items.isEmpty()) {
                    for (ProductItem pi : items) {
                        coveredProductIds.add(pi.Product2Id);
                        Integer scanned = (headerScans != null && headerScans.containsKey(pi.Product2Id))
                            ? headerScans.get(pi.Product2Id) : 0;
                        Integer expected = pi.QuantityOnHand != null ? pi.QuantityOnHand.intValue() : 0;
                        if (scanned != expected) {
                            hasDiscrepancy = true;
                            break;
                        }
                    }
                }

                // Check for scanned products not in Oracle (surplus = discrepancy)
                if (!hasDiscrepancy && headerScans != null) {
                    for (Id prodId : headerScans.keySet()) {
                        if (!coveredProductIds.contains(prodId)) {
                            hasDiscrepancy = true;
                            break;
                        }
                    }
                }

                if (items == null || items.isEmpty()) {
                    // No Oracle inventory but has scans → discrepancy
                    if (headerScans != null && !headerScans.isEmpty()) {
                        hasDiscrepancy = true;
                    } else {
                        skipped++;
                        continue;
                    }
                }

                if (!hasDiscrepancy) {
                    h.Status__c = 'Completed';
                    toApprove.add(h);
                    approved++;
                } else {
                    skipped++;
                }
            }

            if (!toApprove.isEmpty()) {
                update toApprove;
            }
            logToApiLogger('FSTInventoryController.autoApproveCleanScans',
                'Auto Approve',
                'Success',
                'Pending scans checked: ' + pendingHeaders.size(),
                'Approved: ' + approved + ', Skipped: ' + skipped);
        } catch (Exception e) {
            throw new AuraHandledException('Auto-approve failed: ' + e.getMessage());
        }
        return new AutoApproveResult(approved, skipped);
    }

    public class AutoApproveResult {
        @AuraEnabled public Integer approved;
        @AuraEnabled public Integer skipped;
        public AutoApproveResult(Integer approved, Integer skipped) {
            this.approved = approved;
            this.skipped = skipped;
        }
    }

    /**
     * @description Sends a notification to all FSTs in the FST_Stock_Tick_Technicians public group
     *              to start their stock tick inventory scanning.
     *              CLS2-08: List<>+isEmpty() guards on CustomNotificationType and Group.
     *              Not called from toggleStockTick — invoked directly or via notifySelectedFSTs.
     */
    @AuraEnabled
    public static void notifyFSTsToStartStockTick() {
        try {
            // CLS2-08: List<>+isEmpty() guard; CLS2-01: WITH SECURITY_ENFORCED
            List<CustomNotificationType> notifTypes = [
                SELECT Id FROM CustomNotificationType
                WHERE DeveloperName = 'Stock_Tick_Initiated'
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (notifTypes.isEmpty()) {
                System.debug(LoggingLevel.WARN, 'CustomNotificationType Stock_Tick_Initiated not found. Notification skipped.');
                return;
            }

            List<Group> groups = [
                SELECT Id FROM Group
                WHERE DeveloperName = 'FST_Stock_Tick_Technicians'
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (groups.isEmpty()) {
                System.debug(LoggingLevel.WARN, 'Group FST_Stock_Tick_Technicians not found. Notification skipped.');
                return;
            }

            Set<String> recipientIds = new Set<String>();
            for (GroupMember gm : [
                SELECT UserOrGroupId FROM GroupMember
                WHERE GroupId = :groups[0].Id
                WITH SECURITY_ENFORCED
            ]) {
                recipientIds.add(gm.UserOrGroupId);
            }

            if (recipientIds.isEmpty()) {
                throw new AuraHandledException('No FSTs found in the notification group.');
            }

            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setTitle('Initiated Stock Reconciliation');
            notification.setBody('Your manager has initiated stock reconciliation. Please start scanning your inventory.');
            notification.setNotificationTypeId(notifTypes[0].Id);
            notification.setTargetPageRef('{"type":"standard__namedPage","attributes":{"pageName":"home"}}');
            notification.send(recipientIds);
        } catch (AuraHandledException ae) {
            throw ae;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to send notification: ' + e.getMessage());
        }
    }

    /**
     * @description Gets the current Stock Tick Active state from Custom Setting.
     * @return Boolean - true if stock tick is active
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getStockTickActive() {
        Inventory_Scan_Config__c config = Inventory_Scan_Config__c.getInstance();
        Map<String, Object> result = new Map<String, Object>();
        result.put('isActive', config != null && config.Stock_Tick_Active__c);
        result.put('reconciliationStartDate', config != null ? config.Reconciliation_Start_Date__c : null);
        return result;
    }

    /**
     * @description Toggles the Stock Tick Active flag in Custom Setting.
     * @param isActive The new state
     * @param forceCancel When disabling, force-cancel active sessions (null treated as false)
     */
    @AuraEnabled
    public static void toggleStockTick(Boolean isActive, Boolean forceCancel) {
        try {
            // CLS2-09 Change 1: disable guard with ACTIVE_SESSIONS sentinel + force-cancel
            Boolean cancel = forceCancel != null && forceCancel;
            if (!isActive) {
                Integer activeSessions = [
                    SELECT COUNT() FROM Inventory_Scanning_Header__c
                    WHERE Status__c IN ('In Progress', 'Pending Review')
                    WITH SECURITY_ENFORCED
                ];
                if (activeSessions > 0 && !cancel) {
                    throw new AuraHandledException('ACTIVE_SESSIONS:' + activeSessions);
                }
                if (cancel && activeSessions > 0) {
                    List<Inventory_Scanning_Header__c> toCancel = [
                        SELECT Id, Status__c FROM Inventory_Scanning_Header__c
                        WHERE Status__c IN ('In Progress', 'Pending Review')
                        WITH SECURITY_ENFORCED
                    ];
                    for (Inventory_Scanning_Header__c h : toCancel) {
                        h.Status__c = 'Cancelled';
                    }
                    update toCancel;
                }
            }

            Inventory_Scan_Config__c orgDefault = Inventory_Scan_Config__c.getOrgDefaults();
            orgDefault.Stock_Tick_Active__c = isActive;
            if (isActive) {
                orgDefault.Reconciliation_Start_Date__c = DateTime.now();
            }
            upsert orgDefault;

            // CLS2-09 Change 2: create Not Started headers for every FST in the group on enable
            // CLS2-09 Change 3: notifyFSTsToStartStockTick() call removed — notification is now
            //                   a separate deliberate action via notifySelectedFSTs()
            if (isActive) {
                List<Group> fstGroups = [
                    SELECT Id FROM Group
                    WHERE DeveloperName = 'FST_Stock_Tick_Technicians'
                    WITH SECURITY_ENFORCED
                    LIMIT 1
                ];
                if (!fstGroups.isEmpty()) {
                    List<GroupMember> members = [
                        SELECT UserOrGroupId FROM GroupMember
                        WHERE GroupId = :fstGroups[0].Id
                        WITH SECURITY_ENFORCED
                    ];
                    if (!members.isEmpty()) {
                        Set<Id> memberIds = new Set<Id>();
                        for (GroupMember gm : members) {
                            memberIds.add(gm.UserOrGroupId);
                        }
                        // NO IsActive filter — every member in the group participates
                        List<ServiceResource> fstSrs = [
                            SELECT RelatedRecordId, LocationId FROM ServiceResource
                            WHERE RelatedRecordId IN :memberIds
                            AND LocationId != null
                            WITH SECURITY_ENFORCED
                        ];
                        List<Inventory_Scanning_Header__c> notStartedHeaders =
                            new List<Inventory_Scanning_Header__c>();
                        for (ServiceResource sr : fstSrs) {
                            notStartedHeaders.add(new Inventory_Scanning_Header__c(
                                FST_Location__c = sr.LocationId,
                                Status__c = 'Not Started',
                                Scan_Start_Date__c = DateTime.now()
                            ));
                        }
                        if (!notStartedHeaders.isEmpty()) {
                            insert notStartedHeaders;
                        }
                    }
                }
            }

            logToApiLogger('FSTInventoryController.toggleStockTick',
                isActive ? 'Reconciliation Initiated' : 'Reconciliation Deactivated',
                'Success',
                'Toggled by: ' + UserInfo.getName(),
                'Stock_Tick_Active__c = ' + isActive);
        } catch (AuraHandledException ae) {
            throw ae;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to toggle stock tick: ' + e.getMessage());
        }
    }

    /**
     * @description Gets all ProductItem records with full details for report export.
     * @return List of ReportWrapper
     */
    /**
     * @description Exports all ProductItem records as a CSV string for download.
     * @return CSV string with headers and all rows
     */
    /**
     * @description Exports a reconciliation pivot report as CSV.
     *              Rows = FSTs, Columns = Products (On Hand | Scanned pairs).
     * @param lastId Not used for pivot (kept for interface compatibility). Pass null.
     * @return Full CSV string of the pivot report.
     */
    @AuraEnabled
    public static String exportInventoryReportCsv(String lastId) {
        // CLS2-06 Fix 3: 50k count guard — throw before silent truncation
        // CLS2-01: WITH SECURITY_ENFORCED
        Integer countCheck = [
            SELECT COUNT() FROM ProductItem
            WHERE QuantityOnHand > 0
            AND LocationId IN (SELECT LocationId FROM ServiceResource WHERE LocationId != null)
            WITH SECURITY_ENFORCED
        ];
        if (countCheck > 50000) {
            throw new AuraHandledException('TRUNCATION_WARNING:' + countCheck);
        }

        // CLS2-06 Fix 1: removed IsActive = true from ServiceResource subquery
        // CLS2-01: WITH SECURITY_ENFORCED
        List<ProductItem> items = [
            SELECT Id, Product2.ProductCode, QuantityOnHand, Inventory_Scan_Count__c,
                   LocationId, Location.Name,
                   Location.AccountId, Location.Account.Customer_Key__c
            FROM ProductItem
            WHERE QuantityOnHand > 0
            AND LocationId IN (SELECT LocationId FROM ServiceResource WHERE LocationId != null)
            WITH SECURITY_ENFORCED
            ORDER BY Location.Name, Product2.ProductCode
            LIMIT 50000
        ];

        if (items.isEmpty()) {
            return '';
        }

        // Build pivot: locKey → { productCode → [onHand, scanned] }
        Map<String, Map<String, List<Integer>>> pivotData = new Map<String, Map<String, List<Integer>>>();
        Map<String, String> fstNameByKey = new Map<String, String>();
        Map<String, String> fstNumberByKey = new Map<String, String>();
        List<String> allProducts = new List<String>();
        Set<String> productSet = new Set<String>();

        for (ProductItem pi : items) {
            String locKey = pi.LocationId;
            String productCode = pi.Product2?.ProductCode;
            if (locKey == null || String.isBlank(productCode)) continue;

            if (!fstNameByKey.containsKey(locKey)) {
                fstNameByKey.put(locKey, pi.Location?.Name);
                String custKey = pi.Location?.Account?.Customer_Key__c;
                fstNumberByKey.put(locKey, String.isNotBlank(custKey) ? 'FS_' + custKey : '');
            }

            if (!productSet.contains(productCode)) {
                productSet.add(productCode);
                allProducts.add(productCode);
            }

            if (!pivotData.containsKey(locKey)) {
                pivotData.put(locKey, new Map<String, List<Integer>>());
            }
            Integer onHand = pi.QuantityOnHand != null ? pi.QuantityOnHand.intValue() : 0;
            pivotData.get(locKey).put(productCode, new List<Integer>{ onHand, 0 });
        }

        allProducts.sort();

        // Get latest submitted/completed header per location for live serial counts
        Set<Id> locationIdSet = new Set<Id>();
        for (String locKey : pivotData.keySet()) {
            locationIdSet.add((Id) locKey);
        }

        // Find latest header per location (Pending Review or Completed)
        Map<Id, Id> latestHeaderByLocation = new Map<Id, Id>();
        Map<Id, DateTime> completionByLocation = new Map<Id, DateTime>();
        for (Inventory_Scanning_Header__c h : [
            SELECT Id, FST_Location__c, Scan_End_Date__c
            FROM Inventory_Scanning_Header__c
            WHERE FST_Location__c IN :locationIdSet
            AND Status__c IN ('Pending Review', 'Completed')
            WITH SECURITY_ENFORCED
            ORDER BY Scan_End_Date__c DESC
        ]) {
            // Ordered by Scan_End_Date__c DESC, so the first row per location is the
            // latest header AND carries the latest completion date. Captured here to
            // avoid a separate MAX()/GROUP BY aggregate (which is also queryMore-limited).
            if (!latestHeaderByLocation.containsKey(h.FST_Location__c)) {
                latestHeaderByLocation.put(h.FST_Location__c, h.Id);
                if (h.Scan_End_Date__c != null) {
                    completionByLocation.put(h.FST_Location__c, h.Scan_End_Date__c);
                }
            }
        }

        // Get live serial counts from those headers
        if (!latestHeaderByLocation.isEmpty()) {
            Set<Id> headerIds = new Set<Id>(latestHeaderByLocation.values());
            // Build header → location map
            Map<Id, Id> headerToLocation = new Map<Id, Id>();
            for (Id locId : latestHeaderByLocation.keySet()) {
                headerToLocation.put(latestHeaderByLocation.get(locId), locId);
            }

            // Count scans per (header, productCode) WITHOUT a GROUP BY aggregate.
            // Aggregate queries cannot use queryMore(), so any grouped query that would
            // return >2000 groups fails outright — and a single header can already carry
            // ~100+ distinct products, so even small header batches can overflow.
            // Instead we stream the raw serial rows with a SOQL for-loop (which pages in
            // chunks of 200 and supports queryMore) and tally the counts in Apex. This is
            // safe no matter how many FSTs or products exist.
            // Tally structure: locKey -> (productCode -> scanCount)
            Map<String, Map<String, Integer>> scanCountByLocProduct = new Map<String, Map<String, Integer>>();
            for (Inventory_Scanning_Serial__c srl : [
                SELECT Inventory_Scanning_Header__c, Product__r.ProductCode
                FROM Inventory_Scanning_Serial__c
                WHERE Inventory_Scanning_Header__c IN :headerIds
                AND Product__c != null
                AND Product__r.ProductCode != null
                WITH SECURITY_ENFORCED
            ]) {
                Id locId = headerToLocation.get(srl.Inventory_Scanning_Header__c);
                if (locId == null) continue;
                String locKey = (String) locId;
                String prodCode = srl.Product__r.ProductCode;
                if (!scanCountByLocProduct.containsKey(locKey)) {
                    scanCountByLocProduct.put(locKey, new Map<String, Integer>());
                }
                Map<String, Integer> byProduct = scanCountByLocProduct.get(locKey);
                byProduct.put(prodCode, (byProduct.containsKey(prodCode) ? byProduct.get(prodCode) : 0) + 1);
            }

            // Fold the tallies into pivotData
            for (String locKey : scanCountByLocProduct.keySet()) {
                if (!pivotData.containsKey(locKey)) {
                    continue;
                }
                for (String prodCode : scanCountByLocProduct.get(locKey).keySet()) {
                    Integer scanCount = scanCountByLocProduct.get(locKey).get(prodCode);
                    if (pivotData.get(locKey).containsKey(prodCode)) {
                        // Product exists as a ProductItem — fill the scanned slot
                        pivotData.get(locKey).get(prodCode)[1] = scanCount;
                    } else {
                        // Scanned product with no ProductItem at this location (Oracle Qty = 0).
                        // Add it to the pivot so it still appears in the report as a discrepancy.
                        pivotData.get(locKey).put(prodCode, new List<Integer>{ 0, scanCount });
                        if (!productSet.contains(prodCode)) {
                            productSet.add(prodCode);
                            allProducts.add(prodCode);
                        }
                    }
                }
            }

            // Re-sort so any newly added (scanned-only) product columns are ordered
            allProducts.sort();
        }
        // CLS2-06 Fix 2: removed IsActive = true; CLS2-01: WITH SECURITY_ENFORCED
        Map<Id, String> emailByLocation = new Map<Id, String>();
        for (ServiceResource sr : [
            SELECT LocationId, RelatedRecord.Email
            FROM ServiceResource
            WHERE LocationId IN :locationIdSet
            WITH SECURITY_ENFORCED
        ]) {
            if (sr.LocationId != null && sr.RelatedRecord != null) {
                emailByLocation.put(sr.LocationId, (String) sr.RelatedRecord.get('Email'));
            }
        }

        // completionByLocation is populated above from the latest-header loop.

        // Build CSV header
        String header = '"Completion Time","Email","Name","FS NUMBER"';
        for (String prod : allProducts) {
            header += ',' + csvSafe(prod + ' (Oracle Qty)') + ',' + csvSafe(prod + ' (On Hand)');
        }

        // Build data rows
        List<String> lines = new List<String>();
        lines.add(header);

        List<String> sortedLocKeys = new List<String>(pivotData.keySet());
        for (String locKey : sortedLocKeys) {
            Id locId = (Id) locKey;
            String completionTime = '';
            if (completionByLocation.containsKey(locId)) {
                completionTime = completionByLocation.get(locId).format('MM/dd/yy HH:mm');
            }
            String email = emailByLocation.containsKey(locId) ? emailByLocation.get(locId) : '';

            String row = csvSafe(completionTime) + ',' + csvSafe(email) + ',' + csvSafe(fstNameByKey.get(locKey)) + ',' + csvSafe(fstNumberByKey.get(locKey));
            Map<String, List<Integer>> locProducts = pivotData.get(locKey);
            for (String prod : allProducts) {
                if (locProducts.containsKey(prod)) {
                    List<Integer> vals = locProducts.get(prod);
                    row += ',' + vals[0] + ',' + vals[1];
                } else {
                    row += ',0,0';
                }
            }
            lines.add(row);
        }

        logToApiLogger('FSTInventoryController.exportInventoryReportCsv',
            'Report Export',
            'Success',
            'Exported by: ' + UserInfo.getName(),
            'FSTs: ' + pivotData.size() + ', Products: ' + allProducts.size());

        return String.join(lines, '\n');
    }

    private static String csvSafe(String val) {
        if (val == null) return '""';
        return '"' + val.replace('"', '""') + '"';
    }

    // ═══════════════════════════════════════════════════════════════════
    // ─── API LOGGER UTILITY ───────────────────────────────────────────
    // ═══════════════════════════════════════════════════════════════════

    // CLS2-10: logToApiLogger now dispatches to @future to keep DML out of the caller's sync context
    private static void logToApiLogger(String classMethod, String operationType, String status, String request, String response) {
        try {
            String reqTrunc = request != null && request.length() > 131072 ? request.substring(0, 131072) : request;
            String resTrunc = response != null && response.length() > 131072 ? response.substring(0, 131072) : response;
            String uid = operationType.replaceAll(' ', '_') + '_' + DateTime.now().format('yyyyMMdd_HHmmss');
            logAsync(classMethod, operationType, status, reqTrunc, resTrunc, uid);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'API Logger dispatch failed: ' + e.getMessage());
        }
    }

    @future
    private static void logAsync(String classMethod, String operationType, String status,
                                  String request, String response, String uid) {
        try {
            API_Logger__c log = new API_Logger__c();
            log.Class_and_method__c = classMethod;
            log.Operation_Type__c   = operationType;
            log.Status__c           = status;
            log.Request__c          = request;
            log.Response__c         = response;
            log.UniqueIdentifier__c = uid;
            insert log;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'API Logger insert failed: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // ─── NEW METHODS: revertScan / notifySelectedFSTs / uploadFSTInventoryCsv
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @description Reverts a Completed scan session back to In Progress.
     * @param headerId The scan session header Id
     * @param comment Mandatory revert reason
     */
    @AuraEnabled
    public static void revertScan(Id headerId, String comment) {
        if (String.isBlank(comment)) {
            throw new AuraHandledException('A revert reason is required.');
        }
        try {
            // CLS2-11: List<>+isEmpty() guard; CLS2-01: WITH SECURITY_ENFORCED
            List<Inventory_Scanning_Header__c> headers = [
                SELECT Id, Status__c, Comments__c, FST_Location__r.Name
                FROM Inventory_Scanning_Header__c
                WHERE Id = :headerId
                AND Status__c = 'Completed'
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (headers.isEmpty()) {
                throw new AuraHandledException('Scan session not found. Please refresh.');
            }
            Inventory_Scanning_Header__c header = headers[0];
            header.Status__c   = 'In Progress';
            header.Comments__c = comment;
            update header;
            logToApiLogger('FSTInventoryController.revertScan',
                'Manager Reverts',
                'Success',
                'Reverted by: ' + UserInfo.getName() + ', Reason: ' + comment,
                'Header: ' + headerId + ', FST: ' + header.FST_Location__r?.Name);
        } catch (AuraHandledException ae) {
            throw ae;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to revert scan: ' + e.getMessage());
        }
    }

    /**
     * @description Sends Stock_Tick_Initiated notification to FSTs owning the selected headers.
     * @param headerIds List of Inventory_Scanning_Header__c Ids whose FSTs to notify
     */
    @AuraEnabled
    public static void notifySelectedFSTs(List<Id> headerIds) {
        if (headerIds == null || headerIds.isEmpty()) {
            throw new AuraHandledException('No FSTs selected for notification.');
        }
        try {
            // CLS2-12: List<>+isEmpty() guard on notification type; CLS2-01: WITH SECURITY_ENFORCED
            List<CustomNotificationType> notifTypes = [
                SELECT Id FROM CustomNotificationType
                WHERE DeveloperName = 'Stock_Tick_Initiated'
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (notifTypes.isEmpty()) {
                throw new AuraHandledException('Notification type not configured. Contact your administrator.');
            }

            // Bulk-resolve users from header locations — NO IsActive filter
            Set<Id> locationIds = new Set<Id>();
            for (Inventory_Scanning_Header__c h : [
                SELECT FST_Location__c FROM Inventory_Scanning_Header__c
                WHERE Id IN :headerIds
                AND FST_Location__c != null
                WITH SECURITY_ENFORCED
            ]) {
                locationIds.add(h.FST_Location__c);
            }

            Set<String> recipientIds = new Set<String>();
            if (!locationIds.isEmpty()) {
                for (ServiceResource sr : [
                    SELECT RelatedRecordId FROM ServiceResource
                    WHERE LocationId IN :locationIds
                    AND RelatedRecordId != null
                    WITH SECURITY_ENFORCED
                ]) {
                    recipientIds.add(sr.RelatedRecordId);
                }
            }

            if (recipientIds.isEmpty()) {
                throw new AuraHandledException('No users found for selected FST locations.');
            }

            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setTitle('Stock Reconciliation Started');
            notification.setBody('Your manager has requested you begin scanning your inventory.');
            notification.setNotificationTypeId(notifTypes[0].Id);
            notification.setTargetPageRef('{"type":"standard__namedPage","attributes":{"pageName":"home"}}');
            notification.send(recipientIds);

            logToApiLogger('FSTInventoryController.notifySelectedFSTs',
                'Selective Notification',
                'Success',
                'Notified by: ' + UserInfo.getName(),
                'Headers: ' + headerIds.size() + ', Recipients: ' + recipientIds.size());
        } catch (AuraHandledException ae) {
            throw ae;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to notify FSTs: ' + e.getMessage());
        }
    }

    /**
     * @description Parses a CSV and creates Inventory_Scanning_Serial__c records on behalf of an absent FST.
     * @param headerId The Not Started scan session header Id
     * @param csvContent Raw CSV string (serial_number/product_code or product_code/quantity rows)
     */
    @AuraEnabled
    public static void uploadFSTInventoryCsv(Id headerId, String csvContent) {
        if (String.isBlank(csvContent)) {
            throw new AuraHandledException('CSV content is empty.');
        }
        try {
            // CLS2-13: List<>+isEmpty() guard; CLS2-01: WITH SECURITY_ENFORCED
            // Proxy_Upload__c field must exist from FEAT-001
            List<Inventory_Scanning_Header__c> headers = [
                SELECT Id, FST_Location__c, Status__c, FST_Location__r.Name
                FROM Inventory_Scanning_Header__c
                WHERE Id = :headerId
                AND Status__c = 'Not Started'
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (headers.isEmpty()) {
                throw new AuraHandledException('Scan session not found or not in Not Started status.');
            }
            Inventory_Scanning_Header__c header = headers[0];

            // Build productCode → Product2Id map from location inventory
            Map<String, Id> productCodeToId = new Map<String, Id>();
            for (ProductItem pi : [
                SELECT Product2.ProductCode, Product2Id
                FROM ProductItem
                WHERE LocationId = :header.FST_Location__c
                AND QuantityOnHand > 0
                WITH SECURITY_ENFORCED
            ]) {
                if (pi.Product2?.ProductCode != null) {
                    productCodeToId.put(pi.Product2.ProductCode.toUpperCase(), pi.Product2Id);
                }
            }

            List<String> rows = csvContent.split('\n');
            String headerRow = rows[0].toLowerCase().trim();
            Boolean hasSerial = headerRow.contains('serial_number');
            Boolean hasQty    = headerRow.contains('quantity');

            if (!hasSerial && !hasQty) {
                throw new AuraHandledException('CSV must contain a serial_number or quantity column.');
            }

            // Parse column positions
            List<String> cols = headerRow.split(',');
            Integer colSerial = -1, colProduct = -1, colQty = -1;
            for (Integer i = 0; i < cols.size(); i++) {
                String col = cols[i].trim();
                if (col == 'serial_number') colSerial  = i;
                if (col == 'product_code')  colProduct = i;
                if (col == 'quantity')      colQty     = i;
            }

            List<Inventory_Scanning_Serial__c> toInsert = new List<Inventory_Scanning_Serial__c>();
            List<String> skippedRows = new List<String>();

            for (Integer r = 1; r < rows.size(); r++) {
                String row = rows[r].trim();
                if (String.isBlank(row)) continue;
                List<String> vals = row.split(',');

                String productCode = (colProduct >= 0 && colProduct < vals.size())
                    ? vals[colProduct].trim().toUpperCase() : null;
                Id productId = productCode != null ? productCodeToId.get(productCode) : null;

                if (productId == null) {
                    skippedRows.add('Row ' + r + ': product code "' + productCode + '" not found.');
                    continue;
                }

                if (colSerial >= 0 && colSerial < vals.size()) {
                    // Serialized row — one record per serial
                    String serial = vals[colSerial].trim();
                    if (String.isBlank(serial)) {
                        skippedRows.add('Row ' + r + ': empty serial number.');
                        continue;
                    }
                    toInsert.add(new Inventory_Scanning_Serial__c(
                        Inventory_Scanning_Header__c = headerId,
                        Serial_Number__c = serial,
                        Product__c = productId,
                        Scanning_Date__c = DateTime.now()
                    ));
                } else if (colQty >= 0 && colQty < vals.size()) {
                    // Non-serialized row — insert one record per unit with Serial_Number__c = null
                    Integer qty = 0;
                    try {
                        qty = Integer.valueOf(vals[colQty].trim());
                    } catch (Exception ex) {
                        skippedRows.add('Row ' + r + ': invalid quantity.');
                        continue;
                    }
                    for (Integer q = 0; q < qty; q++) {
                        toInsert.add(new Inventory_Scanning_Serial__c(
                            Inventory_Scanning_Header__c = headerId,
                            Serial_Number__c = null,
                            Product__c = productId,
                            Scanning_Date__c = DateTime.now()
                        ));
                    }
                }
            }

            if (!toInsert.isEmpty()) insert toInsert;

            header.Status__c       = 'Pending Review';
            header.Proxy_Upload__c = true;
            // Total_Serial_Numbers_Scanned__c is a roll-up — auto-updated by serial insert above
            update header;

            String skippedSummary = skippedRows.isEmpty() ? 'None' : String.join(skippedRows, '; ');
            logToApiLogger('FSTInventoryController.uploadFSTInventoryCsv',
                'Proxy CSV Upload',
                skippedRows.isEmpty() ? 'Success' : 'Partial',
                'Uploaded by: ' + UserInfo.getName() + ' for FST: ' + header.FST_Location__r?.Name,
                'Inserted: ' + toInsert.size() + ', Skipped: ' + skippedRows.size()
                    + ', Details: ' + skippedSummary);

            if (!skippedRows.isEmpty()) {
                throw new AuraHandledException('PARTIAL:' + String.join(skippedRows, '|'));
            }
        } catch (AuraHandledException ae) {
            throw ae;
        } catch (Exception e) {
            throw new AuraHandledException('Upload failed: ' + e.getMessage());
        }
    }

    public class ReportWrapper {
        @AuraEnabled public String id;
        @AuraEnabled public String customerNumber;
        @AuraEnabled public String customerName;
        @AuraEnabled public String sku;
        @AuraEnabled public String uom;
        @AuraEnabled public String shiptoLocation;
        @AuraEnabled public String fstInstallerName;
        @AuraEnabled public String productName;
        @AuraEnabled public Decimal qtyOnHand;
        @AuraEnabled public Decimal scanCount;
        @AuraEnabled public Decimal minQty;
        @AuraEnabled public Decimal maxQty;
        @AuraEnabled public Decimal lotMultiplier;
        @AuraEnabled public String planningMethod;
        @AuraEnabled public Datetime lastUpdated;
    }

    // ═══════════════════════════════════════════════════════════════════
    // ─── WRAPPER CLASSES ──────────────────────────────────────────────
    // ═══════════════════════════════════════════════════════════════════

    public class FSTLocationOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public Integer itemCount;
    }

    // CLS2-04: removed totalCount/pageSize/pageNumber/totalPages; added hasMore
    public class FSTInventoryResult {
        @AuraEnabled public List<FSTInventoryWrapper> items;
        @AuraEnabled public Boolean hasMore;
    }

    public class FSTInventoryWrapper {
        @AuraEnabled public String Id;
        @AuraEnabled public String LocationName;
        @AuraEnabled public String ProductName;
        @AuraEnabled public Decimal QuantityOnHand;
        @AuraEnabled public Datetime LastModifiedDate;
        @AuraEnabled public Decimal MinimumQuantity;
        @AuraEnabled public Decimal FixedLotMultiplier;
        @AuraEnabled public String PlanningMethod;
        @AuraEnabled public Decimal ScanCount;
        @AuraEnabled public Integer rmaCount;
        @AuraEnabled public List<FSTRMADetail> rmas;
    }

    public class FSTRMADetail {
        @AuraEnabled public String rmaNumber;
        @AuraEnabled public String status;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public Datetime approvalDate;
        @AuraEnabled public Decimal quantityReturned;
    }

    public class PendingScanWrapper {
        @AuraEnabled public String headerId;
        @AuraEnabled public String headerName;
        @AuraEnabled public String fstName;
        @AuraEnabled public Integer totalScanned;
        @AuraEnabled public DateTime submittedDate;
        @AuraEnabled public String createdByName;
        @AuraEnabled public String status;
    }

    public class ScanLineItemWrapper {
        @AuraEnabled public String id;
        @AuraEnabled public String serialNumber;
        @AuraEnabled public String productName;
        @AuraEnabled public String productCode;
        @AuraEnabled public DateTime scanDate;
    }

    public class ProductBreakdownWrapper {
        @AuraEnabled public String productName;
        @AuraEnabled public Integer scanned;
        @AuraEnabled public Integer expected;
        @AuraEnabled public Boolean hasMismatch;
    }
}