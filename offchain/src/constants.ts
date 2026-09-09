/**
 * Domain separation tag for the threshold VRF signing scheme.
 *
 * Fixed for the lifetime of the protocol: it is baked into `VRFVerifier` as a
 * constant and must be byte-identical on the operator nodes. Changing it
 * invalidates every signature ever produced, so treat it as part of the
 * on-chain interface, not as configuration.
 */
export const DST = 'RH-VRF-BN254G1_XMD:KECCAK-256_SVDW_RO_V1_'

/** Order of the scalar field Fr of BN254. */
export const FR_ORDER =
    21888242871839275222246405745257275088548364400416034343698204186575808495617n
