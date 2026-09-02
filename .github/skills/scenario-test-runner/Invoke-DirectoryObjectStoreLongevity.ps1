#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet("AttributeCoverage", "Longevity", "ScenarioTest")]
    [string] $WorkloadMode = "AttributeCoverage",

    [ValidateSet("User-Upsert", "Group-Upsert", "User-Properties-Deletion", "Group-Properties-Deletion", "Run-All-OBScenarios")]
    [string] $ScenarioCommand = "Run-All-OBScenarios",

    [ValidateSet("Full", "MiniSet")]
    [string] $ScenarioSetMode = "Full",

    [ValidateRange(0.001, 720)]
    [double] $DurationHours = 84,

    [ValidateRange(0.01, 20)]
    [double] $OperationsPerSecond = 1,

    [ValidateRange(2, 1000)]
    [int] $InitialRecipientCount = 20,

    [ValidateRange(1, 200)]
    [int] $InitialGroupCount = 5,

    [ValidateRange(2, 1000)]
    [int] $CoverageRecipientCount = 100,

    [ValidateRange(1, 200)]
    [int] $CoverageGroupCount = 50,

    [ValidateRange(10, 5000)]
    [int] $MaximumRecipientCount = 500,

    [ValidateRange(2, 1000)]
    [int] $MaximumGroupCount = 100,

    [ValidateRange(5, 86400)]
    [int] $ConvergenceDelaySeconds = 300,

    [ValidateRange(30, 86400)]
    [int] $ValidationTimeoutSeconds = 1800,

    [ValidateRange(5, 600)]
    [int] $CompareCookieReadTimeoutSeconds = 30,

    [ValidateRange(5, 600)]
    [int] $ScenarioTargetQueryTimeoutSeconds = 60,

    [ValidateRange(1, 1000)]
    [int] $ValidationBatchSize = 50,

    [ValidateRange(1, 3600)]
    [int] $CheckpointIntervalSeconds = 30,

    [ValidateRange(1, 100000)]
    [int] $RandomSeed = 1729,

    [ValidatePattern('^[A-Za-z0-9-]{3,32}$')]
    [string] $ObjectPrefix = "DOSLongevity",

    [string] $Organization,

    [ValidateSet("A", "B")]
    [string] $Side = "A",

    [ValidateSet("Test", "TDF", "Canary", "CanaryInt")]
    [string] $ObjectStoreDestination = "Test",

    [string] $OutputRoot,

    [string] $CompareSetupScript = "Q:\src\Substrate\sources\test\data\src\DirectoryObjectStore\TestInstruction\CompareAndRepairSetup.ps1",

    [string] $ScenarioRuntimeDependencyRoot,

    [string] $ResumeRunDirectory,

    [string] $PopulationSourceRunDirectory,

    [switch] $ConfigureEnvironment,

    [switch] $CleanupOnSuccess,

    [switch] $SkipDeletionOperations,

    [switch] $PreflightOnly,

    [switch] $ForceFullPreflightOnResume,

    [switch] $WhatIfTraffic
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($PreflightOnly -and $WorkloadMode -ne "ScenarioTest")
{
    throw "-PreflightOnly is supported only with -WorkloadMode ScenarioTest."
}
if ($WorkloadMode -ne "ScenarioTest" -and $PSBoundParameters.ContainsKey("ScenarioCommand"))
{
    throw "-ScenarioCommand is supported only with -WorkloadMode ScenarioTest."
}
if ($WorkloadMode -ne "ScenarioTest" -and $PSBoundParameters.ContainsKey("ScenarioSetMode"))
{
    throw "-ScenarioSetMode is supported only with -WorkloadMode ScenarioTest."
}
if ($WorkloadMode -ne "ScenarioTest" -and $PSBoundParameters.ContainsKey("PopulationSourceRunDirectory"))
{
    throw "-PopulationSourceRunDirectory is supported only with -WorkloadMode ScenarioTest."
}
if ($CleanupOnSuccess -and -not [string]::IsNullOrWhiteSpace($PopulationSourceRunDirectory))
{
    throw "-CleanupOnSuccess cannot be used when reusing a shared ScenarioTest population."
}

if ([string]::IsNullOrWhiteSpace($OutputRoot))
{
    $OutputRoot = Join-Path $PSScriptRoot "Runs"
}

if ([string]::IsNullOrWhiteSpace($ScenarioRuntimeDependencyRoot))
{
    $ScenarioRuntimeDependencyRoot = Join-Path $PSScriptRoot "RuntimeDependencies\net472"
}
if (-not [string]::IsNullOrWhiteSpace($PopulationSourceRunDirectory))
{
    $PopulationSourceRunDirectory =
        (Resolve-Path -LiteralPath $PopulationSourceRunDirectory -ErrorAction Stop).Path
}

$script:RunId = $null
$script:RunDirectory = $null
$script:OperationLogPath = $null
$script:ReadableOperationLogPath = $null
$script:ValidationLogPath = $null
$script:EventLogPath = $null
$script:ScenarioDetailLogPath = $null
$script:ScenarioDetailLogIndex = 0
$script:CheckpointPath = $null
$script:StatusPath = $null
$script:PausedMarkerPath = $null
$script:StopRequested = $false
$script:Failure = $null
$script:Random = [Random]::new($RandomSeed)
$script:Contacts = @{}
$script:Groups = @{}
$script:PendingValidations = @{}
$script:Counters = [ordered]@{
    OperationsAttempted = 0L
    OperationsSucceeded = 0L
    OperationsFailed = 0L
    Reads = 0L
    Writes = 0L
    ValidationsPassed = 0L
    ValidationsDeferred = 0L
    ValidationsFailed = 0L
    ScenarioLdapRequests = 0L
    ScenarioObjectLevelLdapRequests = 0L
    ScenarioBaselineSeeds = 0L
    ScenarioSelectedAttributeSlots = 0L
    ScenarioBatchesCompleted = 0L
}
$script:LastCheckpointUtc = [datetime]::MinValue
$script:ForestFqdn = $null
$script:ScenarioCookieQueryContextReady = $false
$script:TenantId = [Guid]::Empty
$script:BasicDataType = $null
$script:MailboxDatabaseLinkValue = $null
$script:GroupOwnerIdentity = $null
$script:ScenarioCounts = $null
$script:ScenarioSchema = @{}
$script:ScenarioTargets = @{}
$script:ScenarioSupportingObjects = [Collections.Generic.List[object]]::new()
$script:ScenarioBatchSummaries = [Collections.Generic.List[object]]::new()
$script:ScenarioPhaseSummaries = [Collections.Generic.List[object]]::new()
$script:ScenarioLogSegments = [ordered]@{
    OperationsJson = [Collections.Generic.List[string]]::new()
    OperationsReadable = [Collections.Generic.List[string]]::new()
    ValidationsJson = [Collections.Generic.List[string]]::new()
    EventsJson = [Collections.Generic.List[string]]::new()
    ScenarioDetails = [Collections.Generic.List[string]]::new()
}
$script:ScenarioLogNextIndex = @{}
$script:ScenarioTotalObjectWork = 0L
$script:ScenarioCompletedObjectWork = 0L
$script:ScenarioPlanVersion = 6
$script:ScenarioSharedPopulationVersion = 3
$script:LegacyCommandSpecificPopulation = $false
$script:ScenarioBatchesPerPhase = if ($ScenarioSetMode -eq "MiniSet") { 1 } else { 4 }
$script:ScenarioPreflightEstimatedMinutes = 10
$script:ScenarioPopulationEstimatedMinutes =
    if ([string]::IsNullOrWhiteSpace($PopulationSourceRunDirectory)) { 15 } else { 0 }
$script:PopulationReused = $false
$script:ResolvedPopulationSourceRunDirectory = $null
$script:PopulationImportCompleted = $false
$script:ScenarioPopulationIdentitiesValidated = $false
$script:PopulationGeneration = 0
$script:DataInconsistentPopulation = @{}
$script:PendingPopulationReplacement = $null
$script:PopulationReplacementHistory = [Collections.Generic.List[object]]::new()
$script:RetiredPopulationDistinguishedNames =
    [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:ScenarioBatchFailures = [Collections.Generic.List[object]]::new()
$script:ScenarioState = [ordered]@{
    NextPhaseIndex = 0
    NextBatchIndex = 0
    CurrentBatch = $null
    CurrentBatchCompletedGuids = @()
}

$script:UserRecipientPropertiesForUpsert = @(
    'adminDisplayName'
    'altRecipient'
    'authOrig'
    'c'
    'co'
    'company'
    'CountryCode'
    'delivContLength'
    'deliverAndRedirect'
    'department'
    'description'
    'displayName'
    'displayNamePrintable'
    'dLMemRejectPerms'
    'dLMemSubmitPerms'
    'extensionAttribute1'
    'extensionAttribute10'
    'extensionAttribute11'
    'extensionAttribute12'
    'extensionAttribute13'
    'extensionAttribute14'
    'extensionAttribute15'
    'extensionAttribute2'
    'extensionAttribute3'
    'extensionAttribute4'
    'extensionAttribute5'
    'extensionAttribute6'
    'extensionAttribute7'
    'extensionAttribute8'
    'extensionAttribute9'
    'facsimileTelephoneNumber'
    'garbageCollPeriod'
    'givenName'
    'heuristics'
    'homeMTA'
    'homePhone'
    'info'
    'initials'
    'internetEncoding'
    'l'
    'legacyExchangeDN'
    'mail'
    'mailNickname'
    'manager'
    'mAPIRecipient'
    'mobile'
    'msDS-GeoCoordinatesAltitude'
    'msDS-GeoCoordinatesLatitude'
    'msDS-GeoCoordinatesLongitude'
    'msDS-HABSeniorityIndex'
    'msDS-PhoneticDisplayName'
    'msExchAddressBookFlags'
    'msExchAdministrativeUnitLink'
    'msExchArbitrationMailbox'
    'msExchArchiveRelease'
    'msExchAssistantName'
    'msExchAuditAdmin'
    'msExchAuditDelegate'
    'msExchAuditDelegateAdmin'
    'msExchAuditOwner'
    'msExchAuthPolicyLink'
    'msExchBlockedSendersHash'
    'msExchBypassAudit'
    'msExchBypassModerationFromDLMembersLink'
    'msExchBypassModerationLink'
    'msExchCalculatedTargetAddress'
    'msExchCalendarRepairDisabled'
    'msExchCapabilityIdentifiers'
    'msExchConfigurationXML'
    'msExchCorrelationId'
    'msExchCU'
    'msExchDelegateIRMBlockList'
    'msExchDirsyncAuthorityMetadata'
    'msExchDirsyncID'
    'msExchELCMailboxFlags'
    'msExchEnableModeration'
    'msExchEnforcedTimestamps'
    'msExchEwsApplicationAccessPolicy'
    'msExchEwsEnabled'
    'msExchEwsExceptions'
    'msExchEwsWellKnownApplicationPolicies'
    'msExchExpansionServerName'
    'msExchExtensionAttribute16'
    'msExchExtensionAttribute17'
    'msExchExtensionAttribute18'
    'msExchExtensionAttribute40'
    'msExchExtensionAttribute41'
    'msExchExtensionAttribute45'
    'msExchExtensionCustomAttribute1'
    'msExchExtensionCustomAttribute2'
    'msExchExtensionCustomAttribute3'
    'msExchExtensionCustomAttribute4'
    'msExchExtensionCustomAttribute5'
    'msExchExternalDirectoryObjectId'
    'msExchFBURL'
    'msExchForeignGroupSid'
    'msExchGenericForwardingAddress'
    'msExchGroupExternalMemberCount'
    'msExchGroupMemberCount'
    'msExchGroupSecurityFlags'
    'msExchHideFromAddressLists'
    'msExchImmutableId'
    'msExchInformationBarrierSegmentLink'
    'msExchIntendedMailboxPlanLink'
    'msExchIsMSODirsynced'
    'msExchJoinedProxyAddress'
    'msExchLabeledURI'
    'msExchLastExchangeChangedTime'
    'msExchLitigationHoldDate'
    'msExchLitigationHoldOwner'
    'msExchLocalizationFlags'
    'msExchMailboxAuditEnable'
    'msExchMailboxAuditLastAdminAccess'
    'msExchMailboxAuditLastDelegateAccess'
    'msExchMailboxAuditLastExternalAccess'
    'msExchMailboxAuditLogAgeLimit'
    'msExchMailboxFolderSet'
    'msExchMailboxMoveBatchName'
    'msExchMailboxMoveFlags'
    'msExchMailboxMoveRemoteHostName'
    'msExchMailboxMoveSourceArchiveMDBLink'
    'msExchMailboxMoveSourceMDBLink'
    'msExchMailboxMoveStatus'
    'msExchMailboxMoveTargetArchiveMDBLink'
    'msExchMailboxMoveTargetMDBLink'
    'msExchMailboxPlanType'
    'msExchMailboxRelease'
    'msExchMailboxSecurityDescriptor'
    'nTSecurityDescriptor'
    'msExchMasterAccountSid'
    'msExchMessageHygieneFlags'
    'msExchMessageHygieneSCLDeleteThreshold'
    'msExchMessageHygieneSCLJunkThreshold'
    'msExchMessageHygieneSCLQuarantineThreshold'
    'msExchMessageHygieneSCLRejectThreshold'
    'msExchModeratedByLink'
    'msExchModerationFlags'
    'msExchMultiMailboxDatabasesLink'
    'msExchMultiMailboxGUIDs'
    'msExchMultiMailboxLocationsLink'
    'msExchNonCompliantDeviceLink'
    'msExchNonCompliantDevices'
    'msExchObjectID'
    'msExchOnPremiseObjectGuid'
    'msExchOrganizationUpgradeRequest'
    'msExchOrganizationUpgradeStatus'
    'msExchOURoot'
    'msExchOWAPolicy'
    'msExchParentPlanLink'
    'msExchPartnerGroupID'
    'msExchPoliciesExcluded'
    'msExchPoliciesIncluded'
    'msExchPreviousRecipientTypeDetails'
    'msExchProvisioningFlags'
    'msExchPublicFolderMailbox'
    'msExchRBACPolicyLink'
    'msExchRecipientDisplayType'
    'msExchRecipientSoftDeletedStatus'
    'msExchRecipientTypeDetails'
    'msExchRecipLimit'
    'msExchRemoteRecipientType'
    'msExchReplicableChangeVersion'
    'msExchRequireAuthToSendTo'
    'msExchResourceBehaviorOptions'
    'msExchResourceCapacity'
    'msExchResourceDisplay'
    'msExchResourceMetaData'
    'msExchResourceProvisioningOptions'
    'msExchResourceSearchProperties'
    'msExchRetentionComment'
    'msExchRetentionURL'
    'msExchRMSComputerAccountsLink'
    'msExchRoleGroupType'
    'msExchSafeRecipientsHash'
    'msExchSafeSendersHash'
    'msExchSenderHintTranslations'
    'msExchSharedDomainLastModified'
    'msExchSharedDomainTenant'
    'msExchSharedWithReference'
    'msExchSharedWithTargetProxyAddress'
    'msExchSharingAnonymousIdentities'
    'msExchSharingPartnerIdentities'
    'msExchSharingPolicyLink'
    'msExchSIDHistory'
    'msExchStsRefreshTokensValidFrom'
    'msExchSupervisionDLLink'
    'msExchSupervisionOneOffLink'
    'msExchSupervisionUserLink'
    'msExchSyncAccountsPolicyDN'
    'msExchTextMessagingState'
    'msExchThrottlingPolicyDN'
    'msExchTransportRecipientSettingsFlags'
    'msExchUCVoiceMailSettings'
    'msExchUMCallingLineIds'
    'msExchUMDtmfMap'
    'msExchUMListInDirectorySearch'
    'msExchUMRecipientDialPlanLink'
    'msExchUMSpokenName'
    'msExchUserAccountControl'
    'msExchUserCulture'
    'msExchUserHoldPolicies'
    'msExchVersion'
    'msExchWellKnownObject'
    'msExchWhenIBSegmentChanged'
    'msExchWhenMailboxCreated'
    'msExchWhenMailboxWorkloadsModified'
    'msExchWhenPropChangeLastSubmitted'
    'msExchWhenReplicablePropLastChanged'
    'msExchWhenSoftDeletedTime'
    'msExchWindowsLiveID'
    'otherFacsimileTelephoneNumber'
    'otherHomePhone'
    'otherTelephone'
    'pager'
    'physicalDeliveryOfficeName'
    'postalCode'
    'postOfficeBox'
    'protocolSettings'
    'proxyAddresses'
    'publicDelegates'
    'ReplicationSignature'
    'securityProtocol'
    'showInAddressBook'
    'sn'
    'st'
    'streetAddress'
    'submissionContLength'
    'targetAddress'
    'telephoneAssistant'
    'telephoneNumber'
    'textEncodedORAddress'
    'thumbnailPhoto'
    'title'
    'unauthOrig'
    'userCertificate'
    'userSMIMECertificate'
    'wWWHomePage'
)

$script:GroupRecipientPropertiesForUpsert = @(
    'adminDisplayName'
    'altRecipient'
    'AltSecurityIdentities'
    'authOrig'
    'company'
    'deletedItemFlags'
    'delivContLength'
    'deliverAndRedirect'
    'department'
    'description'
    'displayName'
    'displayNamePrintable'
    'dLMemRejectPerms'
    'dLMemSubmitPerms'
    'extensionAttribute1'
    'extensionAttribute10'
    'extensionAttribute11'
    'extensionAttribute12'
    'extensionAttribute13'
    'extensionAttribute14'
    'extensionAttribute15'
    'extensionAttribute2'
    'extensionAttribute3'
    'extensionAttribute4'
    'extensionAttribute5'
    'extensionAttribute6'
    'extensionAttribute7'
    'extensionAttribute8'
    'extensionAttribute9'
    'garbageCollPeriod'
    'groupType'
    'heuristics'
    'hideDLMembership'
    'homeMDB'
    'homeMTA'
    'info'
    'internetEncoding'
    'legacyExchangeDN'
    'mail'
    'mailNickname'
    'managedBy'
    'mAPIRecipient'
    'mDBUseDefaults'
    'msDS-GeoCoordinatesAltitude'
    'msDS-GeoCoordinatesLatitude'
    'msDS-GeoCoordinatesLongitude'
    'msDS-HABSeniorityIndex'
    'msDS-PhoneticDisplayName'
    'msExchAddressBookFlags'
    'msExchAddressBookPolicyLink'
    'msExchAdministrativeUnitLink'
    'msExchAlternateMailboxes'
    'msExchApprovalApplicationLink'
    'msExchArbitrationMailbox'
    'msExchArchiveAddress'
    'msExchArchiveDatabaseLink'
    'msExchArchiveGUID'
    'msExchArchiveName'
    'msExchArchiveQuota'
    'msExchArchiveRelease'
    'msExchArchiveStatus'
    'msExchArchiveWarnQuota'
    'msExchAssistantName'
    'msExchAuditAdmin'
    'msExchAuditDelegate'
    'msExchAuditDelegateAdmin'
    'msExchAuditOwner'
    'msExchAuthPolicyLink'
    'msExchBlockedSendersHash'
    'msExchBypassAudit'
    'msExchBypassModerationFromDLMembersLink'
    'msExchBypassModerationLink'
    'msExchCalculatedTargetAddress'
    'msExchCalendarLoggingQuota'
    'msExchCalendarRepairDisabled'
    'msExchCapabilityIdentifiers'
    'msExchCoManagedByLink'
    'msExchConfigurationXML'
    'msExchCorrelationId'
    'msExchCU'
    'msExchDataEncryptionPolicyLink'
    'msExchDelegateIRMBlockList'
    'msExchDelegateListLink'
    'msExchDirsyncAuthorityMetadata'
    'msExchDirsyncID'
    'msExchDisabledArchiveDatabaseLink'
    'msExchDisabledArchiveGUID'
    'msExchDumpsterQuota'
    'msExchDumpsterWarningQuota'
    'msExchELCExpirySuspensionEnd'
    'msExchELCExpirySuspensionStart'
    'msExchELCMailboxFlags'
    'msExchEnableModeration'
    'msExchEnforcedTimestamps'
    'msExchEwsApplicationAccessPolicy'
    'msExchEwsEnabled'
    'msExchEwsExceptions'
    'msExchEwsWellKnownApplicationPolicies'
    'msExchExpansionServerName'
    'msExchExtensionAttribute16'
    'msExchExtensionAttribute17'
    'msExchExtensionAttribute18'
    'msExchExtensionAttribute40'
    'msExchExtensionAttribute41'
    'msExchExtensionAttribute45'
    'msExchExtensionCustomAttribute1'
    'msExchExtensionCustomAttribute2'
    'msExchExtensionCustomAttribute3'
    'msExchExtensionCustomAttribute4'
    'msExchExtensionCustomAttribute5'
    'msExchExternalDirectoryObjectId'
    'msExchExternalOOFOptions'
    'msExchFBURL'
    'msExchForeignGroupSid'
    'msExchGenericForwardingAddress'
    'msExchGroupDepartRestriction'
    'msExchGroupExternalMemberCount'
    'msExchGroupJoinRestriction'
    'msExchGroupMemberCount'
    'msExchGroupSecurityFlags'
    'msExchHideFromAddressLists'
    'msExchHomeServerName'
    'msExchImmutableId'
    'msExchInformationBarrierSegmentLink'
    'msExchIntendedMailboxPlanLink'
    'msExchIsMSODirsynced'
    'msExchJoinedProxyAddress'
    'msExchLabeledURI'
    'msExchLastExchangeChangedTime'
    'msExchLitigationHoldDate'
    'msExchLitigationHoldOwner'
    'msExchLocalizationFlags'
    'msExchMailboxAuditEnable'
    'msExchMailboxAuditLastAdminAccess'
    'msExchMailboxAuditLastDelegateAccess'
    'msExchMailboxAuditLastExternalAccess'
    'msExchMailboxAuditLogAgeLimit'
    'msExchMailboxContainerGuid'
    'msExchMailboxFolderSet'
    'msExchMailboxGuid'
    'msExchMailboxMoveBatchName'
    'msExchMailboxMoveFlags'
    'msExchMailboxMoveRemoteHostName'
    'msExchMailboxMoveSourceArchiveMDBLink'
    'msExchMailboxMoveSourceMDBLink'
    'msExchMailboxMoveStatus'
    'msExchMailboxMoveTargetArchiveMDBLink'
    'msExchMailboxMoveTargetMDBLink'
    'msExchMailboxPlanType'
    'msExchMailboxRelease'
    'msExchMailboxSecurityDescriptor'
    'nTSecurityDescriptor'
    'msExchMailboxTemplateLink'
    'msExchMasterAccountSid'
    'msExchMaxBlockedSenders'
    'msExchMaxSafeSenders'
    'msExchMDBRulesQuota'
    'msExchMessageHygieneFlags'
    'msExchMessageHygieneSCLDeleteThreshold'
    'msExchMessageHygieneSCLJunkThreshold'
    'msExchMessageHygieneSCLQuarantineThreshold'
    'msExchMessageHygieneSCLRejectThreshold'
    'msExchMobileAllowedDeviceIds'
    'msExchMobileBlockedDeviceIds'
    'msExchMobileMailboxFlags'
    'msExchMobileMailboxPolicyLink'
    'msExchModeratedByLink'
    'msExchModerationFlags'
    'msExchMultiMailboxDatabasesLink'
    'msExchMultiMailboxGUIDs'
    'msExchMultiMailboxLocationsLink'
    'msExchNonCompliantDeviceLink'
    'msExchNonCompliantDevices'
    'msExchObjectID'
    'msExchOnPremiseObjectGuid'
    'msExchOrganizationUpgradeRequest'
    'msExchOrganizationUpgradeStatus'
    'msExchOURoot'
    'msExchOWAPolicy'
    'msExchParentPlanLink'
    'msExchPartnerGroupID'
    'msExchPoliciesExcluded'
    'msExchPoliciesIncluded'
    'msExchPreviousHomeMDB'
    'msExchPreviousMailboxGuid'
    'msExchPreviousRecipientTypeDetails'
    'msExchProvisioningFlags'
    'msExchPublicFolderMailbox'
    'msExchRBACPolicyLink'
    'msExchRecipientDisplayType'
    'msExchRecipientSoftDeletedStatus'
    'msExchRecipientTypeDetails'
    'msExchRecipLimit'
    'msExchRemoteRecipientType'
    'msExchReplicableChangeVersion'
    'msExchRequireAuthToSendTo'
    'msExchResourceBehaviorOptions'
    'msExchResourceCapacity'
    'msExchResourceDisplay'
    'msExchResourceMetaData'
    'msExchResourceProvisioningOptions'
    'msExchResourceSearchProperties'
    'msExchRetentionComment'
    'msExchRetentionURL'
    'msExchRMSComputerAccountsLink'
    'msExchRoleGroupType'
    'msExchSafeRecipientsHash'
    'msExchSafeSendersHash'
    'msExchSenderHintTranslations'
    'msExchSharedDomainLastModified'
    'msExchSharedDomainTenant'
    'msExchSharedWithReference'
    'msExchSharedWithTargetProxyAddress'
    'msExchSharingAnonymousIdentities'
    'msExchSharingPartnerIdentities'
    'msExchSharingPolicyLink'
    'msExchSIDHistory'
    'msExchStsRefreshTokensValidFrom'
    'msExchSupervisionDLLink'
    'msExchSupervisionOneOffLink'
    'msExchSupervisionUserLink'
    'msExchSyncAccountsPolicyDN'
    'msExchTeamMailboxExpiration'
    'msExchTeamMailboxOwners'
    'msExchTeamMailboxSharePointUrl'
    'msExchTextMessagingState'
    'msExchThrottlingPolicyDN'
    'msExchTransportRecipientSettingsFlags'
    'msExchUCVoiceMailSettings'
    'msExchUMCallingLineIds'
    'msExchUMDtmfMap'
    'msExchUMListInDirectorySearch'
    'msExchUMRecipientDialPlanLink'
    'msExchUMSpokenName'
    'msExchUMTemplateLink'
    'msExchUnifiedMailbox'
    'msExchUseOAB'
    'msExchUserAccountControl'
    'msExchUserCulture'
    'msExchUserHoldPolicies'
    'msExchVersion'
    'msExchWellKnownObject'
    'msExchWhenIBSegmentChanged'
    'msExchWhenMailboxCreated'
    'msExchWhenMailboxWorkloadsModified'
    'msExchWhenPropChangeLastSubmitted'
    'msExchWhenReplicablePropLastChanged'
    'msExchWhenSoftDeletedTime'
    'msExchWindowsLiveID'
    'msOrg-IsOrganizational'
    'oOFReplyToOriginator'
    'protocolSettings'
    'proxyAddresses'
    'publicDelegates'
    'ReplicationSignature'
    'reportToOriginator'
    'reportToOwner'
    'SamAccountName'
    'securityProtocol'
    'showInAddressBook'
    'submissionContLength'
    'targetAddress'
    'telephoneNumber'
    'textEncodedORAddress'
    'thumbnailPhoto'
    'unauthOrig'
    'userCertificate'
    'userSMIMECertificate'
    'wWWHomePage'
)

$script:UserLinkPropertiesForUpsert = @(
    'altRecipient'
    'authOrig'
    'dLMemRejectPerms'
    'dLMemSubmitPerms'
    'mailNickname'
    'manager'
    'msExchAdministrativeUnitLink'
    'msExchArbitrationMailbox'
    'msExchAuthPolicyLink'
    'msExchBypassModerationFromDLMembersLink'
    'msExchBypassModerationLink'
    'msExchInformationBarrierSegmentLink'
    'msExchIntendedMailboxPlanLink'
    'msExchModeratedByLink'
    'msExchNonCompliantDeviceLink'
    'msExchOWAPolicy'
    'msExchParentPlanLink'
    'msExchPublicFolderMailbox'
    'msExchRBACPolicyLink'
    'msExchRecipientSoftDeletedStatus'
    'msExchRecipientTypeDetails'
    'msExchRMSComputerAccountsLink'
    'msExchSharingPolicyLink'
    'msExchSIDHistory'
    'msExchSupervisionDLLink'
    'msExchSupervisionOneOffLink'
    'msExchSupervisionUserLink'
    'msExchSyncAccountsPolicyDN'
    'msExchThrottlingPolicyDN'
    'msExchUMRecipientDialPlanLink'
    'publicDelegates'
    'showInAddressBook'
    'unauthOrig'
)

$script:GroupLinkPropertiesForUpsert = @(
    'altRecipient'
    'authOrig'
    'dLMemRejectPerms'
    'dLMemSubmitPerms'
    'groupType'
    'mailNickname'
    'managedBy'
    'member'
    'msExchAddressBookPolicyLink'
    'msExchAdministrativeUnitLink'
    'msExchApprovalApplicationLink'
    'msExchArbitrationMailbox'
    'msExchAuthPolicyLink'
    'msExchBypassModerationFromDLMembersLink'
    'msExchBypassModerationLink'
    'msExchCoManagedByLink'
    'msExchDataEncryptionPolicyLink'
    'msExchDelegateListLink'
    'msExchHomeServerName'
    'msExchInformationBarrierSegmentLink'
    'msExchIntendedMailboxPlanLink'
    'msExchMailboxTemplateLink'
    'msExchMobileMailboxPolicyLink'
    'msExchModeratedByLink'
    'msExchNonCompliantDeviceLink'
    'msExchOWAPolicy'
    'msExchParentPlanLink'
    'msExchPublicFolderMailbox'
    'msExchRBACPolicyLink'
    'msExchRecipientSoftDeletedStatus'
    'msExchRecipientTypeDetails'
    'msExchRMSComputerAccountsLink'
    'msExchSharingPolicyLink'
    'msExchSIDHistory'
    'msExchSupervisionDLLink'
    'msExchSupervisionOneOffLink'
    'msExchSupervisionUserLink'
    'msExchSyncAccountsPolicyDN'
    'msExchTeamMailboxOwners'
    'msExchThrottlingPolicyDN'
    'msExchUMRecipientDialPlanLink'
    'msExchUMTemplateLink'
    'msExchUseOAB'
    'publicDelegates'
    'showInAddressBook'
    'unauthOrig'
)

$script:UserRecipientPropertiesForDeletion = @(
    'adminDisplayName'
    'altRecipient'
    'authOrig'
    'c'
    'co'
    'company'
    'CountryCode'
    'delivContLength'
    'deliverAndRedirect'
    'department'
    'description'
    'displayName'
    'displayNamePrintable'
    'dLMemRejectPerms'
    'dLMemSubmitPerms'
    'extensionAttribute1'
    'extensionAttribute10'
    'extensionAttribute11'
    'extensionAttribute12'
    'extensionAttribute13'
    'extensionAttribute14'
    'extensionAttribute15'
    'extensionAttribute2'
    'extensionAttribute3'
    'extensionAttribute4'
    'extensionAttribute5'
    'extensionAttribute6'
    'extensionAttribute7'
    'extensionAttribute8'
    'extensionAttribute9'
    'facsimileTelephoneNumber'
    'garbageCollPeriod'
    'givenName'
    'heuristics'
    'homeMTA'
    'homePhone'
    'info'
    'initials'
    'internetEncoding'
    'l'
    'legacyExchangeDN'
    'mail'
    'mailNickname'
    'manager'
    'mAPIRecipient'
    'mobile'
    'msDS-GeoCoordinatesAltitude'
    'msDS-GeoCoordinatesLatitude'
    'msDS-GeoCoordinatesLongitude'
    'msDS-HABSeniorityIndex'
    'msDS-PhoneticDisplayName'
    'msExchAddressBookFlags'
    'msExchAdministrativeUnitLink'
    'msExchArbitrationMailbox'
    'msExchArchiveRelease'
    'msExchAssistantName'
    'msExchAuditAdmin'
    'msExchAuditDelegate'
    'msExchAuditDelegateAdmin'
    'msExchAuditOwner'
    'msExchAuthPolicyLink'
    'msExchBlockedSendersHash'
    'msExchBypassAudit'
    'msExchBypassModerationFromDLMembersLink'
    'msExchBypassModerationLink'
    'msExchCalculatedTargetAddress'
    'msExchCalendarRepairDisabled'
    'msExchCapabilityIdentifiers'
    'msExchConfigurationXML'
    'msExchCorrelationId'
    'msExchCU'
    'msExchDelegateIRMBlockList'
    'msExchDirsyncAuthorityMetadata'
    'msExchDirsyncID'
    'msExchELCMailboxFlags'
    'msExchEnableModeration'
    'msExchEnforcedTimestamps'
    'msExchEwsApplicationAccessPolicy'
    'msExchEwsEnabled'
    'msExchEwsExceptions'
    'msExchEwsWellKnownApplicationPolicies'
    'msExchExpansionServerName'
    'msExchExtensionAttribute16'
    'msExchExtensionAttribute17'
    'msExchExtensionAttribute18'
    'msExchExtensionAttribute40'
    'msExchExtensionAttribute41'
    'msExchExtensionAttribute45'
    'msExchExtensionCustomAttribute1'
    'msExchExtensionCustomAttribute2'
    'msExchExtensionCustomAttribute3'
    'msExchExtensionCustomAttribute4'
    'msExchExtensionCustomAttribute5'
    'msExchExternalDirectoryObjectId'
    'msExchFBURL'
    'msExchForeignGroupSid'
    'msExchGenericForwardingAddress'
    'msExchGroupExternalMemberCount'
    'msExchGroupMemberCount'
    'msExchGroupSecurityFlags'
    'msExchHideFromAddressLists'
    'msExchImmutableId'
    'msExchInformationBarrierSegmentLink'
    'msExchIntendedMailboxPlanLink'
    'msExchIsMSODirsynced'
    'msExchJoinedProxyAddress'
    'msExchLabeledURI'
    'msExchLastExchangeChangedTime'
    'msExchLitigationHoldDate'
    'msExchLitigationHoldOwner'
    'msExchLocalizationFlags'
    'msExchMailboxAuditEnable'
    'msExchMailboxAuditLastAdminAccess'
    'msExchMailboxAuditLastDelegateAccess'
    'msExchMailboxAuditLastExternalAccess'
    'msExchMailboxAuditLogAgeLimit'
    'msExchMailboxFolderSet'
    'msExchMailboxMoveBatchName'
    'msExchMailboxMoveFlags'
    'msExchMailboxMoveRemoteHostName'
    'msExchMailboxMoveSourceArchiveMDBLink'
    'msExchMailboxMoveSourceMDBLink'
    'msExchMailboxMoveStatus'
    'msExchMailboxMoveTargetArchiveMDBLink'
    'msExchMailboxMoveTargetMDBLink'
    'msExchMailboxPlanType'
    'msExchMailboxRelease'
    'msExchMailboxSecurityDescriptor'
    'msExchMasterAccountSid'
    'msExchMessageHygieneFlags'
    'msExchMessageHygieneSCLDeleteThreshold'
    'msExchMessageHygieneSCLJunkThreshold'
    'msExchMessageHygieneSCLQuarantineThreshold'
    'msExchMessageHygieneSCLRejectThreshold'
    'msExchModeratedByLink'
    'msExchModerationFlags'
    'msExchMultiMailboxDatabasesLink'
    'msExchMultiMailboxGUIDs'
    'msExchMultiMailboxLocationsLink'
    'msExchNonCompliantDeviceLink'
    'msExchNonCompliantDevices'
    'msExchObjectID'
    'msExchOnPremiseObjectGuid'
    'msExchOrganizationUpgradeRequest'
    'msExchOrganizationUpgradeStatus'
    'msExchOURoot'
    'msExchOWAPolicy'
    'msExchParentPlanLink'
    'msExchPartnerGroupID'
    'msExchPoliciesExcluded'
    'msExchPoliciesIncluded'
    'msExchPreviousRecipientTypeDetails'
    'msExchProvisioningFlags'
    'msExchPublicFolderMailbox'
    'msExchRBACPolicyLink'
    'msExchRecipientDisplayType'
    'msExchRecipientSoftDeletedStatus'
    'msExchRecipientTypeDetails'
    'msExchRecipLimit'
    'msExchRemoteRecipientType'
    'msExchReplicableChangeVersion'
    'msExchRequireAuthToSendTo'
    'msExchResourceBehaviorOptions'
    'msExchResourceCapacity'
    'msExchResourceDisplay'
    'msExchResourceMetaData'
    'msExchResourceProvisioningOptions'
    'msExchResourceSearchProperties'
    'msExchRetentionComment'
    'msExchRetentionURL'
    'msExchRMSComputerAccountsLink'
    'msExchRoleGroupType'
    'msExchSafeRecipientsHash'
    'msExchSafeSendersHash'
    'msExchSenderHintTranslations'
    'msExchSharedDomainLastModified'
    'msExchSharedDomainTenant'
    'msExchSharedWithReference'
    'msExchSharedWithTargetProxyAddress'
    'msExchSharingAnonymousIdentities'
    'msExchSharingPartnerIdentities'
    'msExchSharingPolicyLink'
    'msExchSIDHistory'
    'msExchStsRefreshTokensValidFrom'
    'msExchSupervisionDLLink'
    'msExchSupervisionOneOffLink'
    'msExchSupervisionUserLink'
    'msExchSyncAccountsPolicyDN'
    'msExchTextMessagingState'
    'msExchThrottlingPolicyDN'
    'msExchTransportRecipientSettingsFlags'
    'msExchUCVoiceMailSettings'
    'msExchUMCallingLineIds'
    'msExchUMDtmfMap'
    'msExchUMListInDirectorySearch'
    'msExchUMRecipientDialPlanLink'
    'msExchUMSpokenName'
    'msExchUserAccountControl'
    'msExchUserCulture'
    'msExchUserHoldPolicies'
    'msExchVersion'
    'msExchWellKnownObject'
    'msExchWhenIBSegmentChanged'
    'msExchWhenMailboxCreated'
    'msExchWhenMailboxWorkloadsModified'
    'msExchWhenPropChangeLastSubmitted'
    'msExchWhenReplicablePropLastChanged'
    'msExchWhenSoftDeletedTime'
    'msExchWindowsLiveID'
    'otherFacsimileTelephoneNumber'
    'otherHomePhone'
    'otherTelephone'
    'pager'
    'physicalDeliveryOfficeName'
    'postalCode'
    'postOfficeBox'
    'protocolSettings'
    'proxyAddresses'
    'publicDelegates'
    'ReplicationSignature'
    'securityProtocol'
    'showInAddressBook'
    'sn'
    'st'
    'streetAddress'
    'submissionContLength'
    'targetAddress'
    'telephoneAssistant'
    'telephoneNumber'
    'textEncodedORAddress'
    'title'
    'unauthOrig'
    'userCertificate'
    'userSMIMECertificate'
    'wWWHomePage'
)

$script:GroupRecipientPropertiesForDeletion = @(
    'adminDisplayName'
    'altRecipient'
    'AltSecurityIdentities'
    'authOrig'
    'company'
    'deletedItemFlags'
    'delivContLength'
    'deliverAndRedirect'
    'department'
    'description'
    'displayName'
    'displayNamePrintable'
    'dLMemRejectPerms'
    'dLMemSubmitPerms'
    'extensionAttribute1'
    'extensionAttribute10'
    'extensionAttribute11'
    'extensionAttribute12'
    'extensionAttribute13'
    'extensionAttribute14'
    'extensionAttribute15'
    'extensionAttribute2'
    'extensionAttribute3'
    'extensionAttribute4'
    'extensionAttribute5'
    'extensionAttribute6'
    'extensionAttribute7'
    'extensionAttribute8'
    'extensionAttribute9'
    'garbageCollPeriod'
    'heuristics'
    'hideDLMembership'
    'homeMDB'
    'homeMTA'
    'info'
    'internetEncoding'
    'legacyExchangeDN'
    'mail'
    'mailNickname'
    'managedBy'
    'mAPIRecipient'
    'mDBUseDefaults'
    'msDS-GeoCoordinatesAltitude'
    'msDS-GeoCoordinatesLatitude'
    'msDS-GeoCoordinatesLongitude'
    'msDS-HABSeniorityIndex'
    'msDS-PhoneticDisplayName'
    'msExchAddressBookFlags'
    'msExchAddressBookPolicyLink'
    'msExchAdministrativeUnitLink'
    'msExchAlternateMailboxes'
    'msExchApprovalApplicationLink'
    'msExchArbitrationMailbox'
    'msExchArchiveAddress'
    'msExchArchiveDatabaseLink'
    'msExchArchiveGUID'
    'msExchArchiveName'
    'msExchArchiveQuota'
    'msExchArchiveRelease'
    'msExchArchiveStatus'
    'msExchArchiveWarnQuota'
    'msExchAssistantName'
    'msExchAuditAdmin'
    'msExchAuditDelegate'
    'msExchAuditDelegateAdmin'
    'msExchAuditOwner'
    'msExchAuthPolicyLink'
    'msExchBlockedSendersHash'
    'msExchBypassAudit'
    'msExchBypassModerationFromDLMembersLink'
    'msExchBypassModerationLink'
    'msExchCalculatedTargetAddress'
    'msExchCalendarLoggingQuota'
    'msExchCalendarRepairDisabled'
    'msExchCapabilityIdentifiers'
    'msExchCoManagedByLink'
    'msExchConfigurationXML'
    'msExchCorrelationId'
    'msExchCU'
    'msExchDataEncryptionPolicyLink'
    'msExchDelegateIRMBlockList'
    'msExchDelegateListLink'
    'msExchDirsyncAuthorityMetadata'
    'msExchDirsyncID'
    'msExchDisabledArchiveDatabaseLink'
    'msExchDisabledArchiveGUID'
    'msExchDumpsterQuota'
    'msExchDumpsterWarningQuota'
    'msExchELCExpirySuspensionEnd'
    'msExchELCExpirySuspensionStart'
    'msExchELCMailboxFlags'
    'msExchEnableModeration'
    'msExchEnforcedTimestamps'
    'msExchEwsApplicationAccessPolicy'
    'msExchEwsEnabled'
    'msExchEwsExceptions'
    'msExchEwsWellKnownApplicationPolicies'
    'msExchExpansionServerName'
    'msExchExtensionAttribute16'
    'msExchExtensionAttribute17'
    'msExchExtensionAttribute18'
    'msExchExtensionAttribute40'
    'msExchExtensionAttribute41'
    'msExchExtensionAttribute45'
    'msExchExtensionCustomAttribute1'
    'msExchExtensionCustomAttribute2'
    'msExchExtensionCustomAttribute3'
    'msExchExtensionCustomAttribute4'
    'msExchExtensionCustomAttribute5'
    'msExchExternalDirectoryObjectId'
    'msExchExternalOOFOptions'
    'msExchFBURL'
    'msExchForeignGroupSid'
    'msExchGenericForwardingAddress'
    'msExchGroupDepartRestriction'
    'msExchGroupExternalMemberCount'
    'msExchGroupJoinRestriction'
    'msExchGroupMemberCount'
    'msExchGroupSecurityFlags'
    'msExchHideFromAddressLists'
    'msExchHomeServerName'
    'msExchImmutableId'
    'msExchInformationBarrierSegmentLink'
    'msExchIntendedMailboxPlanLink'
    'msExchIsMSODirsynced'
    'msExchJoinedProxyAddress'
    'msExchLabeledURI'
    'msExchLastExchangeChangedTime'
    'msExchLitigationHoldDate'
    'msExchLitigationHoldOwner'
    'msExchLocalizationFlags'
    'msExchMailboxAuditEnable'
    'msExchMailboxAuditLastAdminAccess'
    'msExchMailboxAuditLastDelegateAccess'
    'msExchMailboxAuditLastExternalAccess'
    'msExchMailboxAuditLogAgeLimit'
    'msExchMailboxContainerGuid'
    'msExchMailboxFolderSet'
    'msExchMailboxGuid'
    'msExchMailboxMoveBatchName'
    'msExchMailboxMoveFlags'
    'msExchMailboxMoveRemoteHostName'
    'msExchMailboxMoveSourceArchiveMDBLink'
    'msExchMailboxMoveSourceMDBLink'
    'msExchMailboxMoveStatus'
    'msExchMailboxMoveTargetArchiveMDBLink'
    'msExchMailboxMoveTargetMDBLink'
    'msExchMailboxPlanType'
    'msExchMailboxRelease'
    'msExchMailboxSecurityDescriptor'
    'msExchMailboxTemplateLink'
    'msExchMasterAccountSid'
    'msExchMaxBlockedSenders'
    'msExchMaxSafeSenders'
    'msExchMDBRulesQuota'
    'msExchMessageHygieneFlags'
    'msExchMessageHygieneSCLDeleteThreshold'
    'msExchMessageHygieneSCLJunkThreshold'
    'msExchMessageHygieneSCLQuarantineThreshold'
    'msExchMessageHygieneSCLRejectThreshold'
    'msExchMobileAllowedDeviceIds'
    'msExchMobileBlockedDeviceIds'
    'msExchMobileMailboxFlags'
    'msExchMobileMailboxPolicyLink'
    'msExchModeratedByLink'
    'msExchModerationFlags'
    'msExchMultiMailboxDatabasesLink'
    'msExchMultiMailboxGUIDs'
    'msExchMultiMailboxLocationsLink'
    'msExchNonCompliantDeviceLink'
    'msExchNonCompliantDevices'
    'msExchObjectID'
    'msExchOnPremiseObjectGuid'
    'msExchOrganizationUpgradeRequest'
    'msExchOrganizationUpgradeStatus'
    'msExchOURoot'
    'msExchOWAPolicy'
    'msExchParentPlanLink'
    'msExchPartnerGroupID'
    'msExchPoliciesExcluded'
    'msExchPoliciesIncluded'
    'msExchPreviousHomeMDB'
    'msExchPreviousMailboxGuid'
    'msExchPreviousRecipientTypeDetails'
    'msExchProvisioningFlags'
    'msExchPublicFolderMailbox'
    'msExchRBACPolicyLink'
    'msExchRecipientDisplayType'
    'msExchRecipientSoftDeletedStatus'
    'msExchRecipientTypeDetails'
    'msExchRecipLimit'
    'msExchRemoteRecipientType'
    'msExchReplicableChangeVersion'
    'msExchRequireAuthToSendTo'
    'msExchResourceBehaviorOptions'
    'msExchResourceCapacity'
    'msExchResourceDisplay'
    'msExchResourceMetaData'
    'msExchResourceProvisioningOptions'
    'msExchResourceSearchProperties'
    'msExchRetentionComment'
    'msExchRetentionURL'
    'msExchRMSComputerAccountsLink'
    'msExchRoleGroupType'
    'msExchSafeRecipientsHash'
    'msExchSafeSendersHash'
    'msExchSenderHintTranslations'
    'msExchSharedDomainLastModified'
    'msExchSharedDomainTenant'
    'msExchSharedWithReference'
    'msExchSharedWithTargetProxyAddress'
    'msExchSharingAnonymousIdentities'
    'msExchSharingPartnerIdentities'
    'msExchSharingPolicyLink'
    'msExchSIDHistory'
    'msExchStsRefreshTokensValidFrom'
    'msExchSupervisionDLLink'
    'msExchSupervisionOneOffLink'
    'msExchSupervisionUserLink'
    'msExchSyncAccountsPolicyDN'
    'msExchTeamMailboxExpiration'
    'msExchTeamMailboxOwners'
    'msExchTeamMailboxSharePointUrl'
    'msExchTextMessagingState'
    'msExchThrottlingPolicyDN'
    'msExchTransportRecipientSettingsFlags'
    'msExchUCVoiceMailSettings'
    'msExchUMCallingLineIds'
    'msExchUMDtmfMap'
    'msExchUMListInDirectorySearch'
    'msExchUMRecipientDialPlanLink'
    'msExchUMSpokenName'
    'msExchUMTemplateLink'
    'msExchUnifiedMailbox'
    'msExchUseOAB'
    'msExchUserAccountControl'
    'msExchUserCulture'
    'msExchUserHoldPolicies'
    'msExchVersion'
    'msExchWellKnownObject'
    'msExchWhenIBSegmentChanged'
    'msExchWhenMailboxCreated'
    'msExchWhenMailboxWorkloadsModified'
    'msExchWhenPropChangeLastSubmitted'
    'msExchWhenReplicablePropLastChanged'
    'msExchWhenSoftDeletedTime'
    'msExchWindowsLiveID'
    'msOrg-IsOrganizational'
    'oOFReplyToOriginator'
    'protocolSettings'
    'proxyAddresses'
    'publicDelegates'
    'ReplicationSignature'
    'reportToOriginator'
    'reportToOwner'
    'securityProtocol'
    'showInAddressBook'
    'submissionContLength'
    'targetAddress'
    'telephoneNumber'
    'textEncodedORAddress'
    'unauthOrig'
    'userCertificate'
    'userSMIMECertificate'
    'wWWHomePage'
)

$script:UserLinkPropertiesForDeletion = @(
    'altRecipient'
    'authOrig'
    'dLMemRejectPerms'
    'dLMemSubmitPerms'
    'mailNickname'
    'manager'
    'msExchAdministrativeUnitLink'
    'msExchArbitrationMailbox'
    'msExchAuthPolicyLink'
    'msExchBypassModerationFromDLMembersLink'
    'msExchBypassModerationLink'
    'msExchInformationBarrierSegmentLink'
    'msExchIntendedMailboxPlanLink'
    'msExchModeratedByLink'
    'msExchNonCompliantDeviceLink'
    'msExchOWAPolicy'
    'msExchParentPlanLink'
    'msExchPublicFolderMailbox'
    'msExchRBACPolicyLink'
    'msExchRecipientSoftDeletedStatus'
    'msExchRecipientTypeDetails'
    'msExchRMSComputerAccountsLink'
    'msExchSharingPolicyLink'
    'msExchSIDHistory'
    'msExchSupervisionDLLink'
    'msExchSupervisionOneOffLink'
    'msExchSupervisionUserLink'
    'msExchSyncAccountsPolicyDN'
    'msExchThrottlingPolicyDN'
    'msExchUMRecipientDialPlanLink'
    'publicDelegates'
    'showInAddressBook'
    'unauthOrig'
)

$script:GroupLinkPropertiesForDeletion = @(
    'altRecipient'
    'authOrig'
    'dLMemRejectPerms'
    'dLMemSubmitPerms'
    'mailNickname'
    'managedBy'
    'msExchAddressBookPolicyLink'
    'msExchAdministrativeUnitLink'
    'msExchApprovalApplicationLink'
    'msExchArbitrationMailbox'
    'msExchAuthPolicyLink'
    'msExchBypassModerationFromDLMembersLink'
    'msExchBypassModerationLink'
    'msExchCoManagedByLink'
    'msExchDataEncryptionPolicyLink'
    'msExchDelegateListLink'
    'msExchHomeServerName'
    'msExchInformationBarrierSegmentLink'
    'msExchIntendedMailboxPlanLink'
    'msExchMailboxTemplateLink'
    'msExchMobileMailboxPolicyLink'
    'msExchModeratedByLink'
    'msExchNonCompliantDeviceLink'
    'msExchOWAPolicy'
    'msExchParentPlanLink'
    'msExchPublicFolderMailbox'
    'msExchRBACPolicyLink'
    'msExchRecipientSoftDeletedStatus'
    'msExchRecipientTypeDetails'
    'msExchRMSComputerAccountsLink'
    'msExchSharingPolicyLink'
    'msExchSIDHistory'
    'msExchSupervisionDLLink'
    'msExchSupervisionOneOffLink'
    'msExchSupervisionUserLink'
    'msExchSyncAccountsPolicyDN'
    'msExchTeamMailboxOwners'
    'msExchThrottlingPolicyDN'
    'msExchUMRecipientDialPlanLink'
    'msExchUMTemplateLink'
    'msExchUseOAB'
    'publicDelegates'
    'showInAddressBook'
    'unauthOrig'
)

function Initialize-ScenarioCounts
{
    $nUrpU = @($script:UserRecipientPropertiesForUpsert).Count
    $nGrpU = @($script:GroupRecipientPropertiesForUpsert).Count
    $nUlpU = @($script:UserLinkPropertiesForUpsert).Count
    $nGlpU = @($script:GroupLinkPropertiesForUpsert).Count
    $nUrpD = @($script:UserRecipientPropertiesForDeletion).Count
    $nGrpD = @($script:GroupRecipientPropertiesForDeletion).Count
    $nUlpD = @($script:UserLinkPropertiesForDeletion).Count
    $nGlpD = @($script:GroupLinkPropertiesForDeletion).Count

    $allUserCount = [Math]::Max($nUrpU, [Math]::Max($nUlpU, [Math]::Max($nUrpD, $nUlpD)))
    $allGroupCount = [Math]::Max($nGrpU, [Math]::Max($nGlpU, [Math]::Max($nGrpD, $nGlpD)))
    $script:ScenarioCounts = [ordered]@{
        N_URP_U = $nUrpU
        N_GRP_U = $nGrpU
        N_ULP_U = $nUlpU
        N_GLP_U = $nGlpU
        N_URP_D = $nUrpD
        N_GRP_D = $nGrpD
        N_ULP_D = $nUlpD
        N_GLP_D = $nGlpD
        N_User = $allUserCount
        N_Groups = $allGroupCount
    }
}

Initialize-ScenarioCounts

function ConvertTo-CurrentScenarioCommandName
{
    param([AllowNull()] [string] $Value)

    if ([string]::Equals($Value, "RunAll", [StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($Value, "Run-All-Scenarios", [StringComparison]::OrdinalIgnoreCase))
    {
        return "Run-All-OBScenarios"
    }

    return $Value
}

function Get-ScenarioCommandDefinition
{
    switch ($ScenarioCommand)
    {
        "User-Upsert" {
            return [ordered]@{
                FullEstimatedMinutes = 60
                MiniSetEstimatedMinutes = 5
                PhaseNames = @(
                    "Pure User Recipient Upsert",
                    "Pure User Link Upsert",
                    "Mixed User Upsert")
            }
        }
        "Group-Upsert" {
            return [ordered]@{
                FullEstimatedMinutes = 75
                MiniSetEstimatedMinutes = 5
                PhaseNames = @(
                    "Pure Group Recipient Upsert",
                    "Pure Group Link Upsert",
                    "Mixed Group Upsert")
            }
        }
        "User-Properties-Deletion" {
            return [ordered]@{
                FullEstimatedMinutes = 80
                MiniSetEstimatedMinutes = 10
                PhaseNames = @(
                    "Pure User Recipient Deletion",
                    "Pure User Link Deletion",
                    "Mixed User Deletion")
            }
        }
        "Group-Properties-Deletion" {
            return [ordered]@{
                FullEstimatedMinutes = 95
                MiniSetEstimatedMinutes = 10
                PhaseNames = @(
                    "Pure Group Recipient Deletion",
                    "Pure Group Link Deletion",
                    "Mixed Group Deletion")
            }
        }
        default {
            return [ordered]@{
                FullEstimatedMinutes = 305
                MiniSetEstimatedMinutes = 30
                PhaseNames = @(
                    "Pure User Recipient Upsert",
                    "Pure User Link Upsert",
                    "Pure Group Recipient Upsert",
                    "Pure Group Link Upsert",
                    "Mixed User Upsert",
                    "Mixed Group Upsert",
                    "Pure User Recipient Deletion",
                    "Pure User Link Deletion",
                    "Pure Group Recipient Deletion",
                    "Pure Group Link Deletion",
                    "Mixed User Deletion",
                    "Mixed Group Deletion")
            }
        }
    }
}

function Get-ScenarioEstimatedMinutes
{
    if ($ScenarioSetMode -eq "MiniSet")
    {
        return [int](Get-ScenarioCommandDefinition).MiniSetEstimatedMinutes
    }

    return [int](Get-ScenarioCommandDefinition).FullEstimatedMinutes
}

function Get-ScenarioTotalEstimatedMinutes
{
    if ($PreflightOnly)
    {
        return $script:ScenarioPreflightEstimatedMinutes
    }

    return (Get-ScenarioEstimatedMinutes) +
        $script:ScenarioPreflightEstimatedMinutes +
        $script:ScenarioPopulationEstimatedMinutes
}

function ConvertTo-JsonLine
{
    param([Parameter(Mandatory)] [object] $InputObject)

    return ($InputObject | ConvertTo-Json -Depth 12 -Compress)
}

function Get-ScenarioLogKey
{
    param([Parameter(Mandatory)] [string] $Path)

    $name = [IO.Path]::GetFileName($Path)
    switch -Regex ($name)
    {
        "^operations\.jsonl$" { return "OperationsJson" }
        "^operations\.log$" { return "OperationsReadable" }
        "^validations\.jsonl$" { return "ValidationsJson" }
        "^events\.jsonl$" { return "EventsJson" }
        "^scenario-details-\d+\.jsonl$" { return "ScenarioDetails" }
        default { return $null }
    }
}

function Add-ScenarioLogSegment
{
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $Path)

    if (-not $script:ScenarioLogSegments.Contains($Key))
    {
        $script:ScenarioLogSegments[$Key] = [Collections.Generic.List[string]]::new()
    }
    $segmentName = [IO.Path]::GetFileName($Path)
    if (-not $script:ScenarioLogSegments[$Key].Contains($segmentName))
    {
        $script:ScenarioLogSegments[$Key].Add($segmentName)
    }
}

function Get-ScenarioLogArchivePrefix
{
    param([Parameter(Mandatory)] [string] $Key)

    switch ($Key)
    {
        "OperationsJson" { return "operations" }
        "OperationsReadable" { return "operations" }
        "ValidationsJson" { return "validations" }
        "EventsJson" { return "events" }
        "ScenarioDetails" { return "scenario-details" }
        default { throw "No ScenarioTest archive prefix exists for '$Key'." }
    }
}

function Recover-ScenarioLogRotationStaging
{
    $stagingDirectories = @(Get-ChildItem -LiteralPath $script:RunDirectory -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like ".scenario-log-rotation-*" })
    foreach ($stagingDirectory in $stagingDirectories)
    {
        $manifestPath = Join-Path $stagingDirectory.FullName "manifest.json"
        if (-not (Test-Path -LiteralPath $manifestPath))
        {
            Remove-Item -LiteralPath $stagingDirectory.FullName -Recurse -Force -ErrorAction Stop
            continue
        }

        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $sourcePath = if ($manifest.PSObject.Properties.Name -contains "SourcePath")
        {
            [string]$manifest.SourcePath
        }
        else
        {
            [string]$manifest.ActivePath
        }
        $activePath = [string]$manifest.ActivePath
        $backupPath = [string]$manifest.BackupPath
        $archivePaths = @($manifest.ArchivePaths | ForEach-Object { [string]$_ })

        if ((Test-Path -LiteralPath $sourcePath) -or (Test-Path -LiteralPath $activePath))
        {
            Remove-Item -LiteralPath $stagingDirectory.FullName -Recurse -Force -ErrorAction Stop
            continue
        }

        if (-not (Test-Path -LiteralPath $backupPath))
        {
            throw "ScenarioTest log rotation staging '$($stagingDirectory.Name)' cannot be recovered because both the active log and source backup are missing."
        }

        foreach ($archivePath in $archivePaths)
        {
            if (Test-Path -LiteralPath $archivePath)
            {
                Remove-Item -LiteralPath $archivePath -Force -ErrorAction Stop
            }
        }
        Move-Item -LiteralPath $backupPath -Destination $sourcePath -Force -ErrorAction Stop
        Remove-Item -LiteralPath $stagingDirectory.FullName -Recurse -Force -ErrorAction Stop
    }
}

function Repair-ScenarioOversizedActiveLog
{
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $Prefix,
        [Parameter(Mandatory)] [string] $Extension,
        [Parameter(Mandatory)] [string] $ActivePath)

    $maximumBytes = 4MB
    if (-not (Test-Path -LiteralPath $ActivePath) -or
        (Get-Item -LiteralPath $ActivePath).Length -le $maximumBytes)
    {
        return
    }

    $rotationId = [Guid]::NewGuid().ToString("N")
    $stagingDirectory = Join-Path $script:RunDirectory ".scenario-log-rotation-$Key-$rotationId"
    New-Item -Path $stagingDirectory -ItemType Directory -Force | Out-Null

    $encoding = [Text.UTF8Encoding]::new($false)
    $reader = $null
    $writer = $null
    $chunkPath = $null
    $chunkLength = 0L
    $chunkNumber = 0
    $chunkPaths = [Collections.Generic.List[string]]::new()
    $archivePaths = [Collections.Generic.List[string]]::new()
    $movedArchivePaths = [Collections.Generic.List[string]]::new()
    $backupPath = Join-Path $stagingDirectory "source.backup"
    $targetActivePath = $ActivePath
    $completed = $false

    try
    {
        $reader = [IO.StreamReader]::new($ActivePath, $encoding, $true)
        while (($line = $reader.ReadLine()) -ne $null)
        {
            $bytes = $encoding.GetBytes($line + [Environment]::NewLine)
            if ($bytes.Length -gt $maximumBytes)
            {
                throw "A single existing ScenarioTest log record in '$ActivePath' is $($bytes.Length) bytes and exceeds the $maximumBytes-byte segment limit."
            }

            if ($null -eq $writer -or $chunkLength + $bytes.Length -gt $maximumBytes)
            {
                if ($null -ne $writer)
                {
                    $writer.Flush()
                    $writer.Dispose()
                    $writer = $null
                    [void]$chunkPaths.Add($chunkPath)
                }

                $chunkPath = Join-Path $stagingDirectory ("chunk-{0:D8}.tmp" -f $chunkNumber)
                $chunkNumber++
                $chunkLength = 0L
                $writer = [IO.FileStream]::new(
                    $chunkPath,
                    [IO.FileMode]::CreateNew,
                    [IO.FileAccess]::Write,
                    [IO.FileShare]::None)
            }

            $writer.Write($bytes, 0, $bytes.Length)
            $chunkLength += $bytes.Length
        }

        if ($null -ne $writer)
        {
            $writer.Flush()
            $writer.Dispose()
            $writer = $null
            [void]$chunkPaths.Add($chunkPath)
        }
        $reader.Dispose()
        $reader = $null

        if ($chunkPaths.Count -eq 0)
        {
            throw "ScenarioTest log rotation found no complete records in oversized log '$ActivePath'."
        }

        $nextIndex = [int]$script:ScenarioLogNextIndex[$Key]
        $archiveCount = if ($Key -eq "ScenarioDetails") { $chunkPaths.Count } else { $chunkPaths.Count - 1 }
        for ($index = 0; $index -lt $archiveCount; $index++)
        {
            do
            {
                $archivePath = Join-Path $script:RunDirectory ("{0}-{1:D4}{2}" -f $Prefix, $nextIndex, $Extension)
                $nextIndex++
            }
            while (Test-Path -LiteralPath $archivePath)
            [void]$archivePaths.Add($archivePath)
        }
        if ($Key -eq "ScenarioDetails")
        {
            $targetActivePath = $archivePaths[$archivePaths.Count - 1]
            $archivePaths.RemoveAt($archivePaths.Count - 1)
        }

        foreach ($chunk in @($chunkPaths))
        {
            if ((Get-Item -LiteralPath $chunk).Length -gt $maximumBytes)
            {
                throw "ScenarioTest log rotation produced an oversized staged segment '$chunk'."
            }
        }

        $manifest = [ordered]@{
            SourcePath = $ActivePath
            ActivePath = $targetActivePath
            BackupPath = $backupPath
            ArchivePaths = @($archivePaths)
            Key = $Key
        }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stagingDirectory "manifest.json") -Encoding UTF8

        Move-Item -LiteralPath $ActivePath -Destination $backupPath -Force -ErrorAction Stop
        for ($index = 0; $index -lt $archivePaths.Count; $index++)
        {
            Move-Item -LiteralPath $chunkPaths[$index] -Destination $archivePaths[$index] -Force -ErrorAction Stop
            [void]$movedArchivePaths.Add($archivePaths[$index])
        }
        Move-Item `
            -LiteralPath $chunkPaths[$chunkPaths.Count - 1] `
            -Destination $targetActivePath `
            -Force `
            -ErrorAction Stop
        $completed = $true

        foreach ($archivePath in @($archivePaths))
        {
            Add-ScenarioLogSegment -Key $Key -Path $archivePath
        }
        if ($Key -eq "ScenarioDetails")
        {
            [void]$script:ScenarioLogSegments[$Key].Remove([IO.Path]::GetFileName($ActivePath))
            Add-ScenarioLogSegment -Key $Key -Path $targetActivePath
            $script:ScenarioDetailLogPath = $targetActivePath
            $script:ScenarioDetailLogIndex = [int]([IO.Path]::GetFileNameWithoutExtension($targetActivePath) -replace "^scenario-details-", "")
        }
        $script:ScenarioLogNextIndex[$Key] = $nextIndex
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction Stop
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction Stop
    }
    catch
    {
        if ($null -ne $writer)
        {
            $writer.Dispose()
        }
        if ($null -ne $reader)
        {
            $reader.Dispose()
        }

        if (-not $completed)
        {
            if ((Test-Path -LiteralPath $backupPath) -and
                -not (Test-Path -LiteralPath $ActivePath) -and
                -not (Test-Path -LiteralPath $targetActivePath))
            {
                foreach ($archivePath in @($movedArchivePaths))
                {
                    if (Test-Path -LiteralPath $archivePath)
                    {
                        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
                    }
                }
                Move-Item -LiteralPath $backupPath -Destination $ActivePath -Force -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $ActivePath)
            {
                Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        throw
    }
}

function Initialize-ScenarioLogRotationState
{
    $definitions = @(
        [ordered]@{ Key = "OperationsJson"; Prefix = "operations"; Extension = ".jsonl"; ActivePath = $script:OperationLogPath }
        [ordered]@{ Key = "OperationsReadable"; Prefix = "operations"; Extension = ".log"; ActivePath = $script:ReadableOperationLogPath }
        [ordered]@{ Key = "ValidationsJson"; Prefix = "validations"; Extension = ".jsonl"; ActivePath = $script:ValidationLogPath }
        [ordered]@{ Key = "EventsJson"; Prefix = "events"; Extension = ".jsonl"; ActivePath = $script:EventLogPath }
        [ordered]@{ Key = "ScenarioDetails"; Prefix = "scenario-details"; Extension = ".jsonl"; ActivePath = $script:ScenarioDetailLogPath }
    )

    Recover-ScenarioLogRotationStaging
    foreach ($definition in $definitions)
    {
        $key = [string]$definition.Key
        $script:ScenarioLogNextIndex[$key] = 1
        $escapedExtension = [regex]::Escape([string]$definition.Extension)
        $pattern = "^$([regex]::Escape([string]$definition.Prefix))-(\d{4})$escapedExtension$"
        $segmentFiles = @(Get-ChildItem -LiteralPath $script:RunDirectory -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $pattern } |
            Sort-Object Name)
        foreach ($segmentFile in $segmentFiles)
        {
            Add-ScenarioLogSegment -Key $key -Path $segmentFile.FullName
            if ($segmentFile.Name -match $pattern)
            {
                $script:ScenarioLogNextIndex[$key] = [math]::Max(
                    [int]$script:ScenarioLogNextIndex[$key],
                    ([int]$Matches[1] + 1))
            }
        }

        if ($key -eq "ScenarioDetails" -and (Test-Path -LiteralPath $script:ScenarioDetailLogPath))
        {
            Add-ScenarioLogSegment -Key $key -Path $script:ScenarioDetailLogPath
        }

        Repair-ScenarioOversizedActiveLog `
            -Key $key `
            -Prefix ([string]$definition.Prefix) `
            -Extension ([string]$definition.Extension) `
            -ActivePath ([string]$definition.ActivePath)
    }
}

function Write-BoundedScenarioLogLine
{
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [byte[]] $Bytes)

    $maximumBytes = 4MB
    if ($Bytes.Length -gt $maximumBytes)
    {
        throw "A single ScenarioTest log record is $($Bytes.Length) bytes and exceeds the $maximumBytes-byte segment limit."
    }

    $key = Get-ScenarioLogKey -Path $Path
    if ([string]::IsNullOrWhiteSpace($key))
    {
        throw "No ScenarioTest log rotation definition exists for '$Path'."
    }
    if ($key -eq "ScenarioDetails")
    {
        Add-ScenarioLogSegment -Key $key -Path $Path
    }

    $targetPath = $Path
    $currentLength = if (Test-Path -LiteralPath $Path)
    {
        (Get-Item -LiteralPath $Path).Length
    }
    else
    {
        0
    }

    if ($currentLength -gt 0 -and $currentLength + $Bytes.Length -gt $maximumBytes)
    {
        if ($key -eq "ScenarioDetails")
        {
            $nextIndex = [int]$script:ScenarioLogNextIndex[$key]
            do
            {
                $targetPath = Join-Path $script:RunDirectory ("scenario-details-{0:D4}.jsonl" -f $nextIndex)
                $nextIndex++
            }
            while (Test-Path -LiteralPath $targetPath)

            $script:ScenarioLogNextIndex[$key] = $nextIndex
            $script:ScenarioDetailLogIndex = $nextIndex - 1
            $script:ScenarioDetailLogPath = $targetPath
            Add-ScenarioLogSegment -Key $key -Path $targetPath
        }
        else
        {
            $nextIndex = [int]$script:ScenarioLogNextIndex[$key]
            $prefix = Get-ScenarioLogArchivePrefix -Key $key
            $extension = [IO.Path]::GetExtension($Path)
            do
            {
                $archivePath = Join-Path $script:RunDirectory ("{0}-{1:D4}{2}" -f $prefix, $nextIndex, $extension)
                $nextIndex++
            }
            while (Test-Path -LiteralPath $archivePath)

            Move-Item -LiteralPath $Path -Destination $archivePath -ErrorAction Stop
            $script:ScenarioLogNextIndex[$key] = $nextIndex
            Add-ScenarioLogSegment -Key $key -Path $archivePath
            $targetPath = $Path
        }
    }

    $stream = [IO.FileStream]::new(
        $targetPath,
        [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::Write,
        [IO.FileShare]::ReadWrite)
    try
    {
        $stream.Seek(0, [IO.SeekOrigin]::End) | Out-Null
        $stream.Write($Bytes, 0, $Bytes.Length)
    }
    finally
    {
        $stream.Dispose()
    }
}

function Write-JsonLine
{
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $InputObject)

    $line = (ConvertTo-JsonLine $InputObject) + [Environment]::NewLine
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($line)
    if ($WorkloadMode -eq "ScenarioTest" -and $null -ne (Get-ScenarioLogKey -Path $Path))
    {
        Write-BoundedScenarioLogLine -Path $Path -Bytes $bytes
        return
    }

    $stream = [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::Write,
        [IO.FileShare]::ReadWrite)
    try
    {
        $stream.Seek(0, [IO.SeekOrigin]::End) | Out-Null
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally
    {
        $stream.Dispose()
    }
}

function ConvertTo-ScenarioLogValue
{
    param([object] $Value)

    if ($null -eq $Value)
    {
        return $null
    }
    if ($Value -is [byte[]])
    {
        $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
        try
        {
            $hash = [BitConverter]::ToString($hashAlgorithm.ComputeHash($Value)).Replace("-", "").ToLowerInvariant()
        }
        finally
        {
            $hashAlgorithm.Dispose()
        }
        return "[redacted:binary:length=$($Value.Length):sha256=$hash]"
    }
    if ($Value -is [Security.Principal.SecurityIdentifier])
    {
        return "[redacted:sid]"
    }
    if ($Value -is [Security.AccessControl.ObjectSecurity])
    {
        return ConvertTo-ScenarioLogValue -Value $Value.GetSecurityDescriptorBinaryForm()
    }
    if ($Value -is [string])
    {
        if ($Value -match "(?i)(^|,|\s)DC=" -or $Value -match "(?i)^(S:|X509:|Kerberos:)")
        {
            return "[redacted:structured:length=$($Value.Length)]"
        }
        if ($Value.Length -gt 256)
        {
            return $Value.Substring(0, 256) + "...[truncated]"
        }
        return $Value
    }
    if ($Value -is [Collections.IDictionary])
    {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys)
        {
            $result[[string]$key] = ConvertTo-ScenarioLogValue -Value $Value[$key]
        }
        return $result
    }
    if ($Value -is [Collections.IEnumerable] -and -not ($Value -is [string]))
    {
        return @($Value | ForEach-Object { ConvertTo-ScenarioLogValue -Value $_ })
    }
    if ($Value -is [ValueType])
    {
        return $Value
    }
    return "[redacted:object:type=$($Value.GetType().FullName)]"
}

function Write-ScenarioDetail
{
    param([Parameter(Mandatory)] [object] $Record)

    $safeRecord = [ordered]@{}
    if ($Record -is [Collections.IDictionary])
    {
        foreach ($key in $Record.Keys)
        {
            $safeRecord[[string]$key] = ConvertTo-ScenarioLogValue -Value $Record[$key]
        }
    }
    else
    {
        foreach ($property in $Record.PSObject.Properties)
        {
            $safeRecord[$property.Name] = ConvertTo-ScenarioLogValue -Value $property.Value
        }
    }

    $line = (ConvertTo-JsonLine -InputObject $safeRecord) + [Environment]::NewLine
    $encoding = [Text.UTF8Encoding]::new($false)
    $bytes = $encoding.GetBytes($line)
    Write-BoundedScenarioLogLine -Path $script:ScenarioDetailLogPath -Bytes $bytes
}

function Get-ReadableObjectName
{
    param([string] $Identity)

    if ([string]::IsNullOrWhiteSpace($Identity))
    {
        return "-"
    }

    return [string]($Identity -split "[\\/]" | Select-Object -Last 1)
}

function ConvertTo-ReadableOperationDetails
{
    param([hashtable] $Details)

    if ($null -eq $Details -or $Details.Count -eq 0)
    {
        return "-"
    }

    $parts = foreach ($key in @($Details.Keys | Sort-Object))
    {
        $value = $Details[$key]
        if ($null -eq $value)
        {
            $value = "-"
        }
        elseif ($value -is [string])
        {
            $value = Get-ReadableObjectName -Identity $value
        }
        elseif ($value -is [Collections.IEnumerable])
        {
            $value = @($value | ForEach-Object { Get-ReadableObjectName -Identity ([string]$_) }) -join ","
        }

        "$key=$value"
    }

    return $parts -join "; "
}

function Write-ReadableOperationRecord
{
    param(
        [Parameter(Mandatory)] [datetime] $Timestamp,
        [Parameter(Mandatory)] [string] $Operation,
        [Parameter(Mandatory)] [string] $Status,
        [string] $Identity,
        [hashtable] $Details,
        [Exception] $Exception)

    $objectName = Get-ReadableObjectName -Identity $Identity
    $operationDetails = ConvertTo-ReadableOperationDetails -Details $Details
    $result = if ($null -eq $Exception) { $Status } else { "$Status`: $($Exception.Message)" }
    $line = "[{0}] [{1}] [{2}] [{3}] [{4}]" -f @(
        $Timestamp.ToString("yyyy/M/d HH:mm:ss.fff"),
        $objectName,
        $Operation,
        $operationDetails,
        $result)

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($line + [Environment]::NewLine)
    if ($WorkloadMode -eq "ScenarioTest")
    {
        Write-BoundedScenarioLogLine -Path $script:ReadableOperationLogPath -Bytes $bytes
    }
    else
    {
        $line | Add-Content -LiteralPath $script:ReadableOperationLogPath -Encoding UTF8
    }
}

function Write-RunEvent
{
    param(
        [Parameter(Mandatory)] [string] $Level,
        [Parameter(Mandatory)] [string] $Message,
        [hashtable] $Data)

    $eventRecord = [ordered]@{
        TimestampUtc = [datetime]::UtcNow.ToString("o")
        Level = $Level
        Message = $Message
        Data = $Data
    }
    Write-JsonLine -Path $script:EventLogPath -InputObject $eventRecord

    $color = switch ($Level)
    {
        "Error" { "Red" }
        "Warning" { "Yellow" }
        "Success" { "Green" }
        default { "Gray" }
    }
    Write-Host "[$($eventRecord.TimestampUtc)] [$Level] $Message" -ForegroundColor $color
}

function Get-CommandParameters
{
    param(
        [Parameter(Mandatory)] [string] $CommandName,
        [Parameter(Mandatory)] [hashtable] $Parameters)

    if (-not [string]::IsNullOrWhiteSpace($Organization) -and
        (Get-Command $CommandName -ErrorAction Stop).Parameters.ContainsKey("Organization"))
    {
        $Parameters["Organization"] = $Organization
    }
    return $Parameters
}

function Get-RecipientByIdentity
{
    param([Parameter(Mandatory)] [string] $Identity)

    $parameters = Get-CommandParameters -CommandName "Get-Recipient" -Parameters @{
        Identity = $Identity
        ErrorAction = "Stop"
    }
    return Get-Recipient @parameters
}

function Get-ContactByIdentity
{
    param([Parameter(Mandatory)] [string] $Identity)

    $parameters = Get-CommandParameters -CommandName "Get-MailContact" -Parameters @{
        Identity = $Identity
        ErrorAction = "Stop"
    }
    return Get-MailContact @parameters
}

function Get-GroupByIdentity
{
    param([Parameter(Mandatory)] [string] $Identity)

    $parameters = Get-CommandParameters -CommandName "Get-DistributionGroup" -Parameters @{
        Identity = $Identity
        ErrorAction = "Stop"
    }
    return Get-DistributionGroup @parameters
}

function Get-RandomItem
{
    param([object[]] $Items)

    if ($null -eq $Items -or $Items.Count -eq 0)
    {
        return $null
    }
    return $Items[$script:Random.Next(0, $Items.Count)]
}

function New-RandomToken
{
    param([int] $Length = 10)

    $alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
    $builder = [Text.StringBuilder]::new($Length)
    for ($index = 0; $index -lt $Length; $index++)
    {
        [void]$builder.Append($alphabet[$script:Random.Next(0, $alphabet.Length)])
    }
    return $builder.ToString()
}

function New-EntityName
{
    param([Parameter(Mandatory)] [ValidateSet("Contact", "Group")] [string] $Kind)

    $shortKind = if ($Kind -eq "Contact") { "c" } else { "g" }
    if ($script:PopulationGeneration -gt 0)
    {
        return "$ObjectPrefix-r$($script:PopulationGeneration)-$shortKind-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
    }
    return "$ObjectPrefix-$shortKind-$(New-RandomToken -Length 12)"
}

function ConvertFrom-IsoUtc
{
    param([Parameter(Mandatory)] [string] $Value)

    return [DateTimeOffset]::Parse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
}

function ConvertTo-EntityRecord
{
    param(
        [Parameter(Mandatory)] [object] $Recipient,
        [Parameter(Mandatory)] [ValidateSet("Contact", "Group")] [string] $Kind)

    return [ordered]@{
        Identity = [string]$Recipient.Identity
        Name = [string]$Recipient.Name
        Guid = [Guid]$Recipient.Guid
        DistinguishedName = [string]$Recipient.DistinguishedName
        Kind = $Kind
        CreatedUtc = [datetime]::UtcNow.ToString("o")
        Members = @()
    }
}

function Write-AtomicJsonSnapshot
{
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $InputObject,
        [Parameter(Mandatory)] [int] $Depth)

    $temporaryPath = "{0}.{1}.{2}.tmp" -f $Path, $PID, ([Guid]::NewGuid().ToString("N"))
    $backupPath = "{0}.{1}.{2}.backup" -f $Path, $PID, ([Guid]::NewGuid().ToString("N"))
    $maximumAttempts = 20
    try
    {
        $InputObject | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++)
        {
            try
            {
                if (Test-Path -LiteralPath $Path)
                {
                    [IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
                }
                else
                {
                    Move-Item -LiteralPath $temporaryPath -Destination $Path -ErrorAction Stop
                }
                return
            }
            catch [IO.IOException]
            {
                if ($attempt -eq $maximumAttempts)
                {
                    throw
                }
                Start-Sleep -Milliseconds 100
            }
        }
    }
    finally
    {
        if (Test-Path -LiteralPath $temporaryPath)
        {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        if ((Test-Path -LiteralPath $backupPath) -and (Test-Path -LiteralPath $Path))
        {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-RunStatusSnapshot
{
    param([string] $Status)

    if ([string]::IsNullOrWhiteSpace($Status))
    {
        $Status = if ($script:StopRequested) { "PausedOnFailure" } else { "Running" }
    }

    $snapshot = [ordered]@{
        RunId = $script:RunId
        UpdatedUtc = [datetime]::UtcNow.ToString("o")
        ProcessId = $PID
        Status = $Status
        ScenarioCommand = if ($WorkloadMode -eq "ScenarioTest") { $ScenarioCommand } else { $null }
        ScenarioSetMode = if ($WorkloadMode -eq "ScenarioTest") { $ScenarioSetMode } else { $null }
        SharedPopulationVersion = if ($WorkloadMode -eq "ScenarioTest") { if ($script:LegacyCommandSpecificPopulation) { 0 } else { $script:ScenarioSharedPopulationVersion } } else { $null }
        LegacyCommandSpecificPopulation = if ($WorkloadMode -eq "ScenarioTest") { $script:LegacyCommandSpecificPopulation } else { $null }
        ScenarioEstimatedMinutes = if ($WorkloadMode -eq "ScenarioTest") { Get-ScenarioEstimatedMinutes } else { $null }
        PreflightEstimatedMinutes = if ($WorkloadMode -eq "ScenarioTest") { $script:ScenarioPreflightEstimatedMinutes } else { $null }
        PopulationEstimatedMinutes = if ($WorkloadMode -eq "ScenarioTest") { $script:ScenarioPopulationEstimatedMinutes } else { $null }
        EstimatedMinutes = if ($WorkloadMode -eq "ScenarioTest") { Get-ScenarioTotalEstimatedMinutes } else { $null }
        ScenarioBatchTotal = if ($WorkloadMode -eq "ScenarioTest") { @((Get-ScenarioCommandDefinition).PhaseNames).Count * $script:ScenarioBatchesPerPhase } else { $null }
        PopulationReused = if ($WorkloadMode -eq "ScenarioTest") { $script:PopulationReused } else { $null }
        PopulationImportCompleted = if ($WorkloadMode -eq "ScenarioTest") { $script:PopulationImportCompleted } else { $null }
        PopulationSourceRunDirectory = if ($WorkloadMode -eq "ScenarioTest") { $script:ResolvedPopulationSourceRunDirectory } else { $null }
        PopulationGeneration = if ($WorkloadMode -eq "ScenarioTest") { $script:PopulationGeneration } else { $null }
        DataInconsistentPopulation = if ($WorkloadMode -eq "ScenarioTest") { @($script:DataInconsistentPopulation.Values) } else { $null }
        PendingPopulationReplacement = if ($WorkloadMode -eq "ScenarioTest") { $script:PendingPopulationReplacement } else { $null }
        StopRequested = $script:StopRequested
        Failure = $script:Failure
        Counters = $script:Counters
        PendingValidationCount = $script:PendingValidations.Count
        ScenarioState = $script:ScenarioState
        LatestPhaseSummary = if ($script:ScenarioPhaseSummaries.Count -gt 0)
        {
            $script:ScenarioPhaseSummaries[$script:ScenarioPhaseSummaries.Count - 1]
        }
        else
        {
            $null
        }
    }
    Write-AtomicJsonSnapshot -Path $script:StatusPath -InputObject $snapshot -Depth 8
}

function Save-Checkpoint
{
    $state = [ordered]@{
        SchemaVersion = 2
        RunId = $script:RunId
        WorkloadMode = $WorkloadMode
        RandomSeed = $RandomSeed
        SavedUtc = [datetime]::UtcNow.ToString("o")
        Counters = $script:Counters
        Contacts = @($script:Contacts.Values)
        Groups = @($script:Groups.Values)
        PendingValidations = @($script:PendingValidations.Values)
        SupportingObjects = @($script:ScenarioSupportingObjects)
        ScenarioLogSegments = if ($WorkloadMode -eq "ScenarioTest") { $script:ScenarioLogSegments } else { $null }
        ScenarioLogNextIndex = if ($WorkloadMode -eq "ScenarioTest") { $script:ScenarioLogNextIndex } else { $null }
        ScenarioPlanVersion = if ($WorkloadMode -eq "ScenarioTest") { $script:ScenarioPlanVersion } else { $null }
        ScenarioBatchesPerPhase = if ($WorkloadMode -eq "ScenarioTest") { $script:ScenarioBatchesPerPhase } else { $null }
        ScenarioCommand = if ($WorkloadMode -eq "ScenarioTest") { $ScenarioCommand } else { $null }
        ScenarioSetMode = if ($WorkloadMode -eq "ScenarioTest") { $ScenarioSetMode } else { $null }
        SharedPopulationVersion = if ($WorkloadMode -eq "ScenarioTest") { if ($script:LegacyCommandSpecificPopulation) { 0 } else { $script:ScenarioSharedPopulationVersion } } else { $null }
        LegacyCommandSpecificPopulation = if ($WorkloadMode -eq "ScenarioTest") { $script:LegacyCommandSpecificPopulation } else { $null }
        PopulationReused = if ($WorkloadMode -eq "ScenarioTest") { $script:PopulationReused } else { $null }
        PopulationImportCompleted = if ($WorkloadMode -eq "ScenarioTest") { $script:PopulationImportCompleted } else { $null }
        PopulationSourceRunDirectory = if ($WorkloadMode -eq "ScenarioTest") { $script:ResolvedPopulationSourceRunDirectory } else { $null }
        PopulationGeneration = if ($WorkloadMode -eq "ScenarioTest") { $script:PopulationGeneration } else { $null }
        DataInconsistentPopulation = if ($WorkloadMode -eq "ScenarioTest") { @($script:DataInconsistentPopulation.Values) } else { $null }
        PendingPopulationReplacement = if ($WorkloadMode -eq "ScenarioTest") { $script:PendingPopulationReplacement } else { $null }
        PopulationReplacementHistory = if ($WorkloadMode -eq "ScenarioTest") { @($script:PopulationReplacementHistory) } else { $null }
        RetiredPopulationDistinguishedNames = if ($WorkloadMode -eq "ScenarioTest") { @($script:RetiredPopulationDistinguishedNames) } else { $null }
        ScenarioState = $script:ScenarioState
        ScenarioCompletedObjectWork = $script:ScenarioCompletedObjectWork
        ScenarioBatchSummaries = @($script:ScenarioBatchSummaries)
        ScenarioPhaseSummaries = @($script:ScenarioPhaseSummaries)
        Failure = $script:Failure
    }

    Write-AtomicJsonSnapshot -Path $script:CheckpointPath -InputObject $state -Depth 12
    $script:LastCheckpointUtc = [datetime]::UtcNow
    Write-RunStatusSnapshot
}

function Restore-ScenarioDataInconsistentPopulation
{
    param([AllowNull()] [object] $Entries)

    foreach ($entry in @($Entries))
    {
        if ($null -eq $entry)
        {
            continue
        }

        $propertyNames = @($entry.PSObject.Properties | ForEach-Object { $_.Name })
        if ($propertyNames.Count -eq 0)
        {
            Write-RunEvent -Level "Warning" -Message "Ignored an empty legacy DataInconsistentPopulation checkpoint entry."
            continue
        }
        if ($propertyNames -notcontains "Guid")
        {
            throw "DataInconsistentPopulation checkpoint entry is missing the required Guid property."
        }

        $entryGuid = [Guid]::Empty
        if (-not [Guid]::TryParse([string]$entry.Guid, [ref]$entryGuid))
        {
            throw "DataInconsistentPopulation checkpoint entry contains an invalid Guid."
        }

        $script:DataInconsistentPopulation[$entryGuid.ToString("D")] = $entry
    }
}

function Restore-Checkpoint
{
    if (-not (Test-Path -LiteralPath $script:CheckpointPath))
    {
        throw "Checkpoint not found: $($script:CheckpointPath)"
    }

    $state = Get-Content -LiteralPath $script:CheckpointPath -Raw | ConvertFrom-Json
    $checkpointWorkloadMode =
        if ($state.PSObject.Properties.Name -contains "WorkloadMode")
        {
            [string]$state.WorkloadMode
        }
        elseif ($state.PSObject.Properties.Name -contains "ScenarioPlanVersion" -and
            $null -ne $state.ScenarioPlanVersion -and
            [int]$state.ScenarioPlanVersion -gt 0)
        {
            "ScenarioTest"
        }
        else
        {
            $savedParametersPath = Join-Path $script:RunDirectory "parameters.json"
            if (Test-Path -LiteralPath $savedParametersPath)
            {
                $savedParameters = Get-Content -LiteralPath $savedParametersPath -Raw | ConvertFrom-Json
                if ($savedParameters.PSObject.Properties.Name -contains "WorkloadMode")
                {
                    [string]$savedParameters.WorkloadMode
                }
                else
                {
                    $null
                }
            }
            else
            {
                $null
            }
        }
    if (-not [string]::IsNullOrWhiteSpace($checkpointWorkloadMode) -and
        -not [string]::Equals($checkpointWorkloadMode, $WorkloadMode, [StringComparison]::OrdinalIgnoreCase))
    {
        throw "Checkpoint workload '$checkpointWorkloadMode' is incompatible with requested workload '$WorkloadMode'. Resume with the original -WorkloadMode value or start a new run."
    }
    if ($WorkloadMode -eq "ScenarioTest")
    {
        $checkpointPlanVersion = if ($state.PSObject.Properties.Name -contains "ScenarioPlanVersion")
        {
            [int]$state.ScenarioPlanVersion
        }
        else
        {
            0
        }
        $checkpointBatchesPerPhase = if ($state.PSObject.Properties.Name -contains "ScenarioBatchesPerPhase")
        {
            [int]$state.ScenarioBatchesPerPhase
        }
        else
        {
            0
        }
        if ($checkpointPlanVersion -ne $script:ScenarioPlanVersion -or
            $checkpointBatchesPerPhase -ne $script:ScenarioBatchesPerPhase)
        {
            throw "ScenarioTest checkpoint uses an incompatible phase plan (version $checkpointPlanVersion, $checkpointBatchesPerPhase batches per phase). Start a new run; the changed phase order and batch count cannot be resumed safely."
        }
        $checkpointSharedPopulationVersion =
            if ($state.PSObject.Properties.Name -contains "SharedPopulationVersion")
            {
                [int]$state.SharedPopulationVersion
            }
            else
            {
                0
            }
        if ($checkpointSharedPopulationVersion -eq 0)
        {
            $script:LegacyCommandSpecificPopulation = $true
            $legacyIncludesUsers = $ScenarioCommand -in @("User-Upsert", "User-Properties-Deletion", "Run-All-OBScenarios")
            $legacyIncludesGroups = $ScenarioCommand -in @("Group-Upsert", "Group-Properties-Deletion", "Run-All-OBScenarios")
            $script:ScenarioCounts.N_User =
                if ($legacyIncludesUsers)
                {
                    [Math]::Max(
                        [int]$script:ScenarioCounts.N_URP_U,
                        [Math]::Max(
                            [int]$script:ScenarioCounts.N_ULP_U,
                            [Math]::Max(
                                [int]$script:ScenarioCounts.N_URP_D,
                                [int]$script:ScenarioCounts.N_ULP_D)))
                }
                else
                {
                    0
                }
            $script:ScenarioCounts.N_Groups =
                if ($legacyIncludesGroups)
                {
                    [Math]::Max(
                        [int]$script:ScenarioCounts.N_GRP_U,
                        [Math]::Max(
                            [int]$script:ScenarioCounts.N_GLP_U,
                            [Math]::Max(
                                [int]$script:ScenarioCounts.N_GRP_D,
                                [int]$script:ScenarioCounts.N_GLP_D)))
                }
                else
                {
                    0
                }
        }
        elseif ($state.PSObject.Properties.Name -contains "LegacyCommandSpecificPopulation")
        {
            $script:LegacyCommandSpecificPopulation = [bool]$state.LegacyCommandSpecificPopulation
        }
        if (-not [string]::IsNullOrWhiteSpace($PopulationSourceRunDirectory) -and
            $checkpointSharedPopulationVersion -ne $script:ScenarioSharedPopulationVersion)
        {
            throw "ScenarioTest checkpoint shared-population version '$checkpointSharedPopulationVersion' is incompatible with version '$($script:ScenarioSharedPopulationVersion)'. Start a new run."
        }
        $checkpointScenarioCommand =
            if ($state.PSObject.Properties.Name -contains "ScenarioCommand")
            {
                ConvertTo-CurrentScenarioCommandName -Value ([string]$state.ScenarioCommand)
            }
            else
            {
                "Run-All-OBScenarios"
            }
        if (-not [string]::Equals($checkpointScenarioCommand, $ScenarioCommand, [StringComparison]::OrdinalIgnoreCase))
        {
            throw "ScenarioTest checkpoint command '$checkpointScenarioCommand' is incompatible with requested command '$ScenarioCommand'. Resume with the original command or start a new run."
        }
        $checkpointScenarioSetMode =
            if ($state.PSObject.Properties.Name -contains "ScenarioSetMode" -and
                -not [string]::IsNullOrWhiteSpace([string]$state.ScenarioSetMode))
            {
                [string]$state.ScenarioSetMode
            }
            elseif ($checkpointBatchesPerPhase -eq 1)
            {
                "MiniSet"
            }
            else
            {
                "Full"
            }
        if (-not [string]::Equals($checkpointScenarioSetMode, $ScenarioSetMode, [StringComparison]::OrdinalIgnoreCase))
        {
            throw "ScenarioTest checkpoint set mode '$checkpointScenarioSetMode' is incompatible with requested mode '$ScenarioSetMode'. Resume with the original -ScenarioSetMode value or start a new run."
        }
        if ([int]$state.RandomSeed -ne $RandomSeed)
        {
            throw "ScenarioTest checkpoint random seed '$($state.RandomSeed)' is incompatible with requested seed '$RandomSeed'. Resume with the original -RandomSeed value or start a new run."
        }
    }
    foreach ($contact in @($state.Contacts))
    {
        $script:Contacts[[string]$contact.Identity] = $contact
    }
    foreach ($group in @($state.Groups))
    {
        $group.Members = @($group.Members)
        $script:Groups[[string]$group.Identity] = $group
    }
    foreach ($validation in @($state.PendingValidations))
    {
        $script:PendingValidations[[string]$validation.Guid] = $validation
    }

    if ($state.PSObject.Properties.Name -contains "SupportingObjects")
    {
        foreach ($supportingObject in @($state.SupportingObjects))
        {
            $script:ScenarioSupportingObjects.Add($supportingObject)
        }
    }
    if ($state.PSObject.Properties.Name -contains "ScenarioLogSegments" -and $null -ne $state.ScenarioLogSegments)
    {
        foreach ($key in @($script:ScenarioLogSegments.Keys))
        {
            if ($state.ScenarioLogSegments.PSObject.Properties.Name -contains $key)
            {
                foreach ($segment in @($state.ScenarioLogSegments.$key))
                {
                    Add-ScenarioLogSegment -Key $key -Path ([string]$segment)
                }
            }
        }
    }
    if ($state.PSObject.Properties.Name -contains "ScenarioLogNextIndex" -and $null -ne $state.ScenarioLogNextIndex)
    {
        $restoredLogIndexNames = @(
            $state.ScenarioLogNextIndex.PSObject.Properties |
                ForEach-Object { $_.Name }
        )
        foreach ($key in @($script:ScenarioLogNextIndex.Keys))
        {
            if ($restoredLogIndexNames -contains $key)
            {
                $script:ScenarioLogNextIndex[$key] = [math]::Max(
                    [int]$script:ScenarioLogNextIndex[$key],
                    [int]$state.ScenarioLogNextIndex.$key)
            }
        }
    }
    if ($state.PSObject.Properties.Name -contains "ScenarioState" -and $null -ne $state.ScenarioState)
    {
        foreach ($propertyName in @("NextPhaseIndex", "NextBatchIndex", "CurrentBatch", "CurrentBatchCompletedGuids"))
        {
            if ($state.ScenarioState.PSObject.Properties.Name -contains $propertyName)
            {
                $script:ScenarioState[$propertyName] = $state.ScenarioState.$propertyName
            }
        }
        $script:ScenarioState.CurrentBatchCompletedGuids = @($script:ScenarioState.CurrentBatchCompletedGuids)
    }
    if ($state.PSObject.Properties.Name -contains "ScenarioBatchSummaries")
    {
        foreach ($summary in @($state.ScenarioBatchSummaries))
        {
            $script:ScenarioBatchSummaries.Add($summary)
        }
    }
    if ($state.PSObject.Properties.Name -contains "ScenarioPhaseSummaries")
    {
        foreach ($summary in @($state.ScenarioPhaseSummaries))
        {
            $script:ScenarioPhaseSummaries.Add($summary)
        }
    }
    if ($state.PSObject.Properties.Name -contains "ScenarioCompletedObjectWork")
    {
        $script:ScenarioCompletedObjectWork = [long]$state.ScenarioCompletedObjectWork
    }
    if ($state.PSObject.Properties.Name -contains "PopulationReused")
    {
        $script:PopulationReused = [bool]$state.PopulationReused
    }
    if ($state.PSObject.Properties.Name -contains "PopulationSourceRunDirectory")
    {
        $script:ResolvedPopulationSourceRunDirectory = [string]$state.PopulationSourceRunDirectory
    }
    if ($state.PSObject.Properties.Name -contains "PopulationImportCompleted")
    {
        $script:PopulationImportCompleted = [bool]$state.PopulationImportCompleted
    }
    if ($state.PSObject.Properties.Name -contains "PopulationGeneration")
    {
        $script:PopulationGeneration = [int]$state.PopulationGeneration
    }
    if ($state.PSObject.Properties.Name -contains "DataInconsistentPopulation")
    {
        Restore-ScenarioDataInconsistentPopulation -Entries $state.DataInconsistentPopulation
    }
    if ($state.PSObject.Properties.Name -contains "PendingPopulationReplacement")
    {
        if ($null -eq $state.PendingPopulationReplacement)
        {
            $script:PendingPopulationReplacement = $null
        }
        else
        {
            $replacement = [ordered]@{}
            foreach ($property in $state.PendingPopulationReplacement.PSObject.Properties)
            {
                $replacement[$property.Name] = $property.Value
            }
            $script:PendingPopulationReplacement = $replacement
        }
    }
    if ($state.PSObject.Properties.Name -contains "PopulationReplacementHistory")
    {
        foreach ($entry in @($state.PopulationReplacementHistory))
        {
            $script:PopulationReplacementHistory.Add($entry)
        }
    }
    if ($state.PSObject.Properties.Name -contains "RetiredPopulationDistinguishedNames")
    {
        foreach ($distinguishedName in @($state.RetiredPopulationDistinguishedNames))
        {
            [void]$script:RetiredPopulationDistinguishedNames.Add([string]$distinguishedName)
        }
    }

    foreach ($property in $state.Counters.PSObject.Properties)
    {
        $script:Counters[$property.Name] = [long]$property.Value
    }
}

function Initialize-ScenarioPopulationIdentities
{
    if ($script:ScenarioPopulationIdentitiesValidated)
    {
        Save-Checkpoint
        return
    }

    foreach ($entity in @($script:Contacts.Values) + @($script:Groups.Values))
    {
        [void](Set-ScenarioEntityDistinguishedName -Entity $entity)
    }
    Save-Checkpoint
}

function Assert-ScenarioResumeParameters
{
    $parametersPath = Join-Path $script:RunDirectory "parameters.json"
    if (-not (Test-Path -LiteralPath $parametersPath))
    {
        throw "ScenarioTest resume parameters are missing: $parametersPath"
    }

    $saved = Get-Content -LiteralPath $parametersPath -Raw | ConvertFrom-Json
    $savedPropertyNames = @(
        $saved.PSObject.Properties |
            ForEach-Object { $_.Name }
    )
    $savedScenarioCommand =
        if ($savedPropertyNames -contains "ScenarioCommand" -and
            -not [string]::IsNullOrWhiteSpace([string]$saved.ScenarioCommand))
        {
            ConvertTo-CurrentScenarioCommandName -Value ([string]$saved.ScenarioCommand)
        }
        else
        {
            "Run-All-OBScenarios"
        }
    $savedScenarioSetMode =
        if ($savedPropertyNames -contains "ScenarioSetMode" -and
            -not [string]::IsNullOrWhiteSpace([string]$saved.ScenarioSetMode))
        {
            [string]$saved.ScenarioSetMode
        }
        else
        {
            $checkpointPath = Join-Path $script:RunDirectory "checkpoint.json"
            if (Test-Path -LiteralPath $checkpointPath)
            {
                $checkpoint = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
                if ($checkpoint.PSObject.Properties.Name -contains "ScenarioBatchesPerPhase" -and
                    [int]$checkpoint.ScenarioBatchesPerPhase -eq 1)
                {
                    "MiniSet"
                }
                else
                {
                    "Full"
                }
            }
            else
            {
                "Full"
            }
        }
    $savedWorkloadMode =
        if ($savedPropertyNames -contains "WorkloadMode" -and
            -not [string]::IsNullOrWhiteSpace([string]$saved.WorkloadMode))
        {
            [string]$saved.WorkloadMode
        }
        else
        {
            $checkpointPath = Join-Path $script:RunDirectory "checkpoint.json"
            if (Test-Path -LiteralPath $checkpointPath)
            {
                $checkpoint = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
                if ($checkpoint.PSObject.Properties.Name -contains "ScenarioPlanVersion" -and
                    $null -ne $checkpoint.ScenarioPlanVersion -and
                    [int]$checkpoint.ScenarioPlanVersion -gt 0)
                {
                    "ScenarioTest"
                }
            }
        }
    if ([string]::IsNullOrWhiteSpace($savedWorkloadMode))
    {
        throw "ScenarioTest resume parameters do not identify the original workload. Start a new run rather than guessing."
    }
    $mismatches = [Collections.Generic.List[string]]::new()
    $stringChecks = @(
        [ordered]@{ Name = "WorkloadMode"; Saved = $savedWorkloadMode; Requested = $WorkloadMode; CaseSensitive = $false }
        [ordered]@{ Name = "ScenarioCommand"; Saved = $savedScenarioCommand; Requested = $ScenarioCommand; CaseSensitive = $false }
        [ordered]@{ Name = "ScenarioSetMode"; Saved = $savedScenarioSetMode; Requested = $ScenarioSetMode; CaseSensitive = $false }
        [ordered]@{ Name = "ObjectPrefix"; Saved = [string]$saved.ObjectPrefix; Requested = $ObjectPrefix; CaseSensitive = $true }
        [ordered]@{ Name = "Organization"; Saved = [string]$saved.Organization; Requested = $Organization; CaseSensitive = $false }
        [ordered]@{ Name = "Side"; Saved = [string]$saved.Side; Requested = $Side; CaseSensitive = $false }
        [ordered]@{ Name = "ObjectStoreDestination"; Saved = [string]$saved.ObjectStoreDestination; Requested = $ObjectStoreDestination; CaseSensitive = $false }
    )
    if ($WorkloadMode -eq "ScenarioTest")
    {
        $savedPopulationSourceRunDirectory =
            if ($savedPropertyNames -contains "PopulationSourceRunDirectory")
            {
                [string]$saved.PopulationSourceRunDirectory
            }
            else
            {
                $null
            }
        $stringChecks += [ordered]@{
            Name = "PopulationSourceRunDirectory"
            Saved = $savedPopulationSourceRunDirectory
            Requested = $PopulationSourceRunDirectory
            CaseSensitive = $false
        }
        if ($savedPropertyNames -contains "ScenarioRuntimeDependencyRoot" -and
            -not [string]::IsNullOrWhiteSpace([string]$saved.ScenarioRuntimeDependencyRoot))
        {
            $stringChecks += [ordered]@{ Name = "ScenarioRuntimeDependencyRoot"; Saved = [string]$saved.ScenarioRuntimeDependencyRoot; Requested = $ScenarioRuntimeDependencyRoot; CaseSensitive = $false }
        }
        if ($savedPropertyNames -contains "CompareSetupScript")
        {
            $stringChecks += [ordered]@{
                Name = "CompareSetupScript"
                Saved = [string]$saved.CompareSetupScript
                Requested = $CompareSetupScript
                CaseSensitive = $false
            }
        }
    }
    foreach ($check in $stringChecks)
    {
        $comparison = if ($check.CaseSensitive) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
        if (-not [string]::Equals([string]$check.Saved, [string]$check.Requested, $comparison))
        {
            $mismatches.Add("$($check.Name) ('$($check.Saved)' != '$($check.Requested)')")
        }
    }
    if ([int]$saved.RandomSeed -ne $RandomSeed)
    {
        $mismatches.Add("RandomSeed ('$($saved.RandomSeed)' != '$RandomSeed')")
    }
    if ([bool]$saved.WhatIfTraffic -ne [bool]$WhatIfTraffic)
    {
        $mismatches.Add("WhatIfTraffic ('$([bool]$saved.WhatIfTraffic)' != '$([bool]$WhatIfTraffic)')")
    }
    $savedCleanupOnSuccess =
        if ($savedPropertyNames -contains "CleanupOnSuccess")
        {
            [bool]$saved.CleanupOnSuccess
        }
        else
        {
            $false
        }
    if ($savedCleanupOnSuccess -ne [bool]$CleanupOnSuccess)
    {
        $mismatches.Add("CleanupOnSuccess ('$savedCleanupOnSuccess' != '$([bool]$CleanupOnSuccess)')")
    }
    if ($mismatches.Count -gt 0)
    {
        throw "ScenarioTest resume parameters are incompatible: $($mismatches -join '; '). Use the original values or start a new run."
    }
}

function Initialize-RunDirectory
{
    if (-not [string]::IsNullOrWhiteSpace($ResumeRunDirectory))
    {
        $script:RunDirectory = (Resolve-Path -LiteralPath $ResumeRunDirectory).Path
        $script:RunId = Split-Path -Leaf $script:RunDirectory
        Assert-ScenarioResumeParameters
    }
    else
    {
        $script:RunId = "{0}-{1}-{2}" -f `
            ([datetime]::UtcNow.ToString("yyyyMMdd-HHmmssfff")), `
            $RandomSeed, `
            ([guid]::NewGuid().ToString("N").Substring(0, 8))
        $script:RunDirectory = Join-Path $OutputRoot $script:RunId
        New-Item -Path $script:RunDirectory -ItemType Directory -Force | Out-Null
    }

    $script:OperationLogPath = Join-Path $script:RunDirectory "operations.jsonl"
    $script:ReadableOperationLogPath = Join-Path $script:RunDirectory "operations.log"
    $script:ValidationLogPath = Join-Path $script:RunDirectory "validations.jsonl"
    $script:EventLogPath = Join-Path $script:RunDirectory "events.jsonl"
    $scenarioLogFiles = @(Get-ChildItem -LiteralPath $script:RunDirectory -Filter "scenario-details-*.jsonl" -File -ErrorAction SilentlyContinue)
    $script:ScenarioDetailLogIndex = 1
    foreach ($scenarioLogFile in $scenarioLogFiles)
    {
        if ($scenarioLogFile.Name -match "scenario-details-(\d+)\.jsonl")
        {
            $script:ScenarioDetailLogIndex = [math]::Max($script:ScenarioDetailLogIndex, ([int]$Matches[1]))
        }
    }
    $script:ScenarioDetailLogPath = Join-Path $script:RunDirectory ("scenario-details-{0:D4}.jsonl" -f $script:ScenarioDetailLogIndex)
    $script:CheckpointPath = Join-Path $script:RunDirectory "checkpoint.json"
    $script:StatusPath = Join-Path $script:RunDirectory "status.json"
    $script:PausedMarkerPath = Join-Path $script:RunDirectory "PAUSED"
    if ($WorkloadMode -eq "ScenarioTest")
    {
        Initialize-ScenarioLogRotationState
    }

    if (-not (Test-Path -LiteralPath $script:OperationLogPath))
    {
        New-Item -Path $script:OperationLogPath -ItemType File | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:ReadableOperationLogPath))
    {
        New-Item -Path $script:ReadableOperationLogPath -ItemType File | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:ValidationLogPath))
    {
        New-Item -Path $script:ValidationLogPath -ItemType File | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:EventLogPath))
    {
        New-Item -Path $script:EventLogPath -ItemType File | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($ResumeRunDirectory))
    {
        Restore-Checkpoint
    }

    $parameters = [ordered]@{
        WorkloadMode = $WorkloadMode
        ScenarioCommand = if ($WorkloadMode -eq "ScenarioTest") { $ScenarioCommand } else { $null }
        ScenarioSetMode = if ($WorkloadMode -eq "ScenarioTest") { $ScenarioSetMode } else { $null }
        SharedPopulationVersion = if ($WorkloadMode -eq "ScenarioTest") { if ($script:LegacyCommandSpecificPopulation) { 0 } else { $script:ScenarioSharedPopulationVersion } } else { $null }
        LegacyCommandSpecificPopulation = if ($WorkloadMode -eq "ScenarioTest") { $script:LegacyCommandSpecificPopulation } else { $null }
        ScenarioEstimatedMinutes = if ($WorkloadMode -eq "ScenarioTest") { Get-ScenarioEstimatedMinutes } else { $null }
        PreflightEstimatedMinutes = if ($WorkloadMode -eq "ScenarioTest") { $script:ScenarioPreflightEstimatedMinutes } else { $null }
        PopulationEstimatedMinutes = if ($WorkloadMode -eq "ScenarioTest") { $script:ScenarioPopulationEstimatedMinutes } else { $null }
        EstimatedMinutes = if ($WorkloadMode -eq "ScenarioTest") { Get-ScenarioTotalEstimatedMinutes } else { $null }
        DurationHours = $DurationHours
        OperationsPerSecond = $OperationsPerSecond
        InitialRecipientCount = $InitialRecipientCount
        InitialGroupCount = $InitialGroupCount
        CoverageRecipientCount = $CoverageRecipientCount
        CoverageGroupCount = $CoverageGroupCount
        MaximumRecipientCount = $MaximumRecipientCount
        MaximumGroupCount = $MaximumGroupCount
        ConvergenceDelaySeconds = $ConvergenceDelaySeconds
        ValidationTimeoutSeconds = $ValidationTimeoutSeconds
        CompareCookieReadTimeoutSeconds = $CompareCookieReadTimeoutSeconds
        ScenarioTargetQueryTimeoutSeconds = $ScenarioTargetQueryTimeoutSeconds
        ValidationBatchSize = $ValidationBatchSize
        CheckpointIntervalSeconds = $CheckpointIntervalSeconds
        RandomSeed = $RandomSeed
        ObjectPrefix = $ObjectPrefix
        Organization = $Organization
        Side = $Side
        ObjectStoreDestination = $ObjectStoreDestination
        ScenarioRuntimeDependencyRoot = if ($WorkloadMode -eq "ScenarioTest") { $ScenarioRuntimeDependencyRoot } else { $null }
        CompareSetupScript = if ($WorkloadMode -eq "ScenarioTest") { $CompareSetupScript } else { $null }
        ConfigureEnvironment = [bool]$ConfigureEnvironment
        SkipDeletionOperations = [bool]$SkipDeletionOperations
        PreflightOnly = [bool]$PreflightOnly
        WhatIfTraffic = [bool]$WhatIfTraffic
        CleanupOnSuccess = [bool]$CleanupOnSuccess
        PopulationSourceRunDirectory = if ($WorkloadMode -eq "ScenarioTest") { $PopulationSourceRunDirectory } else { $null }
        PopulationImportCompleted = if ($WorkloadMode -eq "ScenarioTest") { $script:PopulationImportCompleted } else { $null }
        PopulationGeneration = if ($WorkloadMode -eq "ScenarioTest") { $script:PopulationGeneration } else { $null }
        ScenarioCounts = $script:ScenarioCounts
    }
    $parameters | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:RunDirectory "parameters.json") -Encoding UTF8
}

function Test-IsAdministrator
{
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ScenarioForestFqdn
{
    $rootDse = Get-ADRootDSE -ErrorAction Stop
    $rootNamingContextProperty = $rootDse.PSObject.Properties["rootDomainNamingContext"]
    if ($null -eq $rootNamingContextProperty)
    {
        throw "Get-ADRootDSE did not return rootDomainNamingContext."
    }

    $rootNamingContext = [string]$rootNamingContextProperty.Value
    if ([string]::IsNullOrWhiteSpace($rootNamingContext))
    {
        throw "rootDomainNamingContext is empty."
    }

    $forestFqdn = (($rootNamingContext -replace "(?i)\bDC=", "") -replace "\s*,\s*", ".").Trim(". ")
    if ([string]::IsNullOrWhiteSpace($forestFqdn) -or $forestFqdn -notmatch "\.")
    {
        throw "Could not derive a forest FQDN from rootDomainNamingContext '$rootNamingContext'."
    }
    return $forestFqdn
}

function Get-ScenarioExceptionChain
{
    param([Parameter(Mandatory)] [Exception] $Exception)

    $messages = [Collections.Generic.List[string]]::new()
    $current = $Exception
    while ($null -ne $current)
    {
        $message = [string]$current.Message
        if (-not [string]::IsNullOrWhiteSpace($message))
        {
            [void]$messages.Add($message.Trim())
        }
        $current = $current.InnerException
    }

    $result = $messages -join " --> "
    if ($result.Length -gt 2048)
    {
        $result = $result.Substring(0, 2048) + "...[truncated]"
    }
    return $result
}

function Initialize-ScenarioCookieQueryContext
{
    if ($WorkloadMode -ne "ScenarioTest" -or $script:ScenarioCookieQueryContextReady)
    {
        return
    }

    try
    {
        $partitions = @(Get-AccountPartition -ErrorAction Stop)
        if ($partitions.Count -eq 0)
        {
            throw "Get-AccountPartition returned no account partitions."
        }

        $script:ScenarioCookieQueryContextReady = $true
        Write-RunEvent -Level "Information" -Message "Initialized Exchange directory context for ScenarioTest sync-cookie reads." -Data @{
            AccountPartitionCount = $partitions.Count
            AccountPartitions = @($partitions | ForEach-Object { [string]$_.Name })
        }
    }
    catch
    {
        $details = Get-ScenarioExceptionChain -Exception $_.Exception
        Write-RunEvent -Level "Error" -Message "Failed to initialize Exchange directory context for ScenarioTest sync-cookie reads." -Data @{
            Exception = $details
        }
        throw "Could not initialize the Exchange directory context required for ScenarioTest sync-cookie reads: $details"
    }
}

function Get-ScenarioSyncCookieRecords
{
    param([Parameter(Mandatory)] [string] $ForestFqdn)

    $accountPartition = ([string]$ForestFqdn).Trim()
    if ([string]::IsNullOrWhiteSpace($accountPartition))
    {
        throw "The forest FQDN used for Object Store sync-cookie lookup is empty."
    }

    if ($WorkloadMode -ne "ScenarioTest")
    {
        return @(Get-DirectoryObjectStoreSyncCookie `
            -AccountPartition $accountPartition `
            -IsReadFromObjectStore:$true `
            -ErrorAction Stop)
    }

    Initialize-ScenarioCookieQueryContext

    $lastFailureDetails = $null
    $sawFailure = $false
    for ($attempt = 1; $attempt -le 3; $attempt++)
    {
        $attemptWarnings = @()
        $attemptErrors = @()
        try
        {
            $records = @(Get-DirectoryObjectStoreSyncCookie `
                -AccountPartition $accountPartition `
                -IsReadFromObjectStore:$true `
                -ErrorAction Stop `
                -WarningVariable attemptWarnings `
                -ErrorVariable attemptErrors)
            $warningDetails = @($attemptWarnings | ForEach-Object { [string]$_ })
            $errorDetails = @($attemptErrors | ForEach-Object {
                if ($null -ne $_.Exception)
                {
                    Get-ScenarioExceptionChain -Exception $_.Exception
                }
                else
                {
                    [string]$_
                }
            })
            $hasDiagnostics = $warningDetails.Count -gt 0 -or $errorDetails.Count -gt 0
            if ($records.Count -gt 0)
            {
                if (-not $hasDiagnostics)
                {
                    return $records
                }

                $sawFailure = $true
                $lastFailureDetails = (@($warningDetails + $errorDetails) -join " | ")
                Write-RunEvent -Level "Warning" -Message "ScenarioTest sync-cookie query returned records with diagnostics; retrying." -Data @{
                    Attempt = $attempt
                    MaximumAttempts = 3
                    ForestFqdn = $accountPartition
                    Warnings = $warningDetails
                    Errors = $errorDetails
                }
            }
            elseif ($hasDiagnostics)
            {
                $sawFailure = $true
                $lastFailureDetails = (@($warningDetails + $errorDetails) -join " | ")
                Write-RunEvent -Level "Warning" -Message "ScenarioTest sync-cookie query returned no records with diagnostics; retrying." -Data @{
                    Attempt = $attempt
                    MaximumAttempts = 3
                    ForestFqdn = $accountPartition
                    Warnings = $warningDetails
                    Errors = $errorDetails
                }
            }
            else
            {
                Write-RunEvent -Level "Warning" -Message "ScenarioTest sync-cookie query returned no records; retrying." -Data @{
                    Attempt = $attempt
                    MaximumAttempts = 3
                    ForestFqdn = $accountPartition
                }
            }
        }
        catch
        {
            $sawFailure = $true
            $lastFailureDetails = Get-ScenarioExceptionChain -Exception $_.Exception
            Write-RunEvent -Level "Warning" -Message "ScenarioTest sync-cookie query failed; retrying." -Data @{
                Attempt = $attempt
                MaximumAttempts = 3
                ForestFqdn = $accountPartition
                Exception = $lastFailureDetails
            }
        }

        if ($attempt -lt 3)
        {
            Start-Sleep -Seconds 2
        }
    }

    if ($sawFailure)
    {
        if ([string]::IsNullOrWhiteSpace([string]$lastFailureDetails))
        {
            $lastFailureDetails = "The cmdlet emitted diagnostics without an exception message."
        }
        throw "Get-DirectoryObjectStoreSyncCookie failed for forest '$accountPartition' after 3 attempts: $lastFailureDetails"
    }

    return @()
}

function Get-ScenarioSyncCookieIndex
{
    param([object[]] $Cookies = @())

    $index = @{}
    foreach ($cookie in @($Cookies))
    {
        if ($null -eq $cookie)
        {
            continue
        }

        $dataType = [string]$cookie.DataType
        $side = [string]$cookie.Side
        if ([string]::IsNullOrWhiteSpace($dataType) -or [string]::IsNullOrWhiteSpace($side))
        {
            continue
        }

        $key = "{0}|{1}" -f $side.Trim().ToUpperInvariant(), $dataType.Trim().ToUpperInvariant()
        if (-not $index.ContainsKey($key))
        {
            $index[$key] = $cookie
        }
    }
    return $index
}

function Test-ScenarioSyncCookieReadiness
{
    param(
        [Parameter(Mandatory)] [hashtable] $CookieIndex,
        [string[]] $Sides = @("A", "B"),
        [string[]] $DataTypes = @("Recipients", "Links", "TenantConfig"))

    $missing = [Collections.Generic.List[string]]::new()
    $notFullSync = [Collections.Generic.List[string]]::new()
    foreach ($side in @($Sides))
    {
        foreach ($dataType in @($DataTypes))
        {
            $key = "{0}|{1}" -f ([string]$side).Trim().ToUpperInvariant(), ([string]$dataType).Trim().ToUpperInvariant()
            if (-not $CookieIndex.ContainsKey($key))
            {
                [void]$missing.Add("$dataType/$side")
                continue
            }

            $cookie = $CookieIndex[$key]
            if (-not (ConvertTo-ScenarioBoolean $cookie.DirSyncFinishedFullSync))
            {
                [void]$notFullSync.Add("$dataType/$side")
            }
        }
    }
    return [ordered]@{
        Passed = $missing.Count -eq 0 -and $notFullSync.Count -eq 0
        Missing = $missing.ToArray()
        NotFullSync = $notFullSync.ToArray()
    }
}

function Test-ScenarioSyntheticSyncCookieIndex
{
    $syntheticCookies = @(
        [pscustomobject]@{ DataType = "Recipients"; Side = "A"; DirSyncFinishedFullSync = $true }
        [pscustomobject]@{ DataType = "Recipients"; Side = "B"; DirSyncFinishedFullSync = $true }
        [pscustomobject]@{ DataType = "Links"; Side = "A"; DirSyncFinishedFullSync = $true }
        [pscustomobject]@{ DataType = "Links"; Side = "B"; DirSyncFinishedFullSync = $true }
        [pscustomobject]@{ DataType = "TenantConfig"; Side = "A"; DirSyncFinishedFullSync = $true }
        [pscustomobject]@{ DataType = "TenantConfig"; Side = "B"; DirSyncFinishedFullSync = $true }
    )
    $index = Get-ScenarioSyncCookieIndex -Cookies $syntheticCookies
    $readiness = Test-ScenarioSyncCookieReadiness -CookieIndex $index
    if (-not $readiness.Passed -or $index.Count -ne 6)
    {
        throw "Synthetic ScenarioTest sync-cookie indexing failed. Keys: $($index.Keys -join ', '); Missing: $($readiness.Missing -join ', '); NotFullSync: $($readiness.NotFullSync -join ', ')."
    }
    Write-RunEvent -Level "Information" -Message "Synthetic ScenarioTest sync-cookie indexing test passed." -Data @{
        CookieCount = $index.Count
        CookieKeys = @($index.Keys | Sort-Object)
    }
}

function ConvertTo-ScenarioPowerShellLiteral
{
    param([Parameter(Mandatory)] [string] $Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-ScenarioCompareCookieForSideWithTimeout
{
    param(
        [Parameter(Mandatory)] [string] $ForestFqdn,
        [Parameter(Mandatory)] [ValidateSet("A", "B")] [string] $Side)

    $compareSetupPath = (Resolve-Path -LiteralPath $CompareSetupScript -ErrorAction Stop).Path
    $powershellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $powershellPath))
    {
        $powershellCommand = Get-Command "powershell.exe" -ErrorAction Stop
        $powershellPath = [string]$powershellCommand.Source
    }

    $childScript = @'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try
{
    Add-PSSnapin *e2010* -ErrorAction Stop
    . __COMPARE_SETUP__
    $key = NewCompareCookieKey __FOREST__ __SIDE__
    $value = [Microsoft.Exchange.Data.DirectoryObjectStore.CompareCookieHelper]::GetCompareCookieValueWithCookieKey($key)
    if ($value -is [System.Threading.Tasks.Task])
    {
        $value = $value.GetAwaiter().GetResult()
    }

    if ($null -eq $value)
    {
        [ordered]@{ Found = $false } | ConvertTo-Json -Compress
    }
    else
    {
        [ordered]@{
            Found = $true
            StartGuid = [string]$value.StartGuid
            CompareStatus = [string]$value.CompareStatus
            Version = [string]$value.Version
        } | ConvertTo-Json -Compress
    }
    exit 0
}
catch
{
    $messages = [Collections.Generic.List[string]]::new()
    $current = $_.Exception
    while ($null -ne $current)
    {
        if (-not [string]::IsNullOrWhiteSpace([string]$current.Message))
        {
            [void]$messages.Add(([string]$current.Message).Trim())
        }
        $current = $current.InnerException
    }
    [ordered]@{ Found = $false; Error = ($messages -join " --> ") } | ConvertTo-Json -Compress
    exit 2
}
'@
    $childScript = $childScript.Replace("__COMPARE_SETUP__", (ConvertTo-ScenarioPowerShellLiteral -Value $compareSetupPath))
    $childScript = $childScript.Replace("__FOREST__", (ConvertTo-ScenarioPowerShellLiteral -Value $ForestFqdn))
    $childScript = $childScript.Replace("__SIDE__", (ConvertTo-ScenarioPowerShellLiteral -Value $Side))
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $powershellPath
    $startInfo.Arguments = "-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try
    {
        if (-not $process.Start())
        {
            throw "Could not start the Windows PowerShell compare-cookie reader."
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timeoutMilliseconds = [int]([math]::Min([int]::MaxValue, $CompareCookieReadTimeoutSeconds * 1000))
        if (-not $process.WaitForExit($timeoutMilliseconds))
        {
            $processId = $process.Id
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            throw [TimeoutException]::new("Compare-cookie read for side '$Side' exceeded $CompareCookieReadTimeoutSeconds seconds in child process $processId.")
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $diagnostics = (([string]$stdout).Trim() + " " + ([string]$stderr).Trim()).Trim()
        if ($diagnostics.Length -gt 4096)
        {
            $diagnostics = $diagnostics.Substring(0, 4096) + "...[truncated]"
        }

        if ($process.ExitCode -ne 0)
        {
            throw "Compare-cookie child process exited with code $($process.ExitCode): $diagnostics"
        }
        if ([string]::IsNullOrWhiteSpace([string]$stdout))
        {
            throw "Compare-cookie child process returned no result. Diagnostics: $diagnostics"
        }

        try
        {
            $result = ConvertFrom-Json -InputObject $stdout
        }
        catch
        {
            throw "Compare-cookie child process returned invalid JSON. Diagnostics: $diagnostics"
        }

        $errorProperty = $result.PSObject.Properties["Error"]
        if ($null -ne $errorProperty -and -not [string]::IsNullOrWhiteSpace([string]$errorProperty.Value))
        {
            throw "Compare-cookie helper failed: $($errorProperty.Value)"
        }
        return $result
    }
    finally
    {
        if ($null -ne $process)
        {
            $process.Dispose()
        }
    }
}

function Test-ScenarioCompareCookieReadiness
{
    param([Parameter(Mandatory)] [string] $ForestFqdn)

    if ($null -eq (Get-Command "GetCompareCookieForSide" -ErrorAction SilentlyContinue))
    {
        throw "CompareAndRepairSetup.ps1 did not provide GetCompareCookieForSide."
    }

    $missing = [Collections.Generic.List[string]]::new()
    $invalid = [Collections.Generic.List[string]]::new()
    foreach ($side in @("A", "B"))
    {
        $readStartedUtc = [datetime]::UtcNow
        Write-RunEvent -Level "Information" -Message "Starting ScenarioTest compare-cookie read." -Data @{
            ForestFqdn = $ForestFqdn
            Side = $side
            TimeoutSeconds = $CompareCookieReadTimeoutSeconds
        }

        try
        {
            $cookie = Get-ScenarioCompareCookieForSideWithTimeout -ForestFqdn ([string]$ForestFqdn) -Side $side
        }
        catch
        {
            $elapsedMilliseconds = [math]::Round(([datetime]::UtcNow - $readStartedUtc).TotalMilliseconds, 0)
            $details = Get-ScenarioExceptionChain -Exception $_.Exception
            Write-RunEvent -Level "Error" -Message "ScenarioTest compare-cookie read failed." -Data @{
                ForestFqdn = $ForestFqdn
                Side = $side
                ElapsedMilliseconds = $elapsedMilliseconds
                TimeoutSeconds = $CompareCookieReadTimeoutSeconds
                Exception = $details
            }
            throw "ScenarioTest compare-cookie read failed for forest '$ForestFqdn', side '$side' after ${elapsedMilliseconds}ms: $details"
        }

        $elapsedMilliseconds = [math]::Round(([datetime]::UtcNow - $readStartedUtc).TotalMilliseconds, 0)
        $foundProperty = $cookie.PSObject.Properties["Found"]
        $found = $null -ne $foundProperty -and [bool]$foundProperty.Value
        Write-RunEvent -Level "Information" -Message "Completed ScenarioTest compare-cookie read." -Data @{
            ForestFqdn = $ForestFqdn
            Side = $side
            Found = $found
            CompareStatus = if ($cookie.PSObject.Properties["CompareStatus"]) { [string]$cookie.CompareStatus } else { $null }
            ElapsedMilliseconds = $elapsedMilliseconds
        }

        if (-not $found)
        {
            [void]$missing.Add($side)
            continue
        }

        $startGuid = [Guid]::Empty
        try
        {
            $startGuid = [Guid][string]$cookie.StartGuid
        }
        catch
        {
            $startGuid = [Guid]::Empty
        }
        if ($startGuid -eq [Guid]::Empty)
        {
            [void]$invalid.Add($side)
        }
    }
    return [ordered]@{
        Passed = $missing.Count -eq 0 -and $invalid.Count -eq 0
        Missing = $missing.ToArray()
        Invalid = $invalid.ToArray()
    }
}

function Initialize-ScenarioRuntimeDependencies
{
    $assemblyName = "Microsoft.Exchange.Directory.ChaosTest"
    $assemblyFileName = "$assemblyName.dll"
    $assembly = [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq $assemblyName } |
        Select-Object -First 1
    $loadErrors = [Collections.Generic.List[string]]::new()

    if ($null -eq $assembly)
    {
        $candidatePaths = [Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($env:ExchangeInstallPath))
        {
            [void]$candidatePaths.Add((Join-Path $env:ExchangeInstallPath "Bin\$assemblyFileName"))
        }
        [void]$candidatePaths.Add((Join-Path $ScenarioRuntimeDependencyRoot $assemblyFileName))

        foreach ($candidatePath in @($candidatePaths | Select-Object -Unique))
        {
            if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf))
            {
                [void]$loadErrors.Add("${candidatePath}: file not found")
                continue
            }

            try
            {
                $assembly = [Reflection.Assembly]::LoadFrom($candidatePath)
                break
            }
            catch
            {
                [void]$loadErrors.Add("${candidatePath}: $($_.Exception.Message)")
            }
        }
    }

    if ($null -eq $assembly)
    {
        throw "Scenario comparison runtime dependency '$assemblyFileName' is unavailable. Deploy the net472 runtime bundle beside this script under 'RuntimeDependencies\net472' before running preflight. Attempts: $($loadErrors -join '; ')"
    }

    $targetFramework = $assembly.GetCustomAttributesData() |
        Where-Object { $_.AttributeType.FullName -eq "System.Runtime.Versioning.TargetFrameworkAttribute" } |
        ForEach-Object { [string]$_.ConstructorArguments[0].Value } |
        Select-Object -First 1
    if ($targetFramework -notlike ".NETFramework,*")
    {
        throw "Scenario comparison runtime dependency '$($assembly.Location)' targets '$targetFramework'; Windows PowerShell requires the net472 build."
    }

    Write-RunEvent -Level "Information" -Message "Loaded ScenarioTest comparison runtime dependency." -Data @{
        Assembly = $assembly.FullName
        Location = $assembly.Location
        TargetFramework = $targetFramework
    }
}

function Initialize-ExchangeEnvironment
{
    if ($WhatIfTraffic)
    {
        $script:ForestFqdn = "whatif.local"
        $script:BasicDataType = "BasicData"
        return
    }

    if ($WorkloadMode -eq "ScenarioTest" -and [string]$PSEdition -ne "Desktop")
    {
        throw "ScenarioTest requires Windows PowerShell 5.1 (Desktop edition) so the Exchange snap-in can access the local directory context. Start powershell.exe, not pwsh.exe."
    }

    if (-not (Test-IsAdministrator))
    {
        throw "Run this script from an elevated Exchange Management Shell on the TDS Exchange box."
    }

    if ([string]::IsNullOrWhiteSpace($Organization) -and
        (-not $SkipDeletionOperations -or $WorkloadMode -eq "ScenarioTest"))
    {
        throw "Specify -Organization for deletion validation, or use -SkipDeletionOperations."
    }

    Add-PSSnapin *e2010* -ErrorAction SilentlyContinue
    if ($WorkloadMode -eq "ScenarioTest")
    {
        Initialize-ScenarioRuntimeDependencies
    }

    $requiredCommands = @(
        "Get-Recipient",
        "New-MailContact",
        "Set-MailContact",
        "Set-Contact",
        "Remove-MailContact",
        "New-DistributionGroup",
        "Set-DistributionGroup",
        "Set-Group",
        "Remove-DistributionGroup",
        "Add-DistributionGroupMember",
        "Remove-DistributionGroupMember",
        "Get-DistributionGroupMember",
        "Invoke-DirectoryADOSOfflineCompare",
        "Invoke-DirectoryOSADOfflineCompare",
        "Get-DirectoryObjectStoreSyncCookie",
        "Get-Mailbox",
        "Get-MailboxDatabase",
        "Set-ADObject")
    if ($WorkloadMode -eq "ScenarioTest")
    {
        $requiredCommands += @(
            "Get-ADObject",
            "Get-ADRootDSE",
            "Get-AccountPartition",
            "Get-EmailAddressPolicy")
    }

    $missing = @($requiredCommands | Where-Object { $null -eq (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -gt 0)
    {
        throw "Required Exchange commands are unavailable: $($missing -join ', ')"
    }

    if ($WorkloadMode -eq "ScenarioTest")
    {
        $cookieCommand = Get-Command "Get-DirectoryObjectStoreSyncCookie" -ErrorAction Stop
        Write-RunEvent -Level "Information" -Message "Loaded ScenarioTest Object Store sync-cookie cmdlet." -Data @{
            CommandType = [string]$cookieCommand.CommandType
            ModuleName = [string]$cookieCommand.ModuleName
            Source = [string]$cookieCommand.Source
        }
    }

    if (-not (Test-Path -LiteralPath $CompareSetupScript))
    {
        throw "Compare setup script not found: $CompareSetupScript"
    }
    . $CompareSetupScript

    $script:ForestFqdn = if ($WorkloadMode -eq "ScenarioTest")
    {
        Get-ScenarioForestFqdn
    }
    else
    {
        GetForestFqdn
    }
    $script:ForestFqdn = ([string]$script:ForestFqdn).Trim()
    $script:BasicDataType = "BasicData"
    if ($WorkloadMode -eq "ScenarioTest")
    {
        Write-RunEvent -Level "Information" -Message "Resolved ScenarioTest Object Store cookie forest." -Data @{
            ForestFqdn = $script:ForestFqdn
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Organization))
    {
        $organization = Get-Organization -Identity $Organization -ErrorAction Stop
        $script:TenantId = [Guid]$organization.ExternalDirectoryOrganizationId

        $groupOwner = Get-Mailbox -Organization $Organization -ResultSize Unlimited -ErrorAction Stop |
            Where-Object { [string]$_.RecipientTypeDetails -eq "UserMailbox" } |
            Sort-Object PrimarySmtpAddress |
            Select-Object -First 1
        if ($null -eq $groupOwner)
        {
            throw "No user mailbox is available in organization '$Organization' to own test distribution groups."
        }
        $script:GroupOwnerIdentity = if ($groupOwner.PrimarySmtpAddress)
        {
            [string]$groupOwner.PrimarySmtpAddress
        }
        else
        {
            [string]$groupOwner.Identity
        }
    }

    if ($WorkloadMode -in @("AttributeCoverage", "ScenarioTest"))
    {
        $database = Get-MailboxDatabase -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $database)
        {
            throw "No mailbox database is available for msExchMultiMailboxDatabasesLink validation."
        }
        $script:MailboxDatabaseLinkValue = "S:7:Primary:$($database.DistinguishedName)"
    }

    if ($ConfigureEnvironment)
    {
        SetupSyncCookies
        SetObjectStoreSetting -Section "ObjectStoreUploaderSettings" -Key "SkipRedundantOidAliasEnabled" -Value "Both"
        SetObjectStoreSetting -Section "ObjectStoreUploaderSettings" -Key "SkipRedundantOidAliasEnabled&test:true" -Value "Both"
        SetObjectStoreSetting -Section "DirSyncEngineSettings" -Key "RemoveOldObjectsOnTidChange" -Value "Both"
        SetObjectStoreSetting -Section "DirSyncEngineSettings" -Key "SkipNonMaterialRecipientChangeEnabled" -Value "true"
        SetObjectStoreSetting -Section "CompareEngineSettings" -Key "SkipCompareRecentOSETagInMinutes" -Value "0"
        SetObjectStoreSetting -Section "CompareEngineSettings" -Key "SkipCompareRecentOSETagInMinutes&test:true" -Value "0"
        RestartCacheService
    }
    else
    {
        $flight = GetObjectStoreSetting -Section "ObjectStoreUploaderSettings" -Key "SkipRedundantOidAliasEnabled&test:true"
        $recentEtagWindow = GetObjectStoreSetting -Section "CompareEngineSettings" -Key "SkipCompareRecentOSETagInMinutes&test:true"
        $skipNonMaterial = GetObjectStoreSetting -Section "DirSyncEngineSettings" -Key "SkipNonMaterialRecipientChangeEnabled"
        if ($flight -ne "Both" -or $recentEtagWindow -ne "0" -or $skipNonMaterial -ne "true")
        {
            throw "Required TDS settings are not active. Run once with -ConfigureEnvironment. Current redundant-alias='$flight', recent-ETag window='$recentEtagWindow', skip-non-material='$skipNonMaterial'."
        }
    }

    $service = Get-Service -Name "MSExchangeDirCacheService" -ErrorAction Stop
    if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Running)
    {
        throw "MSExchangeDirCacheService is not running."
    }

    $cookies = Get-ScenarioSyncCookieRecords -ForestFqdn $script:ForestFqdn
    $cookieIndex = Get-ScenarioSyncCookieIndex -Cookies $cookies
    if ($WorkloadMode -eq "ScenarioTest")
    {
        Write-RunEvent -Level "Information" -Message "Read ScenarioTest Object Store sync cookies." -Data @{
            ForestFqdn = $script:ForestFqdn
            CookieCount = $cookieIndex.Count
            CookieKeys = @($cookieIndex.Keys | Sort-Object)
        }
    }
    $currentSideMissing = [Collections.Generic.List[string]]::new()
    foreach ($requiredType in @("Recipients", "Links"))
    {
        $key = "{0}|{1}" -f ([string]$Side).Trim().ToUpperInvariant(), $requiredType.ToUpperInvariant()
        if (-not $cookieIndex.ContainsKey($key))
        {
            [void]$currentSideMissing.Add("$requiredType/$Side")
        }
    }
    if ($currentSideMissing.Count -gt 0)
    {
        if ($WorkloadMode -eq "ScenarioTest")
        {
            $observedKeys = @($cookieIndex.Keys | Sort-Object)
            throw "ScenarioTest Object Store sync-cookie preflight failed for forest '$script:ForestFqdn', side '$Side'. Missing: $($currentSideMissing -join ', '). Observed: $($observedKeys -join ', ')."
        }
        throw "Missing $($currentSideMissing -join ', ') Object Store sync cookie(s) for side $Side."
    }

    if ($WorkloadMode -eq "ScenarioTest")
    {
        $syncReadiness = Test-ScenarioSyncCookieReadiness -CookieIndex $cookieIndex
        if (-not $syncReadiness.Passed)
        {
            throw "ScenarioTest requires all six A/B sync cookies with completed full-sync flags for forest '$script:ForestFqdn'. Missing: $($syncReadiness.Missing -join ', '). NotFullSync: $($syncReadiness.NotFullSync -join ', ')."
        }

        $compareReadiness = Test-ScenarioCompareCookieReadiness -ForestFqdn $script:ForestFqdn
        if (-not $compareReadiness.Passed)
        {
            throw "ScenarioTest requires valid A/B compare cookies for forest '$script:ForestFqdn'. Missing: $($compareReadiness.Missing -join ', '). Invalid: $($compareReadiness.Invalid -join ', ')."
        }
    }
}

function Add-PendingValidation
{
    param(
        [Parameter(Mandatory)] [Guid] $Guid,
        [Parameter(Mandatory)] [ValidateSet("Active", "Deleted")] [string] $ExpectedState,
        [Parameter(Mandatory)] [string] $Reason,
        [Parameter(Mandatory)] [string] $Identity,
        [datetime] $MutationUtc = ([datetime]::UtcNow),
        [string[]] $RequiredCookies = @("Recipients"))

    $now = [datetime]::UtcNow
    $script:PendingValidations[$Guid.ToString()] = [ordered]@{
        Guid = $Guid.ToString()
        Identity = $Identity
        ExpectedState = $ExpectedState
        Reason = $Reason
        DueUtc = $now.AddSeconds($ConvergenceDelaySeconds).ToString("o")
        DeadlineUtc = $now.AddSeconds($ValidationTimeoutSeconds).ToString("o")
        Attempts = 0
        MutationUtc = $MutationUtc.ToUniversalTime().ToString("o")
        RequiredCookies = @($RequiredCookies)
    }
}

function Get-SyncCookieWatermarks
{
    $watermarks = @{}
    $cookies = Get-ScenarioSyncCookieRecords -ForestFqdn $script:ForestFqdn
    foreach ($cookie in $cookies)
    {
        if ([string]$cookie.Side -ieq [string]$Side)
        {
            $lastProcessedProperty = $cookie.PSObject.Properties["WhenDirSyncLastProcessedUTC"]
            $timestampProperty = $cookie.PSObject.Properties["Timestamp"]
            $watermarks[[string]$cookie.DataType] =
                if ($null -ne $lastProcessedProperty -and $null -ne $lastProcessedProperty.Value)
                {
                    ([datetime]$lastProcessedProperty.Value).ToUniversalTime()
                }
                elseif ($null -ne $timestampProperty -and $null -ne $timestampProperty.Value)
                {
                    ([datetime]$timestampProperty.Value).ToUniversalTime()
                }
                else
                {
                    [datetime]::MinValue
                }
        }
    }
    return $watermarks
}

function Test-ValidationWatermarkReached
{
    param(
        [Parameter(Mandatory)] [object] $Item,
        [Parameter(Mandatory)] [hashtable] $Watermarks)

    foreach ($cookieType in @($Item.RequiredCookies))
    {
        if (-not $Watermarks.ContainsKey([string]$cookieType) -or
            [datetime]$Watermarks[[string]$cookieType] -lt (ConvertFrom-IsoUtc -Value ([string]$Item.MutationUtc)))
        {
            return $false
        }
    }
    return $true
}

function Add-OperationRecord
{
    param(
        [Parameter(Mandatory)] [string] $Operation,
        [Parameter(Mandatory)] [string] $Status,
        [datetime] $StartedUtc,
        [string] $Identity,
        [object] $Guid,
        [hashtable] $Details,
        [Exception] $Exception)

    $timestampUtc = [datetime]::UtcNow
    $guidText = if ($null -eq $Guid -or [string]::IsNullOrWhiteSpace([string]$Guid))
    {
        $null
    }
    else
    {
        $parsedGuid = [Guid]$Guid
        if ($parsedGuid -eq [Guid]::Empty) { $null } else { $parsedGuid.ToString() }
    }
    $record = [ordered]@{
        TimestampUtc = $timestampUtc.ToString("o")
        StartedUtc = $StartedUtc.ToString("o")
        DurationMilliseconds = [math]::Round(([datetime]::UtcNow - $StartedUtc).TotalMilliseconds, 2)
        Operation = $Operation
        Status = $Status
        Identity = $Identity
        Guid = $guidText
        Details = $Details
        ErrorType = if ($null -eq $Exception) { $null } else { $Exception.GetType().FullName }
        ErrorMessage = if ($null -eq $Exception) { $null } else { $Exception.Message }
    }
    Write-JsonLine -Path $script:OperationLogPath -InputObject $record
    Write-ReadableOperationRecord `
        -Timestamp $timestampUtc.ToLocalTime() `
        -Operation $Operation `
        -Status $Status `
        -Identity $Identity `
        -Details $Details `
        -Exception $Exception
}

function Invoke-TrafficOperation
{
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $Action,
        [switch] $PassThru)

    $script:Counters.OperationsAttempted++
    $startedUtc = [datetime]::UtcNow
    try
    {
        $result = & $Action
        $script:Counters.OperationsSucceeded++
        Add-OperationRecord -Operation $Name -Status "Success" -StartedUtc $startedUtc -Identity $result.Identity -Guid $result.Guid -Details $result.Details
        if ($PassThru)
        {
            return $result
        }
    }
    catch
    {
        $script:Counters.OperationsFailed++
        Add-OperationRecord -Operation $Name -Status "Failed" -StartedUtc $startedUtc -Exception $_.Exception
        Stop-LongevityTraffic -Category "TrafficOperationFailure" -Message "$Name failed: $($_.Exception.Message)" -Exception $_.Exception -Data @{
            ScriptStackTrace = $_.ScriptStackTrace
        }
    }
}

function New-TestContact
{
    if ($WorkloadMode -ne "ScenarioTest" -and $script:Contacts.Count -ge $MaximumRecipientCount)
    {
        return (Invoke-ReadRecipient)
    }

    $name = New-EntityName -Kind Contact
    if ($WhatIfTraffic)
    {
        $record = [ordered]@{ Identity = $name; Name = $name; Guid = [Guid]::NewGuid(); DistinguishedName = "CN=$name,DC=whatif,DC=local"; Kind = "Contact"; CreatedUtc = [datetime]::UtcNow.ToString("o"); Members = @() }
    }
    else
    {
        $parameters = Get-CommandParameters -CommandName "New-MailContact" -Parameters @{
            Name = $name
            Alias = $name
            ExternalEmailAddress = "SMTP:$name@example.invalid"
            ErrorAction = "Stop"
        }
        [void](New-MailContact @parameters)
        $record = ConvertTo-EntityRecord -Recipient (Get-ContactByIdentity -Identity $name) -Kind Contact
    }

    $script:Contacts[$record.Identity] = $record
    Add-PendingValidation -Guid $record.Guid -ExpectedState Active -Reason "CreateContact" -Identity $record.Identity
    $script:Counters.Writes++
    return @{ Identity = $record.Identity; Guid = $record.Guid; Details = @{ Count = $script:Contacts.Count } }
}

function Update-TestContact
{
    $contact = Get-RandomItem @($script:Contacts.Values)
    if ($null -eq $contact)
    {
        return New-TestContact
    }

    $propertyChoice = $script:Random.Next(0, 3)
    $value = "$ObjectPrefix-$(New-RandomToken -Length 16)"
    if (-not $WhatIfTraffic)
    {
        $parameters = Get-CommandParameters -CommandName "Set-MailContact" -Parameters @{
            Identity = $contact.Identity
            ErrorAction = "Stop"
        }
        switch ($propertyChoice)
        {
            0 { $parameters.DisplayName = $value }
            1 { $parameters.CustomAttribute1 = $value }
            2 { $parameters.CustomAttribute2 = $value }
        }
        Set-MailContact @parameters
    }

    Add-PendingValidation -Guid ([Guid]$contact.Guid) -ExpectedState Active -Reason "UpdateContact" -Identity $contact.Identity
    $script:Counters.Writes++
    return @{ Identity = $contact.Identity; Guid = [Guid]$contact.Guid; Details = @{ PropertyChoice = $propertyChoice; Value = $value } }
}

function Remove-TestContact
{
    $linkedIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($group in $script:Groups.Values)
    {
        foreach ($member in @($group.Members))
        {
            [void]$linkedIdentities.Add([string]$member)
        }
    }

    $candidate = Get-RandomItem @($script:Contacts.Values | Where-Object { -not $linkedIdentities.Contains([string]$_.Identity) })
    if ($null -eq $candidate)
    {
        return Update-TestContact
    }

    if (-not $WhatIfTraffic)
    {
        $parameters = Get-CommandParameters -CommandName "Remove-MailContact" -Parameters @{
            Identity = $candidate.Identity
            Confirm = $false
            ErrorAction = "Stop"
        }
        Remove-MailContact @parameters
    }

    $script:Contacts.Remove([string]$candidate.Identity)
    Add-PendingValidation -Guid ([Guid]$candidate.Guid) -ExpectedState Deleted -Reason "RemoveContact" -Identity $candidate.Identity -RequiredCookies @("Recipients", "Links")
    $script:Counters.Writes++
    return @{ Identity = $candidate.Identity; Guid = [Guid]$candidate.Guid; Details = @{} }
}

function New-TestGroup
{
    if ($WorkloadMode -ne "ScenarioTest" -and $script:Groups.Count -ge $MaximumGroupCount)
    {
        return (Invoke-ReadGroupMembers)
    }

    $name = New-EntityName -Kind Group
    if ($WhatIfTraffic)
    {
        $record = [ordered]@{ Identity = $name; Name = $name; Guid = [Guid]::NewGuid(); DistinguishedName = "CN=$name,DC=whatif,DC=local"; Kind = "Group"; CreatedUtc = [datetime]::UtcNow.ToString("o"); Members = @() }
    }
    else
    {
        $newGroupParameters = @{
            Name = $name
            Alias = $name
            Type = "Distribution"
            ErrorAction = "Stop"
        }
        if (-not [string]::IsNullOrWhiteSpace($script:GroupOwnerIdentity))
        {
            $newGroupParameters["ManagedBy"] = $script:GroupOwnerIdentity
        }
        $parameters = Get-CommandParameters -CommandName "New-DistributionGroup" -Parameters $newGroupParameters
        [void](New-DistributionGroup @parameters)
        $record = ConvertTo-EntityRecord -Recipient (Get-GroupByIdentity -Identity $name) -Kind Group
    }

    $script:Groups[$record.Identity] = $record
    Add-PendingValidation -Guid $record.Guid -ExpectedState Active -Reason "CreateGroup" -Identity $record.Identity
    $script:Counters.Writes++
    return @{ Identity = $record.Identity; Guid = $record.Guid; Details = @{ Count = $script:Groups.Count } }
}

function Update-TestGroup
{
    $group = Get-RandomItem @($script:Groups.Values)
    if ($null -eq $group)
    {
        return New-TestGroup
    }

    $propertyChoice = $script:Random.Next(0, 3)
    $value = "$ObjectPrefix-$(New-RandomToken -Length 16)"
    if (-not $WhatIfTraffic)
    {
        $parameters = Get-CommandParameters -CommandName "Set-DistributionGroup" -Parameters @{
            Identity = $group.Identity
            ErrorAction = "Stop"
        }
        switch ($propertyChoice)
        {
            0 { $parameters.DisplayName = $value }
            1 { $parameters.CustomAttribute1 = $value }
            2 { $parameters.CustomAttribute2 = $value }
        }
        Set-DistributionGroup @parameters
    }

    Add-PendingValidation -Guid ([Guid]$group.Guid) -ExpectedState Active -Reason "UpdateGroup" -Identity $group.Identity
    $script:Counters.Writes++
    return @{ Identity = $group.Identity; Guid = [Guid]$group.Guid; Details = @{ PropertyChoice = $propertyChoice; Value = $value } }
}

function Remove-TestGroup
{
    $group = Get-RandomItem @($script:Groups.Values)
    if ($null -eq $group)
    {
        return New-TestGroup
    }

    if (-not $WhatIfTraffic)
    {
        $parameters = Get-CommandParameters -CommandName "Remove-DistributionGroup" -Parameters @{
            Identity = $group.Identity
            Confirm = $false
            ErrorAction = "Stop"
        }
        Remove-DistributionGroup @parameters
    }

    $script:Groups.Remove([string]$group.Identity)
    Add-PendingValidation -Guid ([Guid]$group.Guid) -ExpectedState Deleted -Reason "RemoveGroup" -Identity $group.Identity -RequiredCookies @("Recipients", "Links")
    $script:Counters.Writes++
    return @{ Identity = $group.Identity; Guid = [Guid]$group.Guid; Details = @{ MemberCount = @($group.Members).Count } }
}

function Add-TestGroupMember
{
    $group = Get-RandomItem @($script:Groups.Values | Where-Object { @($_.Members).Count -lt [math]::Min(50, $script:Contacts.Count) })
    if ($null -eq $group)
    {
        return New-TestGroup
    }

    $existingMembers = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($member in @($group.Members))
    {
        [void]$existingMembers.Add([string]$member)
    }
    $contact = Get-RandomItem @($script:Contacts.Values | Where-Object { -not $existingMembers.Contains([string]$_.Identity) })
    if ($null -eq $contact)
    {
        return New-TestContact
    }

    if (-not $WhatIfTraffic)
    {
        $parameters = Get-CommandParameters -CommandName "Add-DistributionGroupMember" -Parameters @{
            Identity = $group.Identity
            Member = $contact.Identity
            BypassSecurityGroupManagerCheck = $true
            ErrorAction = "Stop"
        }
        Add-DistributionGroupMember @parameters
    }

    $group.Members = @($group.Members) + [string]$contact.Identity
    $mutationUtc = [datetime]::UtcNow
    Add-PendingValidation -Guid ([Guid]$group.Guid) -ExpectedState Active -Reason "AddGroupMember" -Identity $group.Identity -MutationUtc $mutationUtc -RequiredCookies @("Links")
    Add-PendingValidation -Guid ([Guid]$contact.Guid) -ExpectedState Active -Reason "AddedToGroup" -Identity $contact.Identity -MutationUtc $mutationUtc -RequiredCookies @("Links")
    $script:Counters.Writes++
    return @{ Identity = $group.Identity; Guid = [Guid]$group.Guid; Details = @{ Member = $contact.Identity } }
}

function Remove-TestGroupMember
{
    $group = Get-RandomItem @($script:Groups.Values | Where-Object { @($_.Members).Count -gt 0 })
    if ($null -eq $group)
    {
        return Add-TestGroupMember
    }

    $memberIdentity = [string](Get-RandomItem @($group.Members))
    if (-not $WhatIfTraffic)
    {
        $parameters = Get-CommandParameters -CommandName "Remove-DistributionGroupMember" -Parameters @{
            Identity = $group.Identity
            Member = $memberIdentity
            BypassSecurityGroupManagerCheck = $true
            Confirm = $false
            ErrorAction = "Stop"
        }
        Remove-DistributionGroupMember @parameters
    }

    $group.Members = @($group.Members | Where-Object { -not [string]::Equals([string]$_, $memberIdentity, [StringComparison]::OrdinalIgnoreCase) })
    $mutationUtc = [datetime]::UtcNow
    Add-PendingValidation -Guid ([Guid]$group.Guid) -ExpectedState Active -Reason "RemoveGroupMember" -Identity $group.Identity -MutationUtc $mutationUtc -RequiredCookies @("Links")
    $contact = $script:Contacts[$memberIdentity]
    if ($null -ne $contact)
    {
        Add-PendingValidation -Guid ([Guid]$contact.Guid) -ExpectedState Active -Reason "RemovedFromGroup" -Identity $contact.Identity -MutationUtc $mutationUtc -RequiredCookies @("Links")
    }
    $script:Counters.Writes++
    return @{ Identity = $group.Identity; Guid = [Guid]$group.Guid; Details = @{ Member = $memberIdentity } }
}

function Invoke-ReadRecipient
{
    $entity = Get-RandomItem (@($script:Contacts.Values) + @($script:Groups.Values))
    if ($null -eq $entity)
    {
        return New-TestContact
    }

    if (-not $WhatIfTraffic)
    {
        $recipient = Get-RecipientByIdentity -Identity $entity.Identity
        if ([Guid]$recipient.Guid -ne [Guid]$entity.Guid)
        {
            throw "AD read returned GUID $($recipient.Guid) for $($entity.Identity); expected $($entity.Guid)."
        }
    }
    $script:Counters.Reads++
    return @{ Identity = $entity.Identity; Guid = [Guid]$entity.Guid; Details = @{ ReadPath = "ADRecipient" } }
}

function Invoke-ReadGroupMembers
{
    $group = Get-RandomItem @($script:Groups.Values)
    if ($null -eq $group)
    {
        return (Invoke-ReadRecipient)
    }

    if (-not $WhatIfTraffic)
    {
        $parameters = Get-CommandParameters -CommandName "Get-DistributionGroupMember" -Parameters @{
            Identity = $group.Identity
            ResultSize = "Unlimited"
            ErrorAction = "Stop"
        }
        $actualMembers = @(Get-DistributionGroupMember @parameters | ForEach-Object { [string]$_.Identity })
        $expectedMemberCount = @($group.Members).Count
        if ($actualMembers.Count -ne $expectedMemberCount)
        {
            throw "AD group read for $($group.Identity) returned $($actualMembers.Count) members; expected $expectedMemberCount."
        }
    }
    $script:Counters.Reads++
    return @{ Identity = $group.Identity; Guid = [Guid]$group.Guid; Details = @{ ReadPath = "ADGroupMembers"; ExpectedMemberCount = @($group.Members).Count } }
}

function Get-ShuffledArray
{
    param([Parameter(Mandatory)] [object[]] $Items)

    $result = @($Items)
    for ($index = $result.Count - 1; $index -gt 0; $index--)
    {
        $swapIndex = $script:Random.Next(0, $index + 1)
        $temporary = $result[$index]
        $result[$index] = $result[$swapIndex]
        $result[$swapIndex] = $temporary
    }
    return $result
}

function Get-RecipientAttributeDefinitions
{
    $definitions = @(
        @{ Name = "DisplayName"; Command = "Set-MailContact"; Parameter = "DisplayName"; Kind = "String" }
    )
    foreach ($index in 1..15)
    {
        $definitions += @{
            Name = "CustomAttribute$index"
            Command = "Set-MailContact"
            Parameter = "CustomAttribute$index"
            Kind = "String"
        }
    }
    foreach ($name in @(
        "AssistantName",
        "City",
        "Company",
        "Department",
        "Fax",
        "FirstName",
        "HomePhone",
        "Initials",
        "LastName",
        "MobilePhone",
        "Notes",
        "Office",
        "Pager",
        "Phone",
        "PostalCode",
        "SimpleDisplayName",
        "StateOrProvince",
        "StreetAddress",
        "TelephoneAssistant",
        "Title",
        "WebPage"))
    {
        $definitions += @{ Name = $name; Command = "Set-Contact"; Parameter = $name; Kind = "String" }
    }
    $definitions += @{
        Name = "msExchMultiMailboxDatabasesLink"
        Command = "Set-ADObject"
        Parameter = "msExchMultiMailboxDatabasesLink"
        Kind = "MailboxDatabaseLink"
    }
    return $definitions
}

function Get-GroupAttributeDefinitions
{
    $definitions = @(
        @{ Name = "DisplayName"; Command = "Set-DistributionGroup"; Parameter = "DisplayName"; Kind = "String" }
    )
    foreach ($index in 1..15)
    {
        $definitions += @{
            Name = "CustomAttribute$index"
            Command = "Set-DistributionGroup"
            Parameter = "CustomAttribute$index"
            Kind = "String"
        }
    }
    foreach ($name in @("Description", "Notes", "PhoneticDisplayName", "SimpleDisplayName"))
    {
        $definitions += @{ Name = $name; Command = "Set-Group"; Parameter = $name; Kind = "String" }
    }
    return $definitions
}

function New-CoverageAttributeValue
{
    param(
        [Parameter(Mandatory)] [string] $AttributeName,
        [Parameter(Mandatory)] [string] $EntityName)

    switch ($AttributeName)
    {
        "Initials" { return (New-RandomToken -Length 3).ToUpperInvariant() }
        { $_ -in @("Fax", "HomePhone", "MobilePhone", "Pager", "Phone", "PostalCode", "TelephoneAssistant") }
        {
            return [string]$script:Random.Next(1000000, 9999999)
        }
        "WebPage" { return "https://example.invalid/$(New-RandomToken -Length 12)" }
        default { return "$EntityName-$(New-RandomToken -Length 12)" }
    }
}

function Set-CoverageAttribute
{
    param(
        [Parameter(Mandatory)] [object] $Entity,
        [Parameter(Mandatory)] [hashtable] $Definition,
        [Parameter(Mandatory)] [bool] $Clear)

    $attributeName = [string]$Definition.Name
    $mutationUtc = [datetime]::UtcNow
    $value = $null
    $changed = $true

    if ([string]$Definition.Kind -eq "MailboxDatabaseLink")
    {
        $value = if ($WhatIfTraffic) { "S:7:Primary:CN=Database,DC=whatif,DC=local" } else { $script:MailboxDatabaseLinkValue }
        if (-not $WhatIfTraffic)
        {
            $recipient = Get-ContactByIdentity -Identity $Entity.Identity
            $adObject = Get-ADObject -Identity $recipient.DistinguishedName -Properties $attributeName -ErrorAction Stop
            $currentValues = @($adObject.$attributeName)
            $changed = if ($Clear) { $currentValues -contains $value } else { $currentValues -notcontains $value }
            if ($Clear)
            {
                if ($changed)
                {
                    Set-ADObject -Identity $recipient.DistinguishedName -Remove @{ $attributeName = $value } -ErrorAction Stop
                }
            }
            elseif ($changed)
            {
                Set-ADObject -Identity $recipient.DistinguishedName -Add @{ $attributeName = $value } -ErrorAction Stop
            }
        }
    }
    else
    {
        if (-not $Clear)
        {
            $value = New-CoverageAttributeValue -AttributeName $attributeName -EntityName $Entity.Name
        }
        if (-not $WhatIfTraffic)
        {
            $parameters = Get-CommandParameters -CommandName ([string]$Definition.Command) -Parameters @{
                Identity = $Entity.Identity
                ErrorAction = "Stop"
            }
            $parameters[[string]$Definition.Parameter] = $value
            & ([string]$Definition.Command) @parameters
        }
    }

    Add-PendingValidation `
        -Guid ([Guid]$Entity.Guid) `
        -ExpectedState Active `
        -Reason "$(if ($Clear) { 'Clear' } else { 'Upsert' }):$attributeName" `
        -Identity $Entity.Identity `
        -MutationUtc $mutationUtc `
        -RequiredCookies @("Recipients")
    $script:Counters.Writes++
    return @{
        Identity = $Entity.Identity
        Guid = [Guid]$Entity.Guid
        Details = @{
            Attribute = $attributeName
            Action = if ($Clear) { "Clear" } else { "Upsert" }
            Value = $value
            Changed = $changed
        }
    }
}

function Wait-CoverageValidations
{
    param([Parameter(Mandatory)] [Guid[]] $Guids)

    $keys = @($Guids | ForEach-Object { $_.ToString() } | Select-Object -Unique)
    $deadlineUtc = [datetime]::UtcNow.AddSeconds(
        $ConvergenceDelaySeconds + $ValidationTimeoutSeconds + 30)
    while (-not $script:StopRequested -and [datetime]::UtcNow -lt $deadlineUtc)
    {
        Invoke-DueValidations
        $remaining = @($keys | Where-Object { $script:PendingValidations.ContainsKey($_) })
        if ($remaining.Count -eq 0)
        {
            return
        }
        Start-Sleep -Seconds 1
    }

    if (-not $script:StopRequested)
    {
        Stop-LongevityTraffic `
            -Category "PerMutationCompareTimeout" `
            -Message "Compare Engine did not validate every mutation before the per-round deadline." `
            -Data @{ PendingGuids = @($keys | Where-Object { $script:PendingValidations.ContainsKey($_) }) }
    }
}

function Invoke-AttributeCoveragePhase
{
    param(
        [Parameter(Mandatory)] [ValidateSet("Upsert", "Clear")] [string] $Phase,
        [Parameter(Mandatory)] [object[]] $RecipientDefinitions,
        [Parameter(Mandatory)] [object[]] $GroupDefinitions)

    $recipientPlans = @{}
    foreach ($entity in @($script:Contacts.Values))
    {
        $recipientPlans[[string]$entity.Identity] = @(Get-ShuffledArray -Items $RecipientDefinitions)
    }
    $groupPlans = @{}
    foreach ($entity in @($script:Groups.Values))
    {
        $groupPlans[[string]$entity.Identity] = @(Get-ShuffledArray -Items $GroupDefinitions)
    }

    $roundCount = [math]::Max($RecipientDefinitions.Count, $GroupDefinitions.Count)
    for ($round = 0; $round -lt $roundCount -and -not $script:StopRequested; $round++)
    {
        $validationGuids = [Collections.Generic.List[Guid]]::new()
        $rangedMutationCount = 0
        foreach ($entity in @($script:Contacts.Values))
        {
            $plan = $recipientPlans[[string]$entity.Identity]
            if ($round -ge $plan.Count)
            {
                continue
            }
            $definition = [hashtable]$plan[$round]
            $operationResult = Invoke-TrafficOperation -Name "${Phase}RecipientAttribute" -PassThru -Action {
                Set-CoverageAttribute -Entity $entity -Definition $definition -Clear ($Phase -eq "Clear")
            }
            if ($null -ne $operationResult -and
                [string]$definition.Kind -eq "MailboxDatabaseLink" -and
                $operationResult.Details.Changed)
            {
                $rangedMutationCount++
            }
            $validationGuids.Add([Guid]$entity.Guid)
        }

        foreach ($entity in @($script:Groups.Values))
        {
            $plan = $groupPlans[[string]$entity.Identity]
            if ($round -ge $plan.Count)
            {
                continue
            }
            $definition = [hashtable]$plan[$round]
            Invoke-TrafficOperation -Name "${Phase}GroupAttribute" -Action {
                Set-CoverageAttribute -Entity $entity -Definition $definition -Clear ($Phase -eq "Clear")
            }
            $validationGuids.Add([Guid]$entity.Guid)
        }

        if ($script:StopRequested)
        {
            return
        }

        Wait-CoverageValidations -Guids $validationGuids.ToArray()
        if ($script:StopRequested)
        {
            return
        }

        Write-RunEvent -Level "Success" -Message "$Phase attribute round $($round + 1) passed Compare Engine validation." -Data @{
            Round = $round + 1
            TotalRounds = $roundCount
            ObjectCount = $validationGuids.Count
            RangedMailboxDatabaseLinkMutations = $rangedMutationCount
        }
        Save-Checkpoint
    }
}

function Invoke-AttributeCoverageWorkload
{
    $recipientDefinitions = @(Get-RecipientAttributeDefinitions)
    $groupDefinitions = @(Get-GroupAttributeDefinitions)

    Write-RunEvent -Level "Information" -Message "Starting exhaustive randomized attribute coverage." -Data @{
        Recipients = $script:Contacts.Count
        Groups = $script:Groups.Count
        RecipientAttributes = $recipientDefinitions.Count
        GroupAttributes = $groupDefinitions.Count
    }

    Invoke-AttributeCoveragePhase `
        -Phase Upsert `
        -RecipientDefinitions $recipientDefinitions `
        -GroupDefinitions $groupDefinitions

    if (-not $script:StopRequested)
    {
        Invoke-AttributeCoveragePhase `
            -Phase Clear `
            -RecipientDefinitions $recipientDefinitions `
            -GroupDefinitions $groupDefinitions
    }
}

function Get-WeightedOperation
{
    $roll = $script:Random.Next(0, 100)
    if ($roll -lt 12) { return "CreateContact" }
    if ($roll -lt 32) { return "UpdateContact" }
    if ($roll -lt 38) { return $(if ($SkipDeletionOperations) { "UpdateContact" } else { "RemoveContact" }) }
    if ($roll -lt 44) { return "CreateGroup" }
    if ($roll -lt 52) { return "UpdateGroup" }
    if ($roll -lt 55) { return $(if ($SkipDeletionOperations) { "UpdateGroup" } else { "RemoveGroup" }) }
    if ($roll -lt 70) { return "AddGroupMember" }
    if ($roll -lt 80) { return "RemoveGroupMember" }
    if ($roll -lt 92) { return "ReadRecipient" }
    return "ReadGroupMembers"
}

function Invoke-SelectedOperation
{
    param([Parameter(Mandatory)] [string] $Operation)

    switch ($Operation)
    {
        "CreateContact" { Invoke-TrafficOperation -Name $Operation -Action { New-TestContact } }
        "UpdateContact" { Invoke-TrafficOperation -Name $Operation -Action { Update-TestContact } }
        "RemoveContact" { Invoke-TrafficOperation -Name $Operation -Action { Remove-TestContact } }
        "CreateGroup" { Invoke-TrafficOperation -Name $Operation -Action { New-TestGroup } }
        "UpdateGroup" { Invoke-TrafficOperation -Name $Operation -Action { Update-TestGroup } }
        "RemoveGroup" { Invoke-TrafficOperation -Name $Operation -Action { Remove-TestGroup } }
        "AddGroupMember" { Invoke-TrafficOperation -Name $Operation -Action { Add-TestGroupMember } }
        "RemoveGroupMember" { Invoke-TrafficOperation -Name $Operation -Action { Remove-TestGroupMember } }
        "ReadRecipient" { Invoke-TrafficOperation -Name $Operation -Action { Invoke-ReadRecipient } }
        "ReadGroupMembers" { Invoke-TrafficOperation -Name $Operation -Action { Invoke-ReadGroupMembers } }
        default { throw "Unknown traffic operation: $Operation" }
    }
}

function Get-CompareResultCode
{
    param([object] $Result)

    if ($null -eq $Result)
    {
        return $null
    }
    if ($null -ne $Result.ResultCode)
    {
        return [string]$Result.ResultCode
    }
    return [string]$Result
}

function Invoke-ActiveValidationBatch
{
    param([object[]] $Items)

    $objectIds = ($Items | ForEach-Object { [string]$_.Guid }) -join ","
    $rawOutput = @(Invoke-DirectoryADOSOfflineCompare `
        -ObjectIds $objectIds `
        -PartitionId $script:ForestFqdn `
        -OSDestination $ObjectStoreDestination `
        -Side $Side `
        -SkipUploadingDivergence `
        -ErrorAction Stop)

    if (($rawOutput -join "`n") -match "Compare was skipped")
    {
        return @{ Deferred = $true; Reason = "CompareSkipped"; Raw = $rawOutput }
    }

    $jsonLines = @($rawOutput | Where-Object { "$_".TrimStart().StartsWith("[") -or "$_".TrimStart().StartsWith("{") })
    if ($jsonLines.Count -eq 0)
    {
        throw "AD-to-OS compare returned no JSON result. Output: $($rawOutput -join ' | ')"
    }

    $results = @($jsonLines | ForEach-Object { $_ | ConvertFrom-Json })
    $badCodes = @()
    $codesByGuid = @{}
    foreach ($result in $results)
    {
        $code = Get-CompareResultCode $result
        if ($null -ne $result.ObjectGuid)
        {
            $codesByGuid[[string]$result.ObjectGuid] = $code
        }
        if ($code -ne "DataSame")
        {
            $badCodes += $code
        }
    }
    if ($results.Count -ne $Items.Count)
    {
        return @{
            Deferred = $true
            Reason = "IncompleteCompareResults"
            ExpectedResultCount = $Items.Count
            ActualResultCount = $results.Count
            Raw = $rawOutput
        }
    }
    return @{
        Deferred = $false
        BadCodes = $badCodes
        CodesByGuid = $codesByGuid
        ResultCount = $results.Count
        Raw = $rawOutput
    }
}

function Invoke-DeletedValidation
{
    param([Parameter(Mandatory)] [object] $Item)

    try
    {
        [void](Get-RecipientByIdentity -Identity $Item.Identity)
        return @{ Deferred = $true; Reason = "ObjectStillPresentInAD" }
    }
    catch [Microsoft.Exchange.Configuration.Tasks.ManagementObjectNotFoundException]
    {
    }
    catch
    {
        if ($_.Exception.Message -notmatch "couldn't be found|cannot be found|not found")
        {
            throw
        }
    }

    if ($script:TenantId -eq [Guid]::Empty)
    {
        return @{ Deferred = $true; Reason = "TenantIdUnavailableForOSDeletionCheck" }
    }

    $rawOutput = @(Invoke-DirectoryOSADOfflineCompare `
        -ObjectTable `
        -ObjectId ([Guid]$Item.Guid) `
        -TenantId $script:TenantId `
        -PartitionId $script:ForestFqdn `
        -OSDataPartition $ObjectStoreDestination `
        -DataType $script:BasicDataType `
        -Side $Side `
        -RecentlyChangedInMinutes 0 `
        -SkipUploadingDivergence `
        -ErrorAction Stop)

    $text = $rawOutput -join "`n"
    if ($text -match "No comparison jobs generated")
    {
        return @{ Deferred = $false; Deleted = $true; Raw = $rawOutput }
    }
    if ($text -match "DataMissingInAD")
    {
        return @{ Deferred = $true; Reason = "ObjectStillPresentInObjectStore"; Raw = $rawOutput }
    }
    throw "OS-to-AD deletion check returned an unexpected result: $text"
}

function Complete-Validation
{
    param(
        [Parameter(Mandatory)] [object] $Item,
        [Parameter(Mandatory)] [string] $Status,
        [hashtable] $Details)

    Write-JsonLine -Path $script:ValidationLogPath -InputObject ([ordered]@{
        TimestampUtc = [datetime]::UtcNow.ToString("o")
        Guid = $Item.Guid
        Identity = $Item.Identity
        ExpectedState = $Item.ExpectedState
        Reason = $Item.Reason
        Attempts = $Item.Attempts
        Status = $Status
        Details = $Details
    })

    if ($Status -eq "Passed")
    {
        $script:Counters.ValidationsPassed++
        $script:PendingValidations.Remove([string]$Item.Guid)
    }
    elseif ($Status -eq "Deferred")
    {
        $script:Counters.ValidationsDeferred++
        $Item.DueUtc = [datetime]::UtcNow.AddSeconds([math]::Min(60, [math]::Max(5, $ConvergenceDelaySeconds / 5))).ToString("o")
        $script:PendingValidations[[string]$Item.Guid] = $Item
    }
    else
    {
        $script:Counters.ValidationsFailed++
    }
}

function Add-ScenarioBatchFailure
{
    param(
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [string] $Message,
        [hashtable] $Data = @{})

    $script:ScenarioBatchFailures.Add([ordered]@{
        TimestampUtc = [datetime]::UtcNow.ToString("o")
        Category = $Category
        Message = $Message
        Data = $Data
    })
}

function Add-ScenarioDataInconsistency
{
    param(
        [Parameter(Mandatory)] [object] $Item,
        [Parameter(Mandatory)] [string] $Category,
        [hashtable] $Details)

    $guid = ([Guid]$Item.Guid).ToString("D")
    $currentBatch = $script:ScenarioState.CurrentBatch
    $entityKind =
        if ($currentBatch -is [System.Collections.IDictionary] -and
            $currentBatch.Contains("EntityKind"))
        {
            [string]$currentBatch["EntityKind"]
        }
        elseif ($null -ne $currentBatch -and
            $currentBatch.PSObject.Properties.Name -contains "EntityKind")
        {
            [string]$currentBatch.EntityKind
        }
        elseif (@($script:Contacts.Values | Where-Object { ([Guid]$_.Guid).ToString("D") -eq $guid }).Count -gt 0)
        {
            "User"
        }
        else
        {
            "Group"
        }
    $phaseIndex = if ($null -ne $currentBatch) { [int]$currentBatch.PhaseIndex } else { [int]$script:ScenarioState.NextPhaseIndex }
    $phase = if ($null -ne $currentBatch) { [string]$currentBatch.Phase } else { $null }
    $record = [ordered]@{
        Guid = $guid
        Identity = [string]$Item.Identity
        EntityKind = $entityKind
        PhaseIndex = $phaseIndex
        Phase = $phase
        Category = $Category
        ResultCode = if ($null -ne $Details -and $Details.ContainsKey("ResultCode")) { [string]$Details.ResultCode } else { $null }
        Reason = if ($null -ne $Details -and $Details.ContainsKey("Reason")) { [string]$Details.Reason } else { $null }
        RecordedUtc = [datetime]::UtcNow.ToString("o")
    }
    $script:DataInconsistentPopulation[$guid] = $record

    if ($null -eq $script:PendingPopulationReplacement)
    {
        $script:PendingPopulationReplacement = [ordered]@{
            Status = "Pending"
            PhaseIndex = $phaseIndex
            Phase = $phase
            EntityKind = $entityKind
            FailedGuids = @($guid)
            RequestedUtc = [datetime]::UtcNow.ToString("o")
        }
    }
    else
    {
        if ([int]$script:PendingPopulationReplacement.PhaseIndex -ne $phaseIndex -or
            -not [string]::Equals(
                [string]$script:PendingPopulationReplacement.EntityKind,
                $entityKind,
                [StringComparison]::OrdinalIgnoreCase))
        {
            throw "Data inconsistencies from different phases or entity kinds cannot share one population replacement."
        }
        $script:PendingPopulationReplacement.FailedGuids = @(
            @($script:PendingPopulationReplacement.FailedGuids) + $guid |
                Select-Object -Unique
        )
        if ([string]$script:PendingPopulationReplacement.Status -in @("Creating", "Validating"))
        {
            $script:PendingPopulationReplacement.Status = "Pending"
            $script:PendingPopulationReplacement.ReplacementValidationFailedUtc =
                [datetime]::UtcNow.ToString("o")
        }
    }
}

function Invoke-DueValidations
{
    param(
        [switch] $AggregateFailures,
        [string[]] $OnlyGuids)

    $validationItems = @($script:PendingValidations.Values)
    if ($null -ne $OnlyGuids -and $OnlyGuids.Count -gt 0)
    {
        $allowedGuids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($guid in $OnlyGuids)
        {
            [void]$allowedGuids.Add(([Guid]$guid).ToString("D"))
        }
        $validationItems = @(
            $validationItems |
                Where-Object { $allowedGuids.Contains(([Guid]$_.Guid).ToString("D")) }
        )
    }

    if ($WhatIfTraffic)
    {
        foreach ($item in $validationItems)
        {
            Complete-Validation -Item $item -Status "Passed" -Details @{ WhatIf = $true }
        }
        return
    }

    $now = [datetime]::UtcNow
    $due = @($validationItems | Where-Object { (ConvertFrom-IsoUtc -Value ([string]$_.DueUtc)) -le $now })
    if ($due.Count -eq 0)
    {
        return
    }

    foreach ($item in $due)
    {
        $item.Attempts = [int]$item.Attempts + 1
    }

    try
    {
        $watermarks = Get-SyncCookieWatermarks
    }
    catch
    {
        Stop-LongevityTraffic -Category "SyncCookieReadFailure" -Message "Failed to read Object Store sync-cookie watermarks: $($_.Exception.Message)" -Exception $_.Exception
        return
    }

    $watermarkReady = @()
    foreach ($item in $due)
    {
        if (Test-ValidationWatermarkReached -Item $item -Watermarks $watermarks)
        {
            $watermarkReady += $item
            continue
        }

        if ((ConvertFrom-IsoUtc -Value ([string]$item.DeadlineUtc)) -le $now)
        {
            Complete-Validation -Item $item -Status "Failed" -Details @{
                Reason = "SyncCookieTimestampTimeout"
                MutationUtc = $item.MutationUtc
                Watermarks = $watermarks
            }
            if ($AggregateFailures)
            {
                [void]$script:PendingValidations.Remove([string]$item.Guid)
                Add-ScenarioBatchFailure -Category "SyncProgressTimeout" -Message "Object Store sync cookies did not advance past the mutation time for $($item.Identity)." -Data @{
                    Validation = $item
                    Watermarks = $watermarks
                }
                continue
            }
            Stop-LongevityTraffic -Category "SyncProgressTimeout" -Message "Object Store sync cookies did not advance past the mutation time for $($item.Identity)." -Data @{
                Validation = $item
                Watermarks = $watermarks
            }
            return
        }

        Complete-Validation -Item $item -Status "Deferred" -Details @{
            Reason = "WaitingForSyncCookieTimestamp"
            MutationUtc = $item.MutationUtc
            Watermarks = $watermarks
        }
    }

    $activeItems = @($watermarkReady | Where-Object { $_.ExpectedState -eq "Active" } | Select-Object -First $ValidationBatchSize)
    if ($activeItems.Count -gt 0)
    {
        try
        {
            $result = Invoke-ActiveValidationBatch -Items $activeItems
            if ($result.Deferred)
            {
                foreach ($item in $activeItems)
                {
                    if ((ConvertFrom-IsoUtc -Value ([string]$item.DeadlineUtc)) -le $now)
                    {
                        Complete-Validation -Item $item -Status "Failed" -Details @{ Result = $result }
                        if ($AggregateFailures)
                        {
                            [void]$script:PendingValidations.Remove([string]$item.Guid)
                            Add-ScenarioBatchFailure -Category "ConsistencyFailure" -Message "AD-to-L2 comparison did not converge for $($item.Identity)." -Data @{
                                Validation = $item
                                CompareResult = $result
                            }
                            continue
                        }
                        Stop-LongevityTraffic -Category "ConsistencyFailure" -Message "AD-to-L2 comparison did not converge for $($item.Identity)." -Data @{ Validation = $item; CompareResult = $result }
                        return
                    }
                    Complete-Validation -Item $item -Status "Deferred" -Details @{ Result = $result }
                }
            }
            else
            {
                foreach ($item in $activeItems)
                {
                    $code = [string]$result.CodesByGuid[[string]$item.Guid]
                    if ($code -eq "DataSame")
                    {
                        Complete-Validation -Item $item -Status "Passed" -Details @{ ResultCode = $code; ResultCount = $result.ResultCount }
                        continue
                    }

                    $itemResult = @{
                        ResultCode = $code
                        ObjectGuid = $item.Guid
                        Raw = $result.Raw
                    }
                    if ((ConvertFrom-IsoUtc -Value ([string]$item.DeadlineUtc)) -le $now)
                    {
                        Add-ScenarioDataInconsistency -Item $item -Category "ConsistencyFailure" -Details $itemResult
                        Complete-Validation -Item $item -Status "Failed" -Details $itemResult
                        if ($AggregateFailures)
                        {
                            [void]$script:PendingValidations.Remove([string]$item.Guid)
                            Add-ScenarioBatchFailure -Category "ConsistencyFailure" -Message "AD-to-L2 comparison did not converge for $($item.Identity)." -Data @{
                                Validation = $item
                                CompareResult = $itemResult
                            }
                            continue
                        }
                        Stop-LongevityTraffic -Category "ConsistencyFailure" -Message "AD-to-L2 comparison did not converge for $($item.Identity)." -Data @{
                            Validation = $item
                            CompareResult = $itemResult
                        }
                        return
                    }
                    Complete-Validation -Item $item -Status "Deferred" -Details $itemResult
                }
            }
        }
        catch
        {
            Stop-LongevityTraffic -Category "ValidationReadFailure" -Message "AD-to-L2 comparison failed: $($_.Exception.Message)" -Exception $_.Exception
            return
        }
    }

    foreach ($item in @($watermarkReady | Where-Object { $_.ExpectedState -eq "Deleted" } | Select-Object -First $ValidationBatchSize))
    {
        try
        {
            $result = Invoke-DeletedValidation -Item $item
            if ($result.Deferred)
            {
                if ((ConvertFrom-IsoUtc -Value ([string]$item.DeadlineUtc)) -le $now)
                {
                    if ([string]$result.Reason -eq "ObjectStillPresentInObjectStore")
                    {
                        Add-ScenarioDataInconsistency -Item $item -Category "DeletionConsistencyFailure" -Details $result
                    }
                    Complete-Validation -Item $item -Status "Failed" -Details $result
                    if ($AggregateFailures)
                    {
                        [void]$script:PendingValidations.Remove([string]$item.Guid)
                        Add-ScenarioBatchFailure -Category "DeletionConsistencyFailure" -Message "Deletion did not converge for $($item.Identity)." -Data @{
                            Validation = $item
                            CompareResult = $result
                        }
                        continue
                    }
                    Stop-LongevityTraffic -Category "DeletionConsistencyFailure" -Message "Deletion did not converge for $($item.Identity)." -Data @{ Validation = $item; CompareResult = $result }
                    return
                }
                Complete-Validation -Item $item -Status "Deferred" -Details $result
            }
            else
            {
                Complete-Validation -Item $item -Status "Passed" -Details $result
            }
        }
        catch
        {
            Stop-LongevityTraffic -Category "DeletionValidationReadFailure" -Message "Deletion validation failed: $($_.Exception.Message)" -Exception $_.Exception
            return
        }
    }
}

function Save-FailureDiagnostics
{
    param(
        [string] $Category,
        [string] $Message,
        [Exception] $Exception,
        [hashtable] $Data)

    $diagnosticDirectory = Join-Path $script:RunDirectory "failure-$([datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
    New-Item -Path $diagnosticDirectory -ItemType Directory -Force | Out-Null

    $failure = [ordered]@{
        TimestampUtc = [datetime]::UtcNow.ToString("o")
        Category = $Category
        Message = $Message
        ExceptionType = if ($null -eq $Exception) { $null } else { $Exception.GetType().FullName }
        Exception = if ($null -eq $Exception) { $null } else { $Exception.ToString() }
        Data = $Data
        RandomSeed = $RandomSeed
        Counters = $script:Counters
        PendingValidationCount = $script:PendingValidations.Count
    }
    $failure | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $diagnosticDirectory "failure.json") -Encoding UTF8

    try
    {
        Get-Service -Name "MSExchangeDirCacheService" | Format-List * | Out-File -LiteralPath (Join-Path $diagnosticDirectory "cache-service.txt") -Encoding UTF8
    }
    catch
    {
        $_ | Out-String | Set-Content -LiteralPath (Join-Path $diagnosticDirectory "cache-service-error.txt") -Encoding UTF8
    }

    try
    {
        $syncCookies = if ($WorkloadMode -eq "ScenarioTest")
        {
            Get-ScenarioSyncCookieRecords -ForestFqdn $script:ForestFqdn
        }
        else
        {
            Get-DirectoryObjectStoreSyncCookie -AccountPartition $script:ForestFqdn -IsReadFromObjectStore:$true
        }
        $syncCookies |
            ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath (Join-Path $diagnosticDirectory "sync-cookies.json") -Encoding UTF8
    }
    catch
    {
        $_ | Out-String | Set-Content -LiteralPath (Join-Path $diagnosticDirectory "sync-cookie-error.txt") -Encoding UTF8
    }

    $directoryLogRoot = "D:\DirectoryLogs"
    if (Test-Path -LiteralPath $directoryLogRoot)
    {
        Get-ChildItem -Path $directoryLogRoot -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTimeUtc -ge [datetime]::UtcNow.AddHours(-1) } |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 100 FullName, Length, LastWriteTimeUtc |
            Export-Csv -LiteralPath (Join-Path $diagnosticDirectory "recent-directory-logs.csv") -NoTypeInformation
    }
}

function Stop-LongevityTraffic
{
    param(
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [string] $Message,
        [Exception] $Exception,
        [hashtable] $Data)

    if ($script:StopRequested)
    {
        return
    }

    $script:StopRequested = $true
    $script:Failure = [ordered]@{
        TimestampUtc = [datetime]::UtcNow.ToString("o")
        Category = $Category
        Message = $Message
    }
    "$($script:Failure.TimestampUtc) $Category $Message" | Set-Content -LiteralPath $script:PausedMarkerPath -Encoding UTF8
    Write-RunEvent -Level "Error" -Message "Traffic paused: $Message" -Data @{ Category = $Category }
    Save-FailureDiagnostics -Category $Category -Message $Message -Exception $Exception -Data $Data
    Save-Checkpoint
}

function Initialize-TestPopulation
{
    $recipientCount = if ($WorkloadMode -eq "AttributeCoverage")
    {
        $CoverageRecipientCount
    }
    elseif ($WorkloadMode -eq "ScenarioTest")
    {
        $script:ScenarioCounts.N_User
    }
    else
    {
        $InitialRecipientCount
    }
    $groupCount = if ($WorkloadMode -eq "AttributeCoverage")
    {
        $CoverageGroupCount
    }
    elseif ($WorkloadMode -eq "ScenarioTest")
    {
        $script:ScenarioCounts.N_Groups
    }
    else
    {
        $InitialGroupCount
    }
    $recipientsToCreate = [math]::Max(0, $recipientCount - $script:Contacts.Count)
    $groupsToCreate = [math]::Max(0, $groupCount - $script:Groups.Count)

    Write-RunEvent -Level "Information" -Message "Ensuring the isolated test population is complete." -Data @{
        TargetRecipients = $recipientCount
        TargetGroups = $groupCount
        ExistingRecipients = $script:Contacts.Count
        ExistingGroups = $script:Groups.Count
        RecipientsToCreate = $recipientsToCreate
        GroupsToCreate = $groupsToCreate
        PopulationReused = $script:PopulationReused
        PopulationSourceRunDirectory = $script:ResolvedPopulationSourceRunDirectory
    }

    for ($index = 0; $index -lt $recipientsToCreate -and -not $script:StopRequested; $index++)
    {
        Invoke-TrafficOperation -Name "BootstrapContact" -Action { New-TestContact }
        if ($null -ne $script:PendingPopulationReplacement -and
            [string]$script:PendingPopulationReplacement.Status -eq "Creating")
        {
            Save-Checkpoint
        }
    }
    for ($index = 0; $index -lt $groupsToCreate -and -not $script:StopRequested; $index++)
    {
        Invoke-TrafficOperation -Name "BootstrapGroup" -Action { New-TestGroup }
        if ($null -ne $script:PendingPopulationReplacement -and
            [string]$script:PendingPopulationReplacement.Status -eq "Creating")
        {
            Save-Checkpoint
        }
    }
    Save-Checkpoint
}

function Import-ScenarioPopulation
{
    if ([string]::IsNullOrWhiteSpace($PopulationSourceRunDirectory))
    {
        return
    }

    $sourceRunDirectory = (Resolve-Path -LiteralPath $PopulationSourceRunDirectory -ErrorAction Stop).Path
    if ([string]::Equals($sourceRunDirectory, $script:RunDirectory, [StringComparison]::OrdinalIgnoreCase))
    {
        throw "Population source run directory must differ from the active run directory."
    }

    $sourceParametersPath = Join-Path $sourceRunDirectory "parameters.json"
    $sourceCheckpointPath = Join-Path $sourceRunDirectory "checkpoint.json"
    $sourceSummaryPath = Join-Path $sourceRunDirectory "summary.json"
    foreach ($requiredPath in @($sourceParametersPath, $sourceCheckpointPath, $sourceSummaryPath))
    {
        if (-not (Test-Path -LiteralPath $requiredPath))
        {
            throw "Population source is incomplete; required artifact is missing: $requiredPath"
        }
    }
    $maximumArtifactBytes = @{
        $sourceParametersPath = 4MB
        $sourceCheckpointPath = 128MB
        $sourceSummaryPath = 16MB
    }
    foreach ($artifactPath in $maximumArtifactBytes.Keys)
    {
        if ((Get-Item -LiteralPath $artifactPath).Length -gt [long]$maximumArtifactBytes[$artifactPath])
        {
            throw "Population source artifact exceeds its safety limit: $artifactPath"
        }
    }

    $sourceParameters = Get-Content -LiteralPath $sourceParametersPath -Raw | ConvertFrom-Json
    $sourceParameterNames = @(
        $sourceParameters.PSObject.Properties |
            ForEach-Object { $_.Name }
    )
    $sourceCheckpoint = Get-Content -LiteralPath $sourceCheckpointPath -Raw | ConvertFrom-Json
    $sourceSummary = Get-Content -LiteralPath $sourceSummaryPath -Raw | ConvertFrom-Json
    if (-not [string]::Equals([string]$sourceSummary.Status, "Passed", [StringComparison]::OrdinalIgnoreCase))
    {
        throw "Population source run '$sourceRunDirectory' did not finish with status Passed."
    }
    if (-not [string]::Equals([string]$sourceParameters.WorkloadMode, "ScenarioTest", [StringComparison]::OrdinalIgnoreCase))
    {
        throw "Population source run '$sourceRunDirectory' is not a ScenarioTest run."
    }
    if ($sourceParameterNames -notcontains "SharedPopulationVersion" -or
        [int]$sourceParameters.SharedPopulationVersion -ne $script:ScenarioSharedPopulationVersion)
    {
        throw "Population source run '$sourceRunDirectory' does not contain a compatible shared population."
    }
    if ($sourceParameterNames -notcontains "CleanupOnSuccess" -or
        [bool]$sourceParameters.CleanupOnSuccess)
    {
        throw "Population source run '$sourceRunDirectory' cleaned up its objects and cannot be reused."
    }

    $compatibilityChecks = @(
        [ordered]@{ Name = "Organization"; Source = [string]$sourceParameters.Organization; Requested = $Organization; CaseSensitive = $false }
        [ordered]@{ Name = "ObjectPrefix"; Source = [string]$sourceParameters.ObjectPrefix; Requested = $ObjectPrefix; CaseSensitive = $true }
        [ordered]@{ Name = "Side"; Source = [string]$sourceParameters.Side; Requested = $Side; CaseSensitive = $false }
        [ordered]@{ Name = "ObjectStoreDestination"; Source = [string]$sourceParameters.ObjectStoreDestination; Requested = $ObjectStoreDestination; CaseSensitive = $false }
    )
    foreach ($check in $compatibilityChecks)
    {
        $comparison = if ($check.CaseSensitive) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
        if (-not [string]::Equals([string]$check.Source, [string]$check.Requested, $comparison))
        {
            throw "Population source $($check.Name) '$($check.Source)' is incompatible with requested value '$($check.Requested)'."
        }
    }
    if ([bool]$sourceParameters.WhatIfTraffic -ne [bool]$WhatIfTraffic)
    {
        throw "Population source WhatIfTraffic mode is incompatible with the requested run."
    }

    $importedContacts = 0
    $missingImportedObjects = 0
    foreach ($contact in @($sourceCheckpoint.Contacts))
    {
        try
        {
            [void](Set-ScenarioEntityDistinguishedName -Entity $contact)
            $script:Contacts[[string]$contact.Identity] = $contact
            $importedContacts++
        }
        catch
        {
            $missingImportedObjects++
            Write-RunEvent -Level "Warning" -Message "Skipped missing shared contact '$($contact.Identity)'." -Data @{
                SourceRunDirectory = $sourceRunDirectory
                Guid = [string]$contact.Guid
                Error = $_.Exception.Message
            }
        }
    }

    $importedGroups = 0
    foreach ($group in @($sourceCheckpoint.Groups))
    {
        try
        {
            $group.Members = @($group.Members)
            [void](Set-ScenarioEntityDistinguishedName -Entity $group)
            $script:Groups[[string]$group.Identity] = $group
            $importedGroups++
        }
        catch
        {
            $missingImportedObjects++
            Write-RunEvent -Level "Warning" -Message "Skipped missing shared group '$($group.Identity)'." -Data @{
                SourceRunDirectory = $sourceRunDirectory
                Guid = [string]$group.Guid
                Error = $_.Exception.Message
            }
        }
    }

    $script:PopulationReused = $importedContacts -gt 0 -or $importedGroups -gt 0
    $script:ResolvedPopulationSourceRunDirectory = $sourceRunDirectory
    $script:PopulationImportCompleted = $true
    $script:PopulationGeneration =
        if ($sourceCheckpoint.PSObject.Properties.Name -contains "PopulationGeneration")
        {
            [int]$sourceCheckpoint.PopulationGeneration
        }
        else
        {
            0
        }
    if ($missingImportedObjects -gt 0)
    {
        $script:PopulationGeneration = [math]::Max(1, $script:PopulationGeneration + 1)
    }
    $script:ScenarioPopulationIdentitiesValidated = $true
    if ($importedContacts -lt [int]$script:ScenarioCounts.N_User -or
        $importedGroups -lt [int]$script:ScenarioCounts.N_Groups)
    {
        $script:ScenarioPopulationEstimatedMinutes = 15
    }
    else
    {
        $script:ScenarioPopulationEstimatedMinutes = 0
    }

    Write-RunEvent -Level "Information" -Message "Imported a compatible shared ScenarioTest population." -Data @{
        SourceRunDirectory = $sourceRunDirectory
        ImportedContacts = $importedContacts
        ImportedGroups = $importedGroups
        MissingContactsToCreate = [math]::Max(0, [int]$script:ScenarioCounts.N_User - $importedContacts)
        MissingGroupsToCreate = [math]::Max(0, [int]$script:ScenarioCounts.N_Groups - $importedGroups)
    }
    $parametersPath = Join-Path $script:RunDirectory "parameters.json"
    $runParameters = Get-Content -LiteralPath $parametersPath -Raw | ConvertFrom-Json
    $runParameters | Add-Member -MemberType NoteProperty -Name PopulationReused -Value $script:PopulationReused -Force
    $runParameters | Add-Member -MemberType NoteProperty -Name PopulationImportCompleted -Value $script:PopulationImportCompleted -Force
    $runParameters | Add-Member -MemberType NoteProperty -Name PopulationSourceRunDirectory -Value $script:ResolvedPopulationSourceRunDirectory -Force
    $runParameters | Add-Member -MemberType NoteProperty -Name PopulationEstimatedMinutes -Value $script:ScenarioPopulationEstimatedMinutes -Force
    $runParameters | Add-Member -MemberType NoteProperty -Name EstimatedMinutes -Value (Get-ScenarioTotalEstimatedMinutes) -Force
    $runParameters | Add-Member -MemberType NoteProperty -Name PopulationGeneration -Value $script:PopulationGeneration -Force
    Write-AtomicJsonSnapshot -Path $parametersPath -InputObject $runParameters -Depth 6
    Save-Checkpoint
}

function Initialize-ScenarioPopulationReplacement
{
    if ($null -eq $script:PendingPopulationReplacement)
    {
        return
    }

    $replacement = $script:PendingPopulationReplacement
    $phaseIndex = [int]$replacement.PhaseIndex
    $entityKind = [string]$replacement.EntityKind
    if ([string]$replacement.Status -eq "Pending")
    {
        $retiredEntities =
            if ($entityKind -eq "User")
            {
                @($script:Contacts.Values)
            }
            elseif ($entityKind -eq "Group")
            {
                @($script:Groups.Values)
            }
            else
            {
                throw "Unsupported population replacement entity kind '$entityKind'."
            }
        $script:PopulationGeneration++
        $retiredGuids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entity in $retiredEntities)
        {
            [void]$retiredGuids.Add(([Guid]$entity.Guid).ToString("D"))
            if ($entity.PSObject.Properties.Name -contains "DistinguishedName" -and
                -not [string]::IsNullOrWhiteSpace([string]$entity.DistinguishedName))
            {
                [void]$script:RetiredPopulationDistinguishedNames.Add([string]$entity.DistinguishedName)
            }
        }
        $retiredPopulationFile = "retired-population-p{0:D2}-g{1:D2}.json" -f $phaseIndex, $script:PopulationGeneration
        Write-AtomicJsonSnapshot `
            -Path (Join-Path $script:RunDirectory $retiredPopulationFile) `
            -InputObject ([ordered]@{
                TimestampUtc = [datetime]::UtcNow.ToString("o")
                PhaseIndex = $phaseIndex
                Phase = [string]$replacement.Phase
                EntityKind = $entityKind
                Generation = $script:PopulationGeneration
                FailedGuids = @($replacement.FailedGuids)
                RetiredEntities = $retiredEntities
            }) `
            -Depth 8

        if ($entityKind -eq "User")
        {
            $script:Contacts = @{}
        }
        else
        {
            $script:Groups = @{}
        }
        foreach ($validationGuid in @($script:PendingValidations.Keys))
        {
            if ($retiredGuids.Contains([string]$validationGuid))
            {
                [void]$script:PendingValidations.Remove([string]$validationGuid)
            }
        }
        $script:ScenarioState.NextPhaseIndex = $phaseIndex
        $script:ScenarioState.NextBatchIndex = 0
        $script:ScenarioState.CurrentBatch = $null
        $script:ScenarioState.CurrentBatchCompletedGuids = @()

        $retainedBatchSummaries = [Collections.Generic.List[object]]::new()
        foreach ($summary in @($script:ScenarioBatchSummaries | Where-Object { [int]$_.PhaseIndex -lt $phaseIndex }))
        {
            $retainedBatchSummaries.Add($summary)
        }
        $script:ScenarioBatchSummaries = $retainedBatchSummaries
        $retainedPhaseSummaries = [Collections.Generic.List[object]]::new()
        foreach ($summary in @($script:ScenarioPhaseSummaries | Where-Object { [int]$_.PhaseIndex -lt $phaseIndex }))
        {
            $retainedPhaseSummaries.Add($summary)
        }
        $script:ScenarioPhaseSummaries = $retainedPhaseSummaries
        $script:ScenarioCompletedObjectWork = [long](
            ($script:ScenarioBatchSummaries | Measure-Object ObjectCount -Sum).Sum)
        $script:Counters.ScenarioBatchesCompleted = [long]$script:ScenarioBatchSummaries.Count

        $planPattern = "scenario-plan-p{0:D2}-b*.json" -f $phaseIndex
        Get-ChildItem -LiteralPath $script:RunDirectory -Filter $planPattern -File -ErrorAction SilentlyContinue |
            Remove-Item -Force

        $replacement.Status = "Creating"
        $replacement.Generation = $script:PopulationGeneration
        $replacement.RetiredPopulationFile = $retiredPopulationFile
        $replacement.ReplacementStartedUtc = [datetime]::UtcNow.ToString("o")
        $script:PendingPopulationReplacement = $replacement
        $script:ScenarioPopulationIdentitiesValidated = $false
        Save-Checkpoint
        Write-RunEvent -Level "Warning" -Message "Retired the phase population after a proven data inconsistency." -Data @{
            PhaseIndex = $phaseIndex
            Phase = [string]$replacement.Phase
            EntityKind = $entityKind
            FailedGuids = @($replacement.FailedGuids)
            RetiredObjectCount = $retiredEntities.Count
            PopulationGeneration = $script:PopulationGeneration
            RetiredPopulationFile = $retiredPopulationFile
        }
    }
}

function Test-ScenarioPopulationReplacement
{
    if ($null -eq $script:PendingPopulationReplacement -or
        [string]$script:PendingPopulationReplacement.Status -notin @("Creating", "Validating"))
    {
        return
    }

    $entityKind = [string]$script:PendingPopulationReplacement.EntityKind
    $expectedCount =
        if ($entityKind -eq "User")
        {
            [int]$script:ScenarioCounts.N_User
        }
        else
        {
            [int]$script:ScenarioCounts.N_Groups
        }
    $actualCount =
        if ($entityKind -eq "User")
        {
            $script:Contacts.Count
        }
        else
        {
            $script:Groups.Count
        }
    if ($actualCount -lt $expectedCount)
    {
        throw "Replacement $entityKind population is incomplete: $actualCount/$expectedCount."
    }

    $replacementGuids = [Collections.Generic.List[Guid]]::new()
    $entities =
        if ($entityKind -eq "User")
        {
            @($script:Contacts.Values)
        }
        else
        {
            @($script:Groups.Values)
        }
    foreach ($entity in $entities)
    {
        $replacementGuids.Add([Guid]$entity.Guid)
    }
    $script:PendingPopulationReplacement.Status = "Validating"
    $script:PendingPopulationReplacement.ReplacementGuids =
        @($replacementGuids | ForEach-Object { $_.ToString("D") })
    $script:PendingPopulationReplacement.ValidationStartedUtc =
        [datetime]::UtcNow.ToString("o")
    Save-Checkpoint
    Wait-ScenarioBatchValidations -Guids $replacementGuids
    if ($script:StopRequested)
    {
        return
    }
    $remaining = @(
        $script:PendingPopulationReplacement.ReplacementGuids |
            Where-Object { $script:PendingValidations.ContainsKey([string]$_) }
    )
    if ($remaining.Count -gt 0)
    {
        throw "Replacement population validation is incomplete for $($remaining.Count) GUIDs."
    }
    $script:PendingPopulationReplacement.Status = "Validated"
    $script:PendingPopulationReplacement.ValidationCompletedUtc =
        [datetime]::UtcNow.ToString("o")
    Save-Checkpoint
}

function Complete-ScenarioPopulationReplacement
{
    if ($null -eq $script:PendingPopulationReplacement -or
        [string]$script:PendingPopulationReplacement.Status -ne "Validated")
    {
        return
    }

    $entityKind = [string]$script:PendingPopulationReplacement.EntityKind
    $actualCount =
        if ($entityKind -eq "User")
        {
            $script:Contacts.Count
        }
        else
        {
            $script:Groups.Count
        }

    $completed = [ordered]@{
        PhaseIndex = [int]$script:PendingPopulationReplacement.PhaseIndex
        Phase = [string]$script:PendingPopulationReplacement.Phase
        EntityKind = $entityKind
        FailedGuids = @($script:PendingPopulationReplacement.FailedGuids)
        Generation = [int]$script:PendingPopulationReplacement.Generation
        RetiredPopulationFile = [string]$script:PendingPopulationReplacement.RetiredPopulationFile
        CompletedUtc = [datetime]::UtcNow.ToString("o")
        ReplacementObjectCount = $actualCount
    }
    foreach ($bucket in @(
        "Recipient", "Group", "Mailbox", "Database", "Policy",
        "AddressBook", "Server", "Mta", "Computer", "Configuration",
        "ConfigurationUnit", "OrganizationRoot"))
    {
        if (-not $script:ScenarioTargets.ContainsKey($bucket))
        {
            continue
        }
        $filtered = [Collections.Generic.List[string]]::new()
        foreach ($distinguishedName in @($script:ScenarioTargets[$bucket]))
        {
            if (-not $script:RetiredPopulationDistinguishedNames.Contains([string]$distinguishedName))
            {
                $filtered.Add([string]$distinguishedName)
            }
        }
        $script:ScenarioTargets[$bucket] = $filtered
    }
    foreach ($contact in @($script:Contacts.Values))
    {
        Add-ScenarioTarget -Bucket "Recipient" -Object $contact
    }
    foreach ($group in @($script:Groups.Values))
    {
        Add-ScenarioTarget -Bucket "Group" -Object $group
        Add-ScenarioTarget -Bucket "Recipient" -Object $group
    }
    Save-ScenarioTargetContext
    $script:PopulationReplacementHistory.Add($completed)
    $script:PendingPopulationReplacement = $null
    Save-Checkpoint
    Write-RunEvent -Level "Information" -Message "Completed phase population replacement." -Data $completed
}

function Remove-ScenarioSupportingObjects
{
    foreach ($supportingObject in @($script:ScenarioSupportingObjects))
    {
        try
        {
            if (-not $WhatIfTraffic -and
                [string]$supportingObject.Kind -eq "Certificate" -and
                -not [string]::IsNullOrWhiteSpace([string]$supportingObject.Thumbprint))
            {
                Remove-Item -LiteralPath "$($supportingObject.StorePath)\$($supportingObject.Thumbprint)" -Force -ErrorAction Stop
            }
        }
        catch
        {
            Write-RunEvent -Level "Warning" -Message "Cleanup failed for supporting object $($supportingObject.Kind): $($_.Exception.Message)"
        }
    }
    $script:ScenarioSupportingObjects.Clear()
}

function Remove-TestPopulation
{
    Write-RunEvent -Level "Information" -Message "Cleaning up ledger-owned test objects." -Data @{
        Recipients = $script:Contacts.Count
        Groups = $script:Groups.Count
    }

    foreach ($group in @($script:Groups.Values))
    {
        try
        {
            if (-not $WhatIfTraffic)
            {
                $parameters = Get-CommandParameters -CommandName "Remove-DistributionGroup" -Parameters @{ Identity = ([Guid]$group.Guid); Confirm = $false; ErrorAction = "Stop" }
                Remove-DistributionGroup @parameters
            }
            $script:Groups.Remove([string]$group.Identity)
        }
        catch
        {
            Write-RunEvent -Level "Warning" -Message "Cleanup failed for group $($group.Identity): $($_.Exception.Message)"
        }
    }

    foreach ($contact in @($script:Contacts.Values))
    {
        try
        {
            if (-not $WhatIfTraffic)
            {
                $parameters = Get-CommandParameters -CommandName "Remove-MailContact" -Parameters @{ Identity = ([Guid]$contact.Guid); Confirm = $false; ErrorAction = "Stop" }
                Remove-MailContact @parameters
            }
            $script:Contacts.Remove([string]$contact.Identity)
        }
        catch
        {
            Write-RunEvent -Level "Warning" -Message "Cleanup failed for contact $($contact.Identity): $($_.Exception.Message)"
        }
    }
    Remove-ScenarioSupportingObjects
    Save-Checkpoint
}

function Write-RunSummary
{
    param(
        [datetime] $StartedUtc,
        [datetime] $FinishedUtc,
        [string] $Status)

    $elapsedSeconds = [math]::Max(0.001, ($FinishedUtc - $StartedUtc).TotalSeconds)
    $summary = [ordered]@{
        RunId = $script:RunId
        Status = $Status
        StartedUtc = $StartedUtc.ToString("o")
        FinishedUtc = $FinishedUtc.ToString("o")
        DurationHours = [math]::Round(($FinishedUtc - $StartedUtc).TotalHours, 4)
        ScenarioCommand = if ($WorkloadMode -eq "ScenarioTest") { $ScenarioCommand } else { $null }
        ScenarioSetMode = if ($WorkloadMode -eq "ScenarioTest") { $ScenarioSetMode } else { $null }
        SharedPopulationVersion = if ($WorkloadMode -eq "ScenarioTest") { if ($script:LegacyCommandSpecificPopulation) { 0 } else { $script:ScenarioSharedPopulationVersion } } else { $null }
        LegacyCommandSpecificPopulation = if ($WorkloadMode -eq "ScenarioTest") { $script:LegacyCommandSpecificPopulation } else { $null }
        ScenarioEstimatedMinutes = if ($WorkloadMode -eq "ScenarioTest") { Get-ScenarioEstimatedMinutes } else { $null }
        PreflightEstimatedMinutes = if ($WorkloadMode -eq "ScenarioTest") { $script:ScenarioPreflightEstimatedMinutes } else { $null }
        PopulationEstimatedMinutes = if ($WorkloadMode -eq "ScenarioTest") { $script:ScenarioPopulationEstimatedMinutes } else { $null }
        EstimatedMinutes = if ($WorkloadMode -eq "ScenarioTest") { Get-ScenarioTotalEstimatedMinutes } else { $null }
        ScenarioBatchTotal = if ($WorkloadMode -eq "ScenarioTest") { @((Get-ScenarioCommandDefinition).PhaseNames).Count * $script:ScenarioBatchesPerPhase } else { $null }
        RequestedOperationsPerSecond = $OperationsPerSecond
        ActualOperationsPerSecond = [math]::Round($script:Counters.OperationsSucceeded / $elapsedSeconds, 4)
        RandomSeed = $RandomSeed
        Counters = $script:Counters
        RemainingContacts = $script:Contacts.Count
        RemainingGroups = $script:Groups.Count
        PendingValidations = $script:PendingValidations.Count
        ScenarioCounts = $script:ScenarioCounts
        CompareCookieReadTimeoutSeconds = if ($WorkloadMode -eq "ScenarioTest") { $CompareCookieReadTimeoutSeconds } else { $null }
        ScenarioTargetQueryTimeoutSeconds = if ($WorkloadMode -eq "ScenarioTest") { $ScenarioTargetQueryTimeoutSeconds } else { $null }
        PreflightOnly = [bool]$PreflightOnly
        ScenarioPlanVersion = if ($WorkloadMode -eq "ScenarioTest") { $script:ScenarioPlanVersion } else { $null }
        ScenarioBatchesPerPhase = if ($WorkloadMode -eq "ScenarioTest") { $script:ScenarioBatchesPerPhase } else { $null }
        PopulationReused = if ($WorkloadMode -eq "ScenarioTest") { $script:PopulationReused } else { $null }
        PopulationImportCompleted = if ($WorkloadMode -eq "ScenarioTest") { $script:PopulationImportCompleted } else { $null }
        PopulationSourceRunDirectory = if ($WorkloadMode -eq "ScenarioTest") { $script:ResolvedPopulationSourceRunDirectory } else { $null }
        PopulationGeneration = if ($WorkloadMode -eq "ScenarioTest") { $script:PopulationGeneration } else { $null }
        DataInconsistentPopulation = if ($WorkloadMode -eq "ScenarioTest") { @($script:DataInconsistentPopulation.Values) } else { $null }
        PendingPopulationReplacement = if ($WorkloadMode -eq "ScenarioTest") { $script:PendingPopulationReplacement } else { $null }
        PopulationReplacementHistory = if ($WorkloadMode -eq "ScenarioTest") { @($script:PopulationReplacementHistory) } else { $null }
        RetiredPopulationDistinguishedNames = if ($WorkloadMode -eq "ScenarioTest") { @($script:RetiredPopulationDistinguishedNames) } else { $null }
        ScenarioState = $script:ScenarioState
        ScenarioPhaseSummaries = @($script:ScenarioPhaseSummaries)
        ScenarioBatchSummaries = @($script:ScenarioBatchSummaries)
        ScenarioLogSegments = if ($WorkloadMode -eq "ScenarioTest") { $script:ScenarioLogSegments } else { $null }
        ScenarioDetailLogIndex = $script:ScenarioDetailLogIndex
        ScenarioCompletedObjectWork = $script:ScenarioCompletedObjectWork
        Failure = $script:Failure
    }
    Write-AtomicJsonSnapshot `
        -Path (Join-Path $script:RunDirectory "summary.json") `
        -InputObject $summary `
        -Depth 8
    Write-RunStatusSnapshot -Status $Status
}

function ConvertTo-ScenarioBoolean
{
    param([object] $Value)

    if ($Value -is [bool])
    {
        return [bool]$Value
    }
    return "$Value" -match "^(?i:true|1|yes)$"
}

function ConvertTo-ScenarioGuid
{
    param(
        [Parameter(Mandatory)] [object] $Value,
        [Parameter(Mandatory)] [string] $Context)

    $values = @($Value)
    $guid = [Guid]::Empty
    if ($values.Count -ne 1 -or
        -not [Guid]::TryParse([string]$values[0], [ref]$guid) -or
        $guid -eq [Guid]::Empty)
    {
        throw "Scenario $Context must contain exactly one non-empty GUID; received $($values.Count) value(s)."
    }
    return $guid
}

function Get-ScenarioUniqueNames
{
    param([object[]] $Arrays)

    $names = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($array in $Arrays)
    {
        foreach ($name in @($array))
        {
            if ($seen.Add([string]$name))
            {
                $names.Add([string]$name)
            }
        }
    }
    return $names.ToArray()
}

function Get-ScenarioKnownMultiValued
{
    param([Parameter(Mandatory)] [string] $Name)

    return $Name -match "(?i)^(authOrig|unauthOrig|dLMemRejectPerms|dLMemSubmitPerms|member|proxyAddresses|publicDelegates|showInAddressBook|msExchPoliciesIncluded|msExchPoliciesExcluded|msExchCapabilityIdentifiers|msExchAlternateMailboxes|msExchMobileAllowedDeviceIds|msExchMobileBlockedDeviceIds|msExchNonCompliantDevices|msExchMultiMailboxDatabasesLink|msExchMultiMailboxGUIDs|msExchMultiMailboxLocationsLink|msExchSenderHintTranslations|msExchSharingAnonymousIdentities|msExchSharingPartnerIdentities|msExchTeamMailboxOwners|msExchUMCallingLineIds|msExchUserHoldPolicies|userCertificate|userSMIMECertificate|msExchSIDHistory)$"
}

function Get-ScenarioSyntheticMetadata
{
    param([Parameter(Mandatory)] [string] $Name)

    $syntax = "2.5.5.12"
    if ($Name -match "(?i)SID")
    {
        $syntax = "2.5.5.17"
    }
    elseif ($Name -match "(?i)SecurityDescriptor")
    {
        $syntax = "2.5.5.10"
    }
    elseif ($Name -match "(?i)(GUID|ImmutableId|Certificate)")
    {
        $syntax = "2.5.5.10"
    }
    elseif ($Name -match "(?i)(Link|DN$|^authOrig$|^unauthOrig$|^dLMemRejectPerms$|^dLMemSubmitPerms$|^manager$|^managedBy$|^member$|^altRecipient$|^publicDelegates$|^showInAddressBook$)")
    {
        $syntax = "2.5.5.1"
    }
    elseif ($Name -match "(?i)(Enable|Disabled|DeliverAndRedirect|UseOAB|IsMSODirsynced|MAPIRecipient|RequireAuth|CalendarRepairDisabled|MailboxAuditEnable|DBUseDefaults|HideDLMembership|ReportTo|ReplyTo)")
    {
        $syntax = "2.5.5.8"
    }
    elseif ($Name -match "(?i)(Count|Flags|Quota|Status|TypeDetails|Type$|Capacity|Encoding|Length|Index|Version|SecurityFlags|RemoteRecipientType|RecipientDisplayType|GroupType|CountryCode|HygieneSCL|UserAccountControl|ProvisioningFlags)")
    {
        $syntax = "2.5.5.9"
    }

    return [ordered]@{
        Name = $Name
        AttributeSyntax = $syntax
        OMSyntax = 0
        IsSingleValued = -not (Get-ScenarioKnownMultiValued -Name $Name)
        RangeUpper = 0
        RangeLower = 0
        LinkId = $null
        SystemOnly = $false
        Constructed = $false
        Defunct = $false
    }
}

function Get-ScenarioAttributeMetadata
{
    param([Parameter(Mandatory)] [string] $Name)

    if ($script:ScenarioSchema.ContainsKey($Name))
    {
        return $script:ScenarioSchema[$Name]
    }

    if ($WhatIfTraffic)
    {
        $metadata = Get-ScenarioSyntheticMetadata -Name $Name
        $script:ScenarioSchema[$Name] = $metadata
        return $metadata
    }

    $rootDse = Get-ADRootDSE -ErrorAction Stop
    $escapedName = $Name.Replace("\", "\5c").Replace("*", "\2a").Replace("(", "\28").Replace(")", "\29").Replace([string][char]0, "\00")
    $schemaObjects = @(Get-ADObject `
        -SearchBase $rootDse.schemaNamingContext `
        -LDAPFilter "(&(objectClass=attributeSchema)(lDAPDisplayName=$escapedName))" `
        -Properties lDAPDisplayName, attributeSyntax, oMSyntax, isSingleValued, rangeUpper, rangeLower, linkID, systemOnly, systemFlags `
        -ResultSetSize 1 `
        -ErrorAction Stop)
    if ($schemaObjects.Count -eq 0)
    {
        throw "LDAP attribute '$Name' is not present in the directory schema."
    }

    $schemaObject = $schemaObjects[0]
    $metadata = ConvertTo-ScenarioSchemaMetadata -Name $Name -SchemaObject $schemaObject
    $script:ScenarioSchema[$Name] = $metadata
    return $metadata
}

function ConvertTo-ScenarioSchemaMetadata
{
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [object] $SchemaObject)

    $nameProperty = $SchemaObject.PSObject.Properties["lDAPDisplayName"]
    $attributeName = if ($null -ne $nameProperty -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value))
    {
        [string]$nameProperty.Value
    }
    else
    {
        $Name
    }
    $systemFlagsProperty = $SchemaObject.PSObject.Properties["systemFlags"]
    $systemFlags = if ($null -eq $systemFlagsProperty -or $null -eq $systemFlagsProperty.Value)
    {
        0L
    }
    else
    {
        [int64]$systemFlagsProperty.Value
    }
    $omSyntaxProperty = $SchemaObject.PSObject.Properties["oMSyntax"]
    $defunctProperty = $SchemaObject.PSObject.Properties["isDefunct"]
    return [ordered]@{
        Name = $attributeName
        AttributeSyntax = [string]$SchemaObject.attributeSyntax
        OMSyntax = if ($null -eq $omSyntaxProperty -or $null -eq $omSyntaxProperty.Value) { 0 } else { [int64]$omSyntaxProperty.Value }
        IsSingleValued = ConvertTo-ScenarioBoolean $SchemaObject.isSingleValued
        RangeUpper = if ($null -eq $SchemaObject.rangeUpper) { 0 } else { [int64]$SchemaObject.rangeUpper }
        RangeLower = if ($null -eq $SchemaObject.rangeLower) { 0 } else { [int64]$SchemaObject.rangeLower }
        LinkId = if ($null -eq $SchemaObject.linkID) { $null } else { [string]$SchemaObject.linkID }
        SystemOnly = ConvertTo-ScenarioBoolean $SchemaObject.systemOnly
        Constructed = (($systemFlags -band 0x4) -ne 0)
        Defunct = if ($null -eq $defunctProperty) { $false } else { ConvertTo-ScenarioBoolean $defunctProperty.Value }
    }
}

function Get-ScenarioResultLimitParameter
{
    param([Parameter(Mandatory)] [object] $Command)

    $moduleName = [string]$Command.ModuleName
    if ($moduleName -match "(?i)^ActiveDirectory" -and
        $null -ne $Command.Parameters -and
        $Command.Parameters.ContainsKey("ResultSetSize"))
    {
        return "ResultSetSize"
    }
    if ($null -ne $Command.Parameters -and $Command.Parameters.ContainsKey("ResultSize"))
    {
        return "ResultSize"
    }
    if ($null -ne $Command.Parameters -and $Command.Parameters.ContainsKey("ResultSetSize"))
    {
        return "ResultSetSize"
    }
    return $null
}

function Test-ScenarioSyntheticCommandValueShapes
{
    $singleBinary = ConvertTo-ScenarioCommandValue -Value ([byte[]](1, 2, 3, 4))
    if ($singleBinary -isnot [byte[]] -or $singleBinary.Length -ne 4)
    {
        throw "Synthetic ScenarioTest single binary command-value shape test failed."
    }

    $multiBinaryInput = [byte[][]]@(
        [byte[]](1, 2),
        [byte[]](3, 4))
    $multiBinary = ConvertTo-ScenarioCommandValue -Value $multiBinaryInput
    if ($multiBinary -isnot [byte[][]] -or
        $multiBinary.Length -ne 2 -or
        $multiBinary[0] -isnot [byte[]] -or
        $multiBinary[1] -isnot [byte[]])
    {
        throw "Synthetic ScenarioTest multivalue binary command-value shape test failed."
    }

    $multiInteger = ConvertTo-ScenarioCommandValue -Value ([int[]](775, 791))
    if ($multiInteger -isnot [object[]] -or
        $multiInteger -is [int[]] -or
        $multiInteger.Length -ne 2 -or
        $multiInteger[0] -isnot [int] -or
        $multiInteger[1] -isnot [int])
    {
        throw "Synthetic ScenarioTest multivalue integer command-value shape test failed."
    }

    Write-RunEvent -Level "Information" -Message "Synthetic ScenarioTest command-value shape test passed." -Data @{
        SingleBinaryType = $singleBinary.GetType().FullName
        MultiBinaryType = $multiBinary.GetType().FullName
        MultiIntegerType = $multiInteger.GetType().FullName
    }
}

function Get-ScenarioTargetQueryParameters
{
    param(
        [Parameter(Mandatory)] [string] $CommandName,
        [Parameter(Mandatory)] [object] $Command,
        [switch] $Unlimited,
        [ValidateRange(1, 1000)]
        [int] $ResultLimit = 0)

    $parameters = @{ ErrorAction = "Stop" }
    $resultLimitParameter = Get-ScenarioResultLimitParameter -Command $Command
    $serverSideLimitApplied = $false
    if ($ResultLimit -gt 0 -and $null -ne $resultLimitParameter)
    {
        $parameters[$resultLimitParameter] = $ResultLimit
        $serverSideLimitApplied = $true
    }
    elseif ($Unlimited -and $null -ne $resultLimitParameter)
    {
        $parameters[$resultLimitParameter] = "Unlimited"
        $serverSideLimitApplied = $true
    }

    if ($CommandName -match "(?i)^Get-AD(Computer|User|Group)$")
    {
        if ($Command.Parameters.ContainsKey("Filter"))
        {
            $parameters.Filter = "*"
        }
        if ($Command.Parameters.ContainsKey("Properties"))
        {
            $parameters.Properties = "objectSid"
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Organization) -and $Command.Parameters.ContainsKey("Organization"))
    {
        $parameters.Organization = $Organization
    }
    return [pscustomobject]@{
        Parameters = $parameters
        ResultLimitParameter = $resultLimitParameter
        ServerSideLimitApplied = $serverSideLimitApplied
    }
}

function Invoke-ScenarioTargetQueryWithTimeout
{
    param(
        [Parameter(Mandatory)] [string] $CommandName,
        [Parameter(Mandatory)] [hashtable] $QueryParameters,
        [Parameter(Mandatory)] [int] $TimeoutSeconds)

    $outputPath = Join-Path $script:RunDirectory ("target-query-{0}.clixml" -f ([Guid]::NewGuid().ToString("N")))
    $commandLiteral = ConvertTo-ScenarioPowerShellLiteral -Value $CommandName
    $outputLiteral = ConvertTo-ScenarioPowerShellLiteral -Value $outputPath
    $parameterLines = [Collections.Generic.List[string]]::new()
    foreach ($name in @($QueryParameters.Keys))
    {
        if ($name -eq "ErrorAction")
        {
            continue
        }
        $value = $QueryParameters[$name]
        if ($value -is [int] -or $value -is [long])
        {
            $literal = [string]$value
        }
        else
        {
            $literal = ConvertTo-ScenarioPowerShellLiteral -Value ([string]$value)
        }
        [void]$parameterLines.Add(("`$queryParameters[{0}] = {1}" -f `
                (ConvertTo-ScenarioPowerShellLiteral -Value ([string]$name)), $literal))
    }

    $childScript = @'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try
{
    Add-PSSnapin *e2010* -ErrorAction SilentlyContinue
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
    if ($null -ne (Get-Command "Get-AccountPartition" -ErrorAction SilentlyContinue))
    {
        @(Get-AccountPartition -ErrorAction SilentlyContinue) | Out-Null
    }

    $queryParameters = @{ ErrorAction = "Stop" }
    __PARAMETER_LINES__
    $command = Get-Command __COMMAND__ -ErrorAction Stop
    $items = @(& $command.Name @queryParameters | Select-Object -First 10)
    switch (__COMMAND__)
    {
        "Get-Recipient" {
            $items = @($items | Select-Object Guid,RecipientTypeDetails,DistinguishedName)
        }
        "Get-DistributionGroup" {
            $items = @($items | Select-Object Guid,DistinguishedName)
        }
        { $_ -in @("Get-ADComputer", "Get-ADUser", "Get-ADGroup") } {
            $items = @($items | ForEach-Object {
                $sidBytes = $null
                if ($null -ne $_.objectSid)
                {
                    if ($_.objectSid -is [Security.Principal.SecurityIdentifier])
                    {
                        $sidBytes = New-Object byte[] $_.objectSid.BinaryLength
                        $_.objectSid.GetBinaryForm($sidBytes, 0)
                    }
                    elseif ($_.objectSid -is [byte[]])
                    {
                        $sidBytes = New-Object byte[] $_.objectSid.Length
                        [Array]::Copy($_.objectSid, $sidBytes, $_.objectSid.Length)
                    }
                    else
                    {
                        try
                        {
                            $sid = [Security.Principal.SecurityIdentifier]::new([string]$_.objectSid)
                            $sidBytes = New-Object byte[] $sid.BinaryLength
                            $sid.GetBinaryForm($sidBytes, 0)
                        }
                        catch
                        {
                        }
                    }
                }
                [pscustomobject]@{
                    Guid = $_.Guid
                    DistinguishedName = [string]$_.DistinguishedName
                    objectSid = $sidBytes
                }
            })
        }
        default {
            $items = @($items | Select-Object Guid,DistinguishedName,RecipientTypeDetails)
        }
    }
    $items | Export-Clixml -LiteralPath __OUTPUT__ -Depth 5
    [ordered]@{ Succeeded = $true; ResultCount = $items.Count } | ConvertTo-Json -Compress
    exit 0
}
catch
{
    $messages = [Collections.Generic.List[string]]::new()
    $current = $_.Exception
    while ($null -ne $current)
    {
        if (-not [string]::IsNullOrWhiteSpace([string]$current.Message))
        {
            [void]$messages.Add(([string]$current.Message).Trim())
        }
        $current = $current.InnerException
    }
    [ordered]@{ Succeeded = $false; Error = ($messages -join " --> ") } | ConvertTo-Json -Compress
    exit 2
}
'@
    $childScript = $childScript.Replace("__PARAMETER_LINES__", ($parameterLines -join [Environment]::NewLine))
    $childScript = $childScript.Replace("__COMMAND__", $commandLiteral)
    $childScript = $childScript.Replace("__OUTPUT__", $outputLiteral)
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))

    $powershellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $powershellPath))
    {
        $powershellCommand = Get-Command "powershell.exe" -ErrorAction Stop
        $powershellPath = [string]$powershellCommand.Source
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $powershellPath
    $startInfo.Arguments = "-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try
    {
        if (-not $process.Start())
        {
            throw "Could not start the ScenarioTest target-query child process."
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timeoutMilliseconds = [int]([math]::Min([int]::MaxValue, $TimeoutSeconds * 1000))
        if (-not $process.WaitForExit($timeoutMilliseconds))
        {
            $processId = $process.Id
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            throw [TimeoutException]::new("ScenarioTest target query '$CommandName' exceeded $TimeoutSeconds seconds in child process $processId.")
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $diagnostics = (([string]$stdout).Trim() + " " + ([string]$stderr).Trim()).Trim()
        if ($diagnostics.Length -gt 4096)
        {
            $diagnostics = $diagnostics.Substring(0, 4096) + "...[truncated]"
        }
        if ($process.ExitCode -ne 0)
        {
            throw "ScenarioTest target-query child exited with code $($process.ExitCode): $diagnostics"
        }
        if (-not (Test-Path -LiteralPath $outputPath))
        {
            throw "ScenarioTest target-query child returned no result file. Diagnostics: $diagnostics"
        }
        return @(Import-Clixml -LiteralPath $outputPath)
    }
    finally
    {
        if ($null -ne $process)
        {
            $process.Dispose()
        }
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-ScenarioResultLimitParameterSelection
{
    $resultSizeCommand = [pscustomobject]@{
        ModuleName = "Microsoft.Exchange.Management.PowerShell.SnapIn"
        Parameters = @{ ResultSize = $null }
    }
    $resultSetSizeCommand = [pscustomobject]@{
        ModuleName = "ActiveDirectory"
        Parameters = @{ ResultSetSize = $null }
    }
    $unlimitedCommand = [pscustomobject]@{
        ModuleName = "Test"
        Parameters = @{ Identity = $null }
    }
    $resultSize = Get-ScenarioResultLimitParameter -Command $resultSizeCommand
    $resultSetSize = Get-ScenarioResultLimitParameter -Command $resultSetSizeCommand
    $neither = Get-ScenarioResultLimitParameter -Command $unlimitedCommand
    if ($resultSize -ne "ResultSize" -or $resultSetSize -ne "ResultSetSize" -or $null -ne $neither)
    {
        throw "Synthetic ScenarioTest result-limit parameter selection failed."
    }
    Write-RunEvent -Level "Information" -Message "Synthetic ScenarioTest result-limit parameter selection test passed." -Data @{
        ResultSizeParameter = $resultSize
        ResultSetSizeParameter = $resultSetSize
        NeitherParameter = $neither
    }
}

function Test-ScenarioSyntheticTargetQueryParameters
{
    $computerCommand = [pscustomobject]@{
        ModuleName = "ActiveDirectory"
        Parameters = @{
            Filter = $null
            ResultSetSize = $null
            Properties = $null
        }
    }
    $selection = Get-ScenarioTargetQueryParameters `
        -CommandName "Get-ADComputer" `
        -Command $computerCommand `
        -ResultLimit 10
    if ($selection.ResultLimitParameter -ne "ResultSetSize" -or
        -not $selection.ServerSideLimitApplied -or
        $selection.Parameters.Filter -ne "*" -or
        $selection.Parameters.Properties -ne "objectSid")
    {
        throw "Synthetic ScenarioTest target-query parameter selection failed."
    }
    Write-RunEvent -Level "Information" -Message "Synthetic ScenarioTest target-query parameter selection test passed." -Data @{
        ResultLimitParameter = $selection.ResultLimitParameter
        Filter = $selection.Parameters.Filter
        Properties = $selection.Parameters.Properties
        ServerSideLimitApplied = $selection.ServerSideLimitApplied
    }
}

function Test-ScenarioSyntheticSchemaMetadata
{
    $constructedSchemaObject = [pscustomobject]@{
        lDAPDisplayName = "syntheticConstructed"
        attributeSyntax = "2.5.5.1"
        oMSyntax = 127
        isSingleValued = $true
        rangeUpper = 256
        rangeLower = 1
        linkID = $null
        systemOnly = $false
        systemFlags = 0x4
    }
    $ordinarySchemaObject = [pscustomobject]@{
        lDAPDisplayName = "syntheticOrdinary"
        attributeSyntax = "2.5.5.12"
        oMSyntax = 64
        isSingleValued = $true
        rangeUpper = 1024
        rangeLower = 1
        linkID = $null
        systemOnly = $false
        systemFlags = 0
    }
    $linkedSchemaObject = [pscustomobject]@{
        lDAPDisplayName = "syntheticLinked"
        attributeSyntax = "2.5.5.14"
        oMSyntax = 64
        isSingleValued = $false
        rangeUpper = 0
        rangeLower = 0
        linkID = 1729
        systemOnly = $false
        systemFlags = 0
    }
    $constructed = ConvertTo-ScenarioSchemaMetadata -Name "syntheticConstructed" -SchemaObject $constructedSchemaObject
    $ordinary = ConvertTo-ScenarioSchemaMetadata -Name "syntheticOrdinary" -SchemaObject $ordinarySchemaObject
    $linked = ConvertTo-ScenarioSchemaMetadata -Name "syntheticLinked" -SchemaObject $linkedSchemaObject
    if (-not $constructed.Constructed -or $ordinary.Constructed -or
        $constructed.OMSyntax -ne 127 -or $ordinary.OMSyntax -ne 64 -or
        (Get-ScenarioGeneratorKind -Metadata $linked) -ne "DNString")
    {
        throw "Synthetic ScenarioTest schema metadata test failed."
    }
    Write-RunEvent -Level "Information" -Message "Synthetic ScenarioTest schema metadata test passed." -Data @{
        ConstructedSystemFlags = $constructedSchemaObject.systemFlags
        OrdinarySystemFlags = $ordinarySchemaObject.systemFlags
        Constructed = $constructed.Constructed
        Ordinary = $ordinary.Constructed
        LinkedGeneratorKind = Get-ScenarioGeneratorKind -Metadata $linked
    }
}

function Test-ScenarioSyntheticValueBounds
{
    $entity = [pscustomobject]@{
        Name = "ScenarioValueBounds"
        Guid = [Guid]::NewGuid()
    }
    $initialsMetadata = [ordered]@{
        Name = "Initials"
        AttributeSyntax = "2.5.5.12"
        IsSingleValued = $true
        RangeUpper = 6
        RangeLower = 1
    }
    $planTypeMetadata = [ordered]@{
        Name = "msExchMailboxPlanType"
        AttributeSyntax = "2.5.5.12"
        IsSingleValued = $true
        RangeUpper = 5
        RangeLower = 1
    }
    $configurationXmlMetadata = [ordered]@{
        Name = "msExchConfigurationXML"
        AttributeSyntax = "2.5.5.12"
        IsSingleValued = $true
        RangeUpper = 100000
        RangeLower = 0
    }
    $sharingAnonymousMetadata = [ordered]@{
        Name = "msExchSharingAnonymousIdentities"
        AttributeSyntax = "2.5.5.17"
        IsSingleValued = $false
        RangeUpper = 0
        RangeLower = 0
    }
    $initialsRandom = [Random]::new(1729)
    $initials = New-ScenarioTypedValue -Metadata $initialsMetadata -Entity $entity -Random $initialsRandom
    $planType = New-ScenarioTypedValue -Metadata $planTypeMetadata -Entity $entity -Random ([Random]::new(1729))
    $configurationXml = New-ScenarioTypedValue -Metadata $configurationXmlMetadata -Entity $entity -Random ([Random]::new(1729))
    $sharingAnonymousValues = @(New-ScenarioTypedValues `
        -Metadata $sharingAnonymousMetadata `
        -Entity $entity `
        -Random ([Random]::new(1729)))
    try
    {
        $configurationDocument = [xml]$configurationXml
    }
    catch
    {
        throw "Synthetic ScenarioTest configuration XML generation produced invalid XML: $($_.Exception.Message)"
    }
    if ($initials.Length -lt 1 -or $initials.Length -gt 6 -or
        $planType.Length -lt 1 -or $planType.Length -gt 5 -or
        $initials -cnotmatch "^[A-Z0-9]+$" -or $planType -cnotmatch "^[A-Z0-9]+$" -or
        $configurationDocument.DocumentElement.LocalName -ne "UserConfig" -or
        $sharingAnonymousValues.Count -lt 1 -or
        @($sharingAnonymousValues | Where-Object {
            [string]$_ -notmatch "^calendar\\[0-9a-fA-F-]{36}:[A-Za-z0-9]+$"
        }).Count -gt 0)
    {
        throw "Synthetic ScenarioTest bounded string generation failed."
    }
    Write-RunEvent -Level "Information" -Message "Synthetic ScenarioTest bounded string generation test passed." -Data @{
        Initials = $initials
        InitialsLength = $initials.Length
        MailboxPlanType = $planType
        MailboxPlanTypeLength = $planType.Length
        ConfigurationXmlRoot = $configurationDocument.DocumentElement.LocalName
        SharingAnonymousIdentityCount = $sharingAnonymousValues.Count
    }
}

function Test-ScenarioSyntheticSidValue
{
    $entity = [pscustomobject]@{
        Name = "ScenarioSidValue"
        Guid = [Guid]::NewGuid()
    }
    $metadata = [ordered]@{
        Name = "msExchForeignGroupSid"
        AttributeSyntax = "2.5.5.17"
        IsSingleValued = $true
        RangeUpper = 0
        RangeLower = 0
    }
    $sid = [Security.Principal.SecurityIdentifier]::new("S-1-5-21-3111111111-2222222222-3333333333-1729")
    $bytes = New-ScenarioTypedValue -Metadata $metadata -Entity $entity -Random ([Random]::new(1729)) -ObjectSid (ConvertTo-ScenarioSidBytes -Value $sid)
    $roundTrip = [Security.Principal.SecurityIdentifier]::new([byte[]]$bytes, 0)
    $valueArray = @(ConvertTo-ScenarioValueArray -Value $bytes)
    $sidHistoryMetadata = [ordered]@{
        Name = "msExchSIDHistory"
        AttributeSyntax = "2.5.5.17"
        IsSingleValued = $false
        RangeUpper = 0
        RangeLower = 0
    }
    $sidHistoryValues = @(New-ScenarioTypedValues `
        -Metadata $sidHistoryMetadata `
        -Entity $entity `
        -Random ([Random]::new(1729)) `
        -ObjectSid (ConvertTo-ScenarioSidBytes -Value $sid))
    if ($bytes -isnot [byte[]] -or
        $roundTrip.Value -ne $sid.Value -or
        $valueArray.Count -ne 1 -or
        $valueArray[0] -isnot [byte[]] -or
        $sidHistoryValues.Count -lt 1 -or
        @($sidHistoryValues | Where-Object {
            $_ -isnot [Security.Principal.SecurityIdentifier]
        }).Count -gt 0)
    {
        throw "Synthetic ScenarioTest SID generation failed."
    }
    Write-RunEvent -Level "Information" -Message "Synthetic ScenarioTest SID generation test passed." -Data @{
        Sid = $roundTrip.Value
        ByteCount = $bytes.Length
        SidHistoryCount = $sidHistoryValues.Count
    }
}

function Get-ScenarioCommandOutput
{
    param(
        [Parameter(Mandatory)] [string] $CommandName,
        [switch] $Unlimited,
        [ValidateRange(1, 1000)]
        [int] $ResultLimit = 0)

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($null -eq $command)
    {
        return @()
    }

    $querySelection = Get-ScenarioTargetQueryParameters `
        -CommandName $CommandName `
        -Command $command `
        -Unlimited:$Unlimited `
        -ResultLimit $ResultLimit
    $parameters = $querySelection.Parameters
    $resultLimitParameter = $querySelection.ResultLimitParameter
    $serverSideLimitApplied = $querySelection.ServerSideLimitApplied
    $startedUtc = [datetime]::UtcNow
    $result = @()
    $queryStatus = "Failed"
    try
    {
        Write-RunStatusSnapshot -Status "Starting"
        if ($WorkloadMode -eq "ScenarioTest")
        {
            Write-RunEvent -Level "Information" -Message "Starting ScenarioTest target-pool query." -Data @{
                CommandName = $CommandName
                ResultLimit = $ResultLimit
                ResultLimitParameter = $resultLimitParameter
                ServerSideLimitApplied = $serverSideLimitApplied
            }
        }
        if ($WorkloadMode -eq "ScenarioTest")
        {
            $result = @(Invoke-ScenarioTargetQueryWithTimeout `
                -CommandName $CommandName `
                -QueryParameters $parameters `
                -TimeoutSeconds $ScenarioTargetQueryTimeoutSeconds)
        }
        else
        {
            $result = @(& $command.Name @parameters)
        }
        $queryStatus = "Succeeded"
        return $result
    }
    catch
    {
        if ($WorkloadMode -eq "ScenarioTest")
        {
            Write-RunEvent -Level "Warning" -Message "ScenarioTest target-pool query failed." -Data @{
                CommandName = $CommandName
                ElapsedMilliseconds = [math]::Round(([datetime]::UtcNow - $startedUtc).TotalMilliseconds, 0)
                Exception = Get-ScenarioExceptionChain -Exception $_.Exception
            }
        }
        return @()
    }
    finally
    {
        if ($WorkloadMode -eq "ScenarioTest")
        {
            Write-RunEvent -Level "Information" -Message "Completed ScenarioTest target-pool query." -Data @{
                CommandName = $CommandName
                ResultCount = $result.Count
                Status = $queryStatus
                ElapsedMilliseconds = [math]::Round(([datetime]::UtcNow - $startedUtc).TotalMilliseconds, 0)
            }
        }
    }
}

function Resolve-ScenarioTargetDistinguishedName
{
    param([Parameter(Mandatory)] [object] $Object)

    $dnProperty = $Object.PSObject.Properties["DistinguishedName"]
    $candidate = if ($null -ne $dnProperty) { [string]$dnProperty.Value } else { [string]$Object }
    $guid = [Guid]::Empty
    $guidProperty = $Object.PSObject.Properties["Guid"]
    if ($null -ne $guidProperty)
    {
        [void][Guid]::TryParse([string]$guidProperty.Value, [ref]$guid)
    }
    $identity = if ($guid -ne [Guid]::Empty) { $guid } elseif (-not [string]::IsNullOrWhiteSpace($candidate)) { $candidate } else { $null }
    if ($null -eq $identity)
    {
        throw "Scenario target has neither a valid GUID nor a distinguished name."
    }
    $adObject = Get-ADObject -Identity $identity -Properties DistinguishedName -ErrorAction Stop
    $resolved = [string]$adObject.DistinguishedName
    if ([string]::IsNullOrWhiteSpace($resolved) -or $resolved -notmatch "(?i)(^|,)DC=")
    {
        throw "Scenario target identity '$identity' did not resolve to an LDAP distinguished name."
    }
    return $resolved
}

function Add-ScenarioTarget
{
    param(
        [Parameter(Mandatory)] [string] $Bucket,
        [object] $Object,
        [switch] $ResolveDistinguishedName)

    if ($null -eq $Object)
    {
        return
    }
    $dn = if ($ResolveDistinguishedName -and -not $WhatIfTraffic)
    {
        Resolve-ScenarioTargetDistinguishedName -Object $Object
    }
    elseif ($Object.PSObject.Properties.Name -contains "DistinguishedName")
    {
        [string]$Object.DistinguishedName
    }
    else
    {
        [string]$Object
    }
    if (-not $WhatIfTraffic -and $dn -notmatch "(?i)(^|,)DC=")
    {
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($dn))
    {
        if (-not $script:ScenarioTargets.ContainsKey($Bucket))
        {
            $script:ScenarioTargets[$Bucket] = [Collections.Generic.List[string]]::new()
        }
        if (-not ($script:ScenarioTargets[$Bucket] -contains $dn))
        {
            $script:ScenarioTargets[$Bucket].Add($dn)
        }
    }
}

function Add-ScenarioGuidTarget
{
    param(
        [Parameter(Mandatory)] [string] $Bucket,
        [object] $Value)

    $guid = [Guid]::Empty
    if ($null -eq $Value -or -not [Guid]::TryParse([string]$Value, [ref]$guid) -or $guid -eq [Guid]::Empty)
    {
        return
    }
    if (-not $script:ScenarioTargets.ContainsKey($Bucket))
    {
        $script:ScenarioTargets[$Bucket] = [Collections.Generic.List[string]]::new()
    }
    $guidText = $guid.ToString()
    if (-not ($script:ScenarioTargets[$Bucket] -contains $guidText))
    {
        $script:ScenarioTargets[$Bucket].Add($guidText)
    }
}

function ConvertTo-ScenarioSidBytes
{
    param([object] $Value)

    if ($null -eq $Value)
    {
        return $null
    }
    if ($Value -is [byte[]])
    {
        $copy = New-Object byte[] $Value.Length
        [Array]::Copy($Value, $copy, $Value.Length)
        return ,$copy
    }
    if ($Value -is [Security.Principal.SecurityIdentifier])
    {
        $bytes = New-Object byte[] $Value.BinaryLength
        $Value.GetBinaryForm($bytes, 0)
        return ,$bytes
    }

    $sidText = [string]$Value
    if ($sidText -notmatch "^S-\d-\d+(-\d+)+$")
    {
        return $null
    }
    try
    {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
        $bytes = New-Object byte[] $sid.BinaryLength
        $sid.GetBinaryForm($bytes, 0)
        return ,$bytes
    }
    catch
    {
        return $null
    }
}

function Add-ScenarioSidTarget
{
    param([object] $Value)

    $bytes = ConvertTo-ScenarioSidBytes -Value $Value
    if ($null -eq $bytes)
    {
        return
    }
    $key = [Convert]::ToBase64String($bytes)
    foreach ($existing in @($script:ScenarioTargets.Sid))
    {
        if ([Convert]::ToBase64String([byte[]]$existing) -eq $key)
        {
            return
        }
    }
    $script:ScenarioTargets.Sid.Add($bytes)
}

function Add-ScenarioSyntheticSidTarget
{
    $rid = 1000 + [int]([math]::Abs([int64]$RandomSeed) % 100000)
    $sid = [Security.Principal.SecurityIdentifier]::new("S-1-5-21-3111111111-2222222222-3333333333-$rid")
    Add-ScenarioSidTarget -Value $sid
}

function Initialize-ScenarioTargetPools
{
    Write-RunEvent -Level "Information" -Message "Starting ScenarioTest target-pool initialization." -Data @{}
    $script:ScenarioTargets = @{}
    foreach ($bucket in @(
        "Recipient", "Group", "Mailbox", "Database", "Policy", "PolicyGuid",
        "AddressBook", "Server", "Mta", "Computer", "Configuration",
        "ConfigurationUnit", "OrganizationRoot", "Sid"))
    {
        if ($bucket -eq "Sid")
        {
            $script:ScenarioTargets[$bucket] = [Collections.Generic.List[object]]::new()
        }
        else
        {
            $script:ScenarioTargets[$bucket] = [Collections.Generic.List[string]]::new()
        }
    }
    $script:ScenarioTargets["WhatIfValues"] = @{}

    if ($WhatIfTraffic)
    {
        foreach ($bucket in @(
            "Recipient", "Group", "Mailbox", "Database", "Policy", "AddressBook",
            "Server", "Mta", "Computer", "Configuration", "ConfigurationUnit",
            "OrganizationRoot"))
        {
            Add-ScenarioTarget -Bucket $bucket -Object "CN=ScenarioTarget-$bucket,DC=whatif,DC=local"
        }
        Add-ScenarioGuidTarget -Bucket "PolicyGuid" -Value ([Guid]::NewGuid())
        $sidBytes = New-Object byte[] 28
        ([Security.Principal.SecurityIdentifier]::new("S-1-5-21-100-200-300-400")).GetBinaryForm($sidBytes, 0)
        $script:ScenarioTargets.Sid.Add($sidBytes)
        Write-RunEvent -Level "Information" -Message "Completed ScenarioTest target-pool initialization." -Data @{
            RecipientTargets = $script:ScenarioTargets.Recipient.Count
            GroupTargets = $script:ScenarioTargets.Group.Count
            MailboxTargets = $script:ScenarioTargets.Mailbox.Count
            DatabaseTargets = $script:ScenarioTargets.Database.Count
            PolicyTargets = $script:ScenarioTargets.Policy.Count
        }
        return
    }

    foreach ($recipient in @(Get-ScenarioCommandOutput -CommandName "Get-Recipient" -ResultLimit 10 | Select-Object -First 10))
    {
        try
        {
            $adObject = Get-ADObject -Identity ([Guid]$recipient.Guid) -Properties DistinguishedName,objectSid -ErrorAction Stop
            Add-ScenarioTarget -Bucket "Recipient" -Object $adObject -ResolveDistinguishedName
            if ([string]$recipient.RecipientTypeDetails -match "(?i)Mailbox")
            {
                Add-ScenarioTarget -Bucket "Mailbox" -Object $adObject -ResolveDistinguishedName
            }
            Add-ScenarioSidTarget -Value $adObject.objectSid
        }
        catch
        {
        }
    }
    foreach ($mailbox in @(Get-ScenarioCommandOutput -CommandName "Get-Mailbox" -ResultLimit 10 | Select-Object -First 10))
    {
        try
        {
            $adObject = Get-ADObject -Identity ([Guid]$mailbox.Guid) `
                -Properties DistinguishedName,objectSid,homeMTA,msExchCU,msExchOURoot `
                -ErrorAction Stop
            Add-ScenarioTarget -Bucket "Mailbox" -Object $adObject -ResolveDistinguishedName
            Add-ScenarioTarget -Bucket "Recipient" -Object $adObject -ResolveDistinguishedName
            Add-ScenarioSidTarget -Value $adObject.objectSid
            Add-ScenarioTarget -Bucket "Mta" -Object $adObject.homeMTA
            Add-ScenarioTarget -Bucket "ConfigurationUnit" -Object $adObject.msExchCU
            Add-ScenarioTarget -Bucket "OrganizationRoot" -Object $adObject.msExchOURoot
        }
        catch
        {
        }
    }
    foreach ($group in @(Get-ScenarioCommandOutput -CommandName "Get-DistributionGroup" -ResultLimit 10 | Select-Object -First 10))
    {
        try
        {
            $adObject = Get-ADObject -Identity ([Guid]$group.Guid) -Properties DistinguishedName,objectSid -ErrorAction Stop
            Add-ScenarioTarget -Bucket "Group" -Object $adObject -ResolveDistinguishedName
            Add-ScenarioTarget -Bucket "Recipient" -Object $adObject -ResolveDistinguishedName
            Add-ScenarioSidTarget -Value $adObject.objectSid
        }
        catch
        {
        }
    }
    foreach ($database in @(Get-ScenarioCommandOutput -CommandName "Get-MailboxDatabase" -ResultLimit 10 | Select-Object -First 10))
    {
        Add-ScenarioTarget -Bucket "Database" -Object $database -ResolveDistinguishedName
    }
    foreach ($commandName in @(
        "Get-AddressBookPolicy", "Get-AddressList", "Get-AuthPolicy",
        "Get-DataEncryptionPolicy", "Get-MobileDeviceMailboxPolicy",
        "Get-OWAMailboxPolicy", "Get-RoleAssignmentPolicy", "Get-SharingPolicy",
        "Get-ThrottlingPolicy", "Get-UMMailboxPolicy", "Get-UMDialPlan",
        "Get-MailboxPlan"))
    {
        foreach ($target in @(Get-ScenarioCommandOutput -CommandName $commandName -ResultLimit 10 | Select-Object -First 10))
        {
            if ($commandName -eq "Get-AddressList")
            {
                Add-ScenarioTarget -Bucket "AddressBook" -Object $target -ResolveDistinguishedName
            }
            else
            {
                Add-ScenarioTarget -Bucket "Policy" -Object $target -ResolveDistinguishedName
                Add-ScenarioGuidTarget -Bucket "PolicyGuid" -Value $target.Guid
            }
        }
    }
    foreach ($policy in @(Get-ScenarioCommandOutput -CommandName "Get-EmailAddressPolicy" -ResultLimit 10 | Select-Object -First 10))
    {
        Add-ScenarioTarget -Bucket "Policy" -Object $policy -ResolveDistinguishedName
        Add-ScenarioGuidTarget -Bucket "PolicyGuid" -Value $policy.Guid
    }
    foreach ($server in @(Get-ScenarioCommandOutput -CommandName "Get-ExchangeServer" -ResultLimit 10 | Select-Object -First 10))
    {
        Add-ScenarioTarget -Bucket "Server" -Object $server -ResolveDistinguishedName
    }
    try
    {
        $configurationNamingContext = [string](Get-ADRootDSE -ErrorAction Stop).configurationNamingContext
        foreach ($mta in @(Get-ADObject -SearchBase $configurationNamingContext -LDAPFilter "(objectClass=mTA)" -ResultSetSize 10 -ErrorAction Stop))
        {
            Add-ScenarioTarget -Bucket "Mta" -Object $mta -ResolveDistinguishedName
        }
    }
    catch
    {
    }
    foreach ($computer in @(Get-ScenarioCommandOutput -CommandName "Get-ADComputer" -ResultLimit 10 | Select-Object -First 10))
    {
        Add-ScenarioTarget -Bucket "Computer" -Object $computer -ResolveDistinguishedName
        Add-ScenarioSidTarget -Value $computer.objectSid
    }
    foreach ($user in @(Get-ScenarioCommandOutput -CommandName "Get-ADUser" -ResultLimit 10 | Select-Object -First 10))
    {
        Add-ScenarioSidTarget -Value $user.objectSid
    }
    foreach ($group in @(Get-ScenarioCommandOutput -CommandName "Get-ADGroup" -ResultLimit 10 | Select-Object -First 10))
    {
        Add-ScenarioSidTarget -Value $group.objectSid
    }
    if ($script:ScenarioTargets.Sid.Count -eq 0)
    {
        Add-ScenarioSyntheticSidTarget
        Write-RunEvent -Level "Warning" -Message "ScenarioTest SID target pool had no readable AD SID; using a schema-valid synthetic SID." -Data @{
            Source = "DeterministicSynthetic"
            RandomSeed = $RandomSeed
        }
    }
    try
    {
        $rootDse = Get-ADRootDSE -ErrorAction Stop
        Add-ScenarioTarget -Bucket "Configuration" -Object ([string]$rootDse.configurationNamingContext)
    }
    catch
    {
    }
    Write-RunEvent -Level "Information" -Message "Completed ScenarioTest target-pool initialization." -Data @{
        RecipientTargets = $script:ScenarioTargets.Recipient.Count
        GroupTargets = $script:ScenarioTargets.Group.Count
        MailboxTargets = $script:ScenarioTargets.Mailbox.Count
        DatabaseTargets = $script:ScenarioTargets.Database.Count
        PolicyTargets = $script:ScenarioTargets.Policy.Count
    }
}

function Save-ScenarioTargetContext
{
    $path = Join-Path $script:RunDirectory "scenario-target-context.clixml"
    $temporaryPath = "$path.tmp"
    [ordered]@{
        PlanVersion = $script:ScenarioPlanVersion
        Organization = $Organization
        ForestFqdn = $script:ForestFqdn
        Targets = $script:ScenarioTargets
    } | Export-Clixml -LiteralPath $temporaryPath -Depth 10
    Move-Item -LiteralPath $temporaryPath -Destination $path -Force
}

function Restore-ScenarioTargetContext
{
    $path = Join-Path $script:RunDirectory "scenario-target-context.clixml"
    if (-not (Test-Path -LiteralPath $path))
    {
        return $false
    }

    $context = Import-Clixml -LiteralPath $path
    if ([int]$context.PlanVersion -ne $script:ScenarioPlanVersion -or
        -not [string]::Equals([string]$context.Organization, $Organization, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$context.ForestFqdn, $script:ForestFqdn, [StringComparison]::OrdinalIgnoreCase) -or
        $context.Targets -isnot [System.Collections.IDictionary])
    {
        return $false
    }

    $script:ScenarioTargets = $context.Targets
    Write-RunEvent -Level "Information" -Message "Restored cached ScenarioTest runtime target context." -Data @{
        ContextPath = $path
        PlanVersion = $script:ScenarioPlanVersion
    }
    return $true
}

function Get-ScenarioTargetBucket
{
    param([Parameter(Mandatory)] [string] $Name)

    if ($Name -eq "msExchMultiMailboxDatabasesLink" -or $Name -match "(?i)(MailboxMove|ArchiveDatabase|SourceMDB|TargetMDB)")
    {
        return "Database"
    }
    if ($Name -ieq "msExchCU")
    {
        return "ConfigurationUnit"
    }
    if ($Name -ieq "msExchOURoot")
    {
        return "OrganizationRoot"
    }
    if ($Name -ieq "homeMTA")
    {
        return "Mta"
    }
    if ($Name -match "(?i)(AddressBook|showInAddressBook)")
    {
        return "AddressBook"
    }
    if ($Name -match "(?i)HomeServerName")
    {
        return "Server"
    }
    if ($Name -match "(?i)(RMSComputer|NonCompliantDevice)")
    {
        return "Computer"
    }
    if ($Name -match "(?i)(Policy|Plan|DialPlan|RoleGroup|Sharing|OWA)")
    {
        return "Policy"
    }
    if ($Name -match "(?i)(Mailbox|Arbitration|PublicFolder)")
    {
        return "Mailbox"
    }
    if ($Name -match "(?i)(Group|Member|Owner|ManagedBy|manager|ModeratedBy|Delegate|Orig|Supervisor)")
    {
        return "Recipient"
    }
    return "Recipient"
}

function Test-ScenarioDnTarget
{
    param(
        [Parameter(Mandatory)] [string] $Bucket,
        [Parameter(Mandatory)] [string] $DistinguishedName)

    if ([string]::IsNullOrWhiteSpace($DistinguishedName) -or
        $DistinguishedName -notmatch "(?i)(^|,)DC=" -or
        $DistinguishedName -match "/")
    {
        throw "Scenario $Bucket target '$DistinguishedName' is not an LDAP distinguished name."
    }
    if ($WhatIfTraffic)
    {
        return
    }
    $adObject = Get-ADObject -Identity $DistinguishedName -Properties objectClass,DistinguishedName -ErrorAction Stop
    $resolved = [string]$adObject.DistinguishedName
    if (-not [string]::Equals($resolved, $DistinguishedName, [StringComparison]::OrdinalIgnoreCase))
    {
        throw "Scenario $Bucket target '$DistinguishedName' resolved to '$resolved' instead of the requested LDAP distinguished name."
    }
    $classes = @($adObject.objectClass | ForEach-Object { [string]$_ })
    if ($Bucket -eq "Group" -and -not ($classes -contains "group"))
    {
        throw "Scenario Group target '$DistinguishedName' is not an AD group."
    }
    if ($Bucket -eq "Computer" -and -not ($classes -contains "computer"))
    {
        throw "Scenario Computer target '$DistinguishedName' is not an AD computer."
    }
}

function Get-ScenarioGeneratorKind
{
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Metadata)

    $name = [string]$Metadata.Name
    if ($name -eq "msExchMultiMailboxDatabasesLink")
    {
        return "MailboxDatabaseLink"
    }
    if ($name -ieq "msExchSharingAnonymousIdentities")
    {
        return "String"
    }
    if ($name -match "(?i)SID")
    {
        return "Sid"
    }
    if ($name -match "(?i)SecurityDescriptor")
    {
        return "SecurityDescriptor"
    }
    if ($name -match "(?i)Certificate")
    {
        return "Certificate"
    }
    if ($name -match "(?i)(GUID|ImmutableId)")
    {
        return "Guid"
    }
    if ($Metadata.Contains("LinkId") -and
        $null -ne $Metadata.LinkId -and
        -not [string]::IsNullOrWhiteSpace([string]$Metadata.LinkId))
    {
        if ([string]$Metadata.AttributeSyntax -eq "2.5.5.14")
        {
            return "DNString"
        }
        return "DN"
    }

    switch ([string]$Metadata.AttributeSyntax)
    {
        "2.5.5.1" { return "DN" }
        "2.5.5.2" { return "Oid" }
        "2.5.5.13" { return "DN" }
        "2.5.5.14" { return "DN" }
        "2.5.5.19" { return "DN" }
        "2.5.5.20" { return "DN" }
        "2.5.5.21" { return "DN" }
        "2.5.5.8" { return "Boolean" }
        "2.5.5.9" { return "Integer" }
        "2.5.5.16" { return "LargeInteger" }
        "2.5.5.17" { return "Sid" }
        "2.5.5.10" { return "Octet" }
        "2.5.5.11" { return "DateTime" }
        "2.5.5.24" { return "DateTime" }
        "2.5.5.3" { return "String" }
        "2.5.5.4" { return "String" }
        "2.5.5.5" { return "String" }
        "2.5.5.6" { return "String" }
        "2.5.5.7" { return "String" }
        "2.5.5.12" { return "String" }
        "2.5.5.15" { return "String" }
        default { return "Unsupported" }
    }
}

function New-ScenarioSecurityDescriptorBytes
{
    $descriptor = New-Object System.Security.AccessControl.RawSecurityDescriptor "O:SYG:SYD:(A;;RPWP;;;WD)"
    $bytes = New-Object byte[] $descriptor.BinaryLength
    $descriptor.GetBinaryForm($bytes, 0)
    return ,$bytes
}

function Initialize-ScenarioCertificate
{
    if ($WhatIfTraffic)
    {
        $script:ScenarioTargets.CertificateBytes = [byte[]](0..31)
        $script:ScenarioTargets.CertificateSubject = "CN=$ObjectPrefix-Scenario"
        $script:ScenarioTargets.CertificateIssuer = "CN=$ObjectPrefix-Scenario"
        return
    }
    if ($script:ScenarioTargets.ContainsKey("CertificateBytes") -and $null -ne $script:ScenarioTargets.CertificateBytes)
    {
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($ResumeRunDirectory))
    {
        $certificateRecord = @(
            $script:ScenarioSupportingObjects |
                Where-Object { [string]$_.Kind -eq "Certificate" } |
                Select-Object -Last 1
        )
        if ($certificateRecord.Count -eq 1)
        {
            $certificatePath = Join-Path ([string]$certificateRecord[0].StorePath) ([string]$certificateRecord[0].Thumbprint)
            if (Test-Path -LiteralPath $certificatePath)
            {
                $certificate = Get-Item -LiteralPath $certificatePath -ErrorAction Stop
                $script:ScenarioTargets.CertificateBytes = $certificate.Export(
                    [Security.Cryptography.X509Certificates.X509ContentType]::Cert)
                $script:ScenarioTargets.CertificateSubject = [string]$certificate.Subject
                $script:ScenarioTargets.CertificateIssuer = [string]$certificate.Issuer
                return
            }
        }
        $zeroStateResume =
            $certificateRecord.Count -eq 0 -and
            $script:ScenarioSupportingObjects.Count -eq 0 -and
            $script:Contacts.Count -eq 0 -and
            $script:Groups.Count -eq 0 -and
            [long]$script:Counters.OperationsAttempted -eq 0 -and
            $script:ScenarioCompletedObjectWork -eq 0
        if (-not $zeroStateResume)
        {
            throw "The resumed scenario could not restore its ledger-owned certificate."
        }
    }
    $certificateCommand = Get-Command "New-SelfSignedCertificate" -ErrorAction SilentlyContinue
    if ($null -eq $certificateCommand)
    {
        throw "The scenario arrays require certificate-valued attributes, but New-SelfSignedCertificate is unavailable."
    }
    $subject = "CN=$ObjectPrefix-Scenario"
    $certificate = New-SelfSignedCertificate -Subject $subject -CertStoreLocation "Cert:\CurrentUser\My" -KeyExportPolicy Exportable -ErrorAction Stop
    $script:ScenarioTargets.CertificateBytes = $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $script:ScenarioTargets.CertificateSubject = [string]$certificate.Subject
    $script:ScenarioTargets.CertificateIssuer = [string]$certificate.Issuer
    $script:ScenarioSupportingObjects.Add([ordered]@{
        Kind = "Certificate"
        Thumbprint = [string]$certificate.Thumbprint
        StorePath = "Cert:\CurrentUser\My"
    })
}

function Get-ScenarioValueLimit
{
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Metadata)

    if ([int64]$Metadata.RangeUpper -gt 0)
    {
        return [int][math]::Min([int64]$Metadata.RangeUpper, 512)
    }
    return 256
}

function New-ScenarioBoundedStringValue
{
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [Random] $Random,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Metadata,
        [Parameter(Mandatory)] [int] $PreferredLength)

    $limit = Get-ScenarioValueLimit -Metadata $Metadata
    $minimum = [math]::Max(1, [int]$Metadata.RangeLower)
    if ($limit -lt $minimum)
    {
        throw "Attribute '$Name' has incompatible string bounds: rangeLower=$minimum, rangeUpper=$limit."
    }
    $length = [math]::Max($minimum, [math]::Min($limit, $PreferredLength))
    return (New-ScenarioToken -Random $Random -Length $length).ToUpperInvariant()
}

function New-ScenarioStringValue
{
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [object] $Entity,
        [Parameter(Mandatory)] [Random] $Random,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Metadata)

    $token = "$ObjectPrefix-$(New-ScenarioToken -Random $Random -Length 14)"
    $value = switch -Regex ($Name)
    {
        "(?i)^Initials$" { New-ScenarioBoundedStringValue -Name $Name -Random $Random -Metadata $Metadata -PreferredLength 3; break }
        "(?i)^msExchMailboxPlanType$" { New-ScenarioBoundedStringValue -Name $Name -Random $Random -Metadata $Metadata -PreferredLength 5; break }
        "(?i)^c$" { "US"; break }
        "(?i)^co$" { "United States"; break }
        "(?i)(?<![A-Za-z])mail$" { "$token@example.invalid"; break }
        "(?i)^targetAddress$" { "SMTP:$token@example.invalid"; break }
        "(?i)^proxyAddresses$" { "smtp:$token@example.invalid"; break }
        "(?i)^legacyExchangeDN$" { "/o=Scenario/ou=Exchange Administrative Group/cn=Recipients/cn=$token"; break }
        "(?i)^msExchLabeledURI$" { "https://example.invalid/$token"; break }
        "(?i)^textEncodedORAddress$" { "/o=Scenario/ou=Exchange Administrative Group/cn=Recipients/cn=$token"; break }
        "(?i)^msExchConfigurationXML$" { "<UserConfig><ProvisioningOption>$token</ProvisioningOption></UserConfig>"; break }
        "(?i)^msExchSharingAnonymousIdentities$" {
            $urlId = [Guid]::new([byte[]](New-ScenarioGuidBytes -Random $Random))
            $folderId = New-ScenarioToken -Random $Random -Length 64
            "calendar\$urlId`:$folderId"
            break
        }
        "(?i)^msExchPolicies(Included|Excluded)$" {
            if (-not $script:ScenarioTargets.ContainsKey("PolicyGuid") -or
                $script:ScenarioTargets.PolicyGuid.Count -eq 0)
            {
                throw "Attribute '$Name' requires a valid policy object GUID, but no policy target is available."
            }
            Get-RandomScenarioItem -Items $script:ScenarioTargets.PolicyGuid -Random $Random
            break
        }
        "(?i)^AltSecurityIdentities$" {
            if ($script:ScenarioTargets.ContainsKey("CertificateSubject"))
            {
                "X509:<I>$($script:ScenarioTargets.CertificateIssuer)<S>$($script:ScenarioTargets.CertificateSubject)"
            }
            else
            {
                "Kerberos:$token"
            }
            break
        }
        "(?i)^msExchImmutableId$" { [Convert]::ToBase64String((New-ScenarioGuidBytes -Random $Random)); break }
        "(?i)^msExchUMDtmfMap$" { "email:$token"; break }
        default { "$($Entity.Name)-$token"; break }
    }
    $limit = Get-ScenarioValueLimit -Metadata $Metadata
    if ($value.Length -gt $limit)
    {
        if ($limit -lt 8)
        {
            throw "Attribute '$Name' has a string rangeUpper of $limit, which is too small for a safe generated value."
        }
        $value = $value.Substring(0, $limit)
    }
    return $value
}

function New-ScenarioBoundedIntegerValue
{
    param(
        [Parameter(Mandatory)] [Random] $Random,
        [Parameter(Mandatory)] [int64] $Minimum,
        [Parameter(Mandatory)] [int64] $Maximum)

    if ($Maximum -lt $Minimum)
    {
        throw "Integer range is invalid: minimum $Minimum exceeds maximum $Maximum."
    }

    $sampleMinimum = [int64][math]::Max($Minimum, -1000000L)
    $sampleMaximum = [int64][math]::Min($Maximum, 1000000L)
    if ($sampleMinimum -gt $sampleMaximum)
    {
        return $Minimum
    }

    $sampleWidth = $sampleMaximum - $sampleMinimum + 1
    return $sampleMinimum + [int64]$Random.Next(0, [int]$sampleWidth)
}

function New-ScenarioToken
{
    param(
        [Parameter(Mandatory)] [Random] $Random,
        [int] $Length = 12)

    $alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
    $builder = [Text.StringBuilder]::new($Length)
    for ($index = 0; $index -lt $Length; $index++)
    {
        [void]$builder.Append($alphabet[$Random.Next(0, $alphabet.Length)])
    }
    return $builder.ToString()
}

function New-ScenarioTypedValue
{
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Metadata,
        [Parameter(Mandatory)] [object] $Entity,
        [Parameter(Mandatory)] [Random] $Random,
        [object] $ObjectSid)

    $name = [string]$Metadata.Name
    $kind = Get-ScenarioGeneratorKind -Metadata $Metadata
    switch ($kind)
    {
        "MailboxDatabaseLink" {
            if ($script:ScenarioTargets.Database.Count -eq 0)
            {
                throw "Attribute '$name' requires a mailbox database DN, but no mailbox database target is available."
            }
            $databaseDn = Get-RandomScenarioItem -Items $script:ScenarioTargets.Database -Random $Random
            return "S:7:Primary:$databaseDn"
        }
        "DN" {
            $bucket = Get-ScenarioTargetBucket -Name $name
            if ($script:ScenarioTargets[$bucket].Count -eq 0)
            {
                throw "Attribute '$name' requires a valid $bucket DN, but no target is available."
            }
            return Get-RandomScenarioItem -Items $script:ScenarioTargets[$bucket] -Random $Random
        }
        "DNString" {
            $bucket = Get-ScenarioTargetBucket -Name $name
            if ($script:ScenarioTargets[$bucket].Count -eq 0)
            {
                throw "Attribute '$name' requires a valid $bucket DN, but no target is available."
            }
            $targetDn = Get-RandomScenarioItem -Items $script:ScenarioTargets[$bucket] -Random $Random
            $stringValue = if ($name -eq "msExchNonCompliantDeviceLink")
            {
                $deviceId = [Guid]::new([byte[]](New-ScenarioGuidBytes -Random $Random))
                "{`"DeviceId`":`"$deviceId`",`"DeviceNonCompliantAfter`":`"2000-01-01T00:00:00Z`",`"EnforcedEventType`":`"None`"}"
            }
            elseif ($name -eq "msExchMultiMailboxLocationsLink")
            {
                $mailboxGuid = [Guid]::new([byte[]](New-ScenarioGuidBytes -Random $Random))
                "1;$mailboxGuid;AuxPrimary"
            }
            elseif ($name -eq "msExchSupervisionOneOffLink")
            {
                $token = New-ScenarioToken -Random $Random -Length 12
                "$token,$token@example.invalid"
            }
            else
            {
                New-ScenarioBoundedStringValue -Name $name -Random $Random -Metadata $Metadata -PreferredLength 16
            }
            return "S:$($stringValue.Length):${stringValue}:$targetDn"
        }
        "Sid" {
            $sidBytes = if ($null -ne $ObjectSid -and $ObjectSid -is [byte[]])
            {
                ,([byte[]]$ObjectSid)
            }
            elseif ($script:ScenarioTargets.Sid.Count -gt 0)
            {
                ,([byte[]](Get-RandomScenarioItem -Items $script:ScenarioTargets.Sid -Random $Random))
            }
            else
            {
                throw "Attribute '$name' requires a valid SID value, but no SID target is available."
            }
            if ($name -ieq "msExchSIDHistory")
            {
                return [Security.Principal.SecurityIdentifier]::new($sidBytes, 0)
            }
            if ($null -ne $ObjectSid -and $ObjectSid -is [byte[]])
            {
                return ,([byte[]]$ObjectSid)
            }
            return ,$sidBytes
        }
        "SecurityDescriptor" {
            return ,(New-ScenarioSecurityDescriptorBytes)
        }
        "Certificate" {
            if (-not $script:ScenarioTargets.ContainsKey("CertificateBytes") -or
                $null -eq $script:ScenarioTargets.CertificateBytes)
            {
                throw "Attribute '$name' requires a valid certificate blob, but no certificate is available."
            }
            return ,([byte[]]$script:ScenarioTargets.CertificateBytes)
        }
        "Guid" {
            if ($name -match "(?i)ImmutableId")
            {
                return [Convert]::ToBase64String((New-ScenarioGuidBytes -Random $Random))
            }
            return ,(New-ScenarioGuidBytes -Random $Random)
        }
        "Boolean" {
            return [bool]($Random.Next(0, 2) -eq 1)
        }
        "Integer" {
            if ($name -match "(?i)^groupType$")
            {
                return [int32]8
            }
            if ($name -match "(?i)CountryCode")
            {
                return [int32]840
            }
            if ($name -ieq "msExchLocalizationFlags")
            {
                return [int32]$Random.Next(0, 2)
            }
            if ([int64]$Metadata.RangeLower -ne 0 -or [int64]$Metadata.RangeUpper -ne 0)
            {
                $value = New-ScenarioBoundedIntegerValue `
                    -Random $Random `
                    -Minimum ([int64]$Metadata.RangeLower) `
                    -Maximum ([int64]$Metadata.RangeUpper)
                if ($value -lt [int32]::MinValue -or $value -gt [int32]::MaxValue)
                {
                    throw "Attribute '$name' has an integer range outside Int32 limits."
                }
                return [int32]$value
            }
            return [int32]($Random.Next(0, 1000))
        }
        "LargeInteger" {
            if ([int64]$Metadata.RangeLower -ne 0 -or [int64]$Metadata.RangeUpper -ne 0)
            {
                return [int64](New-ScenarioBoundedIntegerValue `
                    -Random $Random `
                    -Minimum ([int64]$Metadata.RangeLower) `
                    -Maximum ([int64]$Metadata.RangeUpper))
            }
            return [int64]$Random.Next(1, 1000000)
        }
        "DateTime" {
            return [datetime]::new(2020, 1, 1, 0, 0, 0, [DateTimeKind]::Utc).AddMinutes($Random.Next(0, 60))
        }
        "Octet" {
            if ($name -match "(?i)(GUID|ImmutableId)")
            {
                return New-ScenarioGuidBytes -Random $Random
            }
            $bytes = New-Object byte[] 16
            $Random.NextBytes($bytes)
            return ,$bytes
        }
        "Oid" {
            return "1.2.840.113556.1.4.7000.142"
        }
        "Unsupported" {
            throw "schema syntax '$($Metadata.AttributeSyntax)' has no safe typed value generator."
        }
        default {
            return New-ScenarioStringValue -Name $name -Entity $Entity -Random $Random -Metadata $Metadata
        }
    }
}

function New-ScenarioGuidBytes
{
    param([Parameter(Mandatory)] [Random] $Random)

    $bytes = New-Object byte[] 16
    $Random.NextBytes($bytes)
    $bytes[6] = [byte](($bytes[6] -band 0x0f) -bor 0x40)
    $bytes[8] = [byte](($bytes[8] -band 0x3f) -bor 0x80)
    return ,$bytes
}

function Test-ScenarioSingleValuedForEntity
{
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Metadata,
        [Parameter(Mandatory)] [object] $Entity)

    $kindProperty = $Entity.PSObject.Properties["Kind"]
    if ($null -ne $kindProperty -and
        [string]$kindProperty.Value -eq "Group" -and
        [string]$Metadata.Name -ieq "description")
    {
        return $true
    }
    return ConvertTo-ScenarioBoolean $Metadata.IsSingleValued
}

function New-ScenarioTypedValues
{
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Metadata,
        [Parameter(Mandatory)] [object] $Entity,
        [Parameter(Mandatory)] [Random] $Random,
        [object] $ObjectSid)

    $isSingleValued = Test-ScenarioSingleValuedForEntity -Metadata $Metadata -Entity $Entity
    $count = if ($isSingleValued)
    {
        1
    }
    else
    {
        $Random.Next(1, 6)
    }
    $values = [Collections.Generic.List[object]]::new()
    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    for ($index = 0; $index -lt $count; $index++)
    {
        $value = New-ScenarioTypedValue -Metadata $Metadata -Entity $Entity -Random $Random -ObjectSid $ObjectSid
        $key = if ($value -is [byte[]]) { [Convert]::ToBase64String($value) } else { [string]$value }
        if ($keys.Add($key))
        {
            $values.Add($value)
        }
    }
    if ($isSingleValued)
    {
        return ,$values[0]
    }
    return $values.ToArray()
}

function Get-RandomScenarioItem
{
    param(
        [Parameter(Mandatory)] [object[]] $Items,
        [Parameter(Mandatory)] [Random] $Random)

    if ($Items.Count -eq 0)
    {
        return $null
    }
    return $Items[$Random.Next(0, $Items.Count)]
}

function New-ScenarioRandom
{
    param(
        [Parameter(Mandatory)] [int] $PhaseIndex,
        [Parameter(Mandatory)] [int] $BatchIndex,
        [int] $Salt = 0)

    $modulus = [int64]2147483647
    $seed = ([int64]$RandomSeed +
        ([int64]($PhaseIndex + 1) * 1000003) +
        ([int64]($BatchIndex + 1) * 9176) +
        ([int64]$Salt * 7919)) % $modulus
    if ($seed -lt 0)
    {
        $seed += $modulus
    }
    if ($seed -eq 0)
    {
        $seed = 1
    }
    return [Random]::new([int]$seed)
}

function Get-ShuffledScenarioArray
{
    param(
        [Parameter(Mandatory)] [object[]] $Items,
        [Parameter(Mandatory)] [Random] $Random)

    $result = [Collections.Generic.List[object]]::new()
    foreach ($item in @($Items))
    {
        $result.Add($item)
    }
    for ($index = $result.Count - 1; $index -gt 0; $index--)
    {
        $swapIndex = $Random.Next(0, $index + 1)
        $temporary = $result[$index]
        $result[$index] = $result[$swapIndex]
        $result[$swapIndex] = $temporary
    }
    return $result.ToArray()
}

function Select-ScenarioProperties
{
    param(
        [object[]] $Properties = @(),
        [Parameter(Mandatory)] [int] $Width,
        [Parameter(Mandatory)] [Random] $Random)

    $propertyArray = @($Properties)
    if ($propertyArray.Count -eq 0)
    {
        return @()
    }
    $shuffled = Get-ShuffledScenarioArray -Items $propertyArray -Random $Random
    $selected = [Collections.Generic.List[string]]::new()
    $limit = [math]::Min($Width, $shuffled.Count)
    for ($index = 0; $index -lt $limit; $index++)
    {
        $selected.Add([string]$shuffled[$index])
    }
    return $selected.ToArray()
}

function Get-ScenarioInitialSelection
{
    param(
        [object[]] $PropertyOrder = @(),
        [Parameter(Mandatory)] [int] $Position)

    $propertyArray = @($PropertyOrder)
    if ($propertyArray.Count -eq 0)
    {
        return @()
    }
    return @([string]$propertyArray[($Position - 1) % $propertyArray.Count])
}

function Merge-ScenarioMixedSelections
{
    param(
        [Parameter(Mandatory)] [string[]] $RecipientSelection,
        [Parameter(Mandatory)] [string[]] $LinkSelection,
        [Parameter(Mandatory)] [object[]] $FullRecipientOrder,
        [Parameter(Mandatory)] [object[]] $FullLinkOrder,
        [Parameter(Mandatory)] [bool] $RequireDistinct)

    $linkTarget = @($LinkSelection).Count
    $recipient = [Collections.Generic.List[string]]::new()
    $link = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($RecipientSelection))
    {
        if ($seen.Add([string]$name))
        {
            $recipient.Add([string]$name)
        }
    }
    foreach ($name in @($LinkSelection))
    {
        if ($seen.Add([string]$name))
        {
            $link.Add([string]$name)
        }
    }

    if ($RequireDistinct -and $recipient.Count -eq 0)
    {
        throw "Mixed scenario batch could not select a recipient attribute."
    }
    if ($RequireDistinct -and $link.Count -lt $linkTarget)
    {
        foreach ($candidateValue in @($FullLinkOrder))
        {
            if ($link.Count -ge $linkTarget)
            {
                break
            }

            $candidate = [string]$candidateValue
            if ([string]::IsNullOrWhiteSpace($candidate))
            {
                continue
            }

            if ($seen.Contains($candidate))
            {
                $recipientIndex = -1
                for ($index = 0; $index -lt $recipient.Count; $index++)
                {
                    if ([string]::Equals($recipient[$index], $candidate, [StringComparison]::OrdinalIgnoreCase))
                    {
                        $recipientIndex = $index
                        break
                    }
                }

                if ($recipientIndex -lt 0)
                {
                    continue
                }

                $replacement = $null
                foreach ($replacementValue in @($FullRecipientOrder))
                {
                    $replacementCandidate = [string]$replacementValue
                    if (-not [string]::IsNullOrWhiteSpace($replacementCandidate) -and
                        -not $seen.Contains($replacementCandidate) -and
                        -not [string]::Equals($replacementCandidate, $candidate, [StringComparison]::OrdinalIgnoreCase))
                    {
                        $replacement = $replacementCandidate
                        break
                    }
                }

                if ($null -eq $replacement)
                {
                    if ($recipient.Count -le 1)
                    {
                        continue
                    }

                    [void]$seen.Remove($candidate)
                    [void]$recipient.RemoveAt($recipientIndex)
                }
                else
                {
                    [void]$seen.Remove($candidate)
                    $recipient[$recipientIndex] = $replacement
                    [void]$seen.Add($replacement)
                }
            }

            if ($seen.Add($candidate))
            {
                $link.Add($candidate)
            }
        }
    }
    if ($RequireDistinct -and $link.Count -eq 0)
    {
        throw "Mixed scenario batch could not select a distinct link attribute."
    }
    return [ordered]@{
        Recipient = $recipient.ToArray()
        Link = $link.ToArray()
    }
}

function Get-ScenarioPhaseDefinitions
{
    $allPhases = @(
        [ordered]@{
            Name = "Pure User Recipient Upsert"
            EntityKind = "User"
            Operation = "Upsert"
            RecipientProperties = @($script:UserRecipientPropertiesForUpsert)
            LinkProperties = @()
        }
        [ordered]@{
            Name = "Pure User Link Upsert"
            EntityKind = "User"
            Operation = "Upsert"
            RecipientProperties = @()
            LinkProperties = @($script:UserLinkPropertiesForUpsert)
        }
        [ordered]@{
            Name = "Pure Group Recipient Upsert"
            EntityKind = "Group"
            Operation = "Upsert"
            RecipientProperties = @($script:GroupRecipientPropertiesForUpsert)
            LinkProperties = @()
        }
        [ordered]@{
            Name = "Pure Group Link Upsert"
            EntityKind = "Group"
            Operation = "Upsert"
            RecipientProperties = @()
            LinkProperties = @($script:GroupLinkPropertiesForUpsert)
        }
        [ordered]@{
            Name = "Mixed User Upsert"
            EntityKind = "User"
            Operation = "Upsert"
            RecipientProperties = @($script:UserRecipientPropertiesForUpsert)
            LinkProperties = @($script:UserLinkPropertiesForUpsert)
        }
        [ordered]@{
            Name = "Mixed Group Upsert"
            EntityKind = "Group"
            Operation = "Upsert"
            RecipientProperties = @($script:GroupRecipientPropertiesForUpsert)
            LinkProperties = @($script:GroupLinkPropertiesForUpsert)
        }
        [ordered]@{
            Name = "Pure User Recipient Deletion"
            EntityKind = "User"
            Operation = "Delete"
            RecipientProperties = @($script:UserRecipientPropertiesForDeletion)
            LinkProperties = @()
        }
        [ordered]@{
            Name = "Pure User Link Deletion"
            EntityKind = "User"
            Operation = "Delete"
            RecipientProperties = @()
            LinkProperties = @($script:UserLinkPropertiesForDeletion)
        }
        [ordered]@{
            Name = "Pure Group Recipient Deletion"
            EntityKind = "Group"
            Operation = "Delete"
            RecipientProperties = @($script:GroupRecipientPropertiesForDeletion)
            LinkProperties = @()
        }
        [ordered]@{
            Name = "Pure Group Link Deletion"
            EntityKind = "Group"
            Operation = "Delete"
            RecipientProperties = @()
            LinkProperties = @($script:GroupLinkPropertiesForDeletion)
        }
        [ordered]@{
            Name = "Mixed User Deletion"
            EntityKind = "User"
            Operation = "Delete"
            RecipientProperties = @($script:UserRecipientPropertiesForDeletion)
            LinkProperties = @($script:UserLinkPropertiesForDeletion)
        }
        [ordered]@{
            Name = "Mixed Group Deletion"
            EntityKind = "Group"
            Operation = "Delete"
            RecipientProperties = @($script:GroupRecipientPropertiesForDeletion)
            LinkProperties = @($script:GroupLinkPropertiesForDeletion)
        }
    )
    $selectedNames = @((Get-ScenarioCommandDefinition).PhaseNames)
    return @($allPhases | Where-Object { $selectedNames -contains [string]$_.Name })
}

function Get-ScenarioQualificationFingerprint
{
    param(
        [switch] $LegacyWithoutScenarioSetMode,
        [switch] $LegacyWithoutPopulationSource,
        [string] $LegacyScenarioCommandName)

    if ($script:LegacyCommandSpecificPopulation)
    {
        $LegacyWithoutPopulationSource = $true
    }

    $phases = @(Get-ScenarioPhaseDefinitions)
    $phaseShape = @(
        foreach ($phase in $phases)
        {
            [ordered]@{
                Name = [string]$phase.Name
                EntityKind = [string]$phase.EntityKind
                Operation = [string]$phase.Operation
                RecipientProperties = @($phase.RecipientProperties)
                LinkProperties = @($phase.LinkProperties)
            }
        }
    )
    $fingerprintInput = [ordered]@{
        PlanVersion = $script:ScenarioPlanVersion
        BatchesPerPhase = $script:ScenarioBatchesPerPhase
        ScenarioCommand =
            if (-not [string]::IsNullOrWhiteSpace($LegacyScenarioCommandName))
            {
                $LegacyScenarioCommandName.ToUpperInvariant()
            }
            else
            {
                $ScenarioCommand.ToUpperInvariant()
            }
    }
    if (-not $LegacyWithoutScenarioSetMode)
    {
        $fingerprintInput.Add("ScenarioSetMode", $ScenarioSetMode.ToUpperInvariant())
    }
    $fingerprintInput.Add("RandomSeed", $RandomSeed)
    $fingerprintInput.Add("MachineName", ([string]$env:COMPUTERNAME).ToUpperInvariant())
    $fingerprintInput.Add("ForestFqdn", ([string]$script:ForestFqdn).ToUpperInvariant())
    $fingerprintInput.Add("TenantId", $script:TenantId.ToString("D"))
    $fingerprintInput.Add("Organization", ([string]$Organization).ToUpperInvariant())
    $fingerprintInput.Add("Side", ([string]$Side).ToUpperInvariant())
    $fingerprintInput.Add("ObjectStoreDestination", ([string]$ObjectStoreDestination).ToUpperInvariant())
    $fingerprintInput.Add("ObjectPrefix", $ObjectPrefix)
    $fingerprintInput.Add("WhatIfTraffic", [bool]$WhatIfTraffic)
    $fingerprintInput.Add("CompareSetupScript", ([string]$CompareSetupScript).ToUpperInvariant())
    $fingerprintInput.Add("ScenarioRuntimeDependencyRoot", ([string]$ScenarioRuntimeDependencyRoot).ToUpperInvariant())
    if (-not $LegacyWithoutPopulationSource)
    {
        $fingerprintInput.Add("SharedPopulationVersion", $script:ScenarioSharedPopulationVersion)
        $fingerprintInput.Add("PopulationSourceRunDirectory", ([string]$PopulationSourceRunDirectory).ToUpperInvariant())
    }
    $fingerprintInput.Add("UserObjects", $script:ScenarioCounts.N_User)
    $fingerprintInput.Add("GroupObjects", $script:ScenarioCounts.N_Groups)
    $fingerprintInput.Add("Phases", $phaseShape)
    $bytes = [Text.Encoding]::UTF8.GetBytes(
        ($fingerprintInput | ConvertTo-Json -Depth 8 -Compress))
    $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
    try
    {
        return [BitConverter]::ToString(
            $hashAlgorithm.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
    }
    finally
    {
        $hashAlgorithm.Dispose()
    }
}

function Test-ScenarioSemanticTargets
{
    if ($WhatIfTraffic)
    {
        Write-RunEvent -Level "Information" -Message "Skipped live ScenarioTest semantic target binding in WhatIf mode." -Data @{
            BindingPerformed = $false
        }
        return
    }

    $requirements = @(
        [ordered]@{ Bucket = "ConfigurationUnit"; ObjectClass = "msExchConfigurationUnitContainer" }
        [ordered]@{ Bucket = "OrganizationRoot"; ObjectClass = "organizationalUnit" }
        [ordered]@{ Bucket = "Mta"; ObjectClass = "mTA" }
    )
    $failures = [Collections.Generic.List[object]]::new()
    foreach ($requirement in $requirements)
    {
        foreach ($targetDn in @($script:ScenarioTargets[$requirement.Bucket]))
        {
            try
            {
                $target = Get-ADObject -Identity $targetDn -Properties objectClass -ErrorAction Stop
                $classes = @($target.objectClass | ForEach-Object { [string]$_ })
                if (-not ($classes -contains [string]$requirement.ObjectClass))
                {
                    $failures.Add([ordered]@{
                        Bucket = $requirement.Bucket
                        Target = $targetDn
                        ExpectedObjectClass = $requirement.ObjectClass
                        ActualObjectClasses = $classes
                    })
                }
            }
            catch
            {
                $failures.Add([ordered]@{
                    Bucket = $requirement.Bucket
                    Target = $targetDn
                    ExpectedObjectClass = $requirement.ObjectClass
                    Error = Get-ScenarioExceptionChain -Exception $_.Exception
                })
            }
        }
    }

    foreach ($policyGuid in @($script:ScenarioTargets.PolicyGuid))
    {
        try
        {
            [void](Get-ADObject -Identity ([Guid]$policyGuid) -ErrorAction Stop)
        }
        catch
        {
            $failures.Add([ordered]@{
                Bucket = "PolicyGuid"
                Target = $policyGuid
                Error = Get-ScenarioExceptionChain -Exception $_.Exception
            })
        }
    }

    if ($failures.Count -gt 0)
    {
        throw "Scenario semantic target qualification failed: $($failures | ConvertTo-Json -Depth 5 -Compress)"
    }

    Write-RunEvent -Level "Success" -Message "ScenarioTest semantic target qualification passed." -Data @{
        ConfigurationUnitTargets = $script:ScenarioTargets.ConfigurationUnit.Count
        OrganizationRootTargets = $script:ScenarioTargets.OrganizationRoot.Count
        MtaTargets = $script:ScenarioTargets.Mta.Count
        PolicyGuidTargets = $script:ScenarioTargets.PolicyGuid.Count
    }
}

function Write-ScenarioQualificationProgress
{
    param(
        [Parameter(Mandatory)] [string] $Stage,
        [string] $Phase,
        [int] $PhaseIndex = -1,
        [int] $BatchIndex = -1,
        [int] $Position = 0,
        [int] $ObjectCount = 0,
        [long] $CompletedObjectPlans = 0,
        [long] $TotalObjectPlans = 0,
        [long] $SelectionCount = 0,
        [long] $GeneratedValueCount = 0,
        [int] $FailureCount = 0)

    $progress = [ordered]@{
        UpdatedUtc = [datetime]::UtcNow.ToString("o")
        Stage = $Stage
        Phase = $Phase
        PhaseIndex = $PhaseIndex
        BatchIndex = $BatchIndex
        Position = $Position
        ObjectCount = $ObjectCount
        CompletedObjectPlans = $CompletedObjectPlans
        TotalObjectPlans = $TotalObjectPlans
        PercentComplete = if ($TotalObjectPlans -gt 0)
        {
            [math]::Round(($CompletedObjectPlans * 100.0) / $TotalObjectPlans, 2)
        }
        else
        {
            0
        }
        SelectionCount = $SelectionCount
        GeneratedValueCount = $GeneratedValueCount
        FailureCount = $FailureCount
    }
    Write-AtomicJsonSnapshot `
        -Path (Join-Path $script:RunDirectory "qualification-progress.json") `
        -InputObject $progress `
        -Depth 4
}

function Test-ScenarioDeterministicPlanQualification
{
    $failures = [Collections.Generic.List[object]]::new()
    $generatedValueCount = 0L
    $selectionCount = 0L
    $phases = @(Get-ScenarioPhaseDefinitions)
    $totalObjectPlans = 0L
    foreach ($phase in $phases)
    {
        $objectCount = if ([string]$phase.EntityKind -eq "User")
        {
            [int]$script:ScenarioCounts.N_User
        }
        else
        {
            [int]$script:ScenarioCounts.N_Groups
        }
        $totalObjectPlans += [long]$objectCount * $script:ScenarioBatchesPerPhase
    }
    $completedObjectPlans = 0L
    Write-ScenarioQualificationProgress `
        -Stage "DeterministicPlan" `
        -CompletedObjectPlans 0 `
        -TotalObjectPlans $totalObjectPlans

    foreach ($phaseIndex in 0..($phases.Count - 1))
    {
        $phase = $phases[$phaseIndex]
        $objectCount = if ([string]$phase.EntityKind -eq "User")
        {
            [int]$script:ScenarioCounts.N_User
        }
        else
        {
            [int]$script:ScenarioCounts.N_Groups
        }

        foreach ($batchIndex in 0..($script:ScenarioBatchesPerPhase - 1))
        {
            $isInitial = $batchIndex -eq 0
            $random = New-ScenarioRandom -PhaseIndex $phaseIndex -BatchIndex $batchIndex
            $recipientOrder = @(
                if (@($phase.RecipientProperties).Count -gt 0)
                {
                    Get-ShuffledScenarioArray -Items @($phase.RecipientProperties) -Random $random
                }
            )
            $linkOrder = @(
                if (@($phase.LinkProperties).Count -gt 0)
                {
                    Get-ShuffledScenarioArray -Items @($phase.LinkProperties) -Random $random
                }
            )

            for ($position = 1; $position -le $objectCount; $position++)
            {
                if ($isInitial)
                {
                    $recipientSelection = @(Get-ScenarioInitialSelection -PropertyOrder $recipientOrder -Position $position)
                    $linkSelection = @(Get-ScenarioInitialSelection -PropertyOrder $linkOrder -Position $position)
                }
                else
                {
                    $objectRandom = New-ScenarioRandom -PhaseIndex $phaseIndex -BatchIndex $batchIndex -Salt $position
                    $recipientWidth = if ($recipientOrder.Count -gt 0) { 1 + ($position % $recipientOrder.Count) } else { 0 }
                    $linkWidth = if ($linkOrder.Count -gt 0) { 1 + ($position % $linkOrder.Count) } else { 0 }
                    $recipientSelection = @(Select-ScenarioProperties -Properties @($phase.RecipientProperties) -Width $recipientWidth -Random $objectRandom)
                    $linkSelection = @(Select-ScenarioProperties -Properties @($phase.LinkProperties) -Width $linkWidth -Random $objectRandom)
                }

                $selection = if ($recipientOrder.Count -gt 0 -and $linkOrder.Count -gt 0)
                {
                    Merge-ScenarioMixedSelections `
                        -RecipientSelection $recipientSelection `
                        -LinkSelection $linkSelection `
                        -FullRecipientOrder $recipientOrder `
                        -FullLinkOrder $linkOrder `
                        -RequireDistinct $true
                }
                else
                {
                    [ordered]@{ Recipient = $recipientSelection; Link = $linkSelection }
                }

                $entity = [pscustomobject]@{
                    Name = "Qualification-$($phase.EntityKind)-$position"
                    Guid = [Guid]::NewGuid()
                    Kind = [string]$phase.EntityKind
                }
                $valueRandom = New-ScenarioRandom -PhaseIndex $phaseIndex -BatchIndex $batchIndex -Salt ($position * 13)
                foreach ($name in @($selection.Recipient) + @($selection.Link))
                {
                    $selectionCount++
                    try
                    {
                        $metadata = Get-ScenarioAttributeMetadata -Name $name
                        $objectSid = if ($script:ScenarioTargets.Sid.Count -gt 0) { $script:ScenarioTargets.Sid[0] } else { $null }
                        $values = @(New-ScenarioTypedValues -Metadata $metadata -Entity $entity -Random $valueRandom -ObjectSid $objectSid)
                        if ($values.Count -eq 0)
                        {
                            throw "generator returned no values."
                        }
                        foreach ($value in $values)
                        {
                            if ($null -eq $value)
                            {
                                throw "generator returned a null value."
                            }
                            if ($value -is [string] -and [int64]$metadata.RangeUpper -gt 0 -and
                                $value.Length -gt [int64]$metadata.RangeUpper)
                            {
                                throw "generated string exceeds rangeUpper $($metadata.RangeUpper)."
                            }
                            $policyGuid = [Guid]::Empty
                            if ($name -match "(?i)^msExchPolicies(Included|Excluded)$" -and
                                -not [Guid]::TryParse([string]$value, [ref]$policyGuid))
                            {
                                throw "generated policy value '$value' is not a GUID."
                            }
                            $generatedValueCount++
                        }
                    }
                    catch
                    {
                        $failures.Add([ordered]@{
                            Phase = [string]$phase.Name
                            PhaseIndex = $phaseIndex
                            Batch = $batchIndex
                            Position = $position
                            Property = [string]$name
                            Error = Get-ScenarioExceptionChain -Exception $_.Exception
                        })
                    }
                }
                $completedObjectPlans++
                if (($position % 10) -eq 0 -or $position -eq $objectCount)
                {
                    Write-ScenarioQualificationProgress `
                        -Stage "DeterministicPlan" `
                        -Phase ([string]$phase.Name) `
                        -PhaseIndex $phaseIndex `
                        -BatchIndex $batchIndex `
                        -Position $position `
                        -ObjectCount $objectCount `
                        -CompletedObjectPlans $completedObjectPlans `
                        -TotalObjectPlans $totalObjectPlans `
                        -SelectionCount $selectionCount `
                        -GeneratedValueCount $generatedValueCount `
                        -FailureCount $failures.Count
                }
            }
        }
    }

    $report = [ordered]@{
        TimestampUtc = [datetime]::UtcNow.ToString("o")
        PlanVersion = $script:ScenarioPlanVersion
        BatchesPerPhase = $script:ScenarioBatchesPerPhase
        ScenarioCommand = $ScenarioCommand
        ScenarioSetMode = $ScenarioSetMode
        SharedPopulationVersion = if ($script:LegacyCommandSpecificPopulation) { 0 } else { $script:ScenarioSharedPopulationVersion }
        PopulationSourceRunDirectory = $script:ResolvedPopulationSourceRunDirectory
        RandomSeed = $RandomSeed
        UserObjects = $script:ScenarioCounts.N_User
        GroupObjects = $script:ScenarioCounts.N_Groups
        PhaseNames = @($phases | ForEach-Object { [string]$_.Name })
        QualificationFingerprint = Get-ScenarioQualificationFingerprint
        PhaseCount = $phases.Count
        SelectionCount = $selectionCount
        GeneratedValueCount = $generatedValueCount
        FailureCount = $failures.Count
        Failures = $failures.ToArray()
    }
    $reportPath = Join-Path $script:RunDirectory "qualification.json"
    Write-AtomicJsonSnapshot -Path $reportPath -InputObject $report -Depth 8
    Write-ScenarioQualificationProgress `
        -Stage "Completed" `
        -CompletedObjectPlans $completedObjectPlans `
        -TotalObjectPlans $totalObjectPlans `
        -SelectionCount $selectionCount `
        -GeneratedValueCount $generatedValueCount `
        -FailureCount $failures.Count
    if ($failures.Count -gt 0)
    {
        throw "Scenario deterministic-plan qualification found $($failures.Count) harness defects. See $reportPath."
    }

    Write-RunEvent -Level "Success" -Message "ScenarioTest deterministic-plan qualification passed." -Data @{
        ReportPath = $reportPath
        SelectionCount = $selectionCount
        GeneratedValueCount = $generatedValueCount
    }
}

function Get-ScenarioQualificationStatus
{
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path))
    {
        return [ordered]@{
            Passed = $false
            Reason = "qualification report is missing"
        }
    }

    try
    {
        $qualification = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch
    {
        return [ordered]@{
            Passed = $false
            Reason = "qualification report is malformed: $($_.Exception.Message)"
        }
    }

    $requiredProperties = @(
        "PlanVersion",
        "BatchesPerPhase",
        "ScenarioCommand",
        "RandomSeed",
        "UserObjects",
        "GroupObjects",
        "PhaseNames",
        "QualificationFingerprint",
        "FailureCount")
    $propertyNames = @(
        $qualification.PSObject.Properties |
            ForEach-Object { $_.Name }
    )
    $missingProperties = @(
        $requiredProperties |
            Where-Object { $propertyNames -notcontains $_ }
    )
    if ($missingProperties.Count -gt 0)
    {
        return [ordered]@{
            Passed = $false
            Reason = "qualification report is incomplete; missing $($missingProperties -join ', ')"
        }
    }

    $expectedPhases = @((Get-ScenarioCommandDefinition).PhaseNames)
    $actualPhases = @($qualification.PhaseNames)
    $mismatches = [Collections.Generic.List[string]]::new()
    if ([int]$qualification.PlanVersion -ne $script:ScenarioPlanVersion)
    {
        $mismatches.Add("plan version")
    }
    if ([int]$qualification.BatchesPerPhase -ne $script:ScenarioBatchesPerPhase)
    {
        $mismatches.Add("batches per phase")
    }
    $qualificationScenarioCommand =
        ConvertTo-CurrentScenarioCommandName -Value ([string]$qualification.ScenarioCommand)
    if (-not [string]::Equals($qualificationScenarioCommand, $ScenarioCommand, [StringComparison]::OrdinalIgnoreCase))
    {
        $mismatches.Add("scenario command")
    }
    $qualificationScenarioSetMode =
        if ($propertyNames -contains "ScenarioSetMode" -and
            -not [string]::IsNullOrWhiteSpace([string]$qualification.ScenarioSetMode))
        {
            [string]$qualification.ScenarioSetMode
        }
        elseif ([int]$qualification.BatchesPerPhase -eq 1)
        {
            "MiniSet"
        }
        else
        {
            "Full"
        }
    if (-not [string]::Equals($qualificationScenarioSetMode, $ScenarioSetMode, [StringComparison]::OrdinalIgnoreCase))
    {
        $mismatches.Add("scenario set mode")
    }
    if ([int]$qualification.RandomSeed -ne $RandomSeed)
    {
        $mismatches.Add("random seed")
    }
    if ([int]$qualification.UserObjects -ne [int]$script:ScenarioCounts.N_User -or
        [int]$qualification.GroupObjects -ne [int]$script:ScenarioCounts.N_Groups)
    {
        $mismatches.Add("population counts")
    }
    if (($actualPhases -join "`n") -cne ($expectedPhases -join "`n"))
    {
        $mismatches.Add("phase selection")
    }
    $fingerprintParameters = @{}
    if ($propertyNames -notcontains "ScenarioSetMode")
    {
        $fingerprintParameters["LegacyWithoutScenarioSetMode"] = $true
    }
    if ($propertyNames -notcontains "SharedPopulationVersion" -or
        [int]$qualification.SharedPopulationVersion -eq 0 -or
        $propertyNames -notcontains "PopulationSourceRunDirectory")
    {
        $fingerprintParameters["LegacyWithoutPopulationSource"] = $true
    }
    if ([string]::Equals(
            [string]$qualification.ScenarioCommand,
            "RunAll",
            [StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals(
            [string]$qualification.ScenarioCommand,
            "Run-All-Scenarios",
            [StringComparison]::OrdinalIgnoreCase))
    {
        $fingerprintParameters["LegacyScenarioCommandName"] =
            [string]$qualification.ScenarioCommand
    }
    $expectedQualificationFingerprint = Get-ScenarioQualificationFingerprint @fingerprintParameters
    if (-not [string]::Equals(
        [string]$qualification.QualificationFingerprint,
        $expectedQualificationFingerprint,
        [StringComparison]::OrdinalIgnoreCase))
    {
        $mismatches.Add("qualification fingerprint")
    }
    if ([int]$qualification.FailureCount -ne 0)
    {
        $mismatches.Add("failure count")
    }

    return [ordered]@{
        Passed = $mismatches.Count -eq 0
        Reason = if ($mismatches.Count -eq 0)
        {
            "qualification report is compatible and zero-defect"
        }
        else
        {
            "qualification report mismatch: $($mismatches -join ', ')"
        }
        Report = $qualification
    }
}

function ConvertTo-ScenarioValueKey
{
    param([object] $Value)

    if ($Value -is [byte[]])
    {
        return "b:$([Convert]::ToBase64String($Value))"
    }
    if ($Value -is [datetime])
    {
        return "d:$($Value.ToUniversalTime().ToString('o'))"
    }
    return "s:$([string]$Value)"
}

function Test-ScenarioValueEqual
{
    param(
        [object] $Left,
        [object] $Right)

    return (ConvertTo-ScenarioValueKey -Value $Left) -eq (ConvertTo-ScenarioValueKey -Value $Right)
}

function Get-ScenarioCurrentValues
{
    param(
        [Parameter(Mandatory)] [object] $Entity,
        [Parameter(Mandatory)] [string[]] $Names)

    $values = @{}
    if ($WhatIfTraffic)
    {
        foreach ($name in @($Names))
        {
            $key = "$($Entity.Guid)|$name"
            if ($script:ScenarioTargets.WhatIfValues.ContainsKey($key))
            {
                $values[$name] = ConvertTo-ScenarioValueArray -Value $script:ScenarioTargets.WhatIfValues[$key]
            }
            else
            {
                $values[$name] = @()
            }
        }
        return $values
    }

    $uniqueNames = @($Names | Select-Object -Unique)
    $propertyBatchSize = 16
    for ($offset = 0; $offset -lt $uniqueNames.Count; $offset += $propertyBatchSize)
    {
        $lastIndex = [math]::Min($offset + $propertyBatchSize - 1, $uniqueNames.Count - 1)
        $propertyBatch = @($uniqueNames[$offset..$lastIndex])
        $adObject = Get-ScenarioAdObject -Entity $Entity -Properties $propertyBatch
        foreach ($name in $propertyBatch)
        {
            $values[$name] = @(Get-ScenarioAttributeValues -AdObject $adObject -Name $name)
        }
    }
    return $values
}

function Set-ScenarioWhatIfValues
{
    param(
        [Parameter(Mandatory)] [object] $Entity,
        [hashtable] $Add,
        [hashtable] $Replace,
        [hashtable] $Remove,
        [string[]] $Clear)

    foreach ($name in @($Add.Keys))
    {
        $key = "$($Entity.Guid)|$name"
        $existing = [Collections.Generic.List[object]]::new()
        if ($script:ScenarioTargets.WhatIfValues.ContainsKey($key))
        {
            foreach ($oldValue in (ConvertTo-ScenarioValueArray -Value $script:ScenarioTargets.WhatIfValues[$key]))
            {
                $existing.Add($oldValue)
            }
        }
        foreach ($value in (ConvertTo-ScenarioValueArray -Value $Add[$name]))
        {
            $alreadyPresent = $false
            foreach ($oldValue in $existing)
            {
                if (Test-ScenarioValueEqual -Left $oldValue -Right $value)
                {
                    $alreadyPresent = $true
                    break
                }
            }
            if (-not $alreadyPresent)
            {
                $existing.Add($value)
            }
        }
        $script:ScenarioTargets.WhatIfValues[$key] = $existing.ToArray()
    }
    foreach ($name in @($Replace.Keys))
    {
        $key = "$($Entity.Guid)|$name"
        $script:ScenarioTargets.WhatIfValues[$key] = ConvertTo-ScenarioValueArray -Value $Replace[$name]
    }
    foreach ($name in @($Remove.Keys))
    {
        $key = "$($Entity.Guid)|$name"
        if ($script:ScenarioTargets.WhatIfValues.ContainsKey($key))
        {
            $remaining = [Collections.Generic.List[object]]::new()
            foreach ($existing in (ConvertTo-ScenarioValueArray -Value $script:ScenarioTargets.WhatIfValues[$key]))
            {
                $removeValues = ConvertTo-ScenarioValueArray -Value $Remove[$name]
                if (-not ($removeValues | Where-Object { Test-ScenarioValueEqual -Left $_ -Right $existing }))
                {
                    $remaining.Add($existing)
                }
            }
            $script:ScenarioTargets.WhatIfValues[$key] = $remaining.ToArray()
        }
    }
    foreach ($name in @($Clear))
    {
        $script:ScenarioTargets.WhatIfValues.Remove("$($Entity.Guid)|$name")
    }
}

function ConvertTo-ScenarioOperationValue
{
    param(
        [Parameter(Mandatory)] [object[]] $Values,
        [Parameter(Mandatory)] [bool] $SingleValued)

    if ($SingleValued)
    {
        return $Values[0]
    }
    return @($Values)
}

function Add-ScenarioPendingValidation
{
    param(
        [Parameter(Mandatory)] [object] $Entity,
        [Parameter(Mandatory)] [string] $Reason,
        [Parameter(Mandatory)] [string[]] $RequiredCookies)

    $now = [datetime]::UtcNow
    $dueUtc = if ($WhatIfTraffic) { $now } else { $now.AddSeconds(15) }
    $script:PendingValidations[[string]$Entity.Guid] = [ordered]@{
        Guid = ([Guid]$Entity.Guid).ToString()
        Identity = [string]$Entity.Identity
        ExpectedState = "Active"
        Reason = $Reason
        DueUtc = $dueUtc.ToString("o")
        DeadlineUtc = $now.AddSeconds($ValidationTimeoutSeconds).ToString("o")
        Attempts = 0
        MutationUtc = $now.ToString("o")
        RequiredCookies = @($RequiredCookies)
    }
}

function Get-ScenarioOperationValueTypeKey
{
    param([Parameter(Mandatory)] [object] $Value)

    if ($Value -is [byte[]])
    {
        return "System.Byte[]"
    }
    if ($Value -is [Collections.IEnumerable] -and -not ($Value -is [string]))
    {
        $elementTypes = @($Value |
            ForEach-Object {
                if ($_ -is [byte[]])
                {
                    "System.Byte[]"
                }
                elseif ($null -eq $_)
                {
                    "<null>"
                }
                else
                {
                    $_.GetType().FullName
                }
            } |
            Select-Object -Unique |
            Sort-Object)
        return "$($Value.GetType().FullName)<$($elementTypes -join ',')>"
    }
    return $Value.GetType().FullName
}

function ConvertTo-ScenarioCommandValue
{
    param([Parameter(Mandatory)] [object] $Value)

    if ($Value -is [byte[]])
    {
        return ,([byte[]]$Value)
    }
    if ($Value -is [string] -or -not ($Value -is [Collections.IEnumerable]))
    {
        return $Value
    }

    $items = @($Value)
    if ($items.Count -eq 0)
    {
        return ,([object[]]@())
    }
    $elementType = $items[0].GetType()
    if (@($items | Where-Object { $null -eq $_ -or $_.GetType() -ne $elementType }).Count -gt 0)
    {
        return ,([object[]]$items)
    }

    if ($elementType.IsValueType)
    {
        return ,([object[]]$items)
    }
    $typedArray = [Array]::CreateInstance($elementType, $items.Count)
    for ($index = 0; $index -lt $items.Count; $index++)
    {
        $typedArray.SetValue($items[$index], $index)
    }
    return ,$typedArray
}

function New-ScenarioLdapRequestBatches
{
    param(
        [hashtable] $Add = @{},
        [hashtable] $Replace = @{},
        [hashtable] $Remove = @{},
        [string[]] $Clear = @(),
        [hashtable] $GeneratedValues = @{},
        [int] $MaximumAttributeCount = 16)

    $modifications = [Collections.Generic.List[object]]::new()
    foreach ($name in @($Add.Keys))
    {
        $value = ConvertTo-ScenarioCommandValue -Value $Add[$name]
        $modifications.Add([pscustomobject]@{
            Name = [string]$name
            Operation = "Add"
            Value = $value
            TypeKey = Get-ScenarioOperationValueTypeKey -Value $value
        })
    }
    foreach ($name in @($Replace.Keys))
    {
        $value = ConvertTo-ScenarioCommandValue -Value $Replace[$name]
        $modifications.Add([pscustomobject]@{
            Name = [string]$name
            Operation = "Replace"
            Value = $value
            TypeKey = Get-ScenarioOperationValueTypeKey -Value $value
        })
    }
    foreach ($name in @($Remove.Keys))
    {
        $value = ConvertTo-ScenarioCommandValue -Value $Remove[$name]
        $modifications.Add([pscustomobject]@{
            Name = [string]$name
            Operation = "Remove"
            Value = $value
            TypeKey = Get-ScenarioOperationValueTypeKey -Value $value
        })
    }
    foreach ($name in @($Clear))
    {
        $modifications.Add([pscustomobject]@{
            Name = [string]$name
            Operation = "Clear"
            Value = $null
            TypeKey = "Clear"
        })
    }

    $batches = [Collections.Generic.List[object]]::new()
    $groups = @($modifications |
        Group-Object { "$($_.Operation)|$($_.TypeKey)" } |
        Sort-Object Name)
    foreach ($group in $groups)
    {
        $groupModifications = @($group.Group | Sort-Object Name)
        for ($offset = 0; $offset -lt $groupModifications.Count; $offset += $MaximumAttributeCount)
        {
            $lastIndex = [math]::Min($offset + $MaximumAttributeCount - 1, $groupModifications.Count - 1)
            $batchModifications = @($groupModifications[$offset..$lastIndex])
            $batchNames = @($batchModifications | ForEach-Object { $_.Name })
            $batchAdd = @{}
            $batchReplace = @{}
            $batchRemove = @{}
            $batchClear = [Collections.Generic.List[string]]::new()
            $batchGeneratedValues = @{}
            foreach ($modification in $batchModifications)
            {
                switch ($modification.Operation)
                {
                    "Add" { $batchAdd[$modification.Name] = $modification.Value }
                    "Replace" { $batchReplace[$modification.Name] = $modification.Value }
                    "Remove" { $batchRemove[$modification.Name] = $modification.Value }
                    "Clear" { $batchClear.Add($modification.Name) }
                }
                if ($GeneratedValues.ContainsKey($modification.Name))
                {
                    $batchGeneratedValues[$modification.Name] = $GeneratedValues[$modification.Name]
                }
            }
            $batches.Add([pscustomobject]@{
                AttributeNames = $batchNames
                Add = $batchAdd
                Replace = $batchReplace
                Remove = $batchRemove
                Clear = $batchClear.ToArray()
                GeneratedValues = $batchGeneratedValues
            })
        }
    }
    return $batches.ToArray()
}

function Invoke-ScenarioLdapRequest
{
    param(
        [Parameter(Mandatory)] [object] $Entity,
        [Parameter(Mandatory)] [string] $Action,
        [hashtable] $Add = @{},
        [hashtable] $Replace = @{},
        [hashtable] $Remove = @{},
        [string[]] $Clear = @(),
        [string] $SplitReason = "None",
        [Parameter(Mandatory)] [string] $Phase,
        [Parameter(Mandatory)] [int] $BatchIndex,
        [Parameter(Mandatory)] [int] $Position,
        [hashtable] $GeneratedValues = @{},
        [bool] $RangedValueChanged = $false,
        [switch] $AggregateFailure)

    $requestBatches = @(New-ScenarioLdapRequestBatches `
        -Add $Add `
        -Replace $Replace `
        -Remove $Remove `
        -Clear $Clear `
        -GeneratedValues $GeneratedValues)
    if ($requestBatches.Count -eq 0)
    {
        $startedUtc = [datetime]::UtcNow
        $operationDetails = @{
            Phase = $Phase
            Batch = $BatchIndex
            Position = $Position
            Action = $Action
            Attributes = @()
            CommandSplit = $SplitReason
            RequestIndex = 0
            RequestCount = 0
        }
        Add-OperationRecord -Operation "ScenarioLDAP" -Status "NoOp" -StartedUtc $startedUtc -Identity $Entity.Identity -Guid $Entity.Guid -Details $operationDetails
        return [ordered]@{
            Changed = $false
            Failed = $false
            RangedMutation = $false
            RequestCount = 0
            SplitReason = $SplitReason
        }
    }

    $requestCount = 0
    $succeededRequestCount = 0
    $failed = $false
    $effectiveSplitReason = if ($requestBatches.Count -gt 1)
    {
        "OperationValueTypeAndAttributeCountLimit=16; $SplitReason"
    }
    else
    {
        $SplitReason
    }

    for ($requestIndex = 0; $requestIndex -lt $requestBatches.Count; $requestIndex++)
    {
        $requestBatch = $requestBatches[$requestIndex]
        $requestCount++
        $startedUtc = [datetime]::UtcNow
        $operationDetails = @{
            Phase = $Phase
            Batch = $BatchIndex
            Position = $Position
            Action = $Action
            Attributes = @($requestBatch.AttributeNames)
            CommandSplit = $effectiveSplitReason
            RequestIndex = $requestIndex + 1
            RequestCount = $requestBatches.Count
        }
        $script:Counters.OperationsAttempted++
        $script:Counters.ScenarioLdapRequests++
        try
        {
            if ($WhatIfTraffic)
            {
                Set-ScenarioWhatIfValues `
                    -Entity $Entity `
                    -Add $requestBatch.Add `
                    -Replace $requestBatch.Replace `
                    -Remove $requestBatch.Remove `
                    -Clear $requestBatch.Clear
            }
            else
            {
                $parameters = @{
                    Identity = if ($Entity.PSObject.Properties.Name -contains "DistinguishedName" -and
                        -not [string]::IsNullOrWhiteSpace([string]$Entity.DistinguishedName))
                    {
                        [string]$Entity.DistinguishedName
                    }
                    else
                    {
                        [Guid]$Entity.Guid
                    }
                    ErrorAction = "Stop"
                }
                if ($requestBatch.Add.Count -gt 0) { $parameters.Add = $requestBatch.Add }
                if ($requestBatch.Replace.Count -gt 0) { $parameters.Replace = $requestBatch.Replace }
                if ($requestBatch.Remove.Count -gt 0) { $parameters.Remove = $requestBatch.Remove }
                if ($requestBatch.Clear.Count -gt 0) { $parameters.Clear = @($requestBatch.Clear) }
                Set-ADObject @parameters
            }
            $script:Counters.OperationsSucceeded++
            $script:Counters.Writes++
            $succeededRequestCount++
            Add-OperationRecord -Operation "ScenarioLDAP" -Status "Success" -StartedUtc $startedUtc -Identity $Entity.Identity -Guid $Entity.Guid -Details $operationDetails
        }
        catch
        {
            $failed = $true
            $script:Counters.OperationsFailed++
            Add-OperationRecord -Operation "ScenarioLDAP" -Status "Failed" -StartedUtc $startedUtc -Identity $Entity.Identity -Guid $Entity.Guid -Details $operationDetails -Exception $_.Exception
            if ($AggregateFailure)
            {
                Add-ScenarioBatchFailure -Category "ScenarioLdapMutationFailure" -Message "Scenario LDAP $Action failed for $($Entity.Identity): $($_.Exception.Message)" -Data @{
                    Phase = $Phase
                    Batch = $BatchIndex
                    Position = $Position
                    Attributes = @($requestBatch.AttributeNames)
                    GeneratedValues = $requestBatch.GeneratedValues
                    CommandSplit = $effectiveSplitReason
                    RequestIndex = $requestIndex + 1
                    RequestCount = $requestBatches.Count
                    Exception = Get-ScenarioExceptionChain -Exception $_.Exception
                }
                continue
            }
            Stop-LongevityTraffic -Category "ScenarioLdapMutationFailure" -Message "Scenario LDAP $Action failed for $($Entity.Identity): $($_.Exception.Message)" -Exception $_.Exception -Data @{
                Phase = $Phase
                Batch = $BatchIndex
                Position = $Position
                Attributes = @($requestBatch.AttributeNames)
                GeneratedValues = $requestBatch.GeneratedValues
                CommandSplit = $effectiveSplitReason
                RequestIndex = $requestIndex + 1
                RequestCount = $requestBatches.Count
            }
            throw
        }
    }

    return [ordered]@{
        Changed = $succeededRequestCount -gt 0
        Failed = $failed
        RangedMutation = $RangedValueChanged -and $succeededRequestCount -gt 0
        RequestCount = $requestCount
        SplitReason = $effectiveSplitReason
    }
}

function Wait-ScenarioBatchValidations
{
    param(
        [Parameter(Mandatory)] [System.Collections.Generic.List[Guid]] $Guids,
        [switch] $AggregateFailures,
        [switch] $TrackScenarioStage)

    $keys = @($Guids | ForEach-Object { $_.ToString() } | Select-Object -Unique)
    if (-not $WhatIfTraffic)
    {
        Start-Sleep -Seconds 15
    }
    if ($TrackScenarioStage -and $null -ne $script:ScenarioState.CurrentBatch)
    {
        $script:ScenarioState.CurrentBatch.Stage = "Comparing"
        $script:ScenarioState.CurrentBatch.ObjectsToCompare = $keys.Count
        $script:ScenarioState.CurrentBatch.ObjectsCompared = 0
        $script:ScenarioState.CurrentBatch.LastUpdatedUtc = [datetime]::UtcNow.ToString("o")
        Save-Checkpoint
    }
    $deadlineUtc = [datetime]::UtcNow.AddSeconds($ValidationTimeoutSeconds)
    while (-not $script:StopRequested -and [datetime]::UtcNow -lt $deadlineUtc)
    {
        Invoke-DueValidations -AggregateFailures:$AggregateFailures -OnlyGuids $keys
        $remaining = @($keys | Where-Object { $script:PendingValidations.ContainsKey($_) })
        if ($TrackScenarioStage -and $null -ne $script:ScenarioState.CurrentBatch)
        {
            $script:ScenarioState.CurrentBatch.ObjectsCompared = $keys.Count - $remaining.Count
            $script:ScenarioState.CurrentBatch.LastUpdatedUtc = [datetime]::UtcNow.ToString("o")
        }
        if ($remaining.Count -eq 0)
        {
            if ($TrackScenarioStage)
            {
                Save-Checkpoint
            }
            return
        }
        Start-Sleep -Seconds 1
    }
    if (-not $script:StopRequested)
    {
        if ($AggregateFailures)
        {
            foreach ($guid in @($keys | Where-Object { $script:PendingValidations.ContainsKey($_) }))
            {
                $item = $script:PendingValidations[$guid]
                Complete-Validation -Item $item -Status "Failed" -Details @{ Reason = "ScenarioBatchValidationTimeout" }
                [void]$script:PendingValidations.Remove($guid)
                Add-ScenarioBatchFailure -Category "ScenarioCompareTimeout" -Message "Scenario batch did not reach DataSame for $($item.Identity)." -Data @{
                    Validation = $item
                }
            }
            return
        }
        Stop-LongevityTraffic -Category "ScenarioCompareTimeout" -Message "Scenario batch did not reach DataSame for every mutated GUID." -Data @{
            PendingGuids = @($keys | Where-Object { $script:PendingValidations.ContainsKey($_) })
        }
    }
    throw "Scenario batch validation timed out."
}

function Get-ScenarioProtectedAttribute
{
    param([Parameter(Mandatory)] [string] $Name)

    return $Name -match "(?i)^(mail|mailNickname|legacyExchangeDN|proxyAddresses|targetAddress|objectCategory|objectClass|objectGUID|objectSid|distinguishedName|name|cn|sAMAccountName)$"
}

function Get-ScenarioUnsupportedUpsertAttribute
{
    param([Parameter(Mandatory)] [string] $Name)

    return $Name -match "(?i)^(objectCategory|objectClass|objectGUID|objectSid|distinguishedName|name|cn)$"
}

function Get-ScenarioUnsupportedDeletionAttribute
{
    param([Parameter(Mandatory)] [string] $Name)

    return $Name -match "(?i)^(msExchCU|msExchOURoot)$"
}

function Initialize-ScenarioDeletionBaseline
{
    param(
        [Parameter(Mandatory)] [object] $Entity,
        [Parameter(Mandatory)] [string] $Phase,
        [Parameter(Mandatory)] [int] $BatchIndex,
        [Parameter(Mandatory)] [int] $Position,
        [Parameter(Mandatory)] [string[]] $SelectedProperties,
        [Parameter(Mandatory)] [Random] $Random,
        [Parameter(Mandatory)] [string[]] $RequiredCookies,
        [switch] $AggregateFailure)

    $metadataByName = @{}
    foreach ($name in $SelectedProperties)
    {
        $metadataByName[$name] = Get-ScenarioAttributeMetadata -Name $name
    }
    $current = Get-ScenarioCurrentValues -Entity $Entity -Names $SelectedProperties
    $objectSid = $null
    if (-not $WhatIfTraffic)
    {
        $adObject = Get-ScenarioAdObject -Entity $Entity
        $objectSid = $adObject.PSObject.Properties["objectSid"].Value
    }

    $protectedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $SelectedProperties)
    {
        if (Get-ScenarioProtectedAttribute -Name $name)
        {
            [void]$protectedNames.Add($name)
        }
    }

    $seedAdd = @{}
    $seedReplace = @{}
    $seedValues = @{}
    foreach ($name in $SelectedProperties)
    {
        $metadata = $metadataByName[$name]
        $existing = @($current[$name])
        $isSingleValued = Test-ScenarioSingleValuedForEntity -Metadata $metadata -Entity $Entity
        if ($existing.Count -eq 0 -or (-not $isSingleValued -and $protectedNames.Contains($name)))
        {
            $seedCount = if ($isSingleValued -or -not $protectedNames.Contains($name)) { 1 } else { 2 }
            $seededValues = [Collections.Generic.List[object]]::new()
            $seededKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($existingValue in $existing)
            {
                [void]$seededKeys.Add((ConvertTo-ScenarioValueKey -Value $existingValue))
            }
            while ($seededValues.Count -lt $seedCount)
            {
                foreach ($candidate in @(New-ScenarioTypedValues -Metadata $metadata -Entity $Entity -Random $Random -ObjectSid $objectSid))
                {
                    if ($seededKeys.Add((ConvertTo-ScenarioValueKey -Value $candidate)))
                    {
                        $seededValues.Add($candidate)
                    }
                    if ($seededValues.Count -ge $seedCount)
                    {
                        break
                    }
                }
            }
            $seedValues[$name] = $seededValues.ToArray()
            if ($isSingleValued)
            {
                $seedReplace[$name] = $seededValues[0]
            }
            else
            {
                $seedAdd[$name] = $seededValues.ToArray()
            }
        }
    }

    if ($seedAdd.Count -eq 0 -and $seedReplace.Count -eq 0)
    {
        return [ordered]@{
            Seeded = $false
            Failed = $false
            RequestCount = 0
        }
    }

    $seedResult = Invoke-ScenarioLdapRequest `
        -Entity $Entity `
        -Action "BaselineSeed" `
        -Add $seedAdd `
        -Replace $seedReplace `
        -Phase $Phase `
        -BatchIndex $BatchIndex `
        -Position $Position `
        -SplitReason "Deletion baseline seed required before selected value existed." `
        -GeneratedValues $seedValues `
        -RangedValueChanged ($seedValues.ContainsKey("msExchMultiMailboxDatabasesLink")) `
        -AggregateFailure:$AggregateFailure
    if ($seedResult.Failed)
    {
        return [ordered]@{
            Seeded = $false
            Failed = $true
            RequestCount = [int]$seedResult.RequestCount
        }
    }

    $script:Counters.ScenarioBaselineSeeds++
    if ($seedResult.Changed)
    {
        Add-ScenarioPendingValidation -Entity $Entity -Reason "ScenarioBaselineSeed:$Phase" -RequiredCookies $RequiredCookies
    }
    return [ordered]@{
        Seeded = [bool]$seedResult.Changed
        Failed = $false
        RequestCount = [int]$seedResult.RequestCount
    }
}

function Invoke-ScenarioObjectMutation
{
    param(
        [Parameter(Mandatory)] [object] $Entity,
        [Parameter(Mandatory)] [string] $Phase,
        [Parameter(Mandatory)] [int] $BatchIndex,
        [Parameter(Mandatory)] [int] $Position,
        [Parameter(Mandatory)] [ValidateSet("Upsert", "Delete")] [string] $Operation,
        [Parameter(Mandatory)] [string[]] $SelectedProperties,
        [Parameter(Mandatory)] [Random] $Random,
        [Parameter(Mandatory)] [string[]] $RequiredCookies,
        [switch] $AggregateFailure)

    $selected = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($SelectedProperties))
    {
        if ($seen.Add([string]$name))
        {
            $selected.Add([string]$name)
        }
    }
    if ($selected.Count -eq 0)
    {
        throw "Scenario selected no attributes for $($Entity.Identity)."
    }
    if ($Operation -eq "Upsert")
    {
        $unsupported = @($selected | Where-Object { Get-ScenarioUnsupportedUpsertAttribute -Name $_ })
        if ($unsupported.Count -gt 0)
        {
            throw "Scenario selected AD-owned attributes that cannot be upserted: $($unsupported -join ', ')."
        }
    }

    $metadataByName = @{}
    foreach ($name in $selected)
    {
        $metadataByName[$name] = Get-ScenarioAttributeMetadata -Name $name
    }
    $current = Get-ScenarioCurrentValues -Entity $Entity -Names $selected.ToArray()
    $objectSid = $null
    if (-not $WhatIfTraffic)
    {
        $adObject = Get-ScenarioAdObject -Entity $Entity
        $objectSid = $adObject.PSObject.Properties["objectSid"].Value
    }

    $add = @{}
    $replace = @{}
    $remove = @{}
    $clear = [Collections.Generic.List[string]]::new()
    $generatedValues = @{}
    $deletionModes = @{}
    $rangedValueChanged = $false

    if ($Operation -eq "Upsert")
    {
        foreach ($name in $selected)
        {
            $metadata = $metadataByName[$name]
            $values = @(New-ScenarioTypedValues -Metadata $metadata -Entity $Entity -Random $Random -ObjectSid $objectSid)
            $generatedValues[$name] = $values
            $existing = @($current[$name])
            if (Test-ScenarioSingleValuedForEntity -Metadata $metadata -Entity $Entity)
            {
                if ($existing.Count -eq 1 -and (Test-ScenarioValueEqual -Left $existing[0] -Right $values[0]))
                {
                    $replace[$name] = $values[0]
                    continue
                }
                $replace[$name] = $values[0]
                if ($name -eq "msExchMultiMailboxDatabasesLink")
                {
                    $rangedValueChanged = $true
                }
            }
            else
            {
                $newValues = [Collections.Generic.List[object]]::new()
                foreach ($value in $values)
                {
                    $alreadyPresent = $false
                    foreach ($oldValue in $existing)
                    {
                        if (Test-ScenarioValueEqual -Left $oldValue -Right $value)
                        {
                            $alreadyPresent = $true
                            break
                        }
                    }
                    if (-not $alreadyPresent)
                    {
                        $newValues.Add($value)
                    }
                }
                if ($newValues.Count -gt 0)
                {
                    $add[$name] = $newValues.ToArray()
                    if ($name -eq "msExchMultiMailboxDatabasesLink")
                    {
                        $rangedValueChanged = $true
                    }
                }
            }
        }
    }
    else
    {
        $protectedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($name in $selected)
        {
            if (Get-ScenarioProtectedAttribute -Name $name)
            {
                [void]$protectedNames.Add($name)
            }
        }

        foreach ($name in $selected)
        {
            $metadata = $metadataByName[$name]
            $existing = [Collections.Generic.List[object]]::new()
            foreach ($value in @($current[$name]))
            {
                $existing.Add($value)
            }
            if ($existing.Count -eq 0)
            {
                throw "Attribute '$name' was absent after the required deletion batch-preparation stage."
            }
            $generatedValues[$name] = $existing.ToArray()
            if (Test-ScenarioSingleValuedForEntity -Metadata $metadata -Entity $Entity)
            {
                $clear.Add($name)
                $deletionModes[$name] = "ClearSingleValued"
                if ($name -eq "msExchMultiMailboxDatabasesLink")
                {
                    $rangedValueChanged = $true
                }
                continue
            }

            $mode = if ($protectedNames.Contains($name) -or $Random.Next(0, 2) -eq 0) { "RemoveValues" } else { "ClearAttribute" }
            if ($mode -eq "RemoveValues" -and $existing.Count -le 1 -and -not $protectedNames.Contains($name))
            {
                $mode = "ClearAttribute"
            }
            if ($mode -eq "ClearAttribute")
            {
                $clear.Add($name)
                $deletionModes[$name] = $mode
                if ($name -eq "msExchMultiMailboxDatabasesLink")
                {
                    $rangedValueChanged = $true
                }
                continue
            }

            $retainAtLeastOne = $true
            $maximumRemoval = [math]::Min(5, [math]::Max(1, $existing.Count - 1))
            if ($existing.Count -le 1)
            {
                throw "Attribute '$name' did not contain enough values to perform a retaining multivalue deletion."
            }
            $removeCount = $Random.Next(1, $maximumRemoval + 1)
            $removalValues = [Collections.Generic.List[object]]::new()
            $availableIndexes = [Collections.Generic.List[int]]::new()
            for ($index = 0; $index -lt $existing.Count; $index++)
            {
                $availableIndexes.Add($index)
            }
            for ($index = 0; $index -lt $removeCount; $index++)
            {
                $choice = $Random.Next(0, $availableIndexes.Count)
                $selectedIndex = $availableIndexes[$choice]
                $availableIndexes.RemoveAt($choice)
                $removalValues.Add($existing[$selectedIndex])
            }
            $remove[$name] = $removalValues.ToArray()
            $deletionModes[$name] = $mode
            if ($name -eq "msExchMultiMailboxDatabasesLink")
            {
                $rangedValueChanged = $true
            }
        }
    }

    $kindProperty = $Entity.PSObject.Properties["Kind"]
    if ($null -ne $kindProperty -and [string]$kindProperty.Value -eq "Group")
    {
        if ($add.ContainsKey("description"))
        {
            $descriptionValues = @($add["description"])
            if ($descriptionValues.Count -eq 0)
            {
                throw "Group description upsert produced no value."
            }
            [void]$add.Remove("description")
            $replace["description"] = [string]$descriptionValues[0]
        }
        elseif ($replace.ContainsKey("description"))
        {
            $descriptionValues = @($replace["description"])
            if ($descriptionValues.Count -eq 0)
            {
                throw "Group description upsert produced no value."
            }
            $replace["description"] = [string]$descriptionValues[0]
        }
    }

    $requestResult = Invoke-ScenarioLdapRequest `
        -Entity $Entity `
        -Action $Operation `
        -Add $add `
        -Replace $replace `
        -Remove $remove `
        -Clear $clear.ToArray() `
        -Phase $Phase `
        -BatchIndex $BatchIndex `
        -Position $Position `
        -GeneratedValues $generatedValues `
        -RangedValueChanged $rangedValueChanged `
        -AggregateFailure:$AggregateFailure
    if ($requestResult.Changed)
    {
        Add-ScenarioPendingValidation -Entity $Entity -Reason "Scenario:${Phase}:$Operation" -RequiredCookies $RequiredCookies
    }

    return [ordered]@{
        Guid = [Guid]$Entity.Guid
        Identity = [string]$Entity.Identity
        SelectedAttributes = $selected.ToArray()
        GeneratedValues = $generatedValues
        DeletionModes = $deletionModes
        Changed = [bool]$requestResult.Changed
        RangedMutation = [bool]$requestResult.RangedMutation
        RequestCount = [int]$requestResult.RequestCount
        BaselineSeeded = $false
        CommandSplit = "None"
        Failed = [bool]$requestResult.Failed
    }
}

function Invoke-ScenarioBatch
{
    param(
        [Parameter(Mandatory)] [object] $PhaseDefinition,
        [Parameter(Mandatory)] [int] $PhaseIndex,
        [Parameter(Mandatory)] [int] $BatchIndex)

    $isInitial = $BatchIndex -eq 0
    $repetition = if ($isInitial) { 0 } else { $BatchIndex }
    if ($isInitial)
    {
        $script:ScenarioBatchFailures.Clear()
    }
    $entities = if ([string]$PhaseDefinition.EntityKind -eq "User")
    {
        @($script:Contacts.Values | Sort-Object { ([Guid]$_.Guid).ToString("D") })
    }
    else
    {
        @($script:Groups.Values | Sort-Object { ([Guid]$_.Guid).ToString("D") })
    }
    $random = New-ScenarioRandom -PhaseIndex $PhaseIndex -BatchIndex $BatchIndex
    $objectOrder = Get-ShuffledScenarioArray -Items $entities -Random $random
    $recipientProperties = @($PhaseDefinition.RecipientProperties)
    if ([string]$PhaseDefinition.Operation -eq "Delete")
    {
        $recipientProperties = @(
            $recipientProperties |
                Where-Object { -not (Get-ScenarioUnsupportedDeletionAttribute -Name ([string]$_)) }
        )
    }
    $recipientOrder = @(
        if ($recipientProperties.Count -gt 0)
    {
        Get-ShuffledScenarioArray -Items $recipientProperties -Random $random
    }
    else
    {
        @()
    }
    )
    $linkOrder = @(
        if (@($PhaseDefinition.LinkProperties).Count -gt 0)
    {
        Get-ShuffledScenarioArray -Items @($PhaseDefinition.LinkProperties) -Random $random
    }
    else
    {
        @()
    }
    )

    $currentBatch = $script:ScenarioState.CurrentBatch
    $sameBatch = $null -ne $currentBatch -and
        [int]$currentBatch.PhaseIndex -eq $PhaseIndex -and
        [int]$currentBatch.BatchIndex -eq $BatchIndex
    if (-not $sameBatch)
    {
        $script:ScenarioState.CurrentBatch = [ordered]@{
            PhaseIndex = $PhaseIndex
            BatchIndex = $BatchIndex
            Phase = [string]$PhaseDefinition.Name
            EntityKind = [string]$PhaseDefinition.EntityKind
            Stage = "Mutating"
            ObjectCount = $objectOrder.Count
            ObjectsAttempted = 0
            ObjectsSucceeded = 0
            ObjectsFailed = 0
            ObjectsToCompare = 0
            ObjectsCompared = 0
            LastPosition = 0
            LastObjectGuid = $null
            LastUpdatedUtc = [datetime]::UtcNow.ToString("o")
            StartedUtc = [datetime]::UtcNow.ToString("o")
            BaselinePreparationCompleted = ([string]$PhaseDefinition.Operation -ne "Delete")
            BaselinePreparedGuids = @()
            BaselineSeededGuids = @()
            BaselineObjectsPrepared = 0
            BaselineObjectsSeeded = 0
            BaselineObjectsCompared = 0
            BaselinePreparationLdapRequests = 0L
            BaselinePreparationSeedCount = 0L
            MaterializedPlan = @()
            MaterializedPlanPath = $null
            MaterializedPlanCount = 0
        }
        $script:ScenarioState.CurrentBatchCompletedGuids = @()
        Save-Checkpoint
    }
    $completed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($guid in @($script:ScenarioState.CurrentBatchCompletedGuids))
    {
        [void]$completed.Add([string]$guid)
    }
    foreach ($property in @{
        Stage = "Mutating"
        EntityKind = [string]$PhaseDefinition.EntityKind
        ObjectCount = $objectOrder.Count
        ObjectsAttempted = $completed.Count
        ObjectsSucceeded = $completed.Count
        ObjectsFailed = 0
        ObjectsToCompare = 0
        ObjectsCompared = 0
        LastPosition = 0
        LastObjectGuid = $null
        LastUpdatedUtc = [datetime]::UtcNow.ToString("o")
        BaselinePreparationCompleted = ([string]$PhaseDefinition.Operation -ne "Delete")
        BaselinePreparedGuids = @()
        BaselineSeededGuids = @()
        BaselineObjectsPrepared = 0
        BaselineObjectsSeeded = 0
        BaselineObjectsCompared = 0
        BaselinePreparationLdapRequests = 0L
        BaselinePreparationSeedCount = 0L
        MaterializedPlan = @()
        MaterializedPlanPath = $null
        MaterializedPlanCount = 0
    }.GetEnumerator())
    {
        if ($script:ScenarioState.CurrentBatch -is [System.Collections.IDictionary])
        {
            if (-not $script:ScenarioState.CurrentBatch.Contains($property.Key))
            {
                $script:ScenarioState.CurrentBatch[$property.Key] = $property.Value
            }
        }
        elseif (-not ($script:ScenarioState.CurrentBatch.PSObject.Properties.Name -contains $property.Key))
        {
            Add-Member -InputObject $script:ScenarioState.CurrentBatch `
                -MemberType NoteProperty `
                -Name $property.Key `
                -Value $property.Value
        }
    }
    $script:ScenarioState.CurrentBatch.Stage = "Mutating"
    $script:ScenarioState.CurrentBatch.ObjectCount = $objectOrder.Count
    $script:ScenarioState.CurrentBatch.ObjectsAttempted = $completed.Count
    $script:ScenarioState.CurrentBatch.ObjectsSucceeded = $completed.Count
    $script:ScenarioState.CurrentBatch.ObjectsFailed = 0
    $script:ScenarioState.CurrentBatch.ObjectsToCompare = 0
    $script:ScenarioState.CurrentBatch.ObjectsCompared = 0
    $script:ScenarioState.CurrentBatch.LastUpdatedUtc = [datetime]::UtcNow.ToString("o")

    $currentBatch = $script:ScenarioState.CurrentBatch
    $batchPlans = [Collections.Generic.List[object]]::new()
    $persistedPlans = @()
    if (@($currentBatch.MaterializedPlan).Count -gt 0)
    {
        $persistedPlans = @($currentBatch.MaterializedPlan)
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$currentBatch.MaterializedPlanPath))
    {
        $planPath = Join-Path $script:RunDirectory ([string]$currentBatch.MaterializedPlanPath)
        if (-not (Test-Path -LiteralPath $planPath))
        {
            throw "Scenario materialized plan file is missing: $planPath"
        }
        $loadedPlans = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
        $persistedPlans = @($loadedPlans)
    }
    if ($persistedPlans.Count -gt 0)
    {
        $entitiesByGuid = @{}
        foreach ($entity in $entities)
        {
            $entitiesByGuid[([Guid]$entity.Guid).ToString()] = $entity
        }
        foreach ($persistedPlan in @($persistedPlans | Sort-Object Position))
        {
            $guidKey = ([Guid]$persistedPlan.Guid).ToString()
            if (-not $entitiesByGuid.ContainsKey($guidKey))
            {
                throw "Scenario materialized plan references missing entity '$guidKey'."
            }
            $batchPlans.Add([ordered]@{
                Position = [int]$persistedPlan.Position
                Entity = $entitiesByGuid[$guidKey]
                SelectedProperties = @($persistedPlan.SelectedProperties)
                RequiredCookies = @($persistedPlan.RequiredCookies)
            })
        }
    }
    else
    {
        for ($position = 1; $position -le $objectOrder.Count; $position++)
        {
            $entity = $objectOrder[$position - 1]
            if ($isInitial)
            {
                $recipientSelection = Get-ScenarioInitialSelection -PropertyOrder $recipientOrder -Position $position
                $linkSelection = Get-ScenarioInitialSelection -PropertyOrder $linkOrder -Position $position
            }
            else
            {
                $selectionRandom = New-ScenarioRandom -PhaseIndex $PhaseIndex -BatchIndex $BatchIndex -Salt $position
                $recipientWidth = if ($recipientOrder.Count -gt 0) { 1 + ($position % $recipientOrder.Count) } else { 0 }
                $linkWidth = if ($linkOrder.Count -gt 0) { 1 + ($position % $linkOrder.Count) } else { 0 }
                $recipientSelection = Select-ScenarioProperties -Properties $recipientProperties -Width $recipientWidth -Random $selectionRandom
                $linkSelection = Select-ScenarioProperties -Properties @($PhaseDefinition.LinkProperties) -Width $linkWidth -Random $selectionRandom
            }

            $selection = if ($recipientOrder.Count -gt 0 -and $linkOrder.Count -gt 0)
            {
                Merge-ScenarioMixedSelections `
                    -RecipientSelection @($recipientSelection) `
                    -LinkSelection @($linkSelection) `
                    -FullRecipientOrder $recipientOrder `
                    -FullLinkOrder $linkOrder `
                    -RequireDistinct $true
            }
            else
            {
                [ordered]@{
                    Recipient = @($recipientSelection)
                    Link = @($linkSelection)
                }
            }
            $requiredCookies =
                if ($selection.Link.Count -gt 0 -and $selection.Recipient.Count -gt 0)
                {
                    @("Recipients", "Links")
                }
                elseif ($selection.Link.Count -gt 0)
                {
                    @("Links")
                }
                else
                {
                    @("Recipients")
                }
            $batchPlans.Add([ordered]@{
                Position = $position
                Entity = $entity
                SelectedProperties = @($selection.Recipient) + @($selection.Link)
                RequiredCookies = $requiredCookies
            })
        }
        $persistedPlans = @(
            foreach ($plan in $batchPlans)
            {
                [ordered]@{
                    Position = [int]$plan.Position
                    Guid = ([Guid]$plan.Entity.Guid).ToString()
                    SelectedProperties = @($plan.SelectedProperties)
                    RequiredCookies = @($plan.RequiredCookies)
                }
            }
        )
        $planFileName = "scenario-plan-p{0:D2}-b{1:D2}.json" -f $PhaseIndex, $BatchIndex
        $planPath = Join-Path $script:RunDirectory $planFileName
        Write-AtomicJsonSnapshot -Path $planPath -InputObject $persistedPlans -Depth 5
        $currentBatch.MaterializedPlan = @()
        $currentBatch.MaterializedPlanPath = $planFileName
        $currentBatch.MaterializedPlanCount = $persistedPlans.Count
        Save-Checkpoint
    }
    if (@($currentBatch.MaterializedPlan).Count -gt 0)
    {
        $planFileName = "scenario-plan-p{0:D2}-b{1:D2}.json" -f $PhaseIndex, $BatchIndex
        $planPath = Join-Path $script:RunDirectory $planFileName
        Write-AtomicJsonSnapshot -Path $planPath -InputObject $persistedPlans -Depth 5
        $currentBatch.MaterializedPlan = @()
        $currentBatch.MaterializedPlanPath = $planFileName
        $currentBatch.MaterializedPlanCount = $persistedPlans.Count
        Save-Checkpoint
    }
    if ([int]$currentBatch.MaterializedPlanCount -ne $batchPlans.Count)
    {
        throw "Scenario materialized plan count $($currentBatch.MaterializedPlanCount) does not match object plan count $($batchPlans.Count)."
    }

    $startedUtc = [datetime]::UtcNow
    $batchGuids = [Collections.Generic.List[Guid]]::new()
    $batchStats = [ordered]@{
        Phase = [string]$PhaseDefinition.Name
        PhaseIndex = $PhaseIndex
        Batch = $BatchIndex
        Repetition = $repetition
        InitialCoverageBatch = $isInitial
        Operation = [string]$PhaseDefinition.Operation
        EntityKind = [string]$PhaseDefinition.EntityKind
        ObjectCount = $batchPlans.Count
        ObjectsCompleted = $completed.Count
        SelectedAttributeSlots = 0L
        LdapRequests = [long]$currentBatch.BaselinePreparationLdapRequests
        ObjectLevelLdapRequests = $completed.Count
        BaselineSeeds = [long]$currentBatch.BaselinePreparationSeedCount
        RangedMutations = 0
        StartedUtc = $startedUtc.ToString("o")
        Status = "Running"
    }
    Write-RunEvent -Level "Information" -Message "Scenario phase '$($PhaseDefinition.Name)' batch $BatchIndex started." -Data @{
        PhaseIndex = $PhaseIndex
        Batch = $BatchIndex
        Repetition = $repetition
        InitialCoverageBatch = $isInitial
        ObjectCount = $batchPlans.Count
        RandomSeed = $RandomSeed
    }

    if ([string]$PhaseDefinition.Operation -eq "Delete" -and
        -not [bool]$currentBatch.BaselinePreparationCompleted)
    {
        $currentBatch.Stage = "PreparingDeletionBaseline"
        Write-RunEvent -Level "Information" -Message "Scenario deletion baseline preparation started." -Data @{
            Phase = [string]$PhaseDefinition.Name
            PhaseIndex = $PhaseIndex
            Batch = $BatchIndex
            ObjectCount = $batchPlans.Count
        }
        $prepared = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($guid in @($currentBatch.BaselinePreparedGuids))
        {
            [void]$prepared.Add([string]$guid)
        }
        foreach ($guid in @($completed))
        {
            [void]$prepared.Add([string]$guid)
        }
        $seeded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($guid in @($currentBatch.BaselineSeededGuids))
        {
            [void]$seeded.Add([string]$guid)
        }
        foreach ($plan in $batchPlans)
        {
            if ($script:StopRequested)
            {
                break
            }
            $entity = $plan.Entity
            $position = [int]$plan.Position
            $guidKey = ([Guid]$entity.Guid).ToString()
            if ($completed.Contains($guidKey) -or $prepared.Contains($guidKey))
            {
                continue
            }
            $baselineRandom = New-ScenarioRandom -PhaseIndex $PhaseIndex -BatchIndex $BatchIndex -Salt (($position * 13) + 1)
            try
            {
                $baseline = Initialize-ScenarioDeletionBaseline `
                    -Entity $entity `
                    -Phase ([string]$PhaseDefinition.Name) `
                    -BatchIndex $BatchIndex `
                    -Position $position `
                    -SelectedProperties @($plan.SelectedProperties) `
                    -Random $baselineRandom `
                    -RequiredCookies @($plan.RequiredCookies) `
                    -AggregateFailure:$isInitial
            }
            catch
            {
                Save-Checkpoint
                throw
            }
            if (-not $baseline.Failed)
            {
                [void]$prepared.Add($guidKey)
                if ($baseline.Seeded)
                {
                    [void]$seeded.Add($guidKey)
                    $currentBatch.BaselinePreparationSeedCount++
                }
                $currentBatch.BaselinePreparationLdapRequests += [int]$baseline.RequestCount
            }
            $currentBatch.BaselinePreparedGuids = @($prepared)
            $currentBatch.BaselineSeededGuids = @($seeded)
            $currentBatch.BaselineObjectsPrepared = $prepared.Count
            $currentBatch.BaselineObjectsSeeded = $seeded.Count
            $currentBatch.LastPosition = $position
            $currentBatch.LastObjectGuid = $guidKey
            $currentBatch.LastUpdatedUtc = [datetime]::UtcNow.ToString("o")
            if ($baseline.Failed -or
                ($prepared.Count % 10) -eq 0 -or
                ([datetime]::UtcNow - $script:LastCheckpointUtc).TotalSeconds -ge 5)
            {
                Save-Checkpoint
            }
        }
        if ($script:StopRequested)
        {
            return
        }
        $pendingBaselineGuids = [Collections.Generic.List[Guid]]::new()
        foreach ($guid in @($seeded))
        {
            if ($script:PendingValidations.ContainsKey($guid))
            {
                $pendingBaselineGuids.Add([Guid]$guid)
            }
        }
        if ($pendingBaselineGuids.Count -gt 0)
        {
            Wait-ScenarioBatchValidations -Guids $pendingBaselineGuids -AggregateFailures:$isInitial
        }
        $currentBatch.BaselineObjectsCompared = $seeded.Count
        if ($isInitial -and $script:ScenarioBatchFailures.Count -gt 0)
        {
            Stop-LongevityTraffic -Category "ScenarioDeletionBaselinePreparationFailures" -Message "Scenario deletion baseline preparation found $($script:ScenarioBatchFailures.Count) failures." -Data @{
                Phase = [string]$PhaseDefinition.Name
                Batch = $BatchIndex
                PreparedObjects = $prepared.Count
                SeededObjects = $seeded.Count
                Failures = $script:ScenarioBatchFailures.ToArray()
            }
            return
        }
        if ($prepared.Count -ne $batchPlans.Count)
        {
            throw "Scenario deletion baseline preparation completed only $($prepared.Count) of $($batchPlans.Count) objects."
        }
        $currentBatch.BaselinePreparationCompleted = $true
        $currentBatch.Stage = "Mutating"
        $currentBatch.LastUpdatedUtc = [datetime]::UtcNow.ToString("o")
        Save-Checkpoint
        $batchStats.LdapRequests = [long]$currentBatch.BaselinePreparationLdapRequests
        $batchStats.BaselineSeeds = [long]$currentBatch.BaselinePreparationSeedCount
        Write-RunEvent -Level "Success" -Message "Scenario deletion baseline preparation passed." -Data @{
            Phase = [string]$PhaseDefinition.Name
            PhaseIndex = $PhaseIndex
            Batch = $BatchIndex
            PreparedObjects = $prepared.Count
            SeededObjects = $seeded.Count
            LdapRequests = [long]$currentBatch.BaselinePreparationLdapRequests
        }
    }

    $currentBatch.Stage = "Mutating"
    $currentBatch.ObjectsAttempted = $completed.Count
    $currentBatch.ObjectsSucceeded = $completed.Count
    $currentBatch.ObjectsFailed = 0
    $currentBatch.LastUpdatedUtc = [datetime]::UtcNow.ToString("o")

    foreach ($plan in $batchPlans)
    {
        if ($script:StopRequested)
        {
            break
        }
        $entity = $plan.Entity
        $position = [int]$plan.Position
        $guidKey = ([Guid]$entity.Guid).ToString()
        if ($completed.Contains($guidKey))
        {
            $batchGuids.Add([Guid]$entity.Guid)
            continue
        }
        $objectRandom = New-ScenarioRandom `
            -PhaseIndex $PhaseIndex `
            -BatchIndex $BatchIndex `
            -Salt $(if ([string]$PhaseDefinition.Operation -eq "Delete") { ($position * 13) + 2 } else { $position * 13 })
        try
        {
            $result = Invoke-ScenarioObjectMutation `
                -Entity $entity `
                -Phase ([string]$PhaseDefinition.Name) `
                -BatchIndex $BatchIndex `
                -Position $position `
                -Operation ([string]$PhaseDefinition.Operation) `
                -SelectedProperties @($plan.SelectedProperties) `
                -Random $objectRandom `
                -RequiredCookies @($plan.RequiredCookies) `
                -AggregateFailure:$isInitial
        }
        catch
        {
            $currentBatch.ObjectsAttempted++
            $currentBatch.ObjectsFailed++
            $currentBatch.LastPosition = $position
            $currentBatch.LastObjectGuid = $guidKey
            $currentBatch.LastUpdatedUtc = [datetime]::UtcNow.ToString("o")
            if ($isInitial)
            {
                Add-ScenarioBatchFailure -Category "ScenarioHarnessFailure" -Message "Scenario mutation planning failed for $($entity.Identity): $($_.Exception.Message)" -Data @{
                    Phase = [string]$PhaseDefinition.Name
                    Batch = $BatchIndex
                    Position = $position
                    SelectedProperties = @($plan.SelectedProperties)
                    Exception = Get-ScenarioExceptionChain -Exception $_.Exception
                }
                continue
            }
            Save-Checkpoint
            throw
        }

        if (-not $result.Failed)
        {
            $batchGuids.Add([Guid]$entity.Guid)
        }
        $currentBatch.ObjectsAttempted++
        if ($result.Failed)
        {
            $currentBatch.ObjectsFailed++
        }
        else
        {
            $currentBatch.ObjectsSucceeded++
            [void]$completed.Add($guidKey)
            $script:ScenarioState.CurrentBatchCompletedGuids = @($completed)
        }
        $currentBatch.LastPosition = $position
        $currentBatch.LastObjectGuid = $guidKey
        $currentBatch.LastUpdatedUtc = [datetime]::UtcNow.ToString("o")
        $batchStats.ObjectsCompleted++
        $batchStats.SelectedAttributeSlots += $result.SelectedAttributes.Count
        $batchStats.LdapRequests += $result.RequestCount
        $batchStats.ObjectLevelLdapRequests++
        $script:Counters.ScenarioObjectLevelLdapRequests++
        if ($result.BaselineSeeded) { $batchStats.BaselineSeeds++ }
        if ($result.RangedMutation) { $batchStats.RangedMutations++ }
        $script:Counters.ScenarioSelectedAttributeSlots += $result.SelectedAttributes.Count
        $script:ScenarioCompletedObjectWork++
        $elapsedMilliseconds = ([datetime]::UtcNow - $startedUtc).TotalMilliseconds
        $remainingSeconds = if ($script:ScenarioCompletedObjectWork -gt 0)
        {
            [math]::Round((($elapsedMilliseconds / 1000.0) / $script:ScenarioCompletedObjectWork) *
                [math]::Max(0, $script:ScenarioTotalObjectWork - $script:ScenarioCompletedObjectWork), 2)
        }
        else
        {
            $null
        }
        Write-ScenarioDetail -Record ([ordered]@{
            TimestampUtc = [datetime]::UtcNow.ToString("o")
            Seed = $RandomSeed
            Phase = [string]$PhaseDefinition.Name
            PhaseIndex = $PhaseIndex
            Batch = $BatchIndex
            Repetition = $repetition
            Position = $position
            Object = [string]$entity.Identity
            Guid = ([Guid]$entity.Guid).ToString()
            DistinguishedName = if ($entity.PSObject.Properties.Name -contains "DistinguishedName") { [string]$entity.DistinguishedName } else { $null }
            SelectedAttributes = $result.SelectedAttributes
            GeneratedValues = $result.GeneratedValues
            DeletionModes = $result.DeletionModes
            LdapAction = [string]$PhaseDefinition.Operation
            CommandSplit =
                if (@($currentBatch.BaselineSeededGuids) -contains $guidKey)
                {
                    "BatchPreparationThenDelete"
                }
                else
                {
                    $result.CommandSplit
                }
            Changed = $result.Changed
            LdapRequests = $result.RequestCount
            BaselineSeeded = @($currentBatch.BaselineSeededGuids) -contains $guidKey
            ElapsedMilliseconds = [math]::Round($elapsedMilliseconds, 2)
            EstimatedRemainingSeconds = $remainingSeconds
        })

        if (([datetime]::UtcNow - $script:LastCheckpointUtc).TotalSeconds -ge $CheckpointIntervalSeconds)
        {
            $script:ScenarioState.CurrentBatchCompletedGuids = @($completed)
            Save-Checkpoint
        }
    }
    if ($script:StopRequested)
    {
        return
    }

    $script:ScenarioState.CurrentBatch.Stage = "WaitingForSync"
    $script:ScenarioState.CurrentBatch.ObjectsToCompare = $batchGuids.Count
    $script:ScenarioState.CurrentBatch.LastUpdatedUtc = [datetime]::UtcNow.ToString("o")
    Save-Checkpoint
    Wait-ScenarioBatchValidations -Guids $batchGuids -AggregateFailures:$isInitial -TrackScenarioStage
    if ($script:StopRequested)
    {
        return
    }
    if ($isInitial -and $script:ScenarioBatchFailures.Count -gt 0)
    {
        Stop-LongevityTraffic -Category "ScenarioInitialBatchFailures" -Message "Scenario initial batch found $($script:ScenarioBatchFailures.Count) failures after checking every object." -Data @{
            Phase = [string]$PhaseDefinition.Name
            Batch = $BatchIndex
            Failures = $script:ScenarioBatchFailures.ToArray()
        }
        return
    }
    $finishedUtc = [datetime]::UtcNow
    $batchStats.FinishedUtc = $finishedUtc.ToString("o")
    $batchStats.ElapsedSeconds = [math]::Round(($finishedUtc - $startedUtc).TotalSeconds, 2)
    $batchStats.Status = "Passed"
    $script:ScenarioState.CurrentBatch.Stage = "Completed"
    $script:ScenarioState.CurrentBatch.ObjectsCompared = $batchGuids.Count
    $script:ScenarioState.CurrentBatch.LastUpdatedUtc = [datetime]::UtcNow.ToString("o")
    $script:ScenarioBatchSummaries.Add($batchStats)
    $script:Counters.ScenarioBatchesCompleted++
    $script:ScenarioState.CurrentBatch = $null
    $script:ScenarioState.CurrentBatchCompletedGuids = @()
    $script:ScenarioState.NextPhaseIndex = $PhaseIndex
    $script:ScenarioState.NextBatchIndex = $BatchIndex + 1
    Save-Checkpoint
    Write-RunEvent -Level "Success" -Message "Scenario phase '$($PhaseDefinition.Name)' batch $BatchIndex passed." -Data $batchStats
}

function Invoke-ScenarioWorkload
{
    $phases = @(Get-ScenarioPhaseDefinitions)
    $script:ScenarioTotalObjectWork = 0L
    foreach ($phase in $phases)
    {
        $count = if ([string]$phase.EntityKind -eq "User") { $script:Contacts.Count } else { $script:Groups.Count }
        $script:ScenarioTotalObjectWork += $count * $script:ScenarioBatchesPerPhase
    }

    if ($script:PendingValidations.Count -gt 0)
    {
        $bootstrapGuids = [Collections.Generic.List[Guid]]::new()
        foreach ($item in @($script:PendingValidations.Values))
        {
            $bootstrapGuids.Add((ConvertTo-ScenarioGuid -Value $item.Guid -Context "pending validation"))
        }
        Wait-CoverageValidations -Guids $bootstrapGuids.ToArray()
    }
    if ($script:StopRequested)
    {
        throw "Scenario cannot start because bootstrap validation failed."
    }

    $phaseStart = [math]::Max(0, [int]$script:ScenarioState.NextPhaseIndex)
    for ($phaseIndex = $phaseStart; $phaseIndex -lt $phases.Count -and -not $script:StopRequested; $phaseIndex++)
    {
        $phase = $phases[$phaseIndex]
        $batchStart = if ($phaseIndex -eq $phaseStart) { [math]::Max(0, [int]$script:ScenarioState.NextBatchIndex) } else { 0 }
        $phaseStartedUtc = [datetime]::UtcNow
        for ($batchIndex = $batchStart; $batchIndex -lt $script:ScenarioBatchesPerPhase -and -not $script:StopRequested; $batchIndex++)
        {
            Invoke-ScenarioBatch -PhaseDefinition $phase -PhaseIndex $phaseIndex -BatchIndex $batchIndex
        }
        if ($script:StopRequested)
        {
            break
        }
        $phaseBatchRecords = @($script:ScenarioBatchSummaries |
            Where-Object { [int]$_.PhaseIndex -eq $phaseIndex })
        $phaseFinishedUtc = [datetime]::UtcNow
        $phaseSummary = [ordered]@{
            Phase = [string]$phase.Name
            PhaseIndex = $phaseIndex
            EntityKind = [string]$phase.EntityKind
            Operation = [string]$phase.Operation
            Batches = $phaseBatchRecords
            StartedUtc = $phaseStartedUtc.ToString("o")
            FinishedUtc = $phaseFinishedUtc.ToString("o")
            ElapsedSeconds = [math]::Round(($phaseFinishedUtc - $phaseStartedUtc).TotalSeconds, 2)
        }
        $script:ScenarioPhaseSummaries.Add($phaseSummary)
        $script:ScenarioState.NextPhaseIndex = $phaseIndex + 1
        $script:ScenarioState.NextBatchIndex = 0
        Save-Checkpoint
    }
    if ($script:StopRequested)
    {
        throw "Scenario traffic paused on failure."
    }
}

function Get-ScenarioAttributeValues
{
    param(
        [Parameter(Mandatory)] [object] $AdObject,
        [Parameter(Mandatory)] [string] $Name)

    $property = $AdObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value)
    {
        return @()
    }
    return ConvertTo-ScenarioValueArray -Value $property.Value
}

function ConvertTo-ScenarioValueArray
{
    param([object] $Value)

    if ($null -eq $Value)
    {
        return @()
    }
    if ($Value -is [byte[]])
    {
        return ,([byte[]]$Value)
    }
    if ($Value -is [Collections.IEnumerable] -and -not ($Value -is [string]))
    {
        return @($Value)
    }
    return @($Value)
}

function Get-ScenarioAdObject
{
    param(
        [Parameter(Mandatory)] [object] $Entity,
        [string[]] $Properties = @())

    if ($WhatIfTraffic)
    {
        $values = @{}
        foreach ($property in @($Properties))
        {
            $key = "$($Entity.Guid)|$property"
            if ($script:ScenarioTargets.ContainsKey("WhatIfValues") -and $script:ScenarioTargets.WhatIfValues.ContainsKey($key))
            {
                $values[$property] = @($script:ScenarioTargets.WhatIfValues[$key])
            }
        }
        return [pscustomobject]@{
            DistinguishedName = if ($Entity.PSObject.Properties.Name -contains "DistinguishedName") { [string]$Entity.DistinguishedName } else { "CN=$($Entity.Name),DC=whatif,DC=local" }
            objectSid = $null
            Values = $values
        }
    }

    $parameters = @{
        Identity = [Guid]$Entity.Guid
        Properties = @($Properties + @("DistinguishedName", "objectSid") | Select-Object -Unique)
        ErrorAction = "Stop"
    }
    return Get-ADObject @parameters
}

function Set-ScenarioEntityDistinguishedName
{
    param([Parameter(Mandatory)] [object] $Entity)

    if ($WhatIfTraffic)
    {
        if (-not ($Entity.PSObject.Properties.Name -contains "DistinguishedName"))
        {
            Add-Member -InputObject $Entity -MemberType NoteProperty -Name DistinguishedName -Value "CN=$($Entity.Name),DC=whatif,DC=local"
        }
        return [string]$Entity.DistinguishedName
    }

    $adObject = Get-ScenarioAdObject -Entity $Entity
    if ([string]::IsNullOrWhiteSpace([string]$adObject.DistinguishedName))
    {
        throw "Unable to resolve test object GUID $($Entity.Guid) to a distinguished name."
    }
    if ($Entity.PSObject.Properties.Name -contains "DistinguishedName")
    {
        $Entity.DistinguishedName = [string]$adObject.DistinguishedName
    }
    else
    {
        Add-Member -InputObject $Entity -MemberType NoteProperty -Name DistinguishedName -Value ([string]$adObject.DistinguishedName)
    }
    return [string]$adObject.DistinguishedName
}

function Test-ScenarioDnPreflight
{
    $representativeBuckets = @("Recipient", "Group", "Computer")
    foreach ($bucket in $representativeBuckets)
    {
        $targets = @($script:ScenarioTargets[$bucket])
        if ($targets.Count -eq 0)
        {
            throw "ScenarioTest requires a valid $bucket distinguished-name target."
        }
        Test-ScenarioDnTarget -Bucket $bucket -DistinguishedName ([string]$targets[0])
    }

    if ($WhatIfTraffic)
    {
        $syntheticDn = "CN=$ObjectPrefix-DnPreflight,DC=whatif,DC=local"
        Test-ScenarioDnTarget -Bucket "Recipient" -DistinguishedName $syntheticDn
        Write-RunEvent -Level "Information" -Message "ScenarioTest synthetic DN syntax preflight passed." -Data @{
            Attribute = "unauthOrig"
            SyntheticDistinguishedName = $syntheticDn
            BindingPerformed = $false
        }
        return
    }

    $entity = [pscustomobject]@{
        Name = "$ObjectPrefix-dn-preflight"
        Guid = [Guid]::NewGuid()
    }
    $random = [Random]::new([int]([math]::Abs([int64]$RandomSeed) % 2147483647))
    $metadata = Get-ScenarioAttributeMetadata -Name "unauthOrig"
    $value = New-ScenarioTypedValue -Metadata $metadata -Entity $entity -Random $random
    Test-ScenarioDnTarget -Bucket "Recipient" -DistinguishedName ([string]$value)
    Write-RunEvent -Level "Information" -Message "ScenarioTest DN target preflight passed." -Data @{
        Attribute = "unauthOrig"
        GeneratedValue = [string]$value
        RecipientTarget = [string]$script:ScenarioTargets.Recipient[0]
        GroupTarget = [string]$script:ScenarioTargets.Group[0]
        ComputerTarget = [string]$script:ScenarioTargets.Computer[0]
        BindingPerformed = $true
    }
}

function Test-ScenarioCompareRuntimePreflight
{
    if ($WhatIfTraffic)
    {
        Write-RunEvent -Level "Information" -Message "ScenarioTest synthetic comparison runtime preflight passed." -Data @{
            InvocationPerformed = $false
        }
        return
    }

    $targetDn = [string]$script:ScenarioTargets.Recipient[0]
    $target = Get-ADObject -Identity $targetDn -Properties objectGuid -ErrorAction Stop
    $targetGuid = [Guid]$target.ObjectGuid
    $rawOutput = @(Invoke-DirectoryADOSOfflineCompare `
        -ObjectIds ([string]$targetGuid) `
        -PartitionId $script:ForestFqdn `
        -OSDestination $ObjectStoreDestination `
        -Side $Side `
        -SkipUploadingDivergence `
        -ErrorAction Stop)
    if ($rawOutput.Count -eq 0)
    {
        throw "Scenario comparison runtime preflight returned no output for $targetGuid."
    }

    Write-RunEvent -Level "Information" -Message "ScenarioTest comparison runtime preflight passed." -Data @{
        TargetGuid = $targetGuid
        TargetDistinguishedName = $targetDn
        OutputLineCount = $rawOutput.Count
    }
}

function Initialize-ScenarioPreflight
{
    Test-ScenarioSyntheticSyncCookieIndex
    Test-ScenarioResultLimitParameterSelection
    Test-ScenarioSyntheticTargetQueryParameters
    Test-ScenarioSyntheticSchemaMetadata
    Test-ScenarioSyntheticValueBounds
    Test-ScenarioSyntheticSidValue
    Test-ScenarioSyntheticCommandValueShapes
    Initialize-ScenarioTargetPools
    Test-ScenarioSemanticTargets
    Test-ScenarioDnPreflight
    Test-ScenarioCompareRuntimePreflight

    $selectedPhases = @(Get-ScenarioPhaseDefinitions)
    $allNames = @(
        $selectedPhases |
            ForEach-Object { @($_.RecipientProperties) + @($_.LinkProperties) } |
            Select-Object -Unique
    )

    $blockers = [Collections.Generic.List[string]]::new()
    $upsertNames = @(
        $selectedPhases |
            Where-Object { [string]$_.Operation -eq "Upsert" } |
            ForEach-Object { @($_.RecipientProperties) + @($_.LinkProperties) } |
            Select-Object -Unique
    )
    foreach ($name in $upsertNames)
    {
        if (Get-ScenarioUnsupportedUpsertAttribute -Name $name)
        {
            $blockers.Add("${name}: AD owns this operational or identity attribute and rejects direct upsert.")
        }
    }
    foreach ($name in $allNames)
    {
        try
        {
            $metadata = Get-ScenarioAttributeMetadata -Name $name
            if ($metadata.SystemOnly -or $metadata.Constructed -or $metadata.Defunct)
            {
                $blockers.Add("${name}: schema marks the attribute system-only, constructed, or defunct.")
                continue
            }
            $kind = Get-ScenarioGeneratorKind -Metadata $metadata
            if ($kind -eq "Unsupported")
            {
                $blockers.Add("${name}: schema syntax '$($metadata.AttributeSyntax)' has no safe typed generator.")
            }
            elseif ($kind -eq "DN")
            {
                $bucket = Get-ScenarioTargetBucket -Name $name
                if ($script:ScenarioTargets[$bucket].Count -eq 0)
                {
                    $blockers.Add("${name}: no valid $bucket target DN is available.")
                }
            }
            elseif ($kind -eq "MailboxDatabaseLink" -and $script:ScenarioTargets.Database.Count -eq 0)
            {
                $blockers.Add("${name}: no mailbox database target is available.")
            }
            elseif ($kind -eq "Sid" -and $script:ScenarioTargets.Sid.Count -eq 0)
            {
                $blockers.Add("${name}: no valid SID value is available.")
            }
        }
        catch
        {
            $blockers.Add("$name`: $($_.Exception.Message)")
        }
    }

    if ($allNames -match "(?i)Certificate")
    {
        try
        {
            Initialize-ScenarioCertificate
        }
        catch
        {
            $blockers.Add("Certificate-valued attributes: $($_.Exception.Message)")
        }
    }

    $syntheticEntity = [pscustomobject]@{
        Name = "$ObjectPrefix-scenario-preflight"
        Guid = [Guid]::NewGuid()
        Kind = "Contact"
        DistinguishedName = "CN=ScenarioPreflight,DC=whatif,DC=local"
    }
    $random = [Random]::new([int]([math]::Abs([int64]$RandomSeed) % 2147483647))
    foreach ($name in $allNames)
    {
        if ($blockers | Where-Object { $_ -like "$name`:*" })
        {
            continue
        }
        try
        {
            $metadata = Get-ScenarioAttributeMetadata -Name $name
            $objectSid = if ($script:ScenarioTargets.Sid.Count -gt 0) { $script:ScenarioTargets.Sid[0] } else { $null }
            $values = New-ScenarioTypedValues -Metadata $metadata -Entity $syntheticEntity -Random $random -ObjectSid $objectSid
            foreach ($value in @($values))
            {
                if ($null -eq $value)
                {
                    throw "generator returned a null value."
                }
                if ([int64]$metadata.RangeUpper -gt 0 -and $value -is [string] -and $value.Length -gt [int64]$metadata.RangeUpper)
                {
                    throw "generated string exceeds schema rangeUpper $($metadata.RangeUpper)."
                }
                if ($kind -in @("Integer", "LargeInteger") -and
                    [int64]$metadata.RangeLower -ne 0 -and
                    [int64]$value -lt [int64]$metadata.RangeLower)
                {
                    throw "generated integer $value is below schema rangeLower $($metadata.RangeLower)."
                }
                if ($kind -in @("Integer", "LargeInteger") -and
                    [int64]$metadata.RangeUpper -ne 0 -and
                    [int64]$value -gt [int64]$metadata.RangeUpper)
                {
                    throw "generated integer $value exceeds schema rangeUpper $($metadata.RangeUpper)."
                }
            }
        }
        catch
        {
            $blockers.Add("$name`: $($_.Exception.Message)")
        }
    }

    if ($blockers.Count -gt 0)
    {
        $uniqueBlockers = @($blockers | Select-Object -Unique)
        throw "ScenarioTest preflight failed; no scenario traffic was started:`n - $($uniqueBlockers -join "`n - ")"
    }

    $qualificationPath = Join-Path $script:RunDirectory "qualification.json"
    $reuseQualification = $false
    if (-not [string]::IsNullOrWhiteSpace($ResumeRunDirectory))
    {
        $reuseQualification = [bool](Get-ScenarioQualificationStatus -Path $qualificationPath).Passed
    }
    if ($reuseQualification)
    {
        Write-RunEvent -Level "Information" -Message "Reusing the prior zero-defect deterministic qualification for resume." -Data @{
            QualificationPath = $qualificationPath
            PlanVersion = $script:ScenarioPlanVersion
            BatchesPerPhase = $script:ScenarioBatchesPerPhase
            ScenarioCommand = $ScenarioCommand
        }
    }
    else
    {
        Test-ScenarioDeterministicPlanQualification
    }

    Save-ScenarioTargetContext
    Write-RunEvent -Level "Success" -Message "ScenarioTest preflight passed." -Data @{
        ScenarioCommand = $ScenarioCommand
        ScenarioSetMode = $ScenarioSetMode
        ScenarioEstimatedMinutes = Get-ScenarioEstimatedMinutes
        PreflightEstimatedMinutes = $script:ScenarioPreflightEstimatedMinutes
        PopulationEstimatedMinutes = $script:ScenarioPopulationEstimatedMinutes
        EstimatedMinutes = Get-ScenarioTotalEstimatedMinutes
        PhaseCount = @((Get-ScenarioCommandDefinition).PhaseNames).Count
        BatchCount = @((Get-ScenarioCommandDefinition).PhaseNames).Count * $script:ScenarioBatchesPerPhase
        AttributeCount = $allNames.Count
        UserObjects = $script:ScenarioCounts.N_User
        GroupObjects = $script:ScenarioCounts.N_Groups
        RandomSeed = $RandomSeed
    }
}

Initialize-RunDirectory
$runStartedUtc = [datetime]::UtcNow

try
{
    if ($WorkloadMode -eq "ScenarioTest")
    {
        $commandDefinition = Get-ScenarioCommandDefinition
        Write-RunEvent -Level "Information" -Message "Scenario command '$ScenarioCommand' selected." -Data @{
            ScenarioCommand = $ScenarioCommand
            ScenarioSetMode = $ScenarioSetMode
            PhaseNames = @($commandDefinition.PhaseNames)
            ScenarioEstimatedMinutes = Get-ScenarioEstimatedMinutes
            PreflightEstimatedMinutes = $script:ScenarioPreflightEstimatedMinutes
            PopulationEstimatedMinutes = $script:ScenarioPopulationEstimatedMinutes
            EstimatedMinutes = Get-ScenarioTotalEstimatedMinutes
            EstimatedDuration = if ((Get-ScenarioTotalEstimatedMinutes) -ge 60)
            {
                "{0:0.##} hours" -f ((Get-ScenarioTotalEstimatedMinutes) / 60.0)
            }
            else
            {
                "$(Get-ScenarioTotalEstimatedMinutes) minutes"
            }
            BatchCount = @($commandDefinition.PhaseNames).Count * $script:ScenarioBatchesPerPhase
            UserObjects = $script:ScenarioCounts.N_User
            GroupObjects = $script:ScenarioCounts.N_Groups
        }
    }
    Initialize-ExchangeEnvironment
    if ($WorkloadMode -eq "ScenarioTest")
    {
        if (-not [string]::IsNullOrWhiteSpace($ResumeRunDirectory) -and
            -not $ForceFullPreflightOnResume)
        {
            $qualificationPath = Join-Path $script:RunDirectory "qualification.json"
            $qualificationStatus = Get-ScenarioQualificationStatus -Path $qualificationPath
            if (-not $qualificationStatus.Passed)
            {
                throw "ScenarioTest resume cannot skip qualification because $($qualificationStatus.Reason). Run with -ForceFullPreflightOnResume to requalify this command."
            }
            if (-not (Restore-ScenarioTargetContext))
            {
                Initialize-ScenarioTargetPools
                Initialize-ScenarioCertificate
                Save-ScenarioTargetContext
            }
            Write-RunEvent -Level "Information" -Message "Skipped full ScenarioTest preflight and deterministic qualification for resume." -Data @{
                ResumeRunDirectory = $script:RunDirectory
                CurrentPhaseIndex = $script:ScenarioState.NextPhaseIndex
                CurrentBatchIndex = $script:ScenarioState.NextBatchIndex
                CurrentObjectPosition = @($script:ScenarioState.CurrentBatchCompletedGuids).Count
                QualificationFingerprint = [string]$qualificationStatus.Report.QualificationFingerprint
            }
        }
        else
        {
            Initialize-ScenarioPreflight
        }
    }
    if ($PreflightOnly)
    {
        Write-RunEvent -Level "Success" -Message "ScenarioTest preflight-only validation completed; no test objects or traffic were started." -Data @{
            ForestFqdn = $script:ForestFqdn
            RunDirectory = $script:RunDirectory
        }
    }
    else
    {
        if ($WorkloadMode -eq "ScenarioTest" -and
            -not [string]::IsNullOrWhiteSpace($PopulationSourceRunDirectory) -and
            -not $script:PopulationImportCompleted)
        {
            Import-ScenarioPopulation
        }
        if ($WorkloadMode -eq "ScenarioTest" -and
            $null -ne $script:PendingPopulationReplacement)
        {
            Initialize-ScenarioPopulationReplacement
        }
        Initialize-TestPopulation
        if ($WorkloadMode -eq "ScenarioTest")
        {
            Initialize-ScenarioPopulationIdentities
            Test-ScenarioPopulationReplacement
            if (-not $script:StopRequested)
            {
                Complete-ScenarioPopulationReplacement
            }
        }

        if ($script:StopRequested)
        {
            throw "Initial population creation failed."
        }

        if ($WorkloadMode -eq "AttributeCoverage")
        {
            Invoke-AttributeCoverageWorkload
        }
        elseif ($WorkloadMode -eq "ScenarioTest")
        {
            Invoke-ScenarioWorkload
        }
        else
        {
            $trafficStartedUtc = [datetime]::UtcNow
            $runDeadlineUtc = $trafficStartedUtc.AddHours($DurationHours)
            $operationInterval = [TimeSpan]::FromSeconds(1.0 / $OperationsPerSecond)
            $nextOperationUtc = [datetime]::UtcNow

            Write-RunEvent -Level "Success" -Message "Longevity traffic started." -Data @{
                DeadlineUtc = $runDeadlineUtc.ToString("o")
                TrafficStartedUtc = $trafficStartedUtc.ToString("o")
                OperationsPerSecond = $OperationsPerSecond
                RandomSeed = $RandomSeed
                RunDirectory = $script:RunDirectory
            }

            while (-not $script:StopRequested -and [datetime]::UtcNow -lt $runDeadlineUtc)
            {
                Invoke-DueValidations
                if ($script:StopRequested)
                {
                    break
                }

                $now = [datetime]::UtcNow
                if ($now -ge $nextOperationUtc)
                {
                    Invoke-SelectedOperation -Operation (Get-WeightedOperation)
                    $nextOperationUtc = $nextOperationUtc.Add($operationInterval)
                    if ($nextOperationUtc -lt $now.AddSeconds(-1))
                    {
                        $nextOperationUtc = $now.Add($operationInterval)
                    }
                }
                else
                {
                    $sleepMilliseconds = [math]::Min(250, [math]::Max(1, ($nextOperationUtc - $now).TotalMilliseconds))
                    Start-Sleep -Milliseconds ([int]$sleepMilliseconds)
                }

                if (([datetime]::UtcNow - $script:LastCheckpointUtc).TotalSeconds -ge $CheckpointIntervalSeconds)
                {
                    Save-Checkpoint
                }
            }

            if (-not $script:StopRequested)
            {
                Write-RunEvent -Level "Information" -Message "Traffic duration completed; draining pending validations." -Data @{
                    PendingValidationCount = $script:PendingValidations.Count
                }

                $drainDeadlineUtc = [datetime]::UtcNow.AddSeconds($ValidationTimeoutSeconds)
                while (-not $script:StopRequested -and $script:PendingValidations.Count -gt 0 -and [datetime]::UtcNow -lt $drainDeadlineUtc)
                {
                    Invoke-DueValidations
                    Start-Sleep -Seconds 1
                }

                if (-not $script:StopRequested -and $script:PendingValidations.Count -gt 0)
                {
                    Stop-LongevityTraffic -Category "ValidationDrainTimeout" -Message "The run ended with $($script:PendingValidations.Count) validations that did not converge before the drain deadline."
                }
            }
        }

        if (-not $script:StopRequested -and $CleanupOnSuccess)
        {
            Remove-TestPopulation
        }
    }
}
catch
{
    Stop-LongevityTraffic -Category "HarnessFailure" -Message $_.Exception.Message -Exception $_.Exception -Data @{
        ScriptStackTrace = $_.ScriptStackTrace
    }
}
finally
{
    Save-Checkpoint
    $status = if ($script:StopRequested) { "PausedOnFailure" } else { "Passed" }
    Write-RunSummary -StartedUtc $runStartedUtc -FinishedUtc ([datetime]::UtcNow) -Status $status
    Write-RunEvent -Level $(if ($script:StopRequested) { "Error" } else { "Success" }) -Message "Longevity run finished with status $status." -Data @{
        RunDirectory = $script:RunDirectory
        Counters = $script:Counters
    }
}

if ($script:StopRequested)
{
    throw "Directory Object Store longevity traffic paused on failure. See $($script:RunDirectory)."
}
