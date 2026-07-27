# Trust model — why you can't get in without the cert

Two hardware-rooted identities meet at the VM's `sshd`. Neither involves a static
key or a password.

## The two identities

| | Rooted in | Enrolled via | Used for |
| --- | --- | --- | --- |
| **VM device identity** | the VM's cloud **vTPM** (EK) | ACME `device-attest-01` | proving the VM is a genuine, attested device (Devices CA leaf, TPM-resident key) |
| **Operator device identity** | your **laptop TPM / Secure Enclave** | ACME `device-attest-01` | the **SSH_USER certificate** you log in with |

## What `sshd` actually trusts

`sshd` is configured with `TrustedUserCAKeys` pointing at the Smallstep **SSH user
CA** public key. That means:

- It trusts the **issuing CA**, not any specific key. Any certificate that CA signs
  — for any enrolled, high-assurance device — is accepted; a self-signed or
  unknown-CA key is not.
- The certificate must carry a **principal** listed in `auth_principals/operator`.
  The principal is your Smallstep identity (email), bound into the cert by the
  `SSH_USER` credential.
- There is **no `authorized_keys`** for `operator` and **no password**. Remove the
  cert path and there is no other way in.

So a login succeeds only if **all** of these hold:

1. You present a certificate (your agent does, from the laptop TPM).
2. It was signed by a CA in `TrustedUserCAKeys`.
3. It is unexpired (SSH certs here are 24h).
4. Its principal is mapped to `operator`.

Miss any one → `Permission denied (publickey)`.

## Assurance is enforced upstream, at issuance

The certificate can only exist for a hardware-backed device in the first place: the
Smallstep credential is `HARDWARE_ATTESTED` with assurance `high`, and issuance runs
`device-attest-01`, which requires proof that:

- the private key was generated **inside** a TPM/Secure Enclave (non-exportable), and
- the attestation key lives in the **same** hardware device.

A software key, a copied key, or a low-assurance device never gets a cert — so the
`sshd` gate is really the *tail end* of a chain that starts at silicon.

## Why the open port is fine

Port 22 is reachable from the internet on purpose, so "refused without the cert" is
demonstrable from anywhere. The network is **not** the control; the certificate is.
Narrowing ingress to a `/32` or fronting with a bastion is defense-in-depth layered
*on top of* the cert gate, not a substitute for it. (The admin user is key-based and
exists only for provisioning; harden or remove it for real use.)

## Revocation

- **Operator:** remove the device from inventory (its cert stops renewing) or drop
  its principal from `auth_principals/operator`. Short 24h lifetimes mean access
  lapses quickly without an explicit revocation list.
- **VM:** remove its EK from inventory; it can no longer re-attest or renew.
