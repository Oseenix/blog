---
title: "Keep SSH Connections Alive"
date: 2021-01-05T13:31:50-05:00

categories:
  - net
tags:
  - ssh

toc: true
draft: false
type: posts
---

SSH is an application-layer encrypted network protocol. It's used for remote login, remote command execution, and data transfer.

It consists of an SSH client and an SSH server. There are many implementations, with OpenSSH being the default on Ubuntu.
The client is `ssh`, and the server is `sshd`.
<!--more-->

## Passwordless Login

Check if `id_rsa.pub` exists in your local `~/.ssh/` directory. If not, create a public key locally:

```bash
ssh-keygen -t rsa
```

Then copy the local public key to the `~/.ssh/` directory on the remote machine and name it `authorized_keys`:

```bash
scp ~/.ssh/id_rsa.pub username@hostname:~/.ssh/authorized_keys
# or ssh-copy-id -i ~/.ssh/id_rsa.pub username@hostname
```

If the remote host is configured for passwordless login from multiple machines, it's better to append `id_rsa.pub` to `authorized_keys` instead of overwriting it:

```bash
cat ~/.ssh/id_rsa.pub | ssh username@hostname "cat >> ~/.ssh/authorized_keys" 
```

## Keep Connection Alive

### Server Configuration

Frequent SSH disconnections can be frustrating. You can configure the server to send a keep-alive packet to the client every 30 seconds to maintain the connection:

`vim /etc/ssh/sshd_config`

Add:

```ini
ClientAliveInterval 30
ClientAliveCountMax 6
```

The second line specifies that if the number of keep-alive packets reaches 6 and the client still doesn't respond, the `sshd` server will disconnect.
Restart `sshd`:

```bash
sudo service sshd restart
```

### Client Configuration

If you don't have permission to configure the server, you can configure the SSH client to keep all sessions alive:

Add the following to the `/etc/ssh/ssh_config` file:

```ini
ServerAliveInterval 30
ServerAliveCountMax 6
```

The local SSH client will send a keep-alive packet to the server's `sshd` every 30 seconds. If it sends 6 packets without a response, the connection will be dropped.
Below is the content from `man ssh_config`:

> **ServerAliveCountMax** Sets the number of server alive messages (see below) which may be sent without ssh(1) receiving any messages back from the server. If this threshold is reached while server alive messages are being sent, ssh will disconnect from the server, terminating the session. It is important to note that the use of server alive messages is very different from TCPKeepAlive (below). The server alive messages are sent through the encrypted channel and therefore will not be spoofable. The TCP keepalive option enabled by TCPKeepAlive is spoofable. The server alive mechanism is valuable when the client or server depend on knowing when a connection has become inactive.
>
> The default value is 3. If, for example, ServerAliveInterval (see below) is set to 15 and ServerAliveCountMax is left at the default, if the server becomes unresponsive, ssh will disconnect after approximately 45 seconds. This option applies to protocol version 2 only; in protocol version 1 there is no mechanism to request a response from the server to the server alive messages, so disconnection is the responsibility of the TCP stack.
>
> **ServerAliveInterval** Sets a timeout interval in seconds after which if no data has been received from the server, ssh(1) will send a message through the encrypted channel to request a response from the server. The default is 0, indicating that these messages will not be sent to the server, or 300 if the BatchMode option is set. This option applies to protocol version 2 only. ProtocolKeepAlives and SetupTimeOut are Debian-specific compatibility aliases for this option.

## Shared SSH Connection

To open multiple windows for the same server connection, try adding these two lines to `~/.ssh/config`:

```ini
ControlMaster auto
ControlPath ~/.ssh/%h-%p-%r
```

Once configured, subsequent connections will share the first established connection, speeding up the process.
Add persistent connection configuration:

```ini
ControlPersist 4h
```

Each time an SSH connection is established, it will be kept alive for 4 hours and can be reused even after you exit the server.

## Connection Forwarding

```ini
ForwardAgent yes
```

When a local client needs to connect to another server through a jump host, the jump host only acts as a relay during the authentication phase. Once authenticated, data is transferred directly between the client and the target server without passing through the jump host. Simply configure `ForwardAgent` as shown above.

The jump host must support forwarding:

```ini
AllowAgentForwarding yes
AllowTcpForwarding yes
```
