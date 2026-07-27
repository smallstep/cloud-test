# SSH device identity — how the gate works

Goal: `operator@<vm>` is reachable **only** with a hardware-attested Smallstep SSH
certificate. No static keys, no passwords. This is what
[`scripts/setup-ssh-identity.sh`](../scripts/setup-ssh-identity.sh) automates and
[`scripts/prove.sh`](../scripts/prove.sh) verifies.

```
Operator laptop (TPM)                        Cloud VM
─────────────────────                        ────────
Smallstep agent ── device-attest-01 ──► Smallstep CA
  issues, into the laptop TPM:
    SSH_USER cert (principal = your Smallstep identity / email)
  │
  ▼
ssh operator@vm ──cert──► sshd: TrustedUserCAKeys + AuthorizedPrincipalsFile
                                 → principal "you@example.com" maps to `operator`
```

The SSH cert's private key is generated in and never leaves the device's TPM. The
server trusts the **issuing CA**, not a pinned key — so any enrolled, high-assurance
device is admitted and a non-enrolled machine is refused.

## Part A — server side (per VM, automated by `setup-ssh-identity.sh`)

### A1. Trust the Smallstep SSH user CA

Get the SSH user CA public key in **OpenSSH** format (not X.509) on any enrolled
machine:

```bash
step ssh config --roots > smallstep-ssh-ca.pub
```

> ⚠️ A team can have more than one SSH **user** CA (e.g. a *workload* CA that signs
> servers' SSH certs and an *account* CA that signs operator/laptop certs). The CA
> that signs the **operator's** cert is the one that matters. Trust **every** CA
> that signs operator certs — `TrustedUserCAKeys` takes one key per line. Find a
> cert's signer with `ssh-keygen -L -f <cert>` → "Signing CA".

`sshd` is then told to trust it (additive — normal key auth is unaffected, so you
cannot lock yourself out):

```
# /etc/ssh/sshd_config.d/10-smallstep.conf
TrustedUserCAKeys /etc/ssh/smallstep_ca.pub
AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
MaxAuthTries 20    # an agent holding many identities trips the default cap of 6
```

### A2. Cert-only `operator` user

```bash
# reuse a historical `operator` group (GID 37) if present, else useradd fails
getent passwd operator || sudo useradd -m -s /bin/bash -g operator operator
# map the operator's cert principal (your Smallstep identity) → the operator login
sudo install -d -m 0755 /etc/ssh/auth_principals
echo 'you@example.com' | sudo tee /etc/ssh/auth_principals/operator
```

`operator` has **no password and no `authorized_keys`** — it is reachable only via a
valid SSH cert whose principal is listed in `auth_principals/operator`. The
provisioning admin user (`ubuntu` / `azureuser`) stays key-based and is *not*
cert-accessible (no `auth_principals` file), so you can set this up without risk of
lockout.

## Part B — operator (client) setup

1. **Configure the SSH_USER credential** on your Smallstep team (once): `kind: account`,
   `SSH_USER`, `HARDWARE_ATTESTED`, assurance `high`, principals include
   `smallstep:identity`. This is what makes the issued cert carry your identity as a
   principal and be issued only to a TPM-backed device.
2. **Enroll your laptop** into the team with the official Smallstep agent (TPM
   `device-attest-01`). Get the agent from
   <https://smallstep.com/docs/platform/smallstep-agent/>.
3. **Point SSH at the agent socket** — the agent exposes the hardware SSH cert
   through its SSH agent socket, which `ssh` consumes natively (no PKCS#11 needed):

   | OS | `SSH_AUTH_SOCK` |
   | --- | --- |
   | **Linux** (systemd) | `/run/ssh-agent.sock` |
   | **macOS** | `$HOME/Library/Application Support/Smallstep/step-ssh-agent.sock` |
   | **Windows** | `\\.\pipe\step-agent-ssh` (set as a *User* env var; new terminal) |

   Verify: `ssh-add -L` shows a cert whose principal equals your Smallstep identity.

   > **Windows:** the agent is a named pipe that **Git Bash's ssh cannot consume** —
   > use the **native Windows OpenSSH** (`C:\Windows\System32\OpenSSH\ssh.exe`, i.e.
   > `ssh` from PowerShell). `prove.sh` handles this automatically (it shells out to
   > the native `ssh.exe` for the positive test); if you drive SSH yourself on
   > Windows, run it from PowerShell, not Git Bash. Admin/provisioning connections
   > use your key (not the agent), so those work from either shell.

## Part C — prove it

```bash
ssh operator@<vm>            # ✅ logs in with no key/password (agent presents the cert)
```

Confirm server-side it was a certificate:

```bash
sudo journalctl -u ssh -n 20 | grep -i 'Accepted publickey for operator.*ID you@example.com.*CA'
```

Negative — from a machine (or shell) with **no agent and no key**, the same login is
refused:

```bash
ssh -o IdentityAgent=none -o IdentitiesOnly=yes -o PasswordAuthentication=no \
    operator@<vm>            # ❌ Permission denied (publickey)
```

`scripts/prove.sh <cloud>` runs both and prints a PASS/FAIL summary.

## Troubleshooting (each of these bit us once)

Read the **server** log for the real reason — `sudo journalctl -u ssh -n 30`:

| Client sees | Server log says | Cause → fix |
| --- | --- | --- |
| `Too many authentication failures` | many `…failed` | Agent holds many identities, server caps at `MaxAuthTries 6`. → set `MaxAuthTries 20` (A1). |
| `Permission denied (publickey)` | `Certificate invalid: <CA> not in …` | Operator cert signed by a CA the VM doesn't trust. → add that CA to `smallstep_ca.pub` (A1 dual-CA note). |
| `Permission denied (publickey)` | `…not in list of valid principals` | Cert principal ≠ `auth_principals/<user>`. → fix the mapping or the cert's principals. |

**Windows: `ssh` using the wrong agent.** If `ssh-add -L` shows old/personal certs,
`ssh` is talking to Windows OpenSSH's own agent, not the Smallstep pipe. Fix it **in
the shell you run `ssh` from**:

```powershell
$env:SSH_AUTH_SOCK = '\\.\pipe\step-agent-ssh'
[Environment]::SetEnvironmentVariable('SSH_AUTH_SOCK','\\.\pipe\step-agent-ssh','User')
ssh-add -L    # should now show a cert valid today
```

## Revocation

Remove the device from inventory (it stops renewing), or drop its principal from
`auth_principals/operator`. SSH certs are short-lived (24h), so access lapses fast.
