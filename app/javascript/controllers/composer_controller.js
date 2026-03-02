import { Controller } from "@hotwired/stimulus"
import FileUploader from "models/file_uploader"
import { onNextEventLoopTick, nextFrame } from "helpers/timing_helpers"
import { escapeHTML } from "helpers/dom_helpers"
import { getRoomE2EClient } from "lib/e2e/client"

export default class extends Controller {
  static classes = ["toolbar"]
  static targets = [ "clientid", "e2eAlgorithm", "e2ePayload", "fields", "fileList", "text" ]
  static values = { e2eDeviceUrl: String, e2eEnabled: Boolean, e2ePeerUserId: Number, e2ePrekeyBundleUrl: String, e2eSelfPrekeyBundleUrl: String, roomId: Number }
  static outlets = [ "messages" ]

  #files = []
  #e2eClient = null

  async connect() {
    if (!this.#usingTouchDevice) {
      onNextEventLoopTick(() => this.textTarget.focus())
    }

    await this.#initializeE2E()
  }

  async submit(event) {
    event.preventDefault()

    if (!this.fieldsTarget.disabled) {
      if (this.e2eEnabledValue) {
        await this.#initializeE2E()
      }

      if (this.e2eEnabledValue && !this.#usingE2E) {
        alert("Encrypted direct chat is not ready yet. Please reload and try again.")
        return
      }

      if (this.e2eEnabledValue && this.#files.length > 0) {
        alert("Encrypted direct chats currently support text messages only.")
        return
      }

      await this.#submitFiles()
      await this.#submitMessage()
      this.collapseToolbar()
      this.textTarget.focus()
    }
  }

  submitEnd(event) {
    if (!event.detail.success) {
      this.messagesOutlet.failPendingMessage(this.clientidTarget.value)
    }
  }

  toggleToolbar() {
    this.element.classList.toggle(this.toolbarClass)
    this.textTarget.focus()
  }

  collapseToolbar() {
    this.element.classList.remove(this.toolbarClass)
  }

  replaceMessageContent(content) {
    const editor = this.textTarget.editor

    editor.recordUndoEntry("Format reply")
    editor.setSelectedRange([0, editor.getDocument().toString().length])
    editor.deleteInDirection("forward")
    editor.insertHTML(content)
    editor.setSelectedRange([editor.getDocument().toString().length - 1])
  }

  submitByKeyboard(event) {
    const toolbarVisible = this.element.classList.contains(this.toolbarClass)
    const metaEnter = event.key == "Enter" && (event.metaKey || event.ctrlKey)
    const plainEnter = event.keyCode == 13 && !event.shiftKey && !event.isComposing

    if (!this.#usingTouchDevice && (metaEnter || (plainEnter && !toolbarVisible))) {
      this.submit(event)
    }
  }

  filePicked(event) {
    for (const file of event.target.files) {
      this.#files.push(file)
    }
    event.target.value = null
    this.#updateFileList()
  }

  fileUnpicked(event) {
    this.#files.splice(event.params.index, 1)
    this.#updateFileList()
  }

  pasteFiles(event) {
    if (event.clipboardData.files.length > 0) {
      event.preventDefault()
    }

    for (const file of event.clipboardData.files) {
      this.#files.push(file)
    }

    this.#updateFileList()
  }

  dropFiles({ detail: { files } }) {
    for (const file of files) {
      this.#files.push(file)
    }

    this.#updateFileList()
  }

  preventAttachment(event) {
    event.preventDefault()
  }

  online() {
    this.fieldsTarget.disabled = false
  }

  offline() {
    this.fieldsTarget.disabled = true
  }

  get #usingTouchDevice() {
    return 'ontouchstart' in window || navigator.maxTouchPoints > 0 || navigator.msMaxTouchPoints > 0;
  }

  async #initializeE2E() {
    if (!this.e2eEnabledValue || this.#e2eClient?.available) {
      return
    }

    this.#e2eClient = await getRoomE2EClient({
      enabled: this.e2eEnabledValue,
      deviceUrl: this.e2eDeviceUrlValue,
      peerUserId: this.e2ePeerUserIdValue,
      prekeyBundleUrl: this.e2ePrekeyBundleUrlValue,
      selfPrekeyBundleUrl: this.e2eSelfPrekeyBundleUrlValue,
      roomId: this.roomIdValue,
    })
  }

  get #usingE2E() {
    return Boolean(this.e2eEnabledValue && this.#e2eClient?.available)
  }

  async #submitMessage() {
    if (this.#validInput()) {
      const clientMessageId = this.#generateClientId()
      let pendingNode = this.textTarget

      if (this.#usingE2E) {
        try {
          const plaintext = this.#plaintextInput
          const payload = await this.#e2eClient.encrypt(plaintext)

          this.e2eAlgorithmTarget.value = "double_ratchet_v1"
          this.e2ePayloadTarget.value = JSON.stringify(payload)
          pendingNode = `<div class=\"trix-content\"><div>${escapeHTML(plaintext)}</div></div>`
          this.#clearEditor()
        } catch (error) {
          console.error("Failed to encrypt outgoing message", error)
          alert("Unable to encrypt this message. Please reload the room and try again.")
          this.#resetE2EFields()
          return
        }
      } else {
        this.#resetE2EFields()
      }

      await this.messagesOutlet.insertPendingMessage(clientMessageId, pendingNode)
      await nextFrame()

      this.clientidTarget.value = clientMessageId
      this.element.requestSubmit()
      this.#reset()
    }
  }

  #validInput() {
    return this.textTarget.textContent.trim().length > 0
  }

  async #submitFiles() {
    const files = this.#files

    this.#files = []
    this.#updateFileList()

    for (const file of files) {
      const clientMessageId = this.#generateClientId()
      const uploader = new FileUploader(file, this.element.action, clientMessageId, this.#uploadProgress.bind(this))

      const body = this.#pendingUploadProgress(file.name)
      await this.messagesOutlet.insertPendingMessage(clientMessageId, body)

      const resp = await uploader.upload()

      Turbo.renderStreamMessage(resp)
    }
  }

  #uploadProgress(percent, clientMessageId, file) {
    const body = this.#pendingUploadProgress(file.name, percent)
    this.messagesOutlet.updatePendingMessage(clientMessageId, body)
  }

  #generateClientId() {
    return Math.random().toString(36).slice(2)
  }

  #reset() {
    this.#clearEditor()
    this.#resetE2EFields()
  }

  get #plaintextInput() {
    return this.textTarget.editor?.getDocument()?.toString()?.trim() || this.textTarget.textContent.trim()
  }

  #clearEditor() {
    const editor = this.textTarget.editor

    editor.recordUndoEntry("Clear input")
    editor.setSelectedRange([0, editor.getDocument().toString().length])
    editor.deleteInDirection("forward")
  }

  #resetE2EFields() {
    this.e2eAlgorithmTarget.value = ""
    this.e2ePayloadTarget.value = ""
  }

  #updateFileList() {
    this.#files.sort((a, b) => a.name.localeCompare(b.name))

    const fileNodes = this.#files.map((file, index) => {
      const filename = file.name.split(".").slice(0, -1).join(".")
      const extension = file.name.split(".").pop()

      const node = document.createElement("button")
      node.setAttribute("type","button")
      node.setAttribute("style","gap: 0")
      node.dataset.action = "composer#fileUnpicked"
      node.dataset.composerIndexParam = index
      node.className = "btn btn--plain composer__file txt-normal position-relative unpad flex-column"
      node.innerHTML = file.type.match(/^image\/.*/) ? `<img role="presentation" class="flex-item-no-shrink composer__file-thumbnail" src="${URL.createObjectURL(file)}">` : `<span class="composer__file-thumbnail composer__file-thumbnail--common colorize--black"></span>`
      node.innerHTML += `<span class="pad-inline txt-small flex align-center max-width composer__file-caption"><span class="overflow-ellipsis">${escapeHTML(filename)}.</span><span class="flex-item-no-shrink">${escapeHTML(extension)}</span></span>`

      return node
    })

    this.fileListTarget.replaceChildren(...fileNodes)
  }

  #pendingUploadProgress(filename, percent=0) {
    return `
      <div class="message__pending-upload flex align-center gap" style="--percentage: ${percent}%">
        <div class="composer__file-thumbnail composer__file-thumbnail--common colorize--black borderless flex-item-no-shrink"></div>
        <div>${escapeHTML(filename)} - <span>${percent}%</span></div>
      </div>
    `
  }
}
