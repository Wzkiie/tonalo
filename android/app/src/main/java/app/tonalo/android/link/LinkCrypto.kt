package app.tonalo.android.link

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * The small security layer the TV, the iPhone and their guests share (tv/service/service.js, ios/LinkHTTP.swift):
 * - Pairing: the other screen shows a code. It never goes over the network – the phone proves it knows it with an
 *   HMAC over its public key, and both sides work out the same key with ECDH (P-256).
 * - Every request is signed with that key: HMAC over method, path, time, a one-time value and the body.
 */
object LinkCrypto {
    private val random = SecureRandom()

    fun random(count: Int) = ByteArray(count).also { random.nextBytes(it) }

    fun hmac(key: ByteArray, data: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(key, "HmacSHA256")); doFinal(data) }

    fun newKeyPair(): KeyPair =
        KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()

    /** Uncompressed point (0x04 · X · Y), 65 bytes – what CryptoKit's x963Representation and Node's ECDH use. */
    fun publicBytes(pair: KeyPair): ByteArray {
        val w = (pair.public as ECPublicKey).w
        return byteArrayOf(4) + fixed(w.affineX) + fixed(w.affineY)
    }

    private fun fixed(n: BigInteger): ByteArray {
        val b = n.toByteArray().dropWhile { it == 0.toByte() }.toByteArray()
        return ByteArray(32 - b.size) + b
    }

    private val p256: ECParameterSpec by lazy {
        AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }.getParameterSpec(ECParameterSpec::class.java)
    }

    fun publicKey(bytes: ByteArray): ECPublicKey? = runCatching {
        if (bytes.size != 65 || bytes[0] != 4.toByte()) return null
        val point = ECPoint(BigInteger(1, bytes.copyOfRange(1, 33)), BigInteger(1, bytes.copyOfRange(33, 65)))
        KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, p256)) as ECPublicKey
    }.getOrNull()

    /** Proof of knowing the code, tied to this public key. */
    fun proof(code: String, pub: ByteArray): ByteArray = hmac(code.toByteArray(), pub)

    /** The shared key from the pairing, as service.js and LinkHTTP.swift work it out. */
    fun pairingKey(mine: KeyPair, otherPub: ByteArray, code: String): ByteArray? {
        val other = publicKey(otherPub) ?: return null
        val secret = runCatching {
            KeyAgreement.getInstance("ECDH").run { init(mine.private); doPhase(other, true); generateSecret() }
        }.getOrNull() ?: return null
        return hmac(secret, "tonalo-pair\n$code".toByteArray())
    }

    fun signature(method: String, path: String, time: String, nonce: String, body: ByteArray, key: ByteArray): String =
        hmac(key, "$method\n$path\n$time\n$nonce\n".toByteArray() + body).hex

    /** `offsetSeconds`: how far the other side's clock is ahead – a TV with the wrong time still works. */
    fun authorization(method: String, path: String, body: ByteArray, keyId: String, key: ByteArray, offsetSeconds: Long = 0): String {
        val time = (System.currentTimeMillis() / 1000 + offsetSeconds).toString()
        val nonce = random(8).hex
        return "Tonalo $keyId:$time:$nonce:${signature(method, path, time, nonce, body, key)}"
    }

    /** Compares in full, so the time it takes says nothing about how much matched. */
    fun same(a: ByteArray, b: ByteArray) = MessageDigest.isEqual(a, b)
}

val ByteArray.hex: String get() = joinToString("") { "%02x".format(it) }

fun String.unhex(): ByteArray? {
    if (length % 2 != 0) return null
    return runCatching { ByteArray(length / 2) { substring(it * 2, it * 2 + 2).toInt(16).toByte() } }.getOrNull()
}
