# Minio Azure Gateway

Bitnami helm chart is used and it's configured to provide s3 API for Azure Blob Storage. It's Working wonderfully! 

Some important steps: 

1. Add azure storage account credentials
2. Check minio credentials from the created secret
3. Create backup container i.e. `"longhorn-backup"` from Azure Portal or through Minio UI. 
4. Add credentials to secret file, which is created to same namespace as Longhorn. See ./secret.yaml file for reference. 
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
