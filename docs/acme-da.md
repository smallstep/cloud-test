# ACME Device Attestation — enroll the vTPM of the VM

Each VM shows that it is an approved device with its cloud **vTPM**. The VM
gets a Smallstep certificate. The vTPM **makes the private key** of this
certificate. The private key **does not go out of the vTPM**. The script
[`scripts/enroll-acme-da.sh`](../scripts/enroll-acme-da.sh) does this procedure
automatically. The procedure uses **official software only, with no custom
client code**.

## The flow

```
Terraform/Bicep VM  ──►  EKpub  ──►  Smallstep inventory (device registered + approved)
   (vTPM, UEFI)          identifier = urn:ek:sha256:base64(sha256(DER EKpub))
        │
        └─►  step-agent (official pkg)  ──►  ACME device-attest-01 (tpm)  ──►  Smallstep Devices CA
                team + Agents-CA fingerprint    proves possession of the EK      issues a leaf for a
                                                + the AK lives in the same TPM   TPM-resident key
```

1. **Register the EK of the device** in your Smallstep inventory as an approved
   identity. The inventory identifier is `urn:ek:sha256:` + the base64 value of
   the SHA-256 hash of the DER `SubjectPublicKeyInfo` of the EK public key. You
   can register this value before the first contact. As an alternative, let the
   agent send the EK on the first contact. Then approve the device in the
   inventory.
2. **Install `step-agent`.** Write this configuration to
   `/etc/step-agent/agent.yaml`:
   ```yaml
   team: <your-team-slug>
   fingerprint: <your-Agents-CA-fingerprint>
   ```
3. The agent does the **ACME `device-attest-01`** (TPM) procedure. The
   procedure shows that the agent controls the EK. The **Devices CA** then
   issues a leaf certificate. The private key of this certificate stays in the
   TPM.

`step-agent` **contains the TPM / `device-attest-01` function**. You do not
need `step-kms-plugin`. The command `step ca certificate` cannot do the hosted
attested flow. It stops with an error message about `--attestation-ca-url`.

## Get the EK identifier (to register the device)

The most simple method operates on all three clouds and does not use a
control-plane API: read the identifier **in the guest** after you install the
agent. The script `enroll-acme-da.sh` shows the identifier. To get the
identifier manually:

```bash
sudo step-agent tpm --fingerprint      # → urn:ek:sha256:…
```

The cloud control planes also give the EK public key. This is useful when you
register a device **before** its first boot:

- AWS: `aws ec2 get-instance-tpm-ek-pub --instance-id <id> --key-type rsa-2048
  --key-format der`
- GCP: `gcloud compute instances get-shielded-identity <name> --zone <zone>`

These values are the same as the in-guest EK. Azure has **no** control-plane
EK API. Use the in-guest method on Azure.

> **Agent version note.** The script `enroll-acme-da.sh` sets the version
> **`step-agent=0.67.3-1`**. Version **0.68.0** has a TPM AK-attestation
> malfunction. This malfunction causes a `404` error on GCP and Azure
> `device-attest-01`. AWS NitroTPM is not affected. After the upstream repair,
> set `STEP_AGENT_VERSION=` (empty, for the latest version).

## The certificate contents

Each device certificate has these properties:

- **Issuer:** the Smallstep **Devices** intermediate CA. **Provisioner:**
  `acme-da`.
- **Subject SANs:** a host ID (`urn:smallstep:host:id:…`) and the EK identifier
  (`urn:ek:sha256:…`). The EK identifier is the same as the registered
  inventory device.
- **Key:** ECDSA P-256. The private key **stays in the TPM**. The file
  `service.key` on the disk is absent or empty. The attestation showed that the
  device controls the key.
- **Assurance:** `highAssurance: true`. This value comes from the TPM
  `device-attest-01` attestation. It does not come from a confidential-compute
  function.

Examine the certificate on the VM:

```bash
sudo step certificate inspect /var/lib/step-agent/certificates/device/service.crt
```

## Portability note

The trust anchor that operates on all three clouds is the **EK public key in
the inventory** plus a **credential-activation possession proof**. The hash of
the EK public key (`urn:ek:sha256:…`) identifies the device. Some surfaces
also give an EK **certificate** chain. For example, GCP Confidential VMs get an
EK certificate with a Google root. This chain is better where it is available.
The EK public-key list is the base method that operates on all clouds.

> Cloud products and platform functions change frequently. Do the per-cloud
> commands again in a test before you use them.
