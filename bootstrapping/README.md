# Create cloudinit-ready VM template in Proxmox

1. Download .img
```
wget https://cloud-images.ubuntu.com/jammy/20230613/jammy-server-cloudimg-amd64.img
```

2. Create VM
```
qm create 8000 --memory 8192 --name ubuntu-2204-cloud --net0 virtio,bridge=vmbr0
```

3. Import image as a drive
```
qm importdisk 8000 jammy-server-cloudimg-amd64.img local-lvm
```

4. Configure scsi to use drive from the previous step. Make sure disk id matches!
```
qm set 8000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-8000-disk-0
```

5. Create virtual cloudinit cd-rom
```
qm set 8000 --ide2 local-lvm:cloudinit
```

6. Configure boot from cloudinit drive
```
qm set 8000 --boot c --bootdisk scsi0
```

7. Configure serial so that GUI terminal works
```
qm set 8000 --serial0 socket --vga serial0
```

8. Navigate to Proxmox UI and configure cloud-init tab

9. Right click on the VM and select `Convert to template`

10. Woohoo you now have a cloudinit-ready Ubuntu 2204 template. Congratulations!
