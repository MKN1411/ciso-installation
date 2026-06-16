import os
import sys
import base64
import zipfile
import time
import oci

def log(message):
    print(f"[*] {message}")
    sys.stdout.flush()

def load_env():
    env_vars = {}
    # Load .env from parent directory
    env_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")
    if os.path.exists(env_path):
        with open(env_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    if "=" in line:
                        key, val = line.split("=", 1)
                        env_vars[key.strip()] = val.strip()
    else:
        print(f"[ERROR] .env file not found at {env_path}")
        sys.exit(1)
    return env_vars

def create_iac_zip():
    iac_dir = os.path.dirname(os.path.abspath(__file__))
    zip_path = os.path.join(iac_dir, "iac.zip")
    
    files_to_zip = ["main.tf", "variables.tf", "outputs.tf", "cloud-init.yaml"]
    
    log(f"Zipping IaC files into {zip_path}...")
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
        for file in files_to_zip:
            file_path = os.path.join(iac_dir, file)
            if os.path.exists(file_path):
                zipf.write(file_path, file)
                log(f" Added: {file}")
            else:
                print(f"[ERROR] Required file {file} is missing in {iac_dir}")
                sys.exit(1)
    return zip_path

def call_oci_with_retry(api_func, *args, **kwargs):
    max_retries = 6
    delay = 10
    for attempt in range(max_retries):
        try:
            return api_func(*args, **kwargs)
        except Exception as e:
            err_str = str(e)
            # Do not retry validation or client configuration errors
            if "Invalid parameter" in err_str or "Config file" in err_str or "authentication" in err_str.lower():
                raise e
            log(f"[WARNING] OCI API call failed: {e}. Retrying in {delay} seconds (Attempt {attempt+1}/{max_retries})...")
            time.sleep(delay)
            delay *= 2
    raise Exception("Max retries exceeded for OCI API call.")

def main():
    log("Starting OCI GRC Infrastructure Deployment...")
    env_vars = load_env()
    
    # 1. Setup OCI Configuration
    config = {
        "user": env_vars.get("OCI_USER_OCID"),
        "fingerprint": env_vars.get("OCI_FINGERPRINT"),
        "key_file": env_vars.get("OCI_KEY_FILE"),
        "tenancy": env_vars.get("OCI_TENANCY_OCID"),
        "region": env_vars.get("OCI_REGION", "eu-frankfurt-1")
    }
    
    # Validate OCI Config
    try:
        oci.config.validate_config(config)
        log("OCI Config successfully validated.")
    except Exception as e:
        print(f"[ERROR] Invalid OCI configuration: {e}")
        sys.exit(1)
        
    # 2. Package IaC files
    zip_path = create_iac_zip()
    with open(zip_path, "rb") as f:
        zip_bytes = f.read()
    encoded_zip = base64.b64encode(zip_bytes).decode("utf-8")
    
    # Clean up local zip file
    try:
        os.remove(zip_path)
    except OSError:
        pass

    # 3. Create OCI Resource Manager Client
    resource_manager_client = oci.resource_manager.ResourceManagerClient(config)
    compartment_id = env_vars.get("OCI_COMPARTMENT_OCID")
    
    # 4. Check if stack already exists
    log("Checking for existing OCI Resource Manager Stack...")
    stack_id = None
    try:
        # List stacks in compartment
        stacks_summary = call_oci_with_retry(
            oci.pagination.list_call_get_all_results,
            resource_manager_client.list_stacks,
            compartment_id=compartment_id,
            display_name="GRC-Assistant-Stack"
        ).data
        for s in stacks_summary:
            if s.lifecycle_state == "ACTIVE":
                stack_id = s.id
                log(f"Found existing active Stack. Stack OCID: {stack_id}")
                break
    except Exception as e:
        log(f"Warning searching for existing stack: {e}")

    ad_index = env_vars.get("OCI_AD_INDEX", "1") # Default to AD-2

    if stack_id:
        # Update existing stack configuration source and variables
        log("Updating existing OCI Resource Manager Stack...")
        update_stack_details = oci.resource_manager.models.UpdateStackDetails(
            config_source=oci.resource_manager.models.UpdateZipUploadConfigSourceDetails(
                zip_file_base64_encoded=encoded_zip
            ),
            variables={
                "compartment_ocid": compartment_id,
                "ssh_public_key": env_vars.get("SSH_PUBLIC_KEY"),
                "availability_domain_index": ad_index,
                "github_repo": env_vars.get("GITHUB_REPO", ""),
                "github_token": env_vars.get("GITHUB_TOKEN", ""),
                "oci_user_ocid": env_vars.get("OCI_USER_OCID", ""),
                "notification_email": env_vars.get("NOTIFICATION_EMAIL", "")
            }
        )
        try:
            call_oci_with_retry(resource_manager_client.update_stack, stack_id, update_stack_details)
            log("Stack configuration updated successfully.")
        except Exception as e:
            print(f"[ERROR] Failed to update stack: {e}")
            sys.exit(1)
    else:
        # Create new stack
        log("Creating OCI Resource Manager Stack...")
        create_stack_details = oci.resource_manager.models.CreateStackDetails(
            compartment_id=compartment_id,
            display_name="GRC-Assistant-Stack",
            description="Automated stack for M365 GRC Compliance platform deployment",
            config_source=oci.resource_manager.models.CreateZipUploadConfigSourceDetails(
                zip_file_base64_encoded=encoded_zip
            ),
            variables={
                "compartment_ocid": compartment_id,
                "ssh_public_key": env_vars.get("SSH_PUBLIC_KEY"),
                "availability_domain_index": ad_index,
                "github_repo": env_vars.get("GITHUB_REPO", ""),
                "github_token": env_vars.get("GITHUB_TOKEN", ""),
                "oci_user_ocid": env_vars.get("OCI_USER_OCID", ""),
                "notification_email": env_vars.get("NOTIFICATION_EMAIL", "")
            }
        )
        try:
            stack_response = call_oci_with_retry(resource_manager_client.create_stack, create_stack_details)
            stack = stack_response.data
            stack_id = stack.id
            log(f"Stack created successfully. Stack OCID: {stack_id}")
        except Exception as e:
            print(f"[ERROR] Failed to create stack: {e}")
            sys.exit(1)
        
    # Define fallback configurations (Shapes - Minimum 4 GB RAM required)
    shapes_to_try = [
        {"shape": "VM.Standard.A1.Flex", "ocpus": 2, "memory": 8}, # Always Free ARM
        {"shape": "VM.Standard.E4.Flex", "ocpus": 1, "memory": 4}  # Standard AMD Flex (Paid)
    ]
    
    # Define fallback Availability Domains (Location indices: 0 = AD-1, 1 = AD-2, 2 = AD-3)
    ad_tries = ["1", "2", "0"] # Prioritize AD-2, then AD-3, then AD-1
    if ad_index in ad_tries:
        ad_tries.remove(ad_index)
        ad_tries.insert(0, ad_index)

    log_file_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "deployment_errors.log")
    # Clear previous error log file
    try:
        if os.path.exists(log_file_path):
            os.remove(log_file_path)
    except OSError:
        pass

    def log_error_to_file(message):
        with open(log_file_path, "a", encoding="utf-8") as lf:
            lf.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}\n")

    deployment_success = False

    for shape_cfg in shapes_to_try:
        shape_name = shape_cfg["shape"]
        ocpus = shape_cfg["ocpus"]
        memory = shape_cfg["memory"]
        log(f"Starting deployment attempts with shape: {shape_name}...")

        for attempt, ad in enumerate(ad_tries):
            log(f"Attempting deployment in Availability Domain {int(ad)+1} (Index {ad}) using shape {shape_name}...")
            
            # Update Stack with shape and location parameters for this attempt
            update_stack_details = oci.resource_manager.models.UpdateStackDetails(
                variables={
                    "compartment_ocid": compartment_id,
                    "ssh_public_key": env_vars.get("SSH_PUBLIC_KEY"),
                    "availability_domain_index": ad,
                    "instance_shape": shape_name,
                    "instance_ocpus": str(ocpus),
                    "instance_memory_gbs": str(memory),
                    "github_repo": env_vars.get("GITHUB_REPO", ""),
                    "github_token": env_vars.get("GITHUB_TOKEN", ""),
                    "oci_user_ocid": env_vars.get("OCI_USER_OCID", ""),
                    "notification_email": env_vars.get("NOTIFICATION_EMAIL", "")
                }
            )
            try:
                call_oci_with_retry(resource_manager_client.update_stack, stack_id, update_stack_details)
                log("Stack variables updated successfully.")
            except Exception as e:
                err_msg = f"Failed to update stack variables for shape={shape_name}, AD={ad}: {e}"
                log(f"[ERROR] {err_msg}")
                log_error_to_file(err_msg)
                continue

            log(f"Triggering OCI Resource Manager APPLY Job (Shape: {shape_name}, AD Index: {ad})...")
            apply_details = oci.resource_manager.models.CreateApplyJobOperationDetails(
                operation="APPLY",
                execution_plan_strategy="AUTO_APPROVED"
            )
            create_job_details = oci.resource_manager.models.CreateJobDetails(
                stack_id=stack_id,
                operation="APPLY",
                job_operation_details=apply_details,
                display_name=f"GRC-Apply-{shape_name.split('.')[-1]}-AD{ad}"
            )
            
            try:
                job_response = call_oci_with_retry(resource_manager_client.create_job, create_job_details)
                job_id = job_response.data.id
                log(f"Job triggered successfully. Job OCID: {job_id}")
            except Exception as e:
                err_msg = f"Failed to trigger deployment job for shape={shape_name}, AD={ad}: {e}"
                log(f"[ERROR] {err_msg}")
                log_error_to_file(err_msg)
                continue
                
            # Monitor Job Status
            log("Monitoring deployment progress (polling every 10 seconds)...")
            while True:
                try:
                    job_status = call_oci_with_retry(resource_manager_client.get_job, job_id)
                    state = job_status.data.lifecycle_state
                    log(f"Current Job Status: {state}")
                    
                    if state in ["SUCCEEDED", "FAILED", "CANCELED"]:
                        break
                except Exception as e:
                    print(f"[WARNING] Error polling job status: {e}")
                    
                time.sleep(10)
                
            if state == "SUCCEEDED":
                log("Infrastructure deployed successfully!")
                deployment_success = True
                
                # Retrieve Outputs
                log("Fetching deployment output values...")
                try:
                    outputs_response = call_oci_with_retry(resource_manager_client.list_job_outputs, job_id)
                    outputs = outputs_response.data.items
                    
                    print("\n==================== DEPLOYMENT OUTPUTS ====================")
                    bastion_id = None
                    instance_private_ip = None
                    region = env_vars.get("OCI_REGION", "eu-frankfurt-1")
                    for out in outputs:
                        print(f"{out.output_name}: {out.output_value}")
                        if out.output_name == "bastion_id":
                            bastion_id = out.output_value
                        elif out.output_name == "instance_private_ip":
                            instance_private_ip = out.output_value
                    print("============================================================\n")
                    
                    # Create a ready-to-use Bastion port-forwarding session via OCI SDK
                    if bastion_id and instance_private_ip:
                        log("Creating OCI Bastion port-forwarding session automatically...")
                        try:
                            bastion_client = oci.bastion.BastionClient(config)
                            
                            # Use the SSH public key from the environment
                            ssh_pub_key = env_vars.get("SSH_PUBLIC_KEY", "").strip()
                            # OCI Bastion needs an OpenSSH format public key
                            # The portal generates SPKI format - wrap it properly if needed
                            if not ssh_pub_key.startswith("ssh-rsa") and not ssh_pub_key.startswith("ecdsa-") and not ssh_pub_key.startswith("ssh-ed25519"):
                                # Generate a new temporary key pair for the Bastion session
                                import subprocess
                                tmp_key = "/tmp/bastion_key"
                                subprocess.run(["ssh-keygen", "-t", "ed25519", "-f", tmp_key, "-N", "", "-C", "grc-bastion-session"], 
                                             capture_output=True)
                                with open(f"{tmp_key}.pub") as kf:
                                    ssh_pub_key = kf.read().strip()
                                with open(tmp_key) as kf:
                                    session_private_key = kf.read()
                                log("Generated temporary ED25519 key pair for Bastion session.")
                            else:
                                session_private_key = None
                            
                            session_details = oci.bastion.models.CreateSessionDetails(
                                bastion_id=bastion_id,
                                target_resource_details=oci.bastion.models.CreatePortForwardingSessionTargetResourceDetails(
                                    target_resource_port=8443,
                                    target_resource_private_ip_address=instance_private_ip
                                ),
                                key_details=oci.bastion.models.PublicKeyDetails(
                                    public_key_content=ssh_pub_key
                                ),
                                display_name="grc-web-session",
                                key_type="PUB",
                                session_ttl_in_seconds=10800
                            )
                            session_resp = call_oci_with_retry(bastion_client.create_session, session_details)
                            session_id = session_resp.data.id
                            log(f"Bastion session created. Session OCID: {session_id}")
                            log("Waiting for Bastion session to become ACTIVE (max 90s)...")

                            session_ssh_metadata = None
                            for _ in range(18):  # 18 x 5s = 90s
                                session_data = call_oci_with_retry(bastion_client.get_session, session_id).data
                                log(f"  Bastion session state: {session_data.lifecycle_state}")
                                if session_data.lifecycle_state == "ACTIVE":
                                    session_ssh_metadata = session_data.ssh_metadata
                                    break
                                time.sleep(5)

                            if session_ssh_metadata:
                                raw_cmd = session_ssh_metadata.get("command", "")
                                # Replace placeholder with actual port and note for private key
                                ssh_cmd = raw_cmd.replace("<privateKey>", "grc_oci_private_key.pem").replace("<localPort>", "8443")
                                print(f"\n==================== BASTION SSH COMMAND ====================")
                                print(ssh_cmd)
                                print("==============================================================\n")
                                print(f"[INFO] Führe diesen Befehl in PowerShell aus und öffne dann: https://localhost:8443")
                                sys.stdout.flush()
                                
                                if session_private_key:
                                    log("[INFO] Temporärer Private Key (für Bastion-Session):")
                                    print("-----BEGIN OPENSSH PRIVATE KEY-----")
                                    print(session_private_key)
                                    print("-----END OPENSSH PRIVATE KEY-----")
                            else:
                                log("[WARNING] Bastion session did not activate in 90s. Manual connection required.")
                                # Fallback: print manual connection instructions
                                print(f"\n[MANUAL] ssh -i grc_oci_private_key.pem -N -L 8443:{instance_private_ip}:8443 -p 22 {session_id}@host.bastion.{region}.oci.oraclecloud.com")

                        except Exception as e:
                            log(f"[WARNING] Bastion session creation failed: {e}")
                            # Fallback: Print instructions to connect via OCI Console
                            print(f"\n[MANUAL-FALLBACK] Connect via OCI Console Bastion > Sessions > Create Port Forwarding Session")
                            print(f"  Bastion OCID: {bastion_id}")
                            print(f"  Target Private IP: {instance_private_ip}")
                            print(f"  Target Port: 8443")
                    
                    log("Your CISO Assistant container is now starting via Cloud-Init. Check setup_status.json in your repo for progress.")
                except Exception as e:
                    print(f"[WARNING] Failed to fetch output details: {e}")
                break
            else:
                log(f"[WARNING] Deployment failed in AD Index {ad} with state: {state}. Fetching OCI job logs...")
                try:
                    # Fetch all logs using pagination helper to check for capacity/configuration errors
                    logs = call_oci_with_retry(
                        oci.pagination.list_call_get_all_results,
                        resource_manager_client.get_job_logs,
                        job_id
                    ).data
                    log_text = "\n".join([l.message for l in logs])
                    
                    # Log failure details to local error log file
                    log_error_to_file(f"--- FAILURE REPORT FOR shape={shape_name}, AD={ad} ---")
                    log_error_to_file(log_text)
                    log_error_to_file("----------------------------------------------------\n")
                    
                    # Check if the error is capacity / shape availability related
                    is_capacity_issue = any(kw in log_text for kw in [
                        "Out of host capacity",
                        "InternalError",
                        "NotAuthorizedOrNotFound",
                        "404-NotAuthorizedOrNotFound",
                        "LimitExceeded"
                    ])
                    is_instance_launch_failed = "LaunchInstance" in log_text or "oci_core_instance.grc_instance" in log_text
                    
                    if is_capacity_issue or is_instance_launch_failed:
                        log(f"[ALERT] Capacity limit or shape availability issue detected in AD Index {ad} for shape {shape_name}.")
                        log("Attempting next fallback option...")
                    else:
                        # Print last 30 lines of logs for critical syntax/configuration issues
                        print("\n==================== DEPLOYMENT ERROR LOGS ====================")
                        for log_entry in logs[-30:]:
                            print(f"[{log_entry.timestamp}] {log_entry.message}")
                        print("===============================================================\n")
                        print("[ERROR] Critical configuration or syntax error detected. Aborting fallback loop.")
                        sys.exit(1)
                        
                except Exception as e:
                    print(f"[ERROR] Could not fetch detailed logs: {e}")
                    sys.exit(1)
                    
        if deployment_success:
            break

    if not deployment_success:
        print("\n==================== DEPLOYMENT FAILURE ====================")
        print("[ERROR] ALL FALLBACK SHAPES AND AD COMBINATIONS EXHAUSTED.")
        print("[ERROR] Could not deploy the GRC infrastructure on OCI.")
        print(f"[ERROR] Detailed failure logs have been saved to:\n        {log_file_path}")
        print("============================================================\n")
        sys.exit(1)

if __name__ == "__main__":
    main()
