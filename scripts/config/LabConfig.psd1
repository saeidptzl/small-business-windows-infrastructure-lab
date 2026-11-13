# Single source of truth for the lab. Every script reads this file.
# All people below are synthetic. No passwords are stored here.
@{
    DomainFqdn        = 'corp.smallbiz.test'     # .test is reserved (RFC 2606): never collides with a real domain
    DomainNetbios     = 'SMALLBIZ'
    DomainDN          = 'DC=corp,DC=smallbiz,DC=test'

    LabSubnet         = '10.10.50.0/24'
    PrefixLength      = 24
    LanAdapterName    = 'LAB'

    DcName            = 'DC01'
    DcFqdn            = 'DC01.corp.smallbiz.test'
    DcIPv4            = '10.10.50.10'
    DcMac             = '52-54-00-50-00-10'

    ClientName        = 'CL01'
    ClientIPv4        = '10.10.50.21'
    ClientMac         = '52-54-00-50-00-21'

    # DC01 extra disks (QEMU serial numbers) and drive letters
    DataDiskSerial    = 'SB-DATA'
    BackupDiskSerial  = 'SB-BACKUP'
    DataDriveLetter   = 'D'
    BackupDriveLetter = 'E'
    ShareRoot         = 'D:\Shares'

    BaseOU            = 'SmallBiz'               # OU=SmallBiz,<DomainDN>
    EvidenceRoot      = 'C:\LabEvidence'

    # AGDLP: user accounts -> Global group (role) -> Domain Local group (resource) -> Permission
    Departments = @(
        @{ Name = 'Finance';    Drive = 'F'; Share = 'Finance';    UserGroup = 'GG_Finance';    ShareGroup = 'DL_FS_Finance_Modify' }
        @{ Name = 'Operations'; Drive = 'O'; Share = 'Operations'; UserGroup = 'GG_Operations'; ShareGroup = 'DL_FS_Operations_Modify' }
    )

    # Synthetic staff (fictional names)
    Staff = @(
        @{ Sam = 'giulia.bianchi'; GivenName = 'Giulia'; Surname = 'Bianchi'; Department = 'Finance';    Title = 'Accountant' }
        @{ Sam = 'luca.ferri';     GivenName = 'Luca';   Surname = 'Ferri';   Department = 'Finance';    Title = 'Finance Manager' }
        @{ Sam = 'marco.verdi';    GivenName = 'Marco';  Surname = 'Verdi';   Department = 'Operations'; Title = 'Warehouse Coordinator' }
        @{ Sam = 'sara.conti';     GivenName = 'Sara';   Surname = 'Conti';   Department = 'Operations'; Title = 'Operations Manager' }
    )

    DriveMapGpoName   = 'SB-U-DepartmentDriveMaps'
    SampleFile        = 'D:\Shares\Finance\Budget-2026-Q1-SAMPLE.csv'
    RecoveryRoot      = 'D:\RecoveryTest'
}
