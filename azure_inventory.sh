#!/usr/bin/env bash
# =============================================================================
# Azure Resource Inventory -- Comprehensive Edition  v3.0
#
# WHAT IT DOES
#   Inventories every ARM resource in a subscription and classifies each one's
#   availability configuration using multiple signals:
#     zones[]                   (IaaS: VMs, Disks, LB, Firewall, AppGW ...)
#     sku.name                  (Storage ZRS/GZRS, VNet GW AZ-SKUs, LB SKU)
#     properties.zoneRedundant  (App Service, Redis, SQL DB/MI, Event Hubs)
#     properties.highAvailability.mode  (PostgreSQL / MySQL Flexible Server)
#     properties.zoneRedundancy (Container Registry)
#     CosmosDB locations[].isZoneRedundant  (dedicated Resource Graph sub-query)
#     AKS agentPoolProfiles[].availabilityZones (dedicated sub-query)
#     Service-level knowledge   (auto-ZR services: Key Vault, Logic Apps, etc.)
#
# AVAILABILITY CONFIG VALUES
#   Non-Regional                  Global service; no region/zone concept
#   Zone Redundant                Spans multiple AZs automatically or configured
#   Zone Redundant + Geo          ZRS + Geo (storage GZRS / RA-GZRS)
#   Zone Redundant (Inherited)    App/Function inherits ZR from App Service Plan
#   Zonal - Zone N                Pinned to a specific availability zone
#   Zonal - Same Zone HA          DB HA standby in same zone (not zone-resilient)
#   AZ Capable - Not Configured   Supports AZ but THIS instance is NOT using it
#   Zonal Capable - Not Configured Supports zonal pinning but not set
#   Regional (Geo-Redundant)      GRS/RA-GRS storage -- no zone redundancy
#   Regional                      No AZ support for this type / tier / region
#   Edge Zone / Extended Location Deployed to an edge zone
#   UNCLASSIFIED (...)            Type not yet mapped in this script (see below)
#
# UNCLASSIFIED RESOURCES
#   Any resource type not explicitly handled is written to the CSV with
#   "UNCLASSIFIED" in the Availability Configuration column and "?" in the
#   AZ Capable / Resiliency Gap columns.
#
#   After all normal rows the CSV contains:
#     - A blank separator row
#     - A banner row visible as a spreadsheet row
#     - One summary row per unique unclassified type (type, count, zones hint,
#       and a ready-to-paste bash case snippet)
#
#   A companion file  <output>_unclassified_snippet.sh  is also generated with
#   a skeleton case block for every unclassified type so you can paste it
#   directly into the get_availability() function.
#
# CSV COLUMNS (18)
#   Subscription, Subscription ID, Resource Group, Resource Name,
#   Resource ID, Resource Type, Provider Namespace, Group Type,
#   Service Category, SKU Name, SKU Tier, Location,
#   Tags (JSON), Availability Configuration, Zones (raw),
#   AZ Capable (Y/N), Resiliency Gap (Y/N), Notes
#
# PREREQUISITES
#   - Azure CLI >= 2.40  (az login  or  SP env vars: AZURE_CLIENT_ID etc.)
#   - jq >= 1.6
#   - az extension: resource-graph  (auto-installed if missing)
#
# USAGE
#   chmod +x azure_inventory.sh
#   ./azure_inventory.sh <subscription-id>
#   ./azure_inventory.sh <subscription-id> my_inventory.csv
# =============================================================================

set -euo pipefail

# -- Colours -------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
log_info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${RESET}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_err()   { echo -e "${RED}[ERR ]${RESET}  $*" >&2; }
log_step()  { echo -e "\n${BLUE}${BOLD}---- $* ----${RESET}"; }

# -- Arguments -----------------------------------------------------------------
SUBSCRIPTION_ID="${1:-}"
OUTPUT_FILE="${2:-azure_inventory_$(date +%Y%m%d_%H%M%S).csv}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ -z "$SUBSCRIPTION_ID" ]]; then
  echo -e "${BOLD}Usage:${RESET} $0 <subscription-id> [output.csv]"
  exit 1
fi

# -- Prerequisites -------------------------------------------------------------
log_step "Prerequisites"
command -v az  &>/dev/null || { log_err "Azure CLI (az) not found."; exit 1; }
command -v jq  &>/dev/null || { log_err "jq not found. Install: apt-get install jq / brew install jq"; exit 1; }

if ! az extension show --name resource-graph &>/dev/null 2>&1; then
  log_warn "resource-graph extension not found -- installing..."
  az extension add --name resource-graph --only-show-errors
fi
log_ok "All prerequisites satisfied."

# -- Validate Subscription -----------------------------------------------------
log_step "Subscription"
if ! az account set --subscription "$SUBSCRIPTION_ID" 2>/dev/null; then
  log_err "Cannot set subscription '$SUBSCRIPTION_ID'. Check az login and RBAC permissions."
  exit 1
fi
SUBSCRIPTION_NAME=$(az account show --query "name" -o tsv)
log_ok "Subscription: ${BOLD}${SUBSCRIPTION_NAME}${RESET} (${SUBSCRIPTION_ID})"

# -- Step 1: Resource Graph bulk fetch with pagination -------------------------
log_step "Fetching all resources via Azure Resource Graph"

RG_QUERY='resources
| where subscriptionId =~ "'"$SUBSCRIPTION_ID"'"
| extend
    zonesArr    = iff(array_length(zones) > 0, zones, dynamic([])),
    skuName     = tostring(sku.name),
    skuTier     = tostring(sku.tier),
    kindVal     = tostring(kind),
    extLoc      = tostring(extendedLocation.type),
    extLocName  = tostring(extendedLocation.name),
    propZR      = tostring(properties.zoneRedundant),
    propZRed    = tostring(properties.zoneRedundancy),
    propHAMode  = tostring(properties.highAvailability.mode),
    propRedund  = tostring(properties.redundancySettings.standardTierStorageRedundancy),
    propLBFEZones = iif(type =~ "microsoft.network/loadbalancers",
                      tostring(properties.frontendIPConfigurations[0].zones),
                      ""),
    propGWSku     = iif(type =~ "microsoft.network/virtualnetworkgateways",
                      tostring(properties.sku.name),
                      "")
| project
    id, name, resourceGroup, type, location, tags,
    zonesArr, skuName, skuTier, kindVal,
    extLoc, extLocName,
    propZR, propZRed, propHAMode, propRedund, propLBFEZones, propGWSku'

SKIP=0
PAGE_SIZE=1000
ALL_RESOURCES="[]"
TOTAL_FETCHED=0

while true; do
  PAGE_FILE="$WORK_DIR/page_${SKIP}.json"
  if ! az graph query \
       --subscriptions "$SUBSCRIPTION_ID" \
       --graph-query "$RG_QUERY" \
       --first "$PAGE_SIZE" \
       --skip "$SKIP" \
       --output json \
       --only-show-errors \
       > "$PAGE_FILE" 2>/dev/null; then
    log_warn "Resource Graph query failed at skip=$SKIP -- stopping pagination"
    break
  fi
  PAGE_COUNT=$(jq '.count // 0' "$PAGE_FILE")
  [[ "$PAGE_COUNT" -eq 0 ]] && break
  ALL_RESOURCES=$(jq -s '.[0] + .[1]' <(echo "$ALL_RESOURCES") <(jq '.data' "$PAGE_FILE"))
  TOTAL_FETCHED=$((TOTAL_FETCHED + PAGE_COUNT))
  log_info "  Fetched ${TOTAL_FETCHED} resources so far..."
  [[ "$PAGE_COUNT" -lt "$PAGE_SIZE" ]] && break
  SKIP=$((SKIP + PAGE_SIZE))
done

TOTAL=$(echo "$ALL_RESOURCES" | jq 'length')

if [[ "$TOTAL" -eq 0 ]]; then
  log_warn "Resource Graph returned 0 resources. Falling back to az resource list..."
  az resource list \
    --subscription "$SUBSCRIPTION_ID" \
    --query "[].{id:id,name:name,resourceGroup:resourceGroup,type:type,
               location:location,tags:tags,zones:zones,
               skuName:sku.name,skuTier:sku.tier,kindVal:kind}" \
    -o json \
  | jq '[.[] | . + {
      zonesArr: (.zones // []), propZR: "", propZRed: "",
      propHAMode: "", propRedund: "", extLoc: "", extLocName: "", propLBFEZones: "", propGWSku: ""
    }]' > "$WORK_DIR/all_resources.json"
  TOTAL=$(jq 'length' "$WORK_DIR/all_resources.json")
else
  echo "$ALL_RESOURCES" > "$WORK_DIR/all_resources.json"
fi

log_ok "Total resources to process: ${BOLD}${TOTAL}${RESET}"

# -- Step 2: AKS node pool zone sub-query --------------------------------------
log_step "Fetching AKS node pool availability zones"
az graph query \
  --subscriptions "$SUBSCRIPTION_ID" \
  --graph-query '
    resources
    | where subscriptionId =~ "'"$SUBSCRIPTION_ID"'"
    | where type =~ "microsoft.containerservice/managedclusters"
    | extend agentPools = properties.agentPoolProfiles
    | mv-expand pool = agentPools
    | extend poolZones = tostring(pool.availabilityZones)
    | summarize allZones=make_set(poolZones) by id
    | project id, allZones' \
  --output json --only-show-errors 2>/dev/null \
| jq '[.data[] // empty]' > "$WORK_DIR/aks_zones.json" 2>/dev/null \
|| echo "[]" > "$WORK_DIR/aks_zones.json"

jq 'reduce .[] as $r ({}; . + {($r.id | ascii_downcase): $r.allZones})' \
  "$WORK_DIR/aks_zones.json" > "$WORK_DIR/aks_map.json" 2>/dev/null \
|| echo '{}' > "$WORK_DIR/aks_map.json"

# -- Step 3: CosmosDB zone sub-query -------------------------------------------
log_step "Fetching Cosmos DB zone redundancy"
az graph query \
  --subscriptions "$SUBSCRIPTION_ID" \
  --graph-query '
    resources
    | where subscriptionId =~ "'"$SUBSCRIPTION_ID"'"
    | where type =~ "microsoft.documentdb/databaseaccounts"
    | mv-expand loc = properties.locations
    | extend locZR = tobool(loc.isZoneRedundant)
    | summarize anyZR = max(toint(locZR)) by id
    | project id, anyZR' \
  --output json --only-show-errors 2>/dev/null \
| jq '[.data[] // empty]' > "$WORK_DIR/cosmos_zones.json" 2>/dev/null \
|| echo "[]" > "$WORK_DIR/cosmos_zones.json"

jq 'reduce .[] as $r ({}; . + {($r.id | ascii_downcase): $r.anyZR})' \
  "$WORK_DIR/cosmos_zones.json" > "$WORK_DIR/cosmos_map.json" 2>/dev/null \
|| echo '{}' > "$WORK_DIR/cosmos_map.json"

# -- Step 4: Parent-link sub-query (Web Apps → ASP, App Insights → Workspace, NICs → VM) ---
log_step "Fetching parent-resource links (Web Apps / App Insights / NICs)"
az graph query \
  --subscriptions "$SUBSCRIPTION_ID" \
  --graph-query '
    resources
    | where subscriptionId =~ "'"$SUBSCRIPTION_ID"'"
    | where type in~ ("microsoft.web/sites",
                      "microsoft.insights/components",
                      "microsoft.network/networkinterfaces",
                      "microsoft.compute/virtualmachines/extensions")
    | extend parentId = case(
        type =~ "microsoft.web/sites",
          tolower(tostring(properties.serverFarmId)),
        type =~ "microsoft.insights/components",
          tolower(tostring(properties.WorkspaceResourceId)),
        type =~ "microsoft.network/networkinterfaces",
          tolower(tostring(properties.virtualMachine.id)),
        type =~ "microsoft.compute/virtualmachines/extensions",
          tolower(tostring(strcat_array(array_slice(split(id, "/"), 0, 9), "/"))),
        "")
    | project id, type, parentId' \
  --output json --only-show-errors 2>/dev/null \
| jq '[.data[] // empty]' > "$WORK_DIR/parent_links.json" 2>/dev/null \
|| echo "[]" > "$WORK_DIR/parent_links.json"

# Build per-type link maps from the parent_links query
jq 'reduce .[] as $r ({};
  if ($r.type | ascii_downcase) == "microsoft.web/sites"
  then . + {($r.id | ascii_downcase): $r.parentId}
  else . end)' "$WORK_DIR/parent_links.json" > "$WORK_DIR/webapp_asp_map.json" 2>/dev/null \
|| echo "{}" > "$WORK_DIR/webapp_asp_map.json"

jq 'reduce .[] as $r ({};
  if ($r.type | ascii_downcase) == "microsoft.insights/components"
  then . + {($r.id | ascii_downcase): $r.parentId}
  else . end)' "$WORK_DIR/parent_links.json" > "$WORK_DIR/appinsights_ws_map.json" 2>/dev/null \
|| echo "{}" > "$WORK_DIR/appinsights_ws_map.json"

jq 'reduce .[] as $r ({};
  if ($r.type | ascii_downcase) == "microsoft.network/networkinterfaces"
  then . + {($r.id | ascii_downcase): $r.parentId}
  else . end)' "$WORK_DIR/parent_links.json" > "$WORK_DIR/nic_vm_map.json" 2>/dev/null \
|| echo "{}" > "$WORK_DIR/nic_vm_map.json"

# VM Extensions also resolve to their parent VM via the same vm_zone_map
jq 'reduce .[] as $r ({};
  if ($r.type | ascii_downcase) == "microsoft.compute/virtualmachines/extensions"
  then . + {($r.id | ascii_downcase): $r.parentId}
  else . end)' "$WORK_DIR/parent_links.json" > "$WORK_DIR/vmext_vm_map.json" 2>/dev/null \
|| echo "{}" > "$WORK_DIR/vmext_vm_map.json"

# Build parent-property lookup maps from already-fetched all_resources.json (no extra API calls)
# ASP ZR map: asp_id → "zr" | "capable" | "regional"
jq 'reduce .[] as $r ({};
  if ($r.type | ascii_downcase) == "microsoft.web/serverfarms"
  then
    . + {($r.id | ascii_downcase): {
      zr:  ($r.propZR == "true"),
      sku: ($r.skuName // "" | ascii_downcase)
    }}
  else . end)' "$WORK_DIR/all_resources.json" > "$WORK_DIR/asp_info_map.json" 2>/dev/null \
|| echo "{}" > "$WORK_DIR/asp_info_map.json"

# Workspace info map: workspace_id → {location, zr}
jq 'reduce .[] as $r ({};
  if ($r.type | ascii_downcase) == "microsoft.operationalinsights/workspaces"
  then
    . + {($r.id | ascii_downcase): {
      location: $r.location,
      zr:       ($r.propZR == "true")
    }}
  else . end)' "$WORK_DIR/all_resources.json" > "$WORK_DIR/workspace_info_map.json" 2>/dev/null \
|| echo "{}" > "$WORK_DIR/workspace_info_map.json"

# VM zone map: vm_id → zones array (e.g. ["1"])
jq 'reduce .[] as $r ({};
  if ($r.type | ascii_downcase) == "microsoft.compute/virtualmachines"
  then . + {($r.id | ascii_downcase): ($r.zonesArr // [])}
  else . end)' "$WORK_DIR/all_resources.json" > "$WORK_DIR/vm_zone_map.json" 2>/dev/null \
|| echo "{}" > "$WORK_DIR/vm_zone_map.json"

log_ok "Sub-queries complete."

# -- Helpers -------------------------------------------------------------------
csv_field() {
  local val="${1//\"/\"\"}"
  printf '"%s"' "$val"
}

# -- Group Type ----------------------------------------------------------------
get_group_type() {
  local t="${1,,}"
  local ns; ns=$(cut -d'/' -f1 <<< "$t")
  case "$ns" in
    microsoft.compute)
      case "$t" in
        *virtualmachinescalesets*) echo "Compute - VMSS" ;;
        *virtualmachines/extensions*) echo "Compute - Virtual Machines" ;;
        *virtualmachines*)         echo "Compute - Virtual Machines" ;;
        *sshpublickeys*)           echo "Compute" ;;
        *disks*)                   echo "Compute - Managed Disks" ;;
        *snapshots*)               echo "Compute - Snapshots" ;;
        *images*|*galleries*)      echo "Compute - Compute Gallery / Images" ;;
        *availabilitysets*)        echo "Compute - Availability Sets" ;;
        *dedicatedhosts*)          echo "Compute - Dedicated Hosts" ;;
        *capacityreservation*)     echo "Compute - Capacity Reservations" ;;
        *proximityplacement*)      echo "Compute - Proximity Placement Groups" ;;
        *)                         echo "Compute" ;;
      esac ;;
    microsoft.classiccompute)          echo "Compute (Classic)" ;;
    microsoft.batch)                   echo "Compute - Batch" ;;
    microsoft.servicefabric)           echo "Compute - Service Fabric" ;;
    microsoft.appplatform)             echo "Compute - Spring Apps" ;;
    microsoft.avs|microsoft.vmware)    echo "Compute - Azure VMware Solution" ;;
    microsoft.desktopvirtualization)   echo "Compute - Virtual Desktop" ;;
    microsoft.labservices|microsoft.devtestlabs) echo "Compute - Lab Services" ;;
    microsoft.quantum)                 echo "Compute - Quantum" ;;
    microsoft.hanaonazure)             echo "Compute - SAP HANA Large Instances" ;;
    microsoft.virtualmachineimages)    echo "Compute - Image Builder" ;;
    microsoft.maintenance)             echo "Compute - Maintenance" ;;
    microsoft.serialconsole)           echo "Compute - Serial Console" ;;
    microsoft.network)
      case "$t" in
        *trafficmanagerprofiles*)      echo "Networking - Traffic Manager (Global)" ;;
        *frontdoors*)                  echo "Networking - Front Door (Global)" ;;
        *expressroute*)                echo "Networking - ExpressRoute" ;;
        *virtualwan*|*virtualhub*)     echo "Networking - Virtual WAN" ;;
        *vpngate*|*vpnsites*)          echo "Networking - VPN Gateway" ;;
        *virtualnetworkgateway*)       echo "Networking - VNet Gateway (VPN/ER)" ;;
        *azurefirewall*)               echo "Networking - Azure Firewall" ;;
        *firewallpolic*)               echo "Networking - Firewall Policy" ;;
        *bastionhosts*)                echo "Networking - Azure Bastion" ;;
        *privatelink*|*privateendpoint*) echo "Networking - Private Link / Endpoint" ;;
        *ddosprotection*)              echo "Networking - DDoS Protection" ;;
        *loadbalancer*)                echo "Networking - Load Balancer" ;;
        *applicationgateway*)          echo "Networking - Application Gateway" ;;
        *natgateway*)                  echo "Networking - NAT Gateway" ;;
        *virtualnetworks*)             echo "Networking - Virtual Network" ;;
        *dnszones*|*privatednszones*|*dnsresolvers*) echo "Networking - DNS" ;;
        *routeservers*)                echo "Networking - Route Server" ;;
        *networkwatchers*)             echo "Networking - Network Watcher" ;;
        *publicipaddresses*|*publicipprefixes*) echo "Networking - Public IP" ;;
        *networksecuritygroups*)       echo "Networking - NSG" ;;
        *routetables*)                 echo "Networking - Route Tables" ;;
        *networkinterfaces*)           echo "Networking - Network Interfaces" ;;
        *)                             echo "Networking" ;;
      esac ;;
    microsoft.classicnetwork)          echo "Networking (Classic)" ;;
    microsoft.cdn|microsoft.frontdoor) echo "Networking - CDN / Front Door (Global)" ;;
    microsoft.peering)                 echo "Networking - Peering Service" ;;
    microsoft.hybridnetwork)           echo "Networking - Network Function Manager" ;;
    microsoft.mobilenetwork)           echo "Networking - Private 5G Core" ;;
    microsoft.storage)                 echo "Storage - Storage Accounts" ;;
    microsoft.classicstorage)          echo "Storage (Classic)" ;;
    microsoft.netapp)                  echo "Storage - Azure NetApp Files" ;;
    microsoft.elasticsan)              echo "Storage - Elastic SAN" ;;
    microsoft.storagecache)            echo "Storage - HPC Cache" ;;
    microsoft.storagesync)             echo "Storage - Azure File Sync" ;;
    microsoft.storsimple|microsoft.hybriddata) echo "Storage - StorSimple" ;;
    microsoft.importexport)            echo "Storage - Import/Export" ;;
    microsoft.sql)                     echo "Database - Azure SQL" ;;
    microsoft.sqlvirtualmachine)       echo "Database - SQL on VMs" ;;
    microsoft.azuredata)               echo "Database - Azure Arc SQL" ;;
    microsoft.dbforpostgresql)         echo "Database - PostgreSQL Flexible Server" ;;
    microsoft.dbformysql)              echo "Database - MySQL Flexible Server" ;;
    microsoft.dbformariadb)            echo "Database - MariaDB (deprecated)" ;;
    microsoft.documentdb)              echo "Database - Cosmos DB" ;;
    microsoft.cache)                   echo "Database - Cache for Redis" ;;
    microsoft.cassandra)               echo "Database - Managed Apache Cassandra" ;;
    microsoft.synapse)                 echo "Analytics - Azure Synapse" ;;
    microsoft.databricks)              echo "Analytics - Azure Databricks" ;;
    microsoft.kusto)                   echo "Analytics - Azure Data Explorer" ;;
    microsoft.datafactory)             echo "Analytics - Azure Data Factory" ;;
    microsoft.datalakeanalytics)       echo "Analytics - Data Lake Analytics" ;;
    microsoft.datalakestore)           echo "Analytics - Data Lake Storage" ;;
    microsoft.datashare)               echo "Analytics - Azure Data Share" ;;
    microsoft.hdinsight)               echo "Analytics - HDInsight" ;;
    microsoft.streamanalytics)         echo "Analytics - Stream Analytics" ;;
    microsoft.powerbi)                 echo "Analytics - Power BI" ;;
    microsoft.powerbidedicated)        echo "Analytics - Power BI Embedded" ;;
    microsoft.fabric)                  echo "Analytics - Microsoft Fabric" ;;
    microsoft.purview)                 echo "Analytics - Microsoft Purview" ;;
    microsoft.analysisservices)        echo "Analytics - Analysis Services" ;;
    microsoft.datacatalog|microsoft.projectbabylon) echo "Analytics - Data Catalog" ;;
    microsoft.web)
      case "$t" in
        *serverfarms*)                 echo "App Services - App Service Plan" ;;
        *hostingenvironments*)         echo "App Services - App Service Environment" ;;
        *staticsites*)                 echo "App Services - Static Web Apps" ;;
        *sites/slots*)                 echo "App Services - Deployment Slot" ;;
        *sites*)                       echo "App Services - Web / Function App" ;;
        *)                             echo "App Services" ;;
      esac ;;
    microsoft.certificateregistration) echo "App Services - Certificates" ;;
    microsoft.domainregistration)      echo "App Services - Domain Registration" ;;
    microsoft.app)                     echo "Containers - Azure Container Apps" ;;
    microsoft.containerservice)        echo "Containers - AKS" ;;
    microsoft.containerregistry)       echo "Containers - Container Registry" ;;
    microsoft.containerinstance)       echo "Containers - Container Instances" ;;
    microsoft.redhatopenshift)         echo "Containers - Azure Red Hat OpenShift" ;;
    microsoft.keyvault)                echo "Security - Key Vault" ;;
    microsoft.security)                echo "Security - Microsoft Defender" ;;
    microsoft.securityinsights)        echo "Security - Microsoft Sentinel" ;;
    microsoft.hardwaresecuritymodules) echo "Security - Dedicated HSM" ;;
    microsoft.attestation)             echo "Security - Azure Attestation" ;;
    microsoft.customerlockbox)         echo "Security - Customer Lockbox" ;;
    microsoft.dataprotection)          echo "Security - Data Protection / Backup Vaults" ;;
    microsoft.windowsdefenderatp)      echo "Security - Defender ATP" ;;
    microsoft.windowsesu)              echo "Security - Extended Security Updates" ;;
    microsoft.cognitiveservices)       echo "AI & ML - Cognitive Services / Azure AI" ;;
    microsoft.machinelearningservices) echo "AI & ML - Azure Machine Learning" ;;
    microsoft.botservice)              echo "AI & ML - Azure Bot Service" ;;
    microsoft.search)                  echo "AI & ML - Azure AI Search" ;;
    microsoft.enterpriseknowledgegraph) echo "AI & ML - Enterprise Knowledge Graph" ;;
    microsoft.autonomoussystems)       echo "AI & ML - Autonomous Systems" ;;
    microsoft.apimanagement)           echo "Integration - API Management" ;;
    microsoft.logic)                   echo "Integration - Logic Apps" ;;
    microsoft.servicebus)              echo "Integration - Service Bus" ;;
    microsoft.eventhub)                echo "Integration - Event Hubs" ;;
    microsoft.eventgrid)               echo "Integration - Event Grid" ;;
    microsoft.notificationhubs)        echo "Integration - Notification Hubs" ;;
    microsoft.relay)                   echo "Integration - Azure Relay" ;;
    microsoft.communication)           echo "Integration - Communication Services" ;;
    microsoft.powerplatform)           echo "Integration - Power Platform" ;;
    microsoft.healthcareapis)          echo "Integration - Healthcare APIs / FHIR" ;;
    microsoft.signalrservice)          echo "Real-time - Azure SignalR Service" ;;
    microsoft.webpubsub)               echo "Real-time - Azure Web PubSub" ;;
    microsoft.devices)                 echo "IoT - Azure IoT Hub / DPS" ;;
    microsoft.iotcentral)              echo "IoT - Azure IoT Central" ;;
    microsoft.iotoperations)           echo "IoT - Azure IoT Operations" ;;
    microsoft.deviceregistry)          echo "IoT - Azure Device Registry" ;;
    microsoft.deviceupdate)            echo "IoT - Device Update for IoT Hub" ;;
    microsoft.digitaltwins)            echo "IoT - Azure Digital Twins" ;;
    microsoft.iotspaces)               echo "IoT - Digital Twins (legacy)" ;;
    microsoft.windowsiot)              echo "IoT - Windows IoT Core Services" ;;
    microsoft.insights)                echo "Monitoring - Application Insights" ;;
    microsoft.operationalinsights)     echo "Monitoring - Log Analytics" ;;
    microsoft.monitor)                 echo "Monitoring - Azure Monitor" ;;
    microsoft.alertsmanagement)        echo "Monitoring - Azure Alerts Management" ;;
    microsoft.dashboard)               echo "Monitoring - Azure Managed Grafana" ;;
    microsoft.operationsmanagement)    echo "Monitoring - Operations Management" ;;
    microsoft.workloadmonitor)         echo "Monitoring - Workload Monitor" ;;
    microsoft.changeanalysis)          echo "Monitoring - Change Analysis" ;;
    microsoft.aad)                     echo "Identity - Microsoft Entra Domain Services" ;;
    microsoft.azureactivedirectory)    echo "Identity - Microsoft Entra ID B2C" ;;
    microsoft.adhybridhealthservice)   echo "Identity - Entra Hybrid Health" ;;
    microsoft.managedidentity)         echo "Identity - Managed Identities" ;;
    microsoft.token)                   echo "Identity - Token Service" ;;
    microsoft.recoveryservices)        echo "BCDR - Recovery Services / Backup" ;;
    microsoft.automation)              echo "Management - Azure Automation" ;;
    microsoft.blueprint)               echo "Management - Azure Blueprints" ;;
    microsoft.advisor)                 echo "Management - Azure Advisor" ;;
    microsoft.authorization)           echo "Management - Authorization / RBAC" ;;
    microsoft.management)              echo "Management - Management Groups" ;;
    microsoft.resources)               echo "Management - Azure Resource Manager" ;;
    microsoft.policy|microsoft.policyinsights) echo "Management - Azure Policy" ;;
    microsoft.resourcegraph)           echo "Management - Azure Resource Graph" ;;
    microsoft.resourcehealth)          echo "Management - Azure Service Health" ;;
    microsoft.portal)                  echo "Management - Azure Portal" ;;
    microsoft.solutions)               echo "Management - Azure Managed Applications" ;;
    microsoft.customproviders)         echo "Management - Custom Resource Providers" ;;
    microsoft.managedservices)         echo "Management - Azure Lighthouse" ;;
    microsoft.guestconfiguration)      echo "Management - Guest Configuration" ;;
    microsoft.costmanagement|microsoft.consumption|microsoft.billing|microsoft.costmanagementexports)
                                       echo "Management - Cost Management and Billing" ;;
    microsoft.subscription|microsoft.capacity) echo "Management - Subscription Management" ;;
    microsoft.softwareplan)            echo "Management - Software Plans / Licensing" ;;
    microsoft.scheduler)               echo "Management - Azure Scheduler (deprecated)" ;;
    microsoft.features)                echo "Management - Feature Flags" ;;
    microsoft.marketplace|microsoft.marketplaceapps|microsoft.marketplaceordering)
                                       echo "Marketplace" ;;
    microsoft.saas)                    echo "Marketplace - SaaS Resources" ;;
    microsoft.addons)                  echo "Core - Azure Addons" ;;
    microsoft.commerce)                echo "Core - Commerce" ;;
    microsoft.services)                echo "Core - Azure Services" ;;
    microsoft.hybridcompute)           echo "Hybrid - Azure Arc-enabled Servers" ;;
    microsoft.kubernetes|microsoft.kubernetesconfiguration) echo "Hybrid - Azure Arc-enabled Kubernetes" ;;
    microsoft.azurearcdata)            echo "Hybrid - Azure Arc Data Services" ;;
    microsoft.azurestackhci)           echo "Hybrid - Azure Local (Stack HCI)" ;;
    microsoft.azurestack)              echo "Hybrid - Azure Stack" ;;
    microsoft.edge)                    echo "Hybrid - Azure Arc Site Manager" ;;
    microsoft.databox)                 echo "Migration - Azure Data Box" ;;
    microsoft.databoxedge)             echo "Migration - Azure Stack Edge" ;;
    microsoft.datamigration)           echo "Migration - Azure Database Migration" ;;
    microsoft.offazure|microsoft.migrate) echo "Migration - Azure Migrate" ;;
    microsoft.classicinframigrate)     echo "Migration - Classic Migration" ;;
    microsoft.maps)                    echo "Maps and Geospatial - Azure Maps" ;;
    microsoft.media|microsoft.videoindexer) echo "Media - Azure Media Services" ;;
    microsoft.bingmaps)                echo "Maps - Bing Maps" ;;
    microsoft.blockchain|microsoft.blockchaintokens) echo "Blockchain" ;;
    microsoft.appconfiguration)        echo "Developer Tools - App Configuration" ;;
    microsoft.devcenter)               echo "Developer Tools - Microsoft Dev Box" ;;
    microsoft.loadtestservice)         echo "Developer Tools - Azure Load Testing" ;;
    microsoft.devspaces)               echo "Developer Tools - Dev Spaces (deprecated)" ;;
    microsoft.notebooks)               echo "Developer Tools - Azure Notebooks" ;;
    microsoft.visualstudio|microsoft.devops|microsoft.vsonline) echo "DevOps - Azure DevOps" ;;
    microsoft.devopsinfrastructure)    echo "DevOps - Managed DevOps Pools" ;;
    # -------------------------------------------------------------------------
    # FALLBACK: provider namespace is not in the list above.
    # The resource will appear as UNCLASSIFIED in Group Type too so you can spot
    # it in a pivot table and add the correct mapping.
    # -------------------------------------------------------------------------
    *)
      echo "UNCLASSIFIED - ${ns}" ;;
  esac
}

# -- Service Category ----------------------------------------------------------
get_service_category() {
  local t="${1,,}"
  case "$t" in
    microsoft.network/applicationgateways|microsoft.recoveryservices/vaults|\
    microsoft.documentdb/databaseaccounts|microsoft.eventhub/namespaces|\
    microsoft.network/expressroutecircuits|microsoft.keyvault/vaults|\
    microsoft.containerservice/managedclusters|microsoft.network/loadbalancers|\
    microsoft.network/natgateways|microsoft.network/publicipaddresses|\
    microsoft.servicebus/namespaces|microsoft.servicefabric/clusters|\
    microsoft.sql/servers/databases|microsoft.sql/managedinstances|\
    microsoft.storage/storageaccounts|microsoft.compute/virtualmachinescalesets|\
    microsoft.compute/virtualmachines|microsoft.compute/disks|\
    microsoft.network/virtualnetworks|microsoft.network/virtualnetworkgateways|\
    microsoft.network/vpngateways)
      echo "Foundational" ;;
    microsoft.search/*|microsoft.apimanagement/*|microsoft.appconfiguration/*|\
    microsoft.web/serverfarms|microsoft.web/sites|microsoft.web/hostingenvironments|\
    microsoft.network/bastionhosts|microsoft.batch/*|microsoft.cache/redis|\
    microsoft.containerinstance/*|microsoft.containerregistry/*|\
    microsoft.datafactory/*|microsoft.dbformysql/*|microsoft.dbforpostgresql/*|\
    microsoft.network/ddosprotectionplans|microsoft.network/dnsresolvers|\
    microsoft.eventgrid/*|microsoft.network/azurefirewalls|\
    microsoft.network/firewallpolicies|microsoft.hdinsight/*|\
    microsoft.devices/iothubs|microsoft.logic/*|microsoft.insights/components|\
    microsoft.operationalinsights/workspaces|microsoft.network/networkwatchers|\
    microsoft.network/privatelinkservices|microsoft.network/privateendpoints|\
    microsoft.network/virtualwans|microsoft.aad/domainservices)
      echo "Mainstream" ;;
    *)
      echo "Strategic" ;;
  esac
}

# -- Availability Classification -----------------------------------------------
# Returns TAB-separated: avail_config \t az_capable \t resiliency_gap \t notes
#
# UNCLASSIFIED return format (type not mapped in script):
#   UNCLASSIFIED (...hint...) \t ? \t ? \t <message with exact type string>
#
get_availability() {
  local type="$1"
  local zones_json="${2:-[]}"
  local location="${3:-}"
  local sku_name="${4:-}"
  local sku_tier="${5:-}"
  local prop_zr="${6:-}"
  local prop_zred="${7:-}"
  local prop_ha_mode="${8:-}"
  local ext_loc="${9:-}"
  local prop_redund="${10:-}"
  local aks_zones="${11:-[]}"
  local cosmos_zr="${12:-0}"
  local lb_fe_zones="${13:-}"   # zones from LB frontend IP configuration
  local gw_sku="${14:-}"         # properties.sku.name for VNet Gateways
  local parent_info="${15:-}"    # parent-resource context: asp/workspace/vm link

  [[ "$prop_zr"      == "null" ]] && prop_zr=""
  [[ "$prop_zred"    == "null" ]] && prop_zred=""
  [[ "$prop_ha_mode" == "null" ]] && prop_ha_mode=""
  [[ "$prop_redund"  == "null" ]] && prop_redund=""
  [[ "$ext_loc"      == "null" ]] && ext_loc=""

  local pzr_l="${prop_zr,,}"
  local pzred_l="${prop_zred,,}"
  local pha_l="${prop_ha_mode,,}"
  local sku_l="${sku_name,,}"
  local tier_l="${sku_tier,,}"

  local zone_count=0
  if [[ "$zones_json" != "null" && "$zones_json" != "[]" && -n "$zones_json" ]]; then
    zone_count=$(echo "$zones_json" | jq 'length' 2>/dev/null || echo 0)
  fi
  local zone_list=""
  [[ "$zone_count" -gt 0 ]] && zone_list=$(echo "$zones_json" | jq -r 'join(", ")' 2>/dev/null || echo "")

  # Edge Zone
  if [[ -n "$ext_loc" ]]; then
    printf 'Edge Zone / Extended Location\tY\tN\tExtended location type: %s' "$ext_loc"; return
  fi

  # Non-Regional by location name
  # Some resource types falsely report location="global" in Resource Graph but are
  # actually regional (data residency follows a linked workspace / config).
  # These must be handled by the type-specific cases below — skip the early exit.
  local loc_l="${location,,}"
  case "$type" in
    # ALL microsoft.insights/* and microsoft.alertsmanagement/* types report
    # location="global" in Resource Graph but are regional services in practice.
    # Let them fall through to the type-specific classification blocks below.
    microsoft.insights/*|microsoft.alertsmanagement/*)
      : ;; # fall through to type-specific classification below
    *)
      case "$loc_l" in
        global|"")
          printf 'Non-Regional\tN\tN\tService is global / non-regional'; return ;;
      esac ;;
  esac

  # Non-Regional by resource type
  case "$type" in
    microsoft.azureactivedirectory/*|microsoft.management/managementgroups|\
    microsoft.management/*|microsoft.authorization/*|\
    microsoft.resources/subscriptions|microsoft.resources/resourcegroups|\
    microsoft.resources/deployments|microsoft.resources/*|\
    microsoft.network/dnszones|microsoft.network/trafficmanagerprofiles|\
    microsoft.cdn/profiles|microsoft.frontdoor/*|microsoft.network/frontdoors|\
    microsoft.network/frontdoorwebapplicationfirewallpolicies|\
    microsoft.billing/*|microsoft.consumption/*|microsoft.costmanagement/*|\
    microsoft.costmanagementexports/*|microsoft.subscription/*|\
    microsoft.capacity/*|microsoft.commerce/*|microsoft.policyinsights/*|\
    microsoft.resourcegraph/*|microsoft.resourcehealth/*|\
    microsoft.resourcenotification/*|microsoft.portal/*|\
    microsoft.saas/resources|microsoft.addons/*)
      printf 'Non-Regional\tN\tN\tGlobal / non-regional ARM resource'; return ;;
  esac

  # ===========================================================================
  # COMPUTE
  # ===========================================================================
  case "$type" in
    microsoft.compute/virtualmachines)
      if   [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tVM pinned to availability zone %s' "$zone_list" "$zone_list"
      elif [[ "$zone_count" -ge 2 ]]; then printf 'Zonal - Zones %s\tY\tN\tVM spans multiple zones -- use VMSS for zone-resilient compute' "$zone_list"
      else printf 'AZ Capable - Not Configured\tY\tY\tVM has no zone assignment -- critical resiliency gap'
      fi; return ;;

    microsoft.compute/sshpublickeys)
      # SSH Public Keys are metadata-only resources (stored key pairs).
      # No zone concept — purely a control-plane object scoped to a region.
      # Ref: https://learn.microsoft.com/azure/virtual-machines/ssh-keys-azure-cli
      printf 'Regional\tN\tN\tSSH Public Key is a metadata-only resource -- no zone assignment'; return ;;

    microsoft.compute/virtualmachines/extensions)
      # VM Extensions are child resources — their availability is determined entirely
      # by the parent VM's zone placement.
      # parent_info = "vm:zones=["1"]" resolved via parent-link sub-query
      if [[ "$parent_info" == vm:zones=* ]]; then
        local ext_vm_zones ext_vm_zc ext_vm_zl
        ext_vm_zones=$(echo "$parent_info" | sed 's/vm:zones=//')
        ext_vm_zc=$(echo "$ext_vm_zones" | jq 'length' 2>/dev/null || echo 0)
        ext_vm_zl=$(echo "$ext_vm_zones" | jq -r 'join(", ")' 2>/dev/null || echo "")
        if   [[ "$ext_vm_zc" -eq 1 ]]; then printf 'Zonal - Zone %s (Inherited)\tY\tN\tVM Extension follows parent VM in Zone %s' "$ext_vm_zl" "$ext_vm_zl"
        elif [[ "$ext_vm_zc" -ge 2 ]]; then printf 'Zone Redundant (Inherited)\tY\tN\tVM Extension follows parent VM spanning zones %s' "$ext_vm_zl"
        else printf 'Regional\tN\tN\tVM Extension follows parent VM -- parent VM has no zone assignment'
        fi
      else
        printf 'Regional\tN\tN\tVM Extension -- parent VM zone unknown or VM has no zone'
      fi; return ;;

    microsoft.compute/virtualmachinescalesets)
      if   [[ "$zone_count" -ge 2 ]]; then printf 'Zone Redundant\tY\tN\tVMSS spans zones: %s' "$zone_list"
      elif [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tVMSS pinned to AZ %s' "$zone_list" "$zone_list"
      else printf 'AZ Capable - Not Configured\tY\tY\tVMSS has no zone configuration'
      fi; return ;;

    microsoft.compute/disks)
      if [[ "$sku_l" == *"_zrs"* ]]; then
        printf 'Zone Redundant\tY\tN\tZone-Redundant Storage (ZRS) managed disk'
      elif [[ "$sku_l" == "ultrassd_lrs" ]]; then
        if [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tUltra Disk pinned to AZ %s' "$zone_list" "$zone_list"
        else printf 'Zonal Capable - Not Configured\tY\tY\tUltra Disk requires explicit zone assignment'
        fi
      elif [[ "$zone_count" -eq 1 ]]; then
        printf 'Zonal - Zone %s\tY\tN\tManaged disk pinned to AZ %s' "$zone_list" "$zone_list"
      else
        printf 'AZ Capable - Not Configured\tY\tY\tUse ZRS disk SKU or zone-pin for redundancy'
      fi; return ;;

    microsoft.compute/snapshots)
      # Snapshots can be stored as ZRS (zone-redundant across zones) or LRS/regional.
      # Ref: https://learn.microsoft.com/azure/virtual-machines/disks-redundancy#zone-redundant-storage-for-managed-disks
      if [[ "$sku_l" == *"_zrs"* ]]; then
        printf 'Zone Redundant\tY\tN\tSnapshot stored with ZRS -- zone-redundant across 3 AZs'
      else
        printf 'Regional\tN\tN\tSnapshot stored with LRS -- single region, not zone-redundant'
      fi; return ;;

    microsoft.compute/images|microsoft.compute/galleries|\
    microsoft.compute/galleries/images|\
    microsoft.compute/galleries/images/versions|\
    microsoft.compute/galleries/applications|\
    microsoft.compute/galleries/applications/versions)
      printf 'Zone Redundant\tY\tN\tCompute Gallery replicates images across zones'; return ;;

    microsoft.compute/availabilitysets)
      printf 'Regional\tN\tN\tAvailability Sets provide rack-level redundancy only -- migrate to AZs'; return ;;

    microsoft.compute/dedicatedhosts|microsoft.compute/dedicatedhostgroups)
      if [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tDedicated Host pinned to AZ %s' "$zone_list" "$zone_list"
      else printf 'Zonal Capable - Not Configured\tY\tY\tDedicated Host should specify a zone'
      fi; return ;;

    microsoft.compute/capacityreservationgroups|\
    microsoft.compute/capacityreservations)
      if [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tCapacity Reservation pinned to AZ %s' "$zone_list" "$zone_list"
      else printf 'AZ Capable - Not Configured\tY\tY\tCapacity Reservation supports zone pinning'
      fi; return ;;

    microsoft.compute/proximityplacementgroups)
      printf 'Regional\tN\tN\tProximity Placement Groups are regional only'; return ;;

    microsoft.batch/*) printf 'Zone Redundant\tY\tN\tBatch is automatically zone-redundant in AZ regions'; return ;;

    microsoft.servicefabric/clusters|microsoft.servicefabric/managedclusters)
      if   [[ "$zone_count" -ge 2 ]]; then printf 'Zone Redundant\tY\tN\tService Fabric cluster spans zones: %s' "$zone_list"
      elif [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tService Fabric cluster pinned to AZ' "$zone_list"
      else printf 'AZ Capable - Not Configured\tY\tY\tService Fabric supports cross-zone node types'
      fi; return ;;

    microsoft.avs/*|microsoft.vmware/*)
      if   [[ "$zone_count" -ge 2 ]]; then printf 'Zone Redundant\tY\tN\tAzure VMware Solution spans zones: %s' "$zone_list"
      elif [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tAVS pinned to AZ %s' "$zone_list" "$zone_list"
      else printf 'Zonal Capable - Not Configured\tY\tY\tAVS supports zonal deployment at create time'
      fi; return ;;

    microsoft.desktopvirtualization/*)
      printf 'Regional\tN\tN\tAVD control plane is regional; session hosts follow VM AZ config'; return ;;

    microsoft.appplatform/*)
      printf 'Zone Redundant\tY\tN\tAzure Spring Apps is zone-redundant in AZ-enabled regions'; return ;;

    microsoft.hanaonazure/*)
      printf 'Regional\tN\tN\tSAP HANA Large Instances -- dedicated hardware, regional'; return ;;
  esac

  # ===========================================================================
  # NETWORKING
  # ===========================================================================
  case "$type" in
    microsoft.network/publicipaddresses)
      if   [[ "$zone_count" -ge 2 ]]; then printf 'Zone Redundant\tY\tN\tPublic IP zone-redundant (zones: %s)' "$zone_list"
      elif [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tPublic IP pinned to AZ %s' "$zone_list" "$zone_list"
      elif [[ "$sku_l" == "standard" ]]; then printf 'AZ Capable - Not Configured\tY\tY\tStandard SKU Public IP -- assign zones for ZR'
      else printf 'Regional\tN\tN\tBasic SKU Public IP -- no AZ support (deprecated SKU)'
      fi; return ;;

    microsoft.network/publicipprefixes)
      if   [[ "$zone_count" -ge 2 ]]; then printf 'Zone Redundant\tY\tN\tPublic IP Prefix zone-redundant (zones: %s)' "$zone_list"
      elif [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tPublic IP Prefix zonal' "$zone_list"
      else printf 'AZ Capable - Not Configured\tY\tY\tPublic IP Prefix -- assign zones for redundancy'
      fi; return ;;

    microsoft.network/loadbalancers)
      # Zone info lives on the frontend IP config, not the LB resource itself.
      # lb_fe_zones is propLBFEZones from Resource Graph (frontendIPConfigurations[0].zones).
      local fe_zone_count=0
      if [[ -n "$lb_fe_zones" && "$lb_fe_zones" != "null" && "$lb_fe_zones" != "[]" && "$lb_fe_zones" != '""' ]]; then
        fe_zone_count=$(echo "$lb_fe_zones" | jq 'if type=="array" then length else (. | split(",") | length) end' 2>/dev/null || echo 0)
      fi
      if [[ "$sku_l" == "basic" ]]; then
        printf 'Regional\tN\tN\tBasic Load Balancer -- no AZ support (migrate to Standard)'
      elif [[ "$zone_count" -ge 2 ]]; then
        printf 'Zone Redundant\tY\tN\tStandard LB zone-redundant (zones: %s)' "$zone_list"
      elif [[ "$zone_count" -eq 1 ]]; then
        printf 'Zonal - Zone %s\tY\tN\tStandard LB pinned to zone %s' "$zone_list" "$zone_list"
      elif [[ "$fe_zone_count" -ge 3 ]]; then
        printf 'Zone Redundant\tY\tN\tStandard LB -- frontend IP is zone-redundant (all zones)'
      elif [[ "$fe_zone_count" -eq 2 ]]; then
        printf 'Zone Redundant\tY\tN\tStandard LB -- frontend IP spans %s zones' "$fe_zone_count"
      elif [[ "$fe_zone_count" -eq 1 ]]; then
        printf 'AZ Capable - Not Configured\tY\tY\tStandard LB -- frontend IP pinned to single zone (not zone-redundant)'
      else
        printf 'AZ Capable - Not Configured\tY\tY\tStandard LB -- configure frontend IP zone assignment'
      fi; return ;;

    microsoft.network/applicationgateways)
      if   [[ "$zone_count" -ge 2 ]]; then printf 'Zone Redundant\tY\tN\tApp Gateway v2 zone-redundant (zones: %s)' "$zone_list"
      elif [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tApp Gateway v2 pinned to zone %s' "$zone_list" "$zone_list"
      elif [[ "$sku_l" == *"v2"* || "$tier_l" == *"v2"* ]]; then printf 'AZ Capable - Not Configured\tY\tY\tApp Gateway v2 -- assign zones for ZR'
      else printf 'Regional\tN\tN\tApp Gateway v1 -- upgrade to v2 for AZ support'
      fi; return ;;

    microsoft.network/azurefirewalls)
      if   [[ "$zone_count" -ge 2 ]]; then printf 'Zone Redundant\tY\tN\tAzure Firewall zone-redundant (zones: %s)' "$zone_list"
      elif [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tAzure Firewall pinned to AZ %s' "$zone_list" "$zone_list"
      else printf 'AZ Capable - Not Configured\tY\tY\tAzure Firewall deployed without zones -- resiliency gap'
      fi; return ;;

    microsoft.network/firewallpolicies)
      printf 'Zone Redundant\tY\tN\tFirewall Policy is zone-redundant automatically'; return ;;

    microsoft.network/virtualnetworkgateways)
      # VNet Gateways store SKU under properties.sku.name (not top-level sku.name).
      # Use gw_sku (propGWSku) as fallback when sku_l is empty.
      local eff_gw_sku_l="${sku_l:-${gw_sku,,}}"
      local eff_gw_sku_display="${sku_name:-$gw_sku}"
      if   [[ "$eff_gw_sku_l" == *"az"* ]]; then printf 'Zone Redundant\tY\tN\tVPN/ER Gateway using AZ SKU (%s)' "$eff_gw_sku_display"
      elif [[ "$zone_count" -ge 2 ]]; then printf 'Zone Redundant\tY\tN\tVNet Gateway spans zones: %s' "$zone_list"
      else printf 'AZ Capable - Not Configured\tY\tY\tUse AZ SKU (e.g. VpnGw1AZ / ErGw1AZ) for zone redundancy'
      fi; return ;;

    microsoft.network/expressroutegateways|\
    microsoft.network/expressrouteconnections)
      if   [[ "$sku_l" == *"az"* || "$zone_count" -ge 2 ]]; then printf 'Zone Redundant\tY\tN\tExpressRoute Gateway AZ SKU'
      elif [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tExpressRoute Gateway zonal' "$zone_list"
      else printf 'AZ Capable - Not Configured\tY\tY\tUse AZ Gateway SKU for zone redundancy'
      fi; return ;;

    microsoft.network/expressroutecircuits|\
    microsoft.network/expressrouteports)
      printf 'Regional\tN\tN\tExpressRoute circuit/port is regional'; return ;;

    microsoft.network/bastionhosts)
      if   [[ "$zone_count" -ge 2 ]]; then printf 'Zone Redundant\tY\tN\tAzure Bastion zone-redundant (zones: %s)' "$zone_list"
      elif [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tAzure Bastion pinned to AZ %s' "$zone_list" "$zone_list"
      else printf 'Zone Redundant\tY\tN\tAzure Bastion is automatically zone-redundant in AZ regions'
      fi; return ;;

    microsoft.network/natgateways)
      if [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tNAT Gateway pinned to AZ %s' "$zone_list" "$zone_list"
      else printf 'Zonal Capable - Not Configured\tY\tY\tNAT Gateway must be assigned to a specific zone'
      fi; return ;;

    microsoft.network/virtualnetworks|\
    microsoft.network/virtualnetworks/subnets)
      printf 'Zone Redundant\tY\tN\tVirtual Networks are automatically zone-redundant'; return ;;

    microsoft.network/routeservers|microsoft.network/virtualrouters)
      printf 'Zone Redundant\tY\tN\tRoute Server is automatically zone-redundant'; return ;;

    microsoft.network/networkwatchers)
      # Network Watcher is a regional control-plane tool (auto-created per region/subscription).
      # It does not have an independent zone-redundancy configuration.
      # Ref: https://learn.microsoft.com/azure/network-watcher/network-watcher-overview
      printf 'Regional\tN\tN\tNetwork Watcher -- regional control-plane tool, no AZ configuration'; return ;;

    microsoft.network/networkwatchers/flowlogs|\
    microsoft.network/networkwatchers/*)
      # Flow logs are regional child resources of Network Watcher.
      # Zone redundancy of the stored data depends on the configured storage account, not the flow log resource itself.
      printf 'Regional\tN\tN\tNetwork Watcher flow log -- regional resource; storage ZR depends on target storage account'; return ;;

    microsoft.network/ddosprotectionplans)
      printf 'Zone Redundant\tY\tN\tDDoS Protection Standard is automatically zone-redundant'; return ;;

    microsoft.network/dnsresolvers|\
    microsoft.network/dnsresolvers/inboundendpoints|\
    microsoft.network/dnsresolvers/outboundendpoints|\
    microsoft.network/dnsforwardingrulesets|\
    microsoft.network/dnsforwardingrulesets/forwardingrules|\
    microsoft.network/dnsforwardingrulesets/virtualnetworklinks|\
    microsoft.network/dnszones|\
    microsoft.network/privatednszones)
      # DNS Private Resolver (and its forwarding rulesets) is zone-redundant in AZ-enabled regions.
      # Ref: https://learn.microsoft.com/azure/dns/dns-private-resolver-reliability
      printf 'Zone Redundant\tY\tN\tDNS Private Resolver / Forwarding Ruleset is zone-redundant in AZ-enabled regions'; return ;;

    microsoft.network/privatelinkservices|\
    microsoft.network/privateendpoints)
      printf 'Zone Redundant\tY\tN\tPrivate Link / Endpoint is automatically zone-redundant'; return ;;

    microsoft.network/virtualwans|microsoft.network/virtualhubs|\
    microsoft.network/vpngateways|microsoft.network/p2svpngateways|\
    microsoft.network/hubroutetables|microsoft.network/vpnsites|\
    microsoft.network/vpnserverconfigurations)
      printf 'Zone Redundant\tY\tN\tVirtual WAN infrastructure is zone-redundant in AZ regions'; return ;;

    microsoft.network/trafficmanagerprofiles)
      printf 'Non-Regional\tN\tN\tTraffic Manager is a globally distributed non-regional service'; return ;;

    microsoft.network/frontdoors|\
    microsoft.network/frontdoorwebapplicationfirewallpolicies|\
    microsoft.frontdoor/*)
      printf 'Non-Regional\tN\tN\tAzure Front Door is a globally distributed service'; return ;;

    microsoft.cdn/*)
      printf 'Non-Regional\tN\tN\tAzure CDN is a globally distributed service'; return ;;

    microsoft.network/networksecuritygroups|\
    microsoft.network/networksecuritygroups/securityrules|\
    microsoft.network/routetables|\
    microsoft.network/localnetworkgateways|\
    microsoft.network/connections|\
    microsoft.network/ipgroups|\
    microsoft.network/applicationsecuritygroups|\
    microsoft.network/servicetags)
      printf 'Regional\tN\tN\tNetwork control plane resource -- no direct AZ assignment'; return ;;

    microsoft.network/networkinterfaces)
      # NICs do not have their own zone assignment — they follow the attached VM.
      # parent_info = "vm:zones=["1"]"  or empty if unattached
      if [[ "$parent_info" == vm:zones=* ]]; then
        local nic_vm_zones
        nic_vm_zones=$(echo "$parent_info" | sed 's/vm:zones=//')
        local nic_vm_zc
        nic_vm_zc=$(echo "$nic_vm_zones" | jq 'length' 2>/dev/null || echo 0)
        local nic_vm_zl
        nic_vm_zl=$(echo "$nic_vm_zones" | jq -r 'join(", ")' 2>/dev/null || echo "")
        if   [[ "$nic_vm_zc" -eq 1 ]]; then printf 'Zonal - Zone %s (Inherited)\tY\tN\tNIC follows attached VM in Zone %s' "$nic_vm_zl" "$nic_vm_zl"
        elif [[ "$nic_vm_zc" -ge 2 ]]; then printf 'Zone Redundant (Inherited)\tY\tN\tNIC follows attached VM spanning zones %s' "$nic_vm_zl"
        else printf 'Regional\tN\tN\tNIC attached to non-zonal VM'
        fi
      else
        printf 'Regional\tN\tN\tNIC not attached to a VM (unassigned or PaaS-managed)'
      fi; return ;;

    microsoft.peering/*)
      printf 'Regional\tN\tN\tAzure Peering Service -- regional resource'; return ;;

    microsoft.hybridnetwork/*|microsoft.mobilenetwork/*)
      printf 'Regional\tN\tN\tNetwork Function Manager / Private 5G -- regional'; return ;;
  esac

  # ===========================================================================
  # STORAGE
  # ===========================================================================
  case "$type" in
    microsoft.storage/storageaccounts)
      case "$sku_l" in
        *"_zrs")    printf 'Zone Redundant\tY\tN\tZone-Redundant Storage (ZRS)' ;;
        *"_gzrs")   printf 'Zone Redundant + Geo\tY\tN\tGeo-Zone-Redundant Storage (GZRS)' ;;
        *"_ragzrs") printf 'Zone Redundant + Geo\tY\tN\tRead-Access Geo-Zone-Redundant Storage (RA-GZRS)' ;;
        *"_grs")    printf 'Regional (Geo-Redundant)\tN\tY\tGRS -- geo-redundant but NOT zone-redundant; consider GZRS' ;;
        *"_ragrs")  printf 'Regional (Geo-Redundant)\tN\tY\tRA-GRS -- read-access geo-redundant; consider RA-GZRS' ;;
        *"_lrs")    printf 'AZ Capable - Not Configured\tY\tY\tLRS -- no zone redundancy; upgrade to ZRS for AZ protection' ;;
        *)          printf 'AZ Capable - Not Configured\tY\tY\tStorage account SKU unknown -- verify redundancy' ;;
      esac; return ;;

    microsoft.netapp/netappaccounts|\
    microsoft.netapp/netappaccounts/capacitypools|\
    microsoft.netapp/netappaccounts/capacitypools/volumes)
      if [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tNetApp Files volume/pool pinned to AZ %s' "$zone_list" "$zone_list"
      else printf 'Zonal Capable - Not Configured\tY\tY\tNetApp Files supports zonal volume placement'
      fi; return ;;

    microsoft.storagecache/caches)
      if [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tHPC Cache pinned to AZ %s' "$zone_list" "$zone_list"
      else printf 'Zonal Capable - Not Configured\tY\tY\tHPC Cache supports zonal deployment'
      fi; return ;;

    microsoft.elasticsan/*|microsoft.storagesync/*|\
    microsoft.hybriddata/*|microsoft.storsimple/*|\
    microsoft.importexport/*)
      printf 'Regional\tN\tN\tStorage service -- regional only'; return ;;
  esac

  # ===========================================================================
  # DATABASE
  # ===========================================================================
  case "$type" in
    microsoft.sql/servers/databases|\
    microsoft.sql/servers/elasticpools)
      if   [[ "$pzr_l" == "true" ]];  then printf 'Zone Redundant\tY\tN\tzoneRedundant=true -- SQL DB/Pool is zone-redundant'
      elif [[ "$pzr_l" == "false" ]]; then
        case "$sku_l" in
          *"businesscritical"*|*"bc_"*|*"premium"*|"p"[0-9]*)
            printf 'AZ Capable - Not Configured\tY\tY\tPremium/Business Critical SQL DB -- enable zoneRedundant' ;;
          *"hyperscale"*|*"hs_"*)
            printf 'Zonal Capable - Not Configured\tY\tY\tHyperscale SQL DB supports zonal replica deployment' ;;
          *)
            printf 'Regional\tN\tN\tSQL DB tier (Basic/Standard/GP) -- check if AZ supported in region' ;;
        esac
      else printf 'AZ Capable - Not Configured\tY\tY\tSQL DB -- verify zoneRedundant property'
      fi; return ;;

    microsoft.sql/managedinstances)
      if   [[ "$pzr_l" == "true" ]];  then printf 'Zone Redundant\tY\tN\tzoneRedundant=true -- SQL MI is zone-redundant'
      elif [[ "$pzr_l" == "false" ]]; then printf 'AZ Capable - Not Configured\tY\tY\tzoneRedundant=false -- enable for SQL MI zone redundancy'
      else printf 'AZ Capable - Not Configured\tY\tY\tSQL Managed Instance supports zone redundancy -- verify config'
      fi; return ;;

    microsoft.sql/servers)
      printf 'Regional\tN\tN\tSQL Server logical server -- AZ configured at database/pool level'; return ;;

    microsoft.documentdb/*)
      if [[ "$cosmos_zr" == "1" ]]; then printf 'Zone Redundant\tY\tN\tCosmos DB -- isZoneRedundant=true on one or more locations'
      else printf 'AZ Capable - Not Configured\tY\tY\tCosmos DB -- enable zone redundancy on each location'
      fi; return ;;

    microsoft.dbforpostgresql/*)
      case "$pha_l" in
        "zoneredundant"|"zone_redundant"|"zone-redundant")
          printf 'Zone Redundant\tY\tN\tPostgreSQL Flexible Server with Zone-Redundant HA' ;;
        "samezone"|"same_zone"|"same-zone")
          printf 'Zonal - Same Zone HA\tY\tN\tPostgreSQL Flexible Server with Same-Zone HA' ;;
        *)
          printf 'AZ Capable - Not Configured\tY\tY\tPostgreSQL Flexible Server -- enable Zone-Redundant HA mode' ;;
      esac; return ;;

    microsoft.dbformysql/*)
      case "$pha_l" in
        "zoneredundant"|"zone_redundant"|"zone-redundant")
          printf 'Zone Redundant\tY\tN\tMySQL Flexible Server with Zone-Redundant HA' ;;
        "samezone"|"same_zone"|"same-zone")
          printf 'Zonal - Same Zone HA\tY\tN\tMySQL Flexible Server with Same-Zone HA' ;;
        *)
          printf 'AZ Capable - Not Configured\tY\tY\tMySQL Flexible Server -- enable Zone-Redundant HA mode' ;;
      esac; return ;;

    microsoft.dbformariadb/*)
      printf 'Regional\tN\tN\tMariaDB -- no AZ support (service is deprecated)'; return ;;

    microsoft.cache/*)
      if   [[ "$zone_count" -ge 2 ]]; then printf 'Zone Redundant\tY\tN\tRedis cache zone-redundant (zones: %s)' "$zone_list"
      elif [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tRedis cache pinned to AZ %s' "$zone_list" "$zone_list"
      elif [[ "$pzr_l" == "true" ]];  then printf 'Zone Redundant\tY\tN\tzoneRedundant=true on Redis'
      else
        case "$sku_l" in
          *"premium"*|*"enterprise"*)
            printf 'AZ Capable - Not Configured\tY\tY\tPremium/Enterprise Redis supports AZ -- not configured' ;;
          *)
            printf 'Regional\tN\tN\tBasic/Standard Redis Cache -- no AZ support' ;;
        esac
      fi; return ;;

    microsoft.cassandra/*)
      if [[ "$zone_count" -ge 2 ]]; then printf 'Zone Redundant\tY\tN\tManaged Apache Cassandra zone-redundant (zones: %s)' "$zone_list"
      else printf 'AZ Capable - Not Configured\tY\tY\tManaged Cassandra supports zone redundancy -- configure zone placement'
      fi; return ;;

    microsoft.sqlvirtualmachine/*)
      printf 'Zone Redundant\tY\tN\tSQL on VM -- AZ determined by underlying VM zone configuration'; return ;;

    microsoft.azuredata/*)
      printf 'Regional\tN\tN\tAzure Arc SQL -- hosted on Arc-enabled infrastructure'; return ;;
  esac

  # ===========================================================================
  # APP SERVICES
  # ===========================================================================
  case "$type" in
    microsoft.web/serverfarms)
      if [[ "$pzr_l" == "true" ]]; then
        printf 'Zone Redundant\tY\tN\tApp Service Plan zoneRedundant=true'
      else
        case "$sku_l" in
          *"p0v3"*|*"p1v3"*|*"p2v3"*|*"p3v3"*|*"p1mv3"*|*"p2mv3"*|*"p3mv3"*|*"p4mv3"*|*"p5mv3"*|\
          *"premiumv3"*|*"pv3"*|\
          *"i1v2"*|*"i2v2"*|*"i3v2"*|*"i4v2"*|*"i5v2"*|*"i6v2"*|*"isolatedv2"*)
            printf 'AZ Capable - Not Configured\tY\tY\tPremiumV3 or IsolatedV2 App Service Plan -- set zoneRedundant=true' ;;
          *"consumption"*|*"dynamic"*|*"y1"*|"f1"|*"free"*|"d1"|*"shared"*|\
          "b1"|"b2"|"b3"|*"basic"*|"s1"|"s2"|"s3"|*"standard"*)
            printf 'Regional\tN\tN\tApp Service Plan SKU (%s) does not support zone redundancy' "$sku_name" ;;
          *)
            printf 'AZ Capable - Not Configured\tY\tY\tCheck if App Service Plan tier supports zone redundancy' ;;
        esac
      fi; return ;;

    microsoft.web/sites|microsoft.web/sites/slots)
      # Availability is driven by the linked App Service Plan.
      # parent_info = "asp:zr=true/false:sku=<sku>"
      local asp_zr_val asp_sku_val
      asp_zr_val=$(echo "$parent_info" | sed 's/.*zr=\([^:]*\).*/\1/')
      asp_sku_val=$(echo "$parent_info" | sed 's/.*sku=\(.*\)/\1/')
      if [[ "$asp_zr_val" == "true" ]]; then
        printf 'Zone Redundant (Inherited)\tY\tN\tApp/Function App -- linked App Service Plan is zone-redundant'
      else
        case "$asp_sku_val" in
          *p0v3*|*p1v3*|*p2v3*|*p3v3*|*p1mv3*|*p2mv3*|*p3mv3*|*p4mv3*|*p5mv3*|*premiumv3*|*pv3*|          *i1v2*|*i2v2*|*i3v2*|*i4v2*|*i5v2*|*i6v2*|*isolatedv2*)
            printf 'AZ Capable - Not Configured\tY\tY\tApp/Function App -- linked ASP (%s) supports ZR but zoneRedundant=false' "$asp_sku_val" ;;
          *consumption*|*dynamic*|*y1*|f1|*free*|d1|*shared*|b1|b2|b3|*basic*|s1|s2|s3|*standard*)
            printf 'Regional\tN\tN\tApp/Function App -- linked ASP (%s) does not support zone redundancy' "$asp_sku_val" ;;
          "")
            printf 'Zone Redundant (Inherited)\tY\tN\tApp/Function App -- ASP link not resolved (assume inherited)' ;;
          *)
            printf 'AZ Capable - Not Configured\tY\tY\tApp/Function App -- check if linked ASP (%s) supports zone redundancy' "$asp_sku_val" ;;
        esac
      fi; return ;;

    microsoft.web/hostingenvironments)
      if   [[ "$pzr_l" == "true" ]];  then printf 'Zone Redundant\tY\tN\tApp Service Environment v3 zoneRedundant=true'
      elif [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tASE (ILB) pinned to AZ %s' "$zone_list" "$zone_list"
      else printf 'AZ Capable - Not Configured\tY\tY\tASEv3 supports zone redundancy -- enable at creation'
      fi; return ;;

    microsoft.web/staticsites)
      printf 'Zone Redundant\tY\tN\tStatic Web Apps are globally distributed and zone-redundant'; return ;;

    microsoft.web/*|microsoft.certificateregistration/*|microsoft.domainregistration/*)
      printf 'Regional\tN\tN\tApp Service ancillary resource -- regional'; return ;;
  esac

  # ===========================================================================
  # CONTAINERS
  # ===========================================================================
  case "$type" in
    microsoft.containerservice/managedclusters)
      if [[ -n "$aks_zones" && "$aks_zones" != "[]" && "$aks_zones" != "null" ]]; then
        printf 'Zone Redundant\tY\tN\tAKS node pools configured with availability zones: %s' "$aks_zones"
      else
        printf 'AZ Capable - Not Configured\tY\tY\tAKS cluster has no zone configuration on node pools'
      fi; return ;;

    microsoft.containerregistry/registries)
      if   [[ "$pzred_l" == "enabled" ]]; then printf 'Zone Redundant\tY\tN\tContainer Registry zoneRedundancy=Enabled'
      else
        case "$sku_l" in
          *"premium"*) printf 'AZ Capable - Not Configured\tY\tY\tPremium ACR -- enable zoneRedundancy property' ;;
          *)           printf 'Regional\tN\tN\tBasic/Standard ACR -- upgrade to Premium for zone redundancy' ;;
        esac
      fi; return ;;

    microsoft.containerinstance/containergroups)
      if [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tContainer Instance pinned to AZ %s' "$zone_list" "$zone_list"
      else printf 'Zonal Capable - Not Configured\tY\tY\tContainer Instances support zonal deployment'
      fi; return ;;

    microsoft.app/*)
      printf 'Zone Redundant\tY\tN\tContainer Apps are automatically zone-redundant in AZ-enabled regions'; return ;;

    microsoft.redhatopenshift/openshiftclusters)
      if   [[ "$zone_count" -ge 2 ]]; then printf 'Zone Redundant\tY\tN\tARO cluster zone-redundant (zones: %s)' "$zone_list"
      elif [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tARO cluster pinned to AZ %s' "$zone_list" "$zone_list"
      else printf 'AZ Capable - Not Configured\tY\tY\tARO supports zone-spanning worker nodes -- configure during deploy'
      fi; return ;;
  esac

  # ===========================================================================
  # SECURITY
  # ===========================================================================
  case "$type" in
    microsoft.keyvault/*)
      printf 'Zone Redundant\tY\tN\tKey Vault is automatically zone-redundant in AZ-enabled regions'; return ;;

    microsoft.hardwaresecuritymodules/dedicatedhsms)
      if   [[ "$zone_count" -ge 2 ]]; then printf 'Zone Redundant\tY\tN\tDedicated HSM zone-redundant'
      elif [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tDedicated HSM pinned to AZ %s' "$zone_list" "$zone_list"
      else printf 'AZ Capable - Not Configured\tY\tY\tDedicated HSM supports zone pinning'
      fi; return ;;

    microsoft.dataprotection/*)
      printf 'Zone Redundant\tY\tN\tData Protection Backup Vault is zone-redundant in AZ regions'; return ;;

    microsoft.security/*|microsoft.securityinsights/*|microsoft.windowsdefenderatp/*|\
    microsoft.attestation/*|microsoft.customerlockbox/*|microsoft.windowsesu/*)
      printf 'Regional\tN\tN\tSecurity / compliance resource -- regional'; return ;;
  esac

  # ===========================================================================
  # ANALYTICS
  # ===========================================================================
  case "$type" in
    microsoft.datafactory/*)   printf 'Zone Redundant\tY\tN\tData Factory is automatically zone-redundant in AZ regions'; return ;;
    microsoft.databricks/*)    printf 'Zone Redundant\tY\tN\tDatabricks is automatically zone-redundant in AZ regions'; return ;;

    microsoft.kusto/*)
      if   [[ "$zone_count" -ge 2 ]]; then printf 'Zone Redundant\tY\tN\tData Explorer cluster zone-redundant (zones: %s)' "$zone_list"
      elif [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tData Explorer cluster pinned to AZ %s' "$zone_list" "$zone_list"
      else printf 'AZ Capable - Not Configured\tY\tY\tData Explorer supports zone redundancy -- configure at cluster create'
      fi; return ;;

    microsoft.hdinsight/*)
      if [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tHDInsight cluster pinned to AZ %s' "$zone_list" "$zone_list"
      else printf 'Zonal Capable - Not Configured\tY\tY\tHDInsight supports zonal deployment (configure at create time)'
      fi; return ;;

    microsoft.synapse/*)       printf 'Zone Redundant\tY\tN\tAzure Synapse Analytics is zone-redundant'; return ;;
    microsoft.streamanalytics/*) printf 'Zone Redundant\tY\tN\tStream Analytics is automatically zone-redundant'; return ;;
    microsoft.purview/*)       printf 'Zone Redundant\tY\tN\tMicrosoft Purview is zone-redundant in AZ-enabled regions'; return ;;
    microsoft.analysisservices/*) printf 'Regional\tN\tN\tAnalysis Services -- no AZ support'; return ;;
    microsoft.powerbi/*|microsoft.powerbidedicated/*) printf 'Zone Redundant\tY\tN\tPower BI / Embedded leverages zone-redundant infrastructure'; return ;;
    microsoft.fabric/*)        printf 'Zone Redundant\tY\tN\tMicrosoft Fabric is zone-redundant'; return ;;
    microsoft.datalakeanalytics/*|microsoft.datashare/*|microsoft.datacatalog/*|microsoft.projectbabylon/*)
      printf 'Regional\tN\tN\tAnalytics resource -- regional only'; return ;;
  esac

  # ===========================================================================
  # INTEGRATION / MESSAGING
  # ===========================================================================
  case "$type" in
    microsoft.eventhub/*)
      if   [[ "$pzr_l" == "true" ]];  then printf 'Zone Redundant\tY\tN\tEvent Hubs Namespace zoneRedundant=true'
      elif [[ "$pzr_l" == "false" ]]; then
        case "$sku_l" in
          *"premium"*|*"dedicated"*) printf 'AZ Capable - Not Configured\tY\tY\tEvent Hubs Premium/Dedicated -- enable zone redundancy' ;;
          *)                         printf 'Regional\tN\tN\tEvent Hubs Basic/Standard -- upgrade tier for AZ support' ;;
        esac
      else
        case "$sku_l" in
          *"premium"*|*"dedicated"*) printf 'AZ Capable - Not Configured\tY\tY\tEvent Hubs Premium/Dedicated -- verify zone redundancy' ;;
          *)                         printf 'Regional\tN\tN\tEvent Hubs Basic/Standard -- upgrade tier for AZ support' ;;
        esac
      fi; return ;;

    microsoft.servicebus/*)
      if   [[ "$pzr_l" == "true" ]]; then printf 'Zone Redundant\tY\tN\tService Bus Namespace zoneRedundant=true'
      elif [[ "$pzr_l" == "false" ]]; then
        [[ "$sku_l" == *"premium"* ]] \
          && printf 'AZ Capable - Not Configured\tY\tY\tService Bus Premium -- enable zone redundancy' \
          || printf 'Regional\tN\tN\tBasic/Standard Service Bus -- no AZ support'
      else
        [[ "$sku_l" == *"premium"* ]] \
          && printf 'Zone Redundant\tY\tN\tService Bus Premium is automatically zone-redundant in AZ regions' \
          || printf 'Regional\tN\tN\tBasic/Standard Service Bus -- no AZ support'
      fi; return ;;

    microsoft.eventgrid/*)     printf 'Zone Redundant\tY\tN\tEvent Grid is automatically zone-redundant in AZ regions'; return ;;
    microsoft.notificationhubs/*) printf 'Zone Redundant\tY\tN\tNotification Hubs is automatically zone-redundant'; return ;;
    microsoft.relay/*)         printf 'Regional\tN\tN\tAzure Relay -- regional service'; return ;;

    microsoft.apimanagement/*)
      if   [[ "$zone_count" -ge 2 ]]; then printf 'Zone Redundant\tY\tN\tAPI Management zone-redundant (zones: %s)' "$zone_list"
      elif [[ "$zone_count" -eq 1 ]]; then printf 'Zonal - Zone %s\tY\tN\tAPI Management pinned to AZ %s' "$zone_list" "$zone_list"
      else
        [[ "$sku_l" == *"premium"* ]] \
          && printf 'AZ Capable - Not Configured\tY\tY\tAPIM Premium -- assign zones for zone redundancy' \
          || printf 'Regional\tN\tN\tAPI Management non-Premium SKU -- no AZ support'
      fi; return ;;

    microsoft.logic/*)         printf 'Zone Redundant\tY\tN\tLogic Apps (Standard) is automatically zone-redundant'; return ;;
    microsoft.communication/*) printf 'Regional\tN\tN\tAzure Communication Services -- regional'; return ;;
    microsoft.healthcareapis/*) printf 'Regional\tN\tN\tHealthcare APIs / FHIR -- regional'; return ;;
    microsoft.powerplatform/*) printf 'Regional\tN\tN\tPower Platform resource -- regional'; return ;;
  esac

  # ===========================================================================
  # MONITORING
  # ===========================================================================
  case "$type" in
    microsoft.insights/components)
      # Workspace-based App Insights inherits zone redundancy from its Log Analytics workspace.
      # Classic (non-workspace) mode is regional.
      if [[ "$parent_info" == "workspace:classic" ]]; then
        printf 'Regional\tN\tN\tApplication Insights (classic mode) -- no Log Analytics workspace, regional only'
      else
        printf 'Zone Redundant (Inherited)\tY\tN\tApplication Insights -- workspace-based, inherits zone redundancy from linked Log Analytics workspace'
      fi; return ;;
    # microsoft.insights/* sub-type breakdown
    # Ref: https://learn.microsoft.com/azure/reliability/reliability-monitoring-alerts
    microsoft.insights/privatelinkscopes)
      # Azure Monitor Private Link Scope (AMPLS) is a genuinely global resource —
      # it defines connectivity scope across regions and has no regional placement.
      # Ref: https://learn.microsoft.com/azure/azure-monitor/logs/private-link-security
      printf 'Non-Regional\tN\tN\tAzure Monitor Private Link Scope -- global resource'; return ;;

    microsoft.insights/actiongroups)
      # Action Groups are regional; zone-redundant in regions that support AZs.
      # Ref: https://learn.microsoft.com/azure/azure-monitor/alerts/action-groups#reliability
      printf 'Zone Redundant\tY\tN\tAction Group -- zone-redundant in AZ-enabled regions'; return ;;
    microsoft.insights/metricalerts|    microsoft.insights/scheduledqueryrules|    microsoft.insights/activitylogalerts|    microsoft.insights/webtests)
      # Alert rules are stored regionally; not themselves zone-redundant resources
      # (availability depends on Azure Monitor platform, not the rule resource itself).
      # Ref: https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-overview
      printf 'Regional\tN\tN\tMonitor alert rule -- regional resource, availability backed by Azure Monitor platform'; return ;;
    microsoft.insights/autoscalesettings)
      # Autoscale settings are regional control-plane resources.
      printf 'Regional\tN\tN\tAutoscale setting -- regional control-plane resource'; return ;;
    microsoft.insights/workbooks|    microsoft.insights/workbooktemplates)
      printf 'Regional\tN\tN\tAzure Monitor Workbook -- regional resource'; return ;;
    microsoft.insights/datacollectionrules|    microsoft.insights/datacollectionendpoints)
      # DCRs/DCEs are regional; zone redundancy not applicable.
      printf 'Regional\tN\tN\tData Collection Rule/Endpoint -- regional resource'; return ;;
    microsoft.insights/*)
      printf 'Regional\tN\tN\tAzure Monitor resource -- regional (check specific type for ZR support)'; return ;;
    microsoft.operationalinsights/*) printf 'Zone Redundant\tY\tN\tLog Analytics Workspace is zone-redundant in AZ-enabled regions'; return ;;
    microsoft.monitor/*)             printf 'Zone Redundant\tY\tN\tAzure Monitor is zone-redundant in AZ-enabled regions'; return ;;
    microsoft.dashboard/*)           printf 'Zone Redundant\tY\tN\tManaged Grafana is automatically zone-redundant'; return ;;
    microsoft.alertsmanagement/*|microsoft.operationsmanagement/*|\
    microsoft.workloadmonitor/*|microsoft.changeanalysis/*)
      printf 'Regional\tN\tN\tMonitoring ancillary / metadata resource'; return ;;
  esac

  # ===========================================================================
  # AI & ML
  # ===========================================================================
  case "$type" in
    microsoft.cognitiveservices/*)       printf 'Zone Redundant\tY\tN\tAzure AI Services is zone-redundant in AZ-enabled regions'; return ;;
    microsoft.machinelearningservices/*) printf 'Zone Redundant\tY\tN\tAzure Machine Learning is zone-redundant in supported regions'; return ;;
    microsoft.search/*)                  printf 'Zone Redundant\tY\tN\tAzure AI Search is zone-redundant (Standard and above in AZ regions)'; return ;;
    microsoft.botservice/*|microsoft.autonomoussystems/*|microsoft.enterpriseknowledgegraph/*)
      printf 'Regional\tN\tN\tAI service -- regional'; return ;;
  esac

  # ===========================================================================
  # IoT
  # ===========================================================================
  case "$type" in
    microsoft.devices/*)        printf 'Zone Redundant\tY\tN\tIoT Hub is zone-redundant in AZ-enabled regions'; return ;;
    microsoft.iotcentral/*|microsoft.digitaltwins/*|microsoft.iotspaces/*|\
    microsoft.iotoperations/*|microsoft.deviceregistry/*|microsoft.deviceupdate/*|\
    microsoft.windowsiot/*)
      printf 'Regional\tN\tN\tIoT service -- regional resource'; return ;;
  esac

  # ===========================================================================
  # BCDR
  # ===========================================================================
  case "$type" in
    microsoft.recoveryservices/*) printf 'Zone Redundant\tY\tN\tRecovery Services Vault is zone-redundant in AZ regions'; return ;;
    microsoft.dataprotection/*)   printf 'Zone Redundant\tY\tN\tBackup Vault is zone-redundant in AZ regions'; return ;;
  esac

  # ===========================================================================
  # IDENTITY
  # ===========================================================================
  case "$type" in
    microsoft.aad/*)                  printf 'Zone Redundant\tY\tN\tEntra Domain Services is zone-redundant in AZ-enabled regions'; return ;;
    microsoft.azureactivedirectory/*|microsoft.adhybridhealthservice/*)
      printf 'Non-Regional\tN\tN\tEntra ID / B2C -- globally distributed service'; return ;;
    microsoft.managedidentity/*)      printf 'Regional\tN\tN\tManaged Identity -- regional resource'; return ;;
  esac

  # ===========================================================================
  # MANAGEMENT & AUTOMATION
  # ===========================================================================
  case "$type" in
    microsoft.automation/*)    printf 'Zone Redundant\tY\tN\tAutomation Account is zone-redundant in AZ-enabled regions'; return ;;
    microsoft.blueprint/*|microsoft.management/*|microsoft.authorization/*|microsoft.resources/*)
      printf 'Non-Regional\tN\tN\tGovernance / ARM management resource -- global scope'; return ;;
    microsoft.policy/*|microsoft.policyinsights/*|microsoft.guestconfiguration/*)
      printf 'Non-Regional\tN\tN\tAzure Policy resource -- global scope'; return ;;
    microsoft.costmanagement/*|microsoft.consumption/*|microsoft.billing/*|microsoft.costmanagementexports/*)
      printf 'Non-Regional\tN\tN\tCost Management resource -- global / non-regional'; return ;;
    microsoft.resourcegraph/*|microsoft.resourcehealth/*|microsoft.portal/*|microsoft.features/*)
      printf 'Non-Regional\tN\tN\tARM platform resource -- global / non-regional'; return ;;
    microsoft.solutions/*|microsoft.customproviders/*)
      printf 'Regional\tN\tN\tManaged Application / Custom Provider -- regional'; return ;;
    microsoft.managedservices/*)
      printf 'Non-Regional\tN\tN\tAzure Lighthouse -- global scope'; return ;;
  esac

  # ===========================================================================
  # REAL-TIME / SIGNALR / HYBRID / MIGRATION / DEV TOOLS / OTHER KNOWN
  # ===========================================================================
  case "$type" in
    microsoft.signalrservice/*|microsoft.webpubsub/*)
      printf 'Zone Redundant\tY\tN\tSignalR / Web PubSub is zone-redundant in AZ regions'; return ;;

    microsoft.hybridcompute/*|microsoft.kubernetes/*|microsoft.kubernetesconfiguration/*|\
    microsoft.azurearcdata/*|microsoft.azurestackhci/*|microsoft.azurestack/*|microsoft.edge/*)
      printf 'Regional\tN\tN\tAzure Arc / Hybrid resource -- runs on-premises or at edge'; return ;;

    microsoft.databox/*|microsoft.databoxedge/*|microsoft.datamigration/*|\
    microsoft.offazure/*|microsoft.migrate/*)
      printf 'Regional\tN\tN\tMigration service resource -- regional'; return ;;

    microsoft.appconfiguration/*)
      printf 'Zone Redundant\tY\tN\tApp Configuration is zone-redundant in AZ-enabled regions'; return ;;

    microsoft.devcenter/*|microsoft.labservices/*|microsoft.devtestlabs/*|\
    microsoft.loadtestservice/*|microsoft.devspaces/*|microsoft.notebooks/*)
      printf 'Regional\tN\tN\tDeveloper tooling resource -- regional'; return ;;

    microsoft.visualstudio/*|microsoft.devops/*|microsoft.vsonline/*|\
    microsoft.devopsinfrastructure/*)
      printf 'Regional\tN\tN\tDevOps / developer resource -- regional'; return ;;

    microsoft.maps/*|microsoft.bingmaps/*)
      printf 'Regional\tN\tN\tMaps resource -- regional'; return ;;

    microsoft.media/*|microsoft.videoindexer/*)
      printf 'Regional\tN\tN\tMedia Services -- regional'; return ;;

    microsoft.blockchain/*|microsoft.blockchaintokens/*)
      printf 'Regional\tN\tN\tBlockchain resource -- regional'; return ;;

    microsoft.marketplace/*|microsoft.marketplaceapps/*|microsoft.marketplaceordering/*)
      printf 'Non-Regional\tN\tN\tMarketplace resource -- global'; return ;;
  esac

  # ===========================================================================
  # FALLBACK: resource type is NOT mapped in this script.
  #
  # The resource is written to the CSV with UNCLASSIFIED in the Availability
  # Configuration column and "?" in AZ Capable / Resiliency Gap so it clearly
  # stands out.  After all normal rows the CSV includes a summary section with
  # all unique unclassified types with a ready-to-paste case snippet per row.
  # ===========================================================================
  if   [[ "$zone_count" -ge 2 ]]; then
    printf 'UNCLASSIFIED (zones hint: Zone Redundant)\t?\t?\tNot mapped in script. zones[] field suggests ZR (%s). Add case for: %s' "$zone_list" "$type"
  elif [[ "$zone_count" -eq 1 ]]; then
    printf 'UNCLASSIFIED (zones hint: Zonal Zone %s)\t?\t?\tNot mapped in script. zones[] field suggests Zonal. Add case for: %s' "$zone_list" "$type"
  else
    printf 'UNCLASSIFIED (no zone data)\t?\t?\tNot mapped in script. No zone info available. Add case for: %s' "$type"
  fi
}

# -- Step 4: Write CSV ---------------------------------------------------------
log_step "Generating CSV output"

echo "Subscription,Subscription ID,Resource Group,Resource Name,Resource ID,Resource Type,Provider Namespace,Group Type,Service Category,SKU Name,SKU Tier,Location,Tags,Availability Configuration,Zones (raw),AZ Capable (Y/N),Resiliency Gap (Y/N),Notes" > "$OUTPUT_FILE"

AKS_MAP=$(cat          "$WORK_DIR/aks_map.json")
COSMOS_MAP=$(cat       "$WORK_DIR/cosmos_map.json")
WEBAPP_ASP_MAP=$(cat   "$WORK_DIR/webapp_asp_map.json")
APPINS_WS_MAP=$(cat    "$WORK_DIR/appinsights_ws_map.json")
NIC_VM_MAP=$(cat       "$WORK_DIR/nic_vm_map.json")
VMEXT_VM_MAP=$(cat    "$WORK_DIR/vmext_vm_map.json")
ASP_INFO_MAP=$(cat     "$WORK_DIR/asp_info_map.json")
WS_INFO_MAP=$(cat      "$WORK_DIR/workspace_info_map.json")
VM_ZONE_MAP=$(cat      "$WORK_DIR/vm_zone_map.json")

# Track UNCLASSIFIED types: associative arrays keyed by exact type string
declare -A UC_COUNT    # how many instances found
declare -A UC_HINT     # first AVAIL string (contains zones hint)
declare -A UC_EX_RG    # example resource group
declare -A UC_EX_NAME  # example resource name
declare -A UC_EX_SKU   # example SKU name (helps determine correct classification)
declare -A UC_EX_LOC   # example Azure region

COUNT=0; ERRORS=0

while IFS= read -r resource; do
  COUNT=$((COUNT + 1))

  ID=$(echo       "$resource" | jq -r '.id               // ""')
  NAME=$(echo     "$resource" | jq -r '.name             // ""')
  RG=$(echo       "$resource" | jq -r '.resourceGroup    // ""')
  TYPE=$(echo     "$resource" | jq -r '.type             // ""')
  LOCATION=$(echo "$resource" | jq -r '.location         // ""')
  TAGS=$(echo     "$resource" | jq -c '(.tags // {}) | with_entries(.value |= (tostring | gsub("^\\s+|\\s+$"; "")))')
  ZONES=$(echo    "$resource" | jq -c '.zonesArr         // []')
  SKU_N=$(echo    "$resource" | jq -r '.skuName          // ""')
  SKU_T=$(echo    "$resource" | jq -r '.skuTier          // ""')
  EXT_L=$(echo    "$resource" | jq -r '.extLoc           // ""')
  PZR=$(echo      "$resource" | jq -r '.propZR           // ""')
  PZRED=$(echo    "$resource" | jq -r '.propZRed         // ""')
  PHA=$(echo      "$resource" | jq -r '.propHAMode       // ""')
  PRED=$(echo     "$resource" | jq -r '.propRedund       // ""')
  PLB_FE_ZONES=$(echo "$resource" | jq -r '.propLBFEZones // ""')
  PGW_SKU=$(echo      "$resource" | jq -r '.propGWSku     // ""')

  TYPE_L="${TYPE,,}"
  NS=$(cut -d'/' -f1 <<< "$TYPE_L")

  AKS_Z=$(echo "$AKS_MAP"    | jq -r --arg id "${ID,,}" '.[$id] // ""' 2>/dev/null || echo "")
  COSM=$(echo  "$COSMOS_MAP" | jq -r --arg id "${ID,,}" '.[$id] // "0"' 2>/dev/null || echo "0")

  # -- Parent-resource lookup (Web Apps, App Insights, NICs) -------------------
  PARENT_INFO=""
  ID_L="${ID,,}"
  case "$TYPE_L" in
    microsoft.web/sites|microsoft.web/sites/slots)
      ASP_ID=$(echo "$WEBAPP_ASP_MAP" | jq -r --arg id "$ID_L" '.[$id] // ""' 2>/dev/null || echo "")
      if [[ -n "$ASP_ID" ]]; then
        ASP_ZR=$(echo  "$ASP_INFO_MAP" | jq -r --arg id "$ASP_ID" '.[$id].zr  // false' 2>/dev/null || echo "false")
        ASP_SKU=$(echo "$ASP_INFO_MAP" | jq -r --arg id "$ASP_ID" '.[$id].sku // ""'    2>/dev/null || echo "")
        PARENT_INFO="asp:zr=${ASP_ZR}:sku=${ASP_SKU}"
      fi ;;
    microsoft.insights/components)
      WS_ID=$(echo "$APPINS_WS_MAP" | jq -r --arg id "$ID_L" '.[$id] // ""' 2>/dev/null || echo "")
      if [[ -n "$WS_ID" && "$WS_ID" != "null" ]]; then
        PARENT_INFO="workspace:linked"
      else
        PARENT_INFO="workspace:classic"
      fi ;;
    microsoft.network/networkinterfaces)
      VM_ID=$(echo "$NIC_VM_MAP" | jq -r --arg id "$ID_L" '.[$id] // ""' 2>/dev/null || echo "")
      if [[ -n "$VM_ID" && "$VM_ID" != "null" ]]; then
        VM_ZONES=$(echo "$VM_ZONE_MAP" | jq -c --arg id "$VM_ID" '.[$id] // []' 2>/dev/null || echo "[]")
        PARENT_INFO="vm:zones=${VM_ZONES}"
      fi ;;
    microsoft.compute/virtualmachines/extensions)
      VMEXT_PARENT=$(echo "$VMEXT_VM_MAP" | jq -r --arg id "$ID_L" '.[$id] // ""' 2>/dev/null || echo "")
      if [[ -n "$VMEXT_PARENT" && "$VMEXT_PARENT" != "null" ]]; then
        VM_ZONES=$(echo "$VM_ZONE_MAP" | jq -c --arg id "$VMEXT_PARENT" '.[$id] // []' 2>/dev/null || echo "[]")
        PARENT_INFO="vm:zones=${VM_ZONES}"
      fi ;;
  esac

  GROUP=$(get_group_type "$TYPE_L")
  SCAT=$(get_service_category "$TYPE_L")

  RAW=$(get_availability \
    "$TYPE_L" "$ZONES" "$LOCATION" "$SKU_N" "$SKU_T" \
    "$PZR" "$PZRED" "$PHA" "$EXT_L" "$PRED" "$AKS_Z" "$COSM" "$PLB_FE_ZONES" "$PGW_SKU" "$PARENT_INFO")

  AVAIL=$(printf '%s' "$RAW" | cut -f1)
  AZCAP=$(printf '%s' "$RAW" | cut -f2)
  RGAP=$(printf  '%s' "$RAW" | cut -f3)
  NOTES=$(printf '%s' "$RAW" | cut -f4-)

  # ---- Track UNCLASSIFIED types for post-processing -------------------------
  # Track UNCLASSIFIED types — one entry per unique resource type
  if [[ "$AVAIL" == UNCLASSIFIED* ]]; then
    UC_COUNT["$TYPE"]=$(( ${UC_COUNT["$TYPE"]:-0} + 1 ))
    # Store first-seen example per type (helps you identify what to classify)
    if [[ -z "${UC_HINT[$TYPE]:-}" ]]; then
      UC_HINT["$TYPE"]="$AVAIL"
      UC_EX_RG["$TYPE"]="$RG"
      UC_EX_NAME["$TYPE"]="$NAME"
      UC_EX_SKU["$TYPE"]="${SKU_N:-n/a}"
      UC_EX_LOC["$TYPE"]="$LOCATION"
    fi
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(csv_field "$SUBSCRIPTION_NAME")" \
    "$(csv_field "$SUBSCRIPTION_ID")" \
    "$(csv_field "$RG")" \
    "$(csv_field "$NAME")" \
    "$(csv_field "$ID")" \
    "$(csv_field "$TYPE")" \
    "$(csv_field "$NS")" \
    "$(csv_field "$GROUP")" \
    "$(csv_field "$SCAT")" \
    "$(csv_field "$SKU_N")" \
    "$(csv_field "$SKU_T")" \
    "$(csv_field "$LOCATION")" \
    "$(csv_field "$TAGS")" \
    "$(csv_field "$AVAIL")" \
    "$(csv_field "$ZONES")" \
    "$(csv_field "$AZCAP")" \
    "$(csv_field "$RGAP")" \
    "$(csv_field "$NOTES")" \
    >> "$OUTPUT_FILE" || { ERRORS=$((ERRORS + 1)); }

  [[ $((COUNT % 100)) -eq 0 ]] && log_info "  Processed ${COUNT} / ${TOTAL} resources..."

done < <(jq -c '.[]' "$WORK_DIR/all_resources.json")

# -- Step 5: Append UNCLASSIFIED summary section to the SAME CSV file -----------
UNCLASSIFIED_TYPES=("${!UC_COUNT[@]}")

if [[ "${#UNCLASSIFIED_TYPES[@]}" -gt 0 ]]; then
  log_step "Appending UNCLASSIFIED section to CSV  (${#UNCLASSIFIED_TYPES[@]} unique types)"

  SORTED_UC=$(
    for k in "${!UC_COUNT[@]}"; do printf '%d\t%s\n' "${UC_COUNT[$k]}" "$k"; done \
    | sort -t$'\t' -k1 -rn
  )

  {
    printf '\n'
    printf '"=== UNCLASSIFIED RESOURCE TYPES ==="\n'
    printf '"Types below exist in this subscription but are NOT mapped in azure_inventory.sh."\n'
    printf '"For each: look it up at https://learn.microsoft.com/azure/reliability/availability-zones-service-support"\n'
    printf '"then copy the Snippet column into get_availability() (before the UNCLASSIFIED fallback) and re-run."\n'
    printf '\n'
    printf 'Resource Type,Instance Count,Zones Hint,Example Resource Group,Example Resource Name,Example SKU,Example Location,,,,,,,,,,Bash Snippet\n'
  } >> "$OUTPUT_FILE"

  while IFS=$'\t' read -r CNT TYPE_KEY; do
    [[ -z "$TYPE_KEY" ]] && continue
    HINT_LABEL="${UC_HINT[$TYPE_KEY]}"
    EX_RG="${UC_EX_RG[$TYPE_KEY]:-}"
    EX_NM="${UC_EX_NAME[$TYPE_KEY]:-}"
    EX_SK="${UC_EX_SKU[$TYPE_KEY]:-n/a}"
    EX_LC="${UC_EX_LOC[$TYPE_KEY]:-unknown}"
    TL="${TYPE_KEY,,}"
    SNIPPET="    ${TL}) printf 'Regional\tN\tN\tTODO: classify'; return ;;"

    printf '%s,%s,%s,%s,%s,%s,%s,,,,,,,,,,,%s\n' \
      "$(csv_field "$TYPE_KEY")" \
      "$(csv_field "$CNT")" \
      "$(csv_field "$HINT_LABEL")" \
      "$(csv_field "$EX_RG")" \
      "$(csv_field "$EX_NM")" \
      "$(csv_field "$EX_SK")" \
      "$(csv_field "$EX_LC")" \
      "$(csv_field "$SNIPPET")" \
      >> "$OUTPUT_FILE"
  done <<< "$SORTED_UC"


else
  log_ok "No UNCLASSIFIED entries — all resource types are mapped in the script."
fi

# -- Step 7: Summary Report ----------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}==========================================================${RESET}"
echo -e "${BOLD}  Azure Resource Inventory -- Complete${RESET}"
echo -e "${BOLD}${GREEN}==========================================================${RESET}"
log_ok "Output CSV    : ${BOLD}${OUTPUT_FILE}${RESET}"
log_ok "Total rows    : ${BOLD}${COUNT}${RESET}   |   Errors: ${ERRORS}"
echo ""

echo -e "${BOLD}-- Availability Configuration Breakdown --------------------${RESET}"
tail -n +2 "$OUTPUT_FILE" \
  | awk -F'","' '{
      gsub(/^"|"$/, "", $14)
      if ($14 != "" && $14 !~ /^===/ && $14 !~ /^Resource Type/) count[$14]++
    }
    END { for (k in count) printf "  %-58s %d\n", k, count[k] }' \
  | sort -t' ' -k2 -rn
echo ""

GAP_COUNT=$(tail -n +2 "$OUTPUT_FILE" \
  | awk -F'","' '{gsub(/^"|"$/, "", $17); if ($17=="Y") c++} END{print c+0}')
echo -e "${BOLD}-- Resiliency Gaps (AZ capable but NOT configured) ---------${RESET}"
echo -e "  ${RED}${BOLD}${GAP_COUNT} resources${RESET} have a resiliency gap."
echo ""

echo -e "${BOLD}-- Top Resiliency Gaps by Resource Type --------------------${RESET}"
tail -n +2 "$OUTPUT_FILE" \
  | awk -F'","' '{
      gsub(/^"|"$/, "", $6); gsub(/^"|"$/, "", $17)
      if ($17 == "Y") count[$6]++
    }
    END { for (k in count) printf "  %-65s %d\n", k, count[k] }' \
  | sort -t' ' -k2 -rn | head -20
echo ""

if [[ "${#UNCLASSIFIED_TYPES[@]}" -gt 0 ]]; then
  echo -e "${BOLD}-- Unclassified Types (not yet mapped in script) -----------${RESET}"
  for TYPE_KEY in $(
    for k in "${!UC_COUNT[@]}"; do echo "${UC_COUNT[$k]} $k"; done \
    | sort -rn | awk '{$1=""; print substr($0,2)}'
  ); do
    printf "  %-65s %d instance(s)\n" "$TYPE_KEY" "${UC_COUNT[$TYPE_KEY]}"
  done
  echo ""
  echo ""
fi

echo -e "${BOLD}-- Resources by Group Type ---------------------------------${RESET}"
tail -n +2 "$OUTPUT_FILE" \
  | awk -F'","' '{ gsub(/^"|"$/, "", $8)
      if ($8 != "" && $8 !~ /^===/ && $8 != "Group Type") count[$8]++
    }
    END { for (k in count) printf "  %-55s %d\n", k, count[k] }' \
  | sort -t' ' -k2 -rn | head -30
echo ""
