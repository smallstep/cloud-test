# SSH device identity — how the gate operates

Goal: you can log in to `operator@<vm>` **only** with a hardware-attested
Smallstep SSH certificate. There are no static keys and no passwords. The
script [`scripts/setup-ssh-identity.sh`](../scripts/setup-ssh-identity.sh) does
the configuration. The script [`scripts/prove.sh`](../scripts/prove.sh) does
the tests.

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

The TPM of the device makes the private key of the SSH certificate. The
private key does not go out of the TPM. The server trusts the **CA that issues
the certificates**, not one specified key. Thus the server accepts each
enrolled, high-assurance device. The server refuses a machine that is not
enrolled.

## Part A — server side (for each VM; `setup-ssh-identity.sh` does this)

### A1. Trust the Smallstep SSH user CA

Get the public key of the SSH user CA in **OpenSSH** format (not X.509). Do
this on an enrolled machine:

```bash
step ssh config --roots > smallstep-ssh-ca.pub
```

> ⚠️ A team can have more than one SSH **user** CA. For example, a *workload*
> CA signs the SSH certificates of servers, and an *account* CA signs the
> certificates of operators and laptops. The CA that signs the certificate of
> the **operator** is the important CA. Trust **each** CA that signs operator
> certificates. `TrustedUserCAKeys` accepts one key on each line. To find the
> CA that signed a certificate, use `ssh-keygen -L -f <cert>` and read
> "Signing CA".

Then configure `sshd` to trust the CA. This configuration is an addition. The
usual key authentication continues to operate. Thus you cannot lock yourself
out:

```
# /etc/ssh/sshd_config.d/10-smallstep.conf
TrustedUserCAKeys /etc/ssh/smallstep_ca.pub
AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
MaxAuthTries 20    # an agent that holds many identities goes past the default limit of 6
```

### A2. The `operator` user, certificate only

```bash
# reuse a historical `operator` group (GID 37) if present, else useradd fails
getent passwd operator || sudo useradd -m -s /bin/bash -g operator operator
# map the operator's cert principal (your Smallstep identity) → the operator login
sudo install -d -m 0755 /etc/ssh/auth_principals
echo 'you@example.com' | sudo tee /etc/ssh/auth_principals/operator
```

The `operator` user has **no password and no `authorized_keys`**. You can log
in as `operator` only with an applicable SSH certificate. The principal of the
certificate must be in `auth_principals/operator`. The admin user (`ubuntu` /
`azureuser`) uses a key. The admin user cannot use a certificate, because it
has no `auth_principals` file. Thus this procedure cannot lock you out.

## Part B — operator (client) configuration

1. **Configure the SSH_USER credential** on your Smallstep team (one time):
   `kind: account`, `SSH_USER`, `HARDWARE_ATTESTED`, assurance `high`. Include
   `smallstep:identity` in the principals. Then the certificate contains your
   identity as a principal. The CA issues the certificate only to a device
   with a TPM.
2. **Enroll your laptop** into the team with the official Smallstep agent (TPM
   `device-attest-01`). Get the agent from
   <https://smallstep.com/docs/platform/smallstep-agent/>.
3. **Point SSH to the agent socket.** The agent gives the hardware SSH
   certificate through its SSH agent socket. `ssh` can use this socket
   directly. PKCS#11 is not necessary.

   | OS | `SSH_AUTH_SOCK` |
   | --- | --- |
   | **Linux** (systemd) | `/run/ssh-agent.sock` |
   | **macOS** | `$HOME/Library/Application Support/Smallstep/step-ssh-agent.sock` |
   | **Windows** | `\\.\pipe\step-agent-ssh` (set as a *User* env var; new terminal) |

   Make sure that the configuration is correct: the command `ssh-add -L` shows
   a certificate. The principal of this certificate is your Smallstep
   identity.

   > **Windows:** the agent is a named pipe. The `ssh` program of Git Bash
   > **cannot use this pipe**. Use the **native Windows OpenSSH**
   > (`C:\Windows\System32\OpenSSH\ssh.exe`; this is `ssh` in PowerShell). The
   > script `prove.sh` does this automatically. It uses the native `ssh.exe`
   > for the positive test. If you use SSH manually on Windows, use
   > PowerShell, not Git Bash. Admin connections use your key, not the agent.
   > Thus admin connections operate from both shells.

## Part C — the tests

```bash
ssh operator@<vm>            # ✅ logs in with no key/password (agent presents the cert)
```

Make sure on the server that the login used a certificate:

```bash
sudo journalctl -u ssh -n 20 | grep -i 'Accepted publickey for operator.*ID you@example.com.*CA'
```

Negative test — use a machine or a shell that has **no agent and no key**. The
server refuses the same login:

```bash
ssh -o IdentityAgent=none -o IdentitiesOnly=yes -o PasswordAuthentication=no \
    operator@<vm>            # ❌ Permission denied (publickey)
```

The script `scripts/prove.sh <cloud>` does the two tests and shows a PASS/FAIL
summary.

## Troubleshooting

Each of these problems occurred one time in our tests. Read the **server** log
to find the true cause — `sudo journalctl -u ssh -n 30`:

| Client sees | Server log says | Cause → repair |
| --- | --- | --- |
| `Too many authentication failures` | many `…failed` | The agent holds many identities. The server limit is `MaxAuthTries 6`. → Set `MaxAuthTries 20` (A1). |
| `Permission denied (publickey)` | `Certificate invalid: <CA> not in …` | A CA that the VM does not trust signed the operator certificate. → Add that CA to `smallstep_ca.pub` (A1, the note about more than one CA). |
| `Permission denied (publickey)` | `…not in list of valid principals` | The certificate principal is not in `auth_principals/<user>`. → Correct the map or the principals of the certificate. |

**Windows: `ssh` speaks to the incorrect agent.** If `ssh-add -L` shows old or
personal certificates, then `ssh` speaks to the agent of Windows OpenSSH, not
to the Smallstep pipe. Correct this **in the shell where you use `ssh`**:

```powershell
$env:SSH_AUTH_SOCK = '\\.\pipe\step-agent-ssh'
[Environment]::SetEnvironmentVariable('SSH_AUTH_SOCK','\\.\pipe\step-agent-ssh','User')
ssh-add -L    # should now show a cert valid today
```

## Revocation

To remove access, do one of these steps:

- Remove the device from the inventory. The certificate then does not renew.
- Remove the principal from `auth_principals/operator`.

The SSH certificates are valid for 24 hours. Thus access stops quickly.
