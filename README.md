# Hardware-Attested SSH Across Three Clouds

Three cloud VMs — one on **AWS**, one on **GCP**, one on **Azure** — where the
**only** way in is a **hardware-attested SSH certificate**. No static keys, no
passwords. Take the certificate away and you cannot log in, even though the port
is wide open.

Every identity here is rooted in a real **TPM 2.0**:

- **The VM** proves it is a genuine, attested device by its cloud **vTPM**, enrolled
  into [Smallstep](https://smallstep.com) via **ACME [`device-attest-01`](https://smallstep.com/docs/step-ca/provisioners/#acme)**.
  Its issued certificate's private key is generated in, and never leaves, the vTPM.
- **The operator** (you) logs in with an **SSH certificate whose private key lives
  in your laptop's TPM/Secure Enclave**. `sshd` trusts the *issuing CA*, not a
  pinned key — so any enrolled, high-assurance device is admitted and anything else
  is refused.

Two features, nothing else: **ACME Device Attestation** and **SSH device identity**.

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

## Quickstart

Per VM: **provision → enroll the vTPM → gate SSH on the cert → prove it.**

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

`prove.sh` is the deliverable: it logs in as `operator` using the hardware SSH cert
(and shows the server-side `Accepted publickey ... ID <you> ... CA` line), then
tries the same login with **no agent and no key** and shows it refused.

## Prerequisites

- **Terraform** ≥ 1.5 (AWS, GCP) · **Azure CLI** with Bicep (`az bicep install`) · `ssh`/`scp`
- A **Smallstep** team (hosted or `step-ca`) with:
  - an **Agents CA** (for `device-attest-01` enrollment) — you supply its fingerprint,
  - an **SSH user CA** — `step ssh config --roots` gives you its public key,
  - an **SSH_USER credential** configured `HARDWARE_ATTESTED`, assurance `high`,
    with `smallstep:identity` in its principals (see [docs/ssh-device-identity.md](docs/ssh-device-identity.md)).
- Your **laptop enrolled** into that team via the official Smallstep agent, so your
  agent holds a hardware SSH cert (`ssh-add -L` shows it).
- Per cloud you run: AWS (`aws` CLI v2, EC2 perms incl. `ec2:GetInstanceTpmEkPub`),
  GCP (`gcloud`, `export TF_VAR_project_id=<project>`), Azure (`az`, a subscription
  that allows Trusted Launch sizes).

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
  ssh-device-identity.md            # how the SSH gate works, server + operator sides
  acme-da.md                        # how the VM vTPM enrolls (device-attest-01), per cloud
  scope.md                          # what this repo is and is not
  trust-model.md                    # what is trusted, and why you can't get in without the cert
```

## Security notes

This is a **reference / demo**, not production IaC. Read before running:

- **It bills your cloud account.** Real VMs (and, on AWS, an AMI copy + EBS
  snapshot) are created. The dominant risk is a **failed teardown** — always run
  `scripts/teardown.sh all` and verify the console.
- **Port 22 is open to the internet by design** so you can prove "reachable, but
  refused without the cert" from anywhere. The hardware SSH cert is the access
  control; the admin/provisioning user is key-based (no passwords). Narrow
  `ssh_ingress_cidr` / `sshIngressCidr` to your `/32` for network-layer scoping on
  top, or front with a bastion for anything real.
- **`operator` has passwordless sudo** for demo convenience — tighten
  `sudoers.d/90-operator` for real use.
- **Assurance is enforced by the CA:** credentials are `HARDWARE_ATTESTED` +
  assurance `high`, so only TPM/Secure-Enclave-backed devices are ever issued a cert.
- **Revocation** = remove the device from inventory or drop its principal from
  `auth_principals`; SSH certs are short-lived (24h) and stop renewing.

## License

[Apache-2.0](LICENSE).
