import * as mcl from 'mcl-wasm'
import type { BlsBn254 } from '@kevincharm/bls-bn254'

/** One operator's share of the group secret. `index` is the Shamir x-coordinate (1-based). */
export interface Share {
    index: number
    secret: mcl.Fr
}

/** A share of a signature, produced by one operator for one message. */
export interface PartialSignature {
    index: number
    sig: mcl.G1
}

function frFromInt(n: number): mcl.Fr {
    const fr = new mcl.Fr()
    fr.setInt(n)
    return fr
}

/**
 * Shamir-split `secret` into `n` shares, any `t` of which reconstruct it.
 *
 * Only used for local/testnet setups and for tests. In production the shares
 * come out of a DKG and the full secret never exists on any single machine.
 */
export function splitSecret(_bls: BlsBn254, secret: mcl.Fr, t: number, n: number): Share[] {
    if (t < 1 || t > n) throw new Error(`bad threshold ${t} of ${n}`)

    const coefficients: mcl.Fr[] = [secret]
    for (let i = 1; i < t; i++) {
        const a = new mcl.Fr()
        a.setByCSPRNG()
        coefficients.push(a)
    }

    const shares: Share[] = []
    for (let index = 1; index <= n; index++) {
        const x = frFromInt(index)
        // Horner evaluation of the polynomial at x
        let acc = coefficients[coefficients.length - 1]
        for (let k = coefficients.length - 2; k >= 0; k--) {
            acc = mcl.add(mcl.mul(acc, x), coefficients[k])
        }
        shares.push({ index, secret: acc })
    }
    return shares
}

/** Sign `message` (already hashed to G1) with a single share. */
export function partialSign(_bls: BlsBn254, share: Share, message: mcl.G1): PartialSignature {
    const sig = mcl.mul(message, share.secret)
    sig.normalize()
    return { index: share.index, sig }
}

/**
 * Lagrange coefficients at x=0 for the given set of share indices.
 *
 * lambda_i = prod_{j != i} x_j / (x_j - x_i)
 */
function lagrangeCoefficients(indices: number[]): mcl.Fr[] {
    if (new Set(indices).size !== indices.length) throw new Error('duplicate share index')
    return indices.map((i) => {
        const xi = frFromInt(i)
        let acc = frFromInt(1)
        for (const j of indices) {
            if (j === i) continue
            const xj = frFromInt(j)
            acc = mcl.mul(acc, mcl.div(xj, mcl.sub(xj, xi)))
        }
        return acc
    })
}

/**
 * Interpolate partial signatures into the group signature.
 *
 * Given at least `t` honest partials this is exactly `sk * H(m)` — the unique
 * BLS signature of the group key. Fewer, or any corrupted partial, yields a
 * point that simply fails verification; there is no way to steer the result.
 */
export function aggregate(_bls: BlsBn254, partials: PartialSignature[]): mcl.G1 {
    if (partials.length === 0) throw new Error('no partial signatures')
    const lambdas = lagrangeCoefficients(partials.map((p) => p.index))

    let acc = mcl.mul(partials[0].sig, lambdas[0])
    for (let i = 1; i < partials.length; i++) {
        acc = mcl.add(acc, mcl.mul(partials[i].sig, lambdas[i]))
    }
    acc.normalize()
    return acc
}

/**
 * Recover the group public key from any `t` shares, serialised in the EVM
 * ordering `[x.c0, x.c1, y.c0, y.c1]` expected by `VRFVerifier`.
 */
export function groupPublicKey(bls: BlsBn254, shares: Share[]): [bigint, bigint, bigint, bigint] {
    const lambdas = lagrangeCoefficients(shares.map((s) => s.index))

    let acc = mcl.mul(mcl.mul(bls.G2, shares[0].secret), lambdas[0])
    for (let i = 1; i < shares.length; i++) {
        acc = mcl.add(acc, mcl.mul(mcl.mul(bls.G2, shares[i].secret), lambdas[i]))
    }
    acc.normalize()
    return bls.serialiseG2Point(acc)
}
