ITMO 444 - Lab 07 Written Answer

Infrastructure as Code with Terraform

Part A — Terraform Resource Replacement

The -/+ symbol is the one to be most careful about because it means Terraform must replace an existing resource. This could cause downtime or data loss if the resource is important. An in-place update (~) is generally less disruptive because the resource can be modified without replacing it.

Part F - Expirements
Bash vs Terra Form
In Lab 06, the Bash scripts contained a total of 1,311 lines, with 1,060 actual lines of code and 286 lines dedicated to cleanup. In comparison, Lab 07 used 443 total lines of Terraform, with 350 actual lines of code and no separate cleanup scripts.
Bash required me to manually organize deployment steps, create helper functions, and write retry and wait loops. Terraform handled most of these processes automatically through its dependency management and AWS integration.
Terraform reduced the amount of code I had to write by approximately 67%. The biggest improvement was not having to manually manage resource creation order, retries, updates, and cleanup.

Step 2: Terraform Dependency Graph
Terraform identified a dependency between the Advisor launch template and the Application Load Balancer because the Advisor configuration references the Weather application's URL.
If the WEATHER_URL reference were removed, Terraform would no longer need that dependency to order the resources. However, the Advisor would lose the configured Weather application URL and might no longer retrieve forecast information correctly.

Step 3: Terraform Idempotence
Running terraform plan again produced:
No changes. Your infrastructure matches the configuration.
In Lab 06, the Bash script checked whether resources already existed and skipped creating them again. Terraform went further by comparing the actual infrastructure with the configuration, allowing it to detect incorrect settings and configuration drift.

Step 4: Updating the Weather Cache
Changing cache_seconds from 600 to 60 produced:
Plan: 0 to add, 2 to change, 0 to destroy.
Terraform updated the Weather launch template and Auto Scaling Group. The instance refresh completed successfully, and the new configuration was verified as CACHE_SECONDS=60.
With Bash, this required changing the environment configuration and manually managing the instance replacement. With Terraform, I only needed to change the setting, review the plan, and apply it. The original 600-second setting was restored afterward.

Step 5: Configuration Drift
I manually changed the Weather target group's health check path from / to /nope. Terraform detected the change and repaired it after applying the plan.
I also manually deleted the Advisor listener on port 8081. Terraform detected the missing listener and showed 1 to add. Applying the configuration restored the listener and the Advisor returned HTTP 200.
Unlike Lab 06's ensure_target_group function, which mainly checked whether the target group existed, Terraform checked whether the resource matched its intended configuration.

Step 6: IAM Least Privilege
In this experiment, I used the IAM policy simulator to test the permissions assigned to the Weather and Advisor applications. The Weather role was allowed to perform dynamodb:PutItem but denied access to ssm:GetParameter. Meanwhile, the Advisor role was allowed to perform ssm:GetParameter but denied access to dynamodb:GetItem.
These results confirmed that each application only had access to the AWS resources it needed. If an attacker compromised the Advisor instance, they could potentially access the Gemini API key, but they would not have permission to read the Weather application's DynamoDB table through that role. This demonstrated how least-privilege permissions help limit security risks.

Step 7: Terraform State and Secrets
Running terraform plan returned No changes, even though the Gemini parameter had been updated through the AWS CLI.

The command grep -c "AIza" terraform.tfstate returned 0.
However, an additional examination indicated that the parameter value was present in Terraform state. Therefore, the grep result alone did not prove that the state was free of secrets.
The ignore_changes setting prevented Terraform from planning to overwrite the externally updated parameter, but it did not guarantee that the parameter value would remain absent from state.
Without ignore_changes, a subsequent Terraform apply could attempt to restore the configured placeholder value, replacing the working Gemini key. The state would then record the value managed by Terraform.
This shows why Terraform state and saved plan files must remain private, even when secret values are managed outside Terraform.

Step 8: Gemini Failure and Fallback
After replacing the Gemini API key with an invalid value, the Advisor returned fallback recommendations instead of failing.

Example results:
fallback - Wear a light jacket or a sweater over long sleeves.

Both test requests returned fallback advice. Restoring a valid key returned the source to gemini, using the gemini-3.1-flash-lite model.
Problem with silent fallback: If users never see an error and nobody monitors the application logs, a failed AI integration could go unnoticed. The application might continue returning basic recommendations even though Gemini has stopped working. Monitoring and alerts are important for detecting these failures.
Logging limitation: The required gemini_error journal entry could not be retrieved because SSH and AWS Systems Manager access were not configured. The fallback responses were verified, but the journal log evidence was not captured.

Step 9: Moving the Advisor to AWS Lambda
Moving the Advisor application from EC2 to AWS Lambda would eliminate the need for its launch template, Auto Scaling Group, instance profile, and EC2-specific security group rules. The existing Application Load Balancer, Advisor listener, Gemini parameter, and Weather infrastructure would remain. However, the Advisor would need a Lambda function, an execution role, invocation permissions, and a Lambda target group. The application code would also need to be modified to handle Lambda events.
With Lambda, I would no longer need to manually install Node.js, configure a systemd service, manage EC2 instance replacements, or maintain an Auto Scaling Group for the Advisor. Lambda would handle the servers, runtime hosting, and scaling, while Terraform would still manage the AWS resources and their configuration.
The biggest advantage would be having less infrastructure to maintain. However, Lambda would introduce new challenges, such as cold starts, execution time limits, and testing event-based requests. I would test the application using sample Lambda events, valid and invalid ZIP codes, Gemini failures, and requests through the load balancer.
Overall, Terraform reduces the work involved in creating and maintaining infrastructure, while Lambda reduces the work involved in managing the servers that run the application.

Step 10: Destroy and Cost Estimate
Terraform successfully destroyed all 24 managed resources.
Destroy complete! Resources: 24 destroyed.
Verification confirmed that the Lab 07 EC2 instances, Auto Scaling Groups, load balancer, DynamoDB table, SSM parameter, IAM roles, and security group rules had been removed.
The Resource Groups Tagging API temporarily listed five security group rules, but individual EC2 checks confirmed all five no longer existed.
The lab estimated the infrastructure cost at approximately $0.07 per hour.
Using an illustrative runtime of six hours:
6 hours × $0.07/hour = $0.42
The actual deployment start time could not be recovered, so this is an illustrative estimate rather than an exact AWS charge.
Terraform simplified cleanup by replacing multiple Bash deletion scripts and retry procedures with one terraform destroy command.

Section 13.1 — Review Questions
1. Declarative vs. Imperative
Bash allowed me to control the exact sequence of AWS commands and write custom retry logic. Terraform automatically determined resource dependencies, detected configuration drift, and calculated the changes needed to maintain the infrastructure.

2. State File
If I lost the Terraform state file, Terraform would lose track of the resources it manages and could attempt to create duplicates. If two people applied changes using separate state files, they could create conflicting infrastructure changes. Teams avoid this by using shared remote state with locking and access controls.

3. Secrets in State
Secrets can enter state through resource attributes, variables, and outputs. A saved Terraform plan can also contain sensitive values because it records the changes Terraform intends to make. Both files must be protected and excluded from public repositories.

4. Plan Before Apply
Reading a Terraform plan helps prevent accidental deletions, unexpected replacements, and service interruptions. The -/+ symbol concerns me most because replacing a resource could cause downtime or data loss.

5. Version Pinning
Without version pinning, Terraform providers could update unexpectedly and introduce changes that break the configuration. Committing .terraform.lock.hcl helps everyone use consistent provider versions.

6. for_each vs. count
for_each assigns resources stable keys such as weather and advisor. Removing one tier does not shift the identity of another. With count, removing an item from a list can shift indexes and cause unnecessary changes.

7. Infrastructure Ownership
If Terraform and a person both modify the same resource, their changes can conflict. Terraform may overwrite manual modifications during the next apply. Infrastructure should generally be managed through Terraform, with manual changes restricted to authorized situations.

8. Drift Detection
A team could schedule Terraform plans through a CI/CD pipeline and configure alerts when unexpected changes are detected. Only authorized administrators should make manual infrastructure changes, preferably during approved emergency procedures.

9. Blast Radius
The blast radius depends on resource dependencies and which parts of the configuration reference a changed value. The cache update affected only the Weather tier. Separating infrastructure into smaller modules or independently managed states could reduce the impact further.

10. Least Privilege
Referencing a resource's ARN directly is safer than typing it manually because Terraform uses the actual resource identifier. This reduces mistakes and helps ensure permissions apply only to the intended resource.

11. Terraform and Lambda
Both Terraform and Lambda reduce infrastructure management work. Terraform manages the creation and configuration of resources, while Lambda executes application code without requiring server management. The most important difference is that Terraform is a deployment tool, while Lambda is a runtime service.

12. Destroy
In a production environment, I would protect critical databases, important storage resources, and other infrastructure that should not be accidentally removed. Terraform's prevent_destroy lifecycle setting can block destructive plans while the protection remains configured. Backups, restricted permissions, and separate production environments would provide additional protection.

What Terraform Did Not Make Easier
Terraform did not eliminate the need to understand AWS networking, IAM permissions, application configuration, or debugging. I still had to troubleshoot application behavior, validate API key access, and verify that the infrastructure worked correctly. Terraform automated resource management, but I remained responsible for designing and testing the system.

How Terraform Is Similar to Lambda
Both allow developers to focus more on the desired result and less on managing infrastructure details. Terraform handles infrastructure creation and dependencies, while Lambda handles application execution and server management.
The comparison stops because Terraform runs when infrastructure changes are requested, whereas Lambda runs application code in response to events. Terraform also maintains a state file, while Lambda functions should not rely on persistent local execution state.
