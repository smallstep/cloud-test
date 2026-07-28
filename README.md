# Hardware-Attested SSH Across Three Clouds

This repository makes three cloud VMs: one on **AWS**, one on **GCP**, and one
on **Azure**. A **hardware-attested SSH certificate** is the only key that opens
a session on each VM. The VMs do not use static keys or passwords. Port 22 is
open, but you cannot log in without the certificate.

Each identity has its root in **TPM 2.0** hardware:

- **The VM** shows that it is an approved device with its cloud **vTPM**. The VM
  enrolls into [Smallstep](https://smallstep.com) through **ACME
  [`device-attest-01`](https://smallstep.com/docs/step-ca/provisioners/#acme)**.
  The vTPM makes the private key of the device certificate. The private key does
  not go out of the vTPM.
- **The operator** (you) logs in with an **SSH certificate**. The private key of
  this certificate stays in the TPM or the Secure Enclave of your laptop. The
  `sshd` server trusts the *CA that signs the certificates*, not one specified
  key. Thus the server accepts each enrolled, high-assurance device. The server
  refuses all other devices.

The repository shows two functions only: **ACME Device Attestation** and **SSH
device identity**.

```
Operator laptop (TPM)                          Cloud VM (vTPM)
─────────────────────                          ───────────────
Smallstep agent ── device-attest-01 ──►  Smallstep CA  ◄── device-attest-01 ── Smallstep agent
  issues SSH_USER cert                    (issues both)                          issues the VM's
  (key in laptop TPM)                                                            device cert (key in vTPM)
  │
  ▼
ssh operator@vm ──cert──► sshd: TrustedUserCAKeys + AuthorizedPrincipalsFile
                                → principal "you@example.com" maps to `operator`
no cert ─────────────────► Permission denied (publickey)
```

## Quick start

For each VM, do these steps: provision the VM, enroll the vTPM, configure the
SSH gate, and do the tests.

```bash
# 0. Prereqs (see below), then export your SSH public key and Smallstep team:
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
export STEP_TEAM=<your-team-slug>
export STEP_CA_FINGERPRINT=<your-Agents-CA-fingerprint>
export OPERATOR_PRINCIPAL=<the principal in your SSH cert, e.g. you@example.com>
export SSH_USER_CA_FILE=./smallstep-ssh-ca.pub      # from: step ssh config --roots

for CLOUD in aws gcp azure; do
  scripts/provision.sh          "$CLOUD"   # bring up the vTPM VM
  scripts/enroll-acme-da.sh     "$CLOUD"   # enroll its vTPM into Smallstep (device-attest-01)
  scripts/setup-ssh-identity.sh "$CLOUD"   # trust the SSH user CA + create the cert-only operator
  scripts/prove.sh              "$CLOUD"   # ✅ in with the cert · ❌ refused without it
done

scripts/teardown.sh all                    # leave nothing running
```

The script `prove.sh` gives the proof. It logs in as `operator` with the
hardware SSH certificate. It shows the server log line
`Accepted publickey ... ID <you> ... CA`. Then it tries the same login with
**no agent and no key**. It shows that the server refuses this login.

## Before you start

You must have these items:

- **Terraform** 1.5 or later (for AWS and GCP), the **Azure CLI** with Bicep
  (`az bicep install`), and `ssh`/`scp`.
- A **Smallstep** team (hosted or `step-ca`) with:
  - an **Agents CA** for `device-attest-01` enrollment. You supply the
    fingerprint of this CA.
  - an **SSH user CA**. The command `step ssh config --roots` writes its public
    key.
  - an **SSH_USER credential** with `HARDWARE_ATTESTED`, assurance `high`, and
    `smallstep:identity` in its principals. Refer to
    [docs/ssh-device-identity.md](docs/ssh-device-identity.md).
- A **laptop that is enrolled** into that team with the official Smallstep
  agent. Then your agent holds a hardware SSH certificate. The command
  `ssh-add -L` shows this certificate.
- The tools for each cloud that you use:
  - AWS: the `aws` CLI v2, and EC2 permissions that include
    `ec2:GetInstanceTpmEkPub`.
  - GCP: `gcloud`, and `export TF_VAR_project_id=<project>`.
  - Azure: `az`, and a subscription that permits Trusted Launch sizes.

## The three targets

| Cloud | vTPM surface | IaC |
| --- | --- | --- |
| **AWS** | NitroTPM (Intel Nitro) | [`terraform/aws/`](terraform/aws/) |
| **GCP** | Shielded VM | [`terraform/gcp/`](terraform/gcp/) |
| **Azure** | Trusted Launch (Gen2 + vTPM + Secure Boot) | [`azure/`](azure/) (Bicep) |

## Layout

```
terraform/aws/   terraform/gcp/     # AWS NitroTPM + GCP Shielded VM (Terraform)
azure/                              # Azure Trusted Launch (Bicep)
scripts/
  provision.sh                      # bring up one VM
  enroll-acme-da.sh                 # enroll its vTPM into Smallstep (device-attest-01)
  setup-ssh-identity.sh             # trust the SSH user CA + create the cert-only operator
  prove.sh                          # in with the cert; refused without it
  teardown.sh                       # destroy (per cloud, or `all`)
docs/
  ssh-device-identity.md            # how the SSH gate operates, server + operator sides
  acme-da.md                        # how the VM vTPM enrolls (device-attest-01), per cloud
  scope.md                          # what this repository is and is not
  trust-model.md                    # what is trusted, and why you cannot log in without the cert
```

## Security notes

This repository is a **reference demonstration**. It is not production IaC.
Read these notes before you use it:

- **The VMs increase the costs of your cloud account.** The scripts make real
  VMs. On AWS, the scripts also make an AMI copy and an EBS snapshot. A failed
  teardown is the primary risk. Always run `scripts/teardown.sh all`. Then
  examine the cloud console.
- **Port 22 is open to the internet by design.** Thus you can show "the server
  refuses a login without the certificate" from each location. The hardware SSH
  certificate is the access control. The admin user uses a key, not a password.
  To decrease the network exposure, set `ssh_ingress_cidr` / `sshIngressCidr`
  to your `/32` address. For production use, put a bastion in front of the VMs.
- **The `operator` user has sudo without a password.** This is for the
  demonstration only. For production use, make `sudoers.d/90-operator` more
  restrictive.
- **The CA enforces the assurance level.** The credentials are
  `HARDWARE_ATTESTED` with assurance `high`. Thus the CA issues certificates
  only to devices with a TPM or a Secure Enclave.
- **Revocation:** remove the device from the inventory, or remove its principal
  from `auth_principals`. The SSH certificates are valid for 24 hours. They stop
  when the CA does not renew them.

## License

[Apache-2.0](LICENSE).
