# RG353PS network access

## Two independent services

The RG353PS image exposes two separate remote-access paths:

| Path | Service | Address | Purpose | Switch |
|---|---|---|---|---|
| Wi-Fi | OpenSSH `sshd` | Current IPv4 address on `wlan0`, TCP 22 | SFTP-only access to user data | `wifi_sftp=yes/no` |
| USB DC port | Dropbear | `192.168.42.1:22` | Interactive SSH for debugging | `usb_debug=yes/no` |

Wi-Fi SFTP is enabled by default and continues working when `usb_debug=no`.
Enabling USB debugging adds the USB Dropbear listener; it does not replace,
disable, or redirect the Wi-Fi SFTP listener. Both listeners can use TCP/22
because each binds to a different local IP address.

## Wi-Fi SFTP restrictions

The Wi-Fi listener starts after the user-data volume is mounted and waits for
`wlan0` to receive an IPv4 address. It follows DHCP address changes and stops
while the user-data volume is unmounted. Before USB mass-storage mode exports
the data partition, the storage helper stops the SFTP listener and active
sessions; it restarts the supervisor after attempting to remount the partition.

The OpenSSH server is configured to:

- accept only the existing `root` account;
- force `internal-sftp` for every session;
- chroot the session to `/mnt/SDCARD`;
- disable TCP/agent/X11 forwarding, tunnels, PTY allocation and user startup
  scripts.

The SFTP client therefore sees the user-data partition as its `/` directory.
It cannot browse the system root or obtain a shell through this Wi-Fi listener.
The same root password stored by the image is used for authentication; the
current default is `root`. This password is weak, so use the service only on a
trusted network and change the image password before distributing a build
outside a controlled test group. Public-key authentication is also supported
through `/mnt/SDCARD/baseos-ssh/authorized_keys`.

The chroot root on FAT/exFAT must appear root-owned and not writable by
group/others. The userdata mount uses `uid=0,gid=0,umask=022` to establish
those semantics without reformatting the filesystem.

## Settings

Edit `/mnt/SDCARD/baseos.conf`:

```ini
wifi_sftp=yes
usb_debug=no
```

- `wifi_sftp=yes` enables Wi-Fi SFTP independently.
- `wifi_sftp=no` disables only the Wi-Fi SFTP listener.
- `usb_debug=yes` enables the USB RNDIS/Dropbear SSH channel.
- `usb_debug=no` disables only the USB network/SSH channel.

The card-side configuration takes priority over the image defaults. Restart
the device after changing settings.

## Client connection

Find the handheld's current `wlan0` IPv4 address in the Wi-Fi status page or
your router's DHCP client list. Connect with an SFTP client using:

- Protocol: SFTP
- Host: the `wlan0` IPv4 address
- Port: `22`
- Username: `root`
- Password: the current BaseOS root password
- Remote starting directory: `/`

For USB debugging, connect the DC port and use SSH to `root@192.168.42.1`.
That interactive shell is deliberately not exposed on Wi-Fi.
