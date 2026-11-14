'use strict';
const crypto = require('node:crypto');
const { OAuth2Client } = require('google-auth-library');

// A public key's reusable self-signature is public data, not a login secret.
// Each login must prove possession of its private key against a one-use nonce.
function createAuthProof({ audience = process.env.GOOGLE_WEB_CLIENT_ID, verifyGoogle } = {}) {
  const challenges = new Map();
  const google = new OAuth2Client();
  return {
    issue(username) {
      const now = Date.now();
      for (const [id, value] of challenges) {
        if (value.expires <= now) challenges.delete(id);
      }
      if (!/^[a-z0-9_]{3,32}$/.test(username) || challenges.size >= 1000) return null;
      const challenge = crypto.randomBytes(32).toString('hex');
      challenges.set(challenge, { username, expires: now + 60000 });
      return challenge;
    },
    verify({ username, challenge, proof, publicKey }) {
      const value = challenges.get(challenge);
      challenges.delete(challenge); // Consume even a failed proof.
      if (!value || value.username !== username || value.expires <= Date.now()) return false;
      try {
        return crypto.verify('sha256', Buffer.from(
          Buffer.from(`shade-register:v1:${username}:${challenge}`).toString('base64')),
        { key: publicKey, padding: crypto.constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 },
        Buffer.from(proof, 'base64'));
      } catch { return false; }
    },
    async googleProfile(idToken) {
      if (!audience) throw new Error('Google sign-in is not configured on this server');
      const payload = verifyGoogle
        ? await verifyGoogle(idToken, audience)
        : (await google.verifyIdToken({ idToken, audience })).getPayload();
      if (!payload?.sub || !payload.email_verified || !payload.email) throw new Error('Unverified Google account');
      return { googleSub: payload.sub, email: payload.email,
        displayName: (payload.name || '').slice(0, 120), avatarUrl: payload.picture || null };
    },
  };
}
module.exports = { createAuthProof };
