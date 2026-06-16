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

def save_github_secret(repo, token, secret_name, secret_value):
    import urllib.request
    import json
    import base64
    from nacl import encoding, public

    # 1. Get public key
    url = f"https://api.github.com/repos/{repo}/actions/secrets/public-key"
    req = urllib.request.Request(url, headers={
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github+json"
    })
    try:
        with urllib.request.urlopen(req) as response:
            pubkey_data = json.loads(response.read().decode())
            key_id = pubkey_data["key_id"]
            public_key_b64 = pubkey_data["key"]
    except Exception as e:
        print(f"[ERROR] Failed to fetch GitHub repo public key: {e}")
        return False

    # 2. Encrypt the secret
    try:
        public_key = public.PublicKey(public_key_b64.encode("utf-8"), encoding.Base64Encoder)
        sealed_box = public.SealedBox(public_key)
        encrypted = sealed_box.encrypt(secret_value.encode("utf-8"))
        encrypted_value = base64.b64encode(encrypted).decode("utf-8")
    except Exception as e:
        print(f"[ERROR] Failed to encrypt secret {secret_name}: {e}")
        return False

    # 3. Save the secret
    put_url = f"https://api.github.com/repos/{repo}/actions/secrets/{secret_name}"
    put_body = json.dumps({
        "encrypted_value": encrypted_value,
        "key_id": key_id
    }).encode("utf-8")
    put_req = urllib.request.Request(put_url, data=put_body, headers={
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/json"
    }, method="PUT")
    try:
        with urllib.request.urlopen(put_req) as response:
            status = response.status if hasattr(response, 'status') else response.getcode()
            if status in [200, 201, 204]:
                print(f"[+] Secret {secret_name} successfully saved to GitHub.")
                return True
    except Exception as e:
        print(f"[ERROR] Failed to save secret {secret_name} to GitHub: {e}")
    return False


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

def cleanup_existing_smtp_credentials(config):
    try:
        log("Checking for existing SMTP credentials in OCI to clean up / rotate...")
        identity_client = oci.identity.IdentityClient(config)
        # List credentials
        credentials = call_oci_with_retry(
            identity_client.list_smtp_credentials,
            user_id=config["user"]
        ).data
        
        for cred in credentials:
            # Check description or match
            if cred.description == "CISO Assistant SMTP Credentials":
                log(f"Deleting old SMTP credential: {cred.id} (Username: {cred.username})")
                call_oci_with_retry(
                    identity_client.delete_smtp_credential,
                    user_id=config["user"],
                    smtp_credential_id=cred.id
                )
                log(f"Successfully deleted old SMTP credential: {cred.id}")
    except Exception as e:
        log(f"[WARNING] Failed to clean up existing SMTP credentials in OCI: {e}")

def main():
    log("Starting OCI GRC Infrastructure Deployment...")
    env_vars = load_env()
    existing_smtp_user = env_vars.get("EXISTING_SMTP_USER", "")
    existing_smtp_password = env_vars.get("EXISTING_SMTP_PASSWORD", "")
    
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

    # 1.1 Cleanup existing credentials if rotation is triggered or new installation
    if config["user"] and not existing_smtp_password:
        cleanup_existing_smtp_credentials(config)
        
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
    
    # 3.1 Check if the Approved Sender already exists in OCI
    notification_email = env_vars.get("NOTIFICATION_EMAIL", "")
    create_email_sender = "true"
    if notification_email:
        try:
            log(f"Checking if Approved Sender already exists for email: {notification_email}...")
            email_client = oci.email.EmailClient(config)
            senders = call_oci_with_retry(
                email_client.list_senders,
                compartment_id=compartment_id,
                email_address=notification_email
            ).data
            if senders:
                log(f"Approved Sender for '{notification_email}' already exists in OCI (ID: {senders[0].id}). Skipping creation in Terraform.")
                create_email_sender = "false"
            else:
                log(f"Approved Sender for '{notification_email}' does not exist yet. Will create it.")
        except Exception as e:
            log(f"[WARNING] Failed to query OCI Approved Senders: {e}")
    
    # 4. Check if stack already exists
    log("Checking for existing OCI Resource Manager Stack...")
    stack_id = None
    existing_variables = {}
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
                try:
                    stack_details = call_oci_with_retry(resource_manager_client.get_stack, stack_id).data
                    existing_variables = stack_details.variables or {}
                except Exception as ex:
                    log(f"Warning reading existing stack variables: {ex}")
                    existing_variables = {}
                break
    except Exception as e:
        log(f"Warning searching for existing stack: {e}")

    # Load DEPLOYMENT_MODE from env or ciso_config.json
    deployment_mode = env_vars.get("DEPLOYMENT_MODE", "free_fallback")
    
    # Try to load from ciso_config.json if present
    config_json_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "ciso_config.json")
    if os.path.exists(config_json_path):
        try:
            with open(config_json_path, "r", encoding="utf-8") as f:
                import json
                ciso_cfg = json.load(f)
                deployment_mode = ciso_cfg.get("deployment_mode", deployment_mode)
                log(f"Loaded deployment mode '{deployment_mode}' from ciso_config.json")
        except Exception as ex:
            log(f"Warning reading ciso_config.json: {ex}")

    log(f"Deployment mode selected: {deployment_mode}")

    if deployment_mode == "reboot_existing":
        log("Rebooting the existing instance...")
        try:
            compute_client = oci.core.ComputeClient(config)
            instances = call_oci_with_retry(
                compute_client.list_instances,
                compartment_id=compartment_id,
                display_name="ciso-assistant-vps"
            ).data
            target_instance = None
            for inst in instances:
                if inst.lifecycle_state in ["RUNNING", "STOPPED"] and inst.compartment_id == compartment_id:
                    target_instance = inst
                    break
            if target_instance:
                log(f"Found instance: {target_instance.id} in state: {target_instance.lifecycle_state}")
                log("Sending REBOOT action to OCI Core API...")
                call_oci_with_retry(compute_client.instance_action, target_instance.id, "REBOOT")
                log("Reboot command sent successfully!")
                sys.exit(0)
            else:
                print("[ERROR] No active 'ciso-assistant-vps' instance found in compartment.")
                sys.exit(1)
        except Exception as e:
            print(f"[ERROR] Failed to reboot instance: {e}")
            sys.exit(1)

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
                "notification_email": env_vars.get("NOTIFICATION_EMAIL", ""),
                "create_email_sender": create_email_sender
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
                "notification_email": env_vars.get("NOTIFICATION_EMAIL", ""),
                "create_email_sender": create_email_sender
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
        
    # Detect actual running VM shape/AD to avoid Terraform destroying/recreating it
    try:
        compute_client = oci.core.ComputeClient(config)
        instances = call_oci_with_retry(
            compute_client.list_instances,
            compartment_id=compartment_id,
            display_name="ciso-assistant-vps"
        ).data
        
        # Find active instance
        active_vm = None
        for inst in instances:
            if inst.lifecycle_state in ["RUNNING", "STOPPED", "PROVISIONING"]:
                active_vm = inst
                break
        
        if active_vm:
            log(f"Detected live instance on OCI: {active_vm.id} (Shape: {active_vm.shape})")
            existing_variables["instance_shape"] = active_vm.shape
            if active_vm.shape_config:
                existing_variables["instance_ocpus"] = str(active_vm.shape_config.ocpus)
                existing_variables["instance_memory_gbs"] = str(active_vm.shape_config.memory_in_gbs)
            
            # Map AD name to index
            identity_client = oci.identity.IdentityClient(config)
            ads = call_oci_with_retry(identity_client.list_availability_domains, compartment_id).data
            for idx, ad in enumerate(ads):
                if ad.name == active_vm.availability_domain:
                    existing_variables["availability_domain_index"] = str(idx)
                    break
    except Exception as e:
        log(f"[WARNING] Could not query actual running instance shape: {e}")

    # Define shapes and AD tries based on deployment_mode
    shapes_to_try = [
        {"shape": "VM.Standard.A1.Flex", "ocpus": 2, "memory": 8}, # Always Free ARM
        {"shape": "VM.Standard.E4.Flex", "ocpus": 1, "memory": 4}  # Standard AMD Flex (Paid)
    ]
    ad_tries = ["1", "2", "0"] # Prioritize AD-2, then AD-3, then AD-1
    if ad_index in ad_tries:
        ad_tries.remove(ad_index)
        ad_tries.insert(0, ad_index)

    if deployment_mode == "free_only":
        shapes_to_try = [{"shape": "VM.Standard.A1.Flex", "ocpus": 2, "memory": 8}]
    elif deployment_mode == "paid_amd_4gb":
        shapes_to_try = [{"shape": "VM.Standard.E4.Flex", "ocpus": 1, "memory": 4}]
    elif deployment_mode == "paid_amd_8gb":
        shapes_to_try = [{"shape": "VM.Standard.E4.Flex", "ocpus": 1, "memory": 8}]

    # If stack exists, and we are not forcing a new install shape, preserve the existing configuration
    if stack_id and existing_variables.get("instance_shape") and existing_variables.get("availability_domain_index") is not None and deployment_mode not in ["free_only", "free_fallback", "paid_amd_4gb", "paid_amd_8gb"]:
        shapes_to_try = [
            {
                "shape": existing_variables.get("instance_shape"),
                "ocpus": int(existing_variables.get("instance_ocpus", "2")),
                "memory": int(existing_variables.get("instance_memory_gbs", "8"))
            }
        ]
        ad_tries = [str(existing_variables.get("availability_domain_index"))]
        log(f"Preserving existing shape '{shapes_to_try[0]['shape']}' and AD Index '{ad_tries[0]}' to avoid replacing the running instance.")

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
                    "notification_email": env_vars.get("NOTIFICATION_EMAIL", ""),
                    "create_email_sender": create_email_sender
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
                    
                    print("\n==================== DEPLOYMENT OUTPUTS ==================")
                    bastion_id = None
                    instance_private_ip = None
                    new_smtp_user = None
                    new_smtp_password = None
                    region = env_vars.get("OCI_REGION", "eu-frankfurt-1")
                    for out in outputs:
                        val_display = "[SENSITIVE]" if out.output_name == "smtp_password" else out.output_value
                        print(f"{out.output_name}: {val_display}")
                        if out.output_name == "bastion_id":
                            bastion_id = out.output_value
                        elif out.output_name == "instance_private_ip":
                            instance_private_ip = out.output_value
                        elif out.output_name == "smtp_username":
                            new_smtp_user = out.output_value
                        elif out.output_name == "smtp_password":
                            new_smtp_password = out.output_value
                    print("============================================================\n")

                    # Save SMTP credentials to GitHub Secrets if they were newly generated or rotated
                    github_token = env_vars.get("GITHUB_TOKEN")
                    github_repo = env_vars.get("GITHUB_REPO")
                    if not existing_smtp_password and new_smtp_user and new_smtp_password and github_token and github_repo:
                        log("Saving newly generated/rotated OCI SMTP credentials securely to GitHub Secrets...")
                        save_github_secret(github_repo, github_token, "OCI_SMTP_USER", new_smtp_user)
                        save_github_secret(github_repo, github_token, "OCI_SMTP_PASSWORD", new_smtp_password)
                    
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
