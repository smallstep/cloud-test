# Scope

## In scope — two features, three clouds

1. **ACME Device Attestation (`device-attest-01`)** — enroll each VM's cloud vTPM
   into Smallstep so the VM holds a hardware-attested device identity with a
   TPM-resident key.
2. **SSH device identity** — gate `operator` login on a hardware-attested Smallstep
   SSH certificate, and prove access is refused without it.

On three vTPM surfaces, one VM each:

- **AWS** NitroTPM
- **GCP** Shielded VM
- **Azure** Trusted Launch (Gen2 + vTPM + Secure Boot)

## Success criteria

- **3 running VMs**, one per cloud, each with an attested vTPM device identity.
- **Access only via SSH device identity:** `operator@<vm>` logs in with a hardware
  SSH cert and **cannot** be reached without one — demonstrated by
  [`scripts/prove.sh`](../scripts/prove.sh) (positive + negative test) on all three.

## Explicitly out of scope

Kept out on purpose to keep this a single, clean story:

- **mTLS / HTTPS / REST** access (client-certificate gateways).
- **MCP** or any application-layer bridge.
- **Workload identity** (SPIFFE / OIDC).
- **Confidential computing** (SEV-SNP / TDX) as an identity root, and the
  EK-reliability lifecycle harness (reboot/stop-start/redeploy survival testing).
- **Post-quantum** anything.

Those are separate stories for separate write-ups.

## Notes

- The **hardware SSH cert is the access control**; port 22 is intentionally
  reachable so "refused without the cert" is demonstrable from anywhere. Network
  scoping (`/32`, bastion) is an optional layer on top, not the gate.
- The admin/provisioning user (`ubuntu` / `azureuser`) stays key-based and is not
  cert-accessible — it exists only to bring the box up and configure `sshd`.
- This is a **reference / demo**, not production IaC. See the README security notes.
