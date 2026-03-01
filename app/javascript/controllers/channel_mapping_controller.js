import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "select", "nameInput" ]

  connect() {
    this.toggle()
  }

  toggle() {
    const isNew = this.selectTarget.value === "new"
    this.nameInputTarget.style.display = isNew ? "" : "none"
    this.nameInputTarget.disabled = !isNew
  }
}
