import { test } from 'node:test'
import assert from 'node:assert/strict'
import { toUtf8Bytes } from 'ethers'
import { BlsBn254 } from '@kevincharm/bls-bn254'
import { DST } from '../src/constants'
import { splitSecret, partialSign, aggregate, groupPublicKey } from '../src/threshold'

const N = 9
const T = 5

test('any t of n partial signatures aggregate to the single group signature', async () => {
    const bls = await BlsBn254.create()
    const { secretKey } = bls.createKeyPair('0xdeadbeef')
    const msg = bls.hashToPoint(toUtf8Bytes(DST), toUtf8Bytes('seed-1'))

    const full = bls.serialiseG1Point(bls.sign(msg, secretKey).signature)
    const shares = splitSecret(bls, secretKey, T, N)

    // two disjoint quorums must produce the very same signature
    const quorumA = [0, 1, 2, 3, 4].map((i) => partialSign(bls, shares[i], msg))
    const quorumB = [4, 5, 6, 7, 8].map((i) => partialSign(bls, shares[i], msg))

    assert.deepEqual(bls.serialiseG1Point(aggregate(bls, quorumA)), full)
    assert.deepEqual(bls.serialiseG1Point(aggregate(bls, quorumB)), full)
})

test('fewer than t partial signatures do not reconstruct the group signature', async () => {
    const bls = await BlsBn254.create()
    const { secretKey } = bls.createKeyPair('0xdeadbeef')
    const msg = bls.hashToPoint(toUtf8Bytes(DST), toUtf8Bytes('seed-1'))

    const full = bls.serialiseG1Point(bls.sign(msg, secretKey).signature)
    const shares = splitSecret(bls, secretKey, T, N)
    const tooFew = [0, 1, 2, 3].map((i) => partialSign(bls, shares[i], msg))

    assert.notDeepEqual(bls.serialiseG1Point(aggregate(bls, tooFew)), full)
})

test('a forged partial share corrupts the aggregate', async () => {
    const bls = await BlsBn254.create()
    const { secretKey } = bls.createKeyPair('0xdeadbeef')
    const msg = bls.hashToPoint(toUtf8Bytes(DST), toUtf8Bytes('seed-1'))

    const full = bls.serialiseG1Point(bls.sign(msg, secretKey).signature)
    const shares = splitSecret(bls, secretKey, T, N)
    const rogue = { ...shares[2], secret: bls.createKeyPair('0xbadbad').secretKey }
    const partials = [shares[0], shares[1], rogue, shares[3], shares[4]].map((s) =>
        partialSign(bls, s, msg),
    )

    assert.notDeepEqual(bls.serialiseG1Point(aggregate(bls, partials)), full)
})

test('group public key is independent of which shares exist', async () => {
    const bls = await BlsBn254.create()
    const { secretKey, pubKey } = bls.createKeyPair('0xdeadbeef')
    const shares = splitSecret(bls, secretKey, T, N)

    assert.deepEqual(groupPublicKey(bls, shares.slice(0, T)), bls.serialiseG2Point(pubKey))
    assert.deepEqual(groupPublicKey(bls, shares.slice(N - T)), bls.serialiseG2Point(pubKey))
})
