Lab 06 - Weather Advisor in the Cloud
Application Testing and Results

The weather advisor application deployed successfully after usign two EC2 applications tiers behind an application load balancer, with PostgreSQL RDS for catching and Gemini for clothing recommendations. Both target groups became healthy, and the automated smoke test passed all 9 checks. 

Weather Data and Caching
The application makes two National Weather Service API calls because the first converts geogtpahic coordinats into a NWS forecastr grid locatoin, and the second retrieves the forecast for that location.
The PostgreSQL databse stored 3 weather lookup records for Chicago, New York City, and Beverly Hills. Repeated requests did not create additional records when valid cached data was available.
For Zip code 98101, the first time requested took 0.393 seconds, while the 2nd took 0.119 seconds. Caching helps a lot in reducing requests to external weather APIs and improves response time. However, weather information should not remain cached for too long because forecasts and conditions could change. 

Database Security and Availability
The RDS database used PostgreSQL on a db.t4g.micro instance, with encryption enabled, one Availability Zone, no public accessibility, zero backup retention, and no retained snapshots.
During the simulated database outage, the Weather API continued returning Chicago forecasts with cache: unavailable, while the history endpoint returned HTTP 503. The service logged a database connection timeout. After database access was restored, caching became available again.
The 30-second retry pause prevents repeated unsuccessful database connections during an outage, reducing unnecessary load and latency.

IAM and Network Security
IAM simulation confirmed that the Weather role could access only the database password parameter, while the Advisor role could access only the Gemini key parameter.
If an attacker compromised the Advisor instance, its IAM role would allow access to the Gemini key but not the database password.
Direct access to the Weather EC2 instance on port 3000 failed, while access through the ALB returned HTTP 200. A security group reference restricts access based on another resource's security group membership instead of allowing an entire IP address range.

Gemini Fallback
With an intentionally invalid Gemini API key, the Advisor returned three rule-based fallback recommendations. Its journal recorded Gemini HTTP 400 errors.
Silent fallback improves availability but could hide an ongoing AI service failure from users and administrators. The response includes a source field to distinguish AI-generated advice from rule-based advice.

Auto Scaling Recovery
The Weather instance was terminated to test Auto Scaling replacement. The recorded recovery time was 202 seconds, and subsequent weather requests returned cached data.
An Advisor request during the replacement process returned HTTP 200 because the Weather service was still reachable at that point. An HTTP 502 response during the actual outage window was not captured.
The replacement instance accessed the existing PostgreSQL cache, demonstrating why persistent application data should live outside replaceable EC2 instances.

Architecture and Design Decisions
Why Use AWS Systems Manager Parameter Store?
The Gemini API key and PostgreSQL password were stored as SecureString parameters instead of being placed directly in .env files or EC2 user-data. This reduces the risk of committing secrets to Git, exposing them in deployment scripts, or leaving them in instance startup configurations. Each EC2 IAM role was restricted to retrieving only the parameter required by its application.

Why Disable Database Backups?
Disabling automated backups and snapshots reduced unnecessary storage and backup costs for this temporary lab and made cleanup simpler. The disadvantage is that database data could be permanently lost if the instance fails or is deleted. This configuration would not be appropriate for production systems, important organizational records, or databases containing data that must be recoverable. Such systems should use automated backups, suitable retention periods, and tested restoration procedures.

Gemini Data and Free-Tier Considerations
The Advisor sent weather-related information, including the ZIP code and public forecast details, to Gemini to generate clothing recommendations. The application did not need to send user names, passwords, or private database records. The free tier matters because request quotas can restrict availability, and external service interruptions may require fallback behavior. Before using a paid or institution-owned account with real users, privacy requirements, data handling, access controls, and cost limits should be reviewed.

Section 15.1 — Security and Privacy Review
1. Secret storage: Secrets can still leak through terminal history, process arguments, application logs, screenshots, committed configuration files, or overly permissive IAM access. Sensitive values should never be printed or committed.
2. Least privilege: If both EC2 roles had ssm:* permissions on every resource, either compromised application could access both secrets and potentially modify or delete parameters. Restricting each role to one parameter reduces the impact of a compromise.
3. Network exposure: The ALB must accept public HTTP traffic so users can reach the applications. The EC2 application ports and PostgreSQL port should not be directly accessible from the internet because they are internal components.
4. Shared security group: Since both application tiers share one security group, an Advisor instance can establish network connections to the database even though its IAM role cannot read the password. A stronger design would use separate Weather and Advisor security groups and allow database access only from the Weather security group.
5. Database login: Using the PostgreSQL master account gives the application more permissions than it needs. A production system should use a dedicated database user with only the required permissions, such as SELECT and INSERT on the lookups table, along with the minimum access needed for normal operation.
6. Encryption: Encrypting database storage protects data at rest. TLS protects information in transit, while certificate verification additionally confirms that the application is communicating with the intended database server, reducing the risk of impersonation or interception.
7. SQL injection: Parameterized SQL queries keep user-supplied values separate from SQL commands. For example, a query using WHERE zip = $1 with the ZIP code supplied as a parameter prevents malicious input from changing the SQL structure. Joining raw user input into SQL strings could permit SQL injection.
8. Backups: Without backups, a database failure or accidental deletion could cause permanent loss of stored records. Important databases should use automated backups with an appropriate retention period and tested recovery procedures.
9. Data lifecycle: In a real organization, authorized data owners and administrators should establish retention and deletion policies based on business, legal, and regulatory requirements. An individual developer should not independently decide to destroy important data.
10. Untrusted AI output: Displaying raw model output as HTML could expose users to injected markup or malicious scripts. HTML escaping makes the recommendation display as text rather than executable page content.
11. Third-party data sharing: Before using Gemini with real users under a paid or school-owned account, the application would need an appropriate privacy notice, review of the provider's data handling terms, institutional approval where required, and controls limiting unnecessary personal information.
12. Abuse and cost: An attacker could repeatedly call the public Advisor endpoint and consume Gemini API quota or increase paid API usage. Rate limiting, authentication, AWS WAF, monitoring, and usage budgets could reduce this risk.
13. Availability: Reporting source: fallback and cache: unavailable helps users and operators understand when the application is running in a degraded state. Without these fields, failures could remain hidden despite apparently successful HTTP responses.

Cleanup Verification
After the experiments, the application stack and PostgreSQL database were deleted. AWS verification returned empty lists for the lab databases, snapshots, automated backups, load balancers, Auto Scaling Groups, launch templates, and IAM roles. The remaining Gemini SSM parameter was subsequently deleted, and the final parameter query returned an empty list.
