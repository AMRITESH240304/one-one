import { Router } from "express";

/**
 * Digital Asset Links manifest that lets Android verify this domain is
 * allowed to open the app directly for our HTTPS intent filter
 * (`https://one-one-xw00.onrender.com/invite/...`) instead of falling back
 * to a browser. Must be reachable at exactly
 * `/.well-known/assetlinks.json`, unauthenticated, with a JSON content
 * type — Google's verifier fetches it directly, not through a browser
 * session.
 *
 * Keep the package name and SHA-256 signing certificate fingerprint here in
 * sync with `android/app/src/main/AndroidManifest.xml`'s intent filter and
 * the app's actual release signing certificate. If the signing key ever
 * rotates, this fingerprint must be updated too or app link verification
 * will start failing again.
 */
const ASSET_LINKS = [
  {
    relation: ["delegate_permission/common.handle_all_urls"],
    target: {
      namespace: "android_app",
      package_name: "app.oneone.one_one_app",
      sha256_cert_fingerprints: [
        "4E:97:BB:5D:93:4F:EA:6B:9C:0B:C3:D0:03:37:56:63:5A:AD:27:C9:3B:74:19:80:91:AE:82:77:B6:2D:9F:92"
      ]
    }
  }
];

export function createWellKnownRoutes() {
  const router = Router();

  router.get("/.well-known/assetlinks.json", (_request, response) => {
    response.status(200).type("application/json").json(ASSET_LINKS);
  });

  return router;
}
