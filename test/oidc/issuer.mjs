// An authorization server for test_oauth_rfc: node-oidc-provider, OpenID
// Certified, issuing RFC 9068 access tokens, each for the resource RFC
// 8707's parameter names, over HTTPS with the certificate the suite made,
// since RFC 8414 has an issuer be an https URL. Two clients: one by the
// client credentials grant, and a native one signing a person in by the code
// grant with PKCE, sent back to the loopback address (RFC 8252). The person
// is ada, who allows whatever is asked, so a browser only follows redirects.
// It prints its port, and serves until its input closes. Bun runs it, as it
// runs the site, though the provider names Node as the runtime it supports:
// its startup warning says so, and is all that differs.
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
      {
        client_id: "spindle-native",
        application_type: "native",
        token_endpoint_auth_method: "none",
        grant_types: ["authorization_code", "refresh_token"],
        response_types: ["code"],
        redirect_uris: ["http://127.0.0.1/callback"],
      },
    ],
    jwks: {
      keys: [
        signing("rsa", { modulusLength: 2048 }, "rsa"),
        signing("ec", { namedCurve: "P-256" }, "p256"),
        signing("ed25519", {}, "ed25519"),
      ],
    },
    findAccount: (_ctx, id) => ({
      accountId: id,
      claims: () => ({ sub: id }),
    }),
    interactions: {
      url: (_ctx, interaction) => `/interaction/${interaction.uid}`,
    },
    features: {
      devInteractions: { enabled: false },
      clientCredentials: { enabled: true },
      resourceIndicators: {
        enabled: true,
        useGrantedResource: () => true,
        getResourceServerInfo: (_ctx, resource) => ({
          scope: "notes:read notes:write weather:read",
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

  // ada signs in, and allows every scope asked for each resource.
  const interact = async (req, res) => {
    const details = await provider.interactionDetails(req, res);
    if (details.prompt.name === "login") {
      return provider.interactionFinished(
        req,
        res,
        { login: { accountId: "ada" } },
        { mergeWithLastSubmission: false },
      );
    }
    const grant = details.grantId
      ? await provider.Grant.find(details.grantId)
      : new provider.Grant({
          accountId: details.session.accountId,
          clientId: details.params.client_id,
        });
    const missing = details.prompt.details;
    if (missing.missingOIDCScope) {
      grant.addOIDCScope(missing.missingOIDCScope.join(" "));
    }
    for (const [resource, scopes] of Object.entries(
      missing.missingResourceScopes ?? {},
    )) {
      grant.addResourceScope(resource, scopes.join(" "));
    }
    const grantId = await grant.save();
    return provider.interactionFinished(
      req,
      res,
      { consent: { grantId } },
      { mergeWithLastSubmission: true },
    );
  };

  const callback = provider.callback();
  server.on("request", (req, res) => {
    if (req.url.startsWith("/interaction/")) {
      interact(req, res).catch((e) => {
        res.statusCode = 500;
        res.end(String(e));
      });
    } else {
      callback(req, res);
    }
  });
  console.log(port);
});

process.stdin.on("end", () => process.exit(0));
process.stdin.resume();
