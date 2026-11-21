package com.example.shade;

import java.util.Arrays;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** PBKDF2-HMAC-SHA256 over raw password bytes, matching PointyCastle. */
public final class DatabaseKeyDerivation {
    public static byte[] derive(byte[] password, byte[] salt, int iterations) throws Exception {
        if (iterations < 1) throw new IllegalArgumentException("Invalid iterations");
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(password, "HmacSHA256"));
        byte[] block = Arrays.copyOf(salt, salt.length + 4);
        block[block.length - 1] = 1;
        byte[] u = mac.doFinal(block);
        byte[] key = u.clone();
        for (int i = 1; i < iterations; i++) {
            byte[] next = mac.doFinal(u);
            Arrays.fill(u, (byte) 0);
            u = next;
            for (int j = 0; j < key.length; j++) key[j] ^= u[j];
        }
        Arrays.fill(u, (byte) 0);
        Arrays.fill(block, (byte) 0);
        return key;
    }
}
