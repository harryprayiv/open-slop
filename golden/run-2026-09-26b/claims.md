## modules/system/homebeacon/default.nix

### Purpose

- The role listens on a port for client challenges, which must match the client's port setting.

### Interface

- The service validates the key at boot using a sign-and-verify round trip. [inferred]

### Behaviour

- The service performs a sign-and-verify round trip to validate the key. [inferred]


## modules/system/homebeacon/genkey.nix

### Purpose

- The script is intended to be run only on the workstation and not on the target system.

### Interface

- The script accepts an optional argument for the output directory, defaulting to the current directory if not provided. [inferred]

### Behaviour

- The script sets the permissions of the public key file to 644. [inferred]


## modules/system/homebeacon/keycheck.nix

### Interface

- The script accepts one argument, which is the path to the home beacon signing key. [inferred]
- The script uses an environment variable HOMEBEACON_PIN to specify the path to the public key pin. [inferred]


## modules/system/homebeacon/responder.nix

### Purpose

- The responder implements protocol version 2 as specified in tests/homebeacon.nix.

### Behaviour

- The responder binds the peer address into the signature to prevent relay attacks. [inferred]
- The responder signs a message containing the protocol version, nonce, and peer address. [inferred]

