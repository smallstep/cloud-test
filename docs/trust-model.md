# Trust model — why you cannot log in without the certificate

Two hardware identities come together at the `sshd` of the VM. No identity
uses a static key or a password.

## The two identities

| | Root | Enrollment | Function |
| --- | --- | --- | --- |
| **VM device identity** | the cloud **vTPM** of the VM (EK) | ACME `device-attest-01` | shows that the VM is an approved, attested device (Devices CA leaf; the key stays in the TPM) |
| **Operator device identity** | the **TPM / Secure Enclave** of your laptop | ACME `device-attest-01` | the **SSH_USER certificate** that you log in with |

## What `sshd` trusts

`sshd` has the configuration `TrustedUserCAKeys`. This configuration points to
the public key of the Smallstep **SSH user CA**. The effects are:

- `sshd` trusts the **CA**, not one specified key. `sshd` accepts each
  certificate that this CA signs. The CA signs certificates only for enrolled,
  high-assurance devices. `sshd` refuses a self-signed key and a key from an
  unknown CA.
- The certificate must contain a **principal** from the file
  `auth_principals/operator`. The principal is your Smallstep identity (an
  email address). The `SSH_USER` credential puts the principal into the
  certificate.
- The `operator` user has **no `authorized_keys`** and **no password**. If you
  remove the certificate path, no other path exists.

A login is successful only when all these conditions are true:

1. You give a certificate. Your agent does this with the key in the laptop
   TPM.
2. A CA in `TrustedUserCAKeys` signed the certificate.
3. The certificate is not expired. The SSH certificates here are valid for 24
   hours.
4. The principal of the certificate points to `operator`.

If one condition is not true, the result is `Permission denied (publickey)`.

## The CA enforces the assurance level at issuance

A certificate can exist only for a device with hardware protection. The
Smallstep credential is `HARDWARE_ATTESTED` with assurance `high`. The
issuance procedure does `device-attest-01`. This procedure needs proof of two
facts:

- The TPM or the Secure Enclave made the private key **inside** the hardware.
  The key cannot be exported.
- The attestation key is in the **same** hardware device.

A software key, a copied key, or a low-assurance device does not get a
certificate. The `sshd` gate is the last part of a chain that starts in the
silicon.

## Why the open port is acceptable

Port 22 is open to the internet by design. Thus you can show the refused
login from each location. The network is **not** the control. The certificate
is the control. A `/32` ingress rule or a bastion is an extra layer on top of
the certificate gate. It is not a replacement for the gate. The admin user
uses a key and exists only for the initial configuration. Make it more
restrictive, or remove it, for production use.

## Revocation

- **Operator:** remove the device from the inventory. The certificate then
  does not renew. As an alternative, remove the principal from
  `auth_principals/operator`. The certificates are valid for 24 hours. Thus
  access stops quickly without a revocation list.
- **VM:** remove the EK of the VM from the inventory. The VM then cannot
  attest again or renew.
