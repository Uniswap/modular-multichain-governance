# Modular Multichain Governance

Modular multichain message passing infrastructure for Uniswap Governance actions.

Bridge architectures and interfaces vary widely. This creates rifts between what governance signs
and what actually gets run on each chain. Defining an encoder-decoder layer separates the "calls
that need to run" from the "details of how this specific bridge works".

## Overview

To make the foundation concrete, we need governance to sign a collection of `Call`'s to be run on an
arbitrary chain. These `Call` items has a target address, a value (in ether) to send, and a calldata
payload to send use. Bridges use different interfaces and encodings to send and receive messages,
which we must account for. Bridges also serve as central points of failure in terms of security and
liveness. When security fails, invalid messages can be sent to our receiver contract. When liveness
fails, we cannot get messages to our receiver contract at all.

Everything we define below is directly in service of getting an array of `Call`'s from Ethereum to a
remote chain while solving for encoding, decoding, backstopping bridge security failures, and
mitigting bridge liveness failures.

### Bridge Registry

First, we define a `BridgeRegistry`. Authorizing the use of a given bridge requires the storage of a
unique identifier of the bridge. This identifier is derived from the hash of the bridge name and
stored on the `BridgeRegistry` with a two way lookup to avoid spelling ambiguity (ie "is it 'Op' or
'OP'?"). If it exists on the registry, it is correct.

```mermaid
---
config:
    theme: dark
    layout: elk
---
flowchart LR
    subgraph Ethereum
        direction LR
        BR(Bridge Registry):::eth

        WH(Wormhole):::eth
        PN(Polygon Native):::eth
        ON(Op Native):::eth
        
        BR -.-|0xaa..bb| WH
        BR -.-|Wormhole| WH
        BR -.-|0xaa..bb| PN
        BR -.-|Polygon Native| PN
        BR -.-|0xaa..bb| ON
        BR -.-|Op Native| ON
    end

    Ethereum:::eth_subgraph

    classDef eth_subgraph fill:#121212,stroke:#34beff,color:#fff
    classDef eth fill:#202020,stroke:#34beff,color:#fff

    linkStyle 0,1 stroke:#993b93
    linkStyle 2,3 stroke:#2f9c52
    linkStyle 4,5 stroke:#c44535
```

### Sender Hub

For sending messages from Ethereum, we define a `SenderHub`. This must be able to not only send a
message to any chain, it must be able to do so over any available bridge that passes Uniswap
Foundation's assessment. Therefore, we define a `MultichainAction` which contains a unique chain
identifier, a unique bridge identifier, and a collection of `Call`'s.

For a given chain and bridge, we must encode the `Call`'s before sending them over
the bridge, so governance stores an `Encoder` contract address for each chain-bridge pair which can
encode the `Call`'s and direct `SenderHub` to which bridge address must be called. Often, but not
always, the same `Encoder` logic can be re-used for the same bridge targeting different chains
(Wormhole targeting Celo vs Wormhole targeting Polygon).

```mermaid
---
config:
    theme: dark
    layout: elk
---
flowchart LR
    subgraph Polygon
        P_RH0(Receiver Hub):::polygon
    end
    subgraph Celo
        C_RH0(Receiver Hub):::celo
    end
    subgraph Op
        O_RH0(Receiver Hub):::op
    end

    subgraph Ethereum
        GB(Governor Bravo):::eth
        TL(Timelock):::eth
        SH(Sender Hub):::eth
        SH1(Sender Hub):::eth
        ONS[/OP Native Encoder/]:::eth
        WHS[/Wormhole Encoder/]:::eth
        PNS[/Polygon Native Encoder/]:::eth

        WH(Wormhole):::eth
        PN(Polygon Native):::eth
        ON(Op Native):::eth

        GB --> TL
        TL --> SH

        SH -.-> WHS -.-> SH1 --> WH
        SH -.-> PNS -.-> SH1 --> PN
        SH -.-> ONS -.-> SH1 --> ON

        WH --> P_RH0
        WH --> C_RH0
        WH --> O_RH0

        PN --> P_RH0
        ON --> C_RH0
        ON --> O_RH0
    end

    Ethereum:::eth_subgraph
    Polygon:::polygon_subgraph
    Celo:::celo_subgraph
    Op:::op_subgraph

    classDef core fill:#00000000,stroke:#f50db4,stroke-width:4
    classDef eth_subgraph fill:#121212,stroke:#34beff,color:#fff
    classDef polygon_subgraph fill:#121212,stroke:#993b93,color:#fff
    classDef celo_subgraph fill:#121212,stroke:#2f9c52,color:#fff
    classDef op_subgraph fill:#121212,stroke:#c44535,color:#fff

    classDef eth fill:#202020,stroke:#34beff,color:#fff
    classDef polygon fill:#202020,stroke:#993b93,color:#fff
    classDef celo fill:#202020,stroke:#2f9c52,color:#fff
    classDef op fill:#202020,stroke:#c44535,color:#fff

    linkStyle 11,14 stroke:#993b93
    linkStyle 12,15 stroke:#2f9c52
    linkStyle 13,16 stroke:#c44535
```

### Receiver Hub

For receiving messages to a remote chain, we define a `ReceiverHub`. This must be able to receive a
message from Ethereum over any available bridge that passes Uniswap Foundation's assessment. The
actual encoded calldata received varies by bridge, so we use the catch-all `fallback` function to
handle arbitrary calldata payloads from any given bridge.

For a given bridge forwarding a message to the `ReceiverHub`, the `RecevierHub` looks up a `Decoder`
associated with that bridge address. If it does not exist, the bridge is not authorized, so it
reverts. If it does exist, it forwards the bridge address, call value, and calldata into the
`Decoder`, which returns the decodes the data into the array of `Call`'s that was sent by the
`SenderHub`. After this, the `Call`'s are placed into staging where they may only be run after the
prerequisite security checks are performed.

> Context: **All bridged data is untrusted user input until proven otherwise.**

Different bridges and chains require different threat models, so we generalize over them using a
custom `Guard` contract, akin to Gnosis Safe's Guard modules.

When `ReceiverHub` receives a message from a bridge, it decodes it into `Call`'s, notifies the
`Guard` of which bridge called and what the decoded `Call`'s are, then places the `Call`'s into a
staging ground to be executed in another call.

When the `Call`'s are to be run, the `ReceiverHub` notifies the `Guard` and requests authorization
to run them. If `Guard` reverts, `ReceiverHub` must also revert. If `Guard` authorizes, then
`ReceverHub` iterates through the `Call`'s one by one.

```mermaid
---
config:
    theme: dark
    layout: elk
---
flowchart LR
    subgraph Polygon
        P_RH0(Receiver Hub):::polygon
        P_G[/Guard/]:::polygon
        P_RH1(Receiver Hub):::polygon
        P_WHD[/Wormhole Decoder/]:::polygon
        P_PND[/Polygon Native Decoder/]:::polygon
        subgraph PC[Core]
            P_V2F(V2 Factory):::polygon
            P_V3F(V3 Factory):::polygon
            P_PM(Pool Manager):::polygon
        end

        subgraph P_SEC[Security Check]
            P_RH1 <-.-> P_G
        end

        P_RH0 --> P_WHD
        P_RH0 --> P_PND
        P_WHD --> P_RH1
        P_PND --> P_RH1

        P_RH1 --> P_V2F
        P_RH1 --> P_V3F
        P_RH1 --> P_PM
    end
    subgraph Celo
        C_RH0(Receiver Hub):::celo
        C_G[/Guard/]:::celo
        C_RH1(Receiver Hub):::celo
        C_WHD[/Wormhole Decoder/]:::celo
        C_OND[/OP Native Decoder/]:::celo

        subgraph CC[Core]
            C_V2F(V2 Factory):::celo
            C_V3F(V3 Factory):::celo
            C_PM(Pool Manager):::celo
        end

        subgraph C_SEC[Security Check]
            C_RH1 <-.-> C_G
        end

        C_RH0 --> C_WHD
        C_RH0 --> C_OND
        C_WHD --> C_RH1
        C_OND --> C_RH1

        C_RH1 --> C_V2F
        C_RH1 --> C_V3F
        C_RH1 --> C_PM

    end
    subgraph Op
        O_RH0(Receiver Hub):::op
        O_G[/Guard/]:::op
        O_RH1(Receiver Hub):::op
        O_WHD[/Wormhole Decoder/]:::op
        O_OND[/OP Native Decoder/]:::op
        subgraph OC[Core]
            O_V2F(V2 Factory):::op
            O_V3F(V3 Factory):::op
            O_PM(Pool Manager):::op
        end

        subgraph O_SEC[Security Check]
            O_RH1 <-.-> O_G
        end

        O_RH0 --> O_WHD
        O_RH0 --> O_OND
        O_WHD --> O_RH1
        O_OND --> O_RH1
        O_RH1 --> O_V2F
        O_RH1 --> O_V3F
        O_RH1 --> O_PM
    end

    subgraph Ethereum
        WH(Wormhole):::eth
        PN(Polygon Native):::eth
        ON(Op Native):::eth

        WH --> P_RH0
        WH --> C_RH0
        WH --> O_RH0

        PN --> P_RH0
        ON --> C_RH0
        ON --> O_RH0
    end

    Ethereum:::eth_subgraph
    Polygon:::polygon_subgraph
    P_SEC:::sec_subgraph
    Celo:::celo_subgraph
    C_SEC:::sec_subgraph
    Op:::op_subgraph
    O_SEC:::sec_subgraph
    PC:::core
    CC:::core
    OC:::core

    classDef core fill:#00000000,stroke:#f50db4,stroke-width:4
    classDef eth_subgraph fill:#121212,stroke:#34beff,color:#fff
    classDef polygon_subgraph fill:#121212,stroke:#993b93,color:#fff
    classDef celo_subgraph fill:#121212,stroke:#2f9c52,color:#fff
    classDef op_subgraph fill:#121212,stroke:#c44535,color:#fff
    classDef sec_subgraph fill:#121212,stroke:#888,color:#fff

    classDef eth fill:#202020,stroke:#34beff,color:#fff
    classDef polygon fill:#202020,stroke:#993b93,color:#fff
    classDef celo fill:#202020,stroke:#2f9c52,color:#fff
    classDef op fill:#202020,stroke:#c44535,color:#fff

    linkStyle 24,27 stroke:#993b93
    linkStyle 25,28 stroke:#2f9c52
    linkStyle 26,29 stroke:#c44535
```

### Message Flow

Message flow is as follows:

- `GovernorBravo` queues a transaction on `Timelock`
- time passes
- `GovernorBravo` executes a transaction on `Timelock`
- `Timelock` sends the multichain actions to `SenderHub`
- for each multichain action:
  - `SenderHub` loads the `Encoder` for the multichain action
  - `SenderHub` sends the `Call` array to `Encoder`
  - `Encoder` returns the encoded data and bridge address
  - `SenderHub` calls the bridge with the encoded data
  - **bridge magic**
  - `ReceiverHub` is called by a bridge
  - `ReceiverHub` sends the encoded data to the `Decoder` for that bridge
  - `Decoder` returns the decoded `Call` array
  - `ReceiverHub` commits to this `Call` array on `Guard`
  - in another transaction
  - `ReceiverHub` is called to run the staged `Call` array
  - `ReceiverHub` calls `Guard` for authorization
  - `Guard` authorizes
  - `ReceiverHub` loops the `Call` array and dispatches those calls

```mermaid
---
config:
    theme: dark
---
sequenceDiagram
    box rgb(0% 15.8% 26.8%) Ethereum
        participant GovernorBravo
        participant Timelock
        participant SenderHub
        participant Encoder
        participant Bridge
    end

    box rgb(15.7% 0% 0%) Remote Chain
        participant Bridge2 as Bridge
        participant ReceiverHub
        participant Decoder
        participant Guard
        participant target
    end

    GovernorBravo ->> Timelock: queueTransaction
    GovernorBravo ->> Timelock: executeTransaction
    Timelock ->> SenderHub: sendMultichainActions

    loop For each MultichainAction
        SenderHub ->>+ Encoder: encode(Calls)
        Encoder ->>- SenderHub: (Bridge, bridgeData)

        SenderHub ->> Bridge: bridgeData

        Note over Bridge: Bridge May<br/>Encode Further
        Bridge -->> Bridge2: 
        
        Bridge2 ->> ReceiverHub: encoded
        ReceiverHub ->>+ Decoder: decode
        Decoder ->>- ReceiverHub: Calls

        ReceiverHub ->> Guard: commit

        ReceiverHub ->> Guard: authorize

        loop for each Call
            ReceiverHub ->> target: data
        end
    end
```

### API Sketch

```solidity
// Call type to be run
struct Call {
    address target;
    uint256 value;
    bytes data;
}

// Calls to be dispatched over a chain and bridge
struct MultichainAction {
    uint256 chainId;
    bytes32 bridgeId;
    Call[] calls;
}

// Sender Hub function to send the message
function sendMultichainActions(MultichainAction[] calldata actions) external;

// Receiver Hub function to run the calls
function runCalls() external;
```
