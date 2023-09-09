# Disk preparation for Proxmox

1. Get disk serial numbers
    ```
    ls /dev/disk/by-id/
    ```
2. Attach all wanted disks to VM i.e.
    ```
    qm set 100 -scsi1 /dev/disk/by-id/ata-ST10000DM0004-1ZC101_ZA2DR3MJ
    ```
