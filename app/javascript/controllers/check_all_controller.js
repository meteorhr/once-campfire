import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "checkAll", "checkbox" ]

  toggleAll() {
    const checked = this.checkAllTarget.checked
    this.checkboxTargets.forEach(checkbox => checkbox.checked = checked)
  }

  updateCheckAll() {
    const total = this.checkboxTargets.length
    const checked = this.checkboxTargets.filter(cb => cb.checked).length
    this.checkAllTarget.checked = total > 0 && checked === total
    this.checkAllTarget.indeterminate = checked > 0 && checked < total
  }
}
