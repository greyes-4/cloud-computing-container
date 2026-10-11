Why do the Uploader and Viewer use separate IAM roles?
The Uploader and Viewer use separate IAM roles to iprove security by following the principle of leave privilege. Each application only receives the permissions it needs to perform its task. The Uploader has s3:PutObject permission to upload files to S3, while the Viewer has s3:GetObject permission to read files. If both applications shared only one role, they would have unnecessary access to each other's functions. By giving them separate roles, you can reduce security risks and prevent unauthorized actions if one application becomes compromised. 

Why does embedding code into user-data eliminate the need for Git or S3 credentials?
Embedding the application code directly into EC2 user-data allows the instance to receive its code automatically when it launches. Since the code is already included in the instructions when starting up, the instance does not need Git or S3 credentials to download it from an external source. 
