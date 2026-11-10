# RG353PS SSH and SFTP

The RG353PS image keeps Dropbear as its SSH server. SFTP is provided by
OpenSSH's standalone sftp-server executable, invoked by Dropbear as its SSH
subsystem. The image does not install or start a second SSH daemon.

## Connection

When the USB network/SSH channel is enabled:

| Setting | Value |
|---|---|
| Protocol | SFTP (or SSH) |
| Host | 192.168.42.1 |
| Port | 22 |
| User | root |
| Password | root |

SSH and SFTP share the same Dropbear listener, credentials and port. In
WinSCP or FileZilla choose SFTP, not FTP or FTPS. The channel remains
conditional on the existing BaseOS USB debug setting.

## Server implementation

The root filesystem installs Alpine's openssh-sftp-server subpackage only.
It supplies /usr/lib/ssh/sftp-server, which matches the path compiled into
Alpine's Dropbear build. The rootfs build validates that the executable is
present. OpenSSH sshd, its host keys and service scripts are not installed
or started.

## Writable locations

The root filesystem is read-only. Use /mnt/SDCARD for frontend files and
user data. The active boot volume at /mnt/boot contains system boot files
and should only be changed through the documented BaseOS/frontend update
paths. SFTP access does not change the volume ownership contract.
