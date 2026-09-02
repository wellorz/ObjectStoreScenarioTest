# Directory Object Store ScenarioTest

This repository contains the ScenarioTest harness and Copilot skill for
creating isolated Exchange recipients on a TDS machine, mutating recipient and
link properties, and comparing Active Directory with Directory Object Store.

The primary interface is the five `ScenarioCommand` values below. Legacy
`AttributeCoverage` and time-based `Longevity` modes remain available for
advanced use.

Existing run artifacts that stored the former `RunAll` or
`Run-All-Scenarios` command names remain resumable through
`Run-All-OBScenarios`.

## Shared commands

Users can invoke the skill with one of these exact command names:

| Command                     | Scenarios                                                                     | `--miniSet` scenario | `--full` scenario |
| :-------------------------- | :---------------------------------------------------------------------------- | -------------------: | ----------------: |
| `User-Upsert`               | Pure User Recipient Upsert, Pure User Link Upsert, Mixed User Upsert          |            5 minutes |        60 minutes |
| `Group-Upsert`              | Pure Group Recipient Upsert, Pure Group Link Upsert, Mixed Group Upsert       |            5 minutes |        75 minutes |
| `User-Properties-Deletion`  | Pure User Recipient Deletion, Pure User Link Deletion, Mixed User Deletion    |           10 minutes |        80 minutes |
| `Group-Properties-Deletion` | Pure Group Recipient Deletion, Pure Group Link Deletion, Mixed Group Deletion |           10 minutes |        95 minutes |
| `Run-All-OBScenarios`       | All 12 scenarios in canonical order                                           |           30 minutes |       305 minutes |

Mandatory overhead estimates:

- preflight and qualification: measured 7m 21s, estimated 10 minutes on every
  new command run;
- population creation and validation: measured 11m 42s, estimated 15 minutes
  only when no compatible shared population exists.

The total-duration columns combine the scenario set mode with whether an
existing compatible shared population can be reused. `New population` includes
the 15-minute population estimate; these columns do not refer to scenario
batch numbers.

| Command                     | Mini-set, reused population | Mini-set, new population | Full, reused population | Full, new population |
| :-------------------------- | --------------------------: | -----------------------: | ----------------------: | -------------------: |
| `User-Upsert`               |                      15 min |                   30 min |                  70 min |               85 min |
| `Group-Upsert`              |                      15 min |                   30 min |                  85 min |              100 min |
| `User-Properties-Deletion`  |                      20 min |                   35 min |                  90 min |              105 min |
| `Group-Properties-Deletion` |                      20 min |                   35 min |                 105 min |              120 min |
| `Run-All-OBScenarios`       |                      40 min |                   55 min |                 315 min |              330 min |

## Set modes

Every command supports:

- `--full` — four batches per phase; this is the default.
- `--miniSet` — only batch 0 per phase; repetitions 1-3 are skipped.

Examples:

```text
User-Upsert
User-Upsert --full
User-Upsert --miniSet
Run-All-OBScenarios --miniSet
```

| Mode | Subset command | `Run-All-OBScenarios` |
| --- | ---: | ---: |
| `--full` or omitted | 12 batches | 48 batches |
| `--miniSet` | 3 batches | 12 batches |

Full mode uses four batches:

1. Batch 0 mutates one property on every object.
2. Batches 1-3 use deterministic variable-width property selections.
3. Every mutation batch completes before the 15-second sync wait begins.
4. The next batch starts only after every required comparison returns
   `DataSame`.

Deletion commands first prepare missing values for every object, compare all
seeded baselines together, and only then start deletion mutations.

Mini-set mode retains the complete batch-0 mutation barrier, sync wait,
comparison, and aggregated failure behavior. It changes only the number of
batches; it does not weaken batch-0 validation.

## LDAP operations and scenario attribute coverage

All scenario attribute mutations use `Set-ADObject`. Objects are identified by distinguished name when available and by GUID otherwise. Requests are separated by operation/value type and split at the 16-attribute request limit.

| Scenario | Entity | Attributes | Operations |
| --- | --- | ---: | --- |
| Pure User Recipient Upsert | Mail contact | 237 | single `-Replace`; multi `-Add` |
| Pure User Link Upsert | Mail contact | 33 | single `-Replace`; multi `-Add` |
| Pure Group Recipient Upsert | Distribution group | 269 | single `-Replace`; multi `-Add` |
| Pure Group Link Upsert | Distribution group | 46 | single `-Replace`; multi `-Add` |
| Mixed User Upsert | Mail contact | 237 | single `-Replace`; multi `-Add` |
| Mixed Group Upsert | Distribution group | 269 | single `-Replace`; multi `-Add` |
| Pure User Recipient Deletion | Mail contact | 233 | single `-Clear`; multi `-Remove` or `-Clear` |
| Pure User Link Deletion | Mail contact | 33 | single `-Clear`; multi `-Remove` or `-Clear` |
| Pure Group Recipient Deletion | Distribution group | 263 | single `-Clear`; multi `-Remove` or `-Clear` |
| Pure Group Link Deletion | Distribution group | 44 | single `-Clear`; multi `-Remove` or `-Clear` |
| Mixed User Deletion | Mail contact | 233 | single `-Clear`; multi `-Remove` or `-Clear` |
| Mixed Group Deletion | Distribution group | 263 | single `-Clear`; multi `-Remove` or `-Clear` |

Deletion first seeds absent selected attributes using the corresponding upsert operation, waits for synchronization, and requires `DataSame`. `msExchCU` and `msExchOURoot` are excluded from deletion. Multivalued `proxyAddresses` is protected and uses value-level `-Remove`, retaining at least one value. Group `description` is intentionally treated as single-valued and uses `-Replace`/`-Clear`.

<details>
<summary>Pure User Recipient Upsert — 237 LDAP attributes</summary>

Entity: **Mail contact**

#### Set-ADObject -Replace (182)

```text
adminDisplayName
altRecipient
c
co
company
CountryCode
delivContLength
deliverAndRedirect
department
displayName
displayNamePrintable
extensionAttribute1
extensionAttribute10
extensionAttribute11
extensionAttribute12
extensionAttribute13
extensionAttribute14
extensionAttribute15
extensionAttribute2
extensionAttribute3
extensionAttribute4
extensionAttribute5
extensionAttribute6
extensionAttribute7
extensionAttribute8
extensionAttribute9
facsimileTelephoneNumber
garbageCollPeriod
givenName
heuristics
homeMTA
homePhone
info
initials
internetEncoding
l
legacyExchangeDN
mail
mailNickname
manager
mAPIRecipient
mobile
msDS-GeoCoordinatesAltitude
msDS-GeoCoordinatesLatitude
msDS-GeoCoordinatesLongitude
msDS-HABSeniorityIndex
msDS-PhoneticDisplayName
msExchAddressBookFlags
msExchArbitrationMailbox
msExchArchiveRelease
msExchAssistantName
msExchAuditAdmin
msExchAuditDelegate
msExchAuditDelegateAdmin
msExchAuditOwner
msExchAuthPolicyLink
msExchBlockedSendersHash
msExchBypassAudit
msExchCalculatedTargetAddress
msExchCalendarRepairDisabled
msExchConfigurationXML
msExchCorrelationId
msExchCU
msExchDelegateIRMBlockList
msExchDirsyncID
msExchELCMailboxFlags
msExchEnableModeration
msExchEnforcedTimestamps
msExchEwsApplicationAccessPolicy
msExchEwsEnabled
msExchExpansionServerName
msExchExtensionAttribute16
msExchExtensionAttribute17
msExchExtensionAttribute18
msExchExtensionAttribute40
msExchExtensionAttribute41
msExchExtensionAttribute45
msExchExternalDirectoryObjectId
msExchFBURL
msExchForeignGroupSid
msExchGenericForwardingAddress
msExchGroupExternalMemberCount
msExchGroupMemberCount
msExchGroupSecurityFlags
msExchHideFromAddressLists
msExchImmutableId
msExchIntendedMailboxPlanLink
msExchIsMSODirsynced
msExchJoinedProxyAddress
msExchLastExchangeChangedTime
msExchLitigationHoldDate
msExchLitigationHoldOwner
msExchLocalizationFlags
msExchMailboxAuditEnable
msExchMailboxAuditLastAdminAccess
msExchMailboxAuditLastDelegateAccess
msExchMailboxAuditLastExternalAccess
msExchMailboxAuditLogAgeLimit
msExchMailboxFolderSet
msExchMailboxMoveBatchName
msExchMailboxMoveFlags
msExchMailboxMoveRemoteHostName
msExchMailboxMoveSourceArchiveMDBLink
msExchMailboxMoveSourceMDBLink
msExchMailboxMoveStatus
msExchMailboxMoveTargetArchiveMDBLink
msExchMailboxMoveTargetMDBLink
msExchMailboxPlanType
msExchMailboxRelease
msExchMailboxSecurityDescriptor
nTSecurityDescriptor
msExchMasterAccountSid
msExchMessageHygieneFlags
msExchMessageHygieneSCLDeleteThreshold
msExchMessageHygieneSCLJunkThreshold
msExchMessageHygieneSCLQuarantineThreshold
msExchMessageHygieneSCLRejectThreshold
msExchModerationFlags
msExchObjectID
msExchOnPremiseObjectGuid
msExchOrganizationUpgradeRequest
msExchOrganizationUpgradeStatus
msExchOURoot
msExchOWAPolicy
msExchParentPlanLink
msExchPartnerGroupID
msExchPreviousRecipientTypeDetails
msExchProvisioningFlags
msExchPublicFolderMailbox
msExchRBACPolicyLink
msExchRecipientDisplayType
msExchRecipientSoftDeletedStatus
msExchRecipientTypeDetails
msExchRecipLimit
msExchRemoteRecipientType
msExchReplicableChangeVersion
msExchRequireAuthToSendTo
msExchResourceCapacity
msExchResourceDisplay
msExchRetentionComment
msExchRetentionURL
msExchRoleGroupType
msExchSafeRecipientsHash
msExchSafeSendersHash
msExchSharedDomainLastModified
msExchSharedDomainTenant
msExchSharedWithReference
msExchSharedWithTargetProxyAddress
msExchSharingPolicyLink
msExchStsRefreshTokensValidFrom
msExchSyncAccountsPolicyDN
msExchThrottlingPolicyDN
msExchTransportRecipientSettingsFlags
msExchUMListInDirectorySearch
msExchUMRecipientDialPlanLink
msExchUMSpokenName
msExchUserAccountControl
msExchUserCulture
msExchVersion
msExchWellKnownObject
msExchWhenIBSegmentChanged
msExchWhenMailboxCreated
msExchWhenMailboxWorkloadsModified
msExchWhenPropChangeLastSubmitted
msExchWhenReplicablePropLastChanged
msExchWhenSoftDeletedTime
msExchWindowsLiveID
pager
physicalDeliveryOfficeName
postalCode
ReplicationSignature
sn
st
streetAddress
submissionContLength
targetAddress
telephoneAssistant
telephoneNumber
textEncodedORAddress
thumbnailPhoto
title
wWWHomePage
```

#### Set-ADObject -Add (55)

```text
authOrig
description
dLMemRejectPerms
dLMemSubmitPerms
msExchAdministrativeUnitLink
msExchBypassModerationFromDLMembersLink
msExchBypassModerationLink
msExchCapabilityIdentifiers
msExchDirsyncAuthorityMetadata
msExchEwsExceptions
msExchEwsWellKnownApplicationPolicies
msExchExtensionCustomAttribute1
msExchExtensionCustomAttribute2
msExchExtensionCustomAttribute3
msExchExtensionCustomAttribute4
msExchExtensionCustomAttribute5
msExchInformationBarrierSegmentLink
msExchLabeledURI
msExchModeratedByLink
msExchMultiMailboxDatabasesLink
msExchMultiMailboxGUIDs
msExchMultiMailboxLocationsLink
msExchNonCompliantDeviceLink
msExchNonCompliantDevices
msExchPoliciesExcluded
msExchPoliciesIncluded
msExchResourceBehaviorOptions
msExchResourceMetaData
msExchResourceProvisioningOptions
msExchResourceSearchProperties
msExchRMSComputerAccountsLink
msExchSenderHintTranslations
msExchSharingAnonymousIdentities
msExchSharingPartnerIdentities
msExchSIDHistory
msExchSupervisionDLLink
msExchSupervisionOneOffLink
msExchSupervisionUserLink
msExchTextMessagingState
msExchUCVoiceMailSettings
msExchUMCallingLineIds
msExchUMDtmfMap
msExchUserHoldPolicies
otherFacsimileTelephoneNumber
otherHomePhone
otherTelephone
postOfficeBox
protocolSettings
proxyAddresses
publicDelegates
securityProtocol
showInAddressBook
unauthOrig
userCertificate
userSMIMECertificate
```

</details>

<details>
<summary>Pure User Link Upsert — 33 LDAP attributes</summary>

Entity: **Mail contact**

#### Set-ADObject -Replace (16)

```text
altRecipient
mailNickname
manager
msExchArbitrationMailbox
msExchAuthPolicyLink
msExchIntendedMailboxPlanLink
msExchOWAPolicy
msExchParentPlanLink
msExchPublicFolderMailbox
msExchRBACPolicyLink
msExchRecipientSoftDeletedStatus
msExchRecipientTypeDetails
msExchSharingPolicyLink
msExchSyncAccountsPolicyDN
msExchThrottlingPolicyDN
msExchUMRecipientDialPlanLink
```

#### Set-ADObject -Add (17)

```text
authOrig
dLMemRejectPerms
dLMemSubmitPerms
msExchAdministrativeUnitLink
msExchBypassModerationFromDLMembersLink
msExchBypassModerationLink
msExchInformationBarrierSegmentLink
msExchModeratedByLink
msExchNonCompliantDeviceLink
msExchRMSComputerAccountsLink
msExchSIDHistory
msExchSupervisionDLLink
msExchSupervisionOneOffLink
msExchSupervisionUserLink
publicDelegates
showInAddressBook
unauthOrig
```

</details>

<details>
<summary>Pure Group Recipient Upsert — 269 LDAP attributes</summary>

Entity: **Distribution group**

#### Set-ADObject -Replace (210)

```text
adminDisplayName
altRecipient
company
deletedItemFlags
delivContLength
deliverAndRedirect
department
description
displayName
displayNamePrintable
extensionAttribute1
extensionAttribute10
extensionAttribute11
extensionAttribute12
extensionAttribute13
extensionAttribute14
extensionAttribute15
extensionAttribute2
extensionAttribute3
extensionAttribute4
extensionAttribute5
extensionAttribute6
extensionAttribute7
extensionAttribute8
extensionAttribute9
garbageCollPeriod
groupType
heuristics
hideDLMembership
homeMDB
homeMTA
info
internetEncoding
legacyExchangeDN
mail
mailNickname
managedBy
mAPIRecipient
mDBUseDefaults
msDS-GeoCoordinatesAltitude
msDS-GeoCoordinatesLatitude
msDS-GeoCoordinatesLongitude
msDS-HABSeniorityIndex
msDS-PhoneticDisplayName
msExchAddressBookFlags
msExchAddressBookPolicyLink
msExchArbitrationMailbox
msExchArchiveAddress
msExchArchiveDatabaseLink
msExchArchiveGUID
msExchArchiveQuota
msExchArchiveRelease
msExchArchiveStatus
msExchArchiveWarnQuota
msExchAssistantName
msExchAuditAdmin
msExchAuditDelegate
msExchAuditDelegateAdmin
msExchAuditOwner
msExchAuthPolicyLink
msExchBlockedSendersHash
msExchBypassAudit
msExchCalculatedTargetAddress
msExchCalendarLoggingQuota
msExchCalendarRepairDisabled
msExchConfigurationXML
msExchCorrelationId
msExchCU
msExchDataEncryptionPolicyLink
msExchDelegateIRMBlockList
msExchDirsyncID
msExchDisabledArchiveDatabaseLink
msExchDisabledArchiveGUID
msExchDumpsterQuota
msExchDumpsterWarningQuota
msExchELCExpirySuspensionEnd
msExchELCExpirySuspensionStart
msExchELCMailboxFlags
msExchEnableModeration
msExchEnforcedTimestamps
msExchEwsApplicationAccessPolicy
msExchEwsEnabled
msExchExpansionServerName
msExchExtensionAttribute16
msExchExtensionAttribute17
msExchExtensionAttribute18
msExchExtensionAttribute40
msExchExtensionAttribute41
msExchExtensionAttribute45
msExchExternalDirectoryObjectId
msExchExternalOOFOptions
msExchFBURL
msExchForeignGroupSid
msExchGenericForwardingAddress
msExchGroupDepartRestriction
msExchGroupExternalMemberCount
msExchGroupJoinRestriction
msExchGroupMemberCount
msExchGroupSecurityFlags
msExchHideFromAddressLists
msExchHomeServerName
msExchImmutableId
msExchIntendedMailboxPlanLink
msExchIsMSODirsynced
msExchJoinedProxyAddress
msExchLastExchangeChangedTime
msExchLitigationHoldDate
msExchLitigationHoldOwner
msExchLocalizationFlags
msExchMailboxAuditEnable
msExchMailboxAuditLastAdminAccess
msExchMailboxAuditLastDelegateAccess
msExchMailboxAuditLastExternalAccess
msExchMailboxAuditLogAgeLimit
msExchMailboxContainerGuid
msExchMailboxFolderSet
msExchMailboxGuid
msExchMailboxMoveBatchName
msExchMailboxMoveFlags
msExchMailboxMoveRemoteHostName
msExchMailboxMoveSourceArchiveMDBLink
msExchMailboxMoveSourceMDBLink
msExchMailboxMoveStatus
msExchMailboxMoveTargetArchiveMDBLink
msExchMailboxMoveTargetMDBLink
msExchMailboxPlanType
msExchMailboxRelease
msExchMailboxSecurityDescriptor
nTSecurityDescriptor
msExchMailboxTemplateLink
msExchMasterAccountSid
msExchMaxBlockedSenders
msExchMaxSafeSenders
msExchMDBRulesQuota
msExchMessageHygieneFlags
msExchMessageHygieneSCLDeleteThreshold
msExchMessageHygieneSCLJunkThreshold
msExchMessageHygieneSCLQuarantineThreshold
msExchMessageHygieneSCLRejectThreshold
msExchMobileMailboxFlags
msExchMobileMailboxPolicyLink
msExchModerationFlags
msExchObjectID
msExchOnPremiseObjectGuid
msExchOrganizationUpgradeRequest
msExchOrganizationUpgradeStatus
msExchOURoot
msExchOWAPolicy
msExchParentPlanLink
msExchPartnerGroupID
msExchPreviousHomeMDB
msExchPreviousMailboxGuid
msExchPreviousRecipientTypeDetails
msExchProvisioningFlags
msExchPublicFolderMailbox
msExchRBACPolicyLink
msExchRecipientDisplayType
msExchRecipientSoftDeletedStatus
msExchRecipientTypeDetails
msExchRecipLimit
msExchRemoteRecipientType
msExchReplicableChangeVersion
msExchRequireAuthToSendTo
msExchResourceCapacity
msExchResourceDisplay
msExchRetentionComment
msExchRetentionURL
msExchRoleGroupType
msExchSafeRecipientsHash
msExchSafeSendersHash
msExchSharedDomainLastModified
msExchSharedDomainTenant
msExchSharedWithReference
msExchSharedWithTargetProxyAddress
msExchSharingPolicyLink
msExchStsRefreshTokensValidFrom
msExchSyncAccountsPolicyDN
msExchTeamMailboxExpiration
msExchTeamMailboxSharePointUrl
msExchThrottlingPolicyDN
msExchTransportRecipientSettingsFlags
msExchUMListInDirectorySearch
msExchUMRecipientDialPlanLink
msExchUMSpokenName
msExchUMTemplateLink
msExchUnifiedMailbox
msExchUseOAB
msExchUserAccountControl
msExchUserCulture
msExchVersion
msExchWellKnownObject
msExchWhenIBSegmentChanged
msExchWhenMailboxCreated
msExchWhenMailboxWorkloadsModified
msExchWhenPropChangeLastSubmitted
msExchWhenReplicablePropLastChanged
msExchWhenSoftDeletedTime
msExchWindowsLiveID
msOrg-IsOrganizational
oOFReplyToOriginator
ReplicationSignature
reportToOriginator
reportToOwner
SamAccountName
submissionContLength
targetAddress
telephoneNumber
textEncodedORAddress
thumbnailPhoto
wWWHomePage
```

#### Set-ADObject -Add (59)

```text
AltSecurityIdentities
authOrig
dLMemRejectPerms
dLMemSubmitPerms
msExchAdministrativeUnitLink
msExchAlternateMailboxes
msExchApprovalApplicationLink
msExchArchiveName
msExchBypassModerationFromDLMembersLink
msExchBypassModerationLink
msExchCapabilityIdentifiers
msExchCoManagedByLink
msExchDelegateListLink
msExchDirsyncAuthorityMetadata
msExchEwsExceptions
msExchEwsWellKnownApplicationPolicies
msExchExtensionCustomAttribute1
msExchExtensionCustomAttribute2
msExchExtensionCustomAttribute3
msExchExtensionCustomAttribute4
msExchExtensionCustomAttribute5
msExchInformationBarrierSegmentLink
msExchLabeledURI
msExchMobileAllowedDeviceIds
msExchMobileBlockedDeviceIds
msExchModeratedByLink
msExchMultiMailboxDatabasesLink
msExchMultiMailboxGUIDs
msExchMultiMailboxLocationsLink
msExchNonCompliantDeviceLink
msExchNonCompliantDevices
msExchPoliciesExcluded
msExchPoliciesIncluded
msExchResourceBehaviorOptions
msExchResourceMetaData
msExchResourceProvisioningOptions
msExchResourceSearchProperties
msExchRMSComputerAccountsLink
msExchSenderHintTranslations
msExchSharingAnonymousIdentities
msExchSharingPartnerIdentities
msExchSIDHistory
msExchSupervisionDLLink
msExchSupervisionOneOffLink
msExchSupervisionUserLink
msExchTeamMailboxOwners
msExchTextMessagingState
msExchUCVoiceMailSettings
msExchUMCallingLineIds
msExchUMDtmfMap
msExchUserHoldPolicies
protocolSettings
proxyAddresses
publicDelegates
securityProtocol
showInAddressBook
unauthOrig
userCertificate
userSMIMECertificate
```

</details>

<details>
<summary>Pure Group Link Upsert — 46 LDAP attributes</summary>

Entity: **Distribution group**

#### Set-ADObject -Replace (24)

```text
altRecipient
groupType
mailNickname
managedBy
msExchAddressBookPolicyLink
msExchArbitrationMailbox
msExchAuthPolicyLink
msExchDataEncryptionPolicyLink
msExchHomeServerName
msExchIntendedMailboxPlanLink
msExchMailboxTemplateLink
msExchMobileMailboxPolicyLink
msExchOWAPolicy
msExchParentPlanLink
msExchPublicFolderMailbox
msExchRBACPolicyLink
msExchRecipientSoftDeletedStatus
msExchRecipientTypeDetails
msExchSharingPolicyLink
msExchSyncAccountsPolicyDN
msExchThrottlingPolicyDN
msExchUMRecipientDialPlanLink
msExchUMTemplateLink
msExchUseOAB
```

#### Set-ADObject -Add (22)

```text
authOrig
dLMemRejectPerms
dLMemSubmitPerms
member
msExchAdministrativeUnitLink
msExchApprovalApplicationLink
msExchBypassModerationFromDLMembersLink
msExchBypassModerationLink
msExchCoManagedByLink
msExchDelegateListLink
msExchInformationBarrierSegmentLink
msExchModeratedByLink
msExchNonCompliantDeviceLink
msExchRMSComputerAccountsLink
msExchSIDHistory
msExchSupervisionDLLink
msExchSupervisionOneOffLink
msExchSupervisionUserLink
msExchTeamMailboxOwners
publicDelegates
showInAddressBook
unauthOrig
```

</details>

<details>
<summary>Mixed User Upsert — 237 LDAP attributes</summary>

Entity: **Mail contact**

#### Set-ADObject -Replace (182)

```text
adminDisplayName
altRecipient
c
co
company
CountryCode
delivContLength
deliverAndRedirect
department
displayName
displayNamePrintable
extensionAttribute1
extensionAttribute10
extensionAttribute11
extensionAttribute12
extensionAttribute13
extensionAttribute14
extensionAttribute15
extensionAttribute2
extensionAttribute3
extensionAttribute4
extensionAttribute5
extensionAttribute6
extensionAttribute7
extensionAttribute8
extensionAttribute9
facsimileTelephoneNumber
garbageCollPeriod
givenName
heuristics
homeMTA
homePhone
info
initials
internetEncoding
l
legacyExchangeDN
mail
mailNickname
manager
mAPIRecipient
mobile
msDS-GeoCoordinatesAltitude
msDS-GeoCoordinatesLatitude
msDS-GeoCoordinatesLongitude
msDS-HABSeniorityIndex
msDS-PhoneticDisplayName
msExchAddressBookFlags
msExchArbitrationMailbox
msExchArchiveRelease
msExchAssistantName
msExchAuditAdmin
msExchAuditDelegate
msExchAuditDelegateAdmin
msExchAuditOwner
msExchAuthPolicyLink
msExchBlockedSendersHash
msExchBypassAudit
msExchCalculatedTargetAddress
msExchCalendarRepairDisabled
msExchConfigurationXML
msExchCorrelationId
msExchCU
msExchDelegateIRMBlockList
msExchDirsyncID
msExchELCMailboxFlags
msExchEnableModeration
msExchEnforcedTimestamps
msExchEwsApplicationAccessPolicy
msExchEwsEnabled
msExchExpansionServerName
msExchExtensionAttribute16
msExchExtensionAttribute17
msExchExtensionAttribute18
msExchExtensionAttribute40
msExchExtensionAttribute41
msExchExtensionAttribute45
msExchExternalDirectoryObjectId
msExchFBURL
msExchForeignGroupSid
msExchGenericForwardingAddress
msExchGroupExternalMemberCount
msExchGroupMemberCount
msExchGroupSecurityFlags
msExchHideFromAddressLists
msExchImmutableId
msExchIntendedMailboxPlanLink
msExchIsMSODirsynced
msExchJoinedProxyAddress
msExchLastExchangeChangedTime
msExchLitigationHoldDate
msExchLitigationHoldOwner
msExchLocalizationFlags
msExchMailboxAuditEnable
msExchMailboxAuditLastAdminAccess
msExchMailboxAuditLastDelegateAccess
msExchMailboxAuditLastExternalAccess
msExchMailboxAuditLogAgeLimit
msExchMailboxFolderSet
msExchMailboxMoveBatchName
msExchMailboxMoveFlags
msExchMailboxMoveRemoteHostName
msExchMailboxMoveSourceArchiveMDBLink
msExchMailboxMoveSourceMDBLink
msExchMailboxMoveStatus
msExchMailboxMoveTargetArchiveMDBLink
msExchMailboxMoveTargetMDBLink
msExchMailboxPlanType
msExchMailboxRelease
msExchMailboxSecurityDescriptor
nTSecurityDescriptor
msExchMasterAccountSid
msExchMessageHygieneFlags
msExchMessageHygieneSCLDeleteThreshold
msExchMessageHygieneSCLJunkThreshold
msExchMessageHygieneSCLQuarantineThreshold
msExchMessageHygieneSCLRejectThreshold
msExchModerationFlags
msExchObjectID
msExchOnPremiseObjectGuid
msExchOrganizationUpgradeRequest
msExchOrganizationUpgradeStatus
msExchOURoot
msExchOWAPolicy
msExchParentPlanLink
msExchPartnerGroupID
msExchPreviousRecipientTypeDetails
msExchProvisioningFlags
msExchPublicFolderMailbox
msExchRBACPolicyLink
msExchRecipientDisplayType
msExchRecipientSoftDeletedStatus
msExchRecipientTypeDetails
msExchRecipLimit
msExchRemoteRecipientType
msExchReplicableChangeVersion
msExchRequireAuthToSendTo
msExchResourceCapacity
msExchResourceDisplay
msExchRetentionComment
msExchRetentionURL
msExchRoleGroupType
msExchSafeRecipientsHash
msExchSafeSendersHash
msExchSharedDomainLastModified
msExchSharedDomainTenant
msExchSharedWithReference
msExchSharedWithTargetProxyAddress
msExchSharingPolicyLink
msExchStsRefreshTokensValidFrom
msExchSyncAccountsPolicyDN
msExchThrottlingPolicyDN
msExchTransportRecipientSettingsFlags
msExchUMListInDirectorySearch
msExchUMRecipientDialPlanLink
msExchUMSpokenName
msExchUserAccountControl
msExchUserCulture
msExchVersion
msExchWellKnownObject
msExchWhenIBSegmentChanged
msExchWhenMailboxCreated
msExchWhenMailboxWorkloadsModified
msExchWhenPropChangeLastSubmitted
msExchWhenReplicablePropLastChanged
msExchWhenSoftDeletedTime
msExchWindowsLiveID
pager
physicalDeliveryOfficeName
postalCode
ReplicationSignature
sn
st
streetAddress
submissionContLength
targetAddress
telephoneAssistant
telephoneNumber
textEncodedORAddress
thumbnailPhoto
title
wWWHomePage
```

#### Set-ADObject -Add (55)

```text
authOrig
description
dLMemRejectPerms
dLMemSubmitPerms
msExchAdministrativeUnitLink
msExchBypassModerationFromDLMembersLink
msExchBypassModerationLink
msExchCapabilityIdentifiers
msExchDirsyncAuthorityMetadata
msExchEwsExceptions
msExchEwsWellKnownApplicationPolicies
msExchExtensionCustomAttribute1
msExchExtensionCustomAttribute2
msExchExtensionCustomAttribute3
msExchExtensionCustomAttribute4
msExchExtensionCustomAttribute5
msExchInformationBarrierSegmentLink
msExchLabeledURI
msExchModeratedByLink
msExchMultiMailboxDatabasesLink
msExchMultiMailboxGUIDs
msExchMultiMailboxLocationsLink
msExchNonCompliantDeviceLink
msExchNonCompliantDevices
msExchPoliciesExcluded
msExchPoliciesIncluded
msExchResourceBehaviorOptions
msExchResourceMetaData
msExchResourceProvisioningOptions
msExchResourceSearchProperties
msExchRMSComputerAccountsLink
msExchSenderHintTranslations
msExchSharingAnonymousIdentities
msExchSharingPartnerIdentities
msExchSIDHistory
msExchSupervisionDLLink
msExchSupervisionOneOffLink
msExchSupervisionUserLink
msExchTextMessagingState
msExchUCVoiceMailSettings
msExchUMCallingLineIds
msExchUMDtmfMap
msExchUserHoldPolicies
otherFacsimileTelephoneNumber
otherHomePhone
otherTelephone
postOfficeBox
protocolSettings
proxyAddresses
publicDelegates
securityProtocol
showInAddressBook
unauthOrig
userCertificate
userSMIMECertificate
```

</details>

<details>
<summary>Mixed Group Upsert — 269 LDAP attributes</summary>

Entity: **Distribution group**

#### Set-ADObject -Replace (210)

```text
adminDisplayName
altRecipient
company
deletedItemFlags
delivContLength
deliverAndRedirect
department
description
displayName
displayNamePrintable
extensionAttribute1
extensionAttribute10
extensionAttribute11
extensionAttribute12
extensionAttribute13
extensionAttribute14
extensionAttribute15
extensionAttribute2
extensionAttribute3
extensionAttribute4
extensionAttribute5
extensionAttribute6
extensionAttribute7
extensionAttribute8
extensionAttribute9
garbageCollPeriod
groupType
heuristics
hideDLMembership
homeMDB
homeMTA
info
internetEncoding
legacyExchangeDN
mail
mailNickname
managedBy
mAPIRecipient
mDBUseDefaults
msDS-GeoCoordinatesAltitude
msDS-GeoCoordinatesLatitude
msDS-GeoCoordinatesLongitude
msDS-HABSeniorityIndex
msDS-PhoneticDisplayName
msExchAddressBookFlags
msExchAddressBookPolicyLink
msExchArbitrationMailbox
msExchArchiveAddress
msExchArchiveDatabaseLink
msExchArchiveGUID
msExchArchiveQuota
msExchArchiveRelease
msExchArchiveStatus
msExchArchiveWarnQuota
msExchAssistantName
msExchAuditAdmin
msExchAuditDelegate
msExchAuditDelegateAdmin
msExchAuditOwner
msExchAuthPolicyLink
msExchBlockedSendersHash
msExchBypassAudit
msExchCalculatedTargetAddress
msExchCalendarLoggingQuota
msExchCalendarRepairDisabled
msExchConfigurationXML
msExchCorrelationId
msExchCU
msExchDataEncryptionPolicyLink
msExchDelegateIRMBlockList
msExchDirsyncID
msExchDisabledArchiveDatabaseLink
msExchDisabledArchiveGUID
msExchDumpsterQuota
msExchDumpsterWarningQuota
msExchELCExpirySuspensionEnd
msExchELCExpirySuspensionStart
msExchELCMailboxFlags
msExchEnableModeration
msExchEnforcedTimestamps
msExchEwsApplicationAccessPolicy
msExchEwsEnabled
msExchExpansionServerName
msExchExtensionAttribute16
msExchExtensionAttribute17
msExchExtensionAttribute18
msExchExtensionAttribute40
msExchExtensionAttribute41
msExchExtensionAttribute45
msExchExternalDirectoryObjectId
msExchExternalOOFOptions
msExchFBURL
msExchForeignGroupSid
msExchGenericForwardingAddress
msExchGroupDepartRestriction
msExchGroupExternalMemberCount
msExchGroupJoinRestriction
msExchGroupMemberCount
msExchGroupSecurityFlags
msExchHideFromAddressLists
msExchHomeServerName
msExchImmutableId
msExchIntendedMailboxPlanLink
msExchIsMSODirsynced
msExchJoinedProxyAddress
msExchLastExchangeChangedTime
msExchLitigationHoldDate
msExchLitigationHoldOwner
msExchLocalizationFlags
msExchMailboxAuditEnable
msExchMailboxAuditLastAdminAccess
msExchMailboxAuditLastDelegateAccess
msExchMailboxAuditLastExternalAccess
msExchMailboxAuditLogAgeLimit
msExchMailboxContainerGuid
msExchMailboxFolderSet
msExchMailboxGuid
msExchMailboxMoveBatchName
msExchMailboxMoveFlags
msExchMailboxMoveRemoteHostName
msExchMailboxMoveSourceArchiveMDBLink
msExchMailboxMoveSourceMDBLink
msExchMailboxMoveStatus
msExchMailboxMoveTargetArchiveMDBLink
msExchMailboxMoveTargetMDBLink
msExchMailboxPlanType
msExchMailboxRelease
msExchMailboxSecurityDescriptor
nTSecurityDescriptor
msExchMailboxTemplateLink
msExchMasterAccountSid
msExchMaxBlockedSenders
msExchMaxSafeSenders
msExchMDBRulesQuota
msExchMessageHygieneFlags
msExchMessageHygieneSCLDeleteThreshold
msExchMessageHygieneSCLJunkThreshold
msExchMessageHygieneSCLQuarantineThreshold
msExchMessageHygieneSCLRejectThreshold
msExchMobileMailboxFlags
msExchMobileMailboxPolicyLink
msExchModerationFlags
msExchObjectID
msExchOnPremiseObjectGuid
msExchOrganizationUpgradeRequest
msExchOrganizationUpgradeStatus
msExchOURoot
msExchOWAPolicy
msExchParentPlanLink
msExchPartnerGroupID
msExchPreviousHomeMDB
msExchPreviousMailboxGuid
msExchPreviousRecipientTypeDetails
msExchProvisioningFlags
msExchPublicFolderMailbox
msExchRBACPolicyLink
msExchRecipientDisplayType
msExchRecipientSoftDeletedStatus
msExchRecipientTypeDetails
msExchRecipLimit
msExchRemoteRecipientType
msExchReplicableChangeVersion
msExchRequireAuthToSendTo
msExchResourceCapacity
msExchResourceDisplay
msExchRetentionComment
msExchRetentionURL
msExchRoleGroupType
msExchSafeRecipientsHash
msExchSafeSendersHash
msExchSharedDomainLastModified
msExchSharedDomainTenant
msExchSharedWithReference
msExchSharedWithTargetProxyAddress
msExchSharingPolicyLink
msExchStsRefreshTokensValidFrom
msExchSyncAccountsPolicyDN
msExchTeamMailboxExpiration
msExchTeamMailboxSharePointUrl
msExchThrottlingPolicyDN
msExchTransportRecipientSettingsFlags
msExchUMListInDirectorySearch
msExchUMRecipientDialPlanLink
msExchUMSpokenName
msExchUMTemplateLink
msExchUnifiedMailbox
msExchUseOAB
msExchUserAccountControl
msExchUserCulture
msExchVersion
msExchWellKnownObject
msExchWhenIBSegmentChanged
msExchWhenMailboxCreated
msExchWhenMailboxWorkloadsModified
msExchWhenPropChangeLastSubmitted
msExchWhenReplicablePropLastChanged
msExchWhenSoftDeletedTime
msExchWindowsLiveID
msOrg-IsOrganizational
oOFReplyToOriginator
ReplicationSignature
reportToOriginator
reportToOwner
SamAccountName
submissionContLength
targetAddress
telephoneNumber
textEncodedORAddress
thumbnailPhoto
wWWHomePage
```

#### Set-ADObject -Add (60)

```text
AltSecurityIdentities
authOrig
dLMemRejectPerms
dLMemSubmitPerms
member
msExchAdministrativeUnitLink
msExchAlternateMailboxes
msExchApprovalApplicationLink
msExchArchiveName
msExchBypassModerationFromDLMembersLink
msExchBypassModerationLink
msExchCapabilityIdentifiers
msExchCoManagedByLink
msExchDelegateListLink
msExchDirsyncAuthorityMetadata
msExchEwsExceptions
msExchEwsWellKnownApplicationPolicies
msExchExtensionCustomAttribute1
msExchExtensionCustomAttribute2
msExchExtensionCustomAttribute3
msExchExtensionCustomAttribute4
msExchExtensionCustomAttribute5
msExchInformationBarrierSegmentLink
msExchLabeledURI
msExchMobileAllowedDeviceIds
msExchMobileBlockedDeviceIds
msExchModeratedByLink
msExchMultiMailboxDatabasesLink
msExchMultiMailboxGUIDs
msExchMultiMailboxLocationsLink
msExchNonCompliantDeviceLink
msExchNonCompliantDevices
msExchPoliciesExcluded
msExchPoliciesIncluded
msExchResourceBehaviorOptions
msExchResourceMetaData
msExchResourceProvisioningOptions
msExchResourceSearchProperties
msExchRMSComputerAccountsLink
msExchSenderHintTranslations
msExchSharingAnonymousIdentities
msExchSharingPartnerIdentities
msExchSIDHistory
msExchSupervisionDLLink
msExchSupervisionOneOffLink
msExchSupervisionUserLink
msExchTeamMailboxOwners
msExchTextMessagingState
msExchUCVoiceMailSettings
msExchUMCallingLineIds
msExchUMDtmfMap
msExchUserHoldPolicies
protocolSettings
proxyAddresses
publicDelegates
securityProtocol
showInAddressBook
unauthOrig
userCertificate
userSMIMECertificate
```

</details>

<details>
<summary>Pure User Recipient Deletion — 233 LDAP attributes</summary>

Entity: **Mail contact**

#### Set-ADObject -Clear (178)

```text
adminDisplayName
altRecipient
c
co
company
CountryCode
delivContLength
deliverAndRedirect
department
displayName
displayNamePrintable
extensionAttribute1
extensionAttribute10
extensionAttribute11
extensionAttribute12
extensionAttribute13
extensionAttribute14
extensionAttribute15
extensionAttribute2
extensionAttribute3
extensionAttribute4
extensionAttribute5
extensionAttribute6
extensionAttribute7
extensionAttribute8
extensionAttribute9
facsimileTelephoneNumber
garbageCollPeriod
givenName
heuristics
homeMTA
homePhone
info
initials
internetEncoding
l
legacyExchangeDN
mail
mailNickname
manager
mAPIRecipient
mobile
msDS-GeoCoordinatesAltitude
msDS-GeoCoordinatesLatitude
msDS-GeoCoordinatesLongitude
msDS-HABSeniorityIndex
msDS-PhoneticDisplayName
msExchAddressBookFlags
msExchArbitrationMailbox
msExchArchiveRelease
msExchAssistantName
msExchAuditAdmin
msExchAuditDelegate
msExchAuditDelegateAdmin
msExchAuditOwner
msExchAuthPolicyLink
msExchBlockedSendersHash
msExchBypassAudit
msExchCalculatedTargetAddress
msExchCalendarRepairDisabled
msExchConfigurationXML
msExchCorrelationId
msExchDelegateIRMBlockList
msExchDirsyncID
msExchELCMailboxFlags
msExchEnableModeration
msExchEnforcedTimestamps
msExchEwsApplicationAccessPolicy
msExchEwsEnabled
msExchExpansionServerName
msExchExtensionAttribute16
msExchExtensionAttribute17
msExchExtensionAttribute18
msExchExtensionAttribute40
msExchExtensionAttribute41
msExchExtensionAttribute45
msExchExternalDirectoryObjectId
msExchFBURL
msExchForeignGroupSid
msExchGenericForwardingAddress
msExchGroupExternalMemberCount
msExchGroupMemberCount
msExchGroupSecurityFlags
msExchHideFromAddressLists
msExchImmutableId
msExchIntendedMailboxPlanLink
msExchIsMSODirsynced
msExchJoinedProxyAddress
msExchLastExchangeChangedTime
msExchLitigationHoldDate
msExchLitigationHoldOwner
msExchLocalizationFlags
msExchMailboxAuditEnable
msExchMailboxAuditLastAdminAccess
msExchMailboxAuditLastDelegateAccess
msExchMailboxAuditLastExternalAccess
msExchMailboxAuditLogAgeLimit
msExchMailboxFolderSet
msExchMailboxMoveBatchName
msExchMailboxMoveFlags
msExchMailboxMoveRemoteHostName
msExchMailboxMoveSourceArchiveMDBLink
msExchMailboxMoveSourceMDBLink
msExchMailboxMoveStatus
msExchMailboxMoveTargetArchiveMDBLink
msExchMailboxMoveTargetMDBLink
msExchMailboxPlanType
msExchMailboxRelease
msExchMailboxSecurityDescriptor
msExchMasterAccountSid
msExchMessageHygieneFlags
msExchMessageHygieneSCLDeleteThreshold
msExchMessageHygieneSCLJunkThreshold
msExchMessageHygieneSCLQuarantineThreshold
msExchMessageHygieneSCLRejectThreshold
msExchModerationFlags
msExchObjectID
msExchOnPremiseObjectGuid
msExchOrganizationUpgradeRequest
msExchOrganizationUpgradeStatus
msExchOWAPolicy
msExchParentPlanLink
msExchPartnerGroupID
msExchPreviousRecipientTypeDetails
msExchProvisioningFlags
msExchPublicFolderMailbox
msExchRBACPolicyLink
msExchRecipientDisplayType
msExchRecipientSoftDeletedStatus
msExchRecipientTypeDetails
msExchRecipLimit
msExchRemoteRecipientType
msExchReplicableChangeVersion
msExchRequireAuthToSendTo
msExchResourceCapacity
msExchResourceDisplay
msExchRetentionComment
msExchRetentionURL
msExchRoleGroupType
msExchSafeRecipientsHash
msExchSafeSendersHash
msExchSharedDomainLastModified
msExchSharedDomainTenant
msExchSharedWithReference
msExchSharedWithTargetProxyAddress
msExchSharingPolicyLink
msExchStsRefreshTokensValidFrom
msExchSyncAccountsPolicyDN
msExchThrottlingPolicyDN
msExchTransportRecipientSettingsFlags
msExchUMListInDirectorySearch
msExchUMRecipientDialPlanLink
msExchUMSpokenName
msExchUserAccountControl
msExchUserCulture
msExchVersion
msExchWellKnownObject
msExchWhenIBSegmentChanged
msExchWhenMailboxCreated
msExchWhenMailboxWorkloadsModified
msExchWhenPropChangeLastSubmitted
msExchWhenReplicablePropLastChanged
msExchWhenSoftDeletedTime
msExchWindowsLiveID
pager
physicalDeliveryOfficeName
postalCode
ReplicationSignature
sn
st
streetAddress
submissionContLength
targetAddress
telephoneAssistant
telephoneNumber
textEncodedORAddress
title
wWWHomePage
```

#### Set-ADObject -Remove or -Clear (selected randomly per attribute on each object) (54)

```text
authOrig
description
dLMemRejectPerms
dLMemSubmitPerms
msExchAdministrativeUnitLink
msExchBypassModerationFromDLMembersLink
msExchBypassModerationLink
msExchCapabilityIdentifiers
msExchDirsyncAuthorityMetadata
msExchEwsExceptions
msExchEwsWellKnownApplicationPolicies
msExchExtensionCustomAttribute1
msExchExtensionCustomAttribute2
msExchExtensionCustomAttribute3
msExchExtensionCustomAttribute4
msExchExtensionCustomAttribute5
msExchInformationBarrierSegmentLink
msExchLabeledURI
msExchModeratedByLink
msExchMultiMailboxDatabasesLink
msExchMultiMailboxGUIDs
msExchMultiMailboxLocationsLink
msExchNonCompliantDeviceLink
msExchNonCompliantDevices
msExchPoliciesExcluded
msExchPoliciesIncluded
msExchResourceBehaviorOptions
msExchResourceMetaData
msExchResourceProvisioningOptions
msExchResourceSearchProperties
msExchRMSComputerAccountsLink
msExchSenderHintTranslations
msExchSharingAnonymousIdentities
msExchSharingPartnerIdentities
msExchSIDHistory
msExchSupervisionDLLink
msExchSupervisionOneOffLink
msExchSupervisionUserLink
msExchTextMessagingState
msExchUCVoiceMailSettings
msExchUMCallingLineIds
msExchUMDtmfMap
msExchUserHoldPolicies
otherFacsimileTelephoneNumber
otherHomePhone
otherTelephone
postOfficeBox
protocolSettings
publicDelegates
securityProtocol
showInAddressBook
unauthOrig
userCertificate
userSMIMECertificate
```

#### Set-ADObject -Remove only (protected; retain at least one value) (1)

```text
proxyAddresses
```

</details>

<details>
<summary>Pure User Link Deletion — 33 LDAP attributes</summary>

Entity: **Mail contact**

#### Set-ADObject -Clear (16)

```text
altRecipient
mailNickname
manager
msExchArbitrationMailbox
msExchAuthPolicyLink
msExchIntendedMailboxPlanLink
msExchOWAPolicy
msExchParentPlanLink
msExchPublicFolderMailbox
msExchRBACPolicyLink
msExchRecipientSoftDeletedStatus
msExchRecipientTypeDetails
msExchSharingPolicyLink
msExchSyncAccountsPolicyDN
msExchThrottlingPolicyDN
msExchUMRecipientDialPlanLink
```

#### Set-ADObject -Remove or -Clear (selected randomly per attribute on each object) (17)

```text
authOrig
dLMemRejectPerms
dLMemSubmitPerms
msExchAdministrativeUnitLink
msExchBypassModerationFromDLMembersLink
msExchBypassModerationLink
msExchInformationBarrierSegmentLink
msExchModeratedByLink
msExchNonCompliantDeviceLink
msExchRMSComputerAccountsLink
msExchSIDHistory
msExchSupervisionDLLink
msExchSupervisionOneOffLink
msExchSupervisionUserLink
publicDelegates
showInAddressBook
unauthOrig
```

#### Set-ADObject -Remove only (protected; retain at least one value) (0)

_None._

</details>

<details>
<summary>Pure Group Recipient Deletion — 263 LDAP attributes</summary>

Entity: **Distribution group**

#### Set-ADObject -Clear (204)

```text
adminDisplayName
altRecipient
company
deletedItemFlags
delivContLength
deliverAndRedirect
department
description
displayName
displayNamePrintable
extensionAttribute1
extensionAttribute10
extensionAttribute11
extensionAttribute12
extensionAttribute13
extensionAttribute14
extensionAttribute15
extensionAttribute2
extensionAttribute3
extensionAttribute4
extensionAttribute5
extensionAttribute6
extensionAttribute7
extensionAttribute8
extensionAttribute9
garbageCollPeriod
heuristics
hideDLMembership
homeMDB
homeMTA
info
internetEncoding
legacyExchangeDN
mail
mailNickname
managedBy
mAPIRecipient
mDBUseDefaults
msDS-GeoCoordinatesAltitude
msDS-GeoCoordinatesLatitude
msDS-GeoCoordinatesLongitude
msDS-HABSeniorityIndex
msDS-PhoneticDisplayName
msExchAddressBookFlags
msExchAddressBookPolicyLink
msExchArbitrationMailbox
msExchArchiveAddress
msExchArchiveDatabaseLink
msExchArchiveGUID
msExchArchiveQuota
msExchArchiveRelease
msExchArchiveStatus
msExchArchiveWarnQuota
msExchAssistantName
msExchAuditAdmin
msExchAuditDelegate
msExchAuditDelegateAdmin
msExchAuditOwner
msExchAuthPolicyLink
msExchBlockedSendersHash
msExchBypassAudit
msExchCalculatedTargetAddress
msExchCalendarLoggingQuota
msExchCalendarRepairDisabled
msExchConfigurationXML
msExchCorrelationId
msExchDataEncryptionPolicyLink
msExchDelegateIRMBlockList
msExchDirsyncID
msExchDisabledArchiveDatabaseLink
msExchDisabledArchiveGUID
msExchDumpsterQuota
msExchDumpsterWarningQuota
msExchELCExpirySuspensionEnd
msExchELCExpirySuspensionStart
msExchELCMailboxFlags
msExchEnableModeration
msExchEnforcedTimestamps
msExchEwsApplicationAccessPolicy
msExchEwsEnabled
msExchExpansionServerName
msExchExtensionAttribute16
msExchExtensionAttribute17
msExchExtensionAttribute18
msExchExtensionAttribute40
msExchExtensionAttribute41
msExchExtensionAttribute45
msExchExternalDirectoryObjectId
msExchExternalOOFOptions
msExchFBURL
msExchForeignGroupSid
msExchGenericForwardingAddress
msExchGroupDepartRestriction
msExchGroupExternalMemberCount
msExchGroupJoinRestriction
msExchGroupMemberCount
msExchGroupSecurityFlags
msExchHideFromAddressLists
msExchHomeServerName
msExchImmutableId
msExchIntendedMailboxPlanLink
msExchIsMSODirsynced
msExchJoinedProxyAddress
msExchLastExchangeChangedTime
msExchLitigationHoldDate
msExchLitigationHoldOwner
msExchLocalizationFlags
msExchMailboxAuditEnable
msExchMailboxAuditLastAdminAccess
msExchMailboxAuditLastDelegateAccess
msExchMailboxAuditLastExternalAccess
msExchMailboxAuditLogAgeLimit
msExchMailboxContainerGuid
msExchMailboxFolderSet
msExchMailboxGuid
msExchMailboxMoveBatchName
msExchMailboxMoveFlags
msExchMailboxMoveRemoteHostName
msExchMailboxMoveSourceArchiveMDBLink
msExchMailboxMoveSourceMDBLink
msExchMailboxMoveStatus
msExchMailboxMoveTargetArchiveMDBLink
msExchMailboxMoveTargetMDBLink
msExchMailboxPlanType
msExchMailboxRelease
msExchMailboxSecurityDescriptor
msExchMailboxTemplateLink
msExchMasterAccountSid
msExchMaxBlockedSenders
msExchMaxSafeSenders
msExchMDBRulesQuota
msExchMessageHygieneFlags
msExchMessageHygieneSCLDeleteThreshold
msExchMessageHygieneSCLJunkThreshold
msExchMessageHygieneSCLQuarantineThreshold
msExchMessageHygieneSCLRejectThreshold
msExchMobileMailboxFlags
msExchMobileMailboxPolicyLink
msExchModerationFlags
msExchObjectID
msExchOnPremiseObjectGuid
msExchOrganizationUpgradeRequest
msExchOrganizationUpgradeStatus
msExchOWAPolicy
msExchParentPlanLink
msExchPartnerGroupID
msExchPreviousHomeMDB
msExchPreviousMailboxGuid
msExchPreviousRecipientTypeDetails
msExchProvisioningFlags
msExchPublicFolderMailbox
msExchRBACPolicyLink
msExchRecipientDisplayType
msExchRecipientSoftDeletedStatus
msExchRecipientTypeDetails
msExchRecipLimit
msExchRemoteRecipientType
msExchReplicableChangeVersion
msExchRequireAuthToSendTo
msExchResourceCapacity
msExchResourceDisplay
msExchRetentionComment
msExchRetentionURL
msExchRoleGroupType
msExchSafeRecipientsHash
msExchSafeSendersHash
msExchSharedDomainLastModified
msExchSharedDomainTenant
msExchSharedWithReference
msExchSharedWithTargetProxyAddress
msExchSharingPolicyLink
msExchStsRefreshTokensValidFrom
msExchSyncAccountsPolicyDN
msExchTeamMailboxExpiration
msExchTeamMailboxSharePointUrl
msExchThrottlingPolicyDN
msExchTransportRecipientSettingsFlags
msExchUMListInDirectorySearch
msExchUMRecipientDialPlanLink
msExchUMSpokenName
msExchUMTemplateLink
msExchUnifiedMailbox
msExchUseOAB
msExchUserAccountControl
msExchUserCulture
msExchVersion
msExchWellKnownObject
msExchWhenIBSegmentChanged
msExchWhenMailboxCreated
msExchWhenMailboxWorkloadsModified
msExchWhenPropChangeLastSubmitted
msExchWhenReplicablePropLastChanged
msExchWhenSoftDeletedTime
msExchWindowsLiveID
msOrg-IsOrganizational
oOFReplyToOriginator
ReplicationSignature
reportToOriginator
reportToOwner
submissionContLength
targetAddress
telephoneNumber
textEncodedORAddress
wWWHomePage
```

#### Set-ADObject -Remove or -Clear (selected randomly per attribute on each object) (58)

```text
AltSecurityIdentities
authOrig
dLMemRejectPerms
dLMemSubmitPerms
msExchAdministrativeUnitLink
msExchAlternateMailboxes
msExchApprovalApplicationLink
msExchArchiveName
msExchBypassModerationFromDLMembersLink
msExchBypassModerationLink
msExchCapabilityIdentifiers
msExchCoManagedByLink
msExchDelegateListLink
msExchDirsyncAuthorityMetadata
msExchEwsExceptions
msExchEwsWellKnownApplicationPolicies
msExchExtensionCustomAttribute1
msExchExtensionCustomAttribute2
msExchExtensionCustomAttribute3
msExchExtensionCustomAttribute4
msExchExtensionCustomAttribute5
msExchInformationBarrierSegmentLink
msExchLabeledURI
msExchMobileAllowedDeviceIds
msExchMobileBlockedDeviceIds
msExchModeratedByLink
msExchMultiMailboxDatabasesLink
msExchMultiMailboxGUIDs
msExchMultiMailboxLocationsLink
msExchNonCompliantDeviceLink
msExchNonCompliantDevices
msExchPoliciesExcluded
msExchPoliciesIncluded
msExchResourceBehaviorOptions
msExchResourceMetaData
msExchResourceProvisioningOptions
msExchResourceSearchProperties
msExchRMSComputerAccountsLink
msExchSenderHintTranslations
msExchSharingAnonymousIdentities
msExchSharingPartnerIdentities
msExchSIDHistory
msExchSupervisionDLLink
msExchSupervisionOneOffLink
msExchSupervisionUserLink
msExchTeamMailboxOwners
msExchTextMessagingState
msExchUCVoiceMailSettings
msExchUMCallingLineIds
msExchUMDtmfMap
msExchUserHoldPolicies
protocolSettings
publicDelegates
securityProtocol
showInAddressBook
unauthOrig
userCertificate
userSMIMECertificate
```

#### Set-ADObject -Remove only (protected; retain at least one value) (1)

```text
proxyAddresses
```

</details>

<details>
<summary>Pure Group Link Deletion — 44 LDAP attributes</summary>

Entity: **Distribution group**

#### Set-ADObject -Clear (23)

```text
altRecipient
mailNickname
managedBy
msExchAddressBookPolicyLink
msExchArbitrationMailbox
msExchAuthPolicyLink
msExchDataEncryptionPolicyLink
msExchHomeServerName
msExchIntendedMailboxPlanLink
msExchMailboxTemplateLink
msExchMobileMailboxPolicyLink
msExchOWAPolicy
msExchParentPlanLink
msExchPublicFolderMailbox
msExchRBACPolicyLink
msExchRecipientSoftDeletedStatus
msExchRecipientTypeDetails
msExchSharingPolicyLink
msExchSyncAccountsPolicyDN
msExchThrottlingPolicyDN
msExchUMRecipientDialPlanLink
msExchUMTemplateLink
msExchUseOAB
```

#### Set-ADObject -Remove or -Clear (selected randomly per attribute on each object) (21)

```text
authOrig
dLMemRejectPerms
dLMemSubmitPerms
msExchAdministrativeUnitLink
msExchApprovalApplicationLink
msExchBypassModerationFromDLMembersLink
msExchBypassModerationLink
msExchCoManagedByLink
msExchDelegateListLink
msExchInformationBarrierSegmentLink
msExchModeratedByLink
msExchNonCompliantDeviceLink
msExchRMSComputerAccountsLink
msExchSIDHistory
msExchSupervisionDLLink
msExchSupervisionOneOffLink
msExchSupervisionUserLink
msExchTeamMailboxOwners
publicDelegates
showInAddressBook
unauthOrig
```

#### Set-ADObject -Remove only (protected; retain at least one value) (0)

_None._

</details>

<details>
<summary>Mixed User Deletion — 233 LDAP attributes</summary>

Entity: **Mail contact**

#### Set-ADObject -Clear (178)

```text
adminDisplayName
altRecipient
c
co
company
CountryCode
delivContLength
deliverAndRedirect
department
displayName
displayNamePrintable
extensionAttribute1
extensionAttribute10
extensionAttribute11
extensionAttribute12
extensionAttribute13
extensionAttribute14
extensionAttribute15
extensionAttribute2
extensionAttribute3
extensionAttribute4
extensionAttribute5
extensionAttribute6
extensionAttribute7
extensionAttribute8
extensionAttribute9
facsimileTelephoneNumber
garbageCollPeriod
givenName
heuristics
homeMTA
homePhone
info
initials
internetEncoding
l
legacyExchangeDN
mail
mailNickname
manager
mAPIRecipient
mobile
msDS-GeoCoordinatesAltitude
msDS-GeoCoordinatesLatitude
msDS-GeoCoordinatesLongitude
msDS-HABSeniorityIndex
msDS-PhoneticDisplayName
msExchAddressBookFlags
msExchArbitrationMailbox
msExchArchiveRelease
msExchAssistantName
msExchAuditAdmin
msExchAuditDelegate
msExchAuditDelegateAdmin
msExchAuditOwner
msExchAuthPolicyLink
msExchBlockedSendersHash
msExchBypassAudit
msExchCalculatedTargetAddress
msExchCalendarRepairDisabled
msExchConfigurationXML
msExchCorrelationId
msExchDelegateIRMBlockList
msExchDirsyncID
msExchELCMailboxFlags
msExchEnableModeration
msExchEnforcedTimestamps
msExchEwsApplicationAccessPolicy
msExchEwsEnabled
msExchExpansionServerName
msExchExtensionAttribute16
msExchExtensionAttribute17
msExchExtensionAttribute18
msExchExtensionAttribute40
msExchExtensionAttribute41
msExchExtensionAttribute45
msExchExternalDirectoryObjectId
msExchFBURL
msExchForeignGroupSid
msExchGenericForwardingAddress
msExchGroupExternalMemberCount
msExchGroupMemberCount
msExchGroupSecurityFlags
msExchHideFromAddressLists
msExchImmutableId
msExchIntendedMailboxPlanLink
msExchIsMSODirsynced
msExchJoinedProxyAddress
msExchLastExchangeChangedTime
msExchLitigationHoldDate
msExchLitigationHoldOwner
msExchLocalizationFlags
msExchMailboxAuditEnable
msExchMailboxAuditLastAdminAccess
msExchMailboxAuditLastDelegateAccess
msExchMailboxAuditLastExternalAccess
msExchMailboxAuditLogAgeLimit
msExchMailboxFolderSet
msExchMailboxMoveBatchName
msExchMailboxMoveFlags
msExchMailboxMoveRemoteHostName
msExchMailboxMoveSourceArchiveMDBLink
msExchMailboxMoveSourceMDBLink
msExchMailboxMoveStatus
msExchMailboxMoveTargetArchiveMDBLink
msExchMailboxMoveTargetMDBLink
msExchMailboxPlanType
msExchMailboxRelease
msExchMailboxSecurityDescriptor
msExchMasterAccountSid
msExchMessageHygieneFlags
msExchMessageHygieneSCLDeleteThreshold
msExchMessageHygieneSCLJunkThreshold
msExchMessageHygieneSCLQuarantineThreshold
msExchMessageHygieneSCLRejectThreshold
msExchModerationFlags
msExchObjectID
msExchOnPremiseObjectGuid
msExchOrganizationUpgradeRequest
msExchOrganizationUpgradeStatus
msExchOWAPolicy
msExchParentPlanLink
msExchPartnerGroupID
msExchPreviousRecipientTypeDetails
msExchProvisioningFlags
msExchPublicFolderMailbox
msExchRBACPolicyLink
msExchRecipientDisplayType
msExchRecipientSoftDeletedStatus
msExchRecipientTypeDetails
msExchRecipLimit
msExchRemoteRecipientType
msExchReplicableChangeVersion
msExchRequireAuthToSendTo
msExchResourceCapacity
msExchResourceDisplay
msExchRetentionComment
msExchRetentionURL
msExchRoleGroupType
msExchSafeRecipientsHash
msExchSafeSendersHash
msExchSharedDomainLastModified
msExchSharedDomainTenant
msExchSharedWithReference
msExchSharedWithTargetProxyAddress
msExchSharingPolicyLink
msExchStsRefreshTokensValidFrom
msExchSyncAccountsPolicyDN
msExchThrottlingPolicyDN
msExchTransportRecipientSettingsFlags
msExchUMListInDirectorySearch
msExchUMRecipientDialPlanLink
msExchUMSpokenName
msExchUserAccountControl
msExchUserCulture
msExchVersion
msExchWellKnownObject
msExchWhenIBSegmentChanged
msExchWhenMailboxCreated
msExchWhenMailboxWorkloadsModified
msExchWhenPropChangeLastSubmitted
msExchWhenReplicablePropLastChanged
msExchWhenSoftDeletedTime
msExchWindowsLiveID
pager
physicalDeliveryOfficeName
postalCode
ReplicationSignature
sn
st
streetAddress
submissionContLength
targetAddress
telephoneAssistant
telephoneNumber
textEncodedORAddress
title
wWWHomePage
```

#### Set-ADObject -Remove or -Clear (selected randomly per attribute on each object) (54)

```text
authOrig
description
dLMemRejectPerms
dLMemSubmitPerms
msExchAdministrativeUnitLink
msExchBypassModerationFromDLMembersLink
msExchBypassModerationLink
msExchCapabilityIdentifiers
msExchDirsyncAuthorityMetadata
msExchEwsExceptions
msExchEwsWellKnownApplicationPolicies
msExchExtensionCustomAttribute1
msExchExtensionCustomAttribute2
msExchExtensionCustomAttribute3
msExchExtensionCustomAttribute4
msExchExtensionCustomAttribute5
msExchInformationBarrierSegmentLink
msExchLabeledURI
msExchModeratedByLink
msExchMultiMailboxDatabasesLink
msExchMultiMailboxGUIDs
msExchMultiMailboxLocationsLink
msExchNonCompliantDeviceLink
msExchNonCompliantDevices
msExchPoliciesExcluded
msExchPoliciesIncluded
msExchResourceBehaviorOptions
msExchResourceMetaData
msExchResourceProvisioningOptions
msExchResourceSearchProperties
msExchRMSComputerAccountsLink
msExchSenderHintTranslations
msExchSharingAnonymousIdentities
msExchSharingPartnerIdentities
msExchSIDHistory
msExchSupervisionDLLink
msExchSupervisionOneOffLink
msExchSupervisionUserLink
msExchTextMessagingState
msExchUCVoiceMailSettings
msExchUMCallingLineIds
msExchUMDtmfMap
msExchUserHoldPolicies
otherFacsimileTelephoneNumber
otherHomePhone
otherTelephone
postOfficeBox
protocolSettings
publicDelegates
securityProtocol
showInAddressBook
unauthOrig
userCertificate
userSMIMECertificate
```

#### Set-ADObject -Remove only (protected; retain at least one value) (1)

```text
proxyAddresses
```

</details>

<details>
<summary>Mixed Group Deletion — 263 LDAP attributes</summary>

Entity: **Distribution group**

#### Set-ADObject -Clear (204)

```text
adminDisplayName
altRecipient
company
deletedItemFlags
delivContLength
deliverAndRedirect
department
description
displayName
displayNamePrintable
extensionAttribute1
extensionAttribute10
extensionAttribute11
extensionAttribute12
extensionAttribute13
extensionAttribute14
extensionAttribute15
extensionAttribute2
extensionAttribute3
extensionAttribute4
extensionAttribute5
extensionAttribute6
extensionAttribute7
extensionAttribute8
extensionAttribute9
garbageCollPeriod
heuristics
hideDLMembership
homeMDB
homeMTA
info
internetEncoding
legacyExchangeDN
mail
mailNickname
managedBy
mAPIRecipient
mDBUseDefaults
msDS-GeoCoordinatesAltitude
msDS-GeoCoordinatesLatitude
msDS-GeoCoordinatesLongitude
msDS-HABSeniorityIndex
msDS-PhoneticDisplayName
msExchAddressBookFlags
msExchAddressBookPolicyLink
msExchArbitrationMailbox
msExchArchiveAddress
msExchArchiveDatabaseLink
msExchArchiveGUID
msExchArchiveQuota
msExchArchiveRelease
msExchArchiveStatus
msExchArchiveWarnQuota
msExchAssistantName
msExchAuditAdmin
msExchAuditDelegate
msExchAuditDelegateAdmin
msExchAuditOwner
msExchAuthPolicyLink
msExchBlockedSendersHash
msExchBypassAudit
msExchCalculatedTargetAddress
msExchCalendarLoggingQuota
msExchCalendarRepairDisabled
msExchConfigurationXML
msExchCorrelationId
msExchDataEncryptionPolicyLink
msExchDelegateIRMBlockList
msExchDirsyncID
msExchDisabledArchiveDatabaseLink
msExchDisabledArchiveGUID
msExchDumpsterQuota
msExchDumpsterWarningQuota
msExchELCExpirySuspensionEnd
msExchELCExpirySuspensionStart
msExchELCMailboxFlags
msExchEnableModeration
msExchEnforcedTimestamps
msExchEwsApplicationAccessPolicy
msExchEwsEnabled
msExchExpansionServerName
msExchExtensionAttribute16
msExchExtensionAttribute17
msExchExtensionAttribute18
msExchExtensionAttribute40
msExchExtensionAttribute41
msExchExtensionAttribute45
msExchExternalDirectoryObjectId
msExchExternalOOFOptions
msExchFBURL
msExchForeignGroupSid
msExchGenericForwardingAddress
msExchGroupDepartRestriction
msExchGroupExternalMemberCount
msExchGroupJoinRestriction
msExchGroupMemberCount
msExchGroupSecurityFlags
msExchHideFromAddressLists
msExchHomeServerName
msExchImmutableId
msExchIntendedMailboxPlanLink
msExchIsMSODirsynced
msExchJoinedProxyAddress
msExchLastExchangeChangedTime
msExchLitigationHoldDate
msExchLitigationHoldOwner
msExchLocalizationFlags
msExchMailboxAuditEnable
msExchMailboxAuditLastAdminAccess
msExchMailboxAuditLastDelegateAccess
msExchMailboxAuditLastExternalAccess
msExchMailboxAuditLogAgeLimit
msExchMailboxContainerGuid
msExchMailboxFolderSet
msExchMailboxGuid
msExchMailboxMoveBatchName
msExchMailboxMoveFlags
msExchMailboxMoveRemoteHostName
msExchMailboxMoveSourceArchiveMDBLink
msExchMailboxMoveSourceMDBLink
msExchMailboxMoveStatus
msExchMailboxMoveTargetArchiveMDBLink
msExchMailboxMoveTargetMDBLink
msExchMailboxPlanType
msExchMailboxRelease
msExchMailboxSecurityDescriptor
msExchMailboxTemplateLink
msExchMasterAccountSid
msExchMaxBlockedSenders
msExchMaxSafeSenders
msExchMDBRulesQuota
msExchMessageHygieneFlags
msExchMessageHygieneSCLDeleteThreshold
msExchMessageHygieneSCLJunkThreshold
msExchMessageHygieneSCLQuarantineThreshold
msExchMessageHygieneSCLRejectThreshold
msExchMobileMailboxFlags
msExchMobileMailboxPolicyLink
msExchModerationFlags
msExchObjectID
msExchOnPremiseObjectGuid
msExchOrganizationUpgradeRequest
msExchOrganizationUpgradeStatus
msExchOWAPolicy
msExchParentPlanLink
msExchPartnerGroupID
msExchPreviousHomeMDB
msExchPreviousMailboxGuid
msExchPreviousRecipientTypeDetails
msExchProvisioningFlags
msExchPublicFolderMailbox
msExchRBACPolicyLink
msExchRecipientDisplayType
msExchRecipientSoftDeletedStatus
msExchRecipientTypeDetails
msExchRecipLimit
msExchRemoteRecipientType
msExchReplicableChangeVersion
msExchRequireAuthToSendTo
msExchResourceCapacity
msExchResourceDisplay
msExchRetentionComment
msExchRetentionURL
msExchRoleGroupType
msExchSafeRecipientsHash
msExchSafeSendersHash
msExchSharedDomainLastModified
msExchSharedDomainTenant
msExchSharedWithReference
msExchSharedWithTargetProxyAddress
msExchSharingPolicyLink
msExchStsRefreshTokensValidFrom
msExchSyncAccountsPolicyDN
msExchTeamMailboxExpiration
msExchTeamMailboxSharePointUrl
msExchThrottlingPolicyDN
msExchTransportRecipientSettingsFlags
msExchUMListInDirectorySearch
msExchUMRecipientDialPlanLink
msExchUMSpokenName
msExchUMTemplateLink
msExchUnifiedMailbox
msExchUseOAB
msExchUserAccountControl
msExchUserCulture
msExchVersion
msExchWellKnownObject
msExchWhenIBSegmentChanged
msExchWhenMailboxCreated
msExchWhenMailboxWorkloadsModified
msExchWhenPropChangeLastSubmitted
msExchWhenReplicablePropLastChanged
msExchWhenSoftDeletedTime
msExchWindowsLiveID
msOrg-IsOrganizational
oOFReplyToOriginator
ReplicationSignature
reportToOriginator
reportToOwner
submissionContLength
targetAddress
telephoneNumber
textEncodedORAddress
wWWHomePage
```

#### Set-ADObject -Remove or -Clear (selected randomly per attribute on each object) (58)

```text
AltSecurityIdentities
authOrig
dLMemRejectPerms
dLMemSubmitPerms
msExchAdministrativeUnitLink
msExchAlternateMailboxes
msExchApprovalApplicationLink
msExchArchiveName
msExchBypassModerationFromDLMembersLink
msExchBypassModerationLink
msExchCapabilityIdentifiers
msExchCoManagedByLink
msExchDelegateListLink
msExchDirsyncAuthorityMetadata
msExchEwsExceptions
msExchEwsWellKnownApplicationPolicies
msExchExtensionCustomAttribute1
msExchExtensionCustomAttribute2
msExchExtensionCustomAttribute3
msExchExtensionCustomAttribute4
msExchExtensionCustomAttribute5
msExchInformationBarrierSegmentLink
msExchLabeledURI
msExchMobileAllowedDeviceIds
msExchMobileBlockedDeviceIds
msExchModeratedByLink
msExchMultiMailboxDatabasesLink
msExchMultiMailboxGUIDs
msExchMultiMailboxLocationsLink
msExchNonCompliantDeviceLink
msExchNonCompliantDevices
msExchPoliciesExcluded
msExchPoliciesIncluded
msExchResourceBehaviorOptions
msExchResourceMetaData
msExchResourceProvisioningOptions
msExchResourceSearchProperties
msExchRMSComputerAccountsLink
msExchSenderHintTranslations
msExchSharingAnonymousIdentities
msExchSharingPartnerIdentities
msExchSIDHistory
msExchSupervisionDLLink
msExchSupervisionOneOffLink
msExchSupervisionUserLink
msExchTeamMailboxOwners
msExchTextMessagingState
msExchUCVoiceMailSettings
msExchUMCallingLineIds
msExchUMDtmfMap
msExchUserHoldPolicies
protocolSettings
publicDelegates
securityProtocol
showInAddressBook
unauthOrig
userCertificate
userSMIMECertificate
```

#### Set-ADObject -Remove only (protected; retain at least one value) (1)

```text
proxyAddresses
```

</details>

## PowerShell invocation

Run the harness from an elevated Windows PowerShell 5.1 Exchange environment
on the TDS machine:

```powershell
.\Invoke-DirectoryObjectStoreLongevity.ps1 `
    -WorkloadMode ScenarioTest `
    -ScenarioCommand User-Upsert `
    -ScenarioSetMode Full `
    -PopulationSourceRunDirectory C:\tds\ScenarioTest\Runs\<prior-run-id> `
    -Organization contoso.com `
    -ObjectPrefix DOSUserUpsert `
    -Side A `
    -ObjectStoreDestination Test `
    -CompareSetupScript C:\tds\CompareAndRepairSetup.ps1 `
    -ScenarioRuntimeDependencyRoot C:\tds\RuntimeDependencies\net472
```

Omit `-PopulationSourceRunDirectory` when creating a new population on a TDS.
Replace `User-Upsert` with any command from the table. When Copilot runs the
skill, it automatically generates a unique `ObjectPrefix` from the command,
UTC timestamp, and a six-character GUID suffix, for example:

```text
DOSUU-0829170744-a1b2c3
```

Users do not need to choose or approve the prefix. Direct PowerShell callers
must still provide their own unique `-ObjectPrefix`.

The script records the selected command, phase list, estimate, population
sizes, and total batch count in `parameters.json`, `status.json`,
`checkpoint.json`, and `summary.json`.

## Start announcement

Before launching, the skill reports:

```text
Command: <command>
Set mode: <Full-or-MiniSet>
Scenarios: <ordered scenario names>
Estimated duration: <estimate>
Time breakdown: preflight <10m>; population <0m reused-or-15m new>; scenario <estimate>
Population: <reused from run-id-or-237 contacts and 269 groups to create>
Scenario batches: <mode-specific-total>
Organization: <supplied-or-automatically-selected-organization>
Object prefix: <automatically-generated-prefix>
Monitoring: every 2 minutes for the first 10 traffic minutes, then every
5 minutes while healthy.
```

The estimate includes the mandatory 10-minute preflight estimate and includes
the 15-minute population estimate only when a compatible shared population is
not reused. Environment or script repair can add time.

The scenario portions use the measured timings from the completed 48-batch
run. Mini-set sums the three or twelve batch-0 durations; full sums all
applicable scenario totals. Each stage is rounded upward to the next five
minutes:

- `User-Upsert`: 5 minutes mini-set, 60 minutes full;
- `Group-Upsert`: 5 minutes mini-set, 75 minutes full;
- `User-Properties-Deletion`: 10 minutes mini-set, 80 minutes full;
- `Group-Properties-Deletion`: 10 minutes mini-set, 95 minutes full;
- `Run-All-OBScenarios`: 30 minutes mini-set, 305 minutes full.

When no compatible population exists, the command creates the complete shared
population of 237 contacts and 269 groups. Later compatible commands reuse that
population by passing the prior successful run directory through
`-PopulationSourceRunDirectory`. Only the population ledger is imported; each
command gets a new run directory, checkpoint, phase plan, counters, and logs.

## Prerequisites

- Use a dedicated Windows TDS Exchange machine.
- Run from an elevated Windows PowerShell 5.1 process.
- `MSExchangeDirCacheService`, OLS, and
  `M365DirectoryProxyService` must be healthy.
- Ports 83 and 6092 must be listening.
- Supply a test organization such as `contoso.com`.
- Keep `CompareAndRepairSetup.ps1` available on the TDS machine.
- Provision `RuntimeDependencies\net472` from an authorized internal build.
  Do not commit compiled Exchange binaries to this repository.
- Use a dedicated, unique object prefix.

When the user does not specify an organization, the skill discovers eligible
Exchange organizations with `Get-Organization`. It prefers a valid
active `contoso.com` organization with a `UserMailbox`; otherwise it
deterministically uses the first active, non-system organization with a
`UserMailbox`. It never treats the forest's default `Get-AcceptedDomain` value
as the tenant. If no eligible organization exists, the run stops with a
prerequisite error instead of asking the user to choose from system tenants.

`User` means a mail-contact recipient created by this harness. It does not
mean an AD user or mailbox user. `Group` means a distribution group created by
the harness.

## Skill versus MCP

ObjectStoreScenarioTest is an **agent skill plus PowerShell scripts**. It is
not an MCP server and does not require an MCP server when an operator runs the
scripts directly on the TDS machine.

For Copilot-driven remote TDS setup, execution, and monitoring, the skill uses
an independently managed SubstrateMCP server exposing tools such as
`tds_execute_powershell` and `tds_copy_files`. SubstrateMCP is not bundled in
this repository.

Install the internal SubstrateMCP server in Copilot CLI:

```powershell
copilot mcp add substratemcp -- `
    agency artifact exec `
    --feed https://pkgs.dev.azure.com/o365exchange/_packaging/Enzyme/nuget/v3/index.json `
    --name Microsoft.Substrate.SubstrateMCP `
    --type nuget `
    --rid none `
    -- tools\any\win-x64\SubstrateDevelopmentMCP.Hosts.Console mcp start
```

This requires the Microsoft `agency` tool and access to the O365 Exchange
Enzyme feed. Verify the installation:

```powershell
copilot mcp list
copilot mcp get substratemcp
```

Inside an interactive session, use `/mcp` to view or manage configured
servers. Start a new session or use `/restart` if the newly added tools are not
visible.

## Preflight and qualification

A new command run performs:

1. Exchange and Object Store cookie initialization.
2. Comparison-runtime checks.
3. LDAP schema and property-generator validation.
4. Command-specific deterministic qualification.
5. Semantic target checks.
6. Fresh population creation.

Qualification covers only the phases selected by `ScenarioCommand`:

- Full subset command: 3 phases and 12 batches;
- Mini-set subset command: 3 phases and 3 batches;
- Full `Run-All-OBScenarios`: 12 phases and 48 batches;
- Mini-set `Run-All-OBScenarios`: 12 phases and 12 batches.

Scenario traffic starts only after qualification reports zero defects.

For read-only environment checking:

```powershell
.\Invoke-DirectoryObjectStoreLongevity.ps1 `
    -WorkloadMode ScenarioTest `
    -ScenarioCommand Group-Upsert `
    -PreflightOnly `
    -Organization contoso.com `
    -ObjectPrefix DOSPreflight
```

## Monitoring and reporting

Default reporting cadence:

1. Report every two minutes during bootstrap and the first ten traffic
   minutes.
2. After ten stable traffic minutes, report every five minutes.
3. Return to two-minute reporting after a failure, repair, resume, or material
   regression.

A user-requested interval overrides these defaults. If the user requests
separate initial and steady-state intervals, use both requested values.

Every report includes:

- local time with UTC offset and UTC time;
- run ID, exact PID, process start time, CPU, and private memory;
- command, current phase, batch, and stage;
- fresh population counts;
- completed batches versus command total;
- mutation and comparison `m/N`;
- baseline preparation, seeding, and comparison progress for deletion;
- operation and validation counters;
- consistency status and new failures;
- service, port, watermark, host-memory, and monitor health;
- current reporting interval.

The first report after launch uses the same complete shape as recurring
reports. Do not replace it with a short `started` message containing only PID,
prefix, population, batch count, and run directory.

The harness writes a run-bound `Starting` status snapshot before preflight.
The monitor waits up to 60 seconds for that snapshot to match the launched PID,
run ID, and process start time. It persists the verified PID/start pair so a
terminal report can say `previously verified` after the process exits without
confusing it with PID reuse.

```text
Report time: <local ISO-8601 timestamp with UTC offset> / <UTC ISO-8601 timestamp>
• Run: <run-id>
• Process: PID <pid>, identity <verified/previously verified/unverified>, <running/exited>; started <UTC>; ended <active/UTC/unknown>; exit <active/code/unknown>; CPU <seconds/unknown>; private memory <MB/unknown>
• Stage: <preflight/qualification/population/phase>, <batch if active>, <mutation/wait/comparison/terminal stage>
• Population: <contacts>/<target> contacts; <groups>/<target> groups; <new/reused/replacement generation>
• Operations/writes: <succeeded> succeeded, <failed or historical failures>; <current failure state>
• Scenario batches: <completed>/<total>; <active mutation and comparison progress>
• Validations: <passed> passed, <failed> failed; <pending comparisons>
• Data consistency: <consistent through exact phase/batch / inconsistent GUIDs / not checked / unknown>
• Timing statistics: <completed batch durations and phase total, or not available yet>
• Latest progress: <latest meaningful operation or artifact activity>
• Errors: <none current or concise errors>; stderr <empty/non-empty> and `PAUSED` marker <absent/present>
• TDS health: Directory Cache=<state>, OLS=<state>, Directory Proxy=<state>; ports 83=<state> and 6092=<state>
• Side-A sync watermarks: Recipients <UTC/unknown>, Links <UTC/unknown>, TenantConfig <UTC/unknown>; delay <values/unknown>
• Memory health: Scenario process <MB/unknown>; host free physical memory <GB/unknown>; largest WinRM shell <MB/unknown>
• Monitor health: <healthy/degraded/failed> under schedule #<id/unknown>; last successful status <UTC/unknown>; <stall assessment>
• Report interval: <two/five/user-requested> minutes; <reason>
```

Never omit a template line. Use `unknown` or `not available yet` when the run
has not produced that value.

Use the bounded status helper:

```powershell
.\Get-DirectoryObjectStoreScenarioStatus.ps1 `
    -RunDirectory C:\tds\ScenarioTest\Runs\<run-id> `
    -ProcessId <pid> `
    -ResumeStartedUtc <process-start-utc> `
    -StandardErrorPath <stderr-path>
```

Never load complete JSONL histories during recurring monitoring. Read
`status.json`, `checkpoint.json`, `summary.json`, and `PAUSED`; use at most a
20-line, 256-KB tail when additional log evidence is required.

## Failure behavior

Batch 0 attempts every object and aggregates all mutation and comparison
failures before pausing. Batches 1-3 stop on their first failure.

On failure the run preserves:

- completed object GUIDs;
- deletion preparation and seeding progress;
- the immutable batch plan;
- pending validations;
- operation and comparison evidence;
- a `PAUSED` marker and failure bundle.

Script defects may be repaired and resumed without repeating completed
objects. Product, consistency, and environment failures remain paused for
diagnosis.

If diagnosis proves a terminal per-object AD/Object Store inconsistency, the
harness records the affected GUIDs and changes the retry behavior:

- preserve the old objects in a `retired-population-pNN-gNN.json` artifact;
- create a complete replacement set for that phase's entity kind—237 contacts
  for a User phase or 269 groups for a Group phase;
- restart that phase from batch 0 with collision-safe generation names;
- preserve completed earlier phases;
- checkpoint every successful replacement creation and keep the replacement
  pending until every new GUID passes consistency validation.

Timeouts, skipped/incomplete compares, read failures, mutation failures, and
harness defects do not trigger population replacement because they do not
prove an object-data inconsistency.

## Resume

Always resume with the original workload, command, and set mode:

```powershell
.\Invoke-DirectoryObjectStoreLongevity.ps1 `
    -WorkloadMode ScenarioTest `
    -ScenarioCommand User-Properties-Deletion `
    -ScenarioSetMode <original-Full-or-MiniSet> `
    -PopulationSourceRunDirectory <original-source-run-if-reused> `
    -ResumeRunDirectory C:\tds\ScenarioTest\Runs\<run-id> `
    -Organization contoso.com `
    -ObjectPrefix <original-prefix> `
    -Side A `
    -ObjectStoreDestination Test
```

The checkpoint persists `WorkloadMode`, `ScenarioCommand`,
`ScenarioSetMode`, and the population source. A mismatched resume is rejected
before state restoration or traffic. Omit
`-PopulationSourceRunDirectory` only when the original run created its own
population.

Resume also requires the original organization, side, Object Store
destination, object prefix, random seed, simulation mode, comparison setup,
and runtime dependency path. This prevents a checkpoint from one set mode,
tenant, or execution mode being applied to another.

Compatible resumes restore:

- `scenario-target-context.clixml`, avoiding repeated target discovery;
- `scenario-plan-pNN-bNN.json`, preserving exact object/property assignments;
- mutation, comparison, and deletion-preparation checkpoints.

Run full preflight on resume only when the failure is proven to involve the
environment, dependencies, cookies, comparison runtime, configuration, or
target discovery.

## Run artifacts

Each run directory contains:

- `parameters.json`
- `status.json`
- `checkpoint.json`
- `summary.json`
- `qualification.json`
- `qualification-progress.json`
- `scenario-target-context.clixml`
- `scenario-plan-pNN-bNN.json`
- bounded/rotated operation, validation, event, and scenario-detail logs
- `PAUSED` and `failure-<timestamp>` when a failure occurs

JSON snapshots use unique temporary files and atomic same-volume replacement
with bounded retry, so concurrent monitor reads cannot pause healthy traffic.

## Timing statistics

Each successful batch records `ElapsedSeconds`, including preparation,
mutation, sync wait, and comparison. Each completed phase contains its four
batch records.

At terminal success, report:

- every phase total;
- every configured batch duration;
- upsert/deletion totals;
- total scenario-batch time;
- full wall-clock time;
- any repair/resume-affected timing that should be excluded from comparison.

## Cleanup

Pass `-CleanupOnSuccess` to remove only objects recorded in that run's ledger.
Objects are preserved after failure for diagnosis.

## Advanced workloads

`ScenarioCommand` applies only to `-WorkloadMode ScenarioTest`.

`AttributeCoverage` is the legacy default workload and exercises a generated
attribute catalog. `Longevity` runs a time-based production-shaped mix of
create, update, delete, membership, and read operations.

Do not resume a ScenarioTest checkpoint as `AttributeCoverage` or `Longevity`;
workload-mode compatibility is enforced.

## Copilot skill installation

Clone the repository:

```powershell
git clone https://github.com/wellorz/ObjectStoreScenarioTest.git
Set-Location .\ObjectStoreScenarioTest
```

### Project installation

The repository already contains the project skill at:

```text
.github/skills/objectstore-scenario-test-runner/SKILL.md
```

Start Copilot CLI from the repository root:

```powershell
copilot
```

Then verify:

```text
/skills reload
/skills info scenario-test-runner
```

### Personal installation

To make the skill available in other repositories, register the cloned skill
collection:

```powershell
copilot skill add "$PWD\.github\skills"
```

Inside an existing Copilot CLI session:

```text
/skills reload
/skills info scenario-test-runner
```

You can also copy the complete `objectstore-scenario-test-runner` directory to:

```text
%USERPROFILE%\.copilot\skills\objectstore-scenario-test-runner
```

The skill directory includes `SKILL.md`, the harness, status script, scenario
contract documents, and README. Runtime dependency binaries must still be
provisioned separately.

After installation, invoke it with one of:

```text
User-Upsert
Group-Upsert
User-Properties-Deletion
Group-Properties-Deletion
Run-All-OBScenarios
```

This directory is the single source of truth for the skill. Edit these files
directly and do not recreate duplicate operational copies at the repository
root.
