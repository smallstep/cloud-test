# ACME Device Attestation — enrolling the VM's vTPM

Each VM proves it is a genuine, attested device by its cloud **vTPM**, and gets a
Smallstep certificate whose private key is **generated in and never leaves the
vTPM**. This is the "secure" in "3 secure VMs." Automated by
[`scripts/enroll-acme-da.sh`](../scripts/enroll-acme-da.sh) — **official artifacts
only, no custom client code.**

## The flow

```
Terraform/Bicep VM  ──►  EKpub  ──►  Smallstep inventory (device registered + approved)
   (vTPM, UEFI)          identifier = urn:ek:sha256:base64(sha256(DER EKpub))
        │
        └─►  step-agent (official pkg)  ──►  ACME device-attest-01 (tpm)  ──►  Smallstep Devices CA
                team + Agents-CA fingerprint    proves possession of the EK      issues a leaf for a
                                                + the AK lives in the same TPM   TPM-resident key
```

1. **Register the device's EK** in your Smallstep inventory as an approved identity.
   The inventory identifier is `urn:ek:sha256:` + base64 of the SHA-256 over the EK
   public key's DER `SubjectPublicKeyInfo`. Either pre-register that value, or let
   the agent present the EK on first contact and approve the pending device.
2. **Install `step-agent`** and drop in `/etc/step-agent/agent.yaml`:
   ```yaml
   team: <your-team-slug>
   fingerprint: <your-Agents-CA-fingerprint>
   ```
3. The agent runs **ACME `device-attest-01`** (TPM), proving control of the EK, and
   receives a leaf from the **Devices CA** with a TPM-resident private key.

TPM / `device-attest-01` support is **built into `step-agent`** — you do not need
`step-kms-plugin`, and raw `step ca certificate` does **not** drive the hosted
attested flow (it errors asking for `--attestation-ca-url`).

## Getting the EKpub (to register the device)

| Cloud | EKpub source |
| --- | --- |
| **AWS** (NitroTPM) | control-plane: `aws ec2 get-instance-tpm-ek-pub --instance-id <id> --key-type rsa-2048 --key-format der` |
| **GCP** (Shielded VM) | control-plane: `gcloud compute instances get-shielded-identity <name> --zone <zone>` |
| **Azure** (Trusted Launch) | in-guest (no control-plane EKpub API): read the EK from the vTPM on the VM |

On AWS and GCP the control-plane EKpub equals the in-guest EK (verify by hashing
both) — so you can register the device **before** it ever boots your workload. Azure
has no control-plane EKpub API, so seed the identifier from the running VM.

## What you get

Each issued device certificate:

- **Issuer:** the Smallstep **Devices** intermediate CA · **Provisioner:** `acme-da`
- **Subject SANs:** a host id (`urn:smallstep:host:id:…`) and the EK identifier
  (`urn:ek:sha256:…`) that matched the registered inventory device
- **Key:** ECDSA P-256, **TPM-resident** — `service.key` is 0 bytes on disk because
  the private key lives in the vTPM and the attestation proved possession
- **Assurance:** `highAssurance: true`, from the TPM `device-attest-01` attestation
  itself (not from any confidential-compute feature)

Inspect it on the VM:

```bash
sudo step certificate inspect /var/lib/step-agent/certificates/device/service.crt
```

## Portability note

The portable trust anchor across all three clouds is the **EK public key in
inventory + a credential-activation possession proof**, identified by the EKpub
hash (`urn:ek:sha256:…`). Some surfaces additionally offer an EK **certificate**
chain (e.g. GCP Confidential VMs get a Google-rooted EK cert); where present that is
an upgrade, but the bare-EKpub allowlist is the baseline that works everywhere.

> Cloud SKUs and platform features move fast — re-verify the per-cloud commands
> before relying on them.
