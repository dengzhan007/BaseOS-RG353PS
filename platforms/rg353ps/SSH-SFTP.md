# RG353PS SSH and SFTP

RG353PS provides two independent network-access functions: SFTP for file
transfer and interactive SSH for debugging. The USB and Wi-Fi transports are
managed by BaseOS; frontends must not start their own copies.

## Services

| Connection | Service | Address | Port | Configuration |
|---|---|---|---:|---|
| USB SSH (DC port) | Dropbear | `192.168.42.1` | 22 | `ssh_debug=yes` |
| Wi-Fi SSH | Dropbear | Current `wlan0` IPv4 address | 2222 | `ssh_debug=yes` |
| Wi-Fi SFTP | OpenSSH `sshd`, forced `internal-sftp` | Current `wlan0` IPv4 address | 22 | `wifi_sftp=yes` |

`ssh_debug` controls both interactive SSH listeners. Turning it off disables
USB SSH and Wi-Fi SSH together. `wifi_sftp` controls only Wi-Fi SFTP and is
independent of `ssh_debug`. Wi-Fi SFTP is chrooted to `/mnt/SDCARD`; it does
not provide an interactive shell.

## Configuration

Edit `/mnt/SDCARD/baseos.conf`:

```ini
ssh_debug=no
wifi_sftp=yes
```

The card-side file overrides the image defaults. Restart the device after
changing these settings.

## Credentials and security

Both SSH transports use the existing BaseOS `root` account and credentials.
The development image's default password is `root`; change it before exposing
interactive SSH to any network beyond a trusted test LAN. Public-key
authentication is supported through
`/mnt/SDCARD/baseos-ssh/authorized_keys`.

For Wi-Fi SFTP, connect with protocol SFTP, port 22, username `root`, and the
current BaseOS root credentials. The remote starting directory `/` maps to
`/mnt/SDCARD`.

For Wi-Fi interactive SSH:

```sh
ssh -p 2222 root@<wlan0-ip>
```

For USB interactive SSH, connect the cable to the DC port:

```sh
ssh root@192.168.42.1
```

See [the complete RG353PS network-access guide](../../docs/rg353ps-network-access.md)
for service lifecycle, chroot restrictions, DHCP changes and Mass Storage
interaction.
