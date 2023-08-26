# Harvester

## Adding new disk to Harvester node

As of version 1.0.2, the disks need to be formatted before adding to Harvester node. This can be done by following the steps below

1. Remove the existing partitions using fdisk
2. Access the node config edit menu in Harvester UI
3. Click 'Add Disk'
4. Select the wanted drive and let Harvester format it
5. Drive is now ready for scheduling and mounted in /var/lib/harvester/extra-disks/{drive-id}
