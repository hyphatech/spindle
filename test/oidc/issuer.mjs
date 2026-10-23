// An authorization server for test_oauth_rfc: node-oidc-provider, OpenID
// Certified, issuing RFC 9068 access tokens to one client by the client
// credentials grant, each for the resource RFC 8707's parameter names, over
// HTTPS with the certificate the suite made, since RFC 8414 has an issuer be
// an https URL. It prints its port, and serves until its input closes. Bun
// runs it, as it runs the site, though the provider names Node as the
// runtime it supports: its startup warning says so, and is all that differs.
//
//   bun issuer.mjs CERT.pem KEY.pem

import { generateKeyPairSync } from "node:crypto";
import { readFileSync } from "node:fs";
import https from "node:https";
import Provider from "oidc-provider";

const [cert, key] = process.argv.slice(2);

// A key of each kind Spindle checks, so a row can ask for any.
const signing = (kind, options, kid) => ({
  ...generateKeyPairSync(kind, options).privateKey.export({ format: "jwk" }),
  kid,
  use: "sig",
});

const server = https.createServer({
  cert: readFileSync(cert),
  key: readFileSync(key),
});

server.listen(0, "localhost", () => {
  const { port } = server.address();
  const provider = new Provider(`https://localhost:${port}`, {
    clients: [
      {
        client_id: "spindle-test",
        client_secret: "a-secret-the-suite-knows",
        grant_types: ["client_credentials"],
        redirect_uris: [],
        response_types: [],
      },
    ],
    jwks: {
      keys: [
        signing("rsa", { modulusLength: 2048 }, "rsa"),
        signing("ec", { namedCurve: "P-256" }, "p256"),
        signing("ed25519", {}, "ed25519"),
      ],
    },
    features: {
      devInteractions: { enabled: false },
      clientCredentials: { enabled: true },
      resourceIndicators: {
        enabled: true,
        getResourceServerInfo: (_ctx, resource) => ({
          scope: "notes:read notes:write",
          audience: resource,
          accessTokenFormat: "jwt",
          // The resource's last segment picks the algorithm a row checks.
          jwt: {
            sign: {
              alg: resource.endsWith("/rsa")
                ? "RS256"
                : resource.endsWith("/ed25519")
                  ? "EdDSA"
                  : "ES256",
            },
          },
        }),
      },
    },
  });
  server.on("request", provider.callback());
  console.log(port);
});

process.stdin.on("end", () => process.exit(0));
process.stdin.resume();
