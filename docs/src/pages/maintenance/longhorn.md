# Longhorn

## Troubleshooting
### Accessing the files inside longhorn volume

The actual content of the longhorn volume is located in the 'volume-head-000.img' file. The files inside it can be accessed by mounting it to the local filesystem.

1. ssh to the host machine
2. Locate the longhorn volume folder and the .img file
3. Mount the file:
```
sudo mount ./volume-head-000.img /destination/mount/path
```
4. Check the content in '/destination/mount/path'

### Volume stuck in attaching and BackingImage stuck in 'unknown' state

1. Locate BackingImage that is stuck in 'unknown' state
2. Remove matching BackingImageDataSource
3. New image is loaded from the url in the manifest, which hopefully gets to 'ready' state.