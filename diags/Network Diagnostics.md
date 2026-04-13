# Network Diagnostics

## Using tcpdump as a Simple Wireshark

For quick packet inspection without launching Wireshark, use `tcpdump` to capture and display network traffic in real-time.

### Basic Command

```bash
sudo tcpdump -i any -A 'port 50001' -n
```

### Flag Explanation

- `-i any` - Listen on all network interfaces
- `-A` - Print packet contents in ASCII (human-readable)
- `'port 50001'` - Filter traffic on port 50001
- `-n` - Don't resolve IP addresses to hostnames (faster)

### Usage

1. Run the command with sudo privileges
2. Monitor real-time traffic on the specified port
3. Press `Ctrl+C` to stop capture

### Example Output

The output shows:
- IP addresses and ports (e.g., `192.168.3.2.50001 > 192.168.3.1.51284`)
- TCP flags (`[P.]` = Push/Ack, `[.]` = Ack)
- Sequence and acknowledgment numbers
- Packet payload in ASCII format

### Useful Variations

```bash
# Capture specific host
sudo tcpdump -i any -A 'host 192.168.3.2' -n

# Capture to file for later analysis
sudo tcpdump -i any -w capture.pcap 'port 50001'

# Read from capture file
tcpdump -A -r capture.pcap

# More verbose output
sudo tcpdump -i any -A -vv 'port 50001' -n
```

### Tips

- Use `-X` instead of `-A` to show hex + ASCII output
- Add `-v`, `-vv`, or `-vvv` for increasing verbosity
- Combine filters: `'port 50001 and host 192.168.3.2'`
- Save to `.pcap` files to open in Wireshark later

---

## Port and Process Inspection

### List processes using a port

```bash
lsof -i :<port>
```

Example — who is listening on port 1234:

```bash
lsof -i :1234
```

Useful columns: `COMMAND` (process name), `PID`, `TYPE` (TCP/UDP), `NODE` (LISTEN, ESTABLISHED).

### Check socket state for a port

```bash
netstat -an | grep <port>
```

Example — all connections to/from port 1234:

```bash
netstat -an | grep 1234
```

Common states:
- `LISTEN` — server is bound and accepting connections
- `ESTABLISHED` — active connection
- `TIME_WAIT` — connection recently closed; port is in cooldown (prevents port reuse collisions)
- `CLOSE_WAIT` — remote end closed; local close pending

If a test fails with "address already in use", check for `TIME_WAIT` entries on the test port — the previous test run's socket is still cooling down. Wait a few seconds or change the port.

---

## Application-Level Diagnostics

`NIOSocketHandlerServer` and `NIOSocketHandlerClient` expose live state for in-process inspection:

```swift
// Active client IDs (Set<AnyHashable>)
server.connectedClientIDsPublisher.value

// Message counters
server.messagesReceived   // incremented by handleMessage
server.messagesSent       // incremented by send

// Connection state (SocketServerListeningState)
server.serverConnectionStatePublisher.value

// Client metrics snapshot
client.getMetrics()   // [String: Any] — messagesSent, messagesReceived,
                      // connectionAttempts, successfulConnections, etc.
```

These can be logged or exposed via a debug endpoint when diagnosing live issues without a packet capture.
