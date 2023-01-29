

# Minio Azure Gateway

Bitnami helm chart is used and it's configured to provide s3 API for Azure Blob Storage. It's Working wonderfully! 

Some important steps: 

1. Set azure storage account & minio credentials in `cluster-secrets.yaml`
3. Create backup container i.e. `"longhorn-backup"` from Azure Portal or through Minio UI. 
4. Refer to minio credential variables in `./secret.yaml` file. 
5. Specify the backup folder and the secret name in Longhorn settings: 
    * Backup Target:
        ```
        s3://{folder}@{region}/
        ```
        so for my case: 
        ```
        s3://longhorn-backup@eu-central-1/
        ```
    * Backup Target Credential Secret: 
    Put secret name i.e. `minio-aws-secret`
