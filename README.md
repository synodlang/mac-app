# mac-app

The Synod Mac app: editor, animated player, Predict, Break it and Compare, Claude integration

See implementation/06-mac-app.md and 07-claude-integration.md in dsl.

## Why Synod

Synod is named after the Synod protocol, the core consensus algorithm in Leslie Lamport's paper "The Part-Time Parliament" (ACM Transactions on Computer Systems, 1998; first submitted in 1990). The paper tells it as the story of the parliament of the ancient Greek island of Paxos, whose part-time legislators could agree on decrees although they came and went; today the algorithm is known as Paxos. Lamport later explained it plainly in "Paxos Made Simple" (2001), and in 2013 he received the ACM A.M. Turing Award for fundamental contributions to the theory and practice of distributed and concurrent systems. His "Time, Clocks, and the Ordering of Events in a Distributed System" (1978) and his TLA+ specification language shaped how we reason about such systems. We are grateful for his work, and we hope Synod honours it by making these ideas easier to watch and understand. The app is a place to watch, predict and break these protocols.

Implements the Synod language specification v0.2.1: https://github.com/synodlang/dsl

Licensed under the [Apache License 2.0](LICENSE).
