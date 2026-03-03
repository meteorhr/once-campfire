import { Controller } from "@hotwired/stimulus"
import { computeFingerprint } from "lib/e2e/client"

export default class extends Controller {
  static targets = ["output", "peerOutput"]
  static values = {
    ownPublicKey: String,
    peerPublicKey: String
  }

  async connect() {
    if (this.hasOwnPublicKeyValue && this.ownPublicKeyValue) {
      await this.#displayFingerprint(this.ownPublicKeyValue, this.outputTarget)
    }

    if (this.hasPeerPublicKeyValue && this.peerPublicKeyValue) {
      await this.#displayFingerprint(this.peerPublicKeyValue, this.peerOutputTarget)
    }
  }

  async #displayFingerprint(publicKeyJson, target) {
    try {
      const jwk = JSON.parse(publicKeyJson)
      const fingerprint = await computeFingerprint(jwk)
      target.textContent = fingerprint
    } catch {
      target.textContent = "Unable to compute fingerprint"
    }
  }
}
