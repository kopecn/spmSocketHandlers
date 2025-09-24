# NIO Socket Wrapper for Handling ASCII over TCP

[![Swift](https://img.shields.io/badge/Swift-6.0+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20|%20Linux-lightgrey.svg)](https://swift.org)
[![SwiftNIO](https://img.shields.io/badge/SwiftNIO-2.0+-blue.svg)](https://github.com/apple/swift-nio)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Build Status](https://img.shields.io/badge/Build-Passing-brightgreen.svg)](#)

A lightweight Swift wrapper around SwiftNIO for handling ASCII text communication over TCP sockets. This library provides an easy-to-use interface for both client and server socket implementations with built-in connection state management and reactive publishers using OpenCombine.

## Features

- **Simple API** - Easy-to-use client and server socket handlers
- **ASCII Text Protocol** - Optimized for text-based communication
- **Connection State Management** - Built-in state tracking and notifications
- **SwiftNIO Powered** - High-performance asynchronous networking
- **Reactive** - OpenCombine publishers for state changes
- **Well Tested** - Comprehensive test suite included
- **Cross Platform** - Works on macOS and Linux


## Layout:

```mermaid
flowchart TD
    NIOHandler-->Logging[[Logging]]
    NIOHandler-->NIOCore[[NIOCore]]
    NIOHandler-->NIOPosix[[NIOPosix]]
    NIOHandler-->OpenCombine[[OpenCombine]]
    NIOHandler-->SocketCommon
    SocketCommon
    SocketHandlersTests{{SocketHandlersTests}}-->NIOHandler
```

## Example User Implementation for Client:

```mermaid
sequenceDiagram
    participant User as User Application
    participant Client as NIOSocketHandlerClient
    participant StateHandler as NIOClientConnectionStateHandler
    participant Publisher as connectionStatePublisher
    participant Handler as MessageHandler
    participant Channel as NIO Channel

    User->>Client: 1. Create NIOSocketHandlerClient(name, eventLoopGroup)
    Client->>Publisher: Initialize with .disconnected state
    
    User->>Client: 2. connect(host, port, messageHandler)
    Client->>Client: Queue on socketDispatchQueue
    Client->>Publisher: Send .connecting state
    
    Client->>Channel: 3. Bootstrap and connect
    Client->>StateHandler: Create NIOClientConnectionStateHandler
    Client->>Channel: Add handlers to pipeline
    
    alt Connection Successful
        Channel->>StateHandler: channelActive()
        StateHandler->>Publisher: onStateChange(.connected)
        StateHandler->>User: State change notification
        Client->>User: Connection established
    else Connection Failed
        Channel->>StateHandler: errorCaught()
        StateHandler->>Publisher: onStateChange(.error)
        StateHandler->>User: Error notification
    end

    User->>Client: 4. send(message)
    Client->>Channel: writeAndFlush(message + "\n")
    
    Channel->>Handler: 5. Incoming message
    Handler->>User: handleMessage(decodedString)
    
    User->>Client: 6. disconnect()
    Client->>Publisher: Send .disconnecting state
    Client->>Channel: close()
    
    Channel->>StateHandler: channelInactive()
    StateHandler->>Publisher: onStateChange(.disconnected)
    StateHandler->>User: Disconnection notification
    
    User->>Client: 7. shutdown() [optional]
    Client->>Client: Cleanup resources
    alt Owns EventLoopGroup
        Client->>Client: Shutdown EventLoopGroup
    end
```


## Planned:

- add timeout and reconnect handling.
- option for handling/tokenzing datastreams enabling modbus to plug in here.
- Some examples for easier community adoption.
