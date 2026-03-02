import { Controller } from "@hotwired/stimulus"
import { escapeHTML } from "helpers/dom_helpers"
import { getRoomE2EClient } from "lib/e2e/client"

export default class extends Controller {
  static values = {
    payload: Object,
    senderId: Number
  }

  async connect() {
    if (!this.hasPayloadValue || !this.hasSenderIdValue) {
      return
    }

    const config = this.#composerE2EConfig
    if (!config.enabled) {
      this.#showUndecryptable()
      return
    }

    const client = await getRoomE2EClient(config)
    if (!client) {
      this.#showUndecryptable()
      return
    }

    const plaintext = await client.decrypt(this.payloadValue, this.senderIdValue)

    if (plaintext === null) {
      this.#showUndecryptable()
      return
    }

    this.#renderPlaintext(plaintext)
  }

  #renderPlaintext(plaintext) {
    const html = escapeHTML(plaintext).replace(/\n/g, "<br>")
    this.element.innerHTML = `<div class="trix-content"><div>${html}</div></div>`
  }

  #showUndecryptable() {
    this.element.innerHTML = '<span class="pending">Encrypted message (unable to decrypt on this device)</span>'
  }

  get #composerE2EConfig() {
    const composer = document.querySelector("#composer")

    return {
      deviceUrl: composer?.dataset?.composerE2eDeviceUrlValue,
      enabled: composer?.dataset?.composerE2eEnabledValue === "true",
      peerUserId: Number(composer?.dataset?.composerE2ePeerUserIdValue),
      prekeyBundleUrl: composer?.dataset?.composerE2ePrekeyBundleUrlValue,
      selfPrekeyBundleUrl: composer?.dataset?.composerE2eSelfPrekeyBundleUrlValue,
      roomId: Number(composer?.dataset?.composerRoomIdValue),
    }
  }
}
