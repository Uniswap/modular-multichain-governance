# Modular Multichain Governance

Modular Multichain Governance is a system to pass messages from Ethereum L1 to L2's and other L1's
based on Uniswap governance decisions.

We define a `SenderHub` on Ethereum and a `ReceiverHub` on remote chains (L2's or other L1's), which are used to
abstract underlying bridge details for sending messages. The bridge details are abstracted by `Encoder` and `Decoder`
modules.

## Sending Messages

The `SenderHub` assigns an `Encoder` module for a given remote chain (by its `chainId`). When the `SenderHub` is called
by governance, it receives a list of multichain actions's. Each multichain action is a list of calls and a target chain
Id. For each multichain action, the `SenderHub` dispatches the respective `Encoder` for that chain, then the `Encoder`
returns to the `SenderHub` an address, call value, and encoded calldata such that the `SenderHub` can initiate the
bridge call. This ensures the `SenderHub` is always the caller on L1.

## Receiving Messages

The `ReceiverHub` assigns a `Decoder` module for a given calldata payload (by its selector). When the `ReceiverHub` is
called, it dispatches the encoded data to the respective `Decoder`, then the `Decoder` validates the data, decodes it,
and returns the originally sent list of calls for `ReceiverHub` to run. This ensures the `ReceiverHub` is always the
caller on the remote chain.

```mermaid
---
config:
    theme: 'dark'
---
flowchart LR

    subgraph Ethereum
        S0[SenderHub]
        S1[SenderHub]

        E0[/Encoder/]
        E1[/Encoder/]
        E2[/Encoder/]
        E3[/Encoder/]

        S0 --> E0 --> S1
        S0 --> E1 --> S1
        S0 --> E2 --> S1
        S0 --> E3 --> S1
    end


    BM{Bridge\nMagic}
    S1 -.-> BM
    BM -.-> RA0
    BM -.-> RB0

    subgraph RCA[RemoteChain]
        RA0[ReceiverHub]
        RA1[ReceiverHub]
        DA0[/Decoder/]
        DA1[/Decoder/]
        PA((Protocol))

        RA0 --> DA0 --> RA1
        RA0 --> DA1 --> RA1
        RA1 --> PA
    end
    subgraph RCB[RemoteChain]
        RB0[ReceiverHub]
        RB1[ReceiverHub]
        DB0[/Decoder/]
        DB1[/Decoder/]
        PB((Protocol))

        RB0 --> DB0 --> RB1
        RB0 --> DB1 --> RB1
        RB1 --> PB
    end

```

