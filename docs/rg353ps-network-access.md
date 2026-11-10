# RG353PS network access

## Independent SFTP and debug SSH channels

The RG353PS exposes SFTP independently from interactive SSH. All three
listeners can coexist because they use separate TCP ports or local addresses:

| Path | Service | Address | Purpose | Switch |
|---|---|---|---|---|
| Wi-Fi SFTP | OpenSSH `sshd` | Current `wlan0` IPv4, TCP 22 | File transfer, chrooted to user data | `wifi_sftp=yes/no` |
| Wi-Fi SSH | Dropbear | Current `wlan0` IPv4, TCP 2222 | Interactive root shell for debugging | `usb_debug=yes/no` |
| USB DC port SSH | Dropbear | `192.168.42.1:22` | Interactive root shell for debugging | `usb_debug=yes/no` |

The `usb_debug` switch controls both interactive SSH listeners. When it is
`yes`, the device offers USB SSH and Wi-Fi SSH (provided Wi-Fi has an IPv4
address). When it is `no`, both shell-access paths stop.

Wi-Fi SFTP is not tied to `usb_debug`: it remains on TCP/22 when USB debugging
is disabled. The two Wi-Fi services use different ports so enabling the shell
does not change the SFTP port or its chrooted view of `/mnt/SDCARD`.

If Wi-Fi is disconnected or turned off, the Wi-Fi SFTP and Wi-Fi SSH listeners
are unavailable, but USB SSH continues to work as long as `usb_debug=yes`
and the USB RNDIS gadget is connected.

## Wi-Fi SFTP restrictions

The Wi-Fi listener starts after the user-data volume is mounted and waits for
`wlan0` to receive an IPv4 address. It follows DHCP address changes and stops
while the user-data volume is unmounted. Before USB mass-storage mode exports
the data partition, the storage helper stops the SFTP listener and active
sessions; it restarts the supervisor after attempting to remount the partition.

The OpenSSH server is installed from Alpine 3.22 at or above the fixed
`10.0_p1-r11` package revision. The image explicitly creates the locked
`sshd` privilege-separation account because APK install scripts are disabled
when assembling the minimal rootfs. Its runtime SFTP configuration is checked
inside the target rootfs during the build.
 
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
- `wifi_sftp=no` disables only Wi-Fi SFTP; it does not change SSH.
- `usb_debug=yes` enables both USB SSH and Wi-Fi SSH.
- `usb_debug=no` disables both interactive SSH listeners but leaves Wi-Fi
  SFTP unchanged.

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

For interactive SSH over Wi-Fi, set `usb_debug=yes` and connect to the
`wlan0` IPv4 address on port `2222`:

```sh
ssh -p 2222 root@<wlan0-ip>
```

For USB debugging, connect the DC port and use:

```sh
ssh root@192.168.42.1
```

Both interactive SSH paths use the existing root credentials. Enabling
`usb_debug` exposes a root shell to the local Wi-Fi network as well as USB;
use it only on a trusted LAN and disable it when debugging is complete.
