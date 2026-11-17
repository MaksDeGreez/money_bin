import { Controller } from "@hotwired/stimulus"

// Copies the value of the source field to the clipboard and shows "Copied" on the button for a moment.
// Where the clipboard API is not allowed, it selects the text so the person can copy it by hand.
export default class extends Controller {
  static targets = ["source", "label"]

  async copy() {
    try {
      await navigator.clipboard.writeText(this.sourceTarget.value)
      this.flashLabel("Copied")
    } catch (error) {
      this.sourceTarget.select()
      this.flashLabel("Selected")
    }
  }

  flashLabel(text) {
    if (!this.hasLabelTarget) return

    this.originalLabel ??= this.labelTarget.textContent
    this.labelTarget.textContent = text
    clearTimeout(this.timer)
    this.timer = setTimeout(() => { this.labelTarget.textContent = this.originalLabel }, 2000)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
