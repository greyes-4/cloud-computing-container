# ITMO 444 Final Project
## Resume Builder with Gemini, S3 and Amazon SNS

**Student:** Gael Reyes
**Course:** ITMO 444 - Cloud Computing Technologies
**AWS Region:** us-east-2
**Completion Date:** November 23, 2026

## 1. Project Overview

The purpose of this project was to deploy a cloud-based
resume builder using Google Gemini and AWS services.

The application accepts an existing resume and a job
description as plain-text files. Gemini generates a
Harvard-style resume tailored to the job description.
Users can view the generated resume, download it as a
Microsoft Word document, or receive a download link
through email.

The supplied application code was deployed using
infrastructure and automation scripts adapted from Lab 04.

### Architecture

- Amazon EC2: Hosts the Uploader and Viewer applications.
- Application Load Balancer: Routes requests to each tier.
- Auto Scaling Groups: Automatically replace failed instances.
- Amazon S3: Stores generated JSON and DOCX files.
- AWS Systems Manager: Securely stores the Gemini API key.
- Amazon SNS: Delivers resume download links through email.
- AWS IAM: Provides separate least-privilege permissions.
- Google Gemini: Generates structured resume content.

The Uploader uses port 8080 and the Viewer uses port 8081.
Both applications listen internally on port 3000.

Each Auto Scaling Group maintains one EC2 instance.
The applications share persistent data through S3 rather
than communicating directly with each other.

## 2. Part A - Gemini API and Parameter Store

I created a dedicated Google AI Studio project and
successfully tested the gemini-3.1-flash-lite model.

The Gemini API key was stored in AWS Systems Manager
Parameter Store using the following configuration:

- Parameter: /itmo-444/gemini-api-key
- Type: SecureString
- Tier: Standard
- Region: us-east-2

The API key was not embedded in the application source
code or EC2 user-data. The Uploader retrieves the
encrypted parameter using its assigned IAM role.

## 3. Part B - Amazon SNS

### B2 and B3 - Topic and Subscription

I created the standard SNS topic resume-mailer-greyes.
I subscribed my school email address and verified that
the subscription initially displayed PendingConfirmation.

After confirming the subscription through email, the
subscription listing displayed a valid subscription ARN.

### B4 - Publishing a Test Message

The sender address of the SNS notification was
no-reply@sns.amazonaws.com.

The notification also included an unsubscribe link.

I created a temporary SNS topic without any subscribers
and published a test message. SNS accepted the message
and returned a message ID, but no email was delivered
because the topic had no confirmed subscribers.

The temporary topic was deleted after testing.

### B5 - Recipient Filter Policies

I configured the subscriptions to accept messages only
when the recipient message attribute matched the
subscribed email address.

The lab IAM permissions prevented me from modifying
existing subscription attributes. I resolved this by
creating the filtered subscription with its filter
policy included in the Subscribe request.

| Test | Recipient attribute | Expected | Observed |
|---|---|---|---|
| 1 | Matching email address | Delivered | Delivered |
| 2 | Different email address | Not delivered | Not delivered |
| 3 | No recipient attribute | Not delivered | Not delivered |

After allowing time for the filter policy to propagate,
only the matching test messages appeared in the inbox.

This prevents subscribers from receiving notifications
intended for other users.

### B6 - Pre-signed URL Experiment

I uploaded a sample text file to S3 and generated a
pre-signed URL with an expiration time of 600 seconds.

The URL successfully opened the file in a private
browser window without AWS authentication.

After the expiration period, the same URL returned an
AccessDenied error indicating that the request had expired.

This confirmed that pre-signed URLs provide temporary
access to private S3 objects without making the bucket
public.

## 4. Part C - Application Code Review

The Uploader validates uploaded files, retrieves the
Gemini API key, submits the resume and job description,
validates the generated JSON, creates a Word document,
and stores both output files in S3.

The Viewer validates resume identifiers, retrieves JSON
from S3, renders the resume, generates pre-signed URLs,
and manages SNS subscriptions and email notifications.

The applications also implement input validation,
HTML escaping, rate limiting, and friendly error pages.

## 5. Part D - Unit Testing

Both applications were tested locally using npm test.

| Application | Total Tests | Passed | Failed |
|---|---:|---:|---:|
| Uploader | 13 | 13 | 0 |
| Viewer | 13 | 13 | 0 |
| Total | 26 | 26 | 0 |

### Intentional Failure Experiment

I temporarily removed HTML escaping from the Viewer's
highlight function to verify that the tests could
detect a security vulnerability.

Two tests failed as expected:

- highlight bolds whole-word keywords and escapes
  everything else
- renderResume cannot be used to inject HTML

| Viewer Test Run | Passed | Failed |
|---|---:|---:|
| Original | 13 | 0 |
| HTML escaping removed | 11 | 2 |
| Original code restored | 13 | 0 |

After restoring the original application code, all
13 tests passed again.

### Unit Test Evidence

- evidence/uploader_tests_after_csp_fix.txt
- evidence/viewer_tests.txt
- evidence/viewer_intentional_failure.txt
- evidence/viewer_tests_restored.txt

## 6. Part E - Deployment

### E1 - Infrastructure Change Plan

The following changes were planned for the original
Lab 04 create_app_stack.sh script before deployment.

| Requirement | Original Script Lines | Planned Change |
|---|---|---|
| E2 | 3-4 | Retrieve the AWS account ID dynamically |
| E2 | 40-51 | Replace the Uploader IAM policy |
| E2 | 74-85 | Replace the Viewer IAM policy |
| E3 | 100-101 | Update application directory paths |
| E3a | 114, 117 | Compress app.js before base64 encoding |
| E3a | 133, 174 | Decode and decompress application code |
| E3b | 147-148 | Add Uploader environment settings |
| E3b | 188-189 | Add Viewer SNS configuration |
| E3c | 161-162, 202-203 | Check raw user-data sizes |
| E4 | 14-16 | Configure the S3 lifecycle rule |

### Final Implementation Locations

After implementing the changes, the line numbers in
create_app_stack.sh changed as follows:

| Requirement | Final Script Lines |
|---|---|
| E2 - AWS account ID | 5 onward |
| E2 - Uploader IAM policy | 64-77 |
| E2 - Viewer IAM policy | 104-121 |
| E3 - Application directories | 140 onward |
| E3a - Compression | 155-159 |
| E3a - Uploader decompression | 175-176 |
| E3a - Viewer decompression | 230-231 |
| E3b - Uploader settings | 191-194 |
| E3b - Viewer settings | 246-247 |
| E3c - Uploader byte check | 210-211 |
| E3c - Viewer byte check | 263-264 |
| E4 - S3 lifecycle | 19 onward |

### E2 - Least-Privilege IAM Policies

The previous Lab 04 policies were replaced with
permissions specific to the resume builder.

| Application | IAM Action | Resource | app.js Line |
|---|---|---|---|
| Uploader | s3:PutObject | arn:aws:s3:::itmo-444-544-gaelreyes-fileshare/resumes/* | 336, 338 |
| Uploader | ssm:GetParameter | arn:aws:ssm:us-east-2:284901686080:parameter/itmo-444/gemini-api-key | 94 |
| Viewer | s3:GetObject | arn:aws:s3:::itmo-444-544-gaelreyes-fileshare/resumes/* | 161, 168 |
| Viewer | sns:ListSubscriptionsByTopic | arn:aws:sns:us-east-2:284901686080:resume-mailer-greyes | 124 |
| Viewer | sns:Subscribe | arn:aws:sns:us-east-2:284901686080:resume-mailer-greyes | 136 |
| Viewer | sns:Publish | arn:aws:sns:us-east-2:284901686080:resume-mailer-greyes | 143 |

The Uploader does not have permission to read, list,
or delete S3 objects. Its SSM permission is restricted
to the specific Gemini parameter.

The Viewer does not have S3 bucket listing or write
permissions and cannot retrieve the Gemini API key.

Neither role uses unrestricted wildcard actions.

The deployed policies were retrieved through the AWS CLI
and saved in the following files:

- evidence/uploader_iam_policy.json
- evidence/viewer_iam_policy.json

### E3a - Application Compression

The app.js files were compressed using gzip before
being encoded with base64.

During instance initialization, the encoded files
were decoded and decompressed into /opt/app/app.js.

The package.json files continued to use ordinary
base64 encoding because of their smaller size.

### E3b - Environment Variables

Both applications receive BUCKET_NAME, AWS_REGION,
and PORT through their systemd service configurations.

The Uploader additionally receives the Gemini parameter
name, Gemini model, and Viewer listener port.

The Viewer receives the SNS topic ARN.

The actual Gemini API key is retrieved from SSM rather
than being included in the environment configuration.

### E3c - User-data Byte Counts

The AWS launch template user-data limit is 16,384 bytes.

| Application | Raw Bytes | Maximum | Result |
|---|---:|---:|---|
| Uploader | 10147 | 16384 | PASS |
| Viewer | 7744 | 16384 | PASS |

Both final user-data files are below the individual
AWS launch template size limit.

### E4 - S3 Lifecycle Configuration

I configured an enabled lifecycle rule named
ExpireResumesAfterOneDay.

The rule applies to objects under the resumes/ prefix
and makes them eligible for expiration after one day.

This limits unnecessary storage and reduces the
retention period of generated resume data.

### E5 - Initial Deployment

The application infrastructure was successfully
deployed using create_app_stack.sh.

Both applications launched on separate EC2 instances
and both target groups became healthy.

The deployment output was saved in:

- evidence/deployment_output.txt

### E6 - Redeployment and Troubleshooting

During stack deletion, I encountered a ResourceInUse
error while removing the target groups.

I updated the deletion script to retrieve the current
instance IDs dynamically and retry target group
deletion while AWS completed dependent operations.

The stack was successfully removed and redeployed.
The SNS topic and SSM parameter were preserved between
deployments as required.

During functional testing, I also discovered that
the Uploader's Content Security Policy prevented the
browser from following the redirect to the Viewer
on port 8081.

I corrected the form-action policy to allow the
validated Viewer origin while retaining the other
security restrictions.

I created a new Uploader launch template version and
replaced the existing instance through Auto Scaling.

After the replacement became healthy, automatic
redirection worked successfully and all 13 Uploader
unit tests continued to pass.

### Deployment Evidence

- evidence/e6_delete_output.txt
- evidence/e6_cleanup_resumed.txt
- evidence/e6_redeployment_output.txt
- evidence/uploader_tests_after_csp_fix.txt

## 7. Part F - Live Application Testing

### F1 - Functional Test Results

| Test | Description | Observed Result |
|---|---|---|
| 1 | Generate a resume | Resume generated successfully. Automatic redirection worked after correcting the CSP configuration. |
| 2 | Download DOCX | Successfully downloaded and opened the formatted resume in Word. |
| 3 | Compare with original resume | Core facts were preserved, including employers, degree, dates, and the calculated 40 percent reporting time reduction. GPA was omitted, and some generated wording appeared to introduce unsupported claims about reporting documentation and least-privilege IAM. AI output requires human review. |
| 4 | First-time email subscription | SNS confirmation email received and subscription confirmed. |
| 5 | Send resume by email | Email delivered successfully with a one-hour pre-signed download link. |
| 6 | Open link in private browser | Download worked without AWS credentials, confirming that access depends on possession of the signed URL. |
| 7 | Two-recipient test | Each tested inbox received only its intended resume notification. |
| 8 | Invalid file uploads | PDF, binary TXT, empty, and oversized files were rejected with validation errors. |
| 9 | Prompt injection | The instruction to write a poem about cats did not prevent normal resume generation. |
| 10 | Cross-site scripting | Gemini omitted the injected script text from the generated resume. The literal rendering requirement was not demonstrated by this live test, but HTML escaping was independently verified through unit tests. |
| 11 | Email validation | The malformed address was rejected. The uppercase valid address was accepted and the application reported Sent. |
| 12 | Nonexistent resume ID | The Viewer displayed that the resume did not exist or had expired. |

### F2 - Intentional Failure Experiments

#### Experiment 1 - Remove SSM Permission

Change:
I temporarily removed ssm:GetParameter from the
Uploader's IAM policy.

User-facing result:
"The AI service could not be reached. Please try again."

Log result:
The application recorded a Gemini-related error
indicating that the instance role was not authorized
to perform ssm:GetParameter.

Resolution:
The original IAM policy was restored and verified.

Evidence:
evidence/f2_ssm_failure.txt

#### Experiment 2 - Remove SNS Publish Permission

Change:
I temporarily removed sns:Publish from the Viewer's
IAM policy.

User-facing result:
"The email could not be sent. Please try again in a minute."

The generated resume remained accessible, but email
delivery failed.

Log result:
An AuthorizationErrorException indicated that the
Viewer role lacked permission to perform sns:Publish.

Resolution:
The original SNS permission was restored and verified.

Evidence:
evidence/f2_sns_failure.txt

#### Experiment 3 - Invalid Gemini API Key

Change:
I temporarily replaced the SSM parameter value with
an invalid API key.

User-facing result:
"The AI service could not be reached. Please try again."

Log result:
The application recorded a gemini_http_error
with HTTP status 400.

Resolution:
The original Gemini API key was securely restored
without displaying its value. Resume generation
and automatic redirection worked again.

Evidence:
evidence/f2_invalid_key_failure.txt

The reviewed failure logs did not expose resume
contents or the actual Gemini API key.

## 8. Part G - Resilience Testing

To test automatic recovery, I terminated the original
Viewer EC2 instance while keeping the generated resume
URL open in my browser.

| Property | Original Instance | Replacement Instance |
|---|---|---|
| Instance ID | i-0b5009b99e313adf1 | i-0043d30e05ce1ee8a |
| Final condition | Terminated | Healthy |
| Resume URL | Original | Unchanged |

The Auto Scaling Group automatically launched a
replacement Viewer instance.

Once the replacement passed its load balancer health
checks, I refreshed the original URL and verified
that the same generated resume remained accessible.

This demonstrated that the resume data was independent
of the individual EC2 instance.

If the Uploader had stored the generated resume only
in memory, the data would have depended on that
particular Uploader process remaining available.

Replacing or restarting the Uploader would lose that
data. Multiple Uploader instances could also hold
different state, making retrieval unreliable.

Using S3 allows either application to access the
required persistent data independently of instance
replacement.

### Resilience Evidence

- evidence/g_viewer_before.txt
- evidence/g_viewer_termination.txt
- evidence/g_viewer_after.txt
- evidence/g_viewer_healthy.txt

## 9. Part H - Final Cleanup

After completing the application demonstration and
recording the presentation, I executed both cleanup
scripts:

- delete_app_stack.sh
- cleanup_project.sh

The first script removed the application infrastructure.
The second removed the SNS topic and SSM parameter.

I then independently verified resource removal through
the AWS CLI.

| AWS Resource | Remaining | Result |
|---|---:|---|
| SNS topics | 0 | Cleared |
| SSM parameters | 0 | Cleared |
| Load balancers | 0 | Cleared |
| Auto Scaling Groups | 0 | Cleared |
| Active EC2 instances | 0 | Cleared |
| Target groups | 0 | Cleared |
| S3 buckets | 0 | Cleared |
| EBS volumes | 0 | Cleared |
| Elastic IP addresses | 0 | Cleared |

The verification confirmed that the listed project
infrastructure was removed.

Pre-existing resources from previous assignments were
not intentionally deleted.

### Cleanup Evidence

- evidence/delete_stack_output.txt
- evidence/cleanup_project_output.txt
- evidence/h_sns_topics.txt
- evidence/h_ssm_parameters.txt
- evidence/h_load_balancers.txt
- evidence/h_autoscaling_groups.txt
- evidence/h_ec2_instances.txt
- evidence/h_target_groups.txt
- evidence/h_s3_buckets.txt
- evidence/h_ebs_volumes.txt
- evidence/h_elastic_ips.txt
- evidence/h_launch_templates.txt
- evidence/h_iam_roles.txt
- evidence/h_security_groups.txt

## 10. Required Short Answers

### 1. How does SNS deliver the DOCX without attachments?

Amazon SNS does not support sending file attachments
directly through its email notifications. Instead,
the Viewer generates a pre-signed S3 URL that allows
the recipient to download the specific DOCX file.
The link expires after one hour and does not require
the recipient to have AWS credentials. The security
trade-off is that anyone who obtains the link can
download the document while the link remains valid.
Although the bucket stays private, the signed URL
must still be treated as sensitive information.

### 2. Why are SNS filter policies necessary?

The SNS filter policy ensures that each subscriber
only receives messages containing a recipient
attribute matching their email address. Without
this policy, publishing a message to the shared
topic would distribute it to all confirmed
subscribers. This would expose private resume
download links to unrelated users. Recipient
filtering allows multiple users to share one SNS
topic without automatically receiving each
other's resume notifications.

### 3. Why are generated resumes stored in S3?

Generated resumes are stored in S3 because EC2
instances are temporary and can be replaced by
Auto Scaling Groups. If the applications stored
resumes only in memory, restarting or replacing
an instance could permanently lose the generated
data. S3 provides independent persistent storage
that can be accessed by replacement instances.
This was demonstrated during resilience testing
when the original Viewer instance was terminated,
but the same resume URL worked again after its
replacement became healthy.

### 4. Why is the Gemini API key stored in SSM?

The Gemini API key is stored as a SecureString
parameter in SSM to keep sensitive credentials out
of application code and EC2 user-data. User-data
can be viewed by users with sufficient AWS
permissions to inspect launch templates or instance
configuration. Keeping the key in SSM allows
access to be controlled through IAM. The Uploader
role can retrieve the specific parameter, while
the Viewer role cannot. Authorized administrators
can also access it, but users without the necessary
permissions cannot retrieve its decrypted value.

### 5. Why are both prompt instructions and code
### validation necessary?

The prompt instructs Gemini to use only facts
contained in the original resume and to ignore
instructions embedded in uploaded files. However,
an AI model does not always follow its instructions
correctly. Application-level validation provides
an additional layer of protection by checking
JSON structure, data types, lengths, and keywords.
For example, the parser removes keywords that
do not appear in the job description, even if
Gemini includes them. These checks improve the
reliability of the output, but they cannot guarantee
that all generated statements are factual.
Human review is still necessary.

### 6. Why does the Viewer not have s3:ListBucket?

The Viewer only needs to retrieve individual resume
objects using their unique identifiers. It does not
need permission to list the contents of the bucket.
When a requested resume does not exist, S3 can
return AccessDenied because the Viewer does not
have ListBucket permission. The application handles
this response and displays a friendly message
stating that the resume does not exist or has
expired. Avoiding ListBucket reduces unnecessary
permissions and prevents the Viewer role from
enumerating all stored resume objects.

### 7. How could someone abuse the public application?

One possible abuse is repeatedly generating resumes
to exhaust the Gemini API quota or increase service
costs. The Uploader limits requests to 10 per hour
per visitor and 200 per day overall. A deployment
improvement would be to implement AWS WAF rate-based
rules and centralized request quotas.

Another possible abuse is using the email feature
to send unwanted SNS notifications. The Viewer
limits email requests to six per hour per visitor
and requires SNS subscription confirmation.
A deployment improvement would be to introduce
authenticated accounts with verified email ownership
before allowing email delivery. These additional
controls would reduce abuse beyond the existing
application-level rate limits.

## 11. Limitations and Future Improvements

Although the application was successfully deployed
and tested, several improvements would be appropriate
before using it in a production environment.

- Add HTTPS encryption to the public load balancer.
- Require authentication and resume ownership checks.
- Use centralized rate limiting across instances.
- Restrict administrative SSH access.
- Upgrade the deployed Node.js runtime and review
  dependency security warnings.
- Improve factual validation of AI-generated content.
- Introduce stronger controls for sensitive user data.

The deployed application was intended for educational
testing using synthetic resume information rather
than confidential personal documents.

## 12. Conclusion

This project demonstrated the deployment of an
AI-powered application using multiple AWS services.

I gained practical experience with cloud infrastructure,
least-privilege IAM policies, secure credential management,
SNS filtering, pre-signed URLs, automated deployment,
application testing, troubleshooting, and fault tolerance.

The application successfully generated resumes,
provided Word document downloads, delivered email
notifications, and recovered from an EC2 instance
replacement.

After completing the demonstration, all listed project
infrastructure was successfully removed and verified
through the AWS CLI.

## 13. Screenshot Evidence

| Screenshot | Description |
|---|---|
| 01_ssm_securestring.png | Encrypted SSM parameter |
| 02_sns_pending_confirmation.png | Pending SNS subscription |
| 03_sns_confirmed_subscription.png | Confirmed SNS subscription |
| 04_sns_filter_policy_inbox.png | Matching recipient messages |
| 05_resume_generated.png | Generated Harvard-style resume |
| 06_docx_download.png | Word document download |
| 07_docx_opened.png | Downloaded document opened |
| 08_email_confirmation.png | SNS confirmation email |
| 09_email_delivery.png | Resume email notification |
| 10_viewer_resilience.png | Resume available after instance replacement |

## 14. Presentation

The application demonstration and infrastructure
cleanup were recorded for the online student
presentation requirement.

## 15. Project Files

- uploader-app/ - Uploader source code and unit tests.
- viewer-app/ - Viewer source code and unit tests.
- samples/ - Synthetic resume and job description.
- previous/ - Original application files.
- evidence/ - Deployment, testing, and cleanup evidence.
- create_app_stack.sh - Automated AWS deployment.
- delete_app_stack.sh - Application infrastructure deletion.
- cleanup_project.sh - Final SNS and SSM cleanup.
- README.md - Project documentation and written responses.

