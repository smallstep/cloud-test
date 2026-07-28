# Scope

## In scope: two functions, three clouds

1. **ACME Device Attestation (`device-attest-01`)** — Enroll the cloud vTPM of
   each VM into Smallstep. Then the VM holds a hardware-attested device
   identity. The private key of this identity stays in the TPM.
2. **SSH device identity** — Permit `operator` login only with a
   hardware-attested Smallstep SSH certificate. Show that the server refuses
   access without this certificate.

The project uses three vTPM surfaces, with one VM for each surface:

- **AWS** NitroTPM
- **GCP** Shielded VM
- **Azure** Trusted Launch (Gen2 + vTPM + Secure Boot)

## Success criteria

- **Three VMs operate**, one for each cloud. Each VM has an attested vTPM
  device identity.
- **SSH device identity is the only access path.** You can log in to
  `operator@<vm>` with a hardware SSH certificate. You cannot log in without
  one. The script [`scripts/prove.sh`](../scripts/prove.sh) shows this on all
  three VMs. The script does a positive test and a negative test.

## Out of scope

We keep these items out. Thus the repository shows one clear story:

- **mTLS / HTTPS / REST** access (client-certificate gateways).
- **MCP** or other application-layer bridges.
- **Workload identity** (SPIFFE / OIDC).
- **Confidential computing** (SEV-SNP / TDX) as an identity root, and the EK
  lifecycle tests (reboot, stop-start, and redeploy).
- **Post-quantum** cryptography.

These items are for different documents.

## Notes

- **The hardware SSH certificate is the access control.** Port 22 is open by
  design. Thus you can show the refused login from each location. Network
  limits (a `/32` rule, a bastion) are an optional layer. They are not the
  gate.
- The admin user (`ubuntu` / `azureuser`) uses a key. This user cannot use a
  certificate. This user exists only for the initial configuration of the VM
  and `sshd`.
- This repository is a **reference demonstration**, not production IaC. Refer
  to the security notes in the README.
