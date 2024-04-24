# Shiva (v1)

Shiva is an intermediary smart contract designed to facilitate interactions between users and multiple market smart contracts in Overlay ecosystem. 
Inspired by the multifaceted deity Shiva, this protocol aims to efficiently manage ownership of positions within various markets, offering additional functionalities such as building and unwinding positions on behalf of users.

## Features

- **Ownership Management**: Shiva manages ownership of positions within different markets, allowing seamless interaction between users and market smart contracts.
- **Building on Behalf Of**: Users can delegate others to build and unwinding positions on their behalf, enabling efficient portfolio management strategies.

## How It Works

Shiva Protocol acts as an intermediary between users and market smart contracts. 
When a user interacts with Shiva, they can set up allowances to enable other addresses to act on their behalf. 
This feature allows users to delegate the authority to build or unwind positions without directly interacting with the market smart contracts.

When a transaction is initiated through Shiva, the ownership of the position in the market smart contract will be attributed to Shiva. 
However, within Shiva's system, the ownership will be associated with the user who initiated the transaction (or the user the sender acted on behalf of). 
This mechanism ensures that users maintain control over their positions while leveraging the functionalities provided by Shiva.

To ensure security and prevent unauthorized actions, Shiva implements robust security mechanisms. 
These mechanisms verify that the allowed sender is executing transactions that align with the user's intentions. 
By enforcing strict authentication protocols (like signed messages from the user), Shiva mitigates the risk of malicious actors intervening in the transaction process, safeguarding users' assets and interests.

## Limitations

While Shiva Protocol offers powerful features for managing positions within supported markets, it comes with certain limitations:

- **Position Restriction**: Shiva can only handle positions that were initially built through its interface. If a user creates a position directly on the market smart contract without utilizing Shiva, the protocol cannot delegate the unwinding of that position. Users should ensure that all position interactions are conducted through Shiva to leverage its full capabilities effectively.

## Contributing

We welcome contributions from the community to improve and enhance Shiva - and Overlay. To contribute, please fork this repository, make your changes, and submit a pull request. 
For major changes, please open an issue first to discuss the proposed modifications.
