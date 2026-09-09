# ABI

Extracted from the compiled artifacts with `jq '.abi' out/<C>.sol/<C>.json`.

To regenerate:
`forge build && jq '.abi' out/VRFCoordinator.sol/VRFCoordinator.json > docs/frontend/abi/VRFCoordinator.json`

`VRFVerifier` is not needed by a front end — it is here for completeness.
